# D519 - A generic invariant type is checked at the public boundary on TIR

**Status:** accepted, implemented in `Lyric.Tir.Contracts` (docs/70 phase 3c, §7.2; amends D507 "Not done"; the AST path is unchanged)

## Decision

1. **The boundary checks cover generic types on TIR.** A type's checker is found whether or not the type is generic (`collectCheckers` no longer requires the checked type to have no arguments), and `checkerOf` answers for a named type with arguments. The call to the checker carries the value's type arguments (`Direct(checker, typeArgs = args of the parameter's or result's type)`), which `Lyric.Tir.Mono` instantiates as it does any generic call. The entry check of a foreign type, the `inout`/`out` exit check and the result check all apply, with the same messages (`InvariantViolated: Owner.f parameter p` / `... result`) and the same `enabled`-independent behaviour as D507.
2. **The AST path is unchanged, deliberately.** The contract elaborator inserts its checker calls after type checking, and `Lyric.Mono` specialises a generic call only at a site the checker recorded (`genericCallTypeArgSites`), so a call inserted for a generic type stays `__lyric_checked_Cell(...)` on `--target jvm` and fails at run time (`NoSuchMethodError`), while `--target dotnet` works for a non-generic function but a generic function's entry check is not emitted. Shipping that would turn a silent gap into a failure, so `--target dotnet` and `--target jvm` keep not checking generic types at the boundary; the AST path is the one TIR replaces (docs/70 phases 4-5), and the gap is recorded under #7222 and in docs/01 §6.2, and tracked with a concrete plan in #9466 (the type checker records call-site facts for the elaborator's inserted calls; or it closes when dotnet and the JVM lower from TIR). Writing the type arguments explicitly (`__lyric_checked_Cell[String](x)`) was tried and does not work: dotnet then fails with T0123, the JVM is unchanged.

## Effect

The TIR contracts pass conforms to docs/01 §6.2 and docs/08 §7.1 for generic types, verified by the TIR self-tests (the verifier accepts each call against the checker's signature). No target enforces it at run time yet: native lowers a function that mentions a generic record instance from the AST path until its TIR lowering covers those instances (#9370), and dotnet and the JVM follow when they lower from TIR.
