# Runtime Configuration

Applications need typed, declared, fail-fast configuration. The naive approach — sprinkling `Std.Environment.getVar` calls throughout startup code — suffers from the same problems in every language: ad-hoc parsing scattered across multiple files, no central list of what env vars a program reads, silent acceptance of empty strings, and failures that surface in the middle of `main` instead of before it starts. Lyric addresses this with `config` blocks: a module-scope construct that declares every runtime configuration value in one place, reads each from an environment variable before `main` runs, and aborts with a clear diagnostic if anything is missing or malformed.

This chapter covers the full `config` surface: declaring blocks, understanding which field types are allowed, controlling required versus defaulted fields, reading the env-var naming rule, marking fields as sensitive, and splitting configuration across multiple named blocks. The chapter closes with the canonical question — features or config? — and pointers to the overlap with chapter 19.

::: note
**Implementation status.** The `config` surface (parser, AST, type-check, and symbol-table entries) is in the F# bootstrap and the self-hosted compiler. The env-var startup lowering — the compiler-generated initialiser that reads env vars before `main` runs — is gated on the self-hosted compiler's M5.2 stage 3+ AST-to-MSIL bridge. For now, `config` blocks parse and type-check correctly but produce no runtime behaviour. The design here describes the full v1 target.
:::

## §20.1 Declaring a config block

A `config` block is a top-level item, written at module scope alongside `func`, `type`, `wire`, and `aspect`:

```lyric
package MyApp.Server

import Std.Core

config Settings {
  port:   Int range 1 ..= 65535 = 8080
  host:   String                = "0.0.0.0"
  secret: String                             // required — no default
  level:  LogLevel              = LogLevel.Info
}
```

Each line inside the block is a field declaration: a name, a colon, a type, and an optional `= <constant>` default. Fields with no default are *required* — the process will abort before `main` if the corresponding env var is absent or empty. Fields with a default are optional — the default is used when the env var is unset.

Accessing fields uses the block name as a static qualifier:

```lyric
func main(): Unit {
  let server = Http.bind(Settings.host, Settings.port)
  Std.Log.setLevel(Settings.level)
  // ...
}
```

`Settings` is **not** an instantiable type. It has no constructor, no methods, and you cannot pass it to a function as a value. It is a static namespace whose fields are populated once, before `main` begins, and remain immutable for the process lifetime.

### §20.1.1 Visibility

Config blocks are package-private. A block declared in `MyApp.Server` is accessible only within `MyApp.Server`. Other packages that need the value must receive it as a wire `@provided` parameter or declare their own config block from their own env vars. Cross-package config sharing is a deliberate non-goal: it enforces each package owning its own configuration surface, which composes cleanly with `@proof_required` modules (the verifier sees only the package's own declared values).

Writing `pub config` is a compile-time error:

```
error G0008: config blocks are package-private; remove 'pub'
```

## §20.2 Field types

The set of allowed field types is narrow. Every field must parse cleanly from a single environment-variable string, so the type system for config is deliberately simpler than the main type system:

| Type | Env-var format | Example |
|---|---|---|
| `Bool` | `"true"` / `"false"` (case-insensitive), `"1"` / `"0"` | `ENABLED=true` |
| `Int` | Base-10 signed integer | `PORT=8080` |
| `Long` | Base-10 signed long | `LIMIT=1099511627776` |
| `Float` | IEEE-754 round-trip parse | `RATIO=0.5` |
| `Double` | IEEE-754 round-trip parse | `RATE=0.001` |
| `String` | Raw env-var content, unmodified | `HOST=app.example.com` |
| `Int range N ..= M` | Parsed as `Int`, then range-checked | `PORT=8080` |
| Simple enum (no payload variants) | Case name, exact match | `LEVEL=Info` |
| `[T]` where T is any of the above | Comma-separated; `\,` escapes a literal comma; empty string → `[]` | `TAGS=a,b,c` |

### §20.2.1 Rejected types

The following types are rejected at compile time with diagnostic `G0009`:

- Records or structs
- Nested lists (`[[String]]`)
- `Option[T]` — express optionality via a default, not nullability
- `Result[T, E]` — parse failures are startup-fatal, not data
- Function types, generic types beyond the list shape above

If a config value naturally has structure — say, a list of `{ host, port }` pairs — the v1 answer is to encode it as two parallel list fields or as a delimited string that the application parses after startup.

## §20.3 Required vs defaulted fields

A field is **required** when it has no `= value` clause. A field is **defaulted** when it has one.

```lyric
config Database {
  url:      String                       // required: no default
  poolSize: Int range 1 ..= 100 = 10    // defaulted: 10 when unset
}
```

At process startup, before `main` runs, the compiler-generated initialiser:

1. Reads the env var for each field.
2. For a required field that is unset or empty, aborts with exit code 78 and prints to stderr:
   ```
   lyric: required config 'Database.url' (env: LYRIC_CONFIG_MYAPP_SERVER_DATABASE_URL) is unset
   ```
3. For any field whose value fails to parse, aborts with exit code 78 and prints:
   ```
   lyric: config 'Database.poolSize' (env: LYRIC_CONFIG_MYAPP_SERVER_DATABASE_POOLSIZE)
          value '200' fails range check 1 ..= 100
   ```
4. After all fields are validated, passes control to `main`.

Exit code 78 is `EX_CONFIG` from `sysexits.h` — a configuration error that is not a programmer bug. Failing before `main` is intentional: half-initialised configuration state is harder to debug than a clean abort at the entry point.

The initialiser aborts on the **first** failure it encounters. The workflow is fix-as-you-go: start the process, read the diagnostic, set the env var, restart.

### §20.3.1 Defaults must be compile-time constants

A field default must be evaluable at compile time: integer and string literals, named constants imported from other modules, or simple arithmetic on literals. Calling `Std.Environment.getVar` or any function with side effects in a default is rejected:

```lyric
config Settings {
  retries: Int = 3                      // OK — integer literal
  tag:     String = Build.version       // OK — imported constant
  host:    String = Std.Env.hostname()  // error G0010: must be compile-time constant
}
```

This restriction keeps the initialiser simple and ensures that the `Lyric.Contract` embedded resource can record defaults verbatim for operator tooling.

## §20.4 Env-var derivation

For a `config` block named `<Block>` in package `<Pkg>`, each field `<field>` reads from:

```
LYRIC_CONFIG_<PKG_UPPER>_<BLOCK_UPPER>_<FIELD_UPPER>
```

where `<PKG_UPPER>` is the package name with `.` replaced by `_` and all letters uppercased, `<BLOCK_UPPER>` is the block name uppercased, and `<FIELD_UPPER>` is the field name converted to upper-snake.

Package `MyApp.Server`, block `Settings`, field `host`:
```
LYRIC_CONFIG_MYAPP_SERVER_SETTINGS_HOST
```

Package `MyApp.Server`, block `Settings`, field `maxRetries`:
```
LYRIC_CONFIG_MYAPP_SERVER_SETTINGS_MAXRETRIES
```

The `LYRIC_CONFIG_` prefix is reserved for config blocks. Aspects use a parallel `LYRIC_ASPECT_` prefix; see `docs/26-aspects.md` for the exact rule.

### §20.4.1 Custom env-var names

A field may override the auto-derived name with a `via` clause:

```lyric
config Settings {
  host: String = "0.0.0.0" via "APP_HOST"
  port: Int    = 8080       via "APP_PORT"
}
```

`via "NAME"` reads from the literal env-var `APP_HOST` instead of the auto-derived `LYRIC_CONFIG_...` name. This is useful for matching existing deployment conventions or for short names in container-platform UIs. The `via` value must be upper-snake (letters, digits, underscores, no spaces, no dots, first character a letter or underscore); anything else is rejected with `G0011`.

## §20.5 Multiple config blocks per package

A package may declare any number of `config` blocks. Each must have a unique name within the package; duplicate names produce `G0012`. Each block owns its own env-var prefix, so fields across blocks never collide:

```lyric
package CheckoutService

config Http {
  port: Int range 1 ..= 65535 = 8080
  host: String                = "0.0.0.0"
}

config Database {
  url:      String                          // required
  poolSize: Int range 1 ..= 100 = 10
}

config Features {
  newCheckout: Bool     = false
  partners:    [String] = []
}
```

The env vars for this package:

```
LYRIC_CONFIG_CHECKOUTSERVICE_HTTP_PORT
LYRIC_CONFIG_CHECKOUTSERVICE_HTTP_HOST
LYRIC_CONFIG_CHECKOUTSERVICE_DATABASE_URL
LYRIC_CONFIG_CHECKOUTSERVICE_DATABASE_POOLSIZE
LYRIC_CONFIG_CHECKOUTSERVICE_FEATURES_NEWCHECKOUT
LYRIC_CONFIG_CHECKOUTSERVICE_FEATURES_PARTNERS
```

Multiple blocks also provide organisational clarity: operators reading a deployment manifest can tell immediately whether a missing var belongs to network, database, or feature-flag configuration.

Blocks initialise in declaration order within a file (lexical order across files). The first required-field failure aborts startup regardless of which block it belongs to.

## §20.6 Sensitive fields

Fields whose values should not appear in logs or diagnostics may be annotated with `@sensitive`:

```lyric
config Database {
  url:      String                 // required — URL may appear in logs
  @sensitive
  password: String                 // required — must never appear in logs
  @sensitive
  apiToken: String = ""            // optional with empty default
}
```

`@sensitive` is **purely declarative in v1** — no runtime redaction is applied by the current compiler. The annotation is reserved now so that v2 can light up automatic behaviour without a source break:

- Logging aspects will auto-redact sensitive field values.
- `lyric explain` and the LSP will redact sensitive values in hover output.
- The `Lyric.Contract` embedded resource records sensitive field names so deployment-time inspector tools can enumerate "what secrets does this service read" without running the binary.

For v1: treat `@sensitive` as documentation. The discipline of marking secrets now means you get free redaction the moment v2 ships the aspect-based tooling.

::: sidebar
**Why `@sensitive` instead of a distinct type?** The alternative was a `Secret[T]` wrapper type whose unwrap method is `@proof_required`. That is a correct design, but it means every function that receives a password must unwrap it explicitly, and it couples the config mechanism to the proof system. The annotation approach keeps config blocks self-contained: the type of `password` is `String` — you can pass it to `Http.setBasicAuth` without any ceremony — while the marker travels with the field in metadata for external tools. A `Secret[T]` type may arrive in a later milestone; `@sensitive` is compatible with it.
:::

## §20.7 Features vs config

Chapter 19 §19.7.1 covers this distinction from the feature side; here is the config side.

`@cfg(feature = "X")` is a **compile-time gate**: the annotated item is physically absent from the output assembly when the feature is inactive. There is no runtime branch, no IL, no metadata.

`config { … }` is a **runtime gate**: the item is always in the assembly; the env var decides what value it carries (or whether the process starts at all for required fields).

| Need | Use |
|---|---|
| "Compile out the logging aspect in release builds" | `@cfg(feature = "logging")` on the aspect |
| "Set log level at deploy time" | `config { level: LogLevel = LogLevel.Info }` |
| "Enable tracing in staging, disable in prod" | `config { tracingEnabled: Bool = false }` |
| "Ship a version with and without FFI backend" | `@cfg(feature = "ffi-backend")` on the implementation |
| "Choose database URL at deploy time" | `config { url: String }` (required, no default) |

**Rule of thumb.** `@cfg` answers *"is this code in my binary at all?"* `config { … }` answers *"given that it's in my binary, what does it do at runtime?"* When in doubt, use `config { … }` — it works across package boundaries and lets operators adjust behaviour without recompiling.

## Exercises

1. **Declare and access a config block**

   Write a package `MyApp.Api` with a `config Server` block containing four fields: `host` (String, default `"127.0.0.1"`), `port` (Int range 1..=65535, default 3000), `requestTimeoutMs` (Int, default 5000), and `apiKey` (String, required). Write a `func main()` that reads `Server.host` and `Server.port` and prints `"listening on <host>:<port>"`. What env var must be set before the process will start? What happens if you omit it?

2. **Env-var naming rule**

   For a package named `Billing.Processor`, a block named `Stripe`, and a field named `webhookSecret`, derive the auto-generated env-var name by hand following the rule in §20.4. Then add a `via "STRIPE_WEBHOOK_SECRET"` clause to the field declaration. Which name wins? What happens if you write `via "stripe_webhook_secret"` (lower-case)?

3. **Required fields and fail-fast**

   Declare a `config Database` block with a required field `url: String`. Run the compiled program without setting the env var. What is the exit code? What does the stderr message contain? Now set the env var to an empty string. Does the process start? Consult §20.3 for the distinction between `G0001` and `G0002`.

4. **Multiple blocks and field type variety**

   Write a package with three config blocks: one for HTTP settings (port, host), one for feature flags (three `Bool` fields with `false` defaults), and one for a list field (`allowedOrigins: [String] = []`). Set `allowedOrigins` to `"app.example.com,api.example.com"` via its env var. What value does the field hold at runtime? What does `allowedOrigins` hold if the env var is set to the empty string?

5. **Features vs config decision**

   Your service has a metrics emission path. In development you want it off; in production you want it on. Two colleagues disagree: one says use `@cfg(feature = "metrics")`; the other says use `config { metricsEnabled: Bool = false }`. Describe at least one scenario where each approach is strictly correct and the other is wrong. Under the rule of thumb in §20.7, which should you default to when both would work?
