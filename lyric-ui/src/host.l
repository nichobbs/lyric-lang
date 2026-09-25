//! Ui.Host — the target-independent session driver shared by every host
//! (docs/65-ui-library-sketch.md §8, §10).
//! Stability: @experimental — Phase U2 of docs/65.
//!
//! A host (server-driven web, desktop webview) owns a transport; this
//! package owns what happens on it.  `instance` erases a screen's types
//! behind an `Instance`, whose `start`/`receive` apply the pure
//! `Ui.Session` steps, send the resulting patches and host commands through
//! an `Outbox`, and then run the step's effects.
//!
//! Ordering: an instance processes one host message at a time and sends the
//! patches of each step *before* running that step's effects, so a busy
//! state ("Saving...") is visible while the effect runs.  Effects of a step
//! run one after another on the calling thread, each result dispatched as
//! it arrives (docs/65 §15, finding F-15: concurrent effects are future work).
@runtime_checked
package Ui.Host

import Std.Core
import Ui.Core.{View, Step, UiEffect, stay}
import Ui.Diff.{Patch}
import Ui.Protocol.{ClientMessage, Hello, EventMsg, Sync, encodePatches, encodeNavigate, encodeBack, encodeToast}
import Ui.Session
import Ui.Session.{Program, Session, Output, HostCommand, NavigateTo, GoBack, ShowToast}
import Ui.Widgets.{column, heading, paragraph}

/// Where an instance's outgoing protocol messages go.
pub interface Outbox {
  func send(text: in String): Unit
}

/// A running screen, with its types erased so a host can keep instances of
/// different screens side by side.
pub record Instance {
  start: (Outbox) -> Unit
  receive: (ClientMessage, Outbox) -> Unit
}

/// An instance running program `p` from `init`, with `run` interpreting the
/// screen's own effects (UI effects never reach `run`).
///
/// `run` is synchronous from the host's point of view; an `async` effect
/// interpreter is called from it directly (a direct call to an `async func`
/// awaits in place).
pub func instance[M, Msg, E](p: in Program[M, Msg, E], init: in Step[M, E], run: in (E) -> Option[Msg]): Instance {
  // The session is owned by this instance and touched only by the host
  // message it is processing, so a one-slot list is a sufficient cell.
  val cell: List[Session[M, Msg]] = newList()
  val start = { outbox: Outbox ->
    val o: Output[M, Msg, E] = Session.start(p, init)
    val s: Session[M, Msg] = o.session
    store(cell, s)
    drive(p, run, cell, o, outbox)
  }
  val receive = { m: ClientMessage, outbox: Outbox ->
    if cell.count > 0 {
      match m {
        case EventMsg(ev) -> {
          val current: Session[M, Msg] = cell[0]
          val o: Output[M, Msg, E] = Session.handleEvent(p, current, ev)
          if not o.dropped {
            val s: Session[M, Msg] = o.session
            store(cell, s)
            drive(p, run, cell, o, outbox)
          }
        }
        case Sync -> {
          val s: Session[M, Msg] = cell[0]
          val patches: List[Patch] = Session.resync(s)
          outbox.send(encodePatches(s.version, patches, s.inputVersions))
        }
        case Hello(_, _) -> ()
      }
    }
  }
  return Instance(start = start, receive = receive)
}

pub func store[M, Msg](cell: in List[Session[M, Msg]], s: in Session[M, Msg]): Unit {
  if cell.count > 0 {
    cell.removeAt(0)
  }
  cell.add(s)
}

// Sends `first`, then runs its effects (and those of the steps they lead to)
// in order.
pub func drive[M, Msg, E](
  p: in Program[M, Msg, E],
  run: in (E) -> Option[Msg],
  cell: in List[Session[M, Msg]],
  first: in Output[M, Msg, E],
  outbox: in Outbox,
): Unit {
  emit(first, outbox)
  val queue: List[E] = newList()
  val firstEffects: List[E] = first.effects
  for e in firstEffects {
    queue.add(e)
  }
  var i = 0
  while i < queue.count {
    val effect: E = queue[i]
    val reply: Option[Msg] = run(effect)
    match reply {
      case Some(msg) -> {
        val m: Msg = msg
        val current: Session[M, Msg] = cell[0]
        val o: Output[M, Msg, E] = Session.dispatch(p, current, m)
        val s: Session[M, Msg] = o.session
        store(cell, s)
        emit(o, outbox)
        val more: List[E] = o.effects
        for e in more {
          queue.add(e)
        }
      }
      case None -> ()
    }
    i = i + 1
  }
}

pub func emit[M, Msg, E](o: in Output[M, Msg, E], outbox: in Outbox): Unit {
  if o.patches.count > 0 {
    outbox.send(encodePatches(o.session.version, o.patches, o.session.inputVersions))
  }
  for c in o.commands {
    match c {
      case NavigateTo(url) -> outbox.send(encodeNavigate(url))
      case GoBack -> outbox.send(encodeBack())
      case ShowToast(m, level) -> outbox.send(encodeToast(m, level))
    }
  }
}

// ─── Built-in pages ───────────────────────────────────────────────────────────
union NoMsg {
  case Never
}

union NoEffect {
  case NoEffectValue
}

/// A static page showing `title` and `message` (used for unknown routes and
/// protocol mismatches).
pub func staticPage(title: in String, message: in String): Instance {
  val p: Program[String, NoMsg, NoEffect] = Program(
    update = { m: String, _: NoMsg -> stay[String, NoEffect](m) },
    view = { m: String -> pageView(title, m) },
    uiEffect = { _: NoEffect -> None }
  )
  return instance(p, stay[String, NoEffect](message), { _: NoEffect -> None })
}

func pageView(title: in String, message: in String): View[NoMsg] {
  val cs: List[View[NoMsg]] = newList()
  val h: View[NoMsg] = heading[NoMsg](1, title)
  val p: View[NoMsg] = paragraph[NoMsg](message)
  cs.add(h)
  cs.add(p)
  return column(cs)
}
