//! Db — driver-agnostic database access with typed rows and transactions.
//! Stability: @stable — `query`/`execute`/`transaction` are real ADO.NET
//! calls (`Db.Kernel.Net`, `System.Data.Common`), not the historical
//! hardcoded-`Err` stubs (#5407). The SQLite path (Microsoft.Data.Sqlite)
//! is exercised end-to-end in CI against a real `:memory:` database
//! (`tests/db_sqlite_tests.l`); the Postgres path (Npgsql) shares the exact
//! same query/execute/transaction code and is verified for connect-failure
//! error mapping only — no live Postgres server is available in CI/sandboxes
//! (`tests/db_postgres_connect_tests.l`). See lyric-db/README.md "Platform
//! parity" for the full, honest breakdown.
//!
//! `DbConnection` is the public interface; implement it to add a new driver.
//! Two built-in drivers are provided via feature-gated kernel packages:
//!
//! Convenience wrappers (added for gRPC / non-web consumers):
//!   Db.connect(connStr)      — open a connection from an explicit DSN
//!   Db.connectPostgres(...)  — open a Postgres connection directly
//!   Db.connectSqlite(...)    — open a SQLite connection directly
//!   Db.sql(text)             — build a `SqlText` from a SQL literal
//!   Db.unsafeRawSql(text)    — build a `SqlText` from a dynamic string (audited escape hatch)
//!   Db.dbQuery(conn, sql, p) — call conn.query; top-level wrapper
//!   Db.dbExecute(conn, sql, p) — call conn.execute; top-level wrapper
//!   Db.getString/getInt/getLong/getBool — typed column extractors
//!
//! Usage:
//!
//!   import Db
//!
//!   val conn = Db.connect("postgres://...")?
//!   match conn.query(Db.sql("SELECT id, name FROM users WHERE id = @p0"), ["42"]) {
//!     case Ok(rows) ->
//!       for row in rows {
//!         match Db.col(row, "name") {
//!           case DbValue.DbText(name) -> println(name)
//!           case _                   -> ()
//!         }
//!       }
//!     case Err(e) -> Err(e.message)
//!   }
//!   conn.close()
//!
//! See docs/03-decision-log.md D056 and lyric-db/README.md.
@runtime_checked
@io
package Db

import Std.Core
import Std.Collections
import Std.Json as StdJson
import Std.Environment as Environment
import Std.Encoding
import Std.String as Str
import Std.Parse
import Db.Kernel.Net as DbKernel
import extern System.{Convert}

// ─── Error ────────────────────────────────────────────────────────────────────
/// A database error with a driver-reported code and message.
@stable(since = "0.1")
pub record DbError {
  message: String
  code: String    // driver-specific error code (e.g. "23505" for PG unique violation)
}

// ─── SQL text ─────────────────────────────────────────────────────────────────
/// SQL text that is allowed to reach a driver.  Every `query` / `execute` in
/// this package takes a `SqlText`, never a bare `String`, so a statement
/// assembled by string concatenation or interpolation cannot be passed to the
/// driver by accident: it does not type-check.
///
/// Values belong in the `params` list and are bound as `@p0`, `@p1`, ...;
/// SQL text itself should be a literal.  There are two ways to build one:
///
///   Db.sql("SELECT id FROM users WHERE name = @p0")   // audited path
///   Db.unsafeRawSql(dynamicString)                      // greppable escape hatch
///
/// `sql` additionally rejects text that is not a single statement with
/// well-formed placeholders (see `sqlIsWellFormed`).  `unsafeRawSql` performs
/// no structural check: the caller vouches for the text (for example a table
/// name taken from a fixed allow-list), and a reviewer finds every such call
/// with `grep unsafeRawSql`.
@stable(since = "0.2")
pub opaque type SqlText {
  text: String
  placeholders: Int
  invariant: hasSqlContent(text)
  invariant: placeholders >= 0
}

@pure
func isSqlSpace(c: in Char): Bool {
  c == ' ' or c == '\t' or c == '\n' or c == '\r'
}

@pure
func hasSqlContent(text: in String): Bool {
  var i = 0
  while i < text.length {
    if not isSqlSpace(Str.charAtOrReplacement(text, i)) {
      return true
    }
    i = i + 1
  }
  return false
}

@pure
func isSqlIdentChar(c: in Char): Bool {
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_'
}

@pure
func isSqlDigit(c: in Char): Bool {
  c >= '0' and c <= '9'
}

/// True when `text` is acceptable to `sql`: non-blank, a single statement (an
/// optional trailing `;` is allowed), no `--` or `/* */` comments outside a
/// string literal, every string literal terminated, and every `@` outside a
/// literal a positional placeholder of the form `@p<digits>`.
///
/// The scan is dialect-agnostic and conservative: it knows only `'...'` literals
/// with `''` as the quote escape. It does not understand backslash escapes
/// (`E'it\'s'`), dollar quoting (`$$...$$`), double-quoted identifiers, or `@`
/// operators such as Postgres `@>`; text using those is rejected (or, for a
/// backslash escape, mis-scanned) and should go through `unsafeRawSql`.
///
/// This is defence in depth against text that was spliced together at run
/// time (an interpolated `'; DROP TABLE users; --` fails three of these
/// rules); it cannot prove arbitrary text safe.  Use `params` for values.
@pure
@stable(since = "0.2")
pub func sqlIsWellFormed(text: in String): Bool {
  if not hasSqlContent(text) {
    return false
  }
  val n = text.length
  var i = 0
  var inLiteral = false
  var ok = true
  while i < n and ok {
    val c = Str.charAtOrReplacement(text, i)
    if inLiteral {
      if c == '\'' {
        if i + 1 < n and Str.charAtOrReplacement(text, i + 1) == '\'' {
          i = i + 1
        } else {
          inLiteral = false
        }
      }
    } else if c == '\'' {
      inLiteral = true
    } else if c == '-' and i + 1 < n and Str.charAtOrReplacement(text, i + 1) == '-' {
      ok = false
    } else if c == '/' and i + 1 < n and Str.charAtOrReplacement(text, i + 1) == '*' {
      ok = false
    } else if c == ';' {
      var j = i + 1
      while j < n {
        if not isSqlSpace(Str.charAtOrReplacement(text, j)) {
          ok = false
        }
        j = j + 1
      }
    } else if c == '@' {
      if i + 2 < n and Str.charAtOrReplacement(text, i + 1) == 'p' and isSqlDigit(Str.charAtOrReplacement(text, i + 2)) {
        var j = i + 2
        while j < n and isSqlDigit(Str.charAtOrReplacement(text, j)) {
          j = j + 1
        }
        if j < n and isSqlIdentChar(Str.charAtOrReplacement(text, j)) {
          ok = false
        }
        i = j - 1
      } else {
        ok = false
      }
    }
    i = i + 1
  }
  ok and not inLiteral
}

/// Number of positional parameters `text` expects: one more than the highest
/// `@p<N>` index outside a string literal, or 0 when it has none.  Gaps are
/// allowed (`@p0` and `@p2` expect three parameters).  `@` followed by anything
/// else is ignored here (`sqlIsWellFormed` is what rejects it).
@pure
@stable(since = "0.2")
pub func sqlPlaceholderCount(text: in String): Int {
  val n = text.length
  var i = 0
  var inLiteral = false
  var count = 0
  while i < n {
    val c = Str.charAtOrReplacement(text, i)
    if inLiteral {
      if c == '\'' {
        if i + 1 < n and Str.charAtOrReplacement(text, i + 1) == '\'' {
          i = i + 1
        } else {
          inLiteral = false
        }
      }
    } else if c == '\'' {
      inLiteral = true
    } else if c == '@' and i + 2 < n and Str.charAtOrReplacement(text, i + 1) == 'p' and isSqlDigit(Str.charAtOrReplacement(text, i + 2)) {
      var j = i + 2
      var idx = 0
      while j < n and isSqlDigit(Str.charAtOrReplacement(text, j)) {
        if idx < 100000000 {
          idx = idx * 10 + (Str.codeUnitAt(text, j) - 48)
        }
        j = j + 1
      }
      if idx + 1 > count {
        count = idx + 1
      }
      i = j - 1
    }
    i = i + 1
  }
  count
}

func mkSqlText(text: in String): SqlText {
  SqlText(text = text, placeholders = sqlPlaceholderCount(text))
}

/// The error for running `stmt` with a parameter list of the wrong length, or
/// `None` when `params` has exactly the number of values the statement's
/// highest `@p<N>` placeholder needs.  Every `DbConnection` / `DbTransaction`
/// in this package returns it as an `Err` (code `PARAM_COUNT_MISMATCH`)
/// before the statement reaches a driver.
@stable(since = "0.2")
pub func sqlParamsError(stmt: in SqlText, params: in slice[String]): Option[DbError] {
  if stmt.placeholders == params.length {
    return None
  }
  Some(
    value = DbError(
      message = "SQL statement expects " + stmt.placeholders.toString() +
        " parameter(s) (highest placeholder @p" +
        (stmt.placeholders - 1).toString() +
        ") but " +
        params.length.toString() +
        " were supplied",
      code = "PARAM_COUNT_MISMATCH"
    )
  )
}

/// Build a `SqlText` from SQL source.  Intended for string literals: values
/// go in the `params` list as `@p0`, `@p1`, ....  Panics (contract failure)
/// when `text` is not `sqlIsWellFormed`; use `trySql` to handle that as an
/// `Err`, or `unsafeRawSql` when the text really is assembled at run time.
@stable(since = "0.2")
pub func sql(text: in String): SqlText
  requires: sqlIsWellFormed(text)
{
  mkSqlText(text)
}

/// Like `sql`, but a text that is not `sqlIsWellFormed` is an `Err` with code
/// `SQL_REJECTED` instead of a contract failure.
@stable(since = "0.2")
pub func trySql(text: in String): Result[SqlText, DbError] {
  if sqlIsWellFormed(text) {
    return Ok(mkSqlText(text))
  }
  Err(
    DbError(
      message = "SQL text rejected: it must be one statement with no comments, terminated string literals and only @p<N> placeholders",
      code = "SQL_REJECTED"
    )
  )
}

/// Build a `SqlText` from a string assembled at run time, with NO structural
/// check.  The caller vouches that `text` contains no untrusted input: values
/// still go through `params`, and only fixed fragments (a column list, a table
/// name from an allow-list) may be spliced in.  Every call site is greppable
/// by name and is expected to carry a comment saying why the text is safe.
/// Panics only when `text` is blank.
@stable(since = "0.2")
pub func unsafeRawSql(text: in String): SqlText
  requires: hasSqlContent(text)
{
  mkSqlText(text)
}

/// The SQL source held by a `SqlText`.  For `DbConnection` implementations
/// (drivers, test doubles) that need the text to hand to a backend.
@stable(since = "0.2")
pub func sqlToString(stmt: in SqlText): String {
  stmt.text
}

// ─── Row value type ───────────────────────────────────────────────────────────
/// A column value returned by a query.  Pattern-match to extract a typed value.
///
/// `DbDecimal` carries exact decimal text (e.g. `"123.456"`) from the driver;
/// use `Std.String.parseDouble` or a decimal library for arithmetic.
/// `DbDateTime` carries an ISO 8601 UTC timestamp string from the driver.
@stable(since = "0.1")
pub union DbValue {
  case DbNull
  case DbInt(value: Int)
  case DbLong(value: Long)
  case DbFloat(value: Float)
  case DbDouble(value: Double)
  case DbBool(value: Bool)
  case DbText(value: String)
  case DbBytes(value: slice[Byte])
  case DbDecimal(value: String)   // exact decimal text; tagged {"$decimal":"..."} on wire
  case DbDateTime(value: String)  // ISO 8601 UTC; tagged {"$datetime":"..."} on wire
}

/// A single named column (name + value) within a row.
@stable(since = "0.1")
pub record DbColumn {
  name: String
  value: DbValue
}

/// A single query result row: an ordered list of columns.
@stable(since = "0.1")
pub record DbRow {
  columns: slice[DbColumn]
}

/// Extract a column value from a row by name.
/// Returns `DbValue.DbNull` if the column is not found.
@stable(since = "0.1")
pub func col(row: in DbRow, colName: in String): DbValue
  requires: colName.length > 0
{
  for c in row.columns {
    if c.name == colName {
      return c.value
    }
  }
  return DbNull
}

/// Execute a parameterised SELECT and return the first row, or None if no rows match.
///
/// Intended for PostgreSQL `SELECT … FOR UPDATE SKIP LOCKED` job-claim patterns:
///
///   match Db.queryOne(conn,
///     Db.sql("SELECT id, payload FROM jobs WHERE status = @p0
///      ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED"),
///     ["pending"]) { ... }
///
/// Callers are responsible for including the `LIMIT 1` clause to bound the scan.
@stable(since = "0.1")
pub func queryOne(conn: in DbConnection, sql: in SqlText, params: in slice[String]): Result[Option[DbRow], DbError] {
  match conn.query(sql, params) {
    case Err(e) -> Err(e)
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
@stable(since = "0.1")
pub interface DbTransaction {
  /// Execute a parameterised query and return the result rows.
  func query(sql: in SqlText, params: in slice[String]): Result[slice[DbRow], DbError]

  /// Execute a parameterised DML statement and return the affected-row count.
  func execute(sql: in SqlText, params: in slice[String]): Result[Int, DbError]

  /// True until the transaction has been committed or rolled back.  A
  /// finished transaction answers `query`, `execute` and `commit` with an
  /// `Err` whose code is `TX_FINISHED` instead of reaching the driver.
  func isActive(): Bool

  /// Commit the transaction.
  func commit(): Result[Unit, DbError]

  /// Roll back the transaction.  Idempotent: rolling back a transaction that
  /// has already finished is a no-op that returns `Ok`, so cleanup paths can
  /// call it unconditionally.
  func rollback(): Result[Unit, DbError]
}

// ─── Connection interface ─────────────────────────────────────────────────────
/// A database connection.  Obtain one via `Db.connect(connStr)`.
/// Close it with `conn.close()` when done; or inject it through a wire block
/// scoped to the request lifetime.
@stable(since = "0.1")
pub interface DbConnection {
  /// Execute a parameterised SELECT and return the result rows.
  func query(sql: in SqlText, params: in slice[String]): Result[slice[DbRow], DbError]

  /// Execute a parameterised INSERT / UPDATE / DELETE and return the
  /// number of affected rows.
  func execute(sql: in SqlText, params: in slice[String]): Result[Int, DbError]

  /// Begin an explicit transaction.
  func transaction(): Result[DbTransaction, DbError]

  /// Return this connection to the pool.
  func close(): Unit
}

// ─── Native connection wrapper (internal) ────────────────────────────────────
// Holds a real ADO.NET `DbConnection` reference (Db.Kernel.Net.DbConn) — not
// an integer registry handle; the connection object itself is the handle.
record NativeConnection {
  conn: DbKernel.DbConn
}

impl DbConnection for NativeConnection {
  func query(sql: in SqlText, params: in slice[String]): Result[slice[DbRow], DbError] {
    match sqlParamsError(sql, params) {
      case Some(e) -> return Err(e)
      case None -> ()
    }
    match DbKernel.query(self.conn, sql.text, params) {
      case Ok(jsonRows) -> parseRows(jsonRows)
      case Err(msg) -> Err(DbError(message = msg, code = "QUERY_ERROR"))
    }
  }

  func execute(sql: in SqlText, params: in slice[String]): Result[Int, DbError] {
    match sqlParamsError(sql, params) {
      case Some(e) -> return Err(e)
      case None -> ()
    }
    match DbKernel.execute(self.conn, sql.text, params) {
      case Ok(n) -> Ok(n)
      case Err(msg) -> Err(DbError(message = msg, code = "EXECUTE_ERROR"))
    }
  }

  func transaction(): Result[DbTransaction, DbError] {
    match DbKernel.beginTransaction(self.conn) {
      case Ok(tx) -> Ok(NativeTransaction(conn = self.conn, tx = tx, finished = false))
      case Err(msg) -> Err(DbError(message = msg, code = "TX_BEGIN_ERROR"))
    }
  }

  func close(): Unit {
    DbKernel.close(self.conn)
  }
}

ref record NativeTransaction {
  conn: DbKernel.DbConn
  tx: DbKernel.DbTxT
  var finished: Bool
}

func txFinishedError(): DbError {
  DbError(message = "the transaction has already been committed or rolled back", code = "TX_FINISHED")
}

impl DbTransaction for NativeTransaction {
  func query(sql: in SqlText, params: in slice[String]): Result[slice[DbRow], DbError] {
    if self.finished {
      return Err(txFinishedError())
    }
    match sqlParamsError(sql, params) {
      case Some(e) -> return Err(e)
      case None -> ()
    }
    match DbKernel.txQuery(self.conn, self.tx, sql.text, params) {
      case Ok(jsonRows) -> parseRows(jsonRows)
      case Err(msg) -> Err(DbError(message = msg, code = "TX_QUERY_ERROR"))
    }
  }

  func execute(sql: in SqlText, params: in slice[String]): Result[Int, DbError] {
    if self.finished {
      return Err(txFinishedError())
    }
    match sqlParamsError(sql, params) {
      case Some(e) -> return Err(e)
      case None -> ()
    }
    match DbKernel.txExecute(self.conn, self.tx, sql.text, params) {
      case Ok(n) -> Ok(n)
      case Err(msg) -> Err(DbError(message = msg, code = "TX_EXECUTE_ERROR"))
    }
  }

  func isActive(): Bool {
    not self.finished
  }

  func commit(): Result[Unit, DbError] {
    if self.finished {
      return Err(txFinishedError())
    }
    // A failed commit leaves the driver transaction unusable too.
    self.finished = true
    match DbKernel.commitTransaction(self.tx) {
      case Ok(_) -> Ok(())
      case Err(msg) -> Err(DbError(message = msg, code = "TX_COMMIT_ERROR"))
    }
  }

  func rollback(): Result[Unit, DbError] {
    if self.finished {
      return Ok(())
    }
    self.finished = true
    match DbKernel.rollbackTransaction(self.tx) {
      case Ok(_) -> Ok(())
      case Err(msg) -> Err(DbError(message = msg, code = "TX_ROLLBACK_ERROR"))
    }
  }
}

// ─── Factory functions ────────────────────────────────────────────────────────
/// Open a connection from an explicit connection-string DSN.
/// Detects the driver from the DSN scheme: `postgres://` / `postgresql://`
/// uses the Postgres driver; `sqlite://` uses SQLite.
///
/// Requires both the `postgres` and `sqlite` features active in this build
/// of `Lyric.Db` (its `[features] default`) — see
/// `Db.Kernel.Net.connectDsn` and lyric-db/README.md "Feature combinations".
/// Consumers that build `Lyric.Db` with only one driver feature active
/// should call `connectPostgres` / `connectSqlite` directly instead.
@stable(since = "0.1")
pub func connect(connStr: in String): Result[DbConnection, DbError]
  requires: connStr.length > 0
{
  match DbKernel.connectDsn(connStr) {
    case Ok(conn) -> {
      val c: DbConnection = NativeConnection(conn = conn)
      Ok(c)
    }
    case Err(msg) -> Err(DbError(message = msg, code = "CONNECT_ERROR"))
  }
}

/// Read an `LYRIC_CONFIG_DB_CONNECTION_<suffix>` integer env var, clamped
/// to `[lo, hi]`. An unset, empty, or unparseable value falls back to
/// `dflt`; an in-range-but-out-of-bounds value is clamped rather than
/// rejected, matching README.md "Configuration"'s documented bounds. E.g.
/// `envIntClamped("POOLSIZE", 10, 1, 100)` with `POOLSIZE=0` set returns
/// `1`, not `0` — see `db_postgres_connect_tests.l`'s clamp regression
/// test for why an unclamped `0` would panic downstream instead.
func envIntClamped(suffix: in String, dflt: in Int, lo: in Int, hi: in Int): Int {
  val raw = Environment.getVarOrDefault("LYRIC_CONFIG_DB_CONNECTION_" + suffix, "")
  val v = match Std.Parse.parseOptInt(raw) { case Some(n) -> n; case None -> dflt }
  if v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}

/// Open a connection from the `LYRIC_CONFIG_DB_CONNECTION_URL` environment
/// variable.  This is the zero-argument convenience the services in
/// `examples/` and the book's database chapter use: the DSN lives in
/// configuration, not in source.  The driver is detected from the DSN
/// scheme (`postgres://`, `sqlite://`) exactly as `connect` does.  Returns
/// a `CONFIG_ERROR` `DbError` when the variable is unset or empty so the
/// caller can fail fast with a clear message instead of dereferencing an
/// empty DSN.
///
/// Also reads `LYRIC_CONFIG_DB_CONNECTION_POOLSIZE` (default `10`, clamped
/// to 1-100), `..._CONNECTTIMEOUTMS` (default `5000`, clamped to
/// 100-30000), and `..._PASSWORD` (default `""`) — matching README.md
/// "Configuration". These previously had no effect: this function
/// delegated to `connect`, which always used `connectDsn`'s hardcoded
/// `poolSize=10, connectTimeoutMs=5000, password=""` regardless of what
/// an operator configured (#6359). Unlike a `config { }` block's
/// `@sensitive` field annotation (docs/25-config-blocks.md §9 — itself
/// declared but inert in v1: no actual log/diagnostic redaction is
/// implemented anywhere yet), `password` here is a plain local `val` with
/// no annotation support at all — nothing redacts it if it ends up in a
/// `DbError.message` or elsewhere. `LYRIC_CONFIG_DB_CONNECTION_
/// QUERYTIMEOUTMS` is still not wired to anything — no kernel code sets
/// `DbCommand.CommandTimeout` yet; that remains a tracked follow-up.
@stable(since = "0.1")
pub func connectFromEnv(): Result[DbConnection, DbError] {
  val url = Environment.getVarOrDefault("LYRIC_CONFIG_DB_CONNECTION_URL", "")
  if url.length == 0 {
    return Err(DbError(message = "LYRIC_CONFIG_DB_CONNECTION_URL is not set", code = "CONFIG_ERROR"))
  }
  val poolSize = envIntClamped("POOLSIZE", 10, 1, 100)
  val connectTimeoutMs = envIntClamped("CONNECTTIMEOUTMS", 5000, 100, 30000)
  val password = Environment.getVarOrDefault("LYRIC_CONFIG_DB_CONNECTION_PASSWORD", "")
  if Str.startsWith(url, "postgres://") or Str.startsWith(url, "postgresql://") {
    return connectPostgres(url, poolSize, connectTimeoutMs, password)
  }
  if Str.startsWith(url, "sqlite://") or url == "sqlite::memory:" {
    return connectSqlite(url, connectTimeoutMs)
  }
  Err(
    DbError(
      message = "unrecognized DSN scheme (expected postgres://, postgresql://, or sqlite://)",
      code = "CONFIG_ERROR"
    )
  )
}

/// Open a PostgreSQL connection directly, bypassing DSN scheme sniffing.
/// Available whenever the `postgres` feature is active, independent of
/// whether `sqlite` is also active. `url` accepts a
/// `postgres://user:pass@host:port/database` URI or an already-formed
/// Npgsql keyword=value connection string.
@cfg(feature = "postgres")
@stable(since = "0.1")
pub func connectPostgres(
  url: in String, poolSize: in Int, connectTimeoutMs: in Int, password: in String
): Result[DbConnection, DbError]
  requires: url.length > 0
  requires: poolSize >= 1
  requires: connectTimeoutMs >= 100
{
  match DbKernel.connectPostgres(url, poolSize, connectTimeoutMs, password) {
    case Ok(conn) -> {
      val c: DbConnection = NativeConnection(conn = conn)
      Ok(c)
    }
    case Err(msg) -> Err(DbError(message = msg, code = "CONNECT_ERROR"))
  }
}

/// Open a SQLite connection directly, bypassing DSN scheme sniffing.
/// Available whenever the `sqlite` feature is active, independent of
/// whether `postgres` is also active. `url` accepts a `sqlite://<path>`
/// URI, the literal `sqlite::memory:` shorthand, or an already-formed
/// `Data Source=...` connection string.
@cfg(feature = "sqlite")
@stable(since = "0.1")
pub func connectSqlite(url: in String, connectTimeoutMs: in Int): Result[DbConnection, DbError]
  requires: url.length > 0
  requires: connectTimeoutMs >= 100
{
  match DbKernel.connectSqlite(url, connectTimeoutMs) {
    case Ok(conn) -> {
      val c: DbConnection = NativeConnection(conn = conn)
      Ok(c)
    }
    case Err(msg) -> Err(DbError(message = msg, code = "CONNECT_ERROR"))
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
func parseRows(json: in String): Result[slice[DbRow], DbError] {
  val doc = StdJson.parseJson(json)
  defer {
    StdJson.disposeJson(doc)
  }
  val root = StdJson.rootElement(doc)
  if StdJson.valueKind(root) != 2 {
    return Err(DbError(message = "expected JSON array from query", code = "PARSE_ERROR"))
  }
  val rowList = newList()
  var arrEn = StdJson.enumerateArray(root)
  while StdJson.arrayMoveNext(arrEn) {
    val rowElem = StdJson.arrayCurrent(arrEn)
    if StdJson.valueKind(rowElem) != 1 {
      return Err(DbError(message = "expected JSON object for each row", code = "PARSE_ERROR"))
    }
    val colList = newList()
    var objEn = StdJson.enumerateObject(rowElem)
    while StdJson.objectMoveNext(objEn) {
      val prop = StdJson.objectCurrent(objEn)
      val colNm = StdJson.propertyName(prop)
      val rawVal = StdJson.getRawText(StdJson.propertyValue(prop))
      colList.add(DbColumn(name = colNm, value = parseDbValue(rawVal)))
    }
    rowList.add(DbRow(columns = colList.toArray()))
  }
  return Ok(rowList.toArray())
}

// Decode a single JSON value (as raw text) to a DbValue.
// Re-parses the raw text so JsonElement does not escape this module.
func parseDbValue(raw: in String): DbValue {
  val doc = StdJson.parseJson(raw)
  defer {
    StdJson.disposeJson(doc)
  }
  val elem = StdJson.rootElement(doc)
  val kind = StdJson.valueKind(elem)
  match kind {
    case 7 -> DbNull
    case 5 -> DbBool(value = true)
    case 6 -> DbBool(value = false)
    case 3 -> DbText(value = StdJson.getString(elem))
    case 4 -> {
      match StdJson.tryGetInt(elem) {
        case Some(i) -> DbInt(value = i)
        case None -> match StdJson.tryGetLong(elem) {
          case Some(l) -> DbLong(value = l)
          case None -> DbDouble(value = StdJson.getDouble(elem))
        }
      }
    }
    case 1 -> {
      match StdJson.tryGetProperty(elem, "$decimal") {
        case Some(v) -> DbDecimal(value = StdJson.getString(v))
        case None -> match StdJson.tryGetProperty(elem, "$datetime") {
          case Some(v) -> DbDateTime(value = StdJson.getString(v))
          case None -> match StdJson.tryGetProperty(elem, "$bytes") {
            case Some(v) -> match Std.Encoding.tryDecodeBase64(StdJson.getString(v)) {
              case Some(bytes) -> DbBytes(value = bytes)
              case None -> DbNull
            }
            case None -> DbNull
          }
        }
      }
    }
    case _ -> DbNull
  }
}

// ─── Convenience wrappers ─────────────────────────────────────────────────────
/// Top-level wrapper for conn.query — avoids UFCS syntax in callers that
/// hold a DbConnection value (not a concrete NativeConnection).
@stable(since = "0.1")
pub func dbQuery(conn: in DbConnection, sql: in SqlText, params: in slice[String]): Result[slice[DbRow], DbError] {
  return conn.query(sql, params)
}

/// Top-level wrapper for conn.execute.
@stable(since = "0.1")
pub func dbExecute(conn: in DbConnection, sql: in SqlText, params: in slice[String]): Result[Int, DbError] {
  return conn.execute(sql, params)
}

// ─── Typed column extractors ──────────────────────────────────────────────────
/// Extract a String column value.  Returns "" for NULL or non-text values.
@stable(since = "0.1")
pub func dbGetString(row: in DbRow, name: in String): String
  requires: name.length > 0
{
  match col(row, name) {
    case DbText(v) -> return v
    case DbDateTime(v) -> return v
    case DbDecimal(v) -> return v
    case _ -> return ""
  }
}

/// Extract an Int column value.  Returns 0 for NULL, non-integer values, and
/// integers outside Int32 range.  SQLite reports an `INTEGER` column as
/// `DbLong` (Microsoft.Data.Sqlite picks the CLR type per value, not per
/// declared column type), so a `DbLong` that fits `Int32` is returned as-is;
/// one that does not is never truncated into a plausible-looking wrong value
/// (#7241).  Use `getLong` for columns that may hold values outside Int32
/// range, or `getIntOpt` to tell an out-of-range value from a zero.
@stable(since = "0.1")
pub func getInt(row: in DbRow, name: in String): Int
  requires: name.length > 0
{
  match col(row, name) {
    case DbInt(v) -> return v
    case DbLong(v) -> return if fitsInt(v) { v.toInt() } else { 0 }
    case _ -> return 0
  }
}

func fitsInt(v: in Long): Bool {
  v >= -2147483648i64 and v <= 2147483647i64
}

/// Extract a Long column value.  Returns 0L for NULL or non-integer values.
@stable(since = "0.1")
pub func getLong(row: in DbRow, name: in String): Long
  requires: name.length > 0
{
  match col(row, name) {
    case DbLong(v) -> return v
    case DbInt(v) -> return Convert.ToInt64(v)
    case _ -> return 0i64
  }
}

/// Extract a Bool column value.  Returns false for NULL or non-boolean values.
@stable(since = "0.1")
pub func getBool(row: in DbRow, name: in String): Bool
  requires: name.length > 0
{
  match col(row, name) {
    case DbBool(v) -> return v
    case DbText(v) -> return v == "true" or v == "t" or v == "1"
    case DbInt(v) -> return v != 0
    case _ -> return false
  }
}

// ─── Option-returning extractors (NULL-safe) ──────────────────────────────────
// Use these when NULL is a meaningful value distinct from a zero/empty default.
/// Extract a String column value.  Returns None for NULL; Some(v) for any text value.
@stable(since = "0.1")
pub func dbGetStringOpt(row: in DbRow, name: in String): Option[String]
  requires: name.length > 0
{
  match col(row, name) {
    case DbNull -> return None
    case DbText(v) -> return Some(value = v)
    case DbDateTime(v) -> return Some(value = v)
    case DbDecimal(v) -> return Some(value = v)
    case _ -> return None
  }
}

/// Extract an Int column value.  Returns None for NULL, non-integer values,
/// and integers outside Int32 range (see `getInt`: SQLite `INTEGER` columns
/// surface as `DbLong`, which is narrowed only when it fits).
@stable(since = "0.1")
pub func getIntOpt(row: in DbRow, name: in String): Option[Int]
  requires: name.length > 0
{
  match col(row, name) {
    case DbNull -> return None
    case DbInt(v) -> return Some(value = v)
    case DbLong(v) -> return if fitsInt(v) { Some(value = v.toInt()) } else { None }
    case _ -> return None
  }
}

/// Extract a Long column value.  Returns None for NULL or non-integer values.
@stable(since = "0.1")
pub func getLongOpt(row: in DbRow, name: in String): Option[Long]
  requires: name.length > 0
{
  match col(row, name) {
    case DbNull -> return None
    case DbLong(v) -> return Some(value = v)
    case DbInt(v) -> return Some(value = Convert.ToInt64(v))
    case _ -> return None
  }
}

/// Extract a Bool column value.  Returns None for NULL; prevents NULL-as-false confusion.
@stable(since = "0.1")
pub func getBoolOpt(row: in DbRow, name: in String): Option[Bool]
  requires: name.length > 0
{
  match col(row, name) {
    case DbNull -> return None
    case DbBool(v) -> return Some(value = v)
    case DbText(v) -> return Some(value = v == "true" or v == "t" or v == "1")
    case DbInt(v) -> return Some(value = v != 0)
    case _ -> return None
  }
}
