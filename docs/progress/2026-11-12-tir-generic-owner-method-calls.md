# TIR builder: calls of a method of a generic type (D580, #9016)

Docs/70 phase 3a: a call of a method of a generic record or protected type now instantiates the owner's type
parameters from the receiver's type arguments and the member's own from the call, builds `Direct(sym, typeArgs)`
over the whole generic space and converts the arguments against the substituted parameter types
(`build_owner.l`). A call of a member of a generic `impl` whose receiver does not carry the impl's parameters
positionally stays counted. Phase 3a is not complete: I0002/I0003 do not stop the build yet.
