//! Db.Kernel.Net — ADO.NET extern boundary for database drivers.
//!
//! Bridges Lyric's Db package to real ADO.NET drivers via the shared
//! `System.Data.Common` base classes (`DbConnection` / `DbCommand` /
//! `DbDataReader` / `DbTransaction` / `DbParameter`), so `query` / `execute`
//! / transaction handling is written **once** against the provider-agnostic
//! base API and works identically for both drivers:
//!
//!   Postgres  — Npgsql driver for PostgreSQL (@cfg feature = "postgres")
//!   Sqlite    — Microsoft.Data.Sqlite driver  (@cfg feature = "sqlite")
//!
//! Only the connection constructors (`connectPostgres` / `connectSqlite`)
//! touch a driver-specific type (`Npgsql.NpgsqlConnection..ctor` /
//! `Microsoft.Data.Sqlite.SqliteConnection..ctor`); the constructor wrapper
//! declares its *Lyric* return type as the shared `DbConn` (bound to
//! `System.Data.Common.DbConnection`), which is CLR-assignment-compatible
//! with both concrete connection classes (both extend `DbConnection`) — the
//! same narrower-ctor/wider-declared-type pattern already used by
//! `Session.Kernel.Net.connect` (`ConnectionMultiplexer.Connect` returns the
//! concrete class; the Lyric wrapper declares the `IConnectionMultiplexer`
//! interface as its return type).
//!
//! Handles are real object references (`DbConn` / `DbTransaction`), not
//! integer registry handles — the previous design's `Int` handle table and
//! its `not available in bootstrap` stubs are gone (#5407).
//!
//! Result row format (JSON string returned by `query` / `txQuery`), unchanged
//! from the prior design so `Db.parseRows` decodes both without change:
//!   [{"col": <json_value>, ...}, ...]
//!
//! Column value encoding by CLR type (from `DbDataReader.GetFieldType`):
//!   NULL                        → JSON null
//!   Int64 / Int32               → JSON number (integer)
//!   Double / Single             → JSON number (floating-point, invariant culture)
//!   Boolean                     → JSON true / false
//!   String                      → JSON string
//!   Byte[]                      → JSON object  {"$bytes": "<base64>"}
//!   Decimal                     → JSON object  {"$decimal": "<invariant-culture text>"}
//!   DateTime                    → JSON object  {"$datetime": "<invariant-culture text>"}
//!   anything else (Int16, Guid, …) → JSON string, via `Object.ToString()`
//!     (a known, documented scope boundary: rarer CLR column types arrive
//!     as plain text rather than a typed `DbValue` variant; see
//!     lyric-db/README.md "Typed column coverage").
//!
//! Every parameter gets a synthetic name `p0, p1, p2, …` matching its
//! zero-based position in `params` (`Db.Kernel.Net`-internal only, never
//! caller-visible). The **caller's SQL text** uses each driver's own
//! placeholder syntax: Npgsql resolves `$1, $2, …` positionally — by
//! parameter *order*, ignoring the synthetic name — so `p0`/`p1`/… work
//! unchanged there. Microsoft.Data.Sqlite has no working bare-`?` binding
//! path through the `System.Data.Common` abstract API (`SqliteParameterCollection.Add`
//! throws `"ParameterName must be set."` for an unnamed/empty-named
//! parameter — verified empirically; see #5407) — SQLite callers must use
//! named placeholders `@p0, @p1, …` (the `@` sigil is optional in the
//! parameter's `.ParameterName` but required in the SQL text) matching
//! this synthetic naming exactly. Every parameter value is bound as
//! a `String` (matching the public `DbConnection.query`/`execute` signature,
//! which only accepts `slice[String]` params) — never string-interpolated
//! into the SQL text, so this remains injection-safe.
//!
//! Error strings surface the driver exception's `.message` (SQLSTATE-bearing
//! for Postgres via `PostgresException`); `Db.connect` / `Db.dbQuery` /
//! `Db.dbExecute` wrap them into a `DbError` with a stage-specific `code`
//! (`CONNECT_ERROR` / `QUERY_ERROR` / …). No driver exception ever escapes
//! this kernel as an unhandled `Bug` — every ADO.NET call site here is
//! wrapped in `try { … } catch Bug as b { Err(b.message) }`.
//!
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.
package Db.Kernel.Net

import Std.Core
import Std.String as Str
import Std.Encoding

// ─── Shared ADO.NET extern types (System.Data.Common — always in the BCL,
// no NuGet dependency needed for this part) ───────────────────────────────
@axiom("System.Data.Common.DbConnection/DbCommand/DbDataReader/DbTransaction/DbParameter conform to their documented ADO.NET contracts")
pub extern type DbConn = "System.Data.Common.DbConnection"

pub extern type DbTxT = "System.Data.Common.DbTransaction"

extern type DbCmd = "System.Data.Common.DbCommand"

extern type DbReader = "System.Data.Common.DbDataReader"

extern type DbParam = "System.Data.Common.DbParameter"

extern type DbParamCollection = "System.Data.Common.DbParameterCollection"

extern type ClrType = "System.Type"

extern type AnyObj = "System.Object"

// `Convert.ToString(<T>, IFormatProvider)`'s real overloads all take the
// `IFormatProvider` interface, not the concrete `CultureInfo` class — the
// `@externTarget` resolver requires an exact metadata match (F0015 otherwise),
// so every wrapper below is declared against this interface type.
// `CultureInfo` implements `IFormatProvider`, so `invariantCulture()` below
// (whose *actual* CLR return type is the concrete `CultureInfo`) declaring
// this wider interface as its Lyric return type is CLR-assignment-safe —
// the same narrower-actual/wider-declared pattern used throughout this file
// for `newNpgsqlConnection` / `newSqliteConnection` returning `DbConn`.
extern type IFormatProviderT = "System.IFormatProvider"

extern type DecimalT = "System.Decimal"

extern type DateTimeT = "System.DateTime"

extern type StreamT = "System.IO.Stream"

extern type MemStreamT = "System.IO.MemoryStream"

// ─── DbConnection instance members ───────────────────────────────────────────
@externInstance
@externTarget("System.Data.Common.DbConnection.Open")
func connOpen(c: in DbConn): Unit = ()

@externInstance
@externTarget("System.Data.Common.DbConnection.Close")
func connClose(c: in DbConn): Unit = ()

@externInstance
@externTarget("System.Data.Common.DbConnection.CreateCommand")
func connCreateCommand(c: in DbConn): DbCmd = ()

@externInstance
@externTarget("System.Data.Common.DbConnection.BeginTransaction")
func connBeginTransaction(c: in DbConn): DbTxT = ()

// ─── DbCommand instance members ──────────────────────────────────────────────
@externInstance
@externTarget("System.Data.Common.DbCommand.set_CommandText")
func cmdSetSql(c: in DbCmd, sql: in String): Unit = ()

@externInstance
@externTarget("System.Data.Common.DbCommand.set_Transaction")
func cmdSetTransaction(c: in DbCmd, tx: in DbTxT): Unit = ()

@externInstance
@externTarget("System.Data.Common.DbCommand.CreateParameter")
func cmdCreateParameter(c: in DbCmd): DbParam = ()

@externInstance
@externTarget("System.Data.Common.DbCommand.get_Parameters")
func cmdParameters(c: in DbCmd): DbParamCollection = ()

@externInstance
@externTarget("System.Data.Common.DbCommand.ExecuteReader")
func cmdExecuteReader(c: in DbCmd): DbReader = ()

@externInstance
@externTarget("System.Data.Common.DbCommand.ExecuteNonQuery")
func cmdExecuteNonQuery(c: in DbCmd): Int = ()

// ─── DbParameter / DbParameterCollection ─────────────────────────────────────
@externInstance
@externTarget("System.Data.Common.DbParameter.set_ParameterName")
func paramSetName(p: in DbParam, name: in String): Unit = ()

@externInstance
@externTarget("System.Data.Common.DbParameter.set_Value")
func paramSetValue(p: in DbParam, v: in String): Unit = ()

@externInstance
@externTarget("System.Data.Common.DbParameterCollection.Add")
func paramsAdd(coll: in DbParamCollection, p: in DbParam): Int = ()

// ─── DbDataReader instance members ───────────────────────────────────────────
@externInstance
@externTarget("System.Data.Common.DbDataReader.Read")
func readerRead(r: in DbReader): Bool = ()

@externInstance
@externTarget("System.Data.Common.DbDataReader.get_FieldCount")
func readerFieldCount(r: in DbReader): Int = ()

@externInstance
@externTarget("System.Data.Common.DbDataReader.GetName")
func readerGetName(r: in DbReader, i: in Int): String = ()

@externInstance
@externTarget("System.Data.Common.DbDataReader.IsDBNull")
func readerIsDbNull(r: in DbReader, i: in Int): Bool = ()

@externInstance
@externTarget("System.Data.Common.DbDataReader.GetFieldType")
func readerFieldType(r: in DbReader, i: in Int): ClrType = ()

@externInstance
@externTarget("System.Type.get_FullName")
func clrTypeFullName(t: in ClrType): String = ()

@externInstance
@externTarget("System.Data.Common.DbDataReader.GetInt64")
func readerGetInt64(r: in DbReader, i: in Int): Long = ()

@externInstance
@externTarget("System.Data.Common.DbDataReader.GetInt32")
func readerGetInt32(r: in DbReader, i: in Int): Int = ()

@externInstance
@externTarget("System.Data.Common.DbDataReader.GetDouble")
func readerGetDouble(r: in DbReader, i: in Int): Double = ()

@externInstance
@externTarget("System.Data.Common.DbDataReader.GetFloat")
func readerGetFloat(r: in DbReader, i: in Int): Float = ()

@externInstance
@externTarget("System.Data.Common.DbDataReader.GetString")
func readerGetString(r: in DbReader, i: in Int): String = ()

@externInstance
@externTarget("System.Data.Common.DbDataReader.GetBoolean")
func readerGetBoolean(r: in DbReader, i: in Int): Bool = ()

@externInstance
@externTarget("System.Data.Common.DbDataReader.GetDecimal")
func readerGetDecimal(r: in DbReader, i: in Int): DecimalT = ()

@externInstance
@externTarget("System.Data.Common.DbDataReader.GetDateTime")
func readerGetDateTime(r: in DbReader, i: in Int): DateTimeT = ()

@externInstance
@externTarget("System.Data.Common.DbDataReader.GetValue")
func readerGetValue(r: in DbReader, i: in Int): AnyObj = ()

@externInstance
@externTarget("System.Data.Common.DbDataReader.GetStream")
func readerGetStream(r: in DbReader, i: in Int): StreamT = ()

// ─── DbTransaction instance members ──────────────────────────────────────────
@externInstance
@externTarget("System.Data.Common.DbTransaction.Commit")
func txCommit(t: in DbTxT): Unit = ()

@externInstance
@externTarget("System.Data.Common.DbTransaction.Rollback")
func txRollback(t: in DbTxT): Unit = ()

// ─── Disposal (DbCommand / DbDataReader) ─────────────────────────────────────
// `DbCommand` and `DbDataReader` both implement `IDisposable` (`DbCommand`
// via `System.ComponentModel.Component`; `DbDataReader` directly). Every
// `cmd`/`reader` created below must be disposed on both the success and
// error path — an undisposed `DbDataReader` can hold the SQLite connection's
// read lock open past the point its result has been consumed, which then
// makes a same-connection `DbTransaction.Commit()` fail (#5583).
@externInstance
@externTarget("System.Data.Common.DbCommand.Dispose")
func cmdDispose(c: in DbCmd): Unit = ()

@externInstance
@externTarget("System.Data.Common.DbDataReader.Dispose")
func readerDispose(r: in DbReader): Unit = ()

// ─── Culture-invariant text formatting ───────────────────────────────────────
// The row wire format is JSON; every numeric/date value must render in a
// locale-independent way regardless of the host OS's current culture, or
// the JSON text this kernel builds could become unparseable (comma decimal
// separators, localized date formats, …) on a non-US-locale host.
//
// These go through the *static* `Convert.ToString(<T>, IFormatProvider)`
// overloads rather than an instance `<T>.ToString(IFormatProvider)` call on
// a value-type receiver: `Single.ToString(IFormatProvider)` was verified
// (empirically, via a standalone repro) to silently return the wrong value
// ("0") through the generic `@externInstance` value-type-receiver path on
// this backend, while the static `Convert.ToString` form is correct for
// every numeric type tested. `DateTime` is the one exception — see
// `dateTimeToIso8601` below.
@externStatic
@externTarget("System.Globalization.CultureInfo.get_InvariantCulture")
func invariantCulture(): IFormatProviderT = ()

@externStatic
@externTarget("System.Convert.ToString")
func doubleToInvariantString(d: in Double, provider: in IFormatProviderT): String = ()

@externStatic
@externTarget("System.Convert.ToString")
func floatToInvariantString(f: in Float, provider: in IFormatProviderT): String = ()

@externStatic
@externTarget("System.Convert.ToString")
func decimalToInvariantString(d: in DecimalT, provider: in IFormatProviderT): String = ()

// `Convert.ToString(DateTime, IFormatProvider)` renders the culture's
// general date/time pattern ("MM/dd/yyyy HH:mm:ss" under InvariantCulture),
// not ISO 8601 — using the instance `DateTime.ToString(string)` overload
// with the "o" round-trip format specifier instead, matching the
// documented `DbDateTime` contract ("ISO 8601 UTC") and the self-hosted
// MSIL emitter's own built-in `toString(DateTime)` path (#2184). Unlike
// `Float`/`Single` (verified broken as a `@externInstance` receiver — see
// below), a `DateTime` value-type receiver was verified correct here.
@externInstance
@externTarget("System.DateTime.ToString")
func dateTimeToIso8601(d: in DateTimeT, format: in String): String = ()

@externStatic
@externTarget("System.Convert.ToString")
func objToInvariantString(o: in AnyObj, provider: in IFormatProviderT): String = ()

// ─── Blob extraction (Stream → MemoryStream → byte[]) ────────────────────────
// `DbDataReader.GetStream` returns a fully-buffered, synchronous stream over
// already-fetched blob data (unlike a network stream), so a synchronous
// `CopyTo` cannot deadlock the way an async pipe drain could.
@externTarget("System.IO.MemoryStream..ctor")
func newMemStream(): MemStreamT = ()

@externInstance
@externTarget("System.IO.Stream.CopyTo")
func streamCopyToSync(src: in StreamT, dst: in MemStreamT): Unit = ()

@externInstance
@externTarget("System.IO.MemoryStream.ToArray")
func memStreamToArray(m: in MemStreamT): slice[Byte] = ()

func readerGetBlobBase64(r: in DbReader, i: in Int): String {
  val src = readerGetStream(r, i)
  val dst = newMemStream()
  streamCopyToSync(src, dst)
  Std.Encoding.encodeBase64(memStreamToArray(dst))
}

// ─── Row serialisation (DbDataReader → wire-format JSON string) ──────────────
// Minimal hand-rolled JSON encoder matching the wire format documented at
// the top of this file; reuses `Std.Json.encodeString`-equivalent escaping
// via a local helper so this kernel does not need to import `Std.Json`
// (kept the dependency surface minimal: only `Std.Core` / `Std.String` /
// `Std.Encoding`).
func jsonEscapeString(s: in String): String {
  var acc = "\""
  var i = 0
  while i < s.length {
    val c = s[i]
    if c == '"' {
      acc = acc + "\\\""
    } else if c == '\\' {
      acc = acc + "\\\\"
    } else if c == '\n' {
      acc = acc + "\\n"
    } else if c == '\r' {
      acc = acc + "\\r"
    } else if c == '\t' {
      acc = acc + "\\t"
    } else {
      acc = acc + c.toString()
    }
    i = i + 1
  }
  acc + "\""
}

func serializeValue(r: in DbReader, i: in Int): String {
  if readerIsDbNull(r, i) {
    return "null"
  }
  val typeName = clrTypeFullName(readerFieldType(r, i))
  match typeName {
    case "System.Int64" -> readerGetInt64(r, i).toString()
    case "System.Int32" -> readerGetInt32(r, i).toString()
    case "System.Double" -> doubleToInvariantString(readerGetDouble(r, i), invariantCulture())
    case "System.Single" -> floatToInvariantString(readerGetFloat(r, i), invariantCulture())
    case "System.Boolean" -> if readerGetBoolean(r, i) { "true" } else { "false" }
    case "System.String" -> jsonEscapeString(readerGetString(r, i))
    case "System.Decimal" -> "{\"$decimal\":" + jsonEscapeString(decimalToInvariantString(readerGetDecimal(r, i), invariantCulture())) + "}"
    case "System.DateTime" -> "{\"$datetime\":" + jsonEscapeString(dateTimeToIso8601(readerGetDateTime(r, i), "o")) + "}"
    case "System.Byte[]" -> "{\"$bytes\":" + jsonEscapeString(readerGetBlobBase64(r, i)) + "}"
    case _ -> jsonEscapeString(objToInvariantString(readerGetValue(r, i), invariantCulture()))
  }
}

func serializeRow(r: in DbReader): String {
  val n = readerFieldCount(r)
  var acc = "{"
  var i = 0
  while i < n {
    if i > 0 {
      acc = acc + ","
    }
    acc = acc + jsonEscapeString(readerGetName(r, i)) + ":" + serializeValue(r, i)
    i = i + 1
  }
  acc + "}"
}

func serializeRows(r: in DbReader): String {
  var acc = "["
  var first = true
  while readerRead(r) {
    if not first {
      acc = acc + ","
    }
    first = false
    acc = acc + serializeRow(r)
  }
  acc + "]"
}

// ─── Parameter binding ────────────────────────────────────────────────────────
// See the file-header comment for the naming convention (`p0, p1, …`) and
// why bare `?` placeholders don't work against Microsoft.Data.Sqlite's
// `DbParameterCollection.Add`.
func bindParams(cmd: in DbCmd, params: in slice[String]): Unit {
  val coll = cmdParameters(cmd)
  var i = 0
  while i < params.length {
    val p = cmdCreateParameter(cmd)
    paramSetName(p, "p" + i.toString())
    paramSetValue(p, params[i])
    val _ = paramsAdd(coll, p)
    i = i + 1
  }
}

// ─── PostgreSQL driver ────────────────────────────────────────────────────────
@axiom("Npgsql ADO.NET driver for PostgreSQL")
@cfg(feature = "postgres")
@externTarget("Npgsql.NpgsqlConnection..ctor")
func newNpgsqlConnection(connStr: in String): DbConn = ()

// Build an Npgsql keyword=value connection string. Accepts either a
// `postgres://` / `postgresql://` URI (parsed here) or an already-formed
// Npgsql connection string (passed through, with tuning params appended).
@cfg(feature = "postgres")
func buildPgConnStr(dsn: in String, poolSize: in Int, connectTimeoutMs: in Int, passwordOverride: in String): String {
  val isUri = Str.startsWith(dsn, "postgres://") or Str.startsWith(dsn, "postgresql://")
  if not isUri {
    return appendPgTuning(dsn, poolSize, connectTimeoutMs, passwordOverride)
  }
  val prefixLen = if Str.startsWith(dsn, "postgresql://") { 13 } else { 11 }
  val rest = Str.substring(dsn, prefixLen)

  var userinfo = ""
  var afterAt = rest
  match Str.indexOf(rest, "@") {
    case Some(at) -> {
      userinfo = Str.substring(rest, 0, at)
      afterAt = Str.substring(rest, at + 1)
    }
    case None -> ()
  }

  var hostport = afterAt
  var pathAndQuery = ""
  match Str.indexOf(afterAt, "/") {
    case Some(slash) -> {
      hostport = Str.substring(afterAt, 0, slash)
      pathAndQuery = Str.substring(afterAt, slash + 1)
    }
    case None -> ()
  }

  var dbName = pathAndQuery
  match Str.indexOf(pathAndQuery, "?") {
    case Some(q) -> {
      dbName = Str.substring(pathAndQuery, 0, q)
    }
    case None -> ()
  }

  var host = hostport
  var port = "5432"
  match Str.indexOf(hostport, ":") {
    case Some(c) -> {
      host = Str.substring(hostport, 0, c)
      port = Str.substring(hostport, c + 1)
    }
    case None -> ()
  }
  if host.length == 0 {
    host = "localhost"
  }

  var user = ""
  var pass = ""
  if userinfo.length > 0 {
    match Str.indexOf(userinfo, ":") {
      case Some(c) -> {
        user = Str.substring(userinfo, 0, c)
        pass = Str.substring(userinfo, c + 1)
      }
      case None -> {
        user = userinfo
      }
    }
  }

  var connStr = "Host=" + host + ";Port=" + port + ";Username=" + user + ";Database=" + dbName
  if pass.length > 0 {
    connStr = connStr + ";Password=" + pass
  }
  appendPgTuning(connStr, poolSize, connectTimeoutMs, passwordOverride)
}

@cfg(feature = "postgres")
func appendPgTuning(base: in String, poolSize: in Int, connectTimeoutMs: in Int, passwordOverride: in String): String {
  var s = base
  if passwordOverride.length > 0 {
    s = s + ";Password=" + passwordOverride
  }
  s + ";Timeout=" + (connectTimeoutMs / 1000).toString() + ";Maximum Pool Size=" + poolSize.toString()
}

/// Open a PostgreSQL connection.  Available when the `postgres` feature is
/// active (part of this library's `[features] default`).  `url` accepts
/// either a `postgres://user:pass@host:port/database` URI or an already-
/// formed Npgsql keyword=value connection string.  Connect failures (bad
/// host, refused port, auth failure, …) return `Err` with the driver's
/// message — never a panic.
@cfg(feature = "postgres")
pub func connectPostgres(
  url: in String, poolSize: in Int, connectTimeoutMs: in Int, password: in String
): Result[DbConn, String]
  requires: url.length > 0
  requires: poolSize >= 1
  requires: connectTimeoutMs >= 100
{
  val connStr = buildPgConnStr(url, poolSize, connectTimeoutMs, password)
  try {
    val conn: DbConn = newNpgsqlConnection(connStr)
    connOpen(conn)
    Ok(conn)
  } catch Bug as b {
    Err(b.message)
  }
}

// ─── SQLite driver ────────────────────────────────────────────────────────────
@axiom("Microsoft.Data.Sqlite ADO.NET driver for SQLite")
@cfg(feature = "sqlite")
@externTarget("Microsoft.Data.Sqlite.SqliteConnection..ctor")
func newSqliteConnection(connStr: in String): DbConn = ()

// Build a Microsoft.Data.Sqlite connection string. Accepts either a
// `sqlite://<path>` URI, the literal `sqlite::memory:` shorthand, or an
// already-formed `Data Source=...` connection string.
@cfg(feature = "sqlite")
func buildSqliteConnStr(dsn: in String): String {
  if dsn == "sqlite::memory:" {
    return "Data Source=:memory:"
  }
  if Str.startsWith(dsn, "sqlite://") {
    val path = Str.substring(dsn, 9)
    if path.length == 0 or path == ":memory:" {
      return "Data Source=:memory:"
    }
    return "Data Source=" + path
  }
  dsn
}

/// Open a SQLite connection.  Available when the `sqlite` feature is active
/// (part of this library's `[features] default`).  `url` accepts a
/// `sqlite://<path>` URI, the literal `sqlite::memory:` shorthand for an
/// in-memory database, or an already-formed `Data Source=...` connection
/// string.  `connectTimeoutMs` maps to Microsoft.Data.Sqlite's busy-timeout
/// (`Default Timeout`, in whole seconds).
@cfg(feature = "sqlite")
pub func connectSqlite(url: in String, connectTimeoutMs: in Int): Result[DbConn, String]
  requires: url.length > 0
  requires: connectTimeoutMs >= 100
{
  val connStr = buildSqliteConnStr(url) + ";Default Timeout=" + (connectTimeoutMs / 1000).toString()
  try {
    val conn: DbConn = newSqliteConnection(connStr)
    connOpen(conn)
    Ok(conn)
  } catch Bug as b {
    Err(b.message)
  }
}

// ─── Shared connection operations ─────────────────────────────────────────────
// Unconditional: only System.Data.Common types are touched here, so these
// compile and run regardless of which of postgres/sqlite is active — the
// same connection handle (`DbConn`) works for either driver.
pub func query(conn: in DbConn, sql: in String, params: in slice[String]): Result[String, String]
  requires: sql.length > 0
{
  try {
    val cmd = connCreateCommand(conn)
    defer {
      cmdDispose(cmd)
    }
    cmdSetSql(cmd, sql)
    bindParams(cmd, params)
    val reader = cmdExecuteReader(cmd)
    defer {
      readerDispose(reader)
    }
    Ok(serializeRows(reader))
  } catch Bug as b {
    Err(b.message)
  }
}

pub func execute(conn: in DbConn, sql: in String, params: in slice[String]): Result[Int, String]
  requires: sql.length > 0
{
  try {
    val cmd = connCreateCommand(conn)
    defer {
      cmdDispose(cmd)
    }
    cmdSetSql(cmd, sql)
    bindParams(cmd, params)
    Ok(cmdExecuteNonQuery(cmd))
  } catch Bug as b {
    Err(b.message)
  }
}

pub func beginTransaction(conn: in DbConn): Result[DbTxT, String] {
  try {
    Ok(connBeginTransaction(conn))
  } catch Bug as b {
    Err(b.message)
  }
}

pub func txQuery(conn: in DbConn, tx: in DbTxT, sql: in String, params: in slice[String]): Result[String, String]
  requires: sql.length > 0
{
  try {
    val cmd = connCreateCommand(conn)
    defer {
      cmdDispose(cmd)
    }
    cmdSetSql(cmd, sql)
    cmdSetTransaction(cmd, tx)
    bindParams(cmd, params)
    val reader = cmdExecuteReader(cmd)
    defer {
      readerDispose(reader)
    }
    Ok(serializeRows(reader))
  } catch Bug as b {
    Err(b.message)
  }
}

pub func txExecute(conn: in DbConn, tx: in DbTxT, sql: in String, params: in slice[String]): Result[Int, String]
  requires: sql.length > 0
{
  try {
    val cmd = connCreateCommand(conn)
    defer {
      cmdDispose(cmd)
    }
    cmdSetSql(cmd, sql)
    cmdSetTransaction(cmd, tx)
    bindParams(cmd, params)
    Ok(cmdExecuteNonQuery(cmd))
  } catch Bug as b {
    Err(b.message)
  }
}

pub func commitTransaction(tx: in DbTxT): Result[Unit, String] {
  try {
    txCommit(tx)
    Ok(())
  } catch Bug as b {
    Err(b.message)
  }
}

pub func rollbackTransaction(tx: in DbTxT): Result[Unit, String] {
  try {
    txRollback(tx)
    Ok(())
  } catch Bug as b {
    Err(b.message)
  }
}

pub func close(conn: in DbConn): Unit {
  try {
    connClose(conn)
  } catch Bug as _ {
    ()
  }
}

// ─── DSN dispatch ─────────────────────────────────────────────────────────────
/// Open a connection from an explicit DSN string.  The scheme prefix
/// selects the driver: `postgres://` / `postgresql://` → Npgsql;
/// `sqlite://` / the literal `sqlite::memory:` → Microsoft.Data.Sqlite.
///
/// **Requires both the `postgres` and `sqlite` features active** (this
/// library's `[features] default`) — `connectPostgres` and `connectSqlite`
/// are referenced unconditionally below, so a build of `Db.Kernel.Net` with
/// either feature turned off fails to compile this function specifically
/// (a whole-program compile-time error, not a runtime surprise). Consumers
/// who deliberately narrow to a single driver (`--features sqlite` only,
/// say) should call `connectSqlite` / `connectPostgres` directly instead of
/// `connectDsn` / `Db.connect` / `Db.connectFromEnv` — see
/// lyric-db/README.md "Feature combinations".
pub func connectDsn(connStr: in String): Result[DbConn, String]
  requires: connStr.length > 0
{
  if Str.startsWith(connStr, "postgres://") or Str.startsWith(connStr, "postgresql://") {
    return connectPostgres(connStr, 10, 5000, "")
  }
  if Str.startsWith(connStr, "sqlite://") or connStr == "sqlite::memory:" {
    return connectSqlite(connStr, 5000)
  }
  Err(error = "Db.Kernel.Net.connectDsn: unrecognized DSN scheme (expected postgres://, postgresql://, or sqlite://)")
}
