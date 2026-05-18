// tests/session_fixation_tests.l — regression suite for the session
// fixation guard in `InProcessSessionStore` (lyric-lang #316 / #436).
//
// Before the fix, both NativeSessionStore.set() and
// InProcessSessionStore.set() carried a `case None ->` arm that
// materialised a brand-new SessionData using a caller-supplied
// sessionId.  An attacker who planted a known cookie value (XSS,
// subdomain cookie taint, phishing link) could rely on `set()` being
// called during the legitimate sign-in flow to bind real user data
// to the attacker-known id — full account takeover.
//
// These tests pin the post-fix invariant:
//
//   1. set() on an unknown id returns
//      Err(SessionError { code = "SESSION_NOT_FOUND", ... })
//      rather than silently creating the session.
//   2. delete() and clear() on an unknown id continue to return
//      Ok(()) — removal is idempotent, no fixation vector.
//   3. set() after a legitimate create() works as expected.
//
// Run: `lyric test --manifest lyric-session/lyric.toml`
// (Requires the multi-package test runner tracked in issue #465.
// Until then this file ships as the executable spec for the fix.)

@test_module
package Session.SessionFixationTests

import Std.Core
import Std.Testing
import Session

// ─── Helper: build an empty in-process store for each test. ─────────────

func newStore(): Session.InProcessSessionStore {
  Session.inMemory()
}

// ─── Core fixation guard. ─────────────────────────────────────────────────

test "set() on unknown id returns SESSION_NOT_FOUND (no auto-create)" {
  val store = newStore()
  match Session.set(store, "attacker-planted-id", "userId", "victim-42") {
    case Ok(_) ->
      assertTrue(false,
        "set() on an unknown id must NOT silently auto-create — that's the fixation vector")
    case Err(e) ->
      assertEqual(e.code, "SESSION_NOT_FOUND",
        "expected SESSION_NOT_FOUND, got " + e.code + ": " + e.message)
  }
}

test "set() succeeds for an id obtained via create()" {
  val store = newStore()
  match Session.create(store) {
    case Err(e) ->
      assertTrue(false, "create() should succeed for a fresh store: " + e.message)
    case Ok(sid) -> {
      match Session.set(store, sid, "userId", "42") {
        case Err(e) ->
          assertTrue(false, "set() should succeed for a server-issued id: " + e.message)
        case Ok(_) -> assertTrue(true, "ok")
      }
      // And reading the value back returns it.
      match Session.get(store, sid, "userId") {
        case Err(e) ->
          assertTrue(false, "get() should succeed: " + e.message)
        case Ok(opt) ->
          match opt {
            case None    -> assertTrue(false, "value should be present after set()")
            case Some(v) -> assertEqual(v, "42", "round-trip value")
          }
      }
    }
  }
}

// ─── Asymmetry with delete/clear is intentional (#441). ───────────────────

test "delete() on unknown id is idempotent (returns Ok)" {
  val store = newStore()
  match Session.delete(store, "never-existed", "any-key") {
    case Err(e) ->
      assertTrue(false,
        "delete() on an unknown id should be idempotent: got Err " + e.code)
    case Ok(_) -> assertTrue(true, "ok")
  }
}

test "clear() on unknown id is idempotent (returns Ok)" {
  val store = newStore()
  match Session.clear(store, "never-existed") {
    case Err(e) ->
      assertTrue(false,
        "clear() on an unknown id should be idempotent: got Err " + e.code)
    case Ok(_) -> assertTrue(true, "ok")
  }
}

// ─── Boundary: set() error must not leak partial state. ──────────────────

test "failed set() does NOT materialise the id as a side-effect" {
  val store = newStore()
  // First call hits the fixation guard:
  match Session.set(store, "attacker-planted-id", "k1", "v1") {
    case Ok(_)  -> assertTrue(false, "first set() must reject")
    case Err(_) -> ()
  }
  // A subsequent get() against the same id must still see no session.
  match Session.get(store, "attacker-planted-id", "k1") {
    case Err(e) ->
      assertTrue(false,
        "get() on the still-unknown id should succeed with Ok(None): got Err " + e.code)
    case Ok(opt) ->
      match opt {
        case None    -> assertTrue(true, "ok — failed set() left no trace")
        case Some(_) ->
          assertTrue(false,
            "failed set() leaked state — the id was created as a side-effect")
      }
  }
}
