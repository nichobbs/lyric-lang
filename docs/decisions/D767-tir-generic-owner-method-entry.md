# A method of a generic type from another package numbers its own type parameters after the owner's (docs/70 phase 3a, #8613; extends D579)

**Status:** shipped; the TIR symbol table.

## Context

`restored-dependency-codegen-e2e.sh` calls `bx.pick(Pt(x = 3, y = 4))` where `Bx[T]` is a record of another package and `pick[U](self: in Bx[T], u: in U): U` is declared in its body. The call's type arguments are the owner's followed by the method's (`[Int, Pt]`, D579), and the callee's symbol entry numbers a type parameter by its place in that list. The entry the builder made for a callee of another package (`noteFuncSymN`) converted the method's signature, whose `generics` are the method's own (`[U]`), so `U` was parameter 0 and the call's first type argument (`Int`, the owner's `T`) replaced it: I0003 `call-arg-type`, "argument 1: expected Int but found Pt" (#9282, `compiler-self-tests-core`). A method of a generic type declared in the package being built has its entry from its own declaration, which counts the owner's parameters, and was never affected.

## Decision

`noteFuncSymN`, when the callee's type-parameter count is larger than its signature's `generics` (a method of a generic type), prepends the owner's parameters to the signature it converts: the arguments of the receiver type (`Bx[T]`), each named with the key of the type that declares it. The method's parameters then number after the owner's, as the call's type arguments do. Any other callee is unchanged.

## Consequences

`ErApp::main` of `restored-dependency-codegen-e2e.sh` (the `erased` case, project and restored) builds and verifies. Test: that script, under the gate.
