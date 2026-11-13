# D591 - Or-patterns that bind, constant patterns, shorthand record fields and mutating receivers build (docs/70 phase 3a, #8613)

**Status:** shipped; extends D369, D389, D590.

## Context

After D590 the wide census still counted four kinds the builder had no case for: an or-pattern whose alternatives bind a name (4 compiler, 7 self-test sites), a constant pattern `@NAME` (8 ecosystem, 7 self-test), a shorthand record pattern field `P { x, y }` (4 self-test), and a method call whose receiver is passed `inout` or `out` (4 self-test).

## Decision

- **Or-patterns that bind.** Every alternative binds the same names (the checker enforces it). The first alternative declares the locals; each later alternative builds with those locals as the binding for the same name and type (`BuildEnv.orBound`), so all alternatives carry the same `LocalDecl`. The verifier already defines locals from the first alternative only.
- **Constant patterns.** The checker records the constant's symbol under the pattern's `NodeId` (`refByNode`, as for a name expression); the builder emits `TpConst` and notes the symbol.
- **Shorthand record fields.** `P { x, y }` binds a local per field, typed from the record's instantiated field type at the pattern's recorded type (`patTypes`); each is a `TpBind` in a `TFieldPat`.
- **Mutating receivers.** A method whose `self` is `inout` or `out` takes its receiver as a place argument (`TArgInout` / `TArgOut`): the receiver expression as a place, or the enclosing method's `self` for a bare sibling call. A receiver of another type than the method's declared one, or a place receiver after hoisted arguments, is counted rather than guessed.

## Measured

`tir_build` 176 pass: new cases for each kind (each builds and verifies), and three older cases that pinned the old counted behaviour now pin the built one (the DefPath-key case uses a member access that still fails).
