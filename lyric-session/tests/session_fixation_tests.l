// tests/session_fixation_tests.l — regression suite for the
// session-fixation guard in `InProcessSessionStore.set()` (#316).
// Run via the multi-package test runner tracked in #465.

@test_module
package Session.SessionFixationTests

import Std.Core
import Std.Testing
import Session as Session

test "set() on unknown id returns SESSION_NOT_FOUND (no auto-create)" {
  val store = Session.inMemory()
  val r = store.set("attacker-planted-id", "userId", "victim-42")
  match r {
    case Ok(_) ->
      assertTrue(false,
        "set() on an unknown id must NOT silently auto-create — that's the fixation vector")
    case Err(e) ->
      assertEqual(e.code, "SESSION_NOT_FOUND",
        "expected SESSION_NOT_FOUND, got " + e.code + ": " + e.message)
  }
}

test "set() succeeds for an id obtained via create()" {
  val store = Session.inMemory()
  match store.create() {
    case Err(e) ->
      assertTrue(false, "create() should succeed for a fresh store: " + e.message)
    case Ok(sid) -> {
      match store.set(sid, "userId", "42") {
        case Err(e) ->
          assertTrue(false, "set() should succeed for a server-issued id: " + e.message)
        case Ok(_) -> {
          match store.get(sid, "userId") {
            case Err(e) ->
              assertTrue(false, "get() should succeed: " + e.message)
            case Ok(opt) ->
              match opt {
                case None ->
                  assertTrue(false, "value should be present after set()")
                case Some(v) ->
                  assertEqual(v, "42", "round-trip value")
              }
          }
        }
      }
    }
  }
}

// Asymmetry with delete/clear is intentional (#441).

test "delete() on unknown id is idempotent (returns Ok)" {
  val store = Session.inMemory()
  match store.delete("never-existed", "any-key") {
    case Ok(_)  -> ()
    case Err(e) -> assertTrue(false, "delete() on an unknown id should be idempotent: " + e.message)
  }
}

test "clear() on unknown id is idempotent (returns Ok)" {
  val store = Session.inMemory()
  match store.clear("never-existed") {
    case Ok(_)  -> ()
    case Err(e) -> assertTrue(false, "clear() on an unknown id should be idempotent: " + e.message)
  }
}

test "failed set() does NOT materialise the id as a side-effect" {
  val store = Session.inMemory()
  match store.set("attacker-planted-id", "k1", "v1") {
    case Ok(_) -> assertTrue(false, "first set() must reject")
    case Err(_) -> ()
  }
  match store.get("attacker-planted-id", "k1") {
    case Err(e) ->
      assertTrue(false,
        "get() on the still-unknown id should succeed with Ok(None): " + e.message)
    case Ok(opt) ->
      match opt {
        case Some(_) ->
          assertTrue(false,
            "failed set() leaked state — the id was created as a side-effect")
        case None -> ()
      }
  }
}
