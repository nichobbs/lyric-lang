/// Db — driver-agnostic database access with typed rows and transactions.
///
/// `DbConnection` is the public interface; implement it to add a new driver.
/// Two built-in drivers are provided via feature-gated kernel packages:
///
/// Convenience wrappers (added for gRPC / non-web consumers):
///   Db.connect(connStr)      — open a connection from an explicit DSN
///   Db.query(conn, sql, p)   — call conn.query; top-level wrapper
///   Db.execute(conn, sql, p) — call conn.execute; top-level wrapper
///   Db.getString/getInt/getLong/getBool — typed column extractors
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
import Std.Json
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
///
/// `DbDecimal` carries exact decimal text (e.g. `"123.456"`) from the driver;
/// use `Std.String.parseDouble` or a decimal library for arithmetic.
/// `DbDateTime` carries an ISO 8601 UTC timestamp string from the driver.
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
  case DbDecimal(value: String)   // exact decimal text; tagged {"$decimal":"..."} on wire
  case DbDateTime(value: String)  // ISO 8601 UTC; tagged {"$datetime":"..."} on wire
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

/// Execute a parameterised SELECT and return the first row, or None if no rows match.
///
/// Intended for PostgreSQL `SELECT … FOR UPDATE SKIP LOCKED` job-claim patterns:
///
///   match Db.queryOne(conn,
///     "SELECT id, payload FROM jobs WHERE status = $1
///      ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED",
///     ["pending"]) { ... }
///
/// Callers are responsible for including the `LIMIT 1` clause to bound the scan.
@stable(since="0.1")
pub func queryOne(conn: in DbConnection, sql: in String, params: in [String]): Result[Option[DbRow], DbError]
  requires: sql.length > 0
{
  match conn.query(sql, params) {
    case Err(e)   -> Err(e)
    case Ok(rows) -> {
      for row in rows {
        return Ok(Some(value = row))
      }
      Ok(None)
    }
  }
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

// Parse the kernel's JSON wire format into a typed row list.
//
// Wire format: [{"col": <json_value>, ...}, ...]
//   JSON null            → DbNull
//   JSON integer         → DbInt (if fits Int32) else DbLong
//   JSON float           → DbDouble
//   JSON bool            → DbBool
//   JSON string          → DbText
//   JSON {"$decimal":"…"} → DbDecimal  (exact decimal text, avoids float rounding)
//   JSON {"$datetime":"…"} → DbDateTime (ISO 8601 UTC string from driver)
//
// JsonValueKind ordinals: 0=Undefined 1=Object 2=Array 3=String 4=Number 5=True 6=False 7=Null
func parseRows(json: in String): Result[[DbRow], DbError] {
  val doc  = Std.Json.parseJson(json)
  val root = Std.Json.rootElement(doc)
  if Std.Json.valueKind(root) != 2 {
    return Err(DbError(message = "expected JSON array from query", code = "PARSE_ERROR"))
  }
  var rows: [DbRow] = []
  var arrEn = Std.Json.enumerateArray(root)
  while Std.Json.arrayMoveNext(arrEn) {
    val rowElem = Std.Json.arrayCurrent(arrEn)
    if Std.Json.valueKind(rowElem) != 1 {
      return Err(DbError(message = "expected JSON object for each row", code = "PARSE_ERROR"))
    }
    var cols: [(String, DbValue)] = []
    var objEn = Std.Json.enumerateObject(rowElem)
    while Std.Json.objectMoveNext(objEn) {
      val prop    = Std.Json.objectCurrent(objEn)
      val colName = Std.Json.propertyName(prop)
      val rawVal  = Std.Json.getRawText(Std.Json.propertyValue(prop))
      cols = cols + [(colName, parseDbValue(rawVal))]
    }
    rows = rows + [DbRow(columns = cols)]
  }
  return Ok(rows)
}

// Decode a single JSON value (as raw text) to a DbValue.
// Re-parses the raw text so JsonElement does not escape this module.
func parseDbValue(raw: in String): DbValue {
  val doc  = Std.Json.parseJson(raw)
  val elem = Std.Json.rootElement(doc)
  val kind = Std.Json.valueKind(elem)
  match kind {
    case 7 -> DbValue.DbNull
    case 5 -> DbValue.DbBool(value = true)
    case 6 -> DbValue.DbBool(value = false)
    case 3 -> DbValue.DbText(value = Std.Json.getString(elem))
    case 4 -> {
      match Std.Json.tryGetInt(elem) {
        case Some(i) -> DbValue.DbInt(value = i)
        case None ->
          match Std.Json.tryGetLong(elem) {
            case Some(l) -> DbValue.DbLong(value = l)
            case None    -> DbValue.DbDouble(value = Std.Json.getDouble(elem))
          }
      }
    }
    case 1 -> {
      match Std.Json.tryGetProperty(elem, "$decimal") {
        case Some(v) -> DbValue.DbDecimal(value = Std.Json.getString(v))
        case None ->
          match Std.Json.tryGetProperty(elem, "$datetime") {
            case Some(v) -> DbValue.DbDateTime(value = Std.Json.getString(v))
            case None    -> DbValue.DbNull
          }
      }
    }
    case _ -> DbValue.DbNull
  }
}

// ─── Convenience wrappers ─────────────────────────────────────────────────────

/// Open a connection from an explicit connection-string DSN.
/// Detects the driver from the DSN scheme: `postgres://` / `postgresql://`
/// uses the Postgres driver; `sqlite://` uses SQLite.  Falls back to the
/// configured Connection.url driver when scheme is unrecognised.
@stable(since="0.1")
pub func connect(connStr: in String): Result[DbConnection, DbError]
  requires: connStr.length > 0
{
  match DbKernel.connectDsn(connStr) {
    case Ok(connId) -> Ok(NativeConnection(connId = connId))
    case Err(msg)   -> Err(DbError(message = msg, code = "CONNECT_ERROR"))
  }
}

/// Top-level wrapper for conn.query — avoids UFCS syntax in callers that
/// hold a DbConnection value (not a concrete NativeConnection).
@stable(since="0.1")
pub func query(conn: in DbConnection, sql: in String, params: in [String]): Result[[DbRow], DbError]
  requires: sql.length > 0
{
  return conn.query(sql, params)
}

/// Top-level wrapper for conn.execute.
@stable(since="0.1")
pub func execute(conn: in DbConnection, sql: in String, params: in [String]): Result[Int, DbError]
  requires: sql.length > 0
{
  return conn.execute(sql, params)
}

// ─── Typed column extractors ──────────────────────────────────────────────────

/// Extract a String column value.  Returns "" for NULL or non-text values.
@stable(since="0.1")
pub func getString(row: in DbRow, name: in String): String
  requires: name.length > 0
{
  match col(row, name) {
    case DbText(value = v)     -> return v
    case DbDateTime(value = v) -> return v
    case DbDecimal(value = v)  -> return v
    case _                     -> return ""
  }
}

/// Extract an Int column value.  Returns 0 for NULL or non-integer values.
/// Use getLong for columns that may hold values outside Int32 range.
@stable(since="0.1")
pub func getInt(row: in DbRow, name: in String): Int
  requires: name.length > 0
{
  match col(row, name) {
    case DbInt(value = v) -> return v
    case _                -> return 0
  }
}

/// Extract a Long column value.  Returns 0L for NULL or non-integer values.
@stable(since="0.1")
pub func getLong(row: in DbRow, name: in String): Long
  requires: name.length > 0
{
  match col(row, name) {
    case DbLong(value = v) -> return v
    case DbInt(value = v)  -> return v.toLong()
    case _                 -> return 0L
  }
}

/// Extract a Bool column value.  Returns false for NULL or non-boolean values.
@stable(since="0.1")
pub func getBool(row: in DbRow, name: in String): Bool
  requires: name.length > 0
{
  match col(row, name) {
    case DbBool(value = v) -> return v
    case DbText(value = v) -> return v == "true" || v == "t" || v == "1"
    case DbInt(value = v)  -> return v != 0
    case _                 -> return false
  }
}

// ─── Option-returning extractors (NULL-safe) ──────────────────────────────────
// Use these when NULL is a meaningful value distinct from a zero/empty default.

/// Extract a String column value.  Returns None for NULL; Some(v) for any text value.
@stable(since="0.1")
pub func getStringOpt(row: in DbRow, name: in String): Option[String]
  requires: name.length > 0
{
  match col(row, name) {
    case DbNull            -> return None
    case DbText(value = v)     -> return Some(value = v)
    case DbDateTime(value = v) -> return Some(value = v)
    case DbDecimal(value = v)  -> return Some(value = v)
    case _                     -> return None
  }
}

/// Extract an Int column value.  Returns None for NULL or non-integer values.
@stable(since="0.1")
pub func getIntOpt(row: in DbRow, name: in String): Option[Int]
  requires: name.length > 0
{
  match col(row, name) {
    case DbNull           -> return None
    case DbInt(value = v) -> return Some(value = v)
    case _                -> return None
  }
}

/// Extract a Long column value.  Returns None for NULL or non-integer values.
@stable(since="0.1")
pub func getLongOpt(row: in DbRow, name: in String): Option[Long]
  requires: name.length > 0
{
  match col(row, name) {
    case DbNull            -> return None
    case DbLong(value = v) -> return Some(value = v)
    case DbInt(value = v)  -> return Some(value = v.toLong())
    case _                 -> return None
  }
}

/// Extract a Bool column value.  Returns None for NULL; prevents NULL-as-false confusion.
@stable(since="0.1")
pub func getBoolOpt(row: in DbRow, name: in String): Option[Bool]
  requires: name.length > 0
{
  match col(row, name) {
    case DbNull            -> return None
    case DbBool(value = v) -> return Some(value = v)
    case DbText(value = v) -> return Some(value = v == "true" || v == "t" || v == "1")
    case DbInt(value = v)  -> return Some(value = v != 0)
    case _                 -> return None
  }
}
