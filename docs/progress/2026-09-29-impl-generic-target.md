# `impl[T] I for Box[T]` compiles on both targets with the target's type-parameter context (#7704)

An `impl` block whose target is a generic record never compiled, on either
target, although the language reference has long described
`impl[T] Iface for Target[T]`:

- **Type checker.** `checkImplConformance` and `registerImplsFromItems`
  resolved the impl's target (`Box[T]`) and its methods' parameter and return
  types with an empty generic context, so every `T` was T0010 "unknown type
  name". Both now resolve under the impl's own type parameters
  (`declGenericContext(decl.generics)`); `checkImplMemberBodies` already did.
- **JVM.** `typeExprToJvmClass` refused a `TGenericApp` target (J008).
- **MSIL.** `implTargetNameMsil` named a `TGenericApp` target
  `<pkg>.__impl_target`, and `lowerMImpl` looked the target TypeDef up without
  its arity suffix.

Past those, both backends lowered every impl method with a hard-coded empty
type-parameter list (`noGenericsImpl` in `lowerImplMethodMsil`, `noTpsImpl` in
`lowerImplMethod`), so an impl method got none of the handling a method
declared in `record Box[T]`'s own body gets. The impl lowerings now take the
target's type parameters:

- **MSIL** (`lyric-compiler/msil/codegen.l`). `implTargetGenericsMsil` lists
  the target's arguments in the target type's own parameter order, so
  `impl[K, V] I for Pair[V, K]` maps `V` to `!0`. `lowerImplMethodMsil` takes
  that list and, like `lowerRecordMethodMsil`, resolves its signature and
  declared return through the VAR-form `typeExprToMsilG`
  (`memberTypeExprToMsil`), binds `self` to the open instantiation
  `Box`1<!0>` and sets `FuncCtx.reifiedGenerics` (#7695) through the shared
  `bindGenericSelfMsil`, and registers its parameters with the same list. The
  concrete-receiver registration in `addPackageTokens`
  (`registerMethodParamTypesG`, return types), the `MPImpl`'s TypeDef name
  (`Pkg.Box`1`) and a restored package's impl registration
  (`registerRestoredImpl`) use it too. A call on a `Box[Int]` receiver then
  goes through the existing generic-receiver path (`MCallvirtGeneric`), as for
  the record's own methods.
- **JVM** (`lyric-compiler/jvm/codegen/06_items.l`). `lowerImplMethod` takes
  the impl's type parameters and erases them to `Object` in its descriptor
  (`typeExprToJvmErasedExtern`, `holderAwareParamTypes`), its parameter slots
  and `FuncCtx.typeParams`, and the `IImpl` registration uses
  `registerInstanceSigErased` with the same list, as `lowerRecordMethod` and
  its registration do.
- **Middle end.** `Lyric.ImplDefaults.implTargetName` (diamond-conflict
  tracking) and the hoist engine's impl-target field lookup
  (`hzImplTargetFieldNames`, which lets an impl body name a field bare) key a
  generic target by its head instead of skipping it.

Such an impl applies to every instantiation of its target, because both
backends attach its methods to the target's one generic class. A target whose
arguments are not the impl's own type parameters, each named once — an impl
for one instantiation (`impl I for Box[Int]`), a repeated parameter
(`impl[T] I for Two[T, T]`), or an impl parameter the target never names — is
now **T0145** (language reference §3.9, book appendix B).

`--target native` does not lower such an impl yet (its documented surface is
`impl I for Record` on a non-generic record): a call to one of its methods is
reported as N0007 ("method '.countWith' on this receiver is not yet supported
for --target native") rather than miscompiled.

Generic *interfaces* are a separate, larger gap and are not addressed here:
`interface Holder[T] { func get(): T }` is T0010 in the conformance check with
any implementor, and neither backend reifies a Lyric interface's type
parameters (the MSIL interface slot would have to be a generic CLR interface
for `get(): int32` to implement it).

## Verification

New dual-target `lyric-compiler/lyric/impl_generic_target_self_test.l`:
`impl[T] Counted for Box[T]` whose method declares `List[T]` and `val y: T`
locals and reads the `T` field bare and through `self`, instantiated with
`Int`, `String` and a record and called on the concrete receiver and through
an interface-typed binding. Before: T0010 on dotnet, J008 on jvm. After: all
cases pass on both targets and the dotnet DLL is ilverify-clean; it runs in
both compiler self-test batches and in `scripts/ilverify-selfhosted.sh`'s
phase 4. `typechecker_self_test.l` covers the conformance fix and each T0145
shape.
