# Chapter 20: Runtime Configuration

Lyric services often need to read configuration at startup — database URLs,
port numbers, feature flags, and timeouts.  The `config` block provides a
typed, env-var-backed way to declare and consume runtime configuration without
ceremony.

## Declaring a config block

```lyric
config Server {
  host: String                = "0.0.0.0"
  port: Int range 1 ..= 65535 = 8080
}
```

Each field in a `config` block declares:

- A type (any primitive or `String`).
- An optional range constraint for numeric fields.
- An optional default value.  Fields without a default are *required*; the
  process panics at startup if a required field's env var is absent.

## Environment variable naming

The compiler derives the env var name automatically from the package and block
names:

```
LYRIC_CONFIG_<PACKAGE>_<BLOCK>_<FIELD>
```

All letters are uppercased.  Nested package names use `_` as a separator.

| Package | Block | Field | Env var |
|---|---|---|---|
| `Web` | `Server` | `port` | `LYRIC_CONFIG_WEB_SERVER_PORT` |
| `Db` | `Connection` | `poolSize` | `LYRIC_CONFIG_DB_CONNECTION_POOLSIZE` |
| `Std.Logging` | `Defaults` | `level` | `LYRIC_CONFIG_STD_LOGGING_DEFAULTS_LEVEL` |

## Reading config values

Inside the same package, config fields are read like module-level `val`
bindings:

```lyric
config Connection {
  url:      String
  poolSize: Int range 1 ..= 100 = 10
}

func connectDb(): Result[DbConnection, DbError] {
  DbKernel.connect(Connection.url, Connection.poolSize)
}
```

Config fields are read-only.  There is no mechanism to mutate a config value
at runtime.

## Sensitive fields

Mark a field `@sensitive` to prevent its value from appearing in logs,
diagnostic output, or config dumps:

```lyric
config Connection {
  url:      String
  @sensitive
  password: String = ""
}
```

The value is still read from the env var normally; only the display is
suppressed.

## Range constraints

Numeric fields accept `range <lo> ..= <hi>` to restrict the valid domain:

```lyric
config Cache {
  ttlSeconds:  Int range 0 ..= 86400  = 300
  maxEntries:  Int range 1 ..= 1000000 = 10000
}
```

The range is enforced at startup: a value outside the range is treated as
a missing required field (process panics with a descriptive message).

## Library config blocks

Each `config` block is scoped to its declaring package.  When you add a
library such as `lyric-db` or `lyric-web` as a dependency, that library's
config blocks are automatically available; you configure them by setting the
corresponding env vars.  You never need to re-declare or forward config fields.

## Multiple config blocks

A package can declare multiple `config` blocks to group related fields:

```lyric
config Connection {
  url:      String
  poolSize: Int = 10
}

config Timeouts {
  connectMs: Int range 100 ..= 30000  = 5000
  queryMs:   Int range 100 ..= 300000 = 30000
}
```

Both blocks contribute env vars under the same package prefix.

## Config vs wire injection

`config` blocks are for *scalar* values read from env vars (URLs, timeouts,
feature flags).  If you need to inject a *typed value* — a database connection,
a cache store, or a service dependency — use a `wire {}` block instead
(see Chapter 11).

The two mechanisms are complementary:

- `config` → primitive values from the environment.
- `wire`   → constructed objects from DI.

## Summary

| Concept | Syntax |
|---|---|
| Declare a config block | `config Name { field: Type = default }` |
| Required field | Omit the `= default` |
| Range-constrained field | `field: Int range lo ..= hi = default` |
| Sensitive field | `@sensitive field: String = ""` |
| Read a field | `BlockName.fieldName` (same package) |
| Env var name | `LYRIC_CONFIG_<PKG>_<BLOCK>_<FIELD>` |
