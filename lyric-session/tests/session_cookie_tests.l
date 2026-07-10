//! tests/session_cookie_tests.l — regression suite for `SessionConfig` /
//! `sessionConfigFromEnv()` / `cookieHeader()` (review finding: the README
//! and module doc comment documented secure cookie defaults — `secure`,
//! `httpOnly`, `sameSite` — and their env vars, but no `SessionConfig` type
//! or `Set-Cookie` construction existed anywhere in the library. This file
//! exercises the real implementation that closes that gap.
@test_module
package Session.SessionCookieTests

import Std.Core
import Std.Testing
import Session as Session

test "cookieHeader emits Secure, HttpOnly, and SameSite with the secure defaults" {
  val cfg = Session.SessionConfig(
    cookieName = "LYRIC_SESSION",
    secure = true,
    httpOnly = true,
    sameSite = "Lax",
    ttlSeconds = 3600
  )
  val header = Session.cookieHeader("abc123", cfg)
  assertEqual(header, "LYRIC_SESSION=abc123; Path=/; HttpOnly; Secure; SameSite=Lax", "default-config Set-Cookie value")
}

test "cookieHeader honors a custom cookie name and sameSite policy" {
  val cfg = Session.SessionConfig(
    cookieName = "_myapp_session",
    secure = true,
    httpOnly = true,
    sameSite = "Strict",
    ttlSeconds = 1800
  )
  val header = Session.cookieHeader("sess-42", cfg)
  assertTrue(header.startsWith("_myapp_session=sess-42; Path=/"), "custom cookie name used as the header key")
  assertTrue(header.contains("SameSite=Strict"), "custom sameSite policy carried through")
}

test "cookieHeader omits HttpOnly and Secure when disabled in config" {
  val cfg = Session.SessionConfig(
    cookieName = "LYRIC_SESSION",
    secure = false,
    httpOnly = false,
    sameSite = "None",
    ttlSeconds = 3600
  )
  val header = Session.cookieHeader("xyz", cfg)
  assertFalse(header.contains("HttpOnly"), "HttpOnly must not appear when httpOnly = false")
  assertFalse(header.contains("Secure"), "Secure must not appear when secure = false")
  assertTrue(header.contains("SameSite=None"), "SameSite is always present regardless of secure/httpOnly")
}

test "cookieHeader always includes Path=/" {
  val cfg = Session.SessionConfig(cookieName = "s", secure = false, httpOnly = false, sameSite = "Lax", ttlSeconds = 60)
  val header = Session.cookieHeader("id1", cfg)
  assertTrue(header.contains("Path=/"), "Path=/ must always be present")
}

test "sessionConfigFromEnv falls back to secure-by-default values with no env vars set" {
  // CI does not set LYRIC_CONFIG_SESSION_SESSION_* for this suite, so this
  // exercises the fail-soft defaults documented on SessionConfig.
  val cfg = Session.sessionConfigFromEnv()
  assertEqual(cfg.cookieName, "LYRIC_SESSION", "default cookie name")
  assertTrue(cfg.secure, "default secure = true")
  assertTrue(cfg.httpOnly, "default httpOnly = true")
  assertEqual(cfg.sameSite, "Lax", "default sameSite = Lax")
  assertEqualInt(cfg.ttlSeconds, 3600, "default ttlSeconds = 3600")
}

test "sessionConfigFromEnv result round-trips through cookieHeader with secure defaults intact" {
  val cfg = Session.sessionConfigFromEnv()
  val header = Session.cookieHeader("session-id-1", cfg)
  assertTrue(header.contains("HttpOnly"), "env-sourced config still yields HttpOnly by default")
  assertTrue(header.contains("Secure"), "env-sourced config still yields Secure by default")
  assertTrue(header.contains("SameSite=Lax"), "env-sourced config still yields SameSite=Lax by default")
}
