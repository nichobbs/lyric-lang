//! Review.Effects — runs the review screen's plugin calls.
//!
//! Layer: effects.  The only I/O the screen does: each `CallWidget` runs
//! against the plugin host and its reply comes back as a message.
@runtime_checked
package Review.Effects

import Std.Core
import Ui.PluginWidgets.Host.{WidgetRunner, runWidgetRequest}
import Review.Logic.{Effect, CallWidget, Msg, Replied}

pub func run(e: in Effect, runner: in WidgetRunner): Option[Msg] {
  match e {
    case CallWidget(r) -> Some(value = Replied(reply = runWidgetRequest(runner, r)))
  }
}
