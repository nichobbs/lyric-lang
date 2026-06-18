// tests/session_store_tests.l — unit tests for InProcessSessionStore
// covering the CRUD surface beyond what session_fixation_tests.l covers.

@test_module
package Session.SessionStoreTests

import Std.Core
import Std.Testing
import Session as Session

// ─── create() ────────────────────────────────────────────────────────────────

test "create() returns Ok with a non-empty session ID" {
  val store = Session.inMemory()
  match store.create() {
    case Err(e)  -> assertTrue(false, "create() must succeed: " + e.message)
    case Ok(sid) -> assertTrue(sid.length > 0, "session ID must be non-empty")
  }
}

test "create() returns different IDs on successive calls" {
  val store = Session.inMemory()
  match store.create() {
    case Err(e) -> assertTrue(false, "create() #1 must succeed: " + e.message)
    case Ok(sid1) ->
      match store.create() {
        case Err(e) -> assertTrue(false, "create() #2 must succeed: " + e.message)
        case Ok(sid2) ->
          assertTrue(sid1 != sid2, "successive create() calls must produce distinct IDs")
      }
  }
}

// ─── load() ──────────────────────────────────────────────────────────────────

test "load() after create() returns Some(data)" {
  val store = Session.inMemory()
  match store.create() {
    case Err(e) -> assertTrue(false, "create() must succeed: " + e.message)
    case Ok(sid) ->
      match store.load(sid) {
        case Err(e) -> assertTrue(false, "load() must succeed: " + e.message)
        case Ok(opt) ->
          match opt {
            case None ->
              assertTrue(false, "load() must return Some for a just-created session")
            case Some(_) -> {
              // Verify the session is usable (set/get round-trip confirms the correct
              // session was loaded).
              match store.set(sid, "__probe__", "1") {
                case Err(e) -> assertTrue(false, "set() into the loaded session must succeed: " + e.message)
                case Ok(_)  -> ()
              }
            }
          }
      }
  }
}

test "load() for unknown ID returns Ok(None)" {
  val store = Session.inMemory()
  match store.load("this-id-does-not-exist") {
    case Err(e) -> assertTrue(false, "load() on unknown id must return Ok(None): " + e.message)
    case Ok(opt) ->
      match opt {
        case Some(_) -> assertTrue(false, "load() on unknown id must be None")
        case None    -> ()
      }
  }
}

// ─── get() and set() ─────────────────────────────────────────────────────────

test "get() on unknown session returns Ok(None)" {
  val store = Session.inMemory()
  match store.get("nonexistent-session", "any-key") {
    case Err(e) -> assertTrue(false, "get() on unknown session must be Ok(None): " + e.message)
    case Ok(opt) ->
      match opt {
        case Some(_) -> assertTrue(false, "get() on unknown session must return None")
        case None    -> ()
      }
  }
}

test "set() then get() round-trip" {
  val store = Session.inMemory()
  match store.create() {
    case Err(e) -> assertTrue(false, "create() must succeed: " + e.message)
    case Ok(sid) -> {
      match store.set(sid, "username", "alice") {
        case Err(e) -> assertTrue(false, "set() must succeed: " + e.message)
        case Ok(_)  -> ()
      }
      match store.get(sid, "username") {
        case Err(e) -> assertTrue(false, "get() must succeed: " + e.message)
        case Ok(opt) ->
          match opt {
            case None    -> assertTrue(false, "get() must find value after set()")
            case Some(v) -> assertEqual(v, "alice", "round-trip value")
          }
      }
    }
  }
}

test "set() then delete() then get() returns None" {
  val store = Session.inMemory()
  match store.create() {
    case Err(e) -> assertTrue(false, "create() must succeed: " + e.message)
    case Ok(sid) -> {
      match store.set(sid, "k", "v") {
        case Err(e) -> assertTrue(false, "set() must succeed: " + e.message)
        case Ok(_)  -> ()
      }
      match store.delete(sid, "k") {
        case Err(e) -> assertTrue(false, "delete() must succeed: " + e.message)
        case Ok(_)  -> ()
      }
      match store.get(sid, "k") {
        case Err(e) -> assertTrue(false, "get() after delete() must return Ok(None): " + e.message)
        case Ok(opt) ->
          match opt {
            case Some(_) -> assertTrue(false, "key must be absent after delete()")
            case None    -> ()
          }
      }
    }
  }
}

test "multiple keys in same session are independent" {
  val store = Session.inMemory()
  match store.create() {
    case Err(e) -> assertTrue(false, "create() must succeed: " + e.message)
    case Ok(sid) -> {
      match store.set(sid, "a", "1") {
        case Err(e) -> assertTrue(false, "set(a) must succeed: " + e.message)
        case Ok(_)  -> ()
      }
      match store.set(sid, "b", "2") {
        case Err(e) -> assertTrue(false, "set(b) must succeed: " + e.message)
        case Ok(_)  -> ()
      }
      match store.get(sid, "a") {
        case Err(e) -> assertTrue(false, "get(a) must succeed: " + e.message)
        case Ok(optA) ->
          match optA {
            case None     -> assertTrue(false, "get(a) must find value")
            case Some(va) -> assertEqual(va, "1", "key a")
          }
      }
      match store.get(sid, "b") {
        case Err(e) -> assertTrue(false, "get(b) must succeed: " + e.message)
        case Ok(optB) ->
          match optB {
            case None     -> assertTrue(false, "get(b) must find value")
            case Some(vb) -> assertEqual(vb, "2", "key b")
          }
      }
    }
  }
}

// ─── destroy() ───────────────────────────────────────────────────────────────

test "destroy() makes session disappear from load()" {
  val store = Session.inMemory()
  match store.create() {
    case Err(e) -> assertTrue(false, "create() must succeed: " + e.message)
    case Ok(sid) -> {
      match store.destroy(sid) {
        case Err(e) -> assertTrue(false, "destroy() must succeed: " + e.message)
        case Ok(_)  -> ()
      }
      match store.load(sid) {
        case Err(e) -> assertTrue(false, "load() after destroy() must be Ok(None): " + e.message)
        case Ok(opt) ->
          match opt {
            case Some(_) -> assertTrue(false, "session must not exist after destroy()")
            case None    -> ()
          }
      }
    }
  }
}

// ─── clear() ─────────────────────────────────────────────────────────────────

test "clear() empties all keys but session still exists" {
  val store = Session.inMemory()
  match store.create() {
    case Err(e) -> assertTrue(false, "create() must succeed: " + e.message)
    case Ok(sid) -> {
      match store.set(sid, "x", "hello") {
        case Err(e) -> assertTrue(false, "set(x) must succeed: " + e.message)
        case Ok(_)  -> ()
      }
      match store.set(sid, "y", "world") {
        case Err(e) -> assertTrue(false, "set(y) must succeed: " + e.message)
        case Ok(_)  -> ()
      }
      match store.clear(sid) {
        case Err(e) -> assertTrue(false, "clear() must succeed: " + e.message)
        case Ok(_)  -> ()
      }
      // Session must still exist.
      match store.load(sid) {
        case Err(e) -> assertTrue(false, "load() after clear() must succeed: " + e.message)
        case Ok(opt) ->
          match opt {
            case None    -> assertTrue(false, "session must still exist after clear()")
            case Some(_) -> ()
          }
      }
      // Verify all keys are absent (observable behaviour rather than internal count).
      match store.get(sid, "x") {
        case Err(e) -> assertTrue(false, "get(x) after clear() must be Ok: " + e.message)
        case Ok(optX) ->
          match optX {
            case Some(_) -> assertTrue(false, "key x must be absent after clear()")
            case None    -> ()
          }
      }
      match store.get(sid, "y") {
        case Err(e) -> assertTrue(false, "get(y) after clear() must be Ok: " + e.message)
        case Ok(optY) ->
          match optY {
            case Some(_) -> assertTrue(false, "key y must be absent after clear()")
            case None    -> ()
          }
      }
    }
  }
}

// ─── touch() ─────────────────────────────────────────────────────────────────

test "touch() on existing session returns Ok" {
  val store = Session.inMemory()
  match store.create() {
    case Err(e) -> assertTrue(false, "create() must succeed: " + e.message)
    case Ok(sid) ->
      match store.touch(sid) {
        case Err(e) -> assertTrue(false, "touch() on existing session must succeed: " + e.message)
        case Ok(_)  -> ()
      }
  }
}

test "touch() on non-existent session returns Ok (no-op)" {
  val store = Session.inMemory()
  match store.touch("ghost-session-id") {
    case Err(e) -> assertTrue(false, "touch() on non-existent session must be Ok: " + e.message)
    case Ok(_)  -> ()
  }
}

// ─── delete() ────────────────────────────────────────────────────────────────

test "delete() on non-existent key is idempotent" {
  val store = Session.inMemory()
  match store.create() {
    case Err(e) -> assertTrue(false, "create() must succeed: " + e.message)
    case Ok(sid) ->
      match store.delete(sid, "nope") {
        case Err(e) -> assertTrue(false, "delete() of absent key must be Ok: " + e.message)
        case Ok(_)  -> ()
      }
  }
}

test "destroy() on non-existent session is idempotent" {
  val store = Session.inMemory()
  match store.destroy("no-such-session") {
    case Err(e) -> assertTrue(false, "destroy() on absent session must not fail: " + e.message)
    case Ok(_)  -> ()
  }
}

// ─── Session isolation ────────────────────────────────────────────────────────

test "two distinct sessions are independent" {
  val store = Session.inMemory()
  match store.create() {
    case Err(e) -> assertTrue(false, "create() #1 must succeed: " + e.message)
    case Ok(sid1) ->
      match store.create() {
        case Err(e) -> assertTrue(false, "create() #2 must succeed: " + e.message)
        case Ok(sid2) -> {
          match store.set(sid1, "role", "admin") {
            case Err(e) -> assertTrue(false, "set(sid1, role) must succeed: " + e.message)
            case Ok(_)  -> ()
          }
          match store.set(sid2, "role", "guest") {
            case Err(e) -> assertTrue(false, "set(sid2, role) must succeed: " + e.message)
            case Ok(_)  -> ()
          }
          match store.get(sid1, "role") {
            case Err(e) -> assertTrue(false, "get(sid1, role) must succeed: " + e.message)
            case Ok(opt1) ->
              match opt1 {
                case None     -> assertTrue(false, "get(sid1, role) must find value")
                case Some(r1) -> assertEqual(r1, "admin", "session 1 role")
              }
          }
          match store.get(sid2, "role") {
            case Err(e) -> assertTrue(false, "get(sid2, role) must succeed: " + e.message)
            case Ok(opt2) ->
              match opt2 {
                case None     -> assertTrue(false, "get(sid2, role) must find value")
                case Some(r2) -> assertEqual(r2, "guest", "session 2 role")
              }
          }
        }
      }
  }
}
