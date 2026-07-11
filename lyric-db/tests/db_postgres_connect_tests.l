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
