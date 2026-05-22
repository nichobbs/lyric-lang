# lyric-feature-flags

Runtime feature flag toggles for safe rollouts, A/B testing, and kill switches.

## Platform parity

| Feature flag | Backend                                                              | Status                |
|--------------|----------------------------------------------------------------------|-----------------------|
| `dotnet`     | `System.Net.Http.HttpClient` + `System.Collections.Concurrent`       | Available             |
| `jvm`        | `java.net.http.HttpClient` (JDK 11+) + `ConcurrentHashMap`           | Planned (Phase 6)     |

The JVM kernel (`Flags.Kernel.Jvm`) declares the HTTP polling client
against the built-in `java.net.http.HttpClient` plus a
`lyric.flags.Registry` helper; the JVM helper is supplied by the
Lyric JVM stdlib JAR (out-of-repo).  Until that JAR ships, only the
`dotnet` feature produces a runnable artifact.

## Packages

| Package | Purpose |
|---|---|
| `Flags` | Core types, `FlagStore` interface, in-process implementation, and public API |
| `Flags.Aspects` | `FlagGated` and `FlagVariant` aspect templates |

## Quick start

```lyric
import Flags

val store = Flags.fromEntries([
  Flags.makeFlag("new-checkout", true),
  Flags.makeFlagWithDesc("dark-mode", false, "Enable dark mode UI"),
])

if Flags.isEnabled(store, "new-checkout") {
  // run new checkout flow
}
val colour = Flags.getString(store, "theme-colour", "blue")
```

## FlagStore interface

`FlagStore` is a pluggable interface so you can swap out the backing store:

```lyric
pub interface FlagStore {
  func isEnabled(name: in String): Bool
  func getValue(name: in String): Option[FlagValue]
  func listFlags(): [FlagEntry]
  func refresh(): Result[Unit, FlagError]
}
```

The v1 implementation is `InProcessFlagStore` (in-memory, single-process, not thread-safe).
With the `remote` feature active, `Flags.connectRemote()` returns a `NativeFlagStore`
that polls an HTTP endpoint. Implement `FlagStore` for a custom backing store.

## In-process store

```lyric
val store = Flags.fromEntries([
  Flags.makeFlag("my-flag", true),
  Flags.makeFlagWithDesc("dark-mode", false, "Enable dark mode UI"),
])

// or start empty
val store = Flags.inProcess()
```

## API reference

```lyric
// Factory
Flags.inProcess(): InProcessFlagStore
Flags.fromEntries(entries: [FlagEntry]): InProcessFlagStore
Flags.connectRemote(): Result[FlagStore, FlagError]   // requires feature = "remote"

// FlagEntry construction
Flags.makeFlag(name: String, enabled: Bool): FlagEntry
Flags.makeFlagWithDesc(name: String, enabled: Bool, description: String): FlagEntry

// Typed accessors (return defaultValue when flag absent or wrong type)
Flags.isEnabled(store, name): Bool
Flags.getValue(store, name): Option[FlagValue]
Flags.getBool(store, name, defaultValue: Bool): Bool
Flags.getString(store, name, defaultValue: String): String
Flags.getInt(store, name, defaultValue: Int): Int
Flags.refresh(store): Result[Unit, FlagError]
Flags.listFlags(): [FlagEntry]   // via store.listFlags()
```

## Types

`FlagValue` enum:

```lyric
pub enum FlagValue {
  case FlagBool(value: Bool)
  case FlagString(value: String)
  case FlagInt(value: Int)
  case FlagFloat(value: Float)
}
```

`FlagEntry` record:

```lyric
pub record FlagEntry {
  name:        String
  value:       FlagValue
  description: String
}
```

`FlagError` record:

```lyric
pub record FlagError {
  message: String
  code:    String
}
```

## Remote flag service (experimental)

Feature-gate the remote flag backend in `lyric.toml`:

```toml
[features]
remote = []
```

Then use `Flags.connectRemote()` after setting the config block:

```toml
[LYRIC_CONFIG_REMOTE]
URL = "https://flag-service.example.com"
APIKEY = "..."
POLLINTERVALMS = "30000"
```

Runtime config (env prefix `LYRIC_CONFIG_REMOTE_`):

| Env var | Default | Meaning |
|---|---|---|
| `URL` | *(required)* | Flag service endpoint |
| `APIKEY` | `""` | API key for authentication (`@sensitive`) |
| `POLLINTERVALMS` | `30000` | Poll interval in ms (5000–3600000) |
| `CONNECTTIMEOUTMS` | `5000` | Connect timeout in ms (1000–30000) |
| `APPKEY` | `""` | Application identifier |

## Aspect templates

### FlagGated

Short-circuits execution of the matched function when a named flag is disabled.
Returns `Err("feature disabled: " + flagName)` without invoking the handler.

```lyric
import Flags.Aspects

aspect NewCheckoutGate from Flags.Aspects.FlagGated {
  matches: name == "handleCheckout"
  config {
    flagName:         String = "new-checkout"
    defaultOnMissing: Bool   = false
  }
}
```

Config fields (env prefix `LYRIC_ASPECT_<INSTANTIATION>_`):

| Field | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | `Bool` | `true` | Master switch |
| `flagName` | `String` | *(required)* | Feature flag name to check |
| `defaultOnMissing` | `Bool` | `false` | Value to use when flag is absent |

### FlagVariant

**Experimental stub.** Always proceeds unconditionally. Full A/B variant routing
(read flagName, compare to variant, short-circuit on mismatch) is deferred to a
follow-up stage.

## Decision log

See `docs/03-decision-log.md` D-progress-261.
