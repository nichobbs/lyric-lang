/// Db.Kernel.Jvm — JDBC extern boundary for database drivers.
///
/// JVM implementation of the same contract as Db.Kernel.Net.  Two JDBC
/// driver families are supported:
///
///   Postgres.*  — org.postgresql.jdbc.Driver (PostgreSQL JDBC driver)
///   Sqlite.*    — org.sqlite.JDBC (SQLite JDBC driver)
///
/// Shared functions (query/execute/transaction) are backed by
/// `lyric.db.JdbcConnections`, a custom JVM helper that manages a
/// connection-handle table on top of `java.sql.DriverManager`.
/// The wire format produced by `query` / `txQuery` is identical to
/// Db.Kernel.Net so db.l's `parseRows` helper decodes both without change.
///
/// Handle semantics (identical to Db.Kernel.Net):
///   connect / connectDsn → Int connection handle
///   beginTransaction     → Int transaction handle
///
/// Only active when compiled with feature = "jvm" (Phase 6).
/// See docs/14-native-stdlib-plan.md for the kernel boundary contract.

@cfg(feature = "jvm")
package Db.Kernel.Jvm

import Std.Core

// ─── PostgreSQL JDBC driver ───────────────────────────────────────────────────

@axiom("org.postgresql.jdbc.Driver PostgreSQL JDBC driver for JVM")
@cfg(feature = "postgres")
extern package lyric.db.Postgres {
  /// Open a pooled JDBC connection to PostgreSQL.  Returns a connection handle.
  pub func connect(
    url:              String,
    poolSize:         Int,
    connectTimeoutMs: Int,
    password:         String
  ): Result[Int, String]
    requires: url.length > 0
    requires: poolSize >= 1
    requires: connectTimeoutMs >= 100
}

/// PostgreSQL-specific driver functions, reachable as Db.Kernel.Jvm.Postgres.*.
pub package Postgres {
  @cfg(feature = "postgres")
  pub func connect(
    url:              in String,
    poolSize:         in Int,
    connectTimeoutMs: in Int,
    password:         in String
  ): Result[Int, String] {
    lyric.db.Postgres.connect(url, poolSize, connectTimeoutMs, password)
  }
}

// ─── SQLite JDBC driver ───────────────────────────────────────────────────────

@axiom("org.sqlite.JDBC SQLite JDBC driver for JVM")
@cfg(feature = "sqlite")
extern package lyric.db.Sqlite {
  /// Open a SQLite database file via JDBC.  Returns a connection handle.
  pub func connect(
    url:              String,
    connectTimeoutMs: Int
  ): Result[Int, String]
    requires: url.length > 0
    requires: connectTimeoutMs >= 100
}

/// SQLite-specific driver functions, reachable as Db.Kernel.Jvm.Sqlite.*.
pub package Sqlite {
  @cfg(feature = "sqlite")
  pub func connect(
    url:              in String,
    connectTimeoutMs: in Int
  ): Result[Int, String] {
    lyric.db.Sqlite.connect(url, connectTimeoutMs)
  }
}

// ─── Shared JDBC connection operations ───────────────────────────────────────

@axiom("java.sql.DriverManager + lyric.db.JdbcConnections connection-handle table for JVM")
extern package lyric.db.JdbcConnections {
  /// Execute a parameterised query; returns JSON-serialised row array.
  pub func query(
    connId: Int,
    sql:    String,
    params: [String]
  ): Result[String, String]
    requires: sql.length > 0

  /// Execute a parameterised DML statement; returns affected-row count.
  pub func execute(
    connId: Int,
    sql:    String,
    params: [String]
  ): Result[Int, String]
    requires: sql.length > 0

  /// Begin an explicit transaction; returns a transaction handle.
  pub func beginTransaction(connId: Int): Result[Int, String]

  /// Execute a query inside a transaction; returns JSON-serialised rows.
  pub func txQuery(
    txId:   Int,
    sql:    String,
    params: [String]
  ): Result[String, String]
    requires: sql.length > 0

  /// Execute DML inside a transaction; returns affected-row count.
  pub func txExecute(
    txId:   Int,
    sql:    String,
    params: [String]
  ): Result[Int, String]
    requires: sql.length > 0

  /// Commit a transaction.
  pub func commitTransaction(txId: Int): Result[Unit, String]

  /// Roll back a transaction.
  pub func rollbackTransaction(txId: Int): Result[Unit, String]

  /// Return a connection to the pool.
  pub func close(connId: Int): Unit

  /// Open a connection from an explicit DSN string.  Inspects the scheme
  /// prefix to select the driver: jdbc:postgresql:// → Postgres JDBC;
  /// jdbc:sqlite:// → SQLite JDBC.
  pub func connectDsn(connStr: String): Result[Int, String]
    requires: connStr.length > 0
}

// Re-export shared operations at the package level for db.l to call.
pub func query(connId: in Int, sql: in String, params: in [String]): Result[String, String]
  requires: sql.length > 0
{
  lyric.db.JdbcConnections.query(connId, sql, params)
}

pub func execute(connId: in Int, sql: in String, params: in [String]): Result[Int, String]
  requires: sql.length > 0
{
  lyric.db.JdbcConnections.execute(connId, sql, params)
}

pub func beginTransaction(connId: in Int): Result[Int, String] {
  lyric.db.JdbcConnections.beginTransaction(connId)
}

pub func txQuery(txId: in Int, sql: in String, params: in [String]): Result[String, String]
  requires: sql.length > 0
{
  lyric.db.JdbcConnections.txQuery(txId, sql, params)
}

pub func txExecute(txId: in Int, sql: in String, params: in [String]): Result[Int, String]
  requires: sql.length > 0
{
  lyric.db.JdbcConnections.txExecute(txId, sql, params)
}

pub func commitTransaction(txId: in Int): Result[Unit, String] {
  lyric.db.JdbcConnections.commitTransaction(txId)
}

pub func rollbackTransaction(txId: in Int): Result[Unit, String] {
  lyric.db.JdbcConnections.rollbackTransaction(txId)
}

pub func close(connId: in Int): Unit {
  lyric.db.JdbcConnections.close(connId)
}

/// Open a connection from an explicit DSN string.  The kernel inspects the
/// scheme prefix to select the driver: jdbc:postgresql:// → PostgreSQL JDBC;
/// jdbc:sqlite:// → SQLite JDBC.  All other schemes fall back to the
/// configured Connection.url driver.
pub func connectDsn(connStr: in String): Result[Int, String]
  requires: connStr.length > 0
{
  lyric.db.JdbcConnections.connectDsn(connStr)
}
