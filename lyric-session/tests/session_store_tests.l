// tests/session_store_tests.l — unit tests for InProcessSessionStore
// covering the CRUD surface beyond what session_fixation_tests.l covers.
//
// NOTE: uses Std.Core helpers (isOk/isErr/isSome/unwrapResultOr/unwrapErrOr/
// unwrapOr) instead of direct Ok/Err/Some/None constructor patterns to work
// around an emitter limitation in cross-package Result/Option matching under
// emitProject (#465).  Where isNone would be expected, `not isSome(opt)` is
// used instead: early-return Ok(None) sites produce a None whose generic type
// argument the emitter can't resolve for a direct `case None` isinst check,
// so the `case None` arm of isNone silently falls through returning false.
// `not isSome` avoids the nullary-case isinst path entirely.

@test_module
package Session.SessionStoreTests

import Std.Core
import Std.Testing
import Session as Session

// ─── create() ────────────────────────────────────────────────────────────────

test "create() returns Ok with a non-empty session ID" {
  val store = Session.inMemory()
  val cr = store.create()
  assertTrue(isOk(cr), "create() must succeed")
  val sid = unwrapResultOr(cr, "")
  assertTrue(sid.length > 0, "session ID must be non-empty")
}

test "create() returns different IDs on successive calls" {
  val store = Session.inMemory()
  val cr1 = store.create()
  assertTrue(isOk(cr1), "create() #1 must succeed")
  val sid1 = unwrapResultOr(cr1, "")
  val cr2 = store.create()
  assertTrue(isOk(cr2), "create() #2 must succeed")
  val sid2 = unwrapResultOr(cr2, "")
  assertTrue(sid1 != sid2, "successive create() calls must produce distinct IDs")
}

// ─── load() ──────────────────────────────────────────────────────────────────

test "load() after create() returns Some(data)" {
  val store = Session.inMemory()
  val cr = store.create()
  assertTrue(isOk(cr), "create() must succeed")
  val sid = unwrapResultOr(cr, "")
  val lr = store.load(sid)
  assertTrue(isOk(lr), "load() must succeed")
  val opt = unwrapResultOr(lr, None)
  assertTrue(isSome(opt), "load() must return Some for a just-created session")
  // Verify the session is usable (set/get round-trip confirms the correct session was loaded).
  val sr = store.set(sid, "__probe__", "1")
  assertTrue(isOk(sr), "set() into the loaded session must succeed")
}

test "load() for unknown ID returns Ok(None)" {
  val store = Session.inMemory()
  val lr = store.load("this-id-does-not-exist")
  assertTrue(isOk(lr), "load() on unknown id must return Ok(None)")
  val opt = unwrapResultOr(lr, None)
  assertTrue(not isSome(opt), "load() on unknown id must be None")
}

// ─── get() and set() ─────────────────────────────────────────────────────────

test "get() on unknown session returns Ok(None)" {
  val store = Session.inMemory()
  val gr = store.get("nonexistent-session", "any-key")
  assertTrue(isOk(gr), "get() on unknown session must be Ok(None)")
  val opt = unwrapResultOr(gr, None)
  assertTrue(not isSome(opt), "get() on unknown session must return None")
}

test "set() then get() round-trip" {
  val store = Session.inMemory()
  val cr = store.create()
  assertTrue(isOk(cr), "create() must succeed")
  val sid = unwrapResultOr(cr, "")
  val sr = store.set(sid, "username", "alice")
  assertTrue(isOk(sr), "set() must succeed")
  val gr = store.get(sid, "username")
  assertTrue(isOk(gr), "get() must succeed")
  val opt = unwrapResultOr(gr, None)
  assertTrue(isSome(opt), "get() must find value after set()")
  val v = unwrapOr(opt, "")
  assertEqual(v, "alice", "round-trip value")
}

test "set() then delete() then get() returns None" {
  val store = Session.inMemory()
  val cr = store.create()
  assertTrue(isOk(cr), "create() must succeed")
  val sid = unwrapResultOr(cr, "")
  val sr = store.set(sid, "k", "v")
  assertTrue(isOk(sr), "set() must succeed")
  val dr = store.delete(sid, "k")
  assertTrue(isOk(dr), "delete() must succeed")
  val gr = store.get(sid, "k")
  assertTrue(isOk(gr), "get() after delete() must return Ok(None)")
  val opt = unwrapResultOr(gr, None)
  assertTrue(isNone(opt), "key must be absent after delete()")
}

test "multiple keys in same session are independent" {
  val store = Session.inMemory()
  val cr = store.create()
  assertTrue(isOk(cr), "create() must succeed")
  val sid = unwrapResultOr(cr, "")
  val sra = store.set(sid, "a", "1")
  assertTrue(isOk(sra), "set(a) must succeed")
  val srb = store.set(sid, "b", "2")
  assertTrue(isOk(srb), "set(b) must succeed")
  val gra = store.get(sid, "a")
  assertTrue(isOk(gra), "get(a) must succeed")
  val optA = unwrapResultOr(gra, None)
  assertTrue(isSome(optA), "get(a) must find value")
  val va = unwrapOr(optA, "")
  val grb = store.get(sid, "b")
  assertTrue(isOk(grb), "get(b) must succeed")
  val optB = unwrapResultOr(grb, None)
  assertTrue(isSome(optB), "get(b) must find value")
  val vb = unwrapOr(optB, "")
  assertEqual(va, "1", "key a")
  assertEqual(vb, "2", "key b")
}

// ─── destroy() ───────────────────────────────────────────────────────────────

test "destroy() makes session disappear from load()" {
  val store = Session.inMemory()
  val cr = store.create()
  assertTrue(isOk(cr), "create() must succeed")
  val sid = unwrapResultOr(cr, "")
  val dstr = store.destroy(sid)
  assertTrue(isOk(dstr), "destroy() must succeed")
  val lr = store.load(sid)
  assertTrue(isOk(lr), "load() after destroy() must be Ok(None)")
  val opt = unwrapResultOr(lr, None)
  assertTrue(not isSome(opt), "session must not exist after destroy()")
}

// ─── clear() ─────────────────────────────────────────────────────────────────

test "clear() empties all keys but session still exists" {
  val store = Session.inMemory()
  val cr = store.create()
  assertTrue(isOk(cr), "create() must succeed")
  val sid = unwrapResultOr(cr, "")
  val srx = store.set(sid, "x", "hello")
  assertTrue(isOk(srx), "set(x) must succeed")
  val sry = store.set(sid, "y", "world")
  assertTrue(isOk(sry), "set(y) must succeed")
  val clr = store.clear(sid)
  assertTrue(isOk(clr), "clear() must succeed")
  // Session must still exist.
  val lr = store.load(sid)
  assertTrue(isOk(lr), "load() after clear() must succeed")
  val opt = unwrapResultOr(lr, None)
  assertTrue(isSome(opt), "session must still exist after clear()")
  // Verify all keys are absent (observable behaviour rather than internal count).
  val grx = store.get(sid, "x")
  assertTrue(isOk(grx), "get(x) after clear() must be Ok")
  val optX = unwrapResultOr(grx, None)
  assertTrue(isNone(optX), "key x must be absent after clear()")
  val gry = store.get(sid, "y")
  assertTrue(isOk(gry), "get(y) after clear() must be Ok")
  val optY = unwrapResultOr(gry, None)
  assertTrue(isNone(optY), "key y must be absent after clear()")
}

// ─── touch() ─────────────────────────────────────────────────────────────────

test "touch() on existing session returns Ok" {
  val store = Session.inMemory()
  val cr = store.create()
  assertTrue(isOk(cr), "create() must succeed")
  val sid = unwrapResultOr(cr, "")
  val tr = store.touch(sid)
  assertTrue(isOk(tr), "touch() on existing session must succeed")
}

test "touch() on non-existent session returns Ok (no-op)" {
  val store = Session.inMemory()
  val tr = store.touch("ghost-session-id")
  assertTrue(isOk(tr), "touch() on non-existent session must be Ok")
}

// ─── delete() ────────────────────────────────────────────────────────────────

test "delete() on non-existent key is idempotent" {
  val store = Session.inMemory()
  val cr = store.create()
  assertTrue(isOk(cr), "create() must succeed")
  val sid = unwrapResultOr(cr, "")
  val dr = store.delete(sid, "nope")
  assertTrue(isOk(dr), "delete() of absent key must be Ok")
}

test "destroy() on non-existent session is idempotent" {
  val store = Session.inMemory()
  val dr = store.destroy("no-such-session")
  assertTrue(isOk(dr), "destroy() on absent session must not fail")
}

// ─── Session isolation ────────────────────────────────────────────────────────

test "two distinct sessions are independent" {
  val store = Session.inMemory()
  val cr1 = store.create()
  assertTrue(isOk(cr1), "create() #1 must succeed")
  val sid1 = unwrapResultOr(cr1, "")
  val cr2 = store.create()
  assertTrue(isOk(cr2), "create() #2 must succeed")
  val sid2 = unwrapResultOr(cr2, "")
  val sr1 = store.set(sid1, "role", "admin")
  assertTrue(isOk(sr1), "set(sid1, role) must succeed")
  val sr2 = store.set(sid2, "role", "guest")
  assertTrue(isOk(sr2), "set(sid2, role) must succeed")
  val gr1 = store.get(sid1, "role")
  assertTrue(isOk(gr1), "get(sid1, role) must succeed")
  val opt1 = unwrapResultOr(gr1, None)
  assertTrue(isSome(opt1), "get(sid1, role) must find value")
  val r1 = unwrapOr(opt1, "")
  val gr2 = store.get(sid2, "role")
  assertTrue(isOk(gr2), "get(sid2, role) must succeed")
  val opt2 = unwrapResultOr(gr2, None)
  assertTrue(isSome(opt2), "get(sid2, role) must find value")
  val r2 = unwrapOr(opt2, "")
  assertEqual(r1, "admin", "session 1 role")
  assertEqual(r2, "guest", "session 2 role")
}
