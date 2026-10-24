# Integer overflow panics inside operator-bounded generics (#8532)

D224 accepted `a + b` on a type parameter bounded by `Add`, but the overflow check of D163
is recorded from the checked result type, which is the type parameter in a generic body, so
`sum2[Int](2147483647, 1)` wrapped where the same expression at `Int` panics in a debug
build. A specialisation that binds an `Add`, `Sub` or `Mul` bounded parameter to `Int`,
`Long`, `UInt`, `ULong` or `Byte` is now type-checked again like the other operator
specialisations (`Lyric.Mono` `opOverflow`), and the overflow sites that check records on
the specialised body are lowered by `lowerOverflowChecks` in `Lyric.Pipeline.lowerSpecArrays`
(`SpecArraySites.overflow`), so it panics in a debug build and wraps in a release build.
Standard library generics are left wrapping (D163 item 3). The rewrite runs before any
backend, so dotnet, the JVM and native share it.

Tests: runtime panics for `Int`, `Long`, `UInt`, `ULong` and `Byte` (and compound
assignment, `sum` and `lerp` bodies) in `bounded_generic_ops_self_test.l`; the re-check
selection in `mono_self_test.l`; the debug panic and release wrap of a generic `Add` in
`scripts/ci/overflow-profile-e2e.sh`. D224's review leftovers are folded in: the three
operator-marker lists are asserted to agree in `contract_meta_self_test.l`, and D224 notes
that interface bounds are dropped from the restored repr.
