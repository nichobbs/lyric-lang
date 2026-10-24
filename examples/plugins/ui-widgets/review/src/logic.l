//! Review.Logic — a product review screen whose rating and tag widgets come
//! from a plugin (docs/65 §6.5).
//!
//! Layer: logic.  The screen holds one `PluginWidget` per placement and
//! drives it the model-view-update way: an interaction is a `WidgetSignal`
//! message, the plugin call it needs is a `CallWidget` effect, and the
//! plugin's answer comes back as `Replied`.  What the widgets tell the
//! screen (their outcomes) updates the summary; the screen never sees how
//! the widgets work.
@runtime_checked
package Review.Logic

import Std.Core
import Std.Collections
import Std.JsonValue.{JsonValue, JsonField, JInt, JString, JArray, JObject, asInt, asString}
import Ui.Core.{Step, UiEffect, stepAll}
import Ui.PluginWidgets
import Ui.PluginWidgets.{PluginWidget, WidgetRef, WidgetSignal, WidgetRequest, WidgetReply, WidgetChange, signalInstance}

/// The plugin that provides the screen's widgets.
pub val widgetsPlugin: String = "example.ui-widgets"

pub record Model {
  product: String
  rating: PluginWidget
  tags: PluginWidget
  stars: Int
  maxStars: Int
  chosenTags: List[String]
}

pub union Msg {
  case FromWidget(signal: WidgetSignal)
  case Replied(reply: WidgetReply)
  case ToggleScale
}

pub union Effect {
  case CallWidget(request: WidgetRequest)
}

/// The UI runtime interprets none of this screen's effects.
pub func uiEffect(e: in Effect): Option[UiEffect[Msg]] {
  None
}

/// The rating widget's configuration for a scale of `max` stars.
pub func ratingConfig(max: in Int): JsonValue {
  val fs: List[JsonField] = newList()
  fs.add(JsonField(name = "max", value = JInt(value = max.toLong())))
  fs.add(JsonField(name = "label", value = JString(value = "Your rating")))
  JObject(fields = fs)
}

func tagsConfig(): JsonValue {
  val fs: List[JsonField] = newList()
  fs.add(JsonField(name = "maxTags", value = JInt(value = 5i64)))
  fs.add(JsonField(name = "placeholder", value = JString(value = "Add a tag")))
  JObject(fields = fs)
}

func calls(changes: in List[WidgetChange]): List[Effect] {
  val es: List[Effect] = newList()
  for c in changes {
    for r in c.requests {
      es.add(CallWidget(request = r))
    }
  }
  es
}

pub func init(product: in String): Step[Model, Effect] {
  val rating = PluginWidgets.placeWidget(
    "rating",
    WidgetRef(plugin = widgetsPlugin, widget = "rating"),
    ratingConfig(5)
  )
  val tags = PluginWidgets.placeWidget("tags", WidgetRef(plugin = widgetsPlugin, widget = "tags"), tagsConfig())
  val changes: List[WidgetChange] = newList()
  changes.add(rating)
  changes.add(tags)
  val m = Model(
    product = product,
    rating = rating.widget,
    tags = tags.widget,
    stars = 0,
    maxStars = 5,
    chosenTags = newList()
  )
  stepAll(m, calls(changes))
}

// The model after `change`, with what the widget told the screen applied.
func applyChange(m: in Model, change: in WidgetChange): Step[Model, Effect] {
  var next = m
  if change.widget.instance == "rating" {
    next = next.copy(rating = change.widget)
  } else {
    next = next.copy(tags = change.widget)
  }
  for o in change.outcomes {
    if o.name == "rated" {
      match asInt(o.payload) {
        case Some(n) -> {
          next = next.copy(stars = n.toInt())
        }
        case None -> ()
      }
    } else if o.name == "tagsChanged" {
      next = next.copy(chosenTags = tagList(o.payload))
    }
  }
  val changes: List[WidgetChange] = newList()
  changes.add(change)
  stepAll(next, calls(changes))
}

func tagList(j: in JsonValue): List[String] {
  val acc: List[String] = newList()
  match j {
    case JArray(items) -> {
      for it in items {
        match asString(it) {
          case Some(s) -> acc.add(s)
          case None -> ()
        }
      }
    }
    case _ -> ()
  }
  acc
}

func widgetNamed(m: in Model, instance: in String): PluginWidget {
  if instance == "rating" then m.rating else m.tags
}

pub func update(m: in Model, msg: in Msg): Step[Model, Effect] {
  match msg {
    case FromWidget(s) -> applyChange(m, PluginWidgets.signalWidget(widgetNamed(m, signalInstance(s)), s))
    case Replied(r) -> applyChange(m, PluginWidgets.replyWidget(widgetNamed(m, r.instance), r))
    case ToggleScale -> {
      val max = if m.maxStars == 5 then 10 else 5
      val next = m.copy(maxStars = max, stars = if m.stars > max then max else m.stars)
      applyChange(next, PluginWidgets.reconfigureWidget(next.rating, ratingConfig(max)))
    }
  }
}

/// One line saying what the widgets reported.
pub func summary(m: in Model): String {
  val rated = if m.stars == 0 then "Not rated yet" else "Rated " + m.stars.toString() + " of " + m.maxStars.toString()
  if m.chosenTags.count == 0 {
    return rated + "; no tags"
  }
  var tags = ""
  for t in m.chosenTags {
    tags = if tags == "" then t else tags + ", " + t
  }
  rated + "; tagged " + tags
}
