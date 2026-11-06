//! main.l - Access.Smoke: an AccessKit adapter on a real window, for CI on every platform.
//!
//! Opens a window, attaches the platform adapter before showing it (UI Automation needs that),
//! publishes the accessibility tree of a page with one button, and with `--wait-click <seconds>`
//! pumps the window until an assistive technology clicks the button.  Prints `adapter: attached`,
//! `tree: published <n> nodes`, `request: click press` and `adapter: detached` as it goes.
package Access.Smoke

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.Environment as Environment
import Std.Parse.{parseOptInt}
import Std.Time as Time
import Window
import Ui.Core.{Prop}
import Ui.Native.Layout.{Box}
import Ui.Native.Access.{AccessState, ReqClick, buildTree}
import Access.Platform as A11y

val title: String = "Lyric Access Smoke"

func box(
  kind: String,
  path: List[Int],
  text: String,
  events: List[String],
  y: Float,
  children: List[Box],
  focusable: Bool,
): Box {
  val props: List[Prop] = newList()
  Box(
    kind = kind,
    path = path,
    key = "",
    props = props,
    events = events,
    text = text,
    style = 0,
    x = 20.0f32,
    y = y,
    w = 160.0f32,
    h = 32.0f32,
    children = children,
    focusable = focusable,
    contentHeight = 0.0f32
  )
}

func page(): Box {
  val clicks: List[String] = newList()
  clicks.add("click")
  val heading: List[Int] = newList()
  heading.add(0)
  val button: List[Int] = newList()
  button.add(1)
  val kids: List[Box] = newList()
  kids.add(box("paragraph", heading, "Press the button.", newList(), 20.0f32, newList(), false))
  kids.add(box("button", button, "Press me", clicks, 60.0f32, newList(), true))
  box("page", newList(), "", newList(), 0.0f32, kids, false)
}

func idOf(b: Box): String {
  if b.kind == "button" {
    "press"
  } else if b.kind == "paragraph" {
    "prompt"
  } else {
    ""
  }
}

func fail(message: String): Int {
  Console.println("FAIL: " + message)
  1
}

func waitSeconds(): Int {
  val args = Environment.args()
  if args.length >= 3 and args[1] == "--wait-click" {
    match parseOptInt(args[2]) {
      case Some(n) -> n
      case None -> 0
    }
  } else {
    0
  }
}

func main(): Int {
  val wait = waitSeconds()
  match Window.init(Window.initVideo) {
    case Err(m) -> return fail(m)
    case Ok(_) -> ()
  }
  val win = match Window.createWindow(title, 320, 200, false) { case Ok(w) -> w; case Err(m) -> return fail(m) }
  val adapter = match A11y.attach(win, title, Window.displayScale(win)) {
    case Ok(a) -> a
    case Err(m) -> return fail(m)
  }
  Console.println("adapter: attached")
  Window.show(win)
  val st = AccessState(focusId = "", openSelect = "", edit = { id: String -> None })
  val tree = buildTree(page(), title, st, { b: Box -> idOf(b) })
  A11y.publish(adapter, tree)
  A11y.setWindowFocused(adapter, true)
  A11y.setWindowBounds(adapter, Window.windowBounds(win))
  Console.println("tree: published " + tree.nodes.count.toString() + " nodes")
  var clicked = false
  val deadline = Time.nowEpochMillis() + wait.toLong() * 1000
  while wait > 0 and not clicked and Time.nowEpochMillis() < deadline {
    var polling = true
    while polling {
      match Window.pollEvent() {
        case Some(_) -> ()
        case None -> {
          polling = false
        }
      }
    }
    for r in A11y.takeRequests(adapter) {
      match r.request.kind {
        case ReqClick -> {
          Console.println("request: click " + r.id)
          clicked = r.id == "press"
        }
        case _ -> Console.println("request: other for " + r.id)
      }
    }
    Window.delayNanos(20000000)
  }
  A11y.detach(adapter)
  Console.println("adapter: detached")
  Window.destroyWindow(win)
  Window.quit()
  if wait > 0 and not clicked {
    return fail("no assistive technology clicked the button within " + wait.toString() + " seconds")
  }
  0
}
