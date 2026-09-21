# D-progress-942 — JVM `scrutineeGenericArgs` field-access arm closes #6957

**Status:** shipped

**Context.** Issue #6957 was split out from #6546's fix (PR #6917,
D-progress-879) per that PR's own `claude-review` SUGGESTION finding: not
reproduced end-to-end at the time, but the code-level gap was confirmed as
a pre-existing limitation, not a regression.

`lyric-compiler/jvm/codegen/04_calls.l`'s `.add()` interception (from
#6546) and `02_exprs.l`'s `applyIndexedElemOverrideNormalizingSlice` both
key off `Jvm.Codegen.scrutineeGenericArgs(ctx, recv)` (`03_match.l`) to
detect a `slice[Elem]`-element-typed receiver. Before this fix,
`scrutineeGenericArgs` only resolved a receiver's generic instantiation
for a bare local/parameter reference, an `EList` literal, or specific
`ECall` shapes — it fell through to `newList()` (no recorded args, so no
interception) for a plain FIELD-ACCESS receiver, e.g.:

```lyric
someRecord.rows.add([1, 2, 3])  // someRecord.rows: List[slice[Int]]
```

For this shape, `.add()` was not intercepted, so a bare slice-literal
argument stored a raw `ArrayList` (the exact #6546 Bug 1 failure mode),
and reading it back later threw `ClassCastException: class
java.util.ArrayList cannot be cast to class [Ljava.lang.Object;`.

**Fix.** Two parts, mirroring the suggested fix direction in the issue:

1. `JvmCaseField` (`codegen/01_types.l`) gained its own `genericArgs:
   List[TypeExpr]` field — a record/case field's OWN declared-type generic
   instantiation arguments, computed via the SAME `returnTypeGenericArgs`
   helper a function's declared return type already uses (`rows:
   List[slice[Int]]` records `[slice[Int]]` here exactly as a function
   returning `List[slice[Int]]` would). Populated at every
   `JvmCaseField` construction site in `collectFileCasesExtern`/
   `lowerRecord`/`lowerUnion` (`06_items.l`): union case fields
   (`UFNamed`/`UFPos`), record and exposed-record fields (`RMField`),
   protected-type fields (`PFVar`/`PFLet`/`PFImmutable`), and opaque-type
   fields (`OMField`) all pass the field's own (alias-resolved, where
   applicable) `TypeExpr` through `returnTypeGenericArgs`; the
   synthesised `@projectable` view-field site passes `newList()` since no
   source `TypeExpr` is available there (the view field's type is
   recovered from an already-erased `JvmType`).
2. `scrutineeGenericArgs` (`03_match.l`) gained a top-level `EMember` arm
   (distinct from the existing nested `EMember` arm inside the `ECall`
   case, which resolves a METHOD-CALL receiver's return type, not a plain
   field read): a new `fieldGenericArgsOf(ctx, recv, fieldName)` helper
   resolves the receiver's class via `receiverClassOf` (the same bare
   local/parameter/`self` resolution the method-call-receiver arm already
   uses) and looks `fieldName` up in `ctx.caseFields` for its recorded
   `genericArgs`.

**Testing.** New `field_access_list_of_slice_add_jvm_self_test.l`
(`lyric-compiler/lyric/`, not `lyric-compiler/jvm/`): a `@test_module`
importing only `Std.*` is compiled by the OUTER `lyric test` binary's own
(possibly stale, prebuilt) compiler, which would silently validate
nothing after a codegen-only change — so this test drives the in-process
`Jvm.Bridge.compileToJarBundled` pipeline directly (mirroring
`jvm_auto_ffi_bridge_self_test.l`), compiling and running a real embedded
program via `java -jar` and asserting on captured stdout. Two cases: a
bare slice literal added via a field-access receiver (`c.rows.add(...)`),
and via `self.rows.add(...)` from an instance method. Confirmed
load-bearing by reverting the `EMember` arm and observing the exact
predicted `ClassCastException: class java.util.ArrayList cannot be cast
to class [Ljava.lang.Object;` (and its mirror,
`[Ljava.lang.Object; cannot be cast to class java.util.ArrayList`, for
the self-field case) instead of a pass.

This is also the first JVM self-test to need REAL (not empty) stdlib
source for a bundled in-process compile of a `List`/`newList`-using
program: `Lyric.Emitter.findStdlibSources()` (the existing public helper)
returns the `.NET`-kernel stdlib source, which fails JVM codegen on
`Std.CollectionsHost`'s kernel externs (`error[J002]: stackmap simulation
underflow at newList`) since they don't share a verbatim lowering with
the JVM-specific `_kernel_jvm/` host files. Added
`Lyric.Emitter.findStdlibSourcesJvm()` (a one-line `pub func` wrapper
around the existing private `findStdlibSourcesForTarget(true)`, mirroring
`findStdlibSources()`'s own `findStdlibSourcesForTarget(false)` wrapper)
so a JVM self-test needing real stdlib source in-process has a public
entry point, rather than reaching for the wrong (.NET) helper or an empty
list.

Zero regressions in `list_of_slice_construction_jvm_self_test.l` (4,
#6546's own test), `generic_param_field_read_jvm_self_test.l` (7, #6691 +
#6959), `generic_element_field_read_jvm_self_test.l` (4, #6708), and
`jvm_cross_package_collision_self_test.l` (10).

Closes #6957.
