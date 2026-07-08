# lyric-feature-flags

Runtime feature flag toggles for safe rollouts, A/B testing, and kill switches.

## Platform parity

The in-process flag store (`InProcessFlagStore`) and the `Flags.Registry`-backed
`FlagGated` / `FlagVariant` aspects are pure Lyric — no BCL/JDK extern boundary
is involved — so they behave identically on `dotnet` and `jvm`.

| Feature                     | Status                                             |
|------------------------------|-----------------------------------------------------|
| In-process store             | Available (both targets)                           |
| `FlagGated` aspect           | Available (both targets)                           |
| Remote (HTTP-polling) store  | Not implemented — see "Remote flag store" below     |

A previous revision of this library declared a remote HTTP-polling client
(`Flags.connectRemote()` / `NativeFlagStore`) via `extern package`, which
never resolves to a real binding on either backend (issue #5324) and had
zero callers anywhere in the repo. It was removed rather than fixed — see
`docs/03-decision-log.md` D-progress-627.

## Packages

| Package | Purpose |
|---|---|
| `Flags` | Core types, `FlagStore` interface, in-process implementation, and public API |
| `Flags.Aspects` | `FlagGated` and `FlagVariant` aspect templates |
| `Flags.Registry` | Process-global flag registry consumed by `Flags.Aspects` |

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

The v1 implementation is `InProcessFlagStore` (in-memory, single-process, not
thread-safe). Implement `FlagStore` yourself for a remote-backed store (see
"Remote flag store" below).

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

## Remote flag store

There is no remote (HTTP-polling) `FlagStore` implementation today. A prior
version of this library scaffolded one (`Flags.connectRemote()`) behind an
`extern package` boundary that never resolved to a real HTTP client on either
backend — it was dead, broken code with zero callers, and was removed rather
than fixed (`docs/03-decision-log.md` D-progress-627).

Building a real one is possible but out of scope here: it needs `Std.Http`'s
client, a background poll loop, and a JSON decoder for the remote payload.
Implement `FlagStore` against those primitives if you need one; there is no
tracked timeline for a first-party implementation.

## Aspect templates

### FlagGated

Short-circuits execution of the matched function when a named flag is disabled.
Returns `Err("feature disabled: " + flagName)` without invoking the handler.
The flag value is read from `Flags.Registry`, a process-global, `Map`-backed
registry (see `Flags.Registry`'s doc comment for the thread-safety caveat) —
register flags into it at application startup with
`Flags.Registry.registerBoolFlag(name, value)`.

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

See `docs/03-decision-log.md` D-progress-261 and D-progress-627.
