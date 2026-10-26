//! UiPluginE2e.Host — plugin widgets end to end (docs/65 §6.5, docs/69 §16
//! P6): a screen showing widgets from real plugin processes, driven through
//! the session driver every lyric-ui host uses (`Ui.Host.instance`).
//!
//! It loads the plugins in the directory given as its argument (the
//! `example.ui-widgets` example plugin and the `test.flaky-widgets` fixture),
//! places four widgets (a rating, a tag list, the flaky counter, and a
//! widget of a plugin that is not loaded), sends host events at the
//! plugins' buttons and inputs by their event paths, and checks the
//! rendered page after each step: the plugins' views, the outcomes they
//! send the screen, the queue, and how a failing, crashing, hanging or
//! oversized answer renders and recovers, with the state kept across a
//! restart of the plugin.
//!
//! It prints one `ok` or `not ok` line per check and exits with the number
//! of failures.  scripts/ci/ui-widget-plugins-e2e.sh runs it.
package UiPluginE2e.Host

import Std.Core
import Std.Collections
import Std.Environment.{args}
import Std.String as Str
import Std.Time.{sleepMillis, nowEpochMillis}
import Std.JsonValue.{JsonValue, JsonField, JNull, JInt, JString, JArray, JObject, writeValue}
import Std.Plugin
import Std.PluginSign.{TrustedKey, parsePublicKey}
import Ui.Core.{View, Step, UiEffect, stepAll}
import Ui.Widgets.{column, heading, paragraph, keyed}
import Ui.Protocol.{ClientMessage, EventMsg, Event, NodeRef, At, Keyed}
import Ui.Session.{Program}
import Ui.Host.{Instance, Outbox, instance}
import Ui.Plugins.{widgetPluginPointInfo}
import Ui.PluginWidgets
import Ui.PluginWidgets.{PluginWidget, WidgetRef, WidgetSignal, WidgetRequest, WidgetReply, WidgetChange, signalInstance}
import Ui.PluginWidgets.Host.{WidgetRunner, newWidgetRunner, runWidgetRequest, widgetCatalog, widgetCatalogIssues}

// ── The screen ─────────────────────────────────────────────────────────────
record Model {
  widgets: List[PluginWidget]
  outcomes: List[String]
}

union Msg {
  case FromWidget(signal: WidgetSignal)
  case Replied(reply: WidgetReply)
}

func config(fields: in List[JsonField]): JsonValue {
  JObject(fields = fields)
}

func ratingConfig(): JsonValue {
  val fs: List[JsonField] = newList()
  fs.add(JsonField(name = "max", value = JInt(value = 5i64)))
  fs.add(JsonField(name = "label", value = JString(value = "Quality")))
  config(fs)
}

func tagsConfig(): JsonValue {
  val fs: List[JsonField] = newList()
  fs.add(JsonField(name = "maxTags", value = JInt(value = 3i64)))
  config(fs)
}

func initial(): Step[Model, WidgetRequest] {
  val ws: List[PluginWidget] = newList()
  val reqs: List[WidgetRequest] = newList()
  val placements: List[WidgetChange] = newList()
  placements.add(
    PluginWidgets.placeWidget("rating", WidgetRef(plugin = "example.ui-widgets", widget = "rating"), ratingConfig())
  )
  placements.add(
    PluginWidgets.placeWidget("tags", WidgetRef(plugin = "example.ui-widgets", widget = "tags"), tagsConfig())
  )
  placements.add(
    PluginWidgets.placeWidget("counter", WidgetRef(plugin = "test.flaky-widgets", widget = "counter"), JNull)
  )
  placements.add(
    PluginWidgets.placeWidget("ghost", WidgetRef(plugin = "test.not-installed", widget = "anything"), JNull)
  )
  for c in placements {
    ws.add(c.widget)
    for r in c.requests {
      reqs.add(r)
    }
  }
  stepAll(Model(widgets = ws, outcomes = newList()), reqs)
}

// Apply `change` to the placement it is for.
func applied(m: in Model, change: in WidgetChange): Step[Model, WidgetRequest] {
  val ws: List[PluginWidget] = newList()
  for w in m.widgets {
    if w.instance == change.widget.instance {
      ws.add(change.widget)
    } else {
      ws.add(w)
    }
  }
  val log: List[String] = newList()
  for o in m.outcomes {
    log.add(o)
  }
  for o in change.outcomes {
    log.add(change.widget.instance + ":" + o.name + "=" + payloadText(o.payload))
  }
  stepAll(Model(widgets = ws, outcomes = log), change.requests)
}

// A payload as plain text: strings bare, arrays comma-separated.
func payloadText(j: in JsonValue): String {
  match j {
    case JString(s) -> s
    case JArray(items) -> {
      var t = ""
      for it in items {
        t = if t == "" then payloadText(it) else t + "," + payloadText(it)
      }
      t
    }
    case _ -> writeValue(j)
  }
}

func update(m: in Model, msg: in Msg): Step[Model, WidgetRequest] {
  val target = match msg { case FromWidget(s) -> signalInstance(s); case Replied(r) -> r.instance }
  for w in m.widgets {
    if w.instance == target {
      val change = match msg {
        case FromWidget(s) -> PluginWidgets.signalWidget(w, s)
        case Replied(r) -> PluginWidgets.replyWidget(w, r)
      }
      return applied(m, change)
    }
  }
  val none: List[WidgetRequest] = newList()
  stepAll(m, none)
}

func view(m: in Model): View[Msg] {
  val kids: List[View[Msg]] = newList()
  val title: View[Msg] = heading(1, "Plugin widgets")
  kids.add(title)
  val toMsg: (WidgetSignal) -> Msg = { s: WidgetSignal -> FromWidget(signal = s) }
  for w in m.widgets {
    val placed: View[Msg] = PluginWidgets.widgetView(w, toMsg)
    kids.add(placed)
  }
  var log = ""
  for o in m.outcomes {
    log = log + "[" + o + "]"
  }
  kids.add(keyed("outcomes", paragraph("Outcomes: " + log)))
  column(kids)
}

func noUiEffect(e: in WidgetRequest): Option[UiEffect[Msg]] {
  None
}

// ── Driving it ─────────────────────────────────────────────────────────────
record Discard {
}

impl Outbox for Discard {
  func send(text: in String): Unit = ()
}

ref record Checks {
  var failures: Int
}

func check(c: in Checks, ok: in Bool, what: in String): Unit {
  if ok {
    println("ok - " + what)
  } else {
    c.failures = c.failures + 1
    println("not ok - " + what)
  }
}

// Wait until the page contains every one of `texts` (and none of
// `absent`), or `timeoutMs` passes.  Effects run on the instance's own
// tasks, so the page changes on its own.
func waitFor(inst: in Instance, texts: in List[String], absent: in List[String], timeoutMs: in Int): Bool {
  val deadline = nowEpochMillis() + timeoutMs.toLong()
  while true {
    val page = inst.snapshot()
    var all = true
    for t in texts {
      if not Str.contains(page, t) {
        all = false
      }
    }
    for t in absent {
      if Str.contains(page, t) {
        all = false
      }
    }
    if all {
      return true
    }
    if nowEpochMillis() > deadline {
      println("# page: " + page)
      return false
    }
    sleepMillis(50)
  }
  false
}

func one(s: in String): List[String] {
  val xs: List[String] = newList()
  xs.add(s)
  xs
}

func two(a: in String, b: in String): List[String] {
  val xs = one(a)
  xs.add(b)
  xs
}

func nothing(): List[String] {
  newList()
}

// The event path of a node in placement `instance`'s view: the session root's
// first child is the screen column, whose child keyed `instance` holds the
// plugin's view under `view`.
func pathIn(instance: in String, rest: in List[NodeRef]): List[NodeRef] {
  val p: List[NodeRef] = newList()
  p.add(At(index = 0))
  p.add(Keyed(key = instance))
  p.add(Keyed(key = "view"))
  for r in rest {
    p.add(r)
  }
  p
}

func send(inst: in Instance, path: in List[NodeRef], name: in String, data: in String, iv: in Int): Unit {
  val ev = Event(renderVersion = 0, path = path, name = name, data = data, inputVersion = iv)
  inst.receive(EventMsg(event = ev), Discard())
}

func counterButton(name: in String): List[NodeRef] {
  val r: List[NodeRef] = newList()
  r.add(At(index = 0))
  r.add(Keyed(key = name))
  pathIn("counter", r)
}

func retry(inst: in Instance, instance: in String): Unit {
  val p: List[NodeRef] = newList()
  p.add(At(index = 0))
  p.add(Keyed(key = instance))
  p.add(Keyed(key = "retry"))
  send(inst, p, "click", "", 0)
}

func main(): Int {
  // `args()` follows the host's convention on argv0, so the directory is
  // the last argument.
  val argv = args()
  if argv.length == 0 {
    println("usage: UiPluginE2e.Host <plugins-directory>")
    return 2
  }
  val c = Checks(failures = 0)
  val points: List[PluginPointInfo] = newList()
  points.add(widgetPluginPointInfo())
  // Both plugins are signed with the example publisher key
  // (examples/plugins/keys/example-publisher.pub) by the e2e script.
  val key = match parsePublicKey("lyric-ed25519:hcEkg2A6Xnfv9mQVZmFxq2BPNyq0TfUzkWSeGp5JlaI=") {
    case Ok(k) -> k
    case Err(e) -> panic("example publisher key: " + e)
  }
  val keys: List[TrustedKey] = newList()
  keys.add(TrustedKey(publisher = "lyric-examples", publicKey = key))
  keys.add(TrustedKey(publisher = "lyric-tests", publicKey = key))
  val host = newPluginHost(
    PluginHostConfig(
      points = points,
      providers = newList(),
      policy = GrantAllRequested(),
      trust = Some(value = trustKeys(keys)),
      callTimeoutMs = 3000,
      startTimeoutMs = 20000,
      preferWasm = false,
      restartBackoffMs = 100
    )
  )
  val dirs: List[String] = newList()
  dirs.add(argv[argv.length - 1])
  val issues = discoverPlugins(host, dirs)
  for i in issues {
    println("# load issue: " + pluginLoadIssueMessage(i))
  }
  check(c, issues.count == 0, "both plugins load")
  check(c, widgetCatalogIssues(host).count == 0, "their contributions decode")
  var names = ""
  for e in widgetCatalog(host) {
    names = names + e.plugin + "/" + e.decl.name + ";"
  }
  check(
    c,
    names == "example.ui-widgets/rating;example.ui-widgets/tags;test.flaky-widgets/counter;",
    "the catalog lists every widget from the manifests: " + names
  )

  val runner = newWidgetRunner(host)
  val program: Program[Model, Msg, WidgetRequest] = Program(update = update, view = view, uiEffect = noUiEffect)
  val run = { r: WidgetRequest ->
    val reply: WidgetReply = runWidgetRequest(runner, r)
    Some(value = Replied(reply = reply))
  }
  val inst = instance(program, initial(), run)
  inst.start(Discard())

  val firstViews: List[String] = newList()
  firstViews.add("Not rated")
  firstViews.add("No tags yet")
  firstViews.add("Count 0")
  check(c, waitFor(inst, firstViews, nothing(), 30000), "every loaded widget shows its first view")
  check(
    c,
    waitFor(inst, one("is unavailable: no widget plugin"), nothing(), 5000),
    "a widget of a missing plugin shows an error, not a broken screen"
  )

  // The rating: a star click reaches the plugin as its message, and the
  // widget's outcome reaches the screen.
  val star: List[NodeRef] = newList()
  star.add(At(index = 0))
  star.add(At(index = 0))
  star.add(Keyed(key = "star-4"))
  send(inst, pathIn("rating", star), "click", "", 0)
  check(
    c,
    waitFor(inst, two("4 of 5", "[rating:rated=4]"), nothing(), 10000),
    "a star click rates and tells the screen"
  )

  // The tags: input events carry the text; the button adds it.
  val draft: List[NodeRef] = newList()
  draft.add(At(index = 0))
  draft.add(Keyed(key = "entry"))
  draft.add(Keyed(key = "draft"))
  send(inst, pathIn("tags", draft), "input", "alp", 1)
  send(inst, pathIn("tags", draft), "input", "alpha", 2)
  val add: List[NodeRef] = newList()
  add.add(At(index = 0))
  add.add(Keyed(key = "entry"))
  add.add(Keyed(key = "add"))
  send(inst, pathIn("tags", add), "click", "", 0)
  check(
    c,
    waitFor(inst, two("Remove alpha", "[tags:tagsChanged=alpha]"), one("No tags yet"), 10000),
    "typed text and a click add a tag, in order"
  )

  // The flaky counter.
  send(inst, counterButton("inc"), "click", "", 0)
  check(c, waitFor(inst, one("Count 1"), nothing(), 10000), "the counter counts")

  send(inst, counterButton("fail"), "click", "", 0)
  check(
    c,
    waitFor(inst, two("is unavailable: failing on request", "Count 1"), nothing(), 10000),
    "a widget error shows a banner over the last view"
  )
  retry(inst, "counter")
  check(c, waitFor(inst, one("Count 1"), one("failing on request"), 10000), "Retry recovers")

  send(inst, counterButton("crash"), "click", "", 0)
  check(
    c,
    waitFor(inst, two("is unavailable: plugin crashed", "Count 1"), nothing(), 10000),
    "a crash shows a banner over the last view"
  )
  send(inst, counterButton("inc"), "click", "", 0)
  check(
    c,
    waitFor(inst, one("Count 2"), one("plugin crashed"), 15000),
    "the restarted plugin continues from the state the host kept"
  )

  send(inst, counterButton("hang"), "click", "", 0)
  check(
    c,
    waitFor(inst, two("is unavailable: timed out after 3000 ms", "Count 2"), nothing(), 10000),
    "a call past the timeout shows a banner"
  )
  sleepMillis(4500)
  retry(inst, "counter")
  check(c, waitFor(inst, one("Count 2"), one("timed out"), 10000), "Retry after the plugin answers recovers")

  send(inst, counterButton("huge"), "click", "", 0)
  check(
    c,
    waitFor(inst, two("cannot show: more than 2000 nodes", "Count 2"), nothing(), 10000),
    "an oversized view is refused"
  )
  retry(inst, "counter")
  check(c, waitFor(inst, one("Count 2"), one("cannot show"), 10000), "Retry recovers from a refused view")

  check(c, waitFor(inst, two("4 of 5", "Remove alpha"), nothing(), 1000), "the other widgets are unaffected")

  inst.close()
  stopAllPlugins(host)
  println("# " + c.failures.toString() + " failure(s)")
  c.failures
}
