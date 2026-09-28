# `pushDefaultValueMsil` seeds a real in-bundle generic type parameter correctly (#7525)

## Root cause

`Msil.Codegen.pushDefaultValueMsil` (`lyric-compiler/msil/codegen.l`) pushes a
zero/default value for an `MsilType` it doesn't otherwise recognise via
`ldnull` — valid only for a type known to be a reference type. A method
declared *inside* a generic `record`/`union` body (`lowerRecordMethodMsil`,
docs/43) keeps its own type parameter `T` as a real CLR generic parameter
(`MTypeVar` / `!0`) through codegen — unlike a generic top-level function,
which the monomorphizer specialises or, failing that, `Msil.Codegen` erases to
`object` (#2557). `pushDefaultValueMsil`'s catch-all `ldnull` arm therefore
emitted invalid IL for `T`: legal for a reference-type instantiation (the CLR
JITs one shared "canonical" compilation where `!0` really is `object`), but
`InvalidProgramException`/`BadImageFormatException`-class invalid IL for a
value-type instantiation (`Box[Int]`), which gets its own JIT compilation
where `!0` is genuinely `int32`.

**Reachable, confirmed with a real program and `ilverify`.** A method
declared inside a generic record whose declared return is `T` and whose body
is (or contains, on a dead branch) a bare `: Never`-typed tail expression
(`panic(...)`) reaches `lowerMethodBodyTailMsil`'s
`pushDefaultValueMsil(cctx, fctx, insns, retTy)` call with `retTy =
MTypeVar(idx)`. Repro:

```lyric
record Box[T] {
  value: T
  func alwaysPanic(): T = panic("boom")
}
func main(): Int {
  val b = Box(value = 42)
  b.alwaysPanic()
  0
}
```

Before the fix this compiled clean and `ilverify` reported no error (the
`ldnull; ret` sequence is genuinely dead code after the unconditional
`throw`, which the CLR IL verifier's flow analysis never type-checks) — but
the JIT still imports the whole method body to build its IL→native mapping,
and calling `Box[Int].alwaysPanic()` crashed with
`System.BadImageFormatException: An attempt was made to load a program with
an incorrect format` instead of throwing `"boom"`. `Box[String]`/other
reference-type instantiations were unaffected (canonical shared code, where
the bogus `object` reference IS valid).

## Fix

Added an `MTypeVar` arm to `pushDefaultValueMsil` that mints a `VAR(n)`
TypeSpec (the same by-name VAR-TypeSpec idiom `boxForUnionEqualityMsil`
already uses for `box`) and emits `initobj` against it — universally correct
for any instantiation of `T`, mirroring the existing
`MValueTypeRef`/`MValueTypeGenericInst` arms (`lyric-compiler/msil/codegen.l`,
`pushDefaultValueMsil`).

Applying that fix in isolation surfaced a second, previously-unreachable bug
it depends on: `Msil.Lowering.buildLocalVarSig`/`buildLocalVarSigWithCtx` (the
`.locals init (...)` signature blob encoders, `lyric-compiler/msil/lowering.l`)
had no `MTypeVar`/`MMethodTypeVar` arm — their catch-all fell back to
`elementTypeByte`, which (by its own doc comment) returns only the VAR/MVAR
*prefix* byte and relies on the caller to append the trailing index byte the
way `bufMsilType` does; the local-sig catch-all never did, truncating the
blob. Confirmed directly via `System.Reflection.Metadata`: the emitted
LocalVarSig blob was `[07,01,13]` (`LOCAL_SIG`, count=1, `ELEMENT_TYPE_VAR`
with **no index byte**), and `ilverify` reported `Unable to resolve token` on
the method's `initobj` instruction as a direct consequence. No source shape
reached a `T`-typed *local* before this fix — record/union field and
method-signature encodings all resolve `T` through ctx-aware paths that
already handled `MTypeVar` correctly — so this was latent and untriggered
until `pushDefaultValueMsil`'s new arm became the first caller to allocate
one (via `allocSlotMsil`). Fixed both `buildLocalVarSig` and
`buildLocalVarSigWithCtx` alongside the `pushDefaultValueMsil` fix.

Verified: `ilverify` clean on the repro DLL and on the full self-hosted
compiler closure (126 DLLs via `scripts/ilverify-selfhosted.sh`), and the
repro now correctly throws `"boom"` instead of crashing at JIT time.

## Second finding: the `object[] __caps` closure-cell fallback is dead code

The issue's second item asked whether the fallback cell read for a lambda
without a synthesised closure class (`__caps` typed as `object[]`, reading
via `ldelem.ref`) is still reachable now that every capturing lambda gets a
closure class (docs/53, D113). Traced every consumer of
`cctx.lambdaClosureClasses`/`fctx.types["__caps"]`
(`lyric-compiler/msil/codegen.l`): the single registration site (inside
`liftLambdasMsil`'s `ELambda` lowering) always pairs
`cctx.lambdaCaptureNames.add(lambdaKey, caps)` with
`cctx.lambdaClosureClasses.add(lambdaKey, closureClass)` in one
`if caps.count > 0 { ... }` block — there is no other site that populates
`lambdaCaptureNames` without also populating `lambdaClosureClasses`. Every
downstream read of `fctx.captureNameToIndex`/`__caps` (populated only when
`hasCaps` is true, itself derived from `lambdaCaptureNames`) is therefore
guaranteed to see `fctx.types["__caps"] = MClass(...)`, never the legacy
`MArray(elemTy = MObject)`. Confirmed unreachable; the construction site
(closure instantiation) already asserted this with an explicit `panic` before
this change. Removed the dead `object[]`-array behaviour from every mirror
site and replaced it with an explicit invariant-violation `panic`, matching
the construction site's existing convention, so a future regression fails
loudly instead of silently emitting wrong IL:

- `EPath` capture read (the by-reference-cell / typed-field read arm)
- `ESelf` capture read (a lifted lambda reading `self`)
- `emitCellLoadMsil` (shared by hoisted-`var`-cell reads and compound-assign
  writes)
- the closure-instantiation construction site's *parent*-capture read (a
  nested lambda reading an outer lambda's own capture)
- the two `hasCaps` type-definition sites (`fctx.types.add("__caps", ...)`
  and the lifted method's `paramTypes` builder)

No behaviour change for any reachable program; this closes out a
`docs/53`-era workaround that had already been fully superseded.

## JVM backend: no analogous bug

`Jvm.Codegen` always erases a generic-record type parameter to `Object`
(never a reified `!0`/erasure-free representation), so a JVM local's default
(`null`/`0`/`false`) is unconditionally valid IL for the erased `Object` slot
regardless of the instantiation's true type — there is no JVM equivalent of
`pushDefaultValueMsil`'s bug. No fix needed on `--target jvm`.

## Out-of-scope finding: record/impl methods can't build ANY closure that captures a `var` (#7690)

Discovered while investigating this issue's requested test shape (a closure
capturing an uninitialised `var x: T` inside a generic record/impl method).
`lowerRecordMethodMsil` and `lowerImplMethodMsil`
(`lyric-compiler/msil/codegen.l`) never run the by-reference closure-capture
pre-pass (`collectInLambdaNamesBlock`/`Expr` populating
`fctx.hoistedVarNames`) that `lowerFuncMsilScoped` runs for top-level
functions and lifted lambdas. As a result, ANY closure declared inside ANY
record/impl method body (generic or not, capturing a `var` with or without an
initialiser) fails to build today:

```
error[T0120]: MSIL codegen failed: Msil.Codegen: internal error — captured
mutable (`var`) local 'x' was not hoisted to a heap cell (#1479 v2
closure-capture pre-pass missed it). Please report this with a reproducer.
```

Reproduced with a plain (non-generic) record too — confirmed unrelated to
generics:

```lyric
record Plain {
  value: Int
  func compute(): Int {
    var x: Int
    val f = { -> x = self.value }
    f()
    return x
  }
}
```

This is a distinct, broader pre-existing gap (not introduced or widened by
this fix); this issue's report was almost certainly filed against the
ORIGINAL `LBVar`/`None`-arm hoisted-cell-seeding call site
(`lowerStmtMsil`'s `isHoisted` branch), which — per the issue's own hedge —
is reachable today only via a closure inside a top-level function
(`closure_var_capture_self_test.l` already covers that path, and it does not
exercise a real in-bundle `MTypeVar`, since a top-level generic function's
`T` is erased to `object` via `typeExprToMsilBodyCtx`/`typeExprToMsilGenBody`
before reaching that call site). The genuinely-reified-`T` shape this issue
asked about (a record/impl method) cannot build a closure over a captured
`var` at all right now, for reasons unrelated to `pushDefaultValueMsil`. Not
filed as a new issue here per task instructions; flagged for the calling
agent/maintainer to track.

## Tests

`lyric-compiler/lyric/inbundle_generic_method_typevar_default_self_test.l`
(new, dual-target): a generic in-bundle record `Box[T]` with
`alwaysPanic(): T = panic(...)` (the load-bearing case — exercises
`pushDefaultValueMsil`'s `MTypeVar` arm on every call, since the method body
is Never-typed unconditionally) and `getOrPanic(fail): T` (an `if`/`else`
baseline/parity case), each instantiated with `T = Int` (value type), `T =
String` (reference type), and `T = Pair` (an in-bundle record), asserting
runtime values on both `--target dotnet` and `--target jvm`. Wired into
`scripts/ci/compiler-self-tests-batch.sh` (dotnet) and
`scripts/ci/jvm-generics-self-tests-batch.sh` (jvm).

## Validation

- `bash scripts/ci/compiler-self-tests-batch.sh`: 2252 `ok`, 0 `not ok`.
- `bash scripts/ci/jvm-generics-self-tests-batch.sh`: 146 `ok`, 0 `not ok`.
- `bash scripts/ilverify-selfhosted.sh`: 126 DLLs verified, 0 IL-validity
  errors.
- Manual repro (`Box[Int].alwaysPanic()`): before the fix, crashed with
  `System.BadImageFormatException` at JIT time; after, correctly throws the
  `panic` message and `ilverify` reports the DLL clean.

## Files

- `lyric-compiler/msil/codegen.l` — `pushDefaultValueMsil`'s new `MTypeVar`
  arm; dead-`object[]`-fallback removal across the closure-capture read/write
  sites.
- `lyric-compiler/msil/lowering.l` — `buildLocalVarSig` /
  `buildLocalVarSigWithCtx`'s new `MTypeVar`/`MMethodTypeVar` arms.
- `lyric-compiler/lyric/inbundle_generic_method_typevar_default_self_test.l`
  — new dual-target self-test.
- `scripts/ci/compiler-self-tests-batch.sh`,
  `scripts/ci/jvm-generics-self-tests-batch.sh` — wired the new test in.

## Review follow-up (#7692)

`lowerStmtMsil`'s no-initializer `var` arm stored an `int32 0` for any type
it did not special-case; a real type parameter (`MTypeVar`/`MMethodTypeVar`)
now goes through `pushDefaultValueMsil`, which also gained the matching
`MMethodTypeVar` (MVAR) arm. The motivating shape, `var x: T` inside a
generic record method, does not reach that arm yet: the annotation resolves
`T` as a class on both backends (#7695), and that fix adds its test.
