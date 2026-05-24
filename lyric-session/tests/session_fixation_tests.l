// tests/session_fixation_tests.l — regression suite for the
// session-fixation guard in `InProcessSessionStore.set()` (#316).
// Run via the multi-package test runner tracked in #465.
//
// NOTE: uses Std.Core helpers (isOk/isErr/isSome/unwrapResultOr/unwrapErrOr/
// unwrapOr) instead of direct Ok/Err/Some/None constructor patterns to work
// around an emitter limitation in cross-package Result/Option matching under
// emitProject (#465).  `not isSome(opt)` is used in place of `isNone(opt)`
// where the None originates from an early-return Ok(None) site; see
// session_store_tests.l for the full explanation.

@test_module
package Session.SessionFixationTests

import Std.Core
import Std.Testing
import Session as Session

test "set() on unknown id returns SESSION_NOT_FOUND (no auto-create)" {
  val store = Session.inMemory()
  val r = store.set("attacker-planted-id", "userId", "victim-42")
  assertTrue(isErr(r),
    "set() on an unknown id must NOT silently auto-create — that's the fixation vector")
  val e = unwrapErrOr(r, SessionError(message = "", code = ""))
  assertEqual(e.code, "SESSION_NOT_FOUND",
    "expected SESSION_NOT_FOUND, got " + e.code + ": " + e.message)
}

test "set() succeeds for an id obtained via create()" {
  val store = Session.inMemory()
  val cr = store.create()
  assertTrue(isOk(cr), "create() should succeed for a fresh store")
  val sid = unwrapResultOr(cr, "")
  val sr = store.set(sid, "userId", "42")
  assertTrue(isOk(sr), "set() should succeed for a server-issued id")
  val gr = store.get(sid, "userId")
  assertTrue(isOk(gr), "get() should succeed")
  val opt = unwrapResultOr(gr, None)
  assertTrue(isSome(opt), "value should be present after set()")
  val v = unwrapOr(opt, "")
  assertEqual(v, "42", "round-trip value")
}

// Asymmetry with delete/clear is intentional (#441).

test "delete() on unknown id is idempotent (returns Ok)" {
  val store = Session.inMemory()
  val r = store.delete("never-existed", "any-key")
  assertTrue(isOk(r), "delete() on an unknown id should be idempotent")
}

test "clear() on unknown id is idempotent (returns Ok)" {
  val store = Session.inMemory()
  val r = store.clear("never-existed")
  assertTrue(isOk(r), "clear() on an unknown id should be idempotent")
}

test "failed set() does NOT materialise the id as a side-effect" {
  val store = Session.inMemory()
  val sr = store.set("attacker-planted-id", "k1", "v1")
  assertTrue(isErr(sr), "first set() must reject")
  val gr = store.get("attacker-planted-id", "k1")
  assertTrue(isOk(gr),
    "get() on the still-unknown id should succeed with Ok(None)")
  val opt = unwrapResultOr(gr, None)
  assertTrue(not isSome(opt),
    "failed set() leaked state — the id was created as a side-effect")
}
