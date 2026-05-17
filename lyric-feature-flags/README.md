# lyric-feature-flags

Runtime feature flag toggles for safe rollouts, A/B testing, and kill switches.

## Packages

| Package | Purpose |
|---|---|
| `Flags` | Core types, `FlagStore` interface, in-process implementation, and public API |

## Quick start

```lyric
import Flags

val store = Flags.inProcess()

Flags.makeFlag(store, "newCheckout", Flags.FlagValue.FlagBool(true))

match Flags.getBool(store, "newCheckout") {
  case Some(true)  -> println("Using new checkout flow")
  case Some(false) -> println("Using legacy checkout flow")
  case None        -> println("Flag not found")
}

Flags.listFlags(store)  // Returns all defined flags
```

## FlagStore interface

`FlagStore` is a pluggable interface so you can swap out the backing store:

```lyric
pub interface FlagStore {
  func getFlag(key: in String): Option[FlagEntry]
  func setFlag(key: in String, entry: in FlagEntry): Unit
  func listAll(): slice[FlagEntry]
  func deleteFlag(key: in String): Unit
}
```

The v1 implementation is `InProcessFlagStore` (in-memory, single-process).
Implement `FlagStore` for a remote flag service and pass the implementation
to your own aspect body or helper functions.

## In-process store

`Flags.inProcess()` creates an in-process store from `fromEntries()`:

```lyric
val entries = [
  Flags.FlagEntry { key: "feature1", value: Flags.FlagValue.FlagBool(true), description: "Rollout A" },
  Flags.FlagEntry { key: "feature2", value: Flags.FlagValue.FlagInt(50), description: "A/B split %" }
]

val store = Flags.fromEntries(entries)
```

## API reference

```lyric
Flags.getBool(store, key)      // Option[Bool]
Flags.getString(store, key)    // Option[String]
Flags.getInt(store, key)       // Option[Int]
Flags.getFloat(store, key)     // Option[Float]
Flags.getValue(store, key)     // Option[FlagValue]
Flags.isEnabled(store, key)    // Bool — true if flag key exists and is truthy
Flags.listFlags(store)         // slice[FlagEntry]
Flags.makeFlag(store, key, value)
Flags.makeFlagWithDesc(store, key, value, description)
```

## Configuration

`FlagValue` enum defines supported types:

```lyric
pub enum FlagValue {
  case FlagBool(Bool)
  case FlagString(String)
  case FlagInt(Int)
  case FlagFloat(Float)
}
```

`FlagEntry` record:

```lyric
pub record FlagEntry {
  key: String
  value: FlagValue
  description: Option[String]
}
```

## Remote flag service (experimental)

Feature-gate the remote flag backend in `lyric.toml`:

```toml
[features]
flags = ["remote"]
```

Then use the remote config block:

```lyric
import Flags

val store = Flags.connectRemote({
  url: "https://flag-service.example.com",
  apiKey: env("FLAG_API_KEY"),
  pollIntervalMs: 30000,
  connectTimeoutMs: 5000,
  appKey: "my-app"
})
```

Runtime config (env prefix `LYRIC_CONFIG_REMOTE_`):

| Env var | Default | Meaning |
|---|---|---|
| `URL` | *(required)* | Flag service endpoint |
| `APIKEY` | `""` | API key for authentication |
| `POLLINTERVALMS` | `30000` | Poll interval in ms |
| `CONNECTTIMEOUTMS` | `5000` | Connect timeout in ms |
| `APPKEY` | `""` | Application identifier |

## Aspect templates

### FlagGated

Aspect template for conditional execution based on a feature flag.
Skips the matched function body if the flag is disabled.

```lyric
import Flags.Aspects

aspect NewCheckoutGate from Flags.Aspects.FlagGated {
  matches: name == "handleCheckout"
  config { flagKey: String = "newCheckout" }
}
```

Config fields (env prefix `LYRIC_ASPECT_<INSTANTIATION>_`):

| Field | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | `Bool` | `true` | Master switch |
| `flagKey` | `String` | `""` | Feature flag key to check |

## Decision log

See `docs/03-decision-log.md` D-progress-XXX.
