# Chapter 26: Database Access

The `lyric-db` library provides driver-agnostic database access with typed
rows and transactions.  Two drivers are available: PostgreSQL (via Npgsql)
and SQLite (via Microsoft.Data.Sqlite), each gated by a feature flag.

## Adding the dependency

```toml
# lyric.toml
[dependencies]
"Lyric.Db" = { path = "../lyric-db" }

[features]
postgres = []   # enable to use connectPostgres()
sqlite   = []   # enable to use connectSqlite()
```

Enable only the features you need; both can be active simultaneously.

## Connecting

```lyric
import Db

// Requires LYRIC_CONFIG_DB_CONNECTION_URL
val conn = Db.connectPostgres()?

// Use the connection...

conn.close()
```

## Queries

```lyric
match conn.query("SELECT id, name FROM users WHERE id = $1", ["42"]) {
  case Ok(rows) ->
    for row in rows {
      val name = Db.col(row, "name")
      match name {
        case DbValue.DbText(s) -> println(s)
        case DbValue.DbNull    -> println("(null)")
        case _                 -> ()
      }
    }
  case Err(e) -> eprintln("query failed: " + e.message + " [" + e.code + "]")
}
```

## DML (INSERT / UPDATE / DELETE)

```lyric
match conn.execute("INSERT INTO events (name) VALUES ($1)", ["login"]) {
  case Ok(n)  -> println("inserted " + n.toString() + " rows")
  case Err(e) -> eprintln("insert failed: " + e.message)
}
```

`execute` returns the number of affected rows.

## Transactions

```lyric
val tx = conn.transaction()?

match tx.execute("INSERT INTO orders (user_id) VALUES ($1)", [userId]) {
  case Ok(_) ->
    match tx.execute("UPDATE users SET order_count = order_count + 1 WHERE id = $1", [userId]) {
      case Ok(_)  -> tx.commit()?
      case Err(e) -> { tx.rollback(); return Err(e) }
    }
  case Err(e) -> { tx.rollback(); return Err(e) }
}
```

If neither `commit()` nor `rollback()` is called before the connection is
closed, the transaction is rolled back automatically.

## DbValue variants

All column values are typed:

| Variant | Payload | Lyric type |
|---|---|---|
| `DbNull` | — | — |
| `DbInt(value)` | `Int` | 32-bit integer |
| `DbLong(value)` | `Long` | 64-bit integer |
| `DbFloat(value)` | `Float` | 32-bit float |
| `DbDouble(value)` | `Double` | 64-bit float |
| `DbBool(value)` | `Bool` | boolean |
| `DbText(value)` | `String` | text or varchar |
| `DbBytes(value)` | `[Byte]` | binary data |

## Row access helpers

`Db.col(row, name)` extracts a column by name; returns `DbValue.DbNull` if
the column is absent.

## Configuration

Runtime config (prefix `LYRIC_CONFIG_DB_CONNECTION_`):

| Env var | Default | Meaning |
|---|---|---|
| `URL` | *(required)* | Connection URL |
| `POOLSIZE` | `10` | Pool size (1–100) |
| `CONNECTTIMEOUTMS` | `5000` | Connect timeout in ms |
| `QUERYTIMEOUTMS` | `30000` | Query timeout in ms |
| `PASSWORD` | `""` | Password override (`@sensitive`) |

The `PASSWORD` field is marked `@sensitive` and will not appear in logs.

## Aspect templates

### QueryLogging

Logs handler entry (`"db → name"`) and exit (`"db ← name (Nms)"`):

```lyric
import Db.Aspects
import Std.Logging

aspect DbLog from Db.Aspects.QueryLogging {
  matches: name like "handle*"
  config { level: Std.Logging.LogLevel = Std.Logging.LogLevel.Debug }
}
```

### SlowQueryAlert

Logs a warning when total handler time exceeds the threshold:

```lyric
aspect SlowDb from Db.Aspects.SlowQueryAlert {
  matches: name like "handle*"
  inside:  DbLog
  config { thresholdMs: Int = 200 }
}
```

## DbConnection and DbTransaction interfaces

The `DbConnection` and `DbTransaction` interfaces are the extension points.
Implement them to add a new driver or to build a test double:

```lyric
record MockConnection {}

impl Db.DbConnection for MockConnection {
  func query(sql: in String, params: in [String]): Result[[Db.DbRow], Db.DbError] {
    Ok([])
  }
  func execute(sql: in String, params: in [String]): Result[Int, Db.DbError] {
    Ok(0)
  }
  func transaction(): Result[Db.DbTransaction, Db.DbError] {
    Err(Db.DbError(message = "not implemented", code = "MOCK"))
  }
  func close(): Unit { () }
}
```
