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
//!
//! Every operation on an instance (start, a host message with the effects
//! it leads to, detach, resume) holds the instance's lock for its whole
//! duration.  A host may run each connection on its own thread, and a
//! reconnecting browser can resume a session while the old connection is
//! still running one of its effects; the lock makes the resume wait for that
//! step to finish instead of racing it (D138, Q-UI-007).
@runtime_checked
package Ui.Host

import Std.Core
import Std.Collections
import Ui.Core.{View, Step, UiEffect, stay}
import Ui.Diff.{Patch}
import Ui.Protocol.{ClientMessage, Hello, EventMsg, Sync, ValueEcho, encodePatches, encodeNavigate, encodeBack, encodeToast}
import Ui.Session
import Ui.Session.{Program, Session, Output, HostCommand, NavigateTo, GoBack, ShowToast}
import Ui.Widgets.{column, heading, paragraph}

/// Where an instance's outgoing protocol messages go.
pub interface Outbox {
  func send(text: in String): Unit
}

// ─── Sessions ─────────────────────────────────────────────────────────────────
/// One live session: its instance, the connection it is attached to (empty
/// while disconnected) and when it was last attached or detached.
pub record SessionEntry {
  instance: Instance
  connectionId: String
  since: Long
}

/// The outcome of a reconnect attempt.
pub union Resumed {
  case ResumedSession(instance: Instance)
  case Unknown
}

/// A session detached from its connection by `release`.
pub record DetachedSession {
  sessionId: String
  instance: Instance
}

/// The live sessions of a host, by id, and which session each connection
/// carries (docs/65 §9.5, D138).  A host creates one and consults it for
/// every connection event; it holds no transport state of its own.  Every
/// member is an `entry`, readers included: a protected type's plain `func`
/// members take no lock, and connections run on their own threads.
pub protected type SessionRegistry {
  var byId: Map[String, SessionEntry] = newMap()
  var byConnection: Map[String, String] = newMap()
  /// Adds session `id`, attached to `connectionId`, when there is room for
  /// it under `max`: expired sessions are removed first, then the
  /// longest-disconnected ones are evicted.  False, adding nothing, when
  /// every session is connected and the limit is reached.  Making room and
  /// adding happen under one lock, so concurrent connections cannot together
  /// exceed `max`.
  entry admit(id: in String, inst: in Instance, connectionId: in String, now: in Long, graceMs: in Long, max: in Int): Bool {
    removeExpired(now, graceMs)
    while byId.count >= max {
      var oldest = ""
      var oldestSince = now
      for sid in mapKeys(byId) {
        match mapGet(byId, sid) {
          case Some(e) -> if e.connectionId.length == 0 and (oldest.length == 0 or e.since < oldestSince) {
            oldest = sid
            oldestSince = e.since
          }
          case None -> ()
        }
      }
      if oldest.length == 0 {
        return false
      }
      byId.remove(oldest)
    }
    byId.add(id, SessionEntry(instance = inst, connectionId = connectionId, since = now))
    bindConnection(connectionId, id)
    return true
  }
  /// Attaches session `id` to `connectionId` when it exists and has not
  /// expired.  A session still attached to another connection moves to the
  /// new one (the browser reconnected before the old socket closed).
  entry attach(id: in String, connectionId: in String, now: in Long, graceMs: in Long): Resumed {
    removeExpired(now, graceMs)
    return match mapGet(byId, id) {
      case Some(e) -> {
        if e.connectionId.length > 0 and byConnection.containsKey(e.connectionId) {
          byConnection.remove(e.connectionId)
        }
        byId.remove(id)
        byId.add(id, SessionEntry(instance = e.instance, connectionId = connectionId, since = now))
        bindConnection(connectionId, id)
        ResumedSession(instance = e.instance)
      }
      case None -> Unknown
    }
  }
  /// Marks the session carried by `connectionId` disconnected, if that
  /// connection is still the one it is attached to.  The caller then calls
  /// the instance's `detach`, guarded by `isDetached`.
  entry release(connectionId: in String, now: in Long): Option[DetachedSession] {
    val id = match mapGet(byConnection, connectionId) { case Some(x) -> x; case None -> return None }
    byConnection.remove(connectionId)
    return match mapGet(byId, id) {
      case Some(e) -> if e.connectionId == connectionId {
        byId.remove(id)
        byId.add(id, SessionEntry(instance = e.instance, connectionId = "", since = now))
        Some(value = DetachedSession(sessionId = id, instance = e.instance))
      } else {
        None
      }
      case None -> None
    }
  }
  /// True when session `id` exists and no connection carries it.
  entry isDetached(id: in String): Bool {
    return match mapGet(byId, id) { case Some(e) -> e.connectionId.length == 0; case None -> false }
  }
  /// The session id carried by `connectionId`.
  entry sessionOf(connectionId: in String): Option[String] {
    return mapGet(byConnection, connectionId)
  }
  /// The instance of session `id`.
  entry instanceOf(id: in String): Option[Instance] {
    return match mapGet(byId, id) { case Some(e) -> Some(value = e.instance); case None -> None }
  }
  /// The connection session `id` is attached to, if any.
  entry connectionOf(id: in String): Option[String] {
    return match mapGet(byId, id) {
      case Some(e) -> if e.connectionId.length > 0 then Some(value = e.connectionId) else None
      case None -> None
    }
  }
  /// The number of sessions held, connected or not.
  entry liveCount(): Int {
    return byId.count
  }
  // Records that `connectionId` carries session `id`.
  entry bindConnection(connectionId: in String, id: in String): Unit {
    if byConnection.containsKey(connectionId) {
      byConnection.remove(connectionId)
    }
    byConnection.add(connectionId, id)
  }
  // Removes disconnected sessions older than `graceMs`.
  entry removeExpired(now: in Long, graceMs: in Long): Unit {
    val expired: List[String] = newList()
    for id in mapKeys(byId) {
      match mapGet(byId, id) {
        case Some(e) -> if e.connectionId.length == 0 and now - e.since > graceMs { expired.add(id) }
        case None -> ()
      }
    }
    for id in expired {
      byId.remove(id)
    }
  }
}

// ─── Instances ────────────────────────────────────────────────────────────────
/// A running screen, with its types erased so a host can keep instances of
/// different screens side by side.
///
/// - `start` renders the initial tree and runs the initial effects.
/// - `receive` handles one host message.
/// - `detach(stillDetached)` drops the rendered tree while no host is
///   connected (the model is kept), provided `stillDetached()` holds once
///   the instance lock is held: a reconnect may have resumed the session
///   between the disconnect and the call.
/// - `resume` renders the whole tree again for a reconnected host.
pub record Instance {
  start: (Outbox) -> Unit
  receive: (ClientMessage, Outbox) -> Unit
  detach: (() -> Bool) -> Unit
  resume: (Outbox) -> Unit
}

/// Serialises the operations of one instance: each runs entirely inside
/// `run`'s entry lock.
pub protected type InstanceLock {
  entry run(f: in () -> Unit): Unit {
    f()
  }
}

// The generic `instance` is compiled into each package that calls it, which
// may link `Ui.Host` as a prebuilt assembly.  A protected type crosses that
// boundary as an opaque type (its entries are not callable there), so the
// generic body reaches the lock only through these two functions, which are
// compiled here.
/// A new lock for one instance.
pub func newInstanceLock(): InstanceLock {
  return InstanceLock()
}

/// Runs `f` holding `lock`.
pub func withLock(lock: in InstanceLock, f: in () -> Unit): Unit {
  lock.run(f)
}

/// An instance running program `p` from `init`, with `run` interpreting the
/// screen's own effects (UI effects never reach `run`).
///
/// `run` is synchronous from the host's point of view; an `async` effect
/// interpreter is called from it directly (a direct call to an `async func`
/// awaits in place).
pub func instance[M, Msg, E](p: in Program[M, Msg, E], init: in Step[M, E], run: in (E) -> Option[Msg]): Instance {
  // The session is owned by this instance and only touched while holding
  // `lock`, so a one-slot list is a sufficient cell.
  val cell: List[Session[M, Msg]] = newList()
  val lock = newInstanceLock()
  val start = { outbox: Outbox ->
    withLock(
      lock,
      { ->
        val o: Output[M, Msg, E] = Session.start(p, init)
        val s: Session[M, Msg] = o.session
        store(cell, s)
        drive(p, run, cell, o, outbox)
      }
    )
  }
  val receive = { m: ClientMessage, outbox: Outbox ->
    withLock(
      lock,
      { ->
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
              val noEchoes: List[ValueEcho] = newList()
              outbox.send(encodePatches(s.version, patches, noEchoes))
            }
            case Hello(_, _, _) -> ()
          }
        }
      }
    )
  }
  val detach: (() -> Bool) -> Unit = { stillDetached ->
    withLock(
      lock,
      { ->
        if cell.count > 0 and stillDetached() {
          val current: Session[M, Msg] = cell[0]
          val s: Session[M, Msg] = Session.detach(current)
          store(cell, s)
        }
      }
    )
  }
  val resume = { outbox: Outbox ->
    withLock(
      lock,
      { ->
        if cell.count > 0 {
          val current: Session[M, Msg] = cell[0]
          val o: Output[M, Msg, E] = Session.resume(p, current)
          val s: Session[M, Msg] = o.session
          store(cell, s)
          emit(o, outbox)
        }
      }
    )
  }
  return Instance(start = start, receive = receive, detach = detach, resume = resume)
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
    outbox.send(encodePatches(o.session.version, o.patches, o.echoes))
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
