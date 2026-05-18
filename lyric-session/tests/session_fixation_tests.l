// tests/session_fixation_tests.l — regression suite for the
// session-fixation guard in `InProcessSessionStore.set()` (#316).
// Run via the multi-package test runner tracked in #465.

@test_module
package Session.SessionFixationTests

import Std.Core
import Std.Testing
import Session

func newStore(): Session.InProcessSessionStore {
  Session.inMemory()
}

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
        case Ok(_) -> ()
      }
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

// Asymmetry with delete/clear is intentional (#441).

test "delete() on unknown id is idempotent (returns Ok)" {
  val store = newStore()
  match Session.delete(store, "never-existed", "any-key") {
    case Err(e) ->
      assertTrue(false,
        "delete() on an unknown id should be idempotent: got Err " + e.code)
    case Ok(_) -> ()
  }
}

test "clear() on unknown id is idempotent (returns Ok)" {
  val store = newStore()
  match Session.clear(store, "never-existed") {
    case Err(e) ->
      assertTrue(false,
        "clear() on an unknown id should be idempotent: got Err " + e.code)
    case Ok(_) -> ()
  }
}

test "failed set() does NOT materialise the id as a side-effect" {
  val store = newStore()
  match Session.set(store, "attacker-planted-id", "k1", "v1") {
    case Ok(_)  -> assertTrue(false, "first set() must reject")
    case Err(_) -> ()
  }
  match Session.get(store, "attacker-planted-id", "k1") {
    case Err(e) ->
      assertTrue(false,
        "get() on the still-unknown id should succeed with Ok(None): got Err " + e.code)
    case Ok(opt) ->
      match opt {
        case None    -> ()  // failed set() left no trace — invariant holds.
        case Some(_) ->
          assertTrue(false,
            "failed set() leaked state — the id was created as a side-effect")
      }
  }
}
