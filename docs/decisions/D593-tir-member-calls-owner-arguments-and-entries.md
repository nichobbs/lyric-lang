# D593 - A member of a generic type is described by its declaration, and a call's owner arguments come from the receiver (docs/70 phase 3a, #8613)

**Status:** shipped; corrects D580 and D582.

## Context

The census after #9033 left three I0003 reports in the self-tests, all on calls of members of generic types:
a sibling method called through `self` inside a lambda of a generic record (`symbol-defined`: the callee had no entry),
and `consumeStrings(Chan[String], Chan[Int])` (`call-arg-type`: the callee's receiver parameter was the first
call site's `Chan[String]`). Both come from the symbol table taking each member's entry from the first call site's
signature, which sees the receiver's arguments and never the owner's parameters. Tests of D580 passed only because
the declaration and the call site agreed on the same wrong count.

The checker's method signature lists only the member's own generics for a concrete receiver (`Box[Int].pair[U]` lists
`U`) and none for a receiver typed over the caller's own parameters (`Cell[T].get`).

## Decision

- `buildPackage` describes every member it builds by its declaration (`ownFnEntry`), keeping the kind a call recorded
  (a call of a protected type's `func` is recorded as an entry). A signature that cannot be converted no longer leaves
  a member undefined.
- `instantiateMethod` takes the owner's type arguments from the receiver's type arguments when the callee is declared
  in the receiver type's own body (its DefPath extends the type's), then the member's own from the checker's record or
  inferred from the call. A receiver with type arguments whose callee is in an `impl` is counted ("a method call on a
  member of a generic impl"): the impl's parameters are a pattern over the target and are not the receiver's arguments.
- `noteFuncSymN` records the type-parameter count as the number of arguments the call gives.
