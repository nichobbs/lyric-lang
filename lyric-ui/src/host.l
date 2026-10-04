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
//! patches of each step *before* its effects run, so a busy state
//! ("Saving...") is visible while they run.  The effects of a step run
//! concurrently, each on the instance's task scope (`Std.Task`), outside the
//! instance lock; their results are applied one at a time, in the order they
//! complete, each as a step of its own whose effects are started the same way
//! (docs/65 §15, F-15; #7835).  A slow effect therefore holds up neither the
//! other effects nor the session's input.
//!
//! Every step (start, a host message, an effect result, detach, resume)
//! holds the instance's lock while it updates the session and sends its
//! output.  A host may run each connection on its own thread, and a
//! reconnecting browser can resume a session while an effect is still
//! running; the lock orders the resume and the effect's result instead of
//! racing them (D138, Q-UI-007).  A result arriving while the session is
//! detached updates the model only (a detached session keeps no tree).
//! `close` (called when the session is evicted or expires) cancels the
//! scope, and any effect result that arrives afterwards is dropped.
@runtime_checked
@io
package Ui.Host

import Std.Core
import Std.Collections
import Std.Task as Tasks
import Ui.Kernel.Guard as Guard
import Ui.Core.{View, Step, UiEffect, stay}
import Ui.Diff.{Patch, toWire}
import Ui.Html.{renderHtml}
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
/// while disconnected), when it was last attached or detached, and whether
/// a connection has ever claimed it (false for a prerendered page whose
/// browser has not connected yet, D152).
pub record SessionEntry {
  instance: Instance
  connectionId: String
  since: Long
  claimed: Bool = true
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
  /// longest-disconnected ones are evicted, never-claimed prerendered
  /// sessions before any that a browser was using, so page loads that never
  /// connect cannot push out a session waiting for its user to reconnect.  False, adding nothing, when
  /// every session is connected and the limit is reached.  Making room and
  /// adding happen under one lock, so concurrent connections cannot together
  /// exceed `max`.
  entry admit(id: in String, inst: in Instance, connectionId: in String, now: in Long, graceMs: in Long, max: in Int): Bool {
    removeExpired(now, graceMs)
    while byId.count >= max {
      var oldest = ""
      var oldestSince = now
      var oldestClaimed = true
      for sid in mapKeys(byId) {
        match mapGet(byId, sid) {
          case Some(e) -> if e.connectionId.length == 0 {
            // An unclaimed session beats a claimed one; within a class,
            // the longest disconnected goes first.
            val better = oldest.length == 0 or (oldestClaimed and not e.claimed) or
              (oldestClaimed == e.claimed and e.since < oldestSince)
            if better {
              oldest = sid
              oldestSince = e.since
              oldestClaimed = e.claimed
            }
          }
          case None -> ()
        }
      }
      if oldest.length == 0 {
        return false
      }
      match mapGet(byId, oldest) {
        case Some(e) -> e.instance.close()
        case None -> ()
      }
      byId.remove(oldest)
    }
    byId.add(
      id,
      SessionEntry(instance = inst, connectionId = connectionId, since = now, claimed = connectionId.length > 0)
    )
    // An empty connection id admits the session disconnected: a page
    // prerendered before its socket connects (D152).  It expires like any
    // disconnected session unless a connection attaches within `graceMs`.
    if connectionId.length > 0 {
      bindConnection(connectionId, id)
    }
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
      match mapGet(byId, id) {
        case Some(e) -> e.instance.close()
        case None -> ()
      }
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
/// - `snapshot` is the current tree as HTML (`Ui.Html`), or empty before
///   `start`.  Take it before `detach`, which drops the tree.
/// - `close` stops the instance for good: effects still running are
///   cancelled (cooperatively) and their results dropped.  It never waits
///   for a running step, so it is safe to call while holding another lock.
pub record Instance {
  start: (Outbox) -> Unit
  receive: (ClientMessage, Outbox) -> Unit
  detach: (() -> Bool) -> Unit
  resume: (Outbox) -> Unit
  snapshot: () -> String
  close: () -> Unit
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
  // `lock`, so a one-slot list is a sufficient cell; so is `detached`.
  val cell: List[Session[M, Msg]] = newList()
  val detached: List[Bool] = newList()
  detached.add(false)
  val lock = newInstanceLock()
  // Effects run on this scope; cancelling it is how `close` marks the
  // instance closed, readable from any thread without taking `lock`.
  val tasks = Tasks.makeScope()
  val env = EffectEnv(lock = lock, tasks = tasks, detached = detached)
  val start = { outbox: Outbox ->
    withLock(
      lock,
      { ->
        val o: Output[M, Msg, E] = Session.start(p, init)
        val s: Session[M, Msg] = o.session
        store(cell, s)
        emit(o, outbox)
        startEffects(p, run, cell, env, o.effects, outbox)
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
                emit(o, outbox)
                startEffects(p, run, cell, env, o.effects, outbox)
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
          detached[0] = true
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
          detached[0] = false
          emit(o, outbox)
        }
      }
    )
  }
  val snapshot = { ->
    val html: List[String] = newList()
    withLock(
      lock,
      { -> if cell.count > 0 { val current: Session[M, Msg] = cell[0]; html.add(renderHtml(toWire(current.tree))) } }
    )
    if html.count > 0 {
      html[0]
    } else {
      ""
    }
  }
  val close = { -> Tasks.cancelScope(tasks) }
  return Instance(
    start = start,
    receive = receive,
    detach = detach,
    resume = resume,
    snapshot = snapshot,
    close = close
  )
}

/// What an instance's effect tasks share: its lock, its task scope, and
/// whether its session is detached (read and written under `lock`).
pub record EffectEnv {
  lock: InstanceLock
  tasks: Tasks.Scope
  detached: List[Bool]
}

pub func store[M, Msg](cell: in List[Session[M, Msg]], s: in Session[M, Msg]): Unit {
  if cell.count > 0 {
    cell.removeAt(0)
  }
  cell.add(s)
}

/// Starts each of `effects` on the instance's scope.  Each runs outside the
/// instance lock; its result, if any, is applied as a step of its own
/// (`applyResult`), in completion order.
pub func startEffects[M, Msg, E](
  p: in Program[M, Msg, E],
  run: in (E) -> Option[Msg],
  cell: in List[Session[M, Msg]],
  env: in EffectEnv,
  effects: in List[E],
  outbox: in Outbox,
): Unit {
  for e in effects {
    val effect: E = e
    Tasks.scopeSpawn(env.tasks, { -> runEffect(p, run, cell, env, effect, outbox) })
  }
}

// Runs one effect and applies its result.  An effect that fails is reported
// and produces no result: nothing awaits these tasks, so a failure would
// otherwise vanish.
pub func runEffect[M, Msg, E](
  p: in Program[M, Msg, E],
  run: in (E) -> Option[Msg],
  cell: in List[Session[M, Msg]],
  env: in EffectEnv,
  effect: in E,
  outbox: in Outbox,
): Unit {
  if isClosed(env) {
    return
  }
  val reply: Option[Msg] = Guard.guardedEffect(run, effect)
  match reply {
    case Some(msg) -> {
      val m: Msg = msg
      withLock(env.lock, { -> applyResult(p, run, cell, env, m, outbox) })
    }
    case None -> ()
  }
}

// Applies an effect's result message under the instance lock.  A closed
// instance drops it; a detached session updates its model only.
pub func applyResult[M, Msg, E](
  p: in Program[M, Msg, E],
  run: in (E) -> Option[Msg],
  cell: in List[Session[M, Msg]],
  env: in EffectEnv,
  m: in Msg,
  outbox: in Outbox,
): Unit {
  if isClosed(env) or cell.count == 0 {
    return
  }
  val current: Session[M, Msg] = cell[0]
  val o: Output[M, Msg, E] = Session.dispatch(p, current, m)
  if env.detached[0] {
    val s: Session[M, Msg] = Session.detach(o.session)
    store(cell, s)
  } else {
    val s: Session[M, Msg] = o.session
    store(cell, s)
    emit(o, outbox)
  }
  startEffects(p, run, cell, env, o.effects, outbox)
}

/// Whether the instance owning `env` has been closed.
pub func isClosed(env: in EffectEnv): Bool {
  Tasks.isCancelled(Tasks.scopeToken(env.tasks))
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
