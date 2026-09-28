# Generic record/union method body-local `T` annotations resolve on both targets (#7695)

Inside a method of a generic record (e.g. `Box[T]`), the method's own
params/return/`self.<field>` reads already resolved the enclosing
type's own type parameter `T` correctly on both targets — but a
BODY-LOCAL type annotation naming `T` (`var x: T`, `val y: T = ...`,
a `List[T]`/`Option[T]` local annotation) fell through to a
generics-blind resolution path on both backends, treating `T` as an
unqualified in-package class reference that does not exist:

- `--target jvm`: `NoClassDefFoundError: <pkg>/T` the first time the
  method ran (the JVM loads a referenced class lazily, at the first
  `checkcast`/`new` targeting it).
- `--target dotnet`: ran (the CLR JIT does not itself verify CIL at
  load time), but `ilverify` reported `StackUnexpected ... found
  Int32 ... expected ref 'object'` in `Box`1::pick` — the local's
  `.locals` signature disagreed with the real `!0`-typed value
  flowing from `self.value`/params.

## MSIL

`typeExprToMsilBodyCtx` (`lyric-compiler/msil/codegen.l`) only
consulted `FuncCtx.generics` — a generic FUNCTION's own type params,
erased to `MObject` via `typeExprToMsilGenBody` — which a
record/union method never populates. Added a new `FuncCtx
.reifiedGenerics` field, set by `lowerRecordMethodMsil` to the
enclosing type's own generic-parameter names, that
`typeExprToMsilBodyCtx` prefers: it resolves through the VAR-form-
aware `typeExprToMsilG` (the same helper the method's signature and
fields already use), so `var x: T` reifies to the real `MTypeVar`
just like `self.value`/params do — loads/stores between the local,
the field, and params need no boxing/casting.

Fixing the annotation surfaced a second, narrower gap: a captured
value whose logical type is `MTypeVar` cannot keep that bare `!0`
type once it crosses into a lifted `__lambda_*`'s own closure-class
field or its own `FuncCtx` — a lifted lambda is always emitted on the
non-generic package host class (#1877 Phase 2's Uniform Func ABI),
so `!0` has no enclosing generic scope there and is malformed
metadata (`BadImageFormatException` at JIT time). Fixed by:

- `synthesizeClosureClassMsil`: a BY-VALUE (non-cell) capture whose
  type is `MTypeVar` now erases the closure-class FIELD to `MObject`
  (the CELL-capture path already got this for free through
  `cellStorageElemTyMsil`).
- The capture-store site (`MNewobjByName`/`MStfldByName` loop, which
  runs in the ENCLOSING method's real generic scope): boxes a
  `MTypeVar`-typed local/param via the same bare-VAR-TypeSpec `box`
  idiom `boxForUnionEqualityMsil`/`pushDefaultValueMsil` already use,
  before storing it into the erased field.
- The LAMBDA's own `captureNameToType` (populated where
  `lowerFuncMsil` registers a `__lambda_*`'s captures): erases
  `MTypeVar` to `MObject` right there, so every downstream consumer
  inside the lambda body (`EPath`'s capture-read arm,
  `emitCellAssignMsil`'s `elemTy`) is already `MObject`-consistent and
  never constructs a bare-VAR TypeSpec inside the lambda's own
  (non-generic-owner) scope. The ENCLOSING method's own
  `hoistedCellType`/`types` are untouched, so reads of the captured
  `var` back in the enclosing method still correctly use `MTypeVar`.
- `boxIfNeededMsil`/`castObjectToMsil` gained `MTypeVar` arms (box /
  `unbox.any` against a bare-VAR TypeSpec) for the hoisted-cell
  store/load path a `var x: T` capture cell now needs — `T` may be
  instantiated with a value type, so the cell's `object[]` storage
  must box on write and unbox on read like any other erased slot.

## JVM

`localAnnotatedJvmType` (`lyric-compiler/jvm/codegen/05_stmts.l`)
resolved a body annotation via the typeParams-BLIND
`typeExprToJvmExtern`. Added a `FuncCtx.typeParams` field (the
enclosing generic method's own type-parameter names), threaded
through `makeFuncCtxInstance` from `lowerRecordMethod` (empty for
every other instance-method context: protected-type entries, impl
methods — impl methods on a generic type have no generic support at
all yet on either backend, a separate, larger gap, see below).
`localAnnotatedJvmType` now resolves through the typeParams-aware
`typeExprToJvmErasedExtern`, matching the method's own params/return.

Two more call sites carried the identical typeParams-blind bug,
surfaced only once the annotation itself was fixed (a `List[T]` local
annotation still produced `NoClassDefFoundError` even after the
above):

- `recordDeclaredElemType`'s four call sites in `05_stmts.l` passed a
  hardcoded `newList()` for `typeParams` instead of `ctx.typeParams`,
  so `List[T]`/`Map[_, T]`'s consulted element-type registration never
  skipped a type-param element — `xs[0]` on a `val xs: List[T] = ...`
  local then `checkcast`-ed against the bogus `T` class.
  `Option[T]` was unaffected (it isn't `List`/`Map`-shaped, so this
  function never recorded anything for it in the first place).
- `recordVarGenericArgs` (`03_match.l`) fell back to
  `annotationGenericArgs(te)` — the ANNOTATION's raw type args,
  UNFILTERED — whenever the initialiser's own inferred args were
  empty (true for `newList()`), registering `[T]` verbatim regardless
  of any type-param awareness at all. Added a `typeParams` parameter
  and a `annotationGenericArgsFiltered` helper (mirroring the
  existing `returnTypeGenericArgsFiltered`'s bail-to-empty-on-any-
  type-param-mention policy) so a `List[T]`/`Map[_, T]` annotation
  inside a generic method never registers an unresolvable class name.

No box/unbox distinction was needed on the JVM side beyond getting
the erasure right: the JVM has no reified generics at all (docs/44
M-1), so `T` erases to `Object` uniformly everywhere — fields,
params, locals, closures — with no separate value-type-instantiation
concern.

## Tests

`lyric-compiler/lyric/generic_method_body_typevar_self_test.l`
(`@test_module`, dual-target, 16 cases): a generic record `Box[T]`
with methods covering `var x: T` with no initialiser assigned on
both branches of an `if`/`else` (the original issue's `pick` repro
shape), `val y: T = self.value`, a `List[T]` local annotation, an
`Option[T]` local annotation, and a closure capturing (and
reassigning) a `var x: T` — each instantiated with `Int` (a value
type), `String` (a reference type), and an in-bundle record `Pair`.
16/16 pass on both `--target dotnet` and `--target jvm`.

`lyric-compiler/lyric/method_closure_var_capture_self_test.l`'s
header note (which pointed at #7695 as the tracked follow-up for the
generic-record-method closure-capture case) updated to point at the
new test file.

Wired into `scripts/ci/compiler-self-tests-batch.sh` (dotnet) and
`scripts/ci/jvm-generics-self-tests-batch.sh` (jvm).

## Validation

- `scripts/ci/compiler-self-tests-batch.sh`: 2275 ok, 0 not ok.
- `scripts/ci/jvm-generics-self-tests-batch.sh`: 169 ok, 0 not ok.
- `scripts/ilverify-selfhosted.sh`: 126 DLLs, 0 IL-validity errors
  (the whole self-hosted compiler closure).
- A standalone `lyric build --target dotnet` of the new test file,
  verified directly with `ilverify` against the .NET 10 shared
  runtime and `Lyric.Stdlib*.dll`: "All Classes and Methods ...
  Verified."
- `scripts/ci/jvm-ecosystem-suites.sh`: all 11 suites green (mail,
  storage, resilience, jsonrpc, mcp, health, generator-sdk, web,
  i18n, cache, feature-flags — 0 failed across all).

## Out of scope

- `lowerImplMethodMsil` (MSIL) and `lowerImplMethod` (JVM) pass an
  always-empty `typeParams`/generics list — `impl <Iface> for
  GenericType[T] { ... }` has no generic-type-parameter support at
  all on either backend yet (not just the body-local-annotation gap
  this issue fixes). A separate, larger gap; not touched here.
- A closure's own body-local `T` annotation (as opposed to a captured
  `T`-typed value) is not covered: `FuncCtx.reifiedGenerics` (MSIL)
  is never set for a lifted `__lambda_*`'s own `FuncCtx`, so a NEW
  `val`/`var` declared with a `T` annotation INSIDE a closure body
  (not captured from the enclosing method) would still hit the old
  MObject-erasure-blind fallback. Not exercised by any existing or
  new test; a narrower follow-up if it surfaces.
- Top-level generic functions (`func f[T](...)`) on `--target jvm`
  appear to have the analogous typeParams-blind gap for body-local
  annotations (`lowerFuncScoped`'s `fnElemTps` is computed but never
  threaded into `FuncCtx` for `localAnnotatedJvmType`/
  `recordVarGenericArgs` to consult) — a different call site/AST
  shape than this issue's generic-record/union-method repro, so out
  of scope here; not confirmed by a repro, just read from the code.
- A tuple-pattern's per-element type annotation
  (`val (a, b): (T1, T2) = ...`, `05_stmts.l`'s `lowerLocalPatBind`
  `PTuple` arm) still resolves each element via the typeParams-blind
  `typeExprToJvmExtern` directly, not `localAnnotatedJvmType`/
  `ctx.typeParams`. Not exercised by any test in this ticket's
  matrix; a narrower follow-up if it surfaces.
