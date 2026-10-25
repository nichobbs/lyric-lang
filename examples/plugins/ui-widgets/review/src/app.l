//! Review.App — the review screen's composition below the host.
//!
//! Layer: app.  Loads the widget plugins from a directory and maps a URL to
//! the screen, for any lyric-ui host.
@runtime_checked
package Review.App

import Std.Core
import Std.Collections
import Std.Plugin
import Std.PluginSign
import Ui.Host.{Instance, instance}
import Ui.Session.{Program}
import Ui.Plugins.{widgetPluginPointInfo}
import Ui.PluginWidgets.Host.{WidgetRunner, newWidgetRunner}
import Review.Logic
import Review.Effects
import Review.View

/// The key the example plugins are signed with
/// (examples/plugins/keys/example-publisher.pub).  An application ships the
/// public keys of the publishers it trusts the same way, and loads only
/// plugins they signed (D248).
pub func exampleTrust(): TrustPolicy {
  val key = match parsePublicKey("lyric-ed25519:hcEkg2A6Xnfv9mQVZmFxq2BPNyq0TfUzkWSeGp5JlaI=") {
    case Ok(k) -> k
    case Err(e) -> panic("example publisher key: " + e)
  }
  val keys: List[TrustedKey] = newList()
  keys.add(TrustedKey(publisher = "lyric-examples", publicKey = key))
  trustKeys(keys)
}

/// A plugin host for widget plugins.  A widget call answers a click, so
/// calls time out after five seconds rather than the default minute; the
/// widgets request no capabilities, so the policy has nothing to grant.
pub func widgetHost(): PluginHost {
  val points: List[PluginPointInfo] = newList()
  points.add(widgetPluginPointInfo())
  newPluginHost(
    PluginHostConfig(
      points = points,
      providers = newList(),
      policy = GrantAllRequested(),
      trust = Some(value = exampleTrust()),
      callTimeoutMs = 5000
    )
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
