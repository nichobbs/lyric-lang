// tests/sensitive_url_tests.l — regression for RedisSession.url @sensitive (#357/#477/#1071).
//
// The RedisSession.url field is annotated @sensitive so the config framework
// masks it in log/diagnostic output.  Because the config-layer masking is
// enforced at the framework level (not in pure Lyric), this file tests the
// observable consequences along two axes:
//
//   1. `InProcessSessionStore` produces error messages that never embed
//      a credential substring (defensive belt-and-suspenders check).
//   2. The pure `maskUrlCredentials` rewriter — the function the
//      Redis-backed `connectRedis()` routes kernel errors through —
//      strips the password component of a connection URL while leaving
//      every other component intact, across the URL shapes
//      StackExchange.Redis is known to surface.  Exercising the function
//      directly lets us verify the Redis URL path without standing up a
//      live Redis (#1071).

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
  match store.set("phantom-id", "key", "value") {
    case Ok(_) -> assertTrue(false, "set() on unknown id should fail")
    case Err(e) -> {
      assertTrue(not e.message.contains("s3cr3t"),
        "session error must not contain password substring: " + e.message)
      assertTrue(not e.message.contains("redis://:s3cr3t@127.0.0.1:56789/0"),
        "session error must not echo the full URL: " + e.message)
    }
  }
}

// ─── maskUrlCredentials: pure-function unit coverage (#1071) ─────────────────

test "maskUrlCredentials strips user:password from a Redis URL" {
  val masked = Session.maskUrlCredentials("redis://alice:s3cr3t@127.0.0.1:6379/0")
  assertEqual(masked, "redis://alice:***@127.0.0.1:6379/0",
    "user retained, password replaced with ***")
}

test "maskUrlCredentials strips password-only userinfo (StackExchange shape)" {
  // StackExchange.Redis allows `:password@host` (no username); the masker
  // must keep the literal colon so the userinfo round-trips structurally.
  val masked = Session.maskUrlCredentials("rediss://:s3cr3t@cluster.example.com:6380")
  assertEqual(masked, "rediss://:***@cluster.example.com:6380",
    "empty username retained, password masked")
}

test "maskUrlCredentials leaves credential-free URLs intact" {
  val masked = Session.maskUrlCredentials("redis://127.0.0.1:6379/0")
  assertEqual(masked, "redis://127.0.0.1:6379/0",
    "URL without userinfo round-trips byte-for-byte")
}

test "maskUrlCredentials leaves username-only URLs intact" {
  // `user@host` with no password has nothing to mask; the userinfo stays.
  val masked = Session.maskUrlCredentials("redis://alice@host:6379")
  assertEqual(masked, "redis://alice@host:6379",
    "userinfo without a colon is left untouched")
}

test "maskUrlCredentials does not confuse path-segment '@' for userinfo" {
  // The `@` after the path separator must NOT be treated as the userinfo
  // boundary — defensive against malformed URIs producing wrong masks.
  val masked = Session.maskUrlCredentials("redis://host:6379/foo@bar")
  assertEqual(masked, "redis://host:6379/foo@bar",
    "@ in path component is not interpreted as credential boundary")
}

test "maskUrlCredentials passes non-URL strings through unchanged" {
  // Defensive: arbitrary strings (e.g. plain hostnames, error messages
  // that incidentally embed credential-like substrings) must not be
  // mangled.  Only inputs containing `scheme://user:pass@...` get
  // rewritten.
  val masked = Session.maskUrlCredentials("just a normal error message")
  assertEqual(masked, "just a normal error message",
    "non-URL strings round-trip unchanged")
}

test "maskUrlCredentials handles password embedded with query / fragment" {
  // A `?` or `#` in the URL terminates the authority component just
  // like `/`.  The password before such a marker is still masked.
  val masked = Session.maskUrlCredentials("redis://u:p@host?abortConnect=false")
  assertEqual(masked, "redis://u:***@host?abortConnect=false",
    "query string after authority does not break masking")
}

test "maskUrlCredentials handles Unicode-bearing passwords" {
  // Sanity: passwords containing non-ASCII characters mask to the same
  // sentinel; UTF-8 round-trip is irrelevant because the password is
  // discarded.
  val masked = Session.maskUrlCredentials("redis://alice:pässwörd@host")
  assertEqual(masked, "redis://alice:***@host",
    "non-ASCII password masks identically")
}

test "session destroy errors (if any) do not embed url field value" {
  val store = Session.inMemory()
  // destroy() on a non-existent session is a no-op (Ok); only check if Err.
  match store.destroy("no-such-session") {
    case Ok(_) -> ()
    case Err(e) -> {
      assertTrue(not e.message.contains("s3cr3t"),
        "destroy error must not contain password: " + e.message)
      assertTrue(not e.code.contains("s3cr3t"),
        "destroy error code must not contain password: " + e.code)
    }
  }
}

test "session error codes do not embed url field value" {
  // Verify that error codes from session operations are fixed strings,
  // not constructed from config values (which could include credentials).
  val store = Session.inMemory()
  // load() on a nonexistent id returns Ok(None); only check Err if present.
  match store.load("nonexistent") {
    case Ok(_) -> ()
    case Err(e) -> {
      assertTrue(e.code.length > 0, "error code must be non-empty")
      assertTrue(not e.code.contains("s3cr3t"), "error code must not contain credential")
    }
  }
}
