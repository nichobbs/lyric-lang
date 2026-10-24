//! The plugin of the trusted-mode fixture (docs/69 §10): an ordinary
//! `@plugin` record.  Nothing in it knows whether a host runs it in a
//! process, in wasm or in the host's own process; `Lyric.PluginExpand`
//! generates its server, its `main` and its trusted entry points.
package PluginTrusted.Notes

import Std.Core
import Std.Collections
import Std.Environment as Env
import Std.Plugin
import PluginTrusted.Api

@plugin(id = "lyric.test.trusted-notes", version = "1.0.0", publisher = "lyric", implements(NoteTool))
pub ref record NotesPlugin {
  store: StoreClient
  log: Option[LogClient]
  var calls: Int = 0
}

impl NoteTool for NotesPlugin {
  func summarize(note: in Note): Result[String, Level] {
    if note.title == "" {
      return Err(error = Level.High)
    }
    Ok(value = note.title + ":" + note.body.count.toString() + ":" + note.tags.count.toString())
  }

  func fetch(title: in String): Result[Change, String] {
    match store.load(title) {
      case Ok(n) -> Ok(value = Change.Added(note = n))
      case Err(CallError.App(e)) -> Err(error = "app: " + e)
      case Err(CallError.Boundary(b)) -> Err(error = "boundary: " + boundaryErrorMessage(b))
    }
  }

  func logged(line: in String): Result[Bool, String] {
    match log {
      case None -> Ok(value = false)
      case Some(l) -> match l.log(Level.Low, line) {
        case Ok(_) -> Ok(value = true)
        case Err(CallError.App(e)) -> Err(error = "app: " + e)
        case Err(CallError.Boundary(b)) -> Err(error = "boundary: " + boundaryErrorMessage(b))
      }
    }
  }

  // The environment of the process the plugin runs in: a host proves it
  // runs a trusted plugin in its own process by changing a variable after
  // the plugin started.
  func readEnv(name: in String): Result[String, String] {
    Ok(value = Env.getVarOrDefault(name, ""))
  }

  func count(): Result[Int, String] {
    self.calls = self.calls + 1
    Ok(value = self.calls)
  }
}

@plugin_contributions(NoteTool)
func notesContributions(): NotesContributions {
  val cmds: List[String] = newList()
  cmds.add("notes.summarize")
  cmds.add("notes.fetch")
  NotesContributions(commands = cmds)
}

@plugin_request(Store)
func storeRequest(): StoreGrant {
  val prefixes: List[String] = newList()
  prefixes.add("notes/")
  prefixes.add("shared/")
  StoreGrant(prefixes = prefixes)
}
