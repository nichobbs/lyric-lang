# A call through a type to a method in the type's body builds as the method call (docs/70 phase 3a, #8613)

**Status:** shipped; type checker and TIR builder.

## Context

`Bag.one(b)` (D181) is a call through the type `Bag` of a method declared in the body of the record `Bag`: it binds what the method call `b.one()` binds. The checker recorded it only in `SymbolTable.byRefDotCallSites` (`asMethod`) for `Lyric.Pipeline`'s later rewrite into `b.one()`, and recorded no callee or call shape under the call's node, so the typed IR builder had nothing to build from and reported I0002 ("a call the checker did not resolve") for all nine bodies of `type_qualified_method_self_test.l` on the native and JVM jobs.

## Decision

- The checker records the call's callee and shape under its node (`recordMethodCalleeNode`, the same call a method call written `x.m(args)` makes), from the receiver-dropped signature of the body method it already found.
- The builder (`typeQualifiedMethodCall`) recognises a call whose callee span is an `asMethod` site and builds it as the method call: the first argument is the receiver and the method takes the others, through `buildMethodCall`, so a generic record's method, a method's own type parameters, an `inout` receiver, named and defaulted arguments and an alias-named type all build as the written method call does.

## Results

`type_qualified_method_self_test.l` 10 of 10 on dotnet, the JVM and native (no I0002).
