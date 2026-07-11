# lyric-db

Driver-agnostic database access with typed rows, transactions, and pluggable backends.

## Platform parity

| Feature flag | Backend                                                  | Status                |
|--------------|-----------------------------------------------------------|-----------------------|
| `dotnet`     | Npgsql + Microsoft.Data.Sqlite ADO.NET drivers            | **Real** (#5407)      |
| `jvm`        | PostgreSQL JDBC + SQLite JDBC via `lyric.db.*` shim JAR   | Not real — see below  |

**`dotnet` is genuinely implemented**, not a stub: `query`, `execute`,
`transaction`/`commit`/`rollback` are real `System.Data.Common`
(`DbConnection`/`DbCommand`/`DbDataReader`/`DbTransaction`) calls against
whichever driver you connect with — this replaces the prior design, where
every operation past `connect` unconditionally returned
`Err("not available in bootstrap")` regardless of driver (#5407).

- **SQLite (Microsoft.Data.Sqlite)** is exercised end-to-end in CI against
  a real `:memory:` database: DDL, parameterised insert, typed value
  extraction (`Long`/`Double`/`String`/`Bool`/`NULL`/`Bytes`), affected-row
  counts, transaction commit visibility, transaction rollback
  invisibility, and SQL-error mapping. See `tests/db_sqlite_tests.l`.
- **Postgres (Npgsql)** shares the exact same query/execute/transaction
  code path as SQLite (both operate through the shared
  `System.Data.Common` base classes) but has **no live server available
  in CI/sandboxes**, so only connect-failure error mapping is verified
  (`tests/db_postgres_connect_tests.l`: connecting to a closed TCP port
  maps to a `CONNECT_ERROR` `DbError`, not a panic). The query/execute
  code itself is not driver-specific — see "Kernel boundary" below — so
  this is a live-server verification gap, not an implementation gap, but
  it is an honest one: nothing has driven a real `INSERT`/`SELECT`
  against a real PostgreSQL server.

**`jvm` is still vaporware**, unchanged by #5407: `Db.Kernel.Jvm`
(`src/_kernel/jvm/db_kernel.l`) is not registered in this manifest's
`[project.packages]`, so it is not even compiled today, and its shared
operations depend on a `lyric.db.JdbcConnections` Java helper class that
does not exist anywhere in this repository — the JDBC bindings against
`org.postgresql:postgresql` and `org.xerial:sqlite-jdbc` are declarative
only. Standing up a real `--target jvm` path (JDBC-backed, dropping the
fictional helper) is out of scope for #5407 and tracked as follow-up
work — see `docs/33-platform-parity-remediation.md`.

### Known limitation: native SQLite asset deployment

Microsoft.Data.Sqlite depends on `SQLitePCLRaw.lib.e_sqlite3`, which ships
a native shared library (`libe_sqlite3.so` on Linux) under a
`runtimes/<rid>/native/` NuGet asset folder. **The Lyric CLI's `single`-output
bundler does not copy this native asset** (or emit a `.deps.json` that would
let the .NET runtime's default probing find it) into the build/test output
directory, so a plain `lyric build`/`lyric test` run may fail at first
SQLite connection with `System.Exception: The type initializer for
'Microsoft.Data.Sqlite.SqliteConnection' threw an exception.` unless the
native library is independently reachable — e.g. via
`LD_LIBRARY_PATH=<nuget-cache>/sqlitepclraw.lib.e_sqlite3/<version>/runtimes/linux-x64/native`
pointed at the restored package. This is a build-tooling gap (the CLI
bundler, not this library's `.l` source), out of scope for #5407 and
tracked as follow-up work; it does not affect Npgsql, which has no native
asset dependency.

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
val conn = Db.connectFromEnv()?

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

```toml
[features]
default  = ["postgres", "sqlite"]
postgres = []
sqlite   = []
```

**Both `postgres` and `sqlite` are active by default** — a plain
`lyric build`/`lyric test` against this library's own manifest (which is
what every path/workspace dependent gets; Lyric features are private to
the package that declares them, so a consumer cannot override this
library's own feature selection — see `docs/24-build-features.md` §2.2)
links both drivers. Only the features you activate are linked; both can be
active simultaneously (unlike, say, `lyric-session`'s `dotnet`/`jvm`
features, which are mutually exclusive).

### Feature combinations

`Db.connect` / `Db.connectFromEnv` / `Db.Kernel.Net.connectDsn` sniff the
DSN's scheme prefix and dispatch to whichever driver matches — but they do
this by referencing **both** `connectPostgres` and `connectSqlite`
unconditionally in their own function bodies, so **building this library
with only one of the two features active fails to compile those specific
functions** (a whole-program compile-time error, not a runtime surprise;
Lyric's `@cfg` predicates support only single `feature = "X"` equality
checks — no boolean composition — so a dispatcher spanning "either driver
might be absent" genuinely cannot be expressed without both being
guaranteed present). This mirrors `lyric-storage`'s retired
`connect(provider: String)` dispatcher, which hit the identical problem
and was replaced with explicit per-backend constructors as the canonical
API.

If you deliberately build this library with only one driver feature
active (e.g. to avoid the Npgsql dependency in a SQLite-only deployment),
call `Db.connectPostgres(...)` / `Db.connectSqlite(...)` directly instead
of `Db.connect` / `Db.connectFromEnv` — both are available whenever their
own feature is active, independent of the other.

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

### Typed column coverage

Column values arrive **genuinely typed** from the driver (not stringified):
the kernel inspects each column's real CLR type
(`DbDataReader.GetFieldType`) and maps it to the matching `DbValue`
variant. The `DbValue` variants are:

| Variant | Payload | CLR source type |
|---|---|---|
| `DbNull` | — | `IsDBNull` |
| `DbInt(value)` | `Int` | `System.Int32` |
| `DbLong(value)` | `Long` | `System.Int64` |
| `DbFloat(value)` | `Float` | `System.Single` |
| `DbDouble(value)` | `Double` | `System.Double` |
| `DbBool(value)` | `Bool` | `System.Boolean` |
| `DbText(value)` | `String` | `System.String` |
| `DbBytes(value)` | `[Byte]` | `System.Byte[]` (BLOB) |
| `DbDecimal(value)` | `String` (invariant-culture text) | `System.Decimal` |
| `DbDateTime(value)` | `String` (ISO 8601 UTC, `"o"` round-trip format) | `System.DateTime` |

`Int`/`Long`/`Float`/`Double`/`Bool`/`String`/`Bytes`/`Null` are exercised
end-to-end against a real SQLite database (`tests/db_sqlite_tests.l`).
**`Decimal` and `DateTime` are not exercised by any test in this
repository** — Microsoft.Data.Sqlite reports plain `Double`/`String` CLR
types for `DECIMAL`/`DATETIME`-declared SQLite columns regardless of the
declared column type name (verified empirically; SQLite has no native
decimal or datetime storage class), so there is no SQLite-reachable path
to exercise them, and no live Postgres server is available in CI/sandboxes
to exercise them there either. The `DbDecimal`/`DbDateTime` encoding paths
were verified correct in isolation (a standalone C# repro against
`System.Decimal`/`System.DateTime` directly) but not through this
library's own kernel end-to-end — a real gap, tracked as follow-up
alongside live-server Postgres coverage.

Any other CLR column type (e.g. `Int16`, `Guid`) is a documented scope
boundary: it arrives as a plain `DbText` string via `Object.ToString()`
rather than a dedicated typed variant.

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

- `Db.Kernel.Net.connectPostgres(...)` — opens a real Npgsql `DbConnection`
- `Db.Kernel.Net.connectSqlite(...)` — opens a real Microsoft.Data.Sqlite `DbConnection`
- `Db.Kernel.Net.connectDsn(...)` — DSN scheme dispatch to one of the above
- `Db.Kernel.Net.query/execute/beginTransaction/txQuery/txExecute/commitTransaction/rollbackTransaction/close`
  — shared `System.Data.Common` operations; identical code path for both drivers

Handles are real ADO.NET object references (`Db.Kernel.Net.DbConn` /
`Db.Kernel.Net.DbTxT`, bound to `System.Data.Common.DbConnection` /
`DbTransaction`), not an integer registry — `NativeConnection` and
`NativeTransaction` in `db.l` hold them directly and implement the public
`DbConnection`/`DbTransaction` interfaces by forwarding to the kernel.

## Decision log

See `docs/03-decision-log.md` D056.
