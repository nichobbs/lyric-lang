/// Db.Kernel.Net — ADO.NET extern boundary for database drivers.
///
/// Bridges Lyric's Db package to .NET database drivers:
///   Postgres.*  — Npgsql driver for PostgreSQL (@cfg feature = "postgres")
///   Sqlite.*    — Microsoft.Data.Sqlite driver   (@cfg feature = "sqlite")
///
/// Shared functions (connect/query/execute/transaction) use integer connection
/// and transaction handles.  The kernel maintains a connection pool per handle
/// and serialises query results to JSON for decoding in db.l.
///
/// Result row format (JSON string returned by query / txQuery):
///   [{"col1":"val1","col2":"val2",...}, ...]
/// All column values are JSON strings; the Db layer interprets types.
///
/// Error strings contain the driver error message and, where available,
/// the SQLSTATE code.
///
/// See docs/14-native-stdlib-plan.md for the kernel boundary contract.

package Db.Kernel.Net

// ─── PostgreSQL driver ────────────────────────────────────────────────────────

@axiom("Npgsql ADO.NET driver for PostgreSQL")
@cfg(feature = "postgres")
extern package Npgsql {
  /// Open a pooled connection.  Returns a connection handle on success.
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

/// PostgreSQL-specific driver functions, reachable as Db.Kernel.Net.Postgres.*.
pub package Postgres {
  @cfg(feature = "postgres")
  pub func connect(
    url:              in String,
    poolSize:         in Int,
    connectTimeoutMs: in Int,
    password:         in String
  ): Result[Int, String] {
    Npgsql.connect(url, poolSize, connectTimeoutMs, password)
  }
}

// ─── SQLite driver ────────────────────────────────────────────────────────────

@axiom("Microsoft.Data.Sqlite ADO.NET driver for SQLite")
@cfg(feature = "sqlite")
extern package MicrosoftDataSqlite {
  /// Open a SQLite database file.  Returns a connection handle on success.
  pub func connect(
    url:              String,
    connectTimeoutMs: Int
  ): Result[Int, String]
    requires: url.length > 0
    requires: connectTimeoutMs >= 100
}

/// SQLite-specific driver functions, reachable as Db.Kernel.Net.Sqlite.*.
pub package Sqlite {
  @cfg(feature = "sqlite")
  pub func connect(
    url:              in String,
    connectTimeoutMs: in Int
  ): Result[Int, String] {
    MicrosoftDataSqlite.connect(url, connectTimeoutMs)
  }
}

// ─── Shared connection operations ─────────────────────────────────────────────

@axiom("ADO.NET connection and command execution (driver-independent)")
extern package Db.Kernel.Ado {
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
}

// Re-export shared operations at the package level for db.l to call.
pub func query(connId: in Int, sql: in String, params: in [String]): Result[String, String]
  requires: sql.length > 0
{
  Db.Kernel.Ado.query(connId, sql, params)
}

pub func execute(connId: in Int, sql: in String, params: in [String]): Result[Int, String]
  requires: sql.length > 0
{
  Db.Kernel.Ado.execute(connId, sql, params)
}

pub func beginTransaction(connId: in Int): Result[Int, String] {
  Db.Kernel.Ado.beginTransaction(connId)
}

pub func txQuery(txId: in Int, sql: in String, params: in [String]): Result[String, String]
  requires: sql.length > 0
{
  Db.Kernel.Ado.txQuery(txId, sql, params)
}

pub func txExecute(txId: in Int, sql: in String, params: in [String]): Result[Int, String]
  requires: sql.length > 0
{
  Db.Kernel.Ado.txExecute(txId, sql, params)
}

pub func commitTransaction(txId: in Int): Result[Unit, String] {
  Db.Kernel.Ado.commitTransaction(txId)
}

pub func rollbackTransaction(txId: in Int): Result[Unit, String] {
  Db.Kernel.Ado.rollbackTransaction(txId)
}

pub func close(connId: in Int): Unit {
  Db.Kernel.Ado.close(connId)
}
