//! cli_publish_self_test.l — exercises the pure NU1102 retry/backoff
//! decision helpers in `Lyric.Cli` (cli/cli_shared.l): `shouldRetryRestore`
//! and `backoffMsForAttempt`. These back `runRestoreWithRetry`, which wraps
//! the `dotnet restore` call in `lyric restore` (cli_restore.l) with
//! retry-on-NU1102 logic. (`lyric publish` no longer restores at all: since
//! #5644 it packs from a hand-authored `.nuspec`, so the retry path is
//! restore-only.) The decision logic itself does no I/O and no process
//! spawning, so it can be exercised directly without a network connection or
//! a real `dotnet` invocation (#5239).
//!
//! Also covers the pure `buildPublishNuspec` (cli/cli_publish.l), the #5644
//! nuspec-generation helper, including a regression guard that its output
//! never emits `<PackageReference>` (the retired mechanism that caused the
//! NU1102 ecosystem-publish race).
//!
//! The schedule constants are asserted as literals (8 attempts, 30s base,
//! 4-attempt ramp, 120s plateau) rather than via `Cli.nu1102MaxAttempts`
//! etc.: reading a cross-package `pub val` through the restored-DLL
//! boundary this test links against miscompiles today
//! (InvalidProgramException; #5275). When #5275 is fixed these can switch
//! to the symbolic form.
//!
//! Run in CI via:
//!
//!   lyric test lyric-compiler/lyric/cli_publish_self_test.l
@test_module
package Lyric.CliPublishSelfTest

import Std.Core
import Std.Testing
import Lyric.Cli as Cli

// ─── shouldRetryRestore: NU1102 retries through the max attempt ──────────
test "shouldRetryRestore: NU1102 in stdout retries on attempt 1" {
  assertTrue(
    Cli.shouldRetryRestore(1, "error NU1102: unable to find package", "", 1, false),
    "NU1102 in stdout on attempt 1 should retry"
  )
}

test "shouldRetryRestore: NU1102 in stderr retries on attempt 1" {
  assertTrue(
    Cli.shouldRetryRestore(1, "", "error NU1102: unable to find package", 1, false),
    "NU1102 in stderr on attempt 1 should retry"
  )
}

test "shouldRetryRestore: NU1102 retries through the last attempt before the max" {
  assertTrue(
    Cli.shouldRetryRestore(1, "NU1102", "", 7, false),
    "NU1102 on attempt 7 (nu1102MaxAttempts - 1) should still retry"
  )
}

test "shouldRetryRestore: NU1102 does not retry once nu1102MaxAttempts is reached" {
  assertFalse(
    Cli.shouldRetryRestore(1, "NU1102", "", 8, false),
    "NU1102 on the final attempt (nu1102MaxAttempts = 8) must not retry"
  )
}

// ─── shouldRetryRestore: non-NU1102 / success / timeout never retry ──────
test "shouldRetryRestore: unrelated restore failure never retries" {
  assertFalse(
    Cli.shouldRetryRestore(1, "error NU1000: some other failure", "", 1, false),
    "a non-NU1102 failure must not retry even on the first attempt"
  )
}

test "shouldRetryRestore: success (exit code 0) never retries" {
  assertFalse(
    Cli.shouldRetryRestore(0, "NU1102", "", 1, false),
    "an exit code of 0 must not retry even if NU1102 text is present"
  )
}

test "shouldRetryRestore: a timed-out attempt never retries, even with NU1102 present" {
  assertFalse(Cli.shouldRetryRestore(1, "NU1102", "", 1, true), "a timed-out attempt must not retry")
}

// ─── backoffMsForAttempt: escalation then plateau ─────────────────────────
test "backoffMsForAttempt: escalates by nu1102BaseBackoffMs per attempt through nu1102EscalationAttempts" {
  assertEqualInt(Cli.backoffMsForAttempt(1), 30000, "attempt 1 backoff")
  assertEqualInt(Cli.backoffMsForAttempt(2), 60000, "attempt 2 backoff")
  assertEqualInt(Cli.backoffMsForAttempt(3), 90000, "attempt 3 backoff")
  assertEqualInt(Cli.backoffMsForAttempt(4), 120000, "attempt 4 (nu1102EscalationAttempts) backoff (top of the ramp)")
}

test "backoffMsForAttempt: holds flat at nu1102PlateauBackoffMs past nu1102EscalationAttempts" {
  assertEqualInt(Cli.backoffMsForAttempt(5), 120000, "attempt 5 (nu1102EscalationAttempts + 1) backoff (plateau)")
  assertEqualInt(Cli.backoffMsForAttempt(8), 120000, "final attempt backoff (still plateau)")
}

test "backoffMsForAttempt: plateau equals the top of the escalation ramp" {
  assertEqualInt(
    Cli.backoffMsForAttempt(5),
    Cli.backoffMsForAttempt(4),
    "plateau backoff must equal the top of the escalation ramp"
  )
}

// ─── restoreArgsForAttempt: first attempt cached, retries bypass HTTP cache ──
// The NU1102 retry (runRestoreWithRetry) was firing but never succeeding: the
// first attempt's "package not found" response was served from dotnet's HTTP
// cache on every retry, so a sibling package nuget.org had since indexed was
// never observed and a fresh job rerun was needed (#5644).  Retries now pass
// --no-http-cache; the first attempt stays cached/fast.
test "restoreArgsForAttempt: first attempt uses base args unchanged" {
  val base: List[String] = newList()
  base.add("restore")
  base.add("Foo.csproj")
  val got = Cli.restoreArgsForAttempt(base, 1)
  assertEqualInt(got.count, 2, "attempt 1 must not add flags")
  assertFalse(stringsContain(got, "--no-http-cache"), "attempt 1 keeps the HTTP cache")
}

test "restoreArgsForAttempt: a retry appends --no-http-cache" {
  val base: List[String] = newList()
  base.add("restore")
  base.add("Foo.csproj")
  val got = Cli.restoreArgsForAttempt(base, 2)
  assertEqualInt(got.count, 3, "a retry adds exactly one flag")
  assertTrue(stringsContain(got, "--no-http-cache"), "a retry must bypass the HTTP cache")
  assertTrue(stringsContain(got, "restore"), "base args are preserved")
  assertTrue(stringsContain(got, "Foo.csproj"), "base args are preserved")
}

test "restoreArgsForAttempt: never double-adds --no-http-cache" {
  val base: List[String] = newList()
  base.add("restore")
  base.add("--no-http-cache")
  val got = Cli.restoreArgsForAttempt(base, 3)
  var count = 0
  var i = 0
  while i < got.count {
    if got[i] == "--no-http-cache" {
      count = count + 1
    }
    i = i + 1
  }
  assertEqualInt(count, 1, "--no-http-cache appears exactly once even if already present")
}

func stringsContain(xs: in List[String], s: in String): Bool {
  var i = 0
  while i < xs.count {
    if xs[i] == s {
      return true
    }
    i = i + 1
  }
  false
}

// ─── buildPublishNuspec: deps are metadata, not restorable PackageReferences ──
// The ecosystem-publish NU1102 race (#5644) came from packing a csproj whose
// sibling deps were <PackageReference> (restored from nuget.org before it had
// indexed the just-published sibling).  buildPublishNuspec emits deps as
// <dependency> metadata packed offline instead.
test "buildPublishNuspec: emits a dependency as nuspec metadata, never a PackageReference" {
  val deps = "        <dependency id=\"Lyric.Proto\" version=\"1.2.3\" />\n"
  val ns = Cli.buildPublishNuspec(
    "Lyric.OTel",
    "1.2.3",
    noAuthors(),
    "OTel exporters",
    "MIT",
    None,
    deps,
    "/abs/Lyric.OTel.dll",
    "Lyric.OTel.dll"
  )
  assertTrue(
    strContains(ns, "<dependency id=\"Lyric.Proto\" version=\"1.2.3\" />"),
    "dep appears as <dependency> metadata"
  )
  assertTrue(strContains(ns, "<dependencies>"), "dependencies group is emitted")
  assertFalse(
    strContains(ns, "PackageReference"),
    "must NOT use <PackageReference> (that would require a restore, #5644)"
  )
}

test "buildPublishNuspec: packs the payload DLL into lib/net10.0 and carries id/version" {
  val ns = Cli.buildPublishNuspec(
    "Lyric.OTel",
    "1.2.3",
    noAuthors(),
    "OTel exporters",
    "MIT",
    None,
    "",
    "/abs/Lyric.OTel.dll",
    "Lyric.OTel.dll"
  )
  assertTrue(strContains(ns, "<id>Lyric.OTel</id>"), "id present")
  assertTrue(strContains(ns, "<version>1.2.3</version>"), "version present")
  assertTrue(
    strContains(ns, "<file src=\"/abs/Lyric.OTel.dll\" target=\"lib/net10.0/Lyric.OTel.dll\" />"),
    "payload DLL mapped into lib/net10.0"
  )
  assertFalse(strContains(ns, "<dependencies>"), "no dependencies block when there are no deps")
}

test "buildPublishNuspec: description falls back to the id when empty (NuGet requires one)" {
  val ns = Cli.buildPublishNuspec(
    "Lyric.Proto",
    "0.1.0",
    noAuthors(),
    "",
    "",
    None,
    "",
    "/abs/Lyric.Proto.dll",
    "Lyric.Proto.dll"
  )
  assertTrue(strContains(ns, "<description>Lyric.Proto</description>"), "empty description falls back to the id")
  assertFalse(strContains(ns, "<license"), "no license element when license is empty")
  assertTrue(strContains(ns, "<authors>Lyric.Proto</authors>"), "empty authors falls back to the id")
}

// XML metacharacters in any field must be escaped so the emitted .nuspec stays
// well-formed and dotnet pack does not choke (a git-ref-derived version or a
// description with `&`/`<`/`"` is the realistic trigger).
test "buildPublishNuspec: escapes XML metacharacters in its own fields" {
  val ns = Cli.buildPublishNuspec(
    "A&B",
    "1.0-<rc>",
    noAuthors(),
    "desc \"q\" & <tag>",
    "MIT & Apache",
    Some(value = "https://ex.com/?a=1&b=2"),
    "",
    "/abs/A&B.dll",
    "A&B.dll"
  )
  assertTrue(strContains(ns, "<id>A&amp;B</id>"), "id ampersand escaped")
  assertTrue(strContains(ns, "<version>1.0-&lt;rc&gt;</version>"), "version angle brackets escaped")
  assertTrue(strContains(ns, "<description>desc &quot;q&quot; &amp; &lt;tag&gt;</description>"), "description escaped")
  assertTrue(strContains(ns, "MIT &amp; Apache"), "license ampersand escaped")
  assertTrue(strContains(ns, "url=\"https://ex.com/?a=1&amp;b=2\""), "repository url ampersand escaped")
  assertTrue(
    strContains(ns, "<repository type=\"git\" url=\"https://ex.com/?a=1&amp;b=2\" />"),
    "repository element declares type=\"git\" (#5685 — all ecosystem manifests are git-hosted)"
  )
  assertTrue(strContains(ns, "target=\"lib/net10.0/A&amp;B.dll\""), "dll basename escaped")
  assertFalse(strContains(ns, "<id>A&B</id>"), "raw unescaped ampersand never appears in id")
}

// The manifest's [package] authors must reach the nuspec <authors> element as a
// comma-separated, XML-escaped list — not be silently replaced by the id (#5683).
test "buildPublishNuspec: emits manifest authors as a comma-separated escaped list" {
  val authors: List[String] = newList()
  authors.add("Alice Example")
  authors.add("Bob & Co")
  val ns = Cli.buildPublishNuspec(
    "Lyric.OTel",
    "1.2.3",
    authors,
    "OTel exporters",
    "MIT",
    None,
    "",
    "/abs/Lyric.OTel.dll",
    "Lyric.OTel.dll"
  )
  assertTrue(
    strContains(ns, "<authors>Alice Example, Bob &amp; Co</authors>"),
    "authors joined by comma, escaped, not replaced by the id"
  )
  assertFalse(strContains(ns, "<authors>Lyric.OTel</authors>"), "id is not used when authors are declared")
}

func strContains(haystack: in String, needle: in String): Bool {
  haystack.contains(needle)
}

func noAuthors(): List[String] {
  newList()
}
