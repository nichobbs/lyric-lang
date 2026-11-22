# Map.containsValue is a typed built-in member (docs/70 phase 3a, #8613)

**Status:** shipped.

## Context

`Map.containsValue` is one of the `Map` members every backend lowers by name (`stdCollectionSurface`), but the checker typed only `containsKey` and `remove`: no parameter list, no `Bool` result. A call therefore fell to the host path as `Dictionary`2.containsValue(Int)`, which names no host method (the .NET member is `ContainsValue`), and the TIR gate (D347) stopped the body with "an extern call no host overload fits".

## Decision

`containsValue` takes the map's value type and returns `Bool`, like `containsKey` does for the key type. The checker's `stdCollectionMemberParams` and `stdCollectionMemberResult` carry it, which records the call as the `Map.containsValue` built-in (`IoBuiltin`), and the builder's `memberArgTys` derives the same parameter so an argument typed with a hole settles against the value type.

## Consequences

`map_enhancements_self_test` builds its two `containsValue` bodies. Programs that passed an argument of the wrong type to `containsValue` now get the checker's argument diagnostic instead of a host-method miss. Test: `tir_build_self_test.l`.
