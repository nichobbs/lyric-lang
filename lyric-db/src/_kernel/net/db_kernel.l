//! Db.Kernel.Net — ADO.NET extern boundary for database drivers.
//!
//! Bridges Lyric's Db package to .NET database drivers:
//!   Postgres  — Npgsql driver for PostgreSQL (@cfg feature = "postgres")
//!   Sqlite    — Microsoft.Data.Sqlite driver  (@cfg feature = "sqlite")
//!
//! Shared functions (connect/query/execute/transaction) use integer connection
//! and transaction handles.  The kernel maintains a connection pool per handle
//! and serialises query results to JSON for decoding in db.l.
//!
//! Result row format (JSON string returned by query / txQuery):
//!   [{"col": <json_value>, ...}, ...]
//!
//! Column value encoding by SQL type:
//!   NULL             → JSON null
//!   INTEGER / BIGINT → JSON number (integer)
//!   REAL / FLOAT     → JSON number (floating-point)
//!   BOOLEAN          → JSON true / false
//!   TEXT / VARCHAR   → JSON string
//!   NUMERIC/DECIMAL  → JSON object  {"$decimal": "<exact-text>"}
//!   TIMESTAMP / DATE → JSON object  {"$datetime": "<ISO-8601-UTC>"}
//!   BYTEA / BLOB     → JSON object  {"$bytes": "<base64>"}
//!
//! The tagged-object forms avoid precision loss (DECIMAL) and ambiguity
//! (timestamps vs. plain strings).  The Db layer decodes all forms into
//! DbValue variants; see `parseDbValue` in db.l.
//!
//! Error strings contain the driver error message and, where available,
//! the SQLSTATE code.
//!
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.
package Db.Kernel.Net

import Std.Core

// ─── PostgreSQL driver ────────────────────────────────────────────────────────
@axiom("Npgsql ADO.NET driver for PostgreSQL")
@cfg(feature = "postgres")
extern package Npgsql {
  /// Open a pooled connection.  Returns a connection handle on success.
  pub func connect(url: String, poolSize: Int, connectTimeoutMs: Int, password: String): Result[Int, String]
    requires: url.length > 0
    requires: poolSize >= 1
    requires: connectTimeoutMs >= 100
}

/// Open a PostgreSQL connection.  Available when `postgres` feature is active.
@cfg(feature = "postgres")
pub func connectPostgres(
  url: in String, poolSize: in Int, connectTimeoutMs: in Int, password: in String
): Result[Int, String]
  requires: url.length > 0
  requires: poolSize >= 1
  requires: connectTimeoutMs >= 100
{
  Npgsql.connect(url, poolSize, connectTimeoutMs, password)
}

// ─── SQLite driver ────────────────────────────────────────────────────────────
@axiom("Microsoft.Data.Sqlite ADO.NET driver for SQLite")
@cfg(feature = "sqlite")
extern package MicrosoftDataSqlite {
  /// Open a SQLite database file.  Returns a connection handle on success.
  pub func connect(url: String, connectTimeoutMs: Int): Result[Int, String]
    requires: url.length > 0
    requires: connectTimeoutMs >= 100
}

/// Open a SQLite connection.  Available when `sqlite` feature is active.
@cfg(feature = "sqlite")
pub func connectSqlite(url: in String, connectTimeoutMs: in Int): Result[Int, String]
  requires: url.length > 0
  requires: connectTimeoutMs >= 100
{
  MicrosoftDataSqlite.connect(url, connectTimeoutMs)
}

// ─── Shared connection operations ─────────────────────────────────────────────
// Bootstrap-grade stubs for shared ADO.NET operations.  The actual driver
// calls are provided by the native runtime.  The `extern package Ado` block
// is omitted here because the bootstrap emitter cannot emit extern-package
// calls; these stubs provide both the type-checker signature and the
// bootstrap implementation (always Err).
pub func query(connId: in Int, sql: in String, params: in slice[String]): Result[String, String]
  requires: sql.length > 0
{
  Err(error = "Db.Kernel.Net: not available in bootstrap")
}

pub func execute(connId: in Int, sql: in String, params: in slice[String]): Result[Int, String]
  requires: sql.length > 0
{
  Err(error = "Db.Kernel.Net: not available in bootstrap")
}

pub func beginTransaction(connId: in Int): Result[Int, String] {
  Err(error = "Db.Kernel.Net: not available in bootstrap")
}

pub func txQuery(txId: in Int, sql: in String, params: in slice[String]): Result[String, String]
  requires: sql.length > 0
{
  Err(error = "Db.Kernel.Net: not available in bootstrap")
}

pub func txExecute(txId: in Int, sql: in String, params: in slice[String]): Result[Int, String]
  requires: sql.length > 0
{
  Err(error = "Db.Kernel.Net: not available in bootstrap")
}

pub func commitTransaction(txId: in Int): Result[Unit, String] {
  Err(error = "Db.Kernel.Net: not available in bootstrap")
}

pub func rollbackTransaction(txId: in Int): Result[Unit, String] {
  Err(error = "Db.Kernel.Net: not available in bootstrap")
}

pub func close(connId: in Int): Unit {
}

/// Open a connection from an explicit DSN string.  The kernel inspects the
/// scheme prefix to select the driver: postgres:// → Npgsql; sqlite:// →
/// Microsoft.Data.Sqlite.  All other schemes fall back to the configured
/// Connection.url driver.
pub func connectDsn(connStr: in String): Result[Int, String]
  requires: connStr.length > 0
{
  Err(error = "Db.Kernel.Net: not available in bootstrap")
}
