//! tests/db_postgres_connect_tests.l — connect-failure mapping test for the
//! Npgsql-backed path of `Db.Kernel.Net` (#5407). No live PostgreSQL server
//! is available in CI/sandboxes, so this only verifies the structurally
//! correct, always-testable slice: connecting to a closed/refused TCP port
//! maps to a `CONNECT_ERROR` `DbError`, not an unhandled panic. Full
//! query/execute/transaction behaviour against Postgres shares the exact
//! same `System.Data.Common`-based code path already exercised end-to-end
//! against SQLite in `db_sqlite_tests.l` — see lyric-db/README.md "Platform
//! parity" for the honest scope of what is (and isn't) live-server-verified.
@test_module
package Db.PostgresConnectTests

import Std.Core
import Std.Testing
import Std.Environment
import Db

test "connectPostgres: connecting to a closed port returns CONNECT_ERROR, not a panic" {
  // Port 1 is a privileged TCP port with no listener in this sandbox, so
  // the OS refuses the connection (ECONNREFUSED) quickly and
  // deterministically without needing a real Postgres server anywhere on
  // the network.
  match Db.connectPostgres("postgres://baduser:badpass@127.0.0.1:1/nonexistent", 1, 500, "") {
    case Ok(conn) -> {
      conn.close()
      assertTrue(false, "expected connect failure against a closed port")
    }
    case Err(e) -> {
      assertEqual(e.code, "CONNECT_ERROR", "error code")
      assertTrue(e.message.length > 0, "error message should be non-empty")
    }
  }
}

test "connect: postgres:// DSN scheme dispatches to the Npgsql driver and fails the same way" {
  match Db.connect("postgres://baduser:badpass@127.0.0.1:1/nonexistent") {
    case Ok(conn) -> {
      conn.close()
      assertTrue(false, "expected connect failure against a closed port")
    }
    case Err(e) -> assertEqual(e.code, "CONNECT_ERROR", "error code")
  }
}

// #6359: `connectFromEnv` previously ignored `LYRIC_CONFIG_DB_CONNECTION_
// POOLSIZE`/`_CONNECTTIMEOUTMS`/`_PASSWORD` entirely (silently using
// connectDsn's hardcoded poolSize=10/connectTimeoutMs=5000/password="").
// These two cases exercise the env-var-driven path end to end (still
// against the same closed-port target, so no live server is needed) and
// specifically probe the out-of-range clamp: an unclamped POOLSIZE=0
// would violate connectPostgres's `requires: poolSize >= 1` and panic
// instead of returning a CONNECT_ERROR.
test "connectFromEnv: reads POOLSIZE/CONNECTTIMEOUTMS/PASSWORD and still fails cleanly against a closed port" {
  setVar("LYRIC_CONFIG_DB_CONNECTION_URL", "postgres://baduser:badpass@127.0.0.1:1/nonexistent")
  setVar("LYRIC_CONFIG_DB_CONNECTION_POOLSIZE", "5")
  setVar("LYRIC_CONFIG_DB_CONNECTION_CONNECTTIMEOUTMS", "500")
  setVar("LYRIC_CONFIG_DB_CONNECTION_PASSWORD", "override-pass")
  match Db.connectFromEnv() {
    case Ok(conn) -> {
      conn.close()
      assertTrue(false, "expected connect failure against a closed port")
    }
    case Err(e) -> assertEqual(e.code, "CONNECT_ERROR", "error code")
  }
}

test "connectFromEnv: an out-of-range POOLSIZE is clamped, not passed through to violate connectPostgres's contract" {
  setVar("LYRIC_CONFIG_DB_CONNECTION_URL", "postgres://baduser:badpass@127.0.0.1:1/nonexistent")
  setVar("LYRIC_CONFIG_DB_CONNECTION_POOLSIZE", "0")
  setVar("LYRIC_CONFIG_DB_CONNECTION_CONNECTTIMEOUTMS", "999999")
  match Db.connectFromEnv() {
    case Ok(conn) -> {
      conn.close()
      assertTrue(false, "expected connect failure against a closed port")
    }
    case Err(e) -> assertEqual(e.code, "CONNECT_ERROR", "error code")
  }
}

// connectFromEnv's scheme sniffing (postgres:// / postgresql:// / sqlite:// /
// sqlite::memory:) is now duplicated in db.l rather than delegated to
// Db.Kernel.Net.connectDsn (needed so the env-var-read poolSize/
// connectTimeoutMs/password can flow into the right branch) — these two
// cases pin the sqlite:: and unrecognized-scheme branches so the
// duplication can't silently drift from connectDsn's behaviour.
test "connectFromEnv: sqlite::memory: scheme dispatches to the SQLite driver and succeeds" {
  setVar("LYRIC_CONFIG_DB_CONNECTION_URL", "sqlite::memory:")
  match Db.connectFromEnv() {
    case Err(e) -> assertTrue(false, "connect failed: " + e.message)
    case Ok(conn) -> conn.close()
  }
}

test "connectFromEnv: an unrecognized DSN scheme returns a CONFIG_ERROR, not a panic" {
  setVar("LYRIC_CONFIG_DB_CONNECTION_URL", "mysql://user:pass@127.0.0.1:3306/db")
  match Db.connectFromEnv() {
    case Ok(conn) -> {
      conn.close()
      assertTrue(false, "expected an unrecognized-scheme error")
    }
    case Err(e) -> {
      assertEqual(e.code, "CONFIG_ERROR", "error code")
      assertTrue(e.message.length > 0, "error message should be non-empty")
    }
  }
}
