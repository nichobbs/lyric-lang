/// Db — driver-agnostic database access with typed rows and transactions.
///
/// `DbConnection` is the public interface; implement it to add a new driver.
/// Two built-in drivers are provided via feature-gated kernel packages:
///
///   Db.connectPostgres()  (@cfg feature = "postgres")  — Npgsql / PostgreSQL
///   Db.connectSqlite()    (@cfg feature = "sqlite")    — Microsoft.Data.Sqlite
///
/// Usage:
///
///   import Db
///
///   val conn = Db.connectPostgres()?
///   match conn.query("SELECT id, name FROM users WHERE id = $1", ["42"]) {
///     case Ok(rows) ->
///       for row in rows {
///         match Db.col(row, "name") {
///           case DbValue.DbText(name) -> println(name)
///           case _                   -> ()
///         }
///       }
///     case Err(e) -> Err(Web.internalError(e.message))
///   }
///   conn.close()
///
/// Runtime config env vars (LYRIC_CONFIG_DB_CONNECTION_*):
///   LYRIC_CONFIG_DB_CONNECTION_URL            — connection URL (required)
///   LYRIC_CONFIG_DB_CONNECTION_POOLSIZE       — pool size (default: 10)
///   LYRIC_CONFIG_DB_CONNECTION_CONNECTTIMEOUTMS — connect timeout (default: 5000)
///   LYRIC_CONFIG_DB_CONNECTION_QUERYTIMEOUTMS   — query timeout  (default: 30000)
///   LYRIC_CONFIG_DB_CONNECTION_PASSWORD         — password override (default: "")
///
/// See docs/03-decision-log.md D056 and lyric-db/README.md.

@runtime_checked
package Db

import Std.Core
import Db.Kernel.Net as DbKernel

// ─── Error ────────────────────────────────────────────────────────────────────

/// A database error with a driver-reported code and message.
@stable(since="0.1")
pub record DbError {
  message: String
  code:    String    // driver-specific error code (e.g. "23505" for PG unique violation)
}

// ─── Row value type ───────────────────────────────────────────────────────────

/// A column value returned by a query.  Pattern-match to extract a typed value.
@stable(since="0.1")
pub enum DbValue {
  case DbNull
  case DbInt(value: Int)
  case DbLong(value: Long)
  case DbFloat(value: Float)
  case DbDouble(value: Double)
  case DbBool(value: Bool)
  case DbText(value: String)
  case DbBytes(value: [Byte])
}

/// A single query result row: an ordered list of (columnName, value) pairs.
@stable(since="0.1")
pub record DbRow {
  columns: [(String, DbValue)]
}

/// Extract a column value from a row by name.
/// Returns `DbValue.DbNull` if the column is not found.
@stable(since="0.1")
pub func col(row: in DbRow, name: in String): DbValue
  requires: name.length > 0
{
  for (k, v) in row.columns {
    if k == name { return v }
  }
  return DbValue.DbNull
}

// ─── Transaction interface ────────────────────────────────────────────────────

/// An in-flight database transaction.  Call `commit()` or `rollback()` to
/// finish; the transaction is rolled back automatically on connection close
/// if neither is called.
@stable(since="0.1")
pub interface DbTransaction {
  /// Execute a parameterised query and return the result rows.
  func query(sql: in String, params: in [String]): Result[[DbRow], DbError]
    requires: sql.length > 0

  /// Execute a parameterised DML statement and return the affected-row count.
  func execute(sql: in String, params: in [String]): Result[Int, DbError]
    requires: sql.length > 0

  /// Commit the transaction.
  func commit(): Result[Unit, DbError]

  /// Roll back the transaction.
  func rollback(): Result[Unit, DbError]
}

// ─── Connection interface ─────────────────────────────────────────────────────

/// A database connection.  Obtain one via `Db.connectPostgres()` or
/// `Db.connectSqlite()`.  Close it with `conn.close()` when done; or inject
/// it through a wire block scoped to the request lifetime.
@stable(since="0.1")
pub interface DbConnection {
  /// Execute a parameterised SELECT and return the result rows.
  func query(sql: in String, params: in [String]): Result[[DbRow], DbError]
    requires: sql.length > 0

  /// Execute a parameterised INSERT / UPDATE / DELETE and return the
  /// number of affected rows.
  func execute(sql: in String, params: in [String]): Result[Int, DbError]
    requires: sql.length > 0

  /// Begin an explicit transaction.
  func transaction(): Result[DbTransaction, DbError]

  /// Return this connection to the pool.
  func close(): Unit
}

// ─── Native connection wrapper (internal) ────────────────────────────────────

// Integer handle issued by the kernel; opaque to consumers.
record NativeConnection { connId: Int }

impl DbConnection for NativeConnection {
  func query(sql: in String, params: in [String]): Result[[DbRow], DbError] {
    match DbKernel.query(connId, sql, params) {
      case Ok(jsonRows) -> parseRows(jsonRows)
      case Err(msg)     -> Err(DbError(message = msg, code = "QUERY_ERROR"))
    }
  }

  func execute(sql: in String, params: in [String]): Result[Int, DbError] {
    match DbKernel.execute(connId, sql, params) {
      case Ok(n)    -> Ok(n)
      case Err(msg) -> Err(DbError(message = msg, code = "EXECUTE_ERROR"))
    }
  }

  func transaction(): Result[DbTransaction, DbError] {
    match DbKernel.beginTransaction(connId) {
      case Ok(txId) -> Ok(NativeTransaction(txId = txId))
      case Err(msg) -> Err(DbError(message = msg, code = "TX_BEGIN_ERROR"))
    }
  }

  func close(): Unit {
    DbKernel.close(connId)
  }
}

record NativeTransaction { txId: Int }

impl DbTransaction for NativeTransaction {
  func query(sql: in String, params: in [String]): Result[[DbRow], DbError] {
    match DbKernel.txQuery(txId, sql, params) {
      case Ok(jsonRows) -> parseRows(jsonRows)
      case Err(msg)     -> Err(DbError(message = msg, code = "TX_QUERY_ERROR"))
    }
  }

  func execute(sql: in String, params: in [String]): Result[Int, DbError] {
    match DbKernel.txExecute(txId, sql, params) {
      case Ok(n)    -> Ok(n)
      case Err(msg) -> Err(DbError(message = msg, code = "TX_EXECUTE_ERROR"))
    }
  }

  func commit(): Result[Unit, DbError] {
    match DbKernel.commitTransaction(txId) {
      case Ok(_)    -> Ok(())
      case Err(msg) -> Err(DbError(message = msg, code = "TX_COMMIT_ERROR"))
    }
  }

  func rollback(): Result[Unit, DbError] {
    match DbKernel.rollbackTransaction(txId) {
      case Ok(_)    -> Ok(())
      case Err(msg) -> Err(DbError(message = msg, code = "TX_ROLLBACK_ERROR"))
    }
  }
}

// ─── Config ───────────────────────────────────────────────────────────────────

/// Connection pool and timeout settings.
config Connection {
  url:               String                              // required
  poolSize:          Int range 1 ..= 100   = 10
  connectTimeoutMs:  Int range 100 ..= 30000 = 5000
  queryTimeoutMs:    Int range 100 ..= 300000 = 30000
  @sensitive
  password:          String = ""    // optional override; "" = password in URL
}

// ─── Factory functions ────────────────────────────────────────────────────────

/// Open a connection to a PostgreSQL database using the configured URL.
/// Requires the `postgres` feature to be active (`[features] postgres = []`).
@stable(since="0.1")
@cfg(feature = "postgres")
pub func connectPostgres(): Result[DbConnection, DbError] {
  match DbKernel.Postgres.connect(
    Connection.url, Connection.poolSize,
    Connection.connectTimeoutMs, Connection.password)
  {
    case Ok(connId) -> Ok(NativeConnection(connId = connId))
    case Err(msg)   -> Err(DbError(message = msg, code = "CONNECT_ERROR"))
  }
}

/// Open a connection to a SQLite database file using the configured URL.
/// Requires the `sqlite` feature to be active (`[features] sqlite = []`).
@stable(since="0.1")
@cfg(feature = "sqlite")
pub func connectSqlite(): Result[DbConnection, DbError] {
  match DbKernel.Sqlite.connect(Connection.url, Connection.connectTimeoutMs) {
    case Ok(connId) -> Ok(NativeConnection(connId = connId))
    case Err(msg)   -> Err(DbError(message = msg, code = "CONNECT_ERROR"))
  }
}

// ─── Private helpers ──────────────────────────────────────────────────────────

// Parse a JSON array of objects (kernel-serialised rows) into [DbRow].
// Format: [{"col1":"val1","col2":"val2",...}, ...]
// All values arrive as strings; numeric/bool parsing is left to the consumer.
func parseRows(json: in String): Result[[DbRow], DbError] {
  // TODO: implement JSON → [DbRow] parsing using Std.Json once
  //       the kernel serialisation format is finalised (v1 milestone).
  //       Returns an empty slice in the stub; the kernel will be responsible
  //       for encoding rows as JSON before this function is called.
  return Ok([])
}
