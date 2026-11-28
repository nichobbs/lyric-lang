# D874: the native TIR lowering takes `toString` of an enum

Status: accepted (docs/70 phase 4a, part 9; D520 slice 51).

## Decision

`toString` of an enum value picks the case name by the ordinal: a `switch` on the `i32` over string literals, with the empty string for an ordinal outside the enum. The code generator hands the lowering each enum's case names in ordinal order (`enumNames`, built from the same `enumDefs` ordinals the AST path reads). D859 kept this function on the AST path for want of the name table. `scripts/ci/native-via-tir/keptast.l` now prints the name of two cases and the e2e requires that it does not fall back.
