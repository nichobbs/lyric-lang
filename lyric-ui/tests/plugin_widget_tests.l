//! tests/plugin_widget_tests.l — plugin widgets on the host side
//! (docs/65 §6.5, docs/69 §16 P6): converting a plugin's `WidgetTree` into a
//! `View`, the checks a tree must pass, and the placement's transitions
//! (requests, queueing, stale replies, failures and retries), including a
//! session that routes a host event into a plugin message.
@test_module
package Ui.PluginWidgetTests

import Std.Core
import Std.Collections
import Std.Testing
import Std.JsonValue.{JsonValue, JsonField, JNull, JInt, JString, JObject, writeValue}
import Ui.Core.{View, Element, Text, Empty, Step, UiEffect, WidgetKind, stay, stepAll, propOf, childrenOf}
import Ui.Testing.{hasText, click, findAll}
import Ui.Protocol.{Event, NodeRef, At, Keyed}
import Ui.Session
import Ui.Session.{Program, Output}
import Ui.Plugins.{WidgetTree, TreeNode, TreeText, TreeEmpty, NodeKind, NodeEvent, NodeProp, NodeHandler, WidgetStep, WidgetOutcome}
import Ui.PluginWidgets
import Ui.PluginWidgets.{PluginWidget, WidgetRef, WidgetSignal, WidgetEvent, WidgetRetry, WidgetRequest, WidgetReply, WidgetChange, WidgetCall, CallInit, CallUpdate, CallConfigure, Starting, Ready, Broken}

// Plugin views built by hand: a plugin builds them with Ui.Plugins.Build,
// which the host side does not depend on.
func noProps(): List[NodeProp] {
  newList()
}

func noHandlers(): List[NodeHandler] {
  newList()
}

func treeOf(
  kind: in NodeKind,
  key: in String,
  props: in List[NodeProp],
  handlers: in List[NodeHandler],
  children: in List[WidgetTree],
): WidgetTree {
  TreeNode(kind = kind, key = key, props = props, handlers = handlers, children = children)
}

func treeText(s: in String): WidgetTree {
  TreeText(text = s)
}

func treeParagraph(s: in String): WidgetTree {
  val kids: List[WidgetTree] = newList()
  kids.add(treeText(s))
  treeOf(NodeKind.Paragraph, "", noProps(), noHandlers(), kids)
}

func treeColumn(kids: in List[WidgetTree]): WidgetTree {
  treeOf(NodeKind.Column, "", noProps(), noHandlers(), kids)
}

func treeButton(key: in String, label: in String, message: in String): WidgetTree {
  val ps = noProps()
  ps.add(NodeProp(name = "label", value = label))
  val hs = noHandlers()
  hs.add(NodeHandler(event = NodeEvent.Click, message = message))
  treeOf(NodeKind.Button, key, ps, hs, newList())
}

func treeInput(key: in String, message: in String): WidgetTree {
  val ps = noProps()
  ps.add(NodeProp(name = "value", value = ""))
  val hs = noHandlers()
  hs.add(NodeHandler(event = NodeEvent.Input, message = message))
  treeOf(NodeKind.TextInput, key, ps, hs, newList())
}

func treeLink(label: in String, url: in String): WidgetTree {
  val ps = noProps()
  ps.add(NodeProp(name = "href", value = url))
  val kids: List[WidgetTree] = newList()
  kids.add(treeText(label))
  treeOf(NodeKind.Link, "", ps, noHandlers(), kids)
}

func source(): WidgetRef {
  WidgetRef(plugin = "example.widgets", widget = "counter")
}

func config(): JsonValue {
  val fs: List[JsonField] = newList()
  fs.add(JsonField(name = "step", value = JInt(value = 1i64)))
  JObject(fields = fs)
}

func countState(n: in Int): JsonValue {
  val fs: List[JsonField] = newList()
  fs.add(JsonField(name = "count", value = JInt(value = n.toLong())))
  JObject(fields = fs)
}

func counterTree(n: in Int): WidgetTree {
  val kids: List[WidgetTree] = newList()
  kids.add(treeParagraph("Count " + n.toString()))
  kids.add(treeButton("inc", "Add", "inc"))
  kids.add(treeInput("name", "rename"))
  treeColumn(kids)
}

func step(n: in Int): WidgetStep {
  WidgetStep(state = countState(n), view = counterTree(n), outcomes = newList())
}

func stepWithOutcome(n: in Int): WidgetStep {
  val os: List[WidgetOutcome] = newList()
  os.add(WidgetOutcome(name = "changed", payload = JInt(value = n.toLong())))
  WidgetStep(state = countState(n), view = counterTree(n), outcomes = os)
}

func only(c: in WidgetChange): WidgetRequest {
  assertEqualInt(c.requests.count, 1, "exactly one request")
  c.requests[0]
}

func ok(r: in WidgetRequest, s: in WidgetStep): WidgetReply {
  WidgetReply(instance = r.instance, seq = r.seq, answer = Ok(value = s))
}

func failed(r: in WidgetRequest, reason: in String): WidgetReply {
  WidgetReply(instance = r.instance, seq = r.seq, answer = Err(error = reason))
}

func isInit(r: in WidgetRequest): Bool {
  match r.call {
    case CallInit(_) -> true
    case _ -> false
  }
}

func isConfigure(r: in WidgetRequest): Bool {
  match r.call {
    case CallConfigure(_) -> true
    case _ -> false
  }
}

func updateMessage(r: in WidgetRequest): String {
  match r.call {
    case CallUpdate(u) -> u.message.message + "=" + u.message.data + "@" + writeValue(u.state)
    case _ -> "<not an update>"
  }
}

// A placement that has started and shows count `n`.
func started(n: in Int): PluginWidget {
  val c0 = PluginWidgets.placeWidget("w1", source(), config())
  PluginWidgets.replyWidget(c0.widget, ok(only(c0), step(n))).widget
}

func signalView(w: in PluginWidget): View[WidgetSignal] {
  PluginWidgets.widgetView(w, { s: WidgetSignal -> s })
}

// ─── Converting a tree ────────────────────────────────────────────────────────
test "a plugin tree becomes the host widgets it names" {
  val v: View[WidgetSignal] = PluginWidgets.treeView("w1", counterTree(3), { s: WidgetSignal -> s })
  assertTrue(hasText(v, "Count 3"), "text carried")
  assertEqualInt(findAll(v, WidgetKind.Button).count, 1, "one button")
  assertEqualInt(findAll(v, WidgetKind.TextInput).count, 1, "one input")
}

test "a click produces the plugin's message for its placement" {
  match click(signalView(started(0)), "Add") {
    case Some(WidgetEvent(instance, message, data, coalesce)) -> {
      assertEqual(instance, "w1", "instance")
      assertEqual(message, "inc", "message")
      assertEqual(data, "", "no data")
      assertFalse(coalesce, "clicks do not coalesce")
    }
    case _ -> assertTrue(false, "expected a widget event")
  }
}

test "unknown properties are dropped and unsafe links lose their href" {
  val props: List[NodeProp] = newList()
  props.add(NodeProp(name = "label", value = "ok"))
  props.add(NodeProp(name = "onclick", value = "alert(1)"))
  props.add(NodeProp(name = "label", value = "second"))
  val ps = PluginWidgets.hostProps(props)
  assertEqualInt(ps.count, 1, "one property")
  assertEqual(ps[0].value, "ok", "the first label")
  for good in ["/customers/7", "https://example.com/a", "http://example.com"] {
    assertTrue(PluginWidgets.safeHref(good), good)
  }
  for bad in ["javascript:alert(1)", "//evil.example", "data:text/html,x", "/\\evil", "JAVASCRIPT:x", " /x", "relative"] {
    assertFalse(PluginWidgets.safeHref(bad), bad)
  }
  val link: View[WidgetSignal] = PluginWidgets.treeView(
    "w1",
    treeLink("x", "javascript:alert(1)"),
    { s: WidgetSignal -> s }
  )
  assertTrue(propOf(link, "href") == None, "href dropped")
}

test "a node keeps one handler per event" {
  val hs: List[NodeHandler] = newList()
  hs.add(NodeHandler(event = NodeEvent.Click, message = "a"))
  hs.add(NodeHandler(event = NodeEvent.Click, message = "b"))
  hs.add(NodeHandler(event = NodeEvent.Submit, message = "c"))
  val kept = PluginWidgets.distinctHandlers(hs)
  assertEqualInt(kept.count, 2, "click and submit")
  assertEqual(kept[0].message, "a", "the first click")
}

test "trees beyond the limits are refused" {
  assertTrue(PluginWidgets.treeIssue(counterTree(1)) == None, "a small tree passes")
  var deep: WidgetTree = treeText("leaf")
  var d = 0
  while d < PluginWidgets.maxTreeDepth + 1 {
    val kids: List[WidgetTree] = newList()
    kids.add(deep)
    deep = treeColumn(kids)
    d = d + 1
  }
  assertTrue(PluginWidgets.treeIssue(deep) != None, "too deep")
  val wide: List[WidgetTree] = newList()
  var i = 0
  while i < PluginWidgets.maxTreeNodes {
    wide.add(treeText("x"))
    i = i + 1
  }
  assertTrue(PluginWidgets.treeIssue(treeColumn(wide)) != None, "too many nodes")
  var long = "x"
  while long.length <= PluginWidgets.maxTreeChars {
    long = long + long
  }
  assertTrue(PluginWidgets.treeIssue(treeText(long)) != None, "too much text")
}

// ─── Transitions ──────────────────────────────────────────────────────────────
test "placing a widget sends init and shows a loading indicator" {
  val c = PluginWidgets.placeWidget("w1", source(), config())
  assertTrue(isInit(only(c)), "init request")
  assertTrue(c.widget.status == Starting, "starting")
  val v = signalView(c.widget)
  assertEqualInt(findAll(v, WidgetKind.Spinner).count, 1, "spinner")
}

test "a successful reply installs the state and view and passes outcomes on" {
  val c0 = PluginWidgets.placeWidget("w1", source(), config())
  val c1 = PluginWidgets.replyWidget(c0.widget, ok(only(c0), stepWithOutcome(4)))
  assertTrue(c1.widget.status == Ready, "ready")
  assertEqual(writeValue(c1.widget.state), "{\"count\":4}", "state")
  assertEqualInt(c1.outcomes.count, 1, "one outcome")
  assertEqual(c1.outcomes[0].name, "changed", "outcome")
  assertEqualInt(c1.requests.count, 0, "nothing more to send")
  assertTrue(hasText(signalView(c1.widget), "Count 4"), "view shown")
}

test "an event sends update with the current state" {
  val c = PluginWidgets.signalWidget(
    started(2),
    WidgetEvent(instance = "w1", message = "inc", data = "", coalesce = false)
  )
  assertEqual(updateMessage(only(c)), "inc=@{\"count\":2}", "update")
}

test "events wait while a request is in flight, and input events coalesce" {
  val w = started(0)
  val c1 = PluginWidgets.signalWidget(w, WidgetEvent(instance = "w1", message = "inc", data = "", coalesce = false))
  val r1 = only(c1)
  val c2 = PluginWidgets.signalWidget(
    c1.widget,
    WidgetEvent(instance = "w1", message = "rename", data = "A", coalesce = true)
  )
  val c3 = PluginWidgets.signalWidget(
    c2.widget,
    WidgetEvent(instance = "w1", message = "rename", data = "Ab", coalesce = true)
  )
  val c4 = PluginWidgets.signalWidget(
    c3.widget,
    WidgetEvent(instance = "w1", message = "inc", data = "", coalesce = false)
  )
  assertEqualInt(c4.requests.count, 0, "nothing sent while busy")
  assertEqualInt(c4.widget.queue.count, 2, "rename coalesced, inc queued")
  val d1 = PluginWidgets.replyWidget(c4.widget, ok(r1, step(1)))
  assertEqual(updateMessage(only(d1)), "rename=Ab@{\"count\":1}", "the latest text, on the new state")
  val d2 = PluginWidgets.replyWidget(d1.widget, ok(only(d1), step(1)))
  assertEqual(updateMessage(only(d2)), "inc=@{\"count\":1}", "then the queued click")
}

test "the queue is bounded" {
  val w = started(0)
  var cur = PluginWidgets.signalWidget(w, WidgetEvent(instance = "w1", message = "inc", data = "", coalesce = false)).widget
  var i = 0
  while i < PluginWidgets.maxQueuedSignals + 10 {
    cur = PluginWidgets.signalWidget(cur, WidgetEvent(instance = "w1", message = "inc", data = "", coalesce = false)).widget
    i = i + 1
  }
  assertEqualInt(cur.queue.count, PluginWidgets.maxQueuedSignals, "capped")
}

test "stale replies and other placements' signals are ignored" {
  val w = started(0)
  val c1 = PluginWidgets.signalWidget(w, WidgetEvent(instance = "w1", message = "inc", data = "", coalesce = false))
  val r1 = only(c1)
  val stale = WidgetReply(instance = "w1", seq = r1.seq - 1, answer = Ok(value = step(9)))
  val c2 = PluginWidgets.replyWidget(c1.widget, stale)
  assertTrue(PluginWidgets.isBusy(c2.widget), "still waiting")
  assertEqual(writeValue(c2.widget.state), "{\"count\":0}", "state unchanged")
  val other = PluginWidgets.signalWidget(w, WidgetEvent(instance = "w2", message = "inc", data = "", coalesce = false))
  assertEqualInt(other.requests.count, 0, "not this placement")
}

test "an event before the first view is ignored" {
  val c0 = PluginWidgets.placeWidget("w1", source(), config())
  val c1 = PluginWidgets.signalWidget(
    c0.widget,
    WidgetEvent(instance = "w1", message = "inc", data = "", coalesce = false)
  )
  assertEqualInt(c1.widget.queue.count, 0, "not queued")
}

test "a failure keeps the last view, shows a banner and offers a retry" {
  val w = started(5)
  val c1 = PluginWidgets.signalWidget(w, WidgetEvent(instance = "w1", message = "inc", data = "", coalesce = false))
  val queued = PluginWidgets.signalWidget(
    c1.widget,
    WidgetEvent(instance = "w1", message = "inc", data = "", coalesce = false)
  )
  val c2 = PluginWidgets.replyWidget(queued.widget, failed(only(c1), "the plugin crashed"))
  assertEqualInt(c2.requests.count, 0, "queued work dropped")
  assertEqualInt(c2.widget.queue.count, 0, "queue cleared")
  assertEqual(writeValue(c2.widget.state), "{\"count\":5}", "state kept")
  val v = signalView(c2.widget)
  assertTrue(hasText(v, "Count 5"), "last view kept")
  assertTrue(hasText(v, "is unavailable: the plugin crashed"), "banner")
  match click(v, "Retry") {
    case Some(sig) -> {
      val c3 = PluginWidgets.signalWidget(c2.widget, sig)
      assertTrue(isConfigure(only(c3)), "a started placement retries with configure")
      val c4 = PluginWidgets.replyWidget(c3.widget, ok(only(c3), step(5)))
      assertTrue(c4.widget.status == Ready, "recovered")
      assertFalse(hasText(signalView(c4.widget), "unavailable"), "banner gone")
    }
    case None -> assertTrue(false, "a Retry button")
  }
}

test "a failed init retries with init" {
  val c0 = PluginWidgets.placeWidget("w1", source(), config())
  val c1 = PluginWidgets.replyWidget(c0.widget, failed(only(c0), "no such widget"))
  match click(signalView(c1.widget), "Retry") {
    case Some(sig) -> assertTrue(isInit(only(PluginWidgets.signalWidget(c1.widget, sig))), "init again")
    case None -> assertTrue(false, "a Retry button")
  }
}

test "a view beyond the limits counts as a failure" {
  val c0 = PluginWidgets.placeWidget("w1", source(), config())
  val wide: List[WidgetTree] = newList()
  var i = 0
  while i < PluginWidgets.maxTreeNodes + 1 {
    wide.add(treeText("x"))
    i = i + 1
  }
  val c1 = PluginWidgets.replyWidget(
    c0.widget,
    ok(only(c0), WidgetStep(state = countState(1), view = treeColumn(wide), outcomes = newList()))
  )
  match c1.widget.status {
    case Broken(reason) -> assertTrue(reason.contains("cannot show"), reason)
    case _ -> assertTrue(false, "broken")
  }
  assertFalse(c1.widget.started, "not started")
}

test "reconfiguring sends configure, or waits for the call in flight" {
  val w = started(1)
  val c1 = PluginWidgets.reconfigureWidget(w, countState(7))
  assertTrue(isConfigure(only(c1)), "configure")
  val busy = PluginWidgets.signalWidget(w, WidgetEvent(instance = "w1", message = "inc", data = "", coalesce = false))
  val c2 = PluginWidgets.reconfigureWidget(busy.widget, countState(7))
  val c3 = PluginWidgets.reconfigureWidget(c2.widget, countState(8))
  assertEqualInt(c3.widget.queue.count, 1, "one pending configure")
  val d = PluginWidgets.replyWidget(c3.widget, ok(only(busy), step(2)))
  match only(d).call {
    case CallConfigure(req) -> assertEqual(writeValue(req.config), "{\"count\":8}", "the latest config")
    case _ -> assertTrue(false, "configure after the reply")
  }
}

// ─── Through a session ────────────────────────────────────────────────────────
// A screen holding one placement; its effects are the widget requests.
record Screen {
  widget: PluginWidget
  outcomes: List[String]
}

union ScreenMsg {
  case FromWidget(signal: WidgetSignal)
  case Replied(reply: WidgetReply)
}

func applyChange(m: in Screen, c: in WidgetChange): Step[Screen, WidgetRequest] {
  val seen: List[String] = newList()
  for o in m.outcomes {
    seen.add(o)
  }
  for o in c.outcomes {
    seen.add(o.name)
  }
  stepAll(Screen(widget = c.widget, outcomes = seen), c.requests)
}

func screenUpdate(m: in Screen, msg: in ScreenMsg): Step[Screen, WidgetRequest] {
  match msg {
    case FromWidget(s) -> applyChange(m, PluginWidgets.signalWidget(m.widget, s))
    case Replied(r) -> applyChange(m, PluginWidgets.replyWidget(m.widget, r))
  }
}

func screenView(m: in Screen): View[ScreenMsg] {
  PluginWidgets.widgetView(m.widget, { s: WidgetSignal -> FromWidget(signal = s) })
}

func noUiEffect(e: in WidgetRequest): Option[UiEffect[ScreenMsg]] {
  None
}

func screenProgram(): Program[Screen, ScreenMsg, WidgetRequest] {
  Program(update = screenUpdate, view = screenView, uiEffect = noUiEffect)
}

test "a host event on the plugin's button reaches the plugin as its message" {
  val c0 = PluginWidgets.placeWidget("w1", source(), config())
  val init: Step[Screen, WidgetRequest] = stepAll(Screen(widget = c0.widget, outcomes = newList()), c0.requests)
  val o0: Output[Screen, ScreenMsg, WidgetRequest] = Session.start(screenProgram(), init)
  assertEqualInt(o0.effects.count, 1, "init requested")
  val o1: Output[Screen, ScreenMsg, WidgetRequest] = Session.dispatch(
    screenProgram(),
    o0.session,
    Replied(reply = ok(o0.effects[0], stepWithOutcome(0)))
  )
  assertEqualInt(o1.session.model.outcomes.count, 1, "outcome reached the screen")
  // The app view is the session root's first child, keyed by the
  // placement's instance name; the plugin's view sits under "view".
  val path: List[NodeRef] = newList()
  path.add(Keyed(key = "w1"))
  path.add(Keyed(key = "view"))
  path.add(At(index = 0))
  path.add(Keyed(key = "inc"))
  val ev = Event(renderVersion = o1.session.version, path = path, name = "click", data = "", inputVersion = 0)
  val o2: Output[Screen, ScreenMsg, WidgetRequest] = Session.handleEvent(screenProgram(), o1.session, ev)
  assertFalse(o2.dropped, "the event resolved")
  assertEqualInt(o2.effects.count, 1, "an update request")
  assertEqual(updateMessage(o2.effects[0]), "inc=@{\"count\":0}", "the plugin's message")
}
