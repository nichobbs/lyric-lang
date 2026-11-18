# D429 - A union case built at a type the context settled has its fields from that type (docs/70 phase 3a, #8613)

**Status:** shipped; extends D388 (the construction signature in the symbol table) and D454.

## Context

In a generic function the checker erases the type of an unannotated lambda parameter (`{ m -> App(msg = m) }` against `(M) -> Wrap[M]`), so the argument is untyped when the case is checked and the construction's result is `Wrap[<error>]`. The expected type settles the node at `Wrap[M]` afterwards, but no constructor signature is recorded for a construction that is not closed when it is checked, so the builder had a callee and no fields and counted the body ("a method, constructor or member call", I0002): `ScopedCase.Lib::viaLambda`.

## Decision

When a union-case call has a callee and no recorded signature, the builder takes the case's fields from its own entry (`noteCaseSym`, the fields under the union's parameters) and instantiates them at the arguments of the type the node settled at (`substOwnerArgs`), as `retypeConstruct` does for a built value. Each argument is settled against its field type and converted to it; arguments are taken in field order, named or positional, and a call whose named arguments are out of field order stays counted rather than reordering evaluation.

## Results

`ScopedCase.Lib::viaLambda`'s shape builds with the verifier clean; a new `tir_build_self_test.l` case covers the lambda and the direct construction in one package.
