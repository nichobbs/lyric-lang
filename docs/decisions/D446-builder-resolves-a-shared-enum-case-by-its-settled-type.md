# D446 - The builder resolves a bare shared enum case by the type the checker settled (docs/70 phase 3a, #8613)

**Status:** shipped; the checker is unchanged.

## Context

A bare case name several enums share (`On` of `Beam` and `Ray`) is told apart by the expected type (#6688, #8845). The checker settles the node's type at that enum but, unlike an unshared case, records no reference for the node, so the builder found "a name that is not a local" (`enum_case_collision_self_test`).

## Decision

`sharedCaseRead`, the last step of `buildRefPath` before the name is counted: when the node's type is a type with no type arguments, the name is that type's nullary case of the same name (an enum case, or a union case with no fields), built as `XConstruct`. Any other shape stays counted.

## Results

`enum_case_collision_self_test`'s sibling-enum fixture builds both bodies. `tir-builder-shapes-e2e.sh` gains `shared_enum_case` (built with `--verify-ir` and run).
