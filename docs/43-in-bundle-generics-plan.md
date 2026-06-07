# 43 — In-bundle generics plan (self-hosted MSIL backend)

**Status:** Unbacked execution plan / handoff. Captures the implementation plan for
making the self-hosted MSIL backend emit *truly generic* in-bundle types
(GenericParam metadata + VAR fields + instantiated TypeSpec construction/field/match),
so generic records/unions — and the stdlib `Std.Core.Option[T]` / `Result[T,E]` when
the self-hosted compiler compiles `core.l` — byte-match the F# bootstrap emitter.

**Why this doc exists:** the work below was scoped and partially prototyped in a
session where the GitHub MCP was unavailable, so it is captured here instead of on the
issue. Point an agent at this file for full context.

**Parent spec / backing:** extends the Band 4 "user generic types (C8)" item of
`docs/09-msil-emission.md`'s self-hosted emitter gap analysis,
`docs/41-self-hosted-compiler-gap-analysis.md` (linked from its Band 4 open question).
Open questions: **Q-GEN-001–Q-GEN-005** (see the Open questions section below).

## Related issues

- **Epic #2359** — "Concrete generics in the self-hosted MSIL backend (F#-compatible
  object model)". The umbrella: make the self-hosted backend byte-compatible with the
  F# bootstrap emitter so F#-compiled compiler DLLs can be linked as restored deps and
  the F# self-test wrappers deleted.
- **#2360 Stage 1** — concrete `MClass` (CLASS + TypeDefOrRef) signatures. **Merged.**
- **#2361 Stage 2** — concrete `List[T]` / `Map[K,V]` (reference *and* value elements,
  unboxed). **Merged** (PRs #2487 foundation, #2501 reference elements, #2518 value
  elements).
- **#2362 Stage 3** — concrete `Option[T]` / `Result[T,E]`. **Partially addressed:**
  params/returns already resolve to concrete `MGenericInst` cross-assembly; the
  *remaining* work (record/union **fields** of generic type, and the stdlib's own
  generic emission) is exactly what **this doc's feature unblocks**. The architect
  finding for #2362 is that F# does **not** arity-suffix Lyric union names (`Option_Some`,
  not ``Option_Some`1``) but carries GenericParam rows — so this feature, not a name
  change, is the real prerequisite.
- **#2363 Stage 4** — converge union case-class naming `Union$Case` → `Union_Case`.
  **Merged** (PR #2540). The separator is now a constant `_` everywhere
  (`caseParentUnion` map for parent-FQN recovery).
- **#2364 Stage 5** — link compiler DLLs, convert self-tests to `@test_module`, delete
  the 15 F# `SelfHosted*Tests.fs` wrappers. **Pending.** Note: Stage 5's linking likely
  does **not** require this feature (the consumer *reads* the F# DLLs' signatures and
  references them), so full in-bundle generics is the strict-byte-match path, not a hard
  blocker for deleting the wrappers. It was chosen as the next investment to make the
  self-hosted stdlib byte-identical to F#.

## The problem this feature solves

In-bundle generic types are currently **fully erased**: a `record Box[T]` / `union
Maybe[T]` drops its type parameters. `typeExprToMsilCtx` lowers `Box[Int]` to `MObject`
(the `ffiTypeRefs` miss at `codegen.l` ~2668), a type-param field `value: T` lowers to
the bogus `MClass(pkgName + ".T")` (`codegen.l` ~2729), and construction emits a
non-generic `newobj P.Box::.ctor`. The F# emitter instead emits these as real generic
TypeDefs (bare names + GenericParam rows + VAR fields + instantiated TypeSpec usage).

**Critical discovery (the make-or-break constraint):** emitting GenericParam rows alone
turns `Box` into a generic TypeDef, but the existing non-generic construction
(`newobj P.Box::.ctor`) and field access (`ldfld P.Box::value`) then reference an *open*
generic type → `System.TypeLoadException: Could not load type 'P.Box'` at run time. A
non-generic `Box` loads fine; only the now-generic one fails. So the **usage layer**
(construction / field / match / signatures) must become generic-aware *in lockstep* with
the metadata layer — this is an all-or-nothing change per generic type.

## What already works — the cross-assembly path (use as the template)

The stdlib `Option`/`Result`, consumed from another assembly, already round-trip as
generics. Trace and mirror it for in-bundle types:

1. **Type lowering → `MGenericInst`.** `typeExprToMsilCtx` `TGenericApp` arm
   (`codegen.l` ~2604–2685): resolves the head FQN, looks up
   `cctx.ffiTypeRefs[headPkg + "/" + headFqn]`, and on a hit builds
   `MGenericInst(typeRefCode = tdrTypeRef(row), headFqn, typeArgs)`. On a miss it returns
   `MObject` — **this is the in-bundle erasure point** (in-bundle types are TypeDefs,
   never in `ffiTypeRefs`).
2. **Signature encoding.** `bufMsilType` (`lowering.l` ~260) and `bufMsilTypeWithCtx`
   (~1389) emit `MGenericInst` as `0x15 0x12 <compressed typeRefCode> <argCount>
   <args…>`. Both take a pre-baked coded index and do **not** resolve by name.
3. **Construction.** `buildGenericCaseCtorTok` (`codegen.l` ~14906): reads
   `caseTypeParamCount` / `fieldVarIndices`, infers `typeArgs`, builds ctor params as
   `MTypeVar(varIdx)`, emits `MNewobjGenericCase(typeRefRow, typeArgs, ctorParams)`.
   Lowering (`lowering.l` ~1750) builds a TypeSpec via `buildGenericInstBlobWithCtx(ctx,
   tdrTypeRef(typeRefRow), typeArgs)` + a TypeSpec-parented `.ctor` MemberRef. **This is
   the only generic-usage instruction hardcoded to a TypeRef** (no TypeDef branch).
4. **Field access.** `MLdfldGeneric` lowering (`lowering.l` ~1711) **already tries
   `findTypeDefRowByName` first** → `tdrTypeDef(defRow)` → TypeSpec MemberRef. Already
   in-bundle-capable.
5. **Matching.** `MIsinstGeneric` / `MCastclassGeneric` lowering (`lowering.l`
   ~1643–1709) **already branch `findTypeDefRowByName` first**. Already in-bundle-capable.
6. **`buildGenericInstBlobWithCtx`** (`lowering.l` ~1451): its `typeDefOrRef` parameter
   is written verbatim — agnostic to `tdrTypeRef` vs `tdrTypeDef`. **Already encodes a
   TypeSpec over a TypeDef.**

**Conclusion:** the usage-side machinery (isinst/castclass/ldfld) already resolves
in-bundle TypeDef rows by name at lowering time. The gaps are: (a) type lowering never
produces an in-bundle `MGenericInst`; (b) construction is TypeRef-only; (c) the type-decl
layer emits no GenericParam rows and erases `T` fields.

## Core problem: TypeDef-row timing → resolve by name

`typeExprToMsilCtx` runs at codegen (Phase 3); in-bundle TypeDef rows are allocated
during lowering (Phase 5, `addTypeDef`). Codegen has `typeFqnByName` (name→FQN) but **no
name→predicted-row map**, so it cannot bake a `tdrTypeDef(row)` into an `MGenericInst`.
The `typeDefRowByFqn` registry (seeded by the discovery pass, `lowering.l` ~2670) is
available **only at lowering time**.

**Recommended encoding — a by-name `MsilType` variant** (mirrors the proven
`MCastclassByName`/`MLdfldByName` deferred-by-name pattern):

```
case MGenericInstByName(headFqn: String, typeArgs: List[MsilType])   // add to MsilType (lowering.l ~43)
```

Add a `bufMsilTypeWithCtx` arm (alongside the `MGenericInst` arm, `lowering.l` ~1389):

```
case MGenericInstByName(headFqn, typeArgs) -> {
  val defRow = resolveSigTypeDefRow(ctx, headFqn)     // discovery-registry aware (lowering.l ~2656)
  val coded = if defRow > 0 { tdrTypeDef(defRow) }
              else { val r = findTypeRefRowByName(ctx, headFqn); if r > 0 { tdrTypeRef(r) } else { 0 } }
  if coded > 0 {
    bufU1(w, 0x15); bufU1(w, 0x12); writeCompressedInt(w, coded); bufU1(w, typeArgs.count)
    var gi = 0
    while gi < typeArgs.count { bufMsilTypeWithCtx(w, genericArgType(typeArgs[gi]), ctx); gi = gi + 1 }
  } else { bufU1(w, 0x1C) }  // OBJECT fallback keeps the blob valid
}
```

Also add `MGenericInstByName` arms to: context-free `bufMsilType` (degrade to `0x1C`,
no ctx — only reached for BCL sigs); `elementTypeByte` (→ `0x15`); `msilTypeKey`;
`genericArgType` (pass through); and the LocalVarSig degrade-to-object path
(→ `0x1C`, same as `MGenericInst`; locals are object slots that `castclass` at op sites).

For **construction**, add a by-name sibling of `MNewobjGenericCase` (keeps the proven
TypeRef path untouched):

```
case MNewobjGenericByName(headFqn: String, typeArgs: List[MsilType], ctorParams: List[MsilType])
```

whose lowering mirrors `MNewobjGenericCase` (`lowering.l` ~1750) but resolves the coded
index via `resolveSigTypeDefRow(ctx, headFqn)` → `tdrTypeDef`, falling back to
`findTypeRefRowByName`. `MIsinstGeneric`/`MCastclassGeneric`/`MLdfldGeneric` need **no new
variants** (already TypeDef-by-name capable) — only the codegen `match` guards that emit
them must also fire on `MGenericInstByName` scrutinees.

## Type-decl layer (GenericParam rows + VAR fields)

### Model threading (`lowering.l`)
Add `generics: List[String]` to `MRecord` (~654), `MUnion` (~674), `MUnionCase` (~669).
Populate from the AST in codegen: `lowerRecordMsil` (`codegen.l` ~11213) and
`lowerUnionMsil` (~11254) read `decl.generics` (`Option[GenericParams]`,
`parser_ast.l` ~377/398; `GenericParam` is `GPType(name,_)` | `GPValue(name,constraint,_)`
at ~172). Add a `genericNamesOf(Option[GenericParams]): List[String]` helper that
collects `GPType` names only (skip `GPValue` const-generics — out of scope, handled by
mono). `MUnion.generics` propagates to **every** `MUnionCase.generics` (each case class
re-declares the union's full param list — confirmed against the F# DLL). Every `MRecord`/
`MUnion`/`MUnionCase` constructor must pass `generics` (synthetic SM/generator/distinct
records pass `newList()`; copy sites pass `rec.generics`).

### VAR-typed fields
Lower a generic type's fields with a generics-aware helper
`typeExprToMsilG(te, pkgName, generics)`: a `TRef` whose segment ∈ `generics` →
`MTypeVar(index)`; everything else delegates to `typeExprToMsil`. Apply in
`lowerRecordMsil` and `lowerUnionMsil` field lowering. Result: `Box.value: T` →
`MTypeVar(0)`, encoded `06 13 00` by `buildFieldSigWithCtx` → `bufMsilTypeWithCtx`'s
existing `MTypeVar` arm (`lowering.l` ~1364).

### GenericParam table (0x2A) — validated wire format
Decoded from `.bootstrap/stage1/Lyric.Stdlib.dll`: `heapSizes=0` (all 2-byte indices),
**sorted-mask bit 42 set**, 48 GenericParam rows, bare type names (`Option_Some`, no
``\`1``), `Option_Some.value` = `06 13 00` (VAR 0 = T), `Result_Ok.value` = `06 13 00`,
`Result_Err.error` = `06 13 01` (VAR 1 = E). Every generic TypeDef **and** every case
class carries its own GenericParam rows.

`tables.l` additions:
- `GenericParamRow { number: Int /*u2*/; flags: Int /*u2, 0*/; owner: Int /*TypeOrMethodDef coded*/; name: Int /*#Strings*/ }`.
- `TABLE_BIT_GENERIC_PARAM: Long = 4398046511104i64` (2^42).
- Coded-index helpers (1-bit TypeOrMethodDef tag): `mtdTypeDef(row) = row*2 + 0`,
  `mtdMethodDef(row) = row*2 + 1`.
- `genericParams: List[GenericParamRow]` on `MetadataTables` + `newMetadataTables` +
  `addGenericParam`.
- In `serializeTablesStream` (~655): GenericParam (0x2A) slots **between**
  ManifestResource (0x28) and MethodSpec (0x2B) in **all three** loops (valid bitmask,
  rowCount, rows). Set sorted-mask bit 42 when rows present (replace the `w8(buf, 0i64)`
  sorted-mask write). **Physically sort `genericParams` by `(owner, number)` before
  emission** — the CLR binary-searches GenericParam by owner; an unsorted table →
  `TypeLoadException`. Row wire: `w2(number); w2(flags); w2(owner); w2(name)` (8 bytes).

Emit rows: in `lowerMRecord` (`lowering.l` ~2078, after `addTypeDef`), `lowerMUnion`
(~2326, the abstract base), and `lowerMNullaryUnionCase` (~2221). Owner row =
`t.typeDefs.count` right after each `addTypeDef`; `owner = mtdTypeDef(row)`; `name =
internString(sh, generics[i])`; `number = i`.

### AutoLayout guard (the first TypeLoadException cause)
A generic TypeDef with a type-variable field **cannot** use `TDF_SEQUENTIAL_LAYOUT`. In
`lowerMRecord` (`lowering.l` ~2073), drop `TDF_SEQUENTIAL_LAYOUT` when `r.generics` is
non-empty (use AutoLayout). Union cases already extend the abstract base → AutoLayout, so
only top-level generic records need the guard. (This fix alone is necessary but not
sufficient — the construction/field references still need to be generic, see below.)

## Type-lowering detection + routing (`codegen.l`)

- Add `genericTypeArity: Map[String, Int]` to `CodegenCtx`, populated in
  `addPackageTokens` (~1384–1617) for in-bundle `IRecord`/`IUnion` with non-empty
  `decl.generics`. Also populate `caseTypeParamCount` and `fieldVarIndices` for in-bundle
  unions (mirror `registerStdlibTypeItem` ~15172, which only does this for stdlib/restored
  types today).
- In `typeExprToMsilCtx` `TGenericApp` (~2652): **before** the `ffiTypeRefs` lookup,
  if the head is an in-bundle generic type (per `genericTypeArity`), emit
  `MGenericInstByName(headFqn, resolvedArgs)` instead of the `MObject` erasure.
- **Construction** (~6270–6395): route in-bundle generic records via a
  `buildGenericRecordCtorTok` analog and in-bundle generic union cases via an extended
  `buildGenericCaseCtorTok` (or parallel helper) that detects an in-bundle case and emits
  `MNewobjGenericByName`. `typeArgs` come from `argTypes` + `fctx.contextHintTyArgs` /
  `declaredRetTy` exactly as the cross-assembly path (~6278–6297, 6365–6370).
- **Field access** (EMember/EIndex) and **matching** (EMatch): extend the `match` guards
  that currently fire on `MGenericInst` (~5129, 5247, 5471, 5550, 5599) to also fire on
  `MGenericInstByName`. The lowering needs no change (already TypeDef-by-name).
- **Method signatures** (params/returns/fields) flow through `bufMsilTypeWithCtx`'s new
  arm. A method *inside* a generic type that references `T` must emit `MTypeVar(idx)`
  (extend the generics-aware field lowering to method params/returns).

## Mono interaction — orthogonal

`Lyric.Mono` (`lyric-compiler/lyric/mono.l`) specializes generic **functions** (`IFunc`)
only; it never rewrites generic record/union TypeDefs. This feature is about generic
**types**: `Box[Int]`/`Box[String]` share one generic `Box` TypeDef + per-site TypeSpecs.
**Scope this work to generic types only; leave generic-function mono untouched.** Do not
attempt to de-monomorphize functions in the same change.

## Smallest verifiable slice (sequenced — front-load the load test)

1. **`record Box[T] { value: T }` loads + round-trips.** Minimal surface: model
   `generics`; `genericNamesOf`; GenericParam serializer (table 0x2A) for the record
   TypeDef; VAR field; AutoLayout guard; `MGenericInstByName` + its `bufMsilTypeWithCtx`
   arm; in-bundle construction via `MNewobjGenericByName`; field read via existing
   `MLdfldGeneric`; `genericTypeArity` detection. **Verify:** `val b = Box(value = 5);
   println(toString(b.value))` compiles, the DLL **type-loads** (no `TypeLoadException`),
   prints `5`. This is make-or-break — a malformed generic TypeDef fails at *load*,
   masking usage-layer correctness.
2. **`union Maybe[T] { case Just(value: T); case Nothing }`.** Adds: GenericParam rows on
   the abstract base **and** each case TypeDef; in-bundle `caseTypeParamCount` /
   `fieldVarIndices`; nullary-case singleton interaction (check the F# `Option_None`
   `Instance` field typing and mirror it); matching via `MIsinstGeneric`/
   `MCastclassGeneric`. **Verify:** `match Just(value = 3) { case Just(v) -> v; case
   Nothing -> 0 }` → `3`.
3. **Stdlib `Option[T]`/`Result[T,E]` via stage-3 byte-match.** Once `core.l`
   self-compiles its generics as truly generic, run `scripts/bootstrap.sh --stage 3` and
   confirm the self-hosted `Lyric.Stdlib.dll` GenericParam table matches the F# stage-1
   DLL. This exercises 2-param generics (`Result[T,E]`), GenericParam `number` ordering,
   and cross-case param sharing.

Iterate steps 1–2 with `make stage1-fast` + a focused `*_self_test.l` (~seconds); step 3
needs `make lyric` + the full bootstrap.

## Risks / gotchas

- **GenericParam sort + owner coding** — wrong sort or owner code → `BadImageFormatException`
  / `TypeLoadException` at load. The serializer is validated against F#; re-verify with
  step-3 byte-compare.
- **Nullary generic case (`None`/`Nothing`)** — `lowerMNullaryUnionCase` emits a singleton
  `Instance` static field + `.cctor`; for a generic union the field type / `.cctor` must
  agree with F# (inspect F# `Option_None` before step 2).
- **`ffiTypeRefs` vs in-bundle disambiguation** — both currently miss `ffiTypeRefs`
  → `MObject`. Check `genericTypeArity` *before* `ffiTypeRefs` so in-bundle wins;
  cross-package generics still route through `ffiTypeRefs` → `MGenericInst`.
- **Locals of generic type** degrade to `object` in LocalVarSig (with `castclass` at use
  sites via existing `MCastclassGeneric`).

## Verification without a disassembler (no ildasm available)

- The self-hosted `Msil.MetadataReader` (`lyric-compiler/msil/metadata_reader.l`,
  `readTablesHeader`/`rowCountOf` ~317–372) can open the emitted DLL and assert
  `rowCountOf(th, 42) > 0`; add a small GenericParam row reader (8 bytes/row) to dump
  `(number, flags, owner, name)` for direct comparison.
- Or a throwaway Python PE/CLI decoder (parse PE → COR20 → `#~` → GenericParam at the
  8-byte stride) to diff against `.bootstrap/stage1/Lyric.Stdlib.dll`.
- Guards: `generic_specialization_self_test.l`, `nested_generic_self_test.l`,
  `stdlib_generic_mono_self_test.l`, `lyric-stdlib/tests/core_tests.l`, and the
  **bootstrap stage-3 byte-compare** (the ultimate guard).

## Open questions

- **Q-GEN-001 — Nullary generic case singleton.** A generic union's nullary case
  (`Option_None`, `Maybe.Nothing`) emits a singleton `Instance` static field + `.cctor`
  (`lowerMNullaryUnionCase`). For a generic type, what is the `Instance` field's type and
  the `.cctor` body in the F# emitter — the open generic, a fixed instantiation, or
  `object`? Must be decoded from `Lyric.Stdlib.dll` and mirrored before the union slice
  (step 2).
- **Q-GEN-002 — Generic methods (MVAR) scope.** This plan reifies generic *types* only
  (TypeDef-owned GenericParam rows, VAR `0x13`). Generic *methods* need MVAR
  (`ELEMENT_TYPE_MVAR = 0x1E`) + MethodDef-owned GenericParam rows, and the self-hosted
  compiler currently relies on `Lyric.Mono` to monomorphize generic functions. Do generic
  functions stay monomorphized (recommended — mono is orthogonal) or also reify? The 39
  MethodDef-owned GenericParam rows in the F# DLL are out of scope here; confirm leaving
  them monomorphized still byte-matches at the *type* level.
- **Q-GEN-003 — `GPValue` const-generics.** `genericNamesOf` collects `GPType` names only
  and skips `GPValue` (value/const generics). How are value-generic types represented
  (today: erased / mono-specialized)? Confirm skipping them here is correct and tracked.
- **Q-GEN-004 — Cross-assembly ↔ in-bundle interaction.** Once `Std.Core` self-compiles
  `Option`/`Result` as reified generics, confirm the *consumer* path (restored-dep
  registration + `ffiTypeRefs` → `MGenericInst`) still binds against the now-generic
  TypeDefs, and that `caseTypeParamCount`/`fieldVarIndices` registration is consistent
  across in-bundle (`addPackageTokens`) and restored (`registerStdlibTypeItem`) paths.
- **Q-GEN-005 — LocalVarSig degrade coverage.** Locals/fields of a generic type degrade
  to `object` (0x1C) in LocalVarSig, relying on `castclass` (via `MCastclassGeneric`) at
  every use site. Audit that all read/store sites for generic-typed locals emit the
  narrowing cast, so no `object`-typed slot reaches a generic-member callvirt unverified.

## Key file:line references

- `lyric-compiler/msil/codegen.l`: `typeExprToMsilCtx` `TGenericApp` ~2604–2685 (in-bundle
  erasure ~2668); `typeExprToMsil` type-param erasure ~2729; construction ~6270–6395
  (non-generic fall-through ~6389); generic-usage emission ~5129/5247/5471/5550/5599;
  `buildGenericCaseCtorTok` ~14906; `addPackageTokens` in-bundle registration ~1384–1617;
  `lowerRecordMsil` ~11213 / `lowerUnionMsil` ~11254 (drop `decl.generics` today).
- `lyric-compiler/msil/lowering.l`: `MsilType` ~43; `bufMsilType` ~260 /
  `bufMsilTypeWithCtx` ~1389; `buildGenericInstBlobWithCtx` ~1451 (TypeDef-capable);
  generic-usage lowering ~1643–1775 (`MNewobjGenericCase` TypeRef-only ~1750);
  `lowerMRecord` ~2036 (GenericParam + AutoLayout + VAR sigs); `lowerMNullaryUnionCase`
  ~2221 / `lowerMUnion` ~2326 (per-case + base GenericParam rows); `resolveSigTypeDefRow`
  ~2656 / discovery `typeDefRowByFqn` ~2670; `MRecord`/`MUnion`/`MUnionCase` ~654–679.
- `lyric-compiler/msil/tables.l`: GenericParam table 0x2A **absent** — add per above.
- `lyric-compiler/lyric/mono.l`: generic-function-only (orthogonal).
- `lyric-compiler/lyric/parser/parser_ast.l`: `GenericParams`/`GPType` ~172–180;
  `RecordDecl.generics`/`UnionDecl.generics`/`FunctionDecl.generics` ~377/398/449.
- Reference DLL: `.bootstrap/stage1/Lyric.Stdlib.dll` (F# baseline: bare names, sorted
  bit 42, 48 GenericParam rows, `value`=`06 13 00`, `error`=`06 13 01`).
