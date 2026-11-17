# D441 - A record converts to an extern interface it implements wherever a value is converted (docs/70 phase 3a, #8613)

**Status:** shipped; extends D493 and D440.

## Context

An argument or a call result that is a Lyric record `impl`ing an extern interface already passed as that interface through `hostUpcastKind` (a `CvBoxToHost` node, read from the `impl` table and the host metadata). A function body, `if` or `match` branch, `val` binding or return that meets such a type went through `convertValue`, which did not try `hostUpcastKind`, so the census counted eight bodies as "a branch conversion" (`Seq` as `IEnumerable`, `Cursor` as `IEnumerator`, `Sink` as `Appendable`).

## Decision

`convertValue` tries `hostUpcastKind` where it tried only `taskAsHostTask`, which `hostUpcastKind` runs first. The conversion node is the one arguments already carry, so no TIR kind is added. A conversion the host metadata does not permit stays counted.
