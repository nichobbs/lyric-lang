//! tests/db_kernel_net_tests.l — direct tests for `Db.Kernel.Net`'s
//! connection-string construction (#5584, #5596). These exercise
//! `buildPgConnStr` and its `msToWholeSecondsRoundedUp` timeout helper
//! directly (no live Postgres server needed) rather than only through
//! `connectPostgres`'s connect-failure path.
@test_module
package Db.KernelNetTests

import Std.Core
import Std.Testing
import Db.Kernel.Net as DbKernel

// ─── Connection-string injection (#5584) ─────────────────────────────────────
// Before #5584, `buildPgConnStr` concatenated the password/host/database
// straight into the `Host=...;Password=...;...` text. A password containing
// `;` or `=` could break out into arbitrary connection options — e.g.
// `Password=sec;ret=1` naively concatenated as `...;Password=sec;ret=1;
// Timeout=5;...` parses as `Password=sec` plus a bogus `ret=1` option, not
// the literal password `sec;ret=1`. `NpgsqlConnectionStringBuilder` quotes
// the value instead, so round-tripping the built string back through the
// same builder must yield the password verbatim.
test "buildPgConnStr: a password containing ';' round-trips intact" {
  val connStr = DbKernel.buildPgConnStr("Host=localhost;Database=mydb;Username=appuser", 5, 3000, "sec;ret=1")
  assertEqual(DbKernel.pgConnStrExtractPassword(connStr), "sec;ret=1", "password with embedded ';' is not split")
}

test "buildPgConnStr: a password containing '=' round-trips intact" {
  val connStr = DbKernel.buildPgConnStr("Host=localhost;Database=mydb;Username=appuser", 5, 3000, "sec=et")
  assertEqual(DbKernel.pgConnStrExtractPassword(connStr), "sec=et", "password with embedded '=' is not split")
}

test "buildPgConnStr: a password containing both ';' and '=' round-trips intact" {
  val connStr = DbKernel.buildPgConnStr(
    "Host=localhost;Database=mydb;Username=appuser",
    5,
    3000,
    "a;b=c;Host=evil.example.com"
  )
  assertEqual(
    DbKernel.pgConnStrExtractPassword(connStr),
    "a;b=c;Host=evil.example.com",
    "password containing a fake 'Host=' segment does not override the real host"
  )
  assertEqual(
    DbKernel.pgConnStrExtractHost(connStr),
    "localhost",
    "the real Host keyword is untouched by the injected password"
  )
}

test "buildPgConnStr: a postgres:// URI with an injection-shaped password round-trips intact" {
  val connStr = DbKernel.buildPgConnStr("postgres://appuser:sec;ret=1@localhost:5432/mydb", 5, 3000, "")
  assertEqual(
    DbKernel.pgConnStrExtractPassword(connStr),
    "sec;ret=1",
    "URI-embedded password with ';'/'=' is not split"
  )
}

// ─── Sub-second connect timeout (#5596) ──────────────────────────────────────
// Npgsql's `Timeout` keyword is whole seconds and treats `Timeout=0` as
// **infinite**, not "immediate". A sub-second `connectTimeoutMs` (e.g. 100)
// must not truncate to 0 via plain integer division.
test "buildPgConnStr: a sub-second connectTimeoutMs does not become an infinite Npgsql timeout" {
  val connStr = DbKernel.buildPgConnStr("Host=localhost;Database=mydb;Username=appuser", 5, 100, "")
  assertTrue(
    DbKernel.pgConnStrExtractTimeoutSeconds(connStr) >= 1,
    "a positive sub-second connectTimeoutMs must map to at least 1 second, never 0 (infinite)"
  )
}

test "buildPgConnStr: a multi-second connectTimeoutMs rounds up to whole seconds" {
  val connStr = DbKernel.buildPgConnStr("Host=localhost;Database=mydb;Username=appuser", 5, 1500, "")
  assertEqualInt(DbKernel.pgConnStrExtractTimeoutSeconds(connStr), 2, "1500ms rounds up to 2s, never down to 1s")
}
