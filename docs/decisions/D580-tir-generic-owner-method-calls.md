# D580 - A call of a method of a generic type instantiates the owner's parameters from the receiver (docs/70 phase 3a, #9016)

**Status:** shipped; extends D579 and D389.

## Context

D579 builds the members of generic records, protected types and `impl`s with the owner's type parameters as
the leading ones of the member's generic space. The call side did not follow: `buildMethodCall` always gave
the callee no type arguments and read the callee's parameter types as the checker wrote them, so a call such as
`b.get()` on a `Box[Int]` left the owner's `T` open and was an I0002.

## Decision

`build_owner.l` adds `instantiateMethod`, called from `buildMethodCall`:

- A member with no generics is unchanged.
- Otherwise the type arguments are the checker's record for the call (`genericArgsByNode`) when it covers
  the whole generic space, else the owner's parameters come from the receiver's type arguments
  (`MethodCallSite.recvTy`, positionally; the owner's are the leading generics whose binder key has no dot, the
  member's own being keyed `Owner.fn`) and the member's own are inferred from the arguments and the result as a
  generic function's are (`genericArgsFromCall`).
- The callee is `Direct(sym, tyArgs)` over the whole space, and the parameter types are the signature's with
  its generics substituted, so argument conversions and the verifier's call-argument check see concrete types.
  `noteFuncSym` already binds every owner key of the signature to the callee and records its `TSig` over the
  combined space, matching the member's `TFnDecl.typeParams`.
- A call of a member of a generic `impl` whose receiver's type arguments are not the impl's parameters
  (the impl's target is a pattern over them) is counted as "a method call on a member of a generic impl".

Interface calls keep their empty type arguments.

## Measured

`tir_build_self_test.l`: a call of a generic record's method, of a method with its own parameter beside the
owner's, and of a generic protected type's func, each built with its caller and verified (I0003 0).
