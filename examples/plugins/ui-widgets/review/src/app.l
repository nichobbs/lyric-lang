//! Review.App — the review screen's composition below the host.
//!
//! Layer: app.  Loads the widget plugins from a directory and maps a URL to
//! the screen, for any lyric-ui host.
@runtime_checked
package Review.App

import Std.Core
import Std.Collections
import Std.Plugin
import Ui.Host.{Instance, instance}
import Ui.Session.{Program}
import Ui.Plugins.{widgetPluginPointInfo}
import Ui.PluginWidgets.Host.{WidgetRunner, newWidgetRunner}
import Review.Logic
import Review.Effects
import Review.View

/// A plugin host for widget plugins.  A widget call answers a click, so
/// calls time out after five seconds rather than the default minute; the
/// widgets request no capabilities, so the policy has nothing to grant.
pub func widgetHost(): PluginHost {
  val points: List[PluginPointInfo] = newList()
  points.add(widgetPluginPointInfo())
  newPluginHost(
    PluginHostConfig(points = points, providers = newList(), policy = GrantAllRequested(), callTimeoutMs = 5000)
  )
}

/// Load the plugins in `dir` into a new host; the load issues are logged.
pub func loadWidgets(dir: in String): WidgetRunner {
  val host = widgetHost()
  val dirs: List[String] = newList()
  dirs.add(dir)
  for issue in discoverPlugins(host, dirs) {
    println("Review: plugin not loaded: " + pluginLoadIssueMessage(issue))
  }
  newWidgetRunner(host)
}

/// The screen for `url`: the review page, or `None`.
pub func route(runner: in WidgetRunner, url: in String): Option[Instance] {
  if url != "/" and url != "/review" {
    return None
  }
  val p = Program(update = Logic.update, view = View.view, uiEffect = Logic.uiEffect)
  Some(value = instance(p, Logic.init("Espresso grinder"), { e: Logic.Effect -> Effects.run(e, runner) }))
}
