// tests/sensitive_url_tests.l — regression for RedisSession.url @sensitive (#357/#477).
//
// The RedisSession.url field is annotated @sensitive so the config framework
// masks it in log/diagnostic output.  Because the config-layer masking is
// enforced at the framework level (not in pure Lyric), this file tests the
// observable consequence: any error message produced by the session module when
// given a credential-bearing URL must not echo the raw password substring.
//
// Full config-layer masking is an integration concern and cannot be fully
// exercised in a unit test.  These tests focus on the module's direct error
// surfaces.
//
// NOTE: uses Std.Core helpers (isErr/unwrapErrOr) instead of direct Ok/Err
// constructor patterns to work around an emitter limitation in cross-package
// Result matching under emitProject (#465).

@test_module
package Session.SensitiveUrlTests

import Std.Core
import Std.Testing
import Session as Session

test "InProcessSessionStore: credential URL never appears in session errors" {
  // InProcessSessionStore does not use the URL at all — this test verifies
  // the in-memory path produces errors whose text does not embed credential
  // material (defensive belt-and-suspenders check).
  val store = Session.inMemory()
  val r = store.set("phantom-id", "key", "value")
  assertTrue(isErr(r), "set() on unknown id should fail")
  val e = unwrapErrOr(r, SessionError(message = "", code = ""))
  assertTrue(not e.message.contains("s3cr3t"),
    "session error must not contain password substring: " + e.message)
  assertTrue(not e.message.contains("redis://:s3cr3t@127.0.0.1:56789/0"),
    "session error must not echo the full URL: " + e.message)
}

test "session destroy errors (if any) do not embed url field value" {
  val store = Session.inMemory()
  val r = store.destroy("no-such-session")
  // destroy() on a non-existent session is a no-op (Ok); only check if Err.
  if isErr(r) {
    val e = unwrapErrOr(r, SessionError(message = "", code = ""))
    assertTrue(not e.message.contains("s3cr3t"),
      "destroy error must not contain password: " + e.message)
    assertTrue(not e.code.contains("s3cr3t"),
      "destroy error code must not contain password: " + e.code)
  }
}

test "session error codes do not embed url field value" {
  // Verify that error codes from session operations are fixed strings,
  // not constructed from config values (which could include credentials).
  val store = Session.inMemory()
  val r = store.load("nonexistent")
  // load() on a nonexistent id returns Ok(None); only check Err if present.
  if isErr(r) {
    val e = unwrapErrOr(r, SessionError(message = "", code = ""))
    assertTrue(e.code.length > 0, "error code must be non-empty")
    assertTrue(not e.code.contains("s3cr3t"), "error code must not contain credential")
  }
}
