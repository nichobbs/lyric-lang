# 25 — Config Blocks (typed, env-backed, read-once)

**Status:** Drafted.  v1 implementation in progress.
**Implementation:** prerequisite for `docs/26-aspects.md` runtime
toggles.  Independently useful for application-level configuration.
**Decision-log entry:** D046.

> **v1 scope note.** The first implementation ships a deliberately
> narrow subset of the design below: module-scope `config Name { ... }`
> blocks; field types limited to `Bool`, `Int`, and `String` (no
> range subtypes, enums, or lists in v1); literal defaults only (no
> imported-constant references); auto-derived env vars
> `LYRIC_CONFIG_<PKG>_<BLOCK>_<FIELD>` (no `via "NAME"` overrides);
> read-once-at-startup with fail-fast on required fields.  Lists,
> ranges, enums, `via`, and `@sensitive` behaviour are deferred to
> v1.1; the design below describes the full target.

---

## 1. Motivation

Lyric programs need a typed way to read configuration at startup —
ports, hostnames, log levels, feature flags, sample rates. Today's
options are all bad:

- **Hand-rolled `Std.Environment.getVar`** at startup, with manual
  `tryParseInt` per field. No central declaration, no fail-fast, no
  type safety beyond the parse layer.
- **Constants in source.** Edit-and-recompile-to-change-config.
- **External config files.** No primitive for them yet, and no clear
  story for how they interact with `@runtime_checked` /
  `@proof_required`.

Aspects (`docs/26-aspects.md`) need typed config to support runtime
toggles without inventing a new mechanism. This document promotes
config blocks to a general primitive — **typed, env-var-backed,
read once at process startup, fail-fast on malformed or
missing-required values** — that aspects use as one consumer among
many.

---

## 2. Module-scope config blocks

A `config` block is a top-level item, peer to `func`, `type`, `wire`,
`aspect`:

```lyric
package MyApp.Server

import Std.Core

config Settings {
  port:     Int range 1 ..= 65535 = 8080
  host:     String                = "0.0.0.0"
  features: [String]              = []
  secret:   String                                        // required
  level:    LogLevel              = LogLevel.Info
}
```

The block declares a **named** record of typed fields. Each field has:

- A name (lower-snake by convention; the field syntax is unchanged
  from records).
- A type — see §3 for the allowed set.
- An optional **compile-time-constant default**. Fields with no
  default are *required*: the process fails to start if the env var
  is missing or empty. See §6.

Multiple `config` blocks per package are allowed; each gets a distinct
name and its own env-var prefix (§5).

### 2.1 Access syntax

Fields are accessed via the block name as a static qualifier:

```lyric
func main(): Unit {
  let server = Http.bind(Settings.host, Settings.port)
  Std.Log.setLevel(Settings.level)
  ...
}
```

`Settings` is **not** an instantiable type; it has no constructor and
no methods. It's a static namespace whose fields are populated once,
at process startup, before `main` runs.

### 2.2 Visibility

Config blocks are **package-private**. A field declared in package
`MyApp.Server` is reachable only from inside `MyApp.Server`. Other
packages that need the value must:

- Receive it through a wire `@provided` parameter, or
- Read their own config block from their own env vars.

Cross-package config sharing is a deliberate non-goal. It encourages
each package to own its configuration surface, which composes better
with `@proof_required` (the verifier sees only what the package
itself declares).

`pub config` is **rejected** at parse time
(`G0008: config blocks are package-private; remove 'pub'`).

---

## 3. Field types

The field type set is intentionally narrow — every field must parse
cleanly from a single environment-variable string:

| Type | Parse rule | Example value |
|---|---|---|
| `Bool` | `"true"` / `"false"` (case-insensitive); `"1"` / `"0"` | `BOOL=true` |
| `Int` | base-10 signed integer | `PORT=8080` |
| `Long` | base-10 signed long | `LIMIT=1099511627776` |
| `Float` / `Double` | IEEE-754 round-trip parse (Lyric's existing `tryParseDouble`) | `RATE=0.25` |
| `String` | the raw env-var content, unmodified | `HOST=app.example.com` |
| Range subtype (e.g. `Int range 0 ..= 65535`) | parsed as base type, then range-checked | `PORT=8080` |
| Simple enum (closed sum type, no payloads) | case name, exact match | `LEVEL=Info` |
| `[T]` where `T` is one of the above | comma-separated, `\,` escapes a literal comma, empty string → `[]` | `EXCLUDE=foo,bar,baz` |

### 3.1 Out of scope

The following types are **rejected** at parse time:

- Records / structs (`G0009: record types not allowed in config block`)
- Nested lists (`[[String]]`)
- Maps / dictionaries
- `Option[T]` — express optionality via a default, not nullability
- `Result[T, E]` — parse failures are startup-fatal, not data
- Function types
- Generic types beyond the listed list shape

If a config value naturally has structure (e.g. a list of
`{ host, port }` pairs), the right answer in v1 is to encode it as
two parallel lists or as a delimited string the application parses.
v2 may add a file-based config source (§9) for richer shapes.

### 3.2 Sensitive marker

Fields whose values should not appear in logs / diagnostics may be
marked `@sensitive`:

```lyric
config Settings {
  @sensitive secret: String         // required, must be set
  @sensitive token:  String = ""    // optional; defaults are still valid
}
```

In v1 the marker is **purely declarative** — no behaviour is bound to
it. Future work (v2):

- Logging aspects auto-redact sensitive fields.
- `lyric explain` and the LSP redact in hover output.
- The `Lyric.BuildInfo` resource records sensitive field names so
  external tools can match the redaction policy.

The annotation is reserved now so v2 can light it up without a source
break.

---

## 4. Required vs defaulted fields, fail-fast

A field with no `=` default is **required**. At process startup:

1. The compiler-generated initialiser reads each env var.
2. If a required var is unset or empty, the process aborts before
   `main` runs with diagnostic text on stderr:
   ```
   lyric: required config 'Settings.secret' (env: LYRIC_CONFIG_MYAPPSERVER_SETTINGS_SECRET) is unset
   ```
3. If a present value fails to parse against the field type, the
   process aborts with:
   ```
   lyric: config 'Settings.port' (env: LYRIC_CONFIG_MYAPPSERVER_SETTINGS_PORT)
          value '99999' fails range check 1 ..= 65535
   ```
4. After all fields are read and validated, control passes to `main`.

Aborting before `main` runs is the explicit choice — half-initialised
config is worse than no startup. The exit code is 78 (configuration
error, sysexits.h `EX_CONFIG`).

### 4.1 Defaults are compile-time constants

A field's default expression must evaluate to a value at compile time:
literals, named constants from imported modules, simple arithmetic on
literals. `Std.Env.getVar(...)` calls or function calls with side
effects in defaults are rejected (`G0010: config default must be a
compile-time constant`).

This keeps the initialiser simple and makes the published
`Lyric.Contract` resource able to record defaults verbatim.

---

## 5. Env var derivation

For a config block `<BlockName>` declared in package `<PkgName>`, each
field `<fieldName>` reads from:

```
LYRIC_CONFIG_<PKG_NAME_UPPER>_<BLOCK_NAME_UPPER>_<FIELD_NAME_UPPER>
```

Where:
- `<PKG_NAME_UPPER>` is the package name with `.` replaced by `_` and
  uppercased.
- `<BLOCK_NAME_UPPER>` is the block name uppercased.
- `<FIELD_NAME_UPPER>` is the field name converted to upper-snake.

Example: `MyApp.Server` package, `Settings` block, `host` field →
`LYRIC_CONFIG_MYAPP_SERVER_SETTINGS_HOST`.

The `LYRIC_CONFIG_` prefix is reserved. Aspects (`docs/26-aspects.md`)
use a parallel `LYRIC_ASPECT_` prefix for ergonomics — see that doc
for the exact rule.

### 5.1 Custom env-var name

A field may override the auto-derived env-var name:

```lyric
config Settings {
  host: String = "0.0.0.0" via "APP_HOST"
}
```

`via "<NAME>"` reads from the literal env-var `APP_HOST` instead of
the auto-derived one. Useful for matching existing deployment
conventions or for short names in container-platform UIs.

`via` accepts only an upper-snake identifier; the parser refuses
spaces, dots, and lower case (`G0011: 'via' value must be upper-snake`).

---

## 6. Read-once-at-startup semantics

Config fields are populated **exactly once**, at process startup,
before `main` runs. The values are immutable for the process lifetime.

This rules out, by design:

- Re-reading env vars after a `setenv` call from inside the process
  (the cached value wins).
- Hot-reload of config without process restart (a v2 layered-config
  feature might offer this; v1 does not).
- Lazy initialisation (the field is read whether or not `main` ever
  references it).

The trade-off is simplicity. The verifier and the LSP can both treat
`Settings.port` as an opaque static value of type `Int`, with no
control-flow analysis needed.

### 6.1 Initialiser ordering

Multiple `config` blocks in the same process initialise in the order
they're declared (within a file: lexical; across files: same rule as
top-level static initialisers — currently lexical-by-source-path,
formalised in `docs/01-language-reference.md` §9 over time).

Required-field failures abort on the **first** failure. The error
message names the first failing field, not all of them — fix-as-you-go
is the assumed workflow.

---

## 7. Multiple named blocks

A package may declare any number of `config` blocks. Each must have a
unique name within the package:

```lyric
package MyApp.Server

config HttpSettings {
  port: Int = 8080
  host: String = "0.0.0.0"
}

config DbSettings {
  url:  String                          // required
  pool: Int range 1 ..= 100 = 10
}

config FeatureFlags {
  newCheckout: Bool = false
  asyncEmail:  Bool = true
}
```

The env-var prefix incorporates the block name, so flags don't
collide:

- `LYRIC_CONFIG_MYAPP_SERVER_HTTPSETTINGS_PORT`
- `LYRIC_CONFIG_MYAPP_SERVER_DBSETTINGS_URL`
- `LYRIC_CONFIG_MYAPP_SERVER_FEATUREFLAGS_NEWCHECKOUT`

Each block is independent: separate access namespace, separate
initialisation, separate fail-fast scope.

---

## 8. Diagnostics

| Code | Meaning |
|---|---|
| `G0001` | Required field unset at startup (runtime, exit code 78). |
| `G0002` | Required field present but empty (runtime, exit code 78). |
| `G0003` | Field value fails to parse against declared type (runtime, exit code 78). |
| `G0004` | Field value parses but fails range / enum check (runtime, exit code 78). |
| `G0005` | List field has unbalanced backslash escape (runtime, exit code 78). |
| `G0008` | `pub config` rejected at compile time. |
| `G0009` | Disallowed type in `config` field. |
| `G0010` | Field default is not a compile-time constant. |
| `G0011` | `via "..."` value is not upper-snake. |
| `G0012` | Two config blocks in the same package share a name. |
| `G0013` | Field name collision within a single block. |

The `G0001`–`G0005` codes are runtime; the rest are compile time.

---

## 9. Out of scope (and v2 candidates)

The following are **deliberately deferred**. The v1 design preserves
syntactic and runtime room for each.

- **File-based config source.** Reading a TOML/JSON/YAML file in
  addition to env vars. Plausibly adds a `from "config.toml"` clause
  to `config` blocks. Tracked as Q-config-001.
- **Layered config.** Defaults → file → env → CLI flags, with each
  layer overriding the previous. Tracked as Q-config-002. The v1
  design's "env-only, read-once" is a clean subset of any layered
  scheme.
- **Hot reload.** Changing a config value after process startup. Hard
  to reconcile with `@proof_required` (proofs depend on the value
  being fixed). Probably never; tracked as Q-config-003.
- **Validation beyond types.** Regex-checked strings, length-bounded
  lists, enum-conditional fields. The v1 stance: subtype your way to
  validation. If `port` should be in 1..=65535, write `Int range 1 ..=
  65535`. If `mode` is a finite set, write an enum. If you need a
  regex, that's a v2 conversation.
- **Sensitive-field redaction behaviour.** `@sensitive` is declared
  in v1 but inert. Logging aspects, `lyric explain`, and LSP hover
  redaction land together in v2 once the aspect ecosystem exists to
  consume them.
- **Public config.** Sharing config across packages. Use a wire
  parameter or a stdlib accessor; cross-package config is not the
  right primitive.

---

## 10. Open questions

- **Q-config-001:** File-based config source. The `via` mechanism
  already lets a field name a non-default env var; a file source
  would add a parallel "read this key from the file" path. Plausible
  v2 syntax: `host: String = "0.0.0.0" via file:"config.toml" key:"http.host"`.
- **Q-config-002:** Layering precedence. If file + env are both
  present, env probably wins (operator override of repository
  default). CLI flags would presumably win over both.
- **Q-config-003:** Hot reload — almost certainly never, but worth
  recording the closure of the design space.
- **Q-config-004:** Should config fields be visible in
  `Lyric.BuildInfo`? Recording **names + types + defaults** in the
  published metadata aids ops tooling ("what env vars does this
  service read?"). Names yes; values no (sensitive). Defer
  decision until tooling exists to consume it.

---

## 11. Worked example

Service-style application using two config blocks:

```lyric
package CheckoutService

import Std.Core
import Std.Http

config Http {
  port:    Int range 1 ..= 65535     = 8080
  host:    String                    = "0.0.0.0"
}

config Database {
  url:               String                                  // required
  poolSize:          Int range 1 ..= 100 = 10
  connectTimeoutMs:  Int range 100 ..= 30000 = 5000
  @sensitive
  password:          String                                  // required
}

config Features {
  newCheckout:  Bool       = false
  partners:     [String]   = []           // comma-separated env var
}

func main(): Unit {
  Std.Log.info("starting on ${Http.host}:${Http.port}")
  Std.Log.info("partners enabled: ${Features.partners.length}")
  ...
}
```

Operator deployment:

```sh
export LYRIC_CONFIG_CHECKOUTSERVICE_DATABASE_URL="postgres://localhost/checkout"
export LYRIC_CONFIG_CHECKOUTSERVICE_DATABASE_PASSWORD="$(cat /run/secrets/db)"
export LYRIC_CONFIG_CHECKOUTSERVICE_FEATURES_PARTNERS="acme,initech,umbrella"
./checkout-service
```

If `DATABASE_URL` is unset, the process aborts before binding the
HTTP socket, with a clear diagnostic naming the missing field.
