//! tests/db_sqlite_tests.l — end-to-end tests for the real ADO.NET-backed
//! `Db.Kernel.Net` rewrite (#5407), exercised against SQLite (`:memory:`),
//! which needs no external service and is fully verifiable in CI/sandboxes.
//!
//! Covers: connect, DDL, parameterised insert, typed value extraction
//! (Long / Double / String / Bool / NULL), affected-row counts,
//! transaction commit visibility / rollback invisibility, and SQL-error
//! mapping to a structured `DbError` rather than an unhandled panic.
@test_module
package Db.SqliteTests

import Std.Core
import Std.Testing
import Db

test "connectSqlite: opens an in-memory database" {
  match Db.connectSqlite("sqlite::memory:", 5000) {
    case Err(e) -> assertTrue(false, "connect failed: " + e.message)
    case Ok(conn) -> conn.close()
  }
}

test "SQLite: create table, parameterised insert, and typed value extraction" {
  match Db.connectSqlite("sqlite::memory:", 5000) {
    case Err(e) -> assertTrue(false, "connect failed: " + e.message)
    case Ok(conn) -> {
      match conn.execute("CREATE TABLE items (id INTEGER, name TEXT, price REAL, active BOOLEAN, note TEXT)", []) {
        case Err(e) -> assertTrue(false, "create table failed: " + e.message)
        case Ok(_) -> ()
      }

      match conn.execute("INSERT INTO items (id, name, price, active, note) VALUES (@p0, @p1, @p2, @p3, NULL)", ["1", "widget", "9.99", "1"]) {
        case Err(e) -> assertTrue(false, "insert failed: " + e.message)
        case Ok(affected) -> assertEqualInt(affected, 1, "one row inserted")
      }

      match conn.query("SELECT id, name, price, active, note FROM items WHERE id = @p0", ["1"]) {
        case Err(e) -> assertTrue(false, "query failed: " + e.message)
        case Ok(rows) -> {
          assertEqualInt(rows.length, 1, "one row returned")
          if rows.length == 1 {
            val row = rows[0]
            assertEqualLong(Db.getLong(row, "id"), 1i64, "id column (Long)")
            assertEqual(Db.dbGetString(row, "name"), "widget", "name column (String)")
            match Db.col(row, "price") {
              case DbValue.DbDouble(v) -> assertTrue(v > 9.98 and v < 10.0, "price column (Double)")
              case _ -> assertTrue(false, "expected DbDouble for price")
            }
            assertTrue(Db.getBool(row, "active"), "active column (Bool)")
            match Db.col(row, "note") {
              case DbValue.DbNull -> ()
              case _ -> assertTrue(false, "expected DbNull for note")
            }
          }
        }
      }
      conn.close()
    }
  }
}

test "SQLite: execute reports affected-row count on UPDATE" {
  match Db.connectSqlite("sqlite::memory:", 5000) {
    case Err(e) -> assertTrue(false, "connect failed: " + e.message)
    case Ok(conn) -> {
      val _ = conn.execute("CREATE TABLE counters (id INTEGER, n INTEGER)", [])
      val _ = conn.execute("INSERT INTO counters (id, n) VALUES (1, 0)", [])
      val _ = conn.execute("INSERT INTO counters (id, n) VALUES (2, 0)", [])
      match conn.execute("UPDATE counters SET n = @p0", ["5"]) {
        case Err(e) -> assertTrue(false, "update failed: " + e.message)
        case Ok(affected) -> assertEqualInt(affected, 2, "two rows updated")
      }
      conn.close()
    }
  }
}

test "SQLite: transaction commit makes writes visible" {
  match Db.connectSqlite("sqlite::memory:", 5000) {
    case Err(e) -> assertTrue(false, "connect failed: " + e.message)
    case Ok(conn) -> {
      val _ = conn.execute("CREATE TABLE tx_commit (id INTEGER)", [])
      match conn.transaction() {
        case Err(e) -> assertTrue(false, "begin tx failed: " + e.message)
        case Ok(tx) -> {
          match tx.execute("INSERT INTO tx_commit (id) VALUES (@p0)", ["42"]) {
            case Err(e) -> assertTrue(false, "tx insert failed: " + e.message)
            case Ok(_) -> ()
          }
          match tx.commit() {
            case Err(e) -> assertTrue(false, "commit failed: " + e.message)
            case Ok(_) -> ()
          }
        }
      }
      match conn.query("SELECT id FROM tx_commit", []) {
        case Err(e) -> assertTrue(false, "post-commit query failed: " + e.message)
        case Ok(rows) -> assertEqualInt(rows.length, 1, "committed row is visible")
      }
      conn.close()
    }
  }
}

test "SQLite: transaction rollback discards writes" {
  match Db.connectSqlite("sqlite::memory:", 5000) {
    case Err(e) -> assertTrue(false, "connect failed: " + e.message)
    case Ok(conn) -> {
      val _ = conn.execute("CREATE TABLE tx_rollback (id INTEGER)", [])
      match conn.transaction() {
        case Err(e) -> assertTrue(false, "begin tx failed: " + e.message)
        case Ok(tx) -> {
          match tx.execute("INSERT INTO tx_rollback (id) VALUES (@p0)", ["7"]) {
            case Err(e) -> assertTrue(false, "tx insert failed: " + e.message)
            case Ok(_) -> ()
          }
          match tx.rollback() {
            case Err(e) -> assertTrue(false, "rollback failed: " + e.message)
            case Ok(_) -> ()
          }
        }
      }
      match conn.query("SELECT id FROM tx_rollback", []) {
        case Err(e) -> assertTrue(false, "post-rollback query failed: " + e.message)
        case Ok(rows) -> assertEqualInt(rows.length, 0, "rolled-back row is not visible")
      }
      conn.close()
    }
  }
}

test "SQLite: malformed SQL maps to a QUERY_ERROR DbError, not a panic" {
  match Db.connectSqlite("sqlite::memory:", 5000) {
    case Err(e) -> assertTrue(false, "connect failed: " + e.message)
    case Ok(conn) -> {
      match conn.query("SELECT * FRUM nonexistent_table", []) {
        case Ok(_) -> assertTrue(false, "expected malformed SQL to fail")
        case Err(e) -> {
          assertEqual(e.code, "QUERY_ERROR", "error code")
          assertTrue(e.message.length > 0, "error message should be non-empty")
        }
      }
      conn.close()
    }
  }
}

test "SQLite: malformed SQL on execute maps to an EXECUTE_ERROR DbError, not a panic" {
  match Db.connectSqlite("sqlite::memory:", 5000) {
    case Err(e) -> assertTrue(false, "connect failed: " + e.message)
    case Ok(conn) -> {
      match conn.execute("INSRT INTO nonexistent_table VALUES (1)", []) {
        case Ok(_) -> assertTrue(false, "expected malformed SQL to fail")
        case Err(e) -> {
          assertEqual(e.code, "EXECUTE_ERROR", "error code")
          assertTrue(e.message.length > 0, "error message should be non-empty")
        }
      }
      conn.close()
    }
  }
}

test "SQLite: BLOB column round-trips through DbBytes" {
  match Db.connectSqlite("sqlite::memory:", 5000) {
    case Err(e) -> assertTrue(false, "connect failed: " + e.message)
    case Ok(conn) -> {
      val _ = conn.execute("CREATE TABLE blobs (id INTEGER, payload BLOB)", [])
      // SQLite has no bound-parameter path for raw bytes in this library's
      // String-only parameter API (#5407 scope); use a literal BLOB via
      // CAST so the read-side DbBytes/`$bytes` decoding is still exercised.
      val _ = conn.execute("INSERT INTO blobs (id, payload) VALUES (1, CAST('abc' AS BLOB))", [])
      match conn.query("SELECT payload FROM blobs WHERE id = 1", []) {
        case Err(e) -> assertTrue(false, "query failed: " + e.message)
        case Ok(rows) -> {
          assertEqualInt(rows.length, 1, "one row returned")
          if rows.length == 1 {
            match Db.col(rows[0], "payload") {
              case DbValue.DbBytes(bytes) -> assertEqualInt(bytes.length, 3, "payload byte length")
              case _ -> assertTrue(false, "expected DbBytes for payload")
            }
          }
        }
      }
      conn.close()
    }
  }
}
