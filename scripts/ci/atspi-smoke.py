"""AT-SPI smoke test of the native lyric-ui host (docs/67 G10, issue #8489).

Run by scripts/ci/ui-native-e2e.sh inside a D-Bus session with the AT-SPI bus enabled, while the
customers example (examples/ui-customers on the native host) runs in an X11 window.  It reads the
application's accessibility tree over AT-SPI, the way a screen reader does, and checks:

  - the window, its heading and the customer grid are there with their roles and names;
  - a customer link exposes a "click" action, and doing it opens the edit screen;
  - the edit screen's name input is a text entry labelled by its field, holding the customer's name
    as text;
  - grabbing focus on the input moves the application's focus there;
  - setting the input's text through EditableText changes it.

Usage: python3 atspi-smoke.py <application name> <customer name>
"""

import sys
import time

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi, GLib  # noqa: E402


def fail(message):
    print("FAIL: " + message)
    sys.exit(1)


def find_app(name, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        desktop = Atspi.get_desktop(0)
        for i in range(desktop.get_child_count()):
            app = desktop.get_child_at_index(i)
            if app is not None and app.get_name() == name:
                return app
        time.sleep(0.2)
    return None


def walk(node, depth=0, out=None):
    """The subtree of `node` in pre-order.  A node can go away while it is read (the screen
    changes under the walk); such a node and its subtree are left out."""
    if out is None:
        out = []
    if node is None:
        return out
    try:
        count = node.get_child_count()
        out.append((depth, node))
        for i in range(count):
            walk(node.get_child_at_index(i), depth + 1, out)
    except GLib.Error:
        pass
    return out


def describe(node):
    try:
        return "%s %r" % (node.get_role_name(), node.get_name())
    except GLib.Error:
        return "(gone)"


def dump(app):
    for depth, node in walk(app):
        print("  " * depth + describe(node))


def nodes(app):
    return [n for _, n in walk(app)]


def find(app, role, name=None, seconds=5.0):
    deadline = time.time() + seconds
    while True:
        for n in nodes(app):
            try:
                if n.get_role_name() == role and (name is None or n.get_name() == name):
                    return n
            except GLib.Error:
                continue
        if time.time() > deadline:
            return None
        time.sleep(0.2)


def text_of(node):
    try:
        if node.get_text_iface() is None:
            return None
        return Atspi.Text.get_text(node, 0, Atspi.Text.get_character_count(node))
    except GLib.Error:
        return None


def focused(node):
    try:
        return node.get_state_set().contains(Atspi.StateType.FOCUSED)
    except GLib.Error:
        return False


def wait_for(predicate, seconds, what):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if predicate():
            return
        time.sleep(0.2)
    fail(what)


def main():
    app_name, customer = sys.argv[1], sys.argv[2]
    Atspi.init()
    app = find_app(app_name, 20.0)
    if app is None:
        names = []
        desktop = Atspi.get_desktop(0)
        for i in range(desktop.get_child_count()):
            child = desktop.get_child_at_index(i)
            names.append(child.get_name() if child is not None else None)
        fail("no AT-SPI application named %r (found %r)" % (app_name, names))
    print("application %r, toolkit %r" % (app.get_name(), app.get_toolkit_name()))

    window = find(app, "window", None, 10.0) or find(app, "frame", None, 1.0)
    if window is None:
        dump(app)
        fail("the application has no window node")
    print("window: " + describe(window))

    link = find(app, "link", customer, 10.0)
    if link is None:
        dump(app)
        fail("no link named %r on the list screen" % customer)
    if find(app, "table") is None:
        dump(app)
        fail("the customer grid is not a table")
    if find(app, "heading") is None:
        dump(app)
        fail("the list screen has no heading")
    print("list screen:")
    dump(app)

    if link.get_action_iface() is None or Atspi.Action.get_n_actions(link) < 1:
        fail("the link has no action")
    if Atspi.Action.get_action_name(link, 0) != "click":
        fail("the link's action is %r, not click" % Atspi.Action.get_action_name(link, 0))
    if not Atspi.Action.do_action(link, 0):
        fail("the click action was refused")

    entry = find(app, "entry", "Name", 10.0)
    if entry is None:
        dump(app)
        fail("the click did not open the edit screen (no entry named 'Name')")
    print("edit screen:")
    dump(app)
    wait_for(lambda: text_of(entry) == customer, 5.0,
             "the name input's text is %r, not %r" % (text_of(entry), customer))

    if entry.get_component_iface() is None or not Atspi.Component.grab_focus(entry):
        fail("the name input refused focus")
    wait_for(lambda: focused(entry), 5.0,
             "the name input did not become focused")

    if entry.get_editable_text_iface() is None:
        fail("the name input has no EditableText interface")
    if not Atspi.EditableText.set_text_contents(entry, "Set By AT-SPI"):
        fail("setting the name input's text was refused")
    wait_for(lambda: text_of(entry) == "Set By AT-SPI", 5.0,
             "the name input's text is %r after setting it" % text_of(entry))

    print("AT-SPI: roles and names, a click by action, focus and set value all work")


if __name__ == "__main__":
    main()
