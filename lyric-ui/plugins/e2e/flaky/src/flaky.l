//! UiPluginE2e.Flaky — a widget plugin that misbehaves on request, for the
//! end-to-end test of plugin widgets (`../host`, scripts/ci/ui-widget-plugins-e2e.sh).
//!
//! Its one widget, `counter`, counts clicks of `inc` and, for the other
//! buttons, fails the way a broken plugin does:
//!
//!   - `fail` answers with its own `WidgetError`;
//!   - `crash` exits the process (a panic on native, which has no unwinding);
//!   - `hang` sleeps for `hangMillis` before answering, past the host's call
//!     timeout;
//!   - `huge` answers with a view larger than a host shows.
package UiPluginE2e.Flaky

import Std.Core
import Std.Collections
import Std.Environment
import Std.Time.{sleepMillis}
import Std.JsonValue
import Ui.Plugins
import Ui.Plugins.Build as B

/// How long `hang` sleeps.
val hangMillis: Int = 6000

@plugin(id = "test.flaky-widgets", version = "1.0.0", publisher = "lyric-tests", implements(WidgetPlugin))
pub record FlakyWidgets {
}

@cfg(target = "dotnet")
func crashNow(): Unit {
  exitCode(3)
}

@cfg(target = "jvm")
func crashNow(): Unit {
  exitCode(3)
}

@cfg(target = "native")
func crashNow(): Unit {
  panic("flaky widget: crashing on request")
}

func countOf(state: in JsonValue): Int {
  match getInt(state, "count") {
    case Some(n) -> n.toInt()
    case None -> 0
  }
}

func stateOf(count: in Int): JsonValue {
  val fs: List[JsonField] = newList()
  fs.add(JsonField(name = "count", value = JInt(value = count.toLong())))
  JObject(fields = fs)
}

func counterView(count: in Int): WidgetTree {
  val kids: List[WidgetTree] = newList()
  kids.add(B.keyed("count", B.paragraph("Count " + count.toString())))
  for m in ["inc", "fail", "crash", "hang", "huge"] {
    kids.add(B.keyed(m, B.button(m, m)))
  }
  B.column(kids)
}

func hugeView(): WidgetTree {
  val kids: List[WidgetTree] = newList()
  var i = 0
  while i < 2100 {
    kids.add(B.text("x"))
    i = i + 1
  }
  B.column(kids)
}

func stepOf(count: in Int): WidgetStep {
  val outcomes: List[WidgetOutcome] = newList()
  outcomes.add(WidgetOutcome(name = "count", payload = JInt(value = count.toLong())))
  WidgetStep(state = stateOf(count), view = counterView(count), outcomes = outcomes)
}

func checked(widget: in String): Result[Unit, WidgetError] {
  if widget == "counter" {
    return Ok(value = ())
  }
  Err(error = UnknownWidget(widget = widget))
}

impl WidgetPlugin for FlakyWidgets {
  func init(req: in WidgetInit): Result[WidgetStep, WidgetError] {
    match checked(req.widget) {
      case Ok(_) -> Ok(value = stepOf(0))
      case Err(e) -> Err(error = e)
    }
  }

  func update(req: in WidgetUpdate): Result[WidgetStep, WidgetError] {
    match checked(req.widget) {
      case Err(e) -> return Err(error = e)
      case Ok(_) -> ()
    }
    val count = countOf(req.state)
    val m = req.message.message
    if m == "inc" {
      return Ok(value = stepOf(count + 1))
    }
    if m == "fail" {
      return Err(error = WidgetFailed(detail = "failing on request"))
    }
    if m == "crash" {
      crashNow()
    }
    if m == "hang" {
      sleepMillis(hangMillis)
      return Ok(value = stepOf(count))
    }
    if m == "huge" {
      return Ok(value = WidgetStep(state = stateOf(count), view = hugeView(), outcomes = newList()))
    }
    Err(error = WidgetFailed(detail = "unknown message '" + m + "'"))
  }

  func configure(req: in WidgetConfigure): Result[WidgetStep, WidgetError] {
    match checked(req.widget) {
      case Ok(_) -> Ok(value = stepOf(countOf(req.state)))
      case Err(e) -> Err(error = e)
    }
  }
}

@plugin_contributions(WidgetPlugin)
func contributions(): WidgetContributions {
  val ws: List[WidgetDecl] = newList()
  ws.add(
    WidgetDecl(
      name = "counter",
      title = "Counter",
      description = "Counts clicks; fails, crashes, hangs or answers too much on request.",
      configSchema = JNull,
      defaultConfig = JNull
    )
  )
  WidgetContributions(widgets = ws)
}
