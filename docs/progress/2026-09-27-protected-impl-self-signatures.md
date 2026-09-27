# `Self` in an impl method signature on a protected type (#7550)

`impl Iface for P`, where `P` is a protected type, now accepts an interface
method whose signature mentions `Self` — as a parameter (`func merge(other:
in Self): Int`), a return (`func fresh(): Self`), or nested inside a generic
argument (`func snapshot(): List[Self]`) — on `--target dotnet` and
`--target jvm`. It used to fail with **T0136** (#7547's fix, since a naive
`Self -> P` substitution in the moved entry desynced from the interface
slot's erased `object`/`Object` descriptor: `TypeLoadException` on dotnet,
`AbstractMethodError` on the JVM).

The fix keeps `Self` UNSUBSTITUTED in the moved entry's signature (the
contract elaborator already did this) so both backends' existing `Self ->
object`/`Object` erasure — the same one that erases the interface slot
itself — produces an identical descriptor by construction, at any nesting
depth. What needed fixing was CODEGEN-INTERNAL body-typing bookkeeping so a
`Self`-typed parameter's fields/methods resolve inside the entry's body:
MSIL's `lowerProtectedMsil` now routes entry parameters through the same
`registerParamsMsil` helper `impl`/record methods use; the JVM's
`lowerProtectedMethod` now emits the same `checkcast`-based narrowing
(`emitSelfParamChecksJvm`) `lowerRecordMethod`/`lowerImplMethod` already do.
Both backends' `Self`-return call-result narrowing (`methodRetIsSelf` /
`JvmFuncSig.retIsSelf`) were already populated correctly for protected
entries by the pre-existing shared registration functions, so neither
needed a change (D-progress-1013).

`--target native` still cannot lower ANY interface method mentioning
`Self` — for a record impl or a protected impl alike, a pre-existing,
target-wide gap in its interface vtable-type registration
(`typeExprToNType`'s `TSelf` arm panics). This is unrelated to protected
types specifically and is not addressed here; T0136 is not made
target-conditional (the shared type checker has no target-awareness
mechanism), so a `Self`-mentioning protected impl compiles for dotnet/JVM
and panics on native exactly as an ordinary record impl already does. Native
`Self`-in-interface-method support (records and protected impls) and a
proper diagnostic in its place are tracked in #7585; a JVM narrowing gap
found while writing the tests is tracked in #7586.

Tests: `typechecker_self_test.l`'s T0136-for-Self case is replaced with an
accepted-case test (parameter, return, nested `List[Self]`); new
`protected_iface_impl_self_type_self_test.l` (dotnet and JVM batches,
mirroring `protected_iface_impl_contracts_self_test.l`'s target scope) with
runtime coverage of a `Self` parameter and return through both an
interface-typed value and the concrete receiver, plus a nested-`Self`
compile+round-trip case. `protected_iface_impl_self_test.l`,
`protected_iface_impl_contracts_self_test.l`, and
`protected_exclusion_{dotnet,jvm}_self_test.l` continue to pass unmodified.
Language reference §7.5, book chapter 10, and appendix B's T0136 row
updated.
