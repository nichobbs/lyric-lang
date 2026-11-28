# The native TIR lowering takes `default()` of any representation (docs/70 phase 4a, D875)

## What shipped

- `default()` lowers to the zero value of the representation (`zeroValueOfN`): null for a reference, `zeroinitializer` for a by-value aggregate.
- `keptast.l` and `native-via-tir-e2e.sh`: the `String` fallback is no longer expected; `default()` of a by-value record and a list are pinned.
