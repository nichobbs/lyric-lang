# A call of an interface method with type parameters of its own carries the call's type arguments (docs/70 phase 3a, #8613)

**Status:** shipped; checker (the call site) and builder (the callee).

## Context

`interface Echo { func id[U](self: in Self, x: in U): U }` called as `e.id(5)` on an `Echo`-typed value: `recordMethodCallSite` returned for an interface call whose signature has generics ("waits for the generic-call step"), so the call had no site and the TIR gate (D347) stopped the body (`interface_method_generic_self_test.l`).

## Decision

The site is recorded for a method with type parameters of its own on a non-generic interface; only a call on a generic interface (whose own arguments the site does not carry) still records nothing. The builder instantiates the method as it does any generic member call (the checker's recorded instantiation, else the arguments and the result) and builds `Callee.Interface(iface, [], method, typeArgs)` with those type arguments, the form the verifier already checks (`call-type-args`).

## Results

`scripts/ci/tir-builder-shapes-e2e.sh` (`interface_generic_method`) builds and runs the call at `Int` and runs it.
