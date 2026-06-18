# lyric-db

Driver-agnostic database access with typed rows, transactions, and pluggable backends.

## Platform parity

| Feature flag | Backend                                                  | Status                |
|--------------|----------------------------------------------------------|-----------------------|
| `dotnet`     | Npgsql + Microsoft.Data.Sqlite ADO.NET drivers           | Available             |
| `jvm`        | PostgreSQL JDBC + SQLite JDBC via `lyric.db.*` shim JAR  | Planned (Phase 6)     |

The JVM kernel (`Db.Kernel.Jvm`) declares the JDBC bindings against
`org.postgresql:postgresql` and `org.xerial:sqlite-jdbc`, plus a
`lyric.db.JdbcConnections` helper.  The Java helper is supplied by the
Lyric JVM stdlib JAR (out-of-repo, ships with the JVM channel — see
`docs/33-platform-parity-remediation.md`).

## Packages

| Package | Purpose |
|---|---|
| `Db` | Core types, `DbConnection` / `DbTransaction` interfaces, connection factories |
| `Db.Aspects` | Reusable aspect templates: `QueryLogging` and `SlowQueryAlert` |
| `Db.Kernel.Net` | Extern boundary: Npgsql (PostgreSQL) and Microsoft.Data.Sqlite drivers |

## Quick start

```lyric
import Db

// Requires the "postgres" feature and LYRIC_CONFIG_DB_CONNECTION_URL
val conn = Db.connectPostgres()?

match conn.query("SELECT id, name FROM users WHERE id = $1", ["42"]) {
  case Ok(rows) ->
    for row in rows {
      match Db.col(row, "name") {
        case DbValue.DbText(name) -> println(name)
        case _                   -> ()
      }
    }
  case Err(e) -> eprintln("query failed: " + e.message)
}

conn.close()
```

## Features

The `postgres` and `sqlite` features are off by default.
Enable them in `lyric.toml`:

```toml
[features]
postgres = []
sqlite   = []
```

Only the features you activate are linked. Both can be active simultaneously.

## Configuration

All fields are read from env vars with the prefix `LYRIC_CONFIG_DB_CONNECTION_`:

| Env var suffix | Default | Meaning |
|---|---|---|
| `URL` | *(required)* | Connection URL |
| `POOLSIZE` | `10` | Connection pool size (1–100) |
| `CONNECTTIMEOUTMS` | `5000` | Connect timeout in ms (100–30000) |
| `QUERYTIMEOUTMS` | `30000` | Query timeout in ms (100–300000) |
| `PASSWORD` | `""` | Password override (empty = use URL) |

`PASSWORD` is marked `@sensitive` and will not appear in logs or diagnostics.

## DbConnection interface

```lyric
pub interface DbConnection {
  func query(sql: in String, params: in [String]): Result[[DbRow], DbError]
  func execute(sql: in String, params: in [String]): Result[Int, DbError]
  func transaction(): Result[DbTransaction, DbError]
  func close(): Unit
}
```

## DbTransaction interface

```lyric
pub interface DbTransaction {
  func query(sql: in String, params: in [String]): Result[[DbRow], DbError]
  func execute(sql: in String, params: in [String]): Result[Int, DbError]
  func commit(): Result[Unit, DbError]
  func rollback(): Result[Unit, DbError]
}
```

## Row access

```lyric
val rows: [DbRow] = ...

for row in rows {
  val id   = Db.col(row, "id")
  val name = Db.col(row, "name")

  match name {
    case DbValue.DbText(s)  -> println(s)
    case DbValue.DbNull     -> println("(null)")
    case _                  -> ()
  }
}
```

`Db.col(row, name)` returns `DbValue.DbNull` when the column is absent.

All column values arrive as strings from the kernel; numeric/bool conversion
is the caller's responsibility. The `DbValue` variants are:

| Variant | Payload |
|---|---|
| `DbNull` | — |
| `DbInt(value)` | `Int` |
| `DbLong(value)` | `Long` |
| `DbFloat(value)` | `Float` |
| `DbDouble(value)` | `Double` |
| `DbBool(value)` | `Bool` |
| `DbText(value)` | `String` |
| `DbBytes(value)` | `[Byte]` |

## Transactions

```lyric
val tx = conn.transaction()?

match tx.execute("INSERT INTO events (name) VALUES ($1)", ["login"]) {
  case Ok(_)  -> tx.commit()?
  case Err(e) -> { tx.rollback(); Err(e) }
}
```

## Aspect templates (`Db.Aspects`)

### QueryLogging

B-mode: logs handler entry and exit with elapsed time.

```lyric
import Db.Aspects
import Std.Logging

aspect DbLogging from Db.Aspects.QueryLogging {
  matches: name like "handle*"
  config { level: Std.Logging.LogLevel = Std.Logging.LogLevel.Debug }
}
```

Config fields (env prefix `LYRIC_ASPECT_<INSTANTIATION>_`):

| Field | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | `Bool` | `true` | Master switch |
| `level` | `LogLevel` | `Debug` | Log level for entry/exit messages |
| `loggerName` | `String` | `""` | Logger name; empty = `call.modulePath` |

### SlowQueryAlert

B-mode: logs a warning when a handler's total elapsed time exceeds a threshold.

```lyric
aspect SlowDb from Db.Aspects.SlowQueryAlert {
  matches: name like "handle*"
  inside:  DbLogging
  config { thresholdMs: Int = 200 }
}
```

Config fields (env prefix `LYRIC_ASPECT_<INSTANTIATION>_`):

| Field | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | `Bool` | `true` | Master switch |
| `thresholdMs` | `Int` | `500` | Warn threshold in ms (1–300000) |
| `alertLevel` | `LogLevel` | `Warn` | Log level for the alert |
| `loggerName` | `String` | `""` | Logger name; empty = `call.modulePath` |

## Kernel boundary (`Db.Kernel.Net`)

The kernel boundary is implemented in `src/_kernel/net/db_kernel.l` and is not
part of the public API. It exposes:

- `Db.Kernel.Net.Postgres.connect(...)` — wraps the Npgsql ADO.NET driver
- `Db.Kernel.Net.Sqlite.connect(...)` — wraps Microsoft.Data.Sqlite
- `Db.Kernel.Net.query/execute/beginTransaction/...` — shared ADO.NET operations

All extern functions return integer handles; `NativeConnection` and
`NativeTransaction` in `db.l` wrap them and implement the public interfaces.

## Decision log

See `docs/03-decision-log.md` D056.
