# D469 - The builder fills `valueTy` and builds a bare read of a value-generic parameter as `XValueParam` (docs/70 §6.2, #8613)

**Status:** shipped.

## Context

D467 added `XValueParam` to the TIR; nothing produced it. The census counted about 14 "a name that is not a local" reads in `impl` and protected-type members (`func capacity(): Int = N`, `next = (next + 1) % N`). The language reference (docs/01, value-generic length and value-generic records) says a value generic parameter "is an `Int` constant" in the body, so a read of `N: Nat` has type `Int`, not `Nat`.

## Decision

- `TTypeParam.valueTy` of a value-generic parameter is `Int`: the type a body reads it at. It is not the declared constraint (`Nat`), which is the same for every value parameter today and is implied by the parameter being a value parameter. `XValueParam` is therefore typed `Int`, which the D467 verifier rule (`type == valueTy`) already checks; no `Nat` to `Int` conversion node exists or is needed.
- The checker already binds a value generic as an ordinary local of type `Int` in the body's scope, so it records no table for the read and no checker change was needed. The builder keeps `BuildEnv.valueParams` (name, binding symbol, position among the member's type parameters, the owner's first), filled per function from the declaration's `GPValue` parameters and, for a member, its owner's (`MemberOwner.valueNames`). A single-segment path that is not a local, not a declaration and not a field of the receiver and that names one of them is `XValueParam(owner = <member symbol>, index = <position>)`.
- A local of the same name still wins (the lookup order is unchanged).
- Phase 3c's monomorphisation removes `XValueParam` when it substitutes the length, with the type parameters; value generics stay generic in the TIR and in package interfaces.

## Not covered

A value-generic parameter named in a contract or an invariant of a protected type (the checker binds it there too) goes through the same path where those expressions are built; `tir_build_self_test.l` covers function bodies and protected members.
