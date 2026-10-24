//! build_tests.l — @test_module for Ui.Plugins.Build and the Ui.Plugins codecs.
//!
//! The builders produce the properties and handlers of their `Ui.Widgets`
//! counterparts, and the codecs `Lyric.PluginExpand` generates carry every
//! part of a widget call across the boundary as D207 Decision 4 specifies.
@test_module
package Ui.Plugins.Build.Tests

import Std.Core
import Std.Testing
import Std.Collections
import Std.JsonValue as Jv
import Std.JsonValue.{JsonValue, JsonField, JNull, JInt, JString, JObject}
import Ui.Plugins
import Ui.Plugins.Build as B
import Ui.Plugins.Build.{Choice}

func propValue(t: in WidgetTree, name: in String): String {
  match t {
    case TreeNode(_, _, props, _, _) -> {
      for p in props {
        if p.name == name {
          return p.value
        }
      }
      "<none>"
    }
    case _ -> "<not a node>"
  }
}

func handlerCount(t: in WidgetTree): Int {
  match t {
    case TreeNode(_, _, _, hs, _) -> hs.count
    case _ -> 0
  }
}

func firstHandler(t: in WidgetTree): NodeHandler {
  match t {
    case TreeNode(_, _, _, hs, _) -> hs[0]
    case _ -> NodeHandler(event = NodeEvent.Click, message = "<none>")
  }
}

func childCount(t: in WidgetTree): Int {
  match t {
    case TreeNode(_, _, _, _, cs) -> cs.count
    case _ -> 0
  }
}

func keyOf(t: in WidgetTree): String {
  match t {
    case TreeNode(_, k, _, _, _) -> k
    case _ -> ""
  }
}

func treeText(t: in WidgetTree): String {
  match t {
    case TreeNode(_, _, _, _, cs) -> {
      var s = ""
      for c in cs {
        s = s + treeText(c)
      }
      s
    }
    case TreeText(x) -> x
    case TreeEmpty -> ""
  }
}

func roundTripTree(t: in WidgetTree): Result[WidgetTree, String] {
  match Jv.parseValue(Jv.writeValue(pluginEncodeWidgetTree(t))) {
    case Ok(v) -> pluginDecodeWidgetTree(v)
    case Err(e) -> Err(error = e.message())
  }
}

func sampleTree(): WidgetTree {
  val stars: List[WidgetTree] = newList()
  stars.add(B.keyed("s1", B.button("1", "set:1")))
  stars.add(B.keyed("s2", B.buttonWith("2", "set:2", "primary", false)))
  val kids: List[WidgetTree] = newList()
  kids.add(B.heading(2, "Rate it"))
  kids.add(B.row(stars))
  kids.add(B.textInput("text", "draft", "edit", "Comment"))
  kids.add(B.nothing())
  B.card("Rating", kids)
}

// ─── Builders ─────────────────────────────────────────────────────────────────
test "button: label, variant and a click handler naming its message" {
  val b = B.button("Save", "save")
  assertEqual(propValue(b, "label"), "Save", "label")
  assertEqual(propValue(b, "variant"), "default", "variant")
  assertEqualInt(handlerCount(b), 1, "one handler")
  val h = firstHandler(b)
  assertTrue(h.event == NodeEvent.Click, "click")
  assertEqual(h.message, "save", "message")
}

test "a disabled button has no handler" {
  val b = B.buttonWith("Save", "save", "danger", true)
  assertEqual(propValue(b, "disabled"), "true", "disabled prop")
  assertEqualInt(handlerCount(b), 0, "no handler")
}

test "textInput: value, placeholder, type and an input handler" {
  val t = B.textInput("email", "a@b", "email", "you@example.com")
  assertEqual(propValue(t, "value"), "a@b", "value")
  assertEqual(propValue(t, "placeholder"), "you@example.com", "placeholder")
  assertEqual(propValue(t, "type"), "email", "type")
  val h = firstHandler(t)
  assertTrue(h.event == NodeEvent.Input, "input event")
  assertEqual(h.message, "email", "message")
}

test "checkbox and select answer change events" {
  val c = B.checkbox("Done", true, "done")
  assertEqual(propValue(c, "checked"), "true", "checked")
  assertTrue(firstHandler(c).event == NodeEvent.Change, "checkbox change")
  val choices: List[Choice] = newList()
  choices.add(Choice(value = "a", label = "Apple"))
  choices.add(Choice(value = "b", label = "Banana"))
  val s = B.select("b", choices, "fruit")
  assertEqual(propValue(s, "value"), "b", "selected value")
  assertEqualInt(childCount(s), 2, "two options")
  assertTrue(firstHandler(s).event == NodeEvent.Change, "select change")
}

test "field marks an input invalid and lists its errors" {
  val errs: List[String] = newList()
  errs.add("Required")
  val f = B.field("Name", errs, B.textInput("text", "", "name", ""))
  assertEqual(propValue(f, "invalid"), "true", "invalid")
  assertEqualInt(childCount(f), 2, "input and one error")
  assertEqual(treeText(f), "Required", "the error text")
}

test "table rows: a header row, and a click only with a message" {
  val cells: List[WidgetTree] = newList()
  cells.add(B.text("x"))
  val rows: List[WidgetTree] = newList()
  rows.add(B.keyed("r1", B.tableRow(cells, "open:1")))
  rows.add(B.keyed("r2", B.tableRow(cells, "")))
  val headers: List[String] = newList()
  headers.add("Name")
  val t = B.table(headers, rows)
  assertEqualInt(childCount(t), 3, "header and two rows")
  assertEqualInt(handlerCount(B.tableRow(cells, "open:1")), 1, "clickable row")
  assertEqualInt(handlerCount(B.tableRow(cells, "")), 0, "plain row")
}

test "keyed sets a node's key and leaves text alone" {
  assertEqual(keyOf(B.keyed("k", B.paragraph("p"))), "k", "node key")
  assertEqual(treeText(B.keyed("k", B.text("t"))), "t", "text unchanged")
}

// ─── Codecs ───────────────────────────────────────────────────────────────────
test "a view tree crosses the boundary unchanged" {
  val t = sampleTree()
  match roundTripTree(t) {
    case Ok(back) -> {
      assertEqual(Jv.writeValue(pluginEncodeWidgetTree(back)), Jv.writeValue(pluginEncodeWidgetTree(t)), "same JSON")
      assertEqual(treeText(back), treeText(t), "same text")
      assertEqual(propValue(back, "title"), "Rating", "card title")
    }
    case Err(e) -> assertTrue(false, "decode failed: " + e)
  }
}

test "the encoding: unions by case, enums by name" {
  val j = Jv.writeValue(pluginEncodeWidgetTree(B.button("Go", "go")))
  assertTrue(j.contains("\"case\":\"TreeNode\""), "union case: " + j)
  assertTrue(j.contains("\"kind\":\"Button\""), "enum by name: " + j)
  assertTrue(j.contains("\"event\":\"Click\""), "event by name: " + j)
  assertEqual(Jv.writeValue(pluginEncodeWidgetTree(B.nothing())), "{\"case\":\"TreeEmpty\"}", "empty")
}

test "an unknown node kind does not decode" {
  val bad = "{\"case\":\"TreeNode\",\"kind\":\"Raw\",\"key\":\"\",\"props\":[],\"handlers\":[],\"children\":[]}"
  match Jv.parseValue(bad) {
    case Ok(v) -> match pluginDecodeWidgetTree(v) {
      case Ok(_) -> assertTrue(false, "Raw is not a node kind")
      case Err(_) -> assertTrue(true, "rejected")
    }
    case Err(e) -> assertTrue(false, "test JSON: " + e.message())
  }
}

test "a step carries state, view and outcomes" {
  val fields: List[JsonField] = newList()
  fields.add(JsonField(name = "value", value = JInt(value = 3i64)))
  val outcomes: List[WidgetOutcome] = newList()
  outcomes.add(WidgetOutcome(name = "rated", payload = JInt(value = 3i64)))
  val step = WidgetStep(state = JObject(fields = fields), view = B.text("3"), outcomes = outcomes)
  match Jv.parseValue(Jv.writeValue(pluginEncodeWidgetStep(step))) {
    case Ok(v) -> match pluginDecodeWidgetStep(v) {
      case Ok(back) -> {
        assertEqual(Jv.writeValue(back.state), "{\"value\":3}", "state")
        assertEqualInt(back.outcomes.count, 1, "one outcome")
        assertEqual(back.outcomes[0].name, "rated", "outcome name")
      }
      case Err(e) -> assertTrue(false, "decode: " + e)
    }
    case Err(e) -> assertTrue(false, "parse: " + e.message())
  }
}

test "contributions decode from a manifest's JSON" {
  val json = "{\"widgets\":[{\"name\":\"rating\",\"title\":\"Rating\",\"description\":\"Stars\"," +
    "\"configSchema\":{\"type\":\"object\"},\"defaultConfig\":{\"max\":5}}]}"
  match Jv.parseValue(json) {
    case Ok(v) -> match pluginDecodeWidgetContributions(v) {
      case Ok(c) -> {
        assertEqualInt(c.widgets.count, 1, "one widget")
        assertEqual(c.widgets[0].name, "rating", "name")
        assertEqual(Jv.writeValue(c.widgets[0].defaultConfig), "{\"max\":5}", "default config")
      }
      case Err(e) -> assertTrue(false, "decode: " + e)
    }
    case Err(e) -> assertTrue(false, "parse: " + e.message())
  }
}

test "widget errors read as sentences" {
  assertEqual(widgetErrorMessage(UnknownWidget(widget = "x")), "the plugin has no widget named 'x'", "unknown")
  assertEqual(
    widgetErrorMessage(InvalidConfig(detail = "max must be positive")),
    "invalid configuration: max must be positive",
    "config"
  )
}
