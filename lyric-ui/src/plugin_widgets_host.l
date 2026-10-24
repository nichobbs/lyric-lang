//! Ui.PluginWidgets.Host — running widget plugin calls (docs/65 §6.5,
//! docs/69 §16 P6).
//! Stability: @experimental.
//!
//! The I/O half of `Ui.PluginWidgets`: an application's effect interpreter
//! runs each `WidgetRequest` with `runWidgetRequest` and returns the
//! `WidgetReply` as a message.  It also reads the widgets each loaded plugin
//! offers from the manifests, without starting anything (`widgetCatalog`).
//!
//! The plugins are `Std.Plugin` plugins of point `Ui.Plugins.WidgetPlugin`:
//! the application creates the `PluginHost` (with `widgetPluginPointInfo()`
//! among its points), discovers plugins, and wraps the host in a
//! `WidgetRunner`.  A host serves calls to one plugin one at a time, and the
//! UI hosts run effects concurrently, so the runner holds a lock per plugin
//! around each call; calls to different plugins still run in parallel.  The
//! host's `callTimeoutMs` bounds each call, so an application showing widgets
//! should set it well below the 60-second default.
//!
//! A failed call becomes a reply carrying the reason, which
//! `Ui.PluginWidgets.replyWidget` shows as the placement's error banner:
//! the plugin's own `WidgetError`, a boundary error (`Timeout`, `Crashed`,
//! ...), a plugin that is not loaded, or a widget it does not declare.
@runtime_checked
@io
package Ui.PluginWidgets.Host

import Std.Core
import Std.Collections
import Std.Plugin
import Ui.Plugins
import Ui.PluginWidgets.{WidgetRef, WidgetRequest, WidgetReply, WidgetCall, CallInit, CallUpdate, CallConfigure}

/// A widget a loaded plugin declares.
pub record WidgetEntry {
  plugin: String
  decl: WidgetDecl
}

/// Every widget the loaded plugins declare, in load order, read from their
/// manifests.  A plugin whose contributions do not decode is left out;
/// `widgetCatalogIssues` reports it.
pub func widgetCatalog(host: in PluginHost): List[WidgetEntry] {
  val acc: List[WidgetEntry] = newList()
  for c in widgetPluginContributions(host) {
    for d in c.value.widgets {
      acc.add(WidgetEntry(plugin = c.pluginId, decl = d))
    }
  }
  acc
}

/// K0101 for each loaded plugin whose contributions do not decode as
/// `WidgetContributions`.
pub func widgetCatalogIssues(host: in PluginHost): List[PluginLoadIssue] {
  widgetPluginContributionIssues(host)
}

/// The declaration of the widget `source` names, if a loaded plugin
/// declares it.
pub func findWidget(host: in PluginHost, source: in WidgetRef): Option[WidgetEntry] {
  for e in widgetCatalog(host) {
    if e.plugin == source.plugin and e.decl.name == source.widget {
      return Some(value = e)
    }
  }
  None
}

// ─── Running calls ────────────────────────────────────────────────────────────
/// Serialises the calls to one plugin.
pub protected type PluginCallLock {
  entry run(f: in () -> Unit): Unit {
    f()
  }
}

/// One `PluginCallLock` per plugin id, created on first use.
pub protected type PluginCallLocks {
  var locks: Map[String, PluginCallLock] = newMap()
  entry lockFor(pluginId: in String): PluginCallLock {
    match mapGet(locks, pluginId) {
      case Some(l) -> l
      case None -> {
        val l = PluginCallLock()
        locks.add(pluginId, l)
        l
      }
    }
  }
}

/// Runs widget calls against a plugin host.  Create one per host and share
/// it between every screen that shows plugin widgets.
pub record WidgetRunner {
  host: PluginHost
  locks: PluginCallLocks
}

/// A runner for `host`.
pub func newWidgetRunner(host: in PluginHost): WidgetRunner {
  WidgetRunner(host = host, locks = PluginCallLocks())
}

/// The sentence for a failed widget call.
pub func widgetCallErrorMessage(e: in CallError[WidgetError]): String {
  match e {
    case App(w) -> widgetErrorMessage(w)
    case Boundary(b) -> boundaryErrorMessage(b)
  }
}

func remoteFor(host: in PluginHost, pluginId: in String): Option[WidgetPluginRemote] {
  for r in widgetPluginRemotes(host) {
    if r.conn.pluginId == pluginId {
      return Some(value = r)
    }
  }
  None
}

func invoke(remote: in WidgetPluginRemote, call: in WidgetCall): Result[WidgetStep, String] {
  val answer: Result[WidgetStep, CallError[WidgetError]] = match call {
    case CallInit(req) -> remote.init(req)
    case CallUpdate(req) -> remote.update(req)
    case CallConfigure(req) -> remote.configure(req)
  }
  match answer {
    case Ok(step) -> Ok(value = step)
    case Err(e) -> Err(error = widgetCallErrorMessage(e))
  }
}

/// Run `req` against the plugin it names and return the reply for
/// `Ui.PluginWidgets.replyWidget`.  The plugin is started on its first call
/// and restarted after a crash as `Std.Plugin` does for every plugin; the
/// placement's state is in the request, so a restarted plugin continues
/// from it.
pub func runWidgetRequest(runner: in WidgetRunner, req: in WidgetRequest): WidgetReply {
  val failed = { reason: String -> WidgetReply(instance = req.instance, seq = req.seq, answer = Err(error = reason)) }
  val remote = match remoteFor(runner.host, req.source.plugin) {
    case Some(r) -> r
    case None -> return failed("no widget plugin '" + req.source.plugin + "' is loaded")
  }
  match findWidget(runner.host, req.source) {
    case Some(_) -> ()
    case None -> return failed("plugin '" + req.source.plugin + "' declares no widget '" + req.source.widget + "'")
  }
  val results: List[Result[WidgetStep, String]] = newList()
  val lock = runner.locks.lockFor(req.source.plugin)
  lock.run({ -> results.add(invoke(remote, req.call)) })
  WidgetReply(instance = req.instance, seq = req.seq, answer = results[0])
}
