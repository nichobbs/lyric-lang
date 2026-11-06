//! Db.Kernel.Jvm — JDBC extern boundary for database drivers.
//!
//! JVM database driver bindings are not yet implemented. Rather than using
//! legacy `extern package` declarations (which are a compiler no-op and emit
//! invalid bytecode), every entry point returns a typed `Err` with
//! `NOT_SUPPORTED_ON_TARGET`, matching `Db.connect`'s own `--target jvm`
//! dispatch in `src/db.l`.

@cfg(feature = "jvm")
@io
package Db.Kernel.Jvm

import Std.Core

val NOT_SUPPORTED_MSG: String = "NOT_SUPPORTED_ON_TARGET: lyric-db JDBC kernel is not yet implemented on target jvm"

pub package Postgres {
  @cfg(feature = "postgres")
  pub func connect(
    url:              in String,
    poolSize:         in Int,
    connectTimeoutMs: in Int,
    password:         in String
  ): Result[Int, String]
    requires: url.length > 0
    requires: poolSize >= 1
    requires: connectTimeoutMs >= 100
  {
    Err(NOT_SUPPORTED_MSG)
  }
}

pub package Sqlite {
  @cfg(feature = "sqlite")
  pub func connect(
    url:              in String,
    connectTimeoutMs: in Int
  ): Result[Int, String]
    requires: url.length > 0
    requires: connectTimeoutMs >= 100
  {
    Err(NOT_SUPPORTED_MSG)
  }
}

pub func query(connId: in Int, sql: in String, params: in [String]): Result[String, String]
  requires: sql.length > 0
{
  Err(NOT_SUPPORTED_MSG)
}

pub func execute(connId: in Int, sql: in String, params: in [String]): Result[Int, String]
  requires: sql.length > 0
{
  Err(NOT_SUPPORTED_MSG)
}

pub func beginTransaction(connId: in Int): Result[Int, String] {
  Err(NOT_SUPPORTED_MSG)
}

pub func txQuery(txId: in Int, sql: in String, params: in [String]): Result[String, String]
  requires: sql.length > 0
{
  Err(NOT_SUPPORTED_MSG)
}

pub func txExecute(txId: in Int, sql: in String, params: in [String]): Result[Int, String]
  requires: sql.length > 0
{
  Err(NOT_SUPPORTED_MSG)
}

pub func commitTransaction(txId: in Int): Result[Unit, String] {
  Err(NOT_SUPPORTED_MSG)
}

pub func rollbackTransaction(txId: in Int): Result[Unit, String] {
  Err(NOT_SUPPORTED_MSG)
}

pub func close(connId: in Int): Unit {
}

pub func connectDsn(connStr: in String): Result[Int, String]
  requires: connStr.length > 0
{
  Err(NOT_SUPPORTED_MSG)
}
