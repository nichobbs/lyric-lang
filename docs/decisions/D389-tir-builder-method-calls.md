# D389 - The builder's method calls (docs/70 phase 3a, #8613)

**Status:** shipped (`buildMethodCall` in `build_expr.l`); extends D388.

## Context

After D388 a call `recv.m(args)` was an I0002 ("a method, constructor or member
call"): the checker recorded the method's `SymbolId` (`calleeByNode`, D365) but
not its signature or whether the receiver is passed by value.

## Decision

1. `ResolvedSignature.recvMode: Option[ParamMode]` (a defaulted field) carries
   the mode of the explicit `self` receiver of a method declared in a type body
   (set where `resolveMethodSigParts` drops it) and of the first parameter of a
   dot-named function `T.f(self, ...)` (set by `dropReceiverParam`). It is
   `None` for a signature with no receiver, and for any copy that does not carry
   it, so an unknown mode is never taken for `in`.
2. `SymbolTable.methodCallByNode: Map[Int, MethodCallSite]`, recorded beside
   `calleeByNode` in `recordMethodCalleeNode`: the receiver-dropped signature,
   the receiver's declared type (the first parameter's type for a dot-named
   function, else the receiver's own type), and the interface when the receiver
   is a value of an interface type. Only non-generic calls on a closed receiver.
3. `buildMethodCall` builds `XCall(callee, [receiver] ++ args)`. The callee is
   `Direct(sym, [])`, or `Interface(iface, [], sym, [])` when the receiver is an
   interface value. The receiver is converted to its declared type as an
   argument is; the arguments are placed by `buildCallArgs` (D388). A receiver
   not passed `in` (it would be a place argument) and a method with no known
   receiver are counted I0002, not built.
4. Not built yet, counted as before: generic methods and generic receivers,
   package-qualified or static calls, extern member calls (from `externByNode`),
   mutating receivers.
