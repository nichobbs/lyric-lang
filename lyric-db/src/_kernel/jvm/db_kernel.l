//! Db.Kernel.Jvm — JDBC extern boundary for database drivers.
//!
//! JVM implementation of the same contract as `Db.Kernel.Net`, written once
//! against the provider-agnostic `java.sql` interfaces (`Connection` /
//! `PreparedStatement` / `ResultSet` / `ResultSetMetaData`), so `query` /
//! `execute` / transaction handling is identical for both drivers:
//!
//!   PostgreSQL — `org.postgresql:postgresql` (@cfg feature = "postgres")
//!   SQLite     — `org.xerial:sqlite-jdbc`    (@cfg feature = "sqlite")
//!
//! Pure Lyric over the JVM auto-FFI (`extern type` + `T.method(args)`); no
//! Java shim classes and no `extern package`. Connections are opened with
//! `DriverManager.getConnection(url, Properties)`, so the user name and
//! password travel as `Properties` entries and are never spliced into a URL
//! (the JDBC analogue of the .NET kernel's connection-string builders).
//!
//! Handles are real object references: `DbConn` is the `java.sql.Connection`
//! and `DbTxT` is a small record around it. JDBC has no transaction object,
//! only per-connection auto-commit state, so `beginTransaction` switches
//! auto-commit off and `commitTransaction` / `rollbackTransaction` finish the
//! unit of work and switch it back on. A transaction that is neither
//! committed nor rolled back leaves auto-commit off until the connection is
//! closed (which rolls the work back), exactly as an abandoned transaction
//! holds its locks on .NET until the connection closes.
//!
//! Result row format (JSON string returned by `query` / `txQuery`) is
//! identical to `Db.Kernel.Net`, so `Db.parseRows` decodes both unchanged:
//!   [{"col": <json_value>, ...}, ...]
//!
//! Column value encoding by the Java class of `ResultSet.getObject` (the
//! per-value counterpart of the .NET kernel's `GetFieldType`, so SQLite's
//! dynamic typing reports the stored value's class, not the declared column
//! type):
//!   NULL                             -> JSON null
//!   Long / Integer / Short / Byte    -> JSON number (integer)
//!   Double / Float                   -> JSON number (floating-point, shortest
//!                                       round-trip text, locale independent)
//!   Boolean                          -> JSON true / false
//!   String                           -> JSON string
//!   byte[]                           -> JSON object {"$bytes": "<base64>"}
//!   BigDecimal                       -> JSON object {"$decimal": "<plain text>"}
//!   Timestamp / Date                 -> JSON object {"$datetime": "<ISO 8601>"}
//!       `timestamptz` columns render as a UTC instant ("...Z"); `timestamp`
//!       and `date` render as the stored wall-clock value with no offset, so
//!       the JVM's default time zone never shifts what the database holds.
//!   anything else (UUID, PGobject, ...) -> JSON string via `Object.toString()`
//!
//! Placeholders. The public contract is the same as on .NET: the SQL text
//! uses named placeholders `@p0, @p1, ...` matching each parameter's
//! zero-based position in `params`. JDBC only knows positional `?`, so
//! `translatePlaceholders` rewrites every `@p<N>` that is *code* (not inside
//! a quoted string, a quoted identifier, a comment or a dollar-quoted body)
//! to `?` and records which parameter each `?` binds, so a placeholder may
//! repeat or appear out of order. Every value is bound with `setString`
//! (matching the public `slice[String]` parameter type) and is never
//! interpolated into the SQL text, so the path stays injection-safe. The
//! PostgreSQL connection sets `stringtype=unspecified`, which sends bound
//! strings with an unspecified type so the server infers the target type
//! (`WHERE id = @p0` with `"42"` compares as an integer), the behaviour the
//! SQLite affinity rules give for free.
//!
//! Connection pooling is not part of this kernel: `poolSize` is validated for
//! API parity with `Db.Kernel.Net` and one JDBC connection is opened. A
//! caller that needs a pool wraps `connect` calls in its own.
//!
//! Error strings surface the driver exception's `.message`; `Db.connect` /
//! `Db.dbQuery` / `Db.dbExecute` wrap them into a `DbError` with a
//! stage-specific `code`. No driver exception escapes this kernel as an
//! unhandled `Bug`: every JDBC call site is wrapped in
//! `try { ... } catch Bug as b { Err(b.message) }`.
//!
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.
@axiom("java.sql.DriverManager / Connection / PreparedStatement / ResultSet / ResultSetMetaData and the org.postgresql:postgresql and org.xerial:sqlite-jdbc drivers conform to their documented JDBC contracts")
@cfg(feature = "jvm")
@io
package Db.Kernel.Jvm

import Std.Core
import Std.Collections
import Std.Parse
import Std.String as Str

// ─── JDK / JDBC extern types ────────────────────────────────────────────────
extern type JStatement = "java.sql.PreparedStatement"

extern type JResultSet = "java.sql.ResultSet"

extern type JMetaData = "java.sql.ResultSetMetaData"

extern type JDriverManager = "java.sql.DriverManager"

extern type JProperties = "java.util.Properties"

extern type JObject = "java.lang.Object"

extern type JClass = "java.lang.Class"

extern type JObjects = "java.util.Objects"

extern type JBase64 = "java.util.Base64"

extern type JBigDecimal = "java.math.BigDecimal"

extern type JTimestamp = "java.sql.Timestamp"

extern type JDate = "java.sql.Date"

extern type JLocalDateTime = "java.time.LocalDateTime"

extern type JLocalDate = "java.time.LocalDate"

extern type JInstant = "java.time.Instant"

/// A live JDBC connection. Opaque to callers; `Db` holds it inside its
/// `NativeConnection` record.
pub extern type DbConn = "java.sql.Connection"

/// An open transaction: the connection whose auto-commit is switched off.
pub record DbTxT {
  conn: DbConn
}

// ─── Row serialisation (ResultSet -> wire-format JSON string) ───────────────
func jsonEscapeString(s: in String): String {
  var acc = "\""
  var i = 0
  while i < s.length {
    val c = Str.charAtOrReplacement(s, i)
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
    } else if Str.codeUnitAt(s, i) < 32 {
      acc = acc + "\\u00" + hexDigit(Str.codeUnitAt(s, i) / 16) + hexDigit(Str.codeUnitAt(s, i) % 16)
    } else {
      acc = acc + Str.substring(s, i, 1)
    }
    i = i + 1
  }
  acc + "\""
}

func hexDigit(n: in Int): String {
  Str.substring("0123456789abcdef", n, 1)
}

func className(o: in JObject): String {
  o.getClass().getName()
}

func serializeValue(rs: in JResultSet, meta: in JMetaData, i: in Int): String {
  val o = rs.getObject(i)
  if JObjects.isNull(o) {
    return "null"
  }
  match className(o) {
    case "java.lang.Long" -> rs.getLong(i).toString()
    case "java.lang.Integer" -> rs.getLong(i).toString()
    case "java.lang.Short" -> rs.getLong(i).toString()
    case "java.lang.Byte" -> rs.getLong(i).toString()
    case "java.lang.Double" -> rs.getDouble(i).toString()
    case "java.lang.Float" -> rs.getFloat(i).toString()
    case "java.lang.Boolean" -> if rs.getBoolean(i) { "true" } else { "false" }
    case "java.lang.String" -> jsonEscapeString(rs.getString(i))
    case "[B" -> "{\"$bytes\":" + jsonEscapeString(JBase64.getEncoder().encodeToString(rs.getBytes(i))) + "}"
    case "java.math.BigDecimal" -> "{\"$decimal\":" + jsonEscapeString(rs.getBigDecimal(i).toPlainString()) + "}"
    case "java.sql.Timestamp" -> "{\"$datetime\":" + jsonEscapeString(timestampText(rs, meta, i)) + "}"
    case "java.sql.Date" -> "{\"$datetime\":" +
      jsonEscapeString(withSeconds(rs.getDate(i).toLocalDate().atStartOfDay().toString())) +
      "}"
    case _ -> jsonEscapeString(o.toString())
  }
}

// `timestamptz` is an instant: render it as UTC. `timestamp` is a wall-clock
// reading with no zone: the driver builds a `Timestamp` in the JVM's default
// zone, so convert back through the same zone to recover the stored value.
func timestampText(rs: in JResultSet, meta: in JMetaData, i: in Int): String {
  val ts = rs.getTimestamp(i)
  if Str.toLower(meta.getColumnTypeName(i)) == "timestamptz" {
    ts.toInstant().toString()
  } else {
    withSeconds(ts.toLocalDateTime().toString())
  }
}

// `LocalDateTime.toString` drops a zero seconds field ("2024-01-02T00:00");
// restore it so every value has one shape.
func withSeconds(text: in String): String {
  if text.length == 16 {
    text + ":00"
  } else {
    text
  }
}

func serializeRow(rs: in JResultSet, meta: in JMetaData, n: in Int): String {
  var acc = "{"
  var i = 1
  while i <= n {
    if i > 1 {
      acc = acc + ","
    }
    acc = acc + jsonEscapeString(meta.getColumnLabel(i)) + ":" + serializeValue(rs, meta, i)
    i = i + 1
  }
  acc + "}"
}

func serializeRows(rs: in JResultSet): String {
  val meta = rs.getMetaData()
  val n = meta.getColumnCount()
  var acc = "["
  var first = true
  while rs.next() {
    if not first {
      acc = acc + ","
    }
    first = false
    acc = acc + serializeRow(rs, meta, n)
  }
  acc + "]"
}

// ─── Placeholder translation (@pN -> ?) ─────────────────────────────────────
/// The SQL text rewritten for JDBC plus, for each `?` in order, the index of
/// the `params` entry it binds.
pub record Translated {
  sql: String
  order: slice[Int]
}

func isDigitChar(c: in Char): Bool {
  c >= '0' and c <= '9'
}

func isIdentChar(c: in Char): Bool {
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_'
}

// The index of the first character after a dollar-quote tag that starts at
// `from` (the opening `$`), or -1 when `$` at `from` does not start one. A tag
// is `$$` or `$name$` where `name` is an identifier not starting with a digit.
func dollarTagEnd(sql: in String, from: in Int): Int {
  val n = sql.length
  var j = from + 1
  if j < n and isDigitChar(Str.charAtOrReplacement(sql, j)) {
    return -1
  }
  while j < n and isIdentChar(Str.charAtOrReplacement(sql, j)) {
    j = j + 1
  }
  if j < n and Str.charAtOrReplacement(sql, j) == '$' {
    return j + 1
  }
  -1
}

/// Rewrite `@p<N>` placeholders to JDBC `?`. A placeholder inside a `'...'`
/// literal, a `"..."` identifier, a `--` or `/* */` comment or a `$tag$...$tag$`
/// body is left alone. `Err` when a placeholder names a parameter index that
/// `paramCount` does not cover.
pub func translatePlaceholders(sql: in String, paramCount: in Int): Result[Translated, String] {
  val n = sql.length
  val order = newList()
  var rewritten = ""
  var runStart = 0
  var i = 0
  while i < n {
    val c = Str.charAtOrReplacement(sql, i)
    if c == '\'' or c == '"' {
      var j = i + 1
      var closed = false
      while j < n and not closed {
        if Str.charAtOrReplacement(sql, j) == c {
          if j + 1 < n and Str.charAtOrReplacement(sql, j + 1) == c {
            j = j + 2
          } else {
            closed = true
            j = j + 1
          }
        } else {
          j = j + 1
        }
      }
      i = j
    } else if c == '-' and i + 1 < n and Str.charAtOrReplacement(sql, i + 1) == '-' {
      var j = i + 2
      while j < n and Str.charAtOrReplacement(sql, j) != '\n' {
        j = j + 1
      }
      i = j
    } else if c == '/' and i + 1 < n and Str.charAtOrReplacement(sql, i + 1) == '*' {
      var depth = 1
      var j = i + 2
      while j < n and depth > 0 {
        if Str.charAtOrReplacement(sql, j) == '/' and j + 1 < n and Str.charAtOrReplacement(sql, j + 1) == '*' {
          depth = depth + 1
          j = j + 2
        } else if Str.charAtOrReplacement(sql, j) == '*' and j + 1 < n and Str.charAtOrReplacement(sql, j + 1) == '/' {
          depth = depth - 1
          j = j + 2
        } else {
          j = j + 1
        }
      }
      i = j
    } else if c == '$' and (i == 0 or not isIdentChar(Str.charAtOrReplacement(sql, i - 1))) and dollarTagEnd(sql, i) > 0 {
      val bodyStart = dollarTagEnd(sql, i)
      val tag = Str.substring(sql, i, bodyStart - i)
      match Str.indexOfFrom(sql, tag, bodyStart) {
        case Some(close) -> {
          i = close + tag.length
        }
        case None -> {
          i = n
        }
      }
    } else if c == '@' and i + 2 < n and Str.charAtOrReplacement(sql, i + 1) == 'p' and isDigitChar(Str.charAtOrReplacement(sql, i + 2)) and (i == 0 or not isIdentChar(Str.charAtOrReplacement(sql, i - 1))) {
      var j = i + 2
      var idx = 0
      while j < n and isDigitChar(Str.charAtOrReplacement(sql, j)) {
        if idx < 100000000 {
          idx = idx * 10 + (Str.codeUnitAt(sql, j) - 48)
        }
        j = j + 1
      }
      if j < n and isIdentChar(Str.charAtOrReplacement(sql, j)) {
        i = j
      } else {
        if idx >= paramCount {
          return Err(
            "SQL placeholder @p" + idx.toString() + " has no value: " + paramCount.toString() + " parameter(s) supplied"
          )
        }
        rewritten = rewritten + Str.substring(sql, runStart, i - runStart) + "?"
        order.add(idx)
        runStart = j
        i = j
      }
    } else {
      i = i + 1
    }
  }
  rewritten = rewritten + Str.substring(sql, runStart, n - runStart)
  Ok(Translated(sql = rewritten, order = order.toArray()))
}

// Prepare `sql`, bind every `?` from `params` as a string, and hand the
// statement to `body`. The statement is closed on every path.
func prepare(conn: in DbConn, sql: in String, params: in slice[String]): Result[JStatement, String] {
  match translatePlaceholders(sql, params.length) {
    case Err(e) -> Err(e)
    case Ok(t) -> {
      val stmt = conn.prepareStatement(t.sql)
      var k = 0
      while k < t.order.length {
        stmt.setString(k + 1, params[t.order[k]])
        k = k + 1
      }
      Ok(stmt)
    }
  }
}

func runQuery(conn: in DbConn, sql: in String, params: in slice[String]): Result[String, String] {
  try {
    match prepare(conn, sql, params) {
      case Err(e) -> Err(e)
      case Ok(stmt) -> {
        defer {
          stmt.close()
        }
        val rs = stmt.executeQuery()
        defer {
          rs.close()
        }
        Ok(serializeRows(rs))
      }
    }
  } catch Bug as b {
    Err(b.message)
  }
}

func runExecute(conn: in DbConn, sql: in String, params: in slice[String]): Result[Int, String] {
  try {
    match prepare(conn, sql, params) {
      case Err(e) -> Err(e)
      case Ok(stmt) -> {
        defer {
          stmt.close()
        }
        Ok(stmt.executeUpdate())
      }
    }
  } catch Bug as b {
    Err(b.message)
  }
}

// ─── Connection URLs ────────────────────────────────────────────────────────
// Whole seconds, rounded up: a positive sub-second timeout must not become 0,
// which both drivers read as "wait forever".
func msToWholeSecondsRoundedUp(ms: in Int): Int {
  if ms <= 0 {
    return 0
  }
  val secs = (ms + 999) / 1000
  if secs < 1 {
    1
  } else {
    secs
  }
}

/// The pieces of a PostgreSQL connection target: the JDBC URL (without
/// credentials) and the user and password to pass as `Properties`.
pub record PgTarget {
  jdbcUrl: String
  user: String
  password: String
}

/// Resolve a `postgres://` / `postgresql://` URI or a `jdbc:postgresql:` URL
/// into a JDBC URL plus credentials. `Err` for a port that is not a number in
/// 1..65535 or text that is neither form.
@cfg(feature = "postgres")
pub func buildPgTarget(dsn: in String, passwordOverride: in String): Result[PgTarget, String] {
  var user = ""
  var pass = ""
  var jdbcUrl = ""
  if Str.startsWith(dsn, "jdbc:postgresql:") {
    jdbcUrl = dsn
  } else if Str.startsWith(dsn, "postgres://") or Str.startsWith(dsn, "postgresql://") {
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

    var host = hostport
    var port = 5432
    match Str.indexOf(hostport, ":") {
      case Some(c) -> {
        host = Str.substring(hostport, 0, c)
        val portText = Str.substring(hostport, c + 1)
        port = match Std.Parse.parseOptInt(portText) {
          case Some(p) -> p
          case None -> return Err("invalid port '" + portText + "' in postgres URI")
        }
        if port < 1 or port > 65535 {
          return Err("port " + port.toString() + " in postgres URI is outside 1..65535")
        }
      }
      case None -> ()
    }
    if host.length == 0 {
      host = "localhost"
    }

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
    jdbcUrl = "jdbc:postgresql://" + host + ":" + port.toString() + "/" + pathAndQuery
  } else {
    return Err("unrecognized PostgreSQL connection string (expected a postgres:// URI or a jdbc:postgresql: URL)")
  }
  if passwordOverride.length > 0 {
    pass = passwordOverride
  }
  Ok(PgTarget(jdbcUrl = jdbcUrl, user = user, password = pass))
}

/// Resolve a `sqlite://<path>` URI, the literal `sqlite::memory:`, or a
/// `jdbc:sqlite:` URL into a JDBC URL.
@cfg(feature = "sqlite")
pub func buildSqliteUrl(dsn: in String): Result[String, String] {
  if Str.startsWith(dsn, "jdbc:sqlite:") {
    return Ok(dsn)
  }
  if dsn == "sqlite::memory:" {
    return Ok("jdbc:sqlite::memory:")
  }
  if Str.startsWith(dsn, "sqlite://") {
    val path = Str.substring(dsn, 9)
    if path.length == 0 {
      return Ok("jdbc:sqlite::memory:")
    }
    return Ok("jdbc:sqlite:" + path)
  }
  Err("unrecognized SQLite connection string (expected sqlite://<path>, sqlite::memory: or a jdbc:sqlite: URL)")
}

func openConnection(url: in String, props: in JProperties): Result[DbConn, String] {
  try {
    Ok(JDriverManager.getConnection(url, props))
  } catch Bug as b {
    Err(b.message)
  }
}

func setProp(props: in JProperties, key: in String, value: in String): Unit {
  val _ = props.setProperty(key, value)
}

/// Open a PostgreSQL connection.  Connect failures (bad host, refused port,
/// auth failure, ...) return `Err` with the driver's message, never a panic.
@cfg(feature = "postgres")
pub func connectPostgres(
  url: in String, poolSize: in Int, connectTimeoutMs: in Int, password: in String
): Result[DbConn, String]
  requires: url.length > 0
  requires: poolSize >= 1
  requires: connectTimeoutMs >= 100
{
  val target = match buildPgTarget(url, password) { case Err(e) -> return Err(e); case Ok(t) -> t }
  try {
    val _ = JClass.forName("org.postgresql.Driver")
    val props = JProperties.new()
    if target.user.length > 0 {
      setProp(props, "user", target.user)
    }
    if target.password.length > 0 {
      setProp(props, "password", target.password)
    }
    setProp(props, "stringtype", "unspecified")
    val secs = msToWholeSecondsRoundedUp(connectTimeoutMs).toString()
    setProp(props, "connectTimeout", secs)
    setProp(props, "loginTimeout", secs)
    openConnection(target.jdbcUrl, props)
  } catch Bug as b {
    Err(b.message)
  }
}

/// Open a SQLite connection.  `connectTimeoutMs` maps to the driver's
/// `busy_timeout` (how long a statement waits on a locked database).
@cfg(feature = "sqlite")
pub func connectSqlite(url: in String, connectTimeoutMs: in Int): Result[DbConn, String]
  requires: url.length > 0
  requires: connectTimeoutMs >= 100
{
  val jdbcUrl = match buildSqliteUrl(url) { case Err(e) -> return Err(e); case Ok(u) -> u }
  try {
    val _ = JClass.forName("org.sqlite.JDBC")
    val props = JProperties.new()
    setProp(props, "busy_timeout", connectTimeoutMs.toString())
    openConnection(jdbcUrl, props)
  } catch Bug as b {
    Err(b.message)
  }
}

// ─── Shared connection operations ───────────────────────────────────────────
pub func query(conn: in DbConn, sql: in String, params: in slice[String]): Result[String, String]
  requires: sql.length > 0
{
  runQuery(conn, sql, params)
}

pub func execute(conn: in DbConn, sql: in String, params: in slice[String]): Result[Int, String]
  requires: sql.length > 0
{
  runExecute(conn, sql, params)
}

pub func beginTransaction(conn: in DbConn): Result[DbTxT, String] {
  try {
    conn.setAutoCommit(false)
    Ok(DbTxT(conn = conn))
  } catch Bug as b {
    Err(b.message)
  }
}

pub func txQuery(conn: in DbConn, tx: in DbTxT, sql: in String, params: in slice[String]): Result[String, String]
  requires: sql.length > 0
{
  runQuery(tx.conn, sql, params)
}

pub func txExecute(conn: in DbConn, tx: in DbTxT, sql: in String, params: in slice[String]): Result[Int, String]
  requires: sql.length > 0
{
  runExecute(tx.conn, sql, params)
}

// Finish a unit of work: run `commit` or `rollback`, then restore auto-commit.
// A failed commit is rolled back so the connection is not left in an aborted
// transaction (PostgreSQL refuses further work until it ends).
pub func commitTransaction(tx: in DbTxT): Result[Unit, String] {
  try {
    tx.conn.commit()
    tx.conn.setAutoCommit(true)
    Ok(())
  } catch Bug as b {
    abandon(tx.conn)
    Err(b.message)
  }
}

pub func rollbackTransaction(tx: in DbTxT): Result[Unit, String] {
  try {
    tx.conn.rollback()
    tx.conn.setAutoCommit(true)
    Ok(())
  } catch Bug as b {
    abandon(tx.conn)
    Err(b.message)
  }
}

func abandon(conn: in DbConn): Unit {
  try {
    conn.rollback()
    conn.setAutoCommit(true)
  } catch Bug as _ {
    ()
  }
}

pub func close(conn: in DbConn): Unit {
  try {
    conn.close()
  } catch Bug as _ {
    ()
  }
}

// ─── DSN dispatch ───────────────────────────────────────────────────────────
/// Open a connection from an explicit DSN string.  The scheme prefix selects
/// the driver: `postgres://` / `postgresql://` / `jdbc:postgresql:` ->
/// PostgreSQL; `sqlite://` / `sqlite::memory:` / `jdbc:sqlite:` -> SQLite.
///
/// **Requires both the `postgres` and `sqlite` features active**, like
/// `Db.Kernel.Net.connectDsn` (see lyric-db/README.md "Feature
/// combinations").
pub func connectDsn(connStr: in String): Result[DbConn, String]
  requires: connStr.length > 0
{
  if Str.startsWith(connStr, "postgres://") or Str.startsWith(connStr, "postgresql://") or Str.startsWith(connStr, "jdbc:postgresql:") {
    return connectPostgres(connStr, 10, 5000, "")
  }
  if Str.startsWith(connStr, "sqlite://") or connStr == "sqlite::memory:" or Str.startsWith(connStr, "jdbc:sqlite:") {
    return connectSqlite(connStr, 5000)
  }
  Err("Db.Kernel.Jvm.connectDsn: unrecognized DSN scheme (expected postgres://, postgresql://, or sqlite://)")
}
