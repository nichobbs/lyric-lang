// tests/session_store_tests.l — unit tests for InProcessSessionStore
// covering the CRUD surface beyond what session_fixation_tests.l covers.

@test_module
package Session.SessionStoreTests

import Std.Core
import Std.Testing
import Std.Collections
import Session

func newStore(): Session.InProcessSessionStore {
  Session.inMemory()
}

// ─── create() ────────────────────────────────────────────────────────────────

test "create() returns Ok with a non-empty session ID" {
  val store = newStore()
  match Session.create(store) {
    case Err(e) -> assertTrue(false, "create() must succeed: " + e.message)
    case Ok(sid) -> assertTrue(sid.length > 0, "session ID must be non-empty")
  }
}

test "create() returns different IDs on successive calls" {
  val store = newStore()
  val sid1 = match Session.create(store) {
    case Ok(id)  -> id
    case Err(e)  -> { assertTrue(false, "create() #1 failed: " + e.message); "" }
  }
  val sid2 = match Session.create(store) {
    case Ok(id)  -> id
    case Err(e)  -> { assertTrue(false, "create() #2 failed: " + e.message); "" }
  }
  assertTrue(sid1 != sid2, "successive create() calls must produce distinct IDs")
}

// ─── load() ──────────────────────────────────────────────────────────────────

test "load() after create() returns Some(data) with correct ID" {
  val store = newStore()
  match Session.create(store) {
    case Err(e) -> assertTrue(false, "create() failed: " + e.message)
    case Ok(sid) -> {
      match Session.load(store, sid) {
        case Err(e)  -> assertTrue(false, "load() failed: " + e.message)
        case Ok(opt) ->
          match opt {
            case None    -> assertTrue(false, "load() must return Some for a just-created session")
            case Some(d) -> assertEqual(d.id, sid, "loaded session ID matches created ID")
          }
      }
    }
  }
}

test "load() for unknown ID returns Ok(None)" {
  val store = newStore()
  match Session.load(store, "this-id-does-not-exist") {
    case Err(e)  -> assertTrue(false, "load() on unknown id must return Ok(None): " + e.message)
    case Ok(opt) ->
      match opt {
        case None    -> ()
        case Some(_) -> assertTrue(false, "load() on unknown id must be None")
      }
  }
}

// ─── get() and set() ─────────────────────────────────────────────────────────

test "get() on unknown session returns Ok(None)" {
  val store = newStore()
  match Session.get(store, "nonexistent-session", "any-key") {
    case Err(e)  -> assertTrue(false, "get() on unknown session must be Ok(None): " + e.message)
    case Ok(opt) ->
      match opt {
        case None    -> ()
        case Some(_) -> assertTrue(false, "get() on unknown session must return None")
      }
  }
}

test "set() then get() round-trip" {
  val store = newStore()
  match Session.create(store) {
    case Err(e)  -> assertTrue(false, "create() failed: " + e.message)
    case Ok(sid) -> {
      match Session.set(store, sid, "username", "alice") {
        case Err(e) -> assertTrue(false, "set() failed: " + e.message)
        case Ok(_)  -> ()
      }
      match Session.get(store, sid, "username") {
        case Err(e)  -> assertTrue(false, "get() failed: " + e.message)
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
  val store = newStore()
  match Session.create(store) {
    case Err(e)  -> assertTrue(false, "create() failed: " + e.message)
    case Ok(sid) -> {
      Session.set(store, sid, "k", "v")
      Session.delete(store, sid, "k")
      match Session.get(store, sid, "k") {
        case Err(e)  -> assertTrue(false, "get() after delete() must return Ok(None): " + e.message)
        case Ok(opt) ->
          match opt {
            case None    -> ()
            case Some(_) -> assertTrue(false, "key must be absent after delete()")
          }
      }
    }
  }
}

test "multiple keys in same session are independent" {
  val store = newStore()
  match Session.create(store) {
    case Err(e)  -> assertTrue(false, "create() failed: " + e.message)
    case Ok(sid) -> {
      Session.set(store, sid, "a", "1")
      Session.set(store, sid, "b", "2")
      val va = match Session.get(store, sid, "a") {
        case Ok(Some(v)) -> v
        case _           -> { assertTrue(false, "get(a) failed"); "" }
      }
      val vb = match Session.get(store, sid, "b") {
        case Ok(Some(v)) -> v
        case _           -> { assertTrue(false, "get(b) failed"); "" }
      }
      assertEqual(va, "1", "key a")
      assertEqual(vb, "2", "key b")
    }
  }
}

// ─── destroy() ───────────────────────────────────────────────────────────────

test "destroy() makes session disappear from load()" {
  val store = newStore()
  match Session.create(store) {
    case Err(e)  -> assertTrue(false, "create() failed: " + e.message)
    case Ok(sid) -> {
      match Session.destroy(store, sid) {
        case Err(e) -> assertTrue(false, "destroy() failed: " + e.message)
        case Ok(_)  -> ()
      }
      match Session.load(store, sid) {
        case Err(e)  -> assertTrue(false, "load() after destroy() must be Ok(None): " + e.message)
        case Ok(opt) ->
          match opt {
            case None    -> ()
            case Some(_) -> assertTrue(false, "session must not exist after destroy()")
          }
      }
    }
  }
}

// ─── clear() ─────────────────────────────────────────────────────────────────

test "clear() empties all keys but session still exists" {
  val store = newStore()
  match Session.create(store) {
    case Err(e)  -> assertTrue(false, "create() failed: " + e.message)
    case Ok(sid) -> {
      Session.set(store, sid, "x", "hello")
      Session.set(store, sid, "y", "world")
      match Session.clear(store, sid) {
        case Err(e) -> assertTrue(false, "clear() failed: " + e.message)
        case Ok(_)  -> ()
      }
      // Session must still exist.
      match Session.load(store, sid) {
        case Err(e)  -> assertTrue(false, "load() after clear() failed: " + e.message)
        case Ok(opt) ->
          match opt {
            case None    -> assertTrue(false, "session must still exist after clear()")
            case Some(d) -> assertEqualInt(d.entries.size(), 0, "entries must be empty after clear()")
          }
      }
    }
  }
}

// ─── touch() ─────────────────────────────────────────────────────────────────

test "touch() on existing session returns Ok" {
  val store = newStore()
  match Session.create(store) {
    case Err(e)  -> assertTrue(false, "create() failed: " + e.message)
    case Ok(sid) -> {
      match Session.touch(store, sid) {
        case Err(e) -> assertTrue(false, "touch() on existing session failed: " + e.message)
        case Ok(_)  -> ()
      }
    }
  }
}

test "touch() on non-existent session returns Ok (no-op)" {
  val store = newStore()
  match Session.touch(store, "ghost-session-id") {
    case Err(e) -> assertTrue(false, "touch() on non-existent session must be Ok: " + e.message)
    case Ok(_)  -> ()
  }
}

// ─── delete() ────────────────────────────────────────────────────────────────

test "delete() on non-existent key is idempotent" {
  val store = newStore()
  match Session.create(store) {
    case Err(e)  -> assertTrue(false, "create() failed: " + e.message)
    case Ok(sid) -> {
      match Session.delete(store, sid, "nope") {
        case Err(e) -> assertTrue(false, "delete() of absent key must be Ok: " + e.message)
        case Ok(_)  -> ()
      }
    }
  }
}

// ─── Session isolation ────────────────────────────────────────────────────────

test "two distinct sessions are independent" {
  val store = newStore()
  val sid1 = match Session.create(store) {
    case Ok(id)  -> id
    case Err(e)  -> { assertTrue(false, "create() #1 failed: " + e.message); "" }
  }
  val sid2 = match Session.create(store) {
    case Ok(id)  -> id
    case Err(e)  -> { assertTrue(false, "create() #2 failed: " + e.message); "" }
  }
  Session.set(store, sid1, "role", "admin")
  Session.set(store, sid2, "role", "guest")
  val r1 = match Session.get(store, sid1, "role") {
    case Ok(Some(v)) -> v
    case _           -> { assertTrue(false, "get(sid1, role) failed"); "" }
  }
  val r2 = match Session.get(store, sid2, "role") {
    case Ok(Some(v)) -> v
    case _           -> { assertTrue(false, "get(sid2, role) failed"); "" }
  }
  assertEqual(r1, "admin", "session 1 role")
  assertEqual(r2, "guest",  "session 2 role")
}
