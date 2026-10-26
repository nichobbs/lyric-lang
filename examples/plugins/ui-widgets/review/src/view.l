//! Review.View — the review screen.
//!
//! Layer: view.  The plugin widgets are placed with `widgetView`, which
//! renders each plugin's view with the host's own widgets (or a loading
//! indicator, or an error banner with a Retry button).
@runtime_checked
package Review.View

import Std.Core
import Std.Collections
import Ui.Core.{View}
import Ui.Widgets.{column, card, heading, paragraph, button, keyed}
import Ui.PluginWidgets.{WidgetSignal, widgetView}
import Review.Logic.{Model, Msg, FromWidget, ToggleScale, summary}

pub func view(m: in Model): View[Msg] {
  val toMsg: (WidgetSignal) -> Msg = { s: WidgetSignal -> FromWidget(signal = s) }
  val kids: List[View[Msg]] = newList()
  val title: View[Msg] = heading(1, "Review: " + m.product)
  kids.add(title)
  val rating: View[Msg] = widgetView(m.rating, toMsg)
  kids.add(rating)
  val scaleLabel = if m.maxStars == 5 then "Use a 10-star scale" else "Use a 5-star scale"
  kids.add(keyed("scale", button(scaleLabel, ToggleScale)))
  val tagKids: List[View[Msg]] = newList()
  val tags: View[Msg] = widgetView(m.tags, toMsg)
  tagKids.add(tags)
  val tagCard: View[Msg] = card("Tags", tagKids)
  kids.add(tagCard)
  kids.add(keyed("summary", paragraph(summary(m))))
  column(kids)
}
