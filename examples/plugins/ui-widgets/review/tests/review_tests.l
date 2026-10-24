//! review_tests.l — the review screen's logic and view, with the plugin's
//! answers written by hand: plugin calls are effects, so the screen is
//! tested without a plugin process.
@test_module
package Review.Tests

import Std.Core
import Std.Collections
import Std.Testing
import Std.JsonValue.{JsonValue, JsonField, JInt, JString, JArray, JObject, writeValue}
import Ui.Core.{View, Step}
import Ui.Testing.{hasText, click}
import Ui.Plugins.{WidgetStep, WidgetOutcome, WidgetTree, TreeNode, TreeText, NodeKind, NodeProp, NodeHandler}
import Ui.PluginWidgets.{WidgetRequest, WidgetReply, WidgetEvent, CallInit, CallConfigure}
import Review.Logic
import Review.Logic.{Model, Msg, Effect, CallWidget, FromWidget, Replied, ToggleScale, summary}
import Review.View

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

func requestOf(e: in Effect): WidgetRequest {
  match e {
    case CallWidget(r) -> r
  }
}

func requestFor(s: in Step[Model, Effect], instance: in String): WidgetRequest {
  for e in s.effects {
    val r = requestOf(e)
    if r.instance == instance {
      return r
    }
  }
  assertTrue(false, "no request for " + instance)
  requestOf(s.effects[0])
}

func answer(r: in WidgetRequest, view: in WidgetTree, outcomes: in List[WidgetOutcome]): Msg {
  Replied(
    reply = WidgetReply(
      instance = r.instance,
      seq = r.seq,
      answer = Ok(value = WidgetStep(state = JInt(value = 0i64), view = view, outcomes = outcomes))
    )
  )
}

func outcome(name: in String, payload: in JsonValue): List[WidgetOutcome] {
  val os: List[WidgetOutcome] = newList()
  os.add(WidgetOutcome(name = name, payload = payload))
  os
}

// The screen after both widgets answered their `init`.
func loaded(): Model {
  val s0 = Logic.init("Grinder")
  val s1 = Logic.update(s0.model, answer(requestFor(s0, "rating"), treeParagraph("stars here"), newList()))
  Logic.update(s1.model, answer(requestFor(s0, "tags"), treeParagraph("tags here"), newList())).model
}

test "the screen starts both widgets" {
  val s = Logic.init("Grinder")
  assertEqualInt(s.effects.count, 2, "two init calls")
  match requestFor(s, "rating").call {
    case CallInit(req) -> assertEqual(writeValue(req.config), "{\"max\":5,\"label\":\"Your rating\"}", "rating config")
    case _ -> assertTrue(false, "an init call")
  }
}

test "the plugins' views are shown, and their outcomes reach the summary" {
  val m = loaded()
  val v = View.view(m)
  assertTrue(hasText(v, "stars here"), "rating view")
  assertTrue(hasText(v, "tags here"), "tags view")
  assertEqual(summary(m), "Not rated yet; no tags", "initial summary")
  val r = Logic.update(m, ToggleScale)
  val back = Logic.update(
    r.model,
    answer(requestFor(r, "rating"), treeParagraph("ten stars"), outcome("rated", JInt(value = 7i64)))
  )
  assertEqual(summary(back.model), "Rated 7 of 10; no tags", "rated on the new scale")
  val tags: List[JsonValue] = newList()
  tags.add(JString(value = "quiet"))
  tags.add(JString(value = "fast"))
  val withTags = Logic.update(
    back.model,
    FromWidget(signal = WidgetEvent(instance = "tags", message = "add", data = "", coalesce = false))
  )
  val tagged = Logic.update(
    withTags.model,
    answer(
      requestFor(withTags, "tags"),
      treeParagraph("2 tags"),
      outcome("tagsChanged", JArray(items = tags))
    )
  )
  assertEqual(summary(tagged.model), "Rated 7 of 10; tagged quiet, fast", "tags in the summary")
}

test "changing the scale reconfigures the rating widget" {
  val r = Logic.update(loaded(), ToggleScale)
  match requestFor(r, "rating").call {
    case CallConfigure(req) -> assertEqual(
      writeValue(req.config),
      "{\"max\":10,\"label\":\"Your rating\"}",
      "ten stars"
    )
    case _ -> assertTrue(false, "a configure call")
  }
  assertTrue(hasText(View.view(r.model), "Use a 5-star scale"), "the button flips")
}

test "a failed widget shows an error and a retry, and the rest of the screen stays" {
  val s0 = Logic.init("Grinder")
  val r = requestFor(s0, "rating")
  val failed = Logic.update(
    s0.model,
    Replied(
      reply = WidgetReply(
        instance = r.instance,
        seq = r.seq,
        answer = Err(error = "plugin crashed: exit 3")
      )
    )
  )
  val v = View.view(failed.model)
  assertTrue(hasText(v, "is unavailable: plugin crashed: exit 3"), "banner")
  assertTrue(hasText(v, "Review: Grinder"), "the screen is still there")
  match click(v, "Retry") {
    case Some(msg) -> {
      val again = Logic.update(failed.model, msg)
      match requestFor(again, "rating").call {
        case CallInit(_) -> assertTrue(true, "retried")
        case _ -> assertTrue(false, "an init call")
      }
    }
    case None -> assertTrue(false, "a Retry button")
  }
}
