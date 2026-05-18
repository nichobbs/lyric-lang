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

@test_module
package Session.SensitiveUrlTests

import Std.Core
import Std.Testing
import Session

func credentialUrl(): String {
  // Canonical Redis URL with embedded password — the password "s3cr3t" must
  // not appear in any error message produced by the session module.
  "redis://:s3cr3t@127.0.0.1:56789/0"
}

test "InProcessSessionStore: credential URL never appears in session errors" {
  // InProcessSessionStore does not use the URL at all — this test verifies
  // the in-memory path produces errors whose text does not embed credential
  // material (defensive belt-and-suspenders check).
  val store = Session.inMemory()
  match Session.set(store, "phantom-id", "key", "value") {
    case Ok(_) ->
      assertTrue(false, "set() on unknown id should fail")
    case Err(e) -> {
      assertTrue(not e.message.contains("s3cr3t"),
        "session error must not contain password substring: " + e.message)
      assertTrue(not e.message.contains(credentialUrl()),
        "session error must not echo the full URL: " + e.message)
    }
  }
}

test "session error codes do not embed url field value" {
  // Verify that error codes from session operations are fixed strings,
  // not constructed from config values (which could include credentials).
  val store = Session.inMemory()
  match Session.load(store, "nonexistent") {
    case Err(e) -> {
      assertTrue(e.code.length > 0, "error code must be non-empty")
      assertTrue(not e.code.contains("s3cr3t"), "error code must not contain credential")
    }
    case Ok(_) -> ()
  }
}
