# Calls of a generic impl's members, lambda defaults and integer literals of a fixed type (docs/70 phase 3a, #8613)

**Status:** shipped; builder only, the checker is unchanged.

## Context

Four bodies the TIR gate (D347) stopped in the ilverify consumer self-tests:

1. `p.first()` where `impl[T] Shows for Pair[T]` declares `first`: the call is of a member of a generic `impl`, and `instantiateMethod` accepted only a member declared in the type's body or a sibling of the impl being built (D423). `generic_closure_self_test`, `impl_generic_target_self_test`.
2. `func withDefault(h: () -> Int = { -> 4 })`: a call that takes the default needs the lambda rebuilt at the call, and `refreshDefaultIds` had no case for a lambda, its block body or a read of the lambda's own parameter. `inout_aliasing_self_test`, `lambda_gaps_batch_self_test`.
3. `takeList(b, 3)` with `b: Byte` and `func takeList[T](x: inout T, nv: in T)`: the checker fixes `T` to `Byte` and accepts the literal `3`, which the builder had built as an `Int` with no conversion to `Byte`. `inout_array_element_self_test`.

## Decision

1. `buildPackage` records the declared parameters of each generic in-package `impl` (`TyConvCtx.implOwners`, by the DefPath key of its members' owner) before any body is built. A call of one of its members from any function instantiates the owner's parameters from the receiver's type arguments when the impl's target is written over exactly those parameters in order (`isImplMemberOverOwnParams`; the sibling rule already did this for a caller inside the same impl). Any other target (`Box[List[T]]`, a concrete argument) stays counted.
2. A default argument is built with the highest local number before it began recorded (`BuildEnv.defaultFloor`); `refreshDefaultIds` keeps a read of a local numbered above it (the lambda's own parameter), refreshes a lambda's body and a block with no statements of its own, and counts a lambda that captures. The message for a shape it does not handle names the kind.
3. An integer literal typed `Int` where `Byte`, `UInt` or `ULong` is expected and its value is in that type's range is the same literal retyped (`convertValue`), as a float literal is for `Float`. `Long` keeps its widening node.

## Results

`tir_build_self_test.l` gains a call of a generic impl member from another function, lambda defaults used at several calls, and the `Byte` literal. A call of a lambda-typed local (`f(None)`), `for` over a host `Matches` result and a tuple holding `None` are the main builder's (D690 and D691).

## Not covered

`impl_self_spelling_self_test`: an `inout Self` argument through an interface-typed receiver is an I0003 (the parameter is the interface, the argument the concrete type); it needs a decision on what `Self` is for a by-reference argument.
