# D582 - A method call whose signature lists no generics takes the owner's arguments from the receiver (docs/70 phase 3a, #9016)

**Status:** shipped; corrects D580.

## Context

D580 assumed the checker's method signature lists the owner's type parameters among `generics`. The `tir-census.sh --wide`
run after #9018 found eight I0003 `call-type-args` reports in the self-tests: for a receiver such as `Cell[T]` (the caller's
own parameter, or `self` inside a sibling method) the signature lists none, so the call carried no type arguments although
the callee's declaration has the owner's parameter first (D579). The verifier read the callee's parameter count from the
first call site's signature, so a concrete receiver (`Box[Int]`) agreed with the wrong count and was not reported.

## Decision

- `instantiateMethod` takes the owner's arguments from the receiver's type arguments when the signature has no generics
  and the call is not an interface call.
- `noteFuncSymN` records the callee's type-parameter count as the number of type arguments the call gives, so the
  `TSymEntry` and its `TSig` agree with the declaration (`noteFuncSym` keeps the signature's own count for every other call).
