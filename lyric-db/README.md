# lyric-db

Driver-agnostic database access with typed rows, transactions, and pluggable backends.

## Platform parity

| Feature flag | Backend                                                                   | Status           |
|--------------|---------------------------------------------------------------------------|------------------|
| `dotnet`     | Npgsql + Microsoft.Data.Sqlite ADO.NET drivers (`Db.Kernel.Net`)          | **Real** (#5407) |
| `jvm`        | PostgreSQL JDBC + SQLite JDBC (`Db.Kernel.Jvm`, org.postgresql / org.xerial) | **Real** (#8932) |

`dotnet` and `jvm` are mutually exclusive and select the kernel; `dotnet` is
in the default feature set, and a `--target jvm` build swaps it for `jvm`
(docs/24 section 2.2). Build the JVM kernel explicitly with
`--target jvm --no-default-features --features jvm,sqlite,postgres`, after
`lyric restore` has fetched the two drivers declared in `[maven]`.

**Both targets are genuinely implemented**, not stubs: `query`, `execute`,
`transaction`/`commit`/`rollback` are real `System.Data.Common`
(`DbConnection`/`DbCommand`/`DbDataReader`/`DbTransaction`) calls on `dotnet`
and real `java.sql` (`Connection`/`PreparedStatement`/`ResultSet`) calls on
`jvm`, against whichever driver you connect with. `tests/db_tests.l`,
`tests/db_sqlite_tests.l` and `tests/db_postgres_connect_tests.l` run
unchanged on both targets.

- **SQLite (Microsoft.Data.Sqlite / sqlite-jdbc)** is exercised end-to-end in
  CI against a real `:memory:` database on both targets: DDL, parameterised
  insert, typed value extraction (`Long`/`Int`/`Double`/`String`/`Bool`/`NULL`/
  `Bytes`), affected-row counts, transaction commit visibility, transaction
  rollback invisibility, and SQL-error mapping. See `tests/db_sqlite_tests.l`.
- **Postgres (Npgsql / pgjdbc)** shares the exact same query/execute/
  transaction code path as SQLite on each target but has **no live server
  available in CI**, so CI verifies only connect-failure error mapping
  (`tests/db_postgres_connect_tests.l`: connecting to a closed TCP port maps to
  a `CONNECT_ERROR` `DbError`, not a panic). The JVM kernel was additionally
  driven by hand against a live PostgreSQL 16 server when it landed (typed
  columns `integer`/`bigint`/`real`/`double precision`/`numeric`/`boolean`/
  `text`/`bytea`/`timestamp`/`timestamptz`/`date`/`uuid`/`jsonb`/`smallint`,
  bound parameters, transaction commit, rollback after a failed statement, and
  an authentication failure), but that run is not part of CI.

### JVM kernel notes (`Db.Kernel.Jvm`)

- **DSNs.** `postgres://` / `postgresql://` URIs and `jdbc:postgresql:` URLs;
  `sqlite://<path>`, `sqlite::memory:` and `jdbc:sqlite:` URLs. The user name
  and password are passed to the driver as connection properties, never spliced
  into the URL. Npgsql keyword strings (`Host=...;Username=...`) and
  Microsoft.Data.Sqlite `Data Source=...` strings are .NET-only and return a
  `CONNECT_ERROR` on `jvm`.
- **Placeholders.** The SQL text uses the same `@p0, @p1, ...` placeholders on
  both targets. JDBC only has positional `?`, so the kernel rewrites each
  `@p<N>` that is code (not inside a `'...'` literal, a `"..."` identifier, a
  comment or a dollar-quoted body) to `?` and binds by index, which also lets a
  placeholder repeat or appear out of order. Values are always bound with
  `setString`, never interpolated.
- **String binding.** The PostgreSQL connection sets `stringtype=unspecified`,
  so the server infers the parameter type (`WHERE id = @p0` with `"42"`
  compares as an integer), matching what SQLite's type affinity gives for free.
- **Pooling.** `poolSize` is validated but one JDBC connection is opened; wrap
  `connect` calls in your own pool if you need one. `connectTimeoutMs` maps to
  the PostgreSQL `connectTimeout`/`loginTimeout` (whole seconds, rounded up)
  and to SQLite's `busy_timeout`.
- **Transactions.** JDBC has no transaction object, so `transaction()` turns
  auto-commit off on the connection and `commit`/`rollback` turn it back on. A
  transaction that is never finished leaves the connection in manual-commit
  mode until it is closed (which rolls the work back).
- **Typed columns.** Values are classified by the Java class of
  `ResultSet.getObject`. `timestamptz` renders as a UTC instant (`...Z`);
  `timestamp` and `date` render as the stored wall-clock value with no offset,
  so the JVM's default zone never shifts them.

### Native SQLite asset deployment

Microsoft.Data.Sqlite depends on `SQLitePCLRaw.lib.e_sqlite3`, which ships
a native shared library (`libe_sqlite3.so` on Linux) under a
`runtimes/<rid>/native/` NuGet asset folder. The Lyric CLI's `single`-output
bundler now copies this native asset (for the current build machine's host
RID) beside the build/test output, alongside the managed assemblies it
already co-located (#5573) — a plain `lyric build`/`lyric test` run resolves
it without any `LD_LIBRARY_PATH` workaround. It does not affect Npgsql,
which has no native asset dependency.

## Packages

| Package | Purpose |
|---|---|
| `Db` | Core types, `DbConnection` / `DbTransaction` interfaces, connection factories |
| `Db.Aspects` | Reusable aspect templates: `QueryLogging` and `SlowQueryAlert` |
| `Db.Kernel.Net` | Extern boundary on `dotnet`: Npgsql (PostgreSQL) and Microsoft.Data.Sqlite drivers |
| `Db.Kernel.Jvm` | Extern boundary on `jvm`: PostgreSQL JDBC and SQLite JDBC drivers |

## Quick start

```lyric
import Db

// Requires the "postgres" feature and LYRIC_CONFIG_DB_CONNECTION_URL
val conn = Db.connectFromEnv()?

match conn.query(Db.sql("SELECT id, name FROM users WHERE id = @p0"), ["42"]) {
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

**Placeholder syntax:** always use named placeholders (`@p0`, `@p1`, …, matching each parameter's zero-based position in the `params` array) in your SQL text, for both Postgres and SQLite. Positional `$1`/`$2`-style placeholders do **not** work against the Postgres driver here — passing a named parameter against `$N`-style SQL text makes Npgsql silently bind zero parameters, deterministically, on every call (`PostgresException 08P01`). See `Db.Kernel.Net`'s header comment for the full explanation.

## Features

```toml
[features]
default  = ["dotnet", "postgres", "sqlite"]
dotnet   = []   # Db.Kernel.Net (ADO.NET)
jvm      = []   # Db.Kernel.Jvm (JDBC); exclusive with dotnet
postgres = []
sqlite   = []
```

**Both `postgres` and `sqlite` are active by default** — a plain
`lyric build`/`lyric test` against this library's own manifest (which is
what every path/workspace dependent gets; Lyric features are private to
the package that declares them, so a consumer cannot override this
library's own feature selection — see `docs/24-build-features.md` §2.2)
links both drivers. Only the features you activate are linked; `postgres`
and `sqlite` can be active simultaneously, whereas the `dotnet`/`jvm` kernel
features are mutually exclusive, like `lyric-session`'s.

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

`POOLSIZE`/`CONNECTTIMEOUTMS`/`PASSWORD` are read by `connectFromEnv`
(#6359). `QUERYTIMEOUTMS` is parsed nowhere yet — no kernel code sets
`DbCommand.CommandTimeout` — tracked as a follow-up. `PASSWORD` is **not**
currently redacted from logs/diagnostics: nothing in this library
implements that today (a `config { }` block's `@sensitive` field
annotation exists per docs/25-config-blocks.md, but is declared-and-inert
in v1, and doesn't apply to a plain env-var read like this one regardless).

## SQL text (`SqlText`)

`query`, `execute`, `queryOne`, `dbQuery` and `dbExecute` take a `SqlText`,
never a `String`. A statement built by concatenation or interpolation
(`"... WHERE name = '" + name + "'"`) therefore does not type-check; values go
in the `params` list as `@p0`, `@p1`, ....

| Constructor | Use | Check |
|---|---|---|
| `Db.sql(text)` | SQL literals (including literals joined with `+`) | contract: `sqlIsWellFormed(text)` |
| `Db.trySql(text)` | text you want rejected as an `Err` (`SQL_REJECTED`), not a panic | same check |
| `Db.unsafeRawSql(text)` | text really assembled at run time (a table name from an allow-list, a fixed column list) | non-blank only |

`sqlIsWellFormed` accepts a single statement (optional trailing `;`) with
terminated string literals, no `--` or `/* */` comments outside a literal, and
only `@p<N>` placeholders. It is defence in depth against spliced text, not a
proof of safety: a number or identifier interpolated into otherwise valid SQL
still passes. Keep `sql(...)` arguments literal, and review every
`unsafeRawSql` call (`grep -rn unsafeRawSql`). `Db.sqlToString(stmt)` returns
the text for `DbConnection` implementations.

**Parameter count.** A `SqlText` records how many parameters it expects: one
more than its highest `@p<N>` outside a string literal (`Db.sqlPlaceholderCount`).
`query` and `execute` on a connection and on a transaction return
`Err(DbError(code = "PARAM_COUNT_MISMATCH"))` before the statement reaches a
driver when `params.length` differs (`Db.sqlParamsError` is the same check for
`DbConnection` implementations of your own). A gap still counts (`@p0` and
`@p2` need three values), so supply a value for every index up to the highest.

**Lint.** `lyric lint` rule `L008` warns on a `sql(...)` / `Db.sql(...)` call
whose argument is not a string literal or a `+` chain of literals, pointing at
`unsafeRawSql` for audited dynamic text (#8520).

**Migrating from `String`:** wrap each literal in `Db.sql(...)`; wrap a
deliberately dynamic fragment in `Db.unsafeRawSql(...)` with a comment saying
why it is safe. A `DbConnection`/`DbTransaction` implementation changes its
`sql` parameter type to `Db.SqlText`. This is a breaking change to the
`@stable` surface (decision D220).

## DbConnection interface

```lyric
pub interface DbConnection {
  func query(sql: in SqlText, params: in [String]): Result[[DbRow], DbError]
  func execute(sql: in SqlText, params: in [String]): Result[Int, DbError]
  func transaction(): Result[DbTransaction, DbError]
  func close(): Unit
}
```

## DbTransaction interface

```lyric
pub interface DbTransaction {
  func query(sql: in SqlText, params: in [String]): Result[[DbRow], DbError]
  func execute(sql: in SqlText, params: in [String]): Result[Int, DbError]
  func isActive(): Bool
  func commit(): Result[Unit, DbError]
  func rollback(): Result[Unit, DbError]
}
```

`isActive()` is true until the transaction is committed or rolled back. On
a finished transaction `query`, `execute` and `commit` return an `Err` with
code `TX_FINISHED` without reaching the driver (#7241). `rollback` is
idempotent and returns `Ok` after the transaction has finished, so a
cleanup path can call it unconditionally.

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
the kernel inspects each value's real type (the CLR type from
`DbDataReader.GetFieldType` on `dotnet`, the Java class of
`ResultSet.getObject` on `jvm`) and maps it to the matching `DbValue`
variant. The tables below give the CLR source; on `jvm` the equivalents are
`Integer`/`Long`/`Short`/`Byte` (`DbInt`/`DbLong`, by magnitude), `Float`/
`Double`, `Boolean`, `String`, `byte[]`, `BigDecimal` (`DbDecimal`, plain
text), `Timestamp`/`Date` (`DbDateTime`). The `DbValue` variants are:

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

`Long`/`Double`/`Bool`/`String`/`Bytes`/`Null` are exercised end-to-end
against a real SQLite database (`tests/db_sqlite_tests.l`).

`Int` is also exercised end-to-end, but with a caveat worth knowing:
Microsoft.Data.Sqlite picks the reader's CLR type **per stored value, not
per declared column type** — an `INTEGER` column reports `System.Int32`
(`DbInt`) while every stored value fits Int32 range, but reports
`System.Int64` (`DbLong`) the moment a value overflows it (SQLite has no
native 32-bit integer storage class; this is Microsoft.Data.Sqlite's own
choice of CLR type per row, verified empirically). `Db.getInt`/
`Db.getIntOpt` accept a `DbLong` whose value fits Int32 and return it as an
`Int`, so callers get a consistent `Int`-typed accessor regardless of which
variant the driver happened to pick for a given value (#5597). A `DbLong`
outside Int32 range is never truncated into a plausible-looking wrong value
(#7241): `getInt` returns `0` and `getIntOpt` returns `None`. Use
`Db.getLong` for columns that may hold such values. Pattern-matching
`Db.col(...)` directly still sees the real `DbInt`/`DbLong` split. Both
cases (fits Int32, overflows Int32) are asserted in
`tests/db_sqlite_tests.l`.

**`Float` cannot be exercised against SQLite at all**: Microsoft.Data.Sqlite
always reports a `REAL`-storage-class value as `System.Double`
(`DbDouble`), never `System.Single` (`DbFloat`), regardless of the declared
column type name (`REAL`, `FLOAT`, …) — verified empirically. There is no
SQLite-reachable path to `DbFloat` at all, and no live Postgres server is
available in CI/sandboxes to exercise it there either (Postgres's `real`
column type does map to `System.Single` via Npgsql). The `DbFloat` encoding
path was verified correct in isolation (a standalone repro against
`System.Single` directly) but not through this library's own kernel
end-to-end — a real gap, tracked as follow-up alongside live-server
Postgres coverage.

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

Any other column type (e.g. `Int16` on .NET, `Guid`/`UUID`, `jsonb`) is a
documented scope boundary: it arrives as a plain `DbText` string via
`Object.ToString()` rather than a dedicated typed variant.

## Transactions

```lyric
val tx = conn.transaction()?

match tx.execute(Db.sql("INSERT INTO events (name) VALUES (@p0)"), ["login"]) {
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
