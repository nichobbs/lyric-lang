# D564 - Distinct and range factories, buffer indexing and impl member calls build (docs/70 phase 3a, #8613)

**Status:** shipped; extends D389, D553 and D563.

## Context

Three constructs the checker accepts left function bodies unbuilt in the TIR census: `T.from(x)` and
`T.tryFrom(x)` on a distinct or range type (the checker records a type but no callee), an index on a
`buffer[T]`, and a call of a member of an `impl Iface for T` block on a value of the record `T`
(the member declares no receiver, because `self` is implicit).

## Decision

- `T.from(x)` builds as `XConvert(CvWrapDistinct(T), x)` for a distinct type and as the range check
  of `x` for a range subtype; the argument is first converted to the underlying type.
  `T.tryFrom(x)` builds as `XCall(Intrinsic(IoTryFrom), [x])` of type `Result[T, String]`, where `T`
  is the first type argument of the node's type. `IoTryFrom` is a new `IntrinsicOp` case.
- `IndexKind` gains `IkBuffer`, selected by the receiver's built-in `buffer[T]` type.
- A method call whose signature declares no receiver, on a receiver that is neither a protected type
  nor an interface, is an impl member call: a `Direct` call with the receiver first, passed `in`.

## Measured

`scripts/ci/tir-census.sh` over the 98 programs, on top of D563: bodies built 1053 -> 1056 of 1165,
I0003 0; `a call the checker did not resolve` 20 -> 11, `an index on a receiver that is not an array,
slice, string, List or Map` 11 -> 0, `a method call with no declared receiver` 11 -> 0. Most bodies that
hit these kinds also hit others, so the built count moves less than the kinds do. What is left of the
unresolved calls: conversion methods on a distinct value (`a.toInt()`), chained extern calls, a call on
a stub, and `record.copy(...)`.
