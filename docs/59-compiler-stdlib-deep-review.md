# 59 — Self-Hosted Compiler & Standard Library Deep Review (2026-07)

_Status: Unbacked — audit. See §10 for the prioritized remediation plan; no
decision-log entry yet. Follows the docs/41 (compiler gap analysis) and
docs/57 (stdlib/ecosystem review) audit-doc pattern._

Date: 2026-07-10. Method: seven parallel targeted audits (MSIL backend, JVM
backend, type checker + middle-end, FFI capability matrix, stdlib kernel
boundary, stdlib public API, cross-cutting duplication), each verifying its
claims against the code rather than grep hits, followed by spot verification
of the highest-severity findings. Line numbers reference the tree at commit
`6cc7f19`. This document supersedes nothing; it extends docs/41, docs/44, and
docs/57 with what has changed since and what they missed.

Focus areas, per the review request: types and generics incorrectly lowered
to `object`; missing categories of lowering; inconsistencies; duplicated
logic; optimisations; non-idiomatic usage; stdlib API-surface consolidation;
`@externTarget`-to-modern-FFI migration and the FFI implementation gaps
(statics, properties, …) that block retiring the annotation.

---

## 1. Headline findings

| # | Sev | Area | Finding |
|---|---|---|---|
| H1 | BLOCKER | MSIL | Restored-package interface/record-method MemberRef signatures use the *erasing* encoder while the producer emits *concrete* MethodDef signatures — cross-package `callvirt` on a restored interface method with a record-typed or concrete-collection-typed param/return faults with `MissingMethodException` (§3.1) |
| H2 | BLOCKER | JVM | Match-arm and `for`-loop pattern bindings bypass the #5191 lexical-scope machinery — `case Some(v) ->` silently clobbers a same-named outer `v` (§4.1) |
| H3 | BLOCKER | JVM | `+=` on `String`/`Float` locals emits integer opcodes → `VerifyError`; the same constructs work on MSIL (§4.2) |
| H4 | BLOCKER | JVM | `Byte` has two incompatible in-slot representations (signed vs masked-unsigned) and comparisons never normalize — silently wrong results for values ≥ 128 (§4.3) |
| H5 | BLOCKER | stdlib | Five `_kernel_jvm` files bind phantom `lyric.stdlib.jvm.*` classes that exist nowhere — `Std.Http`, `Std.HttpServer`, `Std.Path`, `Std.Format`, and partially `Std.Regex` are non-functional on `--target jvm` (§7.2) |
| H6 | BLOCKER | stdlib | `Std.Log.log()` panics on any call with a non-empty `fields` slice — `escapeLogValue` calls `substring(i, i + 1)` where the second argument is a *count* (`log.l:58`) (§8.1) |
| H7 | BLOCKER | stdlib | `Std.Task.scopeSpawn` on `--target dotnet` never executes the spawned closure (documented in-file, `_kernel/task.l:57-68`, no tracking issue) (§7.3) |
| H8 | CRITICAL | tests | ~224 numbered backend self-tests (`jvm/self_test_b1..b134`, `msil/msil_self_test_m1..m84`) — ~40k lines — are wired to **no runner**: their F# Expecto host was deleted and no CI job replaced it (§9.5) |
| H9 | HIGH | FFI | The single biggest gap blocking `@externTarget` retirement is **property access** (~24% of kernel externs), then value-type receivers, async/Task unwrap, and out/ref params; ~50-55% of kernel externs are migratable today but seed-blocked inside the stdlib by #5167 (§6) |
| H10 | HIGH | middle-end | The checker's resolved output is consumed only as a diagnostic gate; mono and both codegens re-infer types from raw AST, so the project maintains four independent type systems whose disagreements produce most silent miscompiles below (§5) |

> **Remediation status (2026-07-10, D-progress-638/639):** H1, H2 (both
> backends — MSIL had the same hole), H3, H4 (canonical masked-unsigned
> `Byte`, both backends), and H6 are **fixed**; the §6.4 item-1 property /
> static-field / literal-const capability **shipped** for MSIL auto-FFI
> (D-progress-638), which also fixed the @ET `Math.PI` literal-const runtime
> break and the `Alias.None` union-case hijack. Also shipped from §10 Bands
> 1–2: `out Byte` sign-extension, inline `TRefined` truncation, MSIL by-name
> fallback diagnostics (incl. the `MLdfldGeneric` silent skip), JVM
> `invokeinterface` dispatch, JVM cross-package `pub val` resolution +
> fallback panics, `println(char)` parity, and the §3.5 dead-code removals.
> H5, H7, H9 (remaining capabilities), and H10 remain open; H8 is fixed
> (the numbered corpus is CI-gated).
>
> **Wave 2 (2026-07-10, D-progress-640/641/642):** H5 is now **mostly fixed**
> — `Std.Format`, `Std.Path`, `Std.Regex`, `Std.Math` and the exception
> helper have real JVM kernels (`_kernel_jvm/http_host.l` and
> `http_server.l` remain the only phantom bindings, tracked in #2663); two
> compiler prerequisites landed en route (the auto-FFI class reader skipped
> `ACC_ENUM` class files; opaque-type fields ignored extern-alias seeds).
> §6.4 item 2 **shipped** (value-type instance receivers, value-type
> `.new()` / Q48-004, extern-struct boxing per §3.2 F6 — `inout` struct
> receivers and value-type property *set* remain); #5196's second half
> (mono never received stdlib non-generic signatures; the unresolved-call
> fallback silently emits no call) is fixed. §5.2 B2/B3/B5 shipped (real
> where-bound check + M0001, M0002 dangling-dropped-generic diagnostic —
> the pre-fix behavior was a proven identity-pass-through silent
> miscompile — and M0003 budget diagnostic). §5.4 corrections: the JVM
> *user* single-file path already fed type decls and already cfg-erased
> (only legacy `compileToJar` had the holes — both fixed); native's
> "every stdlib generic stays erased" claim was wrong (native instantiates
> whole-bundle at lowering; its mono now gets iface/record decls);
> `injectWeaveImports` asymmetry is intentional and now documented (probe
> evidence: `call.elapsed` aspects work without `import Std.Time` on both
> targets). §9.3's dead protocol bridges and §7.5's dead .NET kernel
> surface are deleted; `Std.Collections.listContains` shipped (§9.4 root
> cause); one §9.4 correction — `jvm/fuzzer.l` is *alive* (self_test_b8
> is CI-wired since #5515).
>
> **Wave 3 (2026-07-11, D-progress-643/644/645):** the `@externTarget`
> retirement has begun in earnest — 11 kernel files migrated, `_kernel/`
> down from 277 to 172 declarations (§7.1's zero-adoption finding is
> obsolete); #5167 refuted (the v0.4.22 seed compiles arg-bearing
> `.new()` in the stdlib). §6.4 item 3 shipped (auto-FFI Task/Task<T>
> unwrap in `async func` bodies) and the `slice[T]`-argument gap closed;
> §6.4 item 6's JVM half shipped (lambda→SAM bridging at auto-FFI
> boundaries — the #2663 http-kernel prerequisite). New blocker classes
> found: inherited instance members don't resolve; unresolved instance
> auto-FFI defers to a runtime throw instead of a compile panic.
>
> **Wave 4 (2026-07-11, D-progress-647/648/649/650):** **H5 is fully
> closed** — Std.Http and Std.HttpServer have real JVM kernels; zero
> phantom `_kernel_jvm` bindings remain. §9.2's bridge triplication is
> consolidated into `Lyric.Pipeline` (sha256-identical outputs on all
> three targets; net −300 lines; pass order single-sourced). #5560 and
> #5561 (async FFI correctness) are fixed with the missing HTTP
> round-trip CI coverage added. §5.1 A2 shipped (lambda params typed
> from expected function types).
>
> **Wave 5 (2026-07-11, D-progress-651–657):** kernel migration tranche 2
> — `_kernel/` down from 170 to 69 `@externTarget` (value-type receivers,
> slice args, ctors, statics; the residuals each carry a "stays" note;
> §6.4's `Encoding.GetBytes` / `Stream.Write` staleness corrected — both
> resolve). §5.1 **A4 and A5 shipped** (method-call checking with a
> `SymbolTable` method-signature space + **T0113** unknown-member
> diagnostics scoped to member-complete local types; **T0114** rejects
> body-less non-Unit functions, #5603). §6.4's instance-resolution
> failure mode is fixed twice over: unresolved instance auto-FFI **fails
> the build** (#5562) and inherited members resolve via a metadata
> Extends-chain walk (the `process_host.l` residual is retired);
> `HttpResponse.header` works for the first time (#5568, kernel reworked
> off the generic-out-param shape). MSIL async interface dispatch is
> fixed (#5566: a mono `self`-key crash plus explicit-`self` encoded as a
> real IL param) and stdlib interfaces get method MemberRefs (#5564 — the
> whole `Std.Http` async client surface threw before). JVM: scope-body
> Throwables propagate instead of hanging (#5569); erased `slice[prim]`
> payloads bind precisely (#5570); the §4.6-family try/catch
> `slice[Byte]` VerifyError and a *parser* postfix-`(`-across-newline
> mis-parse (#5572) are fixed. `--features` propagates to
> workspace-dependency and single-file builds with swap-only target
> normalization (#5571 — unblocks `lyric-auth` / `lyric-web` JVM builds,
> CI-gated). New blocker found and reverted in-wave: auto-FFI overload
> scoring is exact-arity, so trailing-optional-param BCL methods
> (`JsonEncodedText.Encode`) stay `@externTarget` (Q-MD-004 family).
>
> **Wave 6 (2026-07-12, D-progress-658–662):** the #5604 stdlib-suite
> breakage bisects to *standing* dotnet defects (never CI-run; #5578
> exonerated) and is root-fixed four ways — headline: **the silent
> generic-call drop** (mono inference gaps let codegen drop unresolved
> calls without a diagnostic; also the #5612 mechanism) — with all five
> suites CI-wired. §6.4's overload-scoring rows close (#5605:
> trailing-optional defaults + Extends-chain subtype args; kernel
> un-reverts stay seed-gated). The §3 async-SM operand-stack class
> closes via a new shared `Lyric.AwaitHoist` middle-end pass (#5606),
> and the Phase-A pre-scan gains a typed environment — fixing the
> release-blocking lyric-docker build crash the intact publish logs
> confirmed from CI. JVM: explicit-self interface descriptors (#5607),
> **fatal type-error gating parity with dotnet** (#5609 — jvm builds no
> longer "succeed" with type errors), `[B`-into-field coercion, and
> cross-package enum types. Ecosystem publishing's five-release failure
> streak root-caused from the first intact logs: the publish job lacked
> Java 21 for the Maven resolver (fixed, with warm-up and tier fixes,
> D-progress-662).

---

## 2. Scope inventory

- `lyric-compiler/msil/`: `codegen.l` 28,131 lines (single file, 418 functions),
  `lowering.l` 5,469, plus `ffi.l`, `metadata_reader.l`, `assembler.l`,
  `tables.l`, `heaps.l`, `pe.l`, `bridge.l`.
- `lyric-compiler/jvm/`: `lowering.l`, `codegen/01..06_*.l` (~14,700 lines,
  six files), `bytecode.l`, `classfile.l`, `auto_ffi.l`, `bridge.l`.
- `lyric-compiler/lyric/`: `type_checker/` (9 files), `mono.l`, `propagate.l`,
  `alias_rewriter.l`, `llvm_bridge.l`, `cli/` (20 files).
- `lyric-stdlib/std/`: 40 public modules; `_kernel/` 340 extern declarations
  (277 `@externTarget` + 63 `extern type`), `_kernel_jvm/` 134,
  `_kernel_native/` 80 — combined 554 vs Decision F's v1.0 cap of 150, whose
  enforcement test was deleted with the F# purge (§7.4).

Findings from docs/41 and docs/44 that this review re-verified as **fixed**
and does not repeat: the pipeline disconnect in its original form (both
bridges now run the full middle-end: wire-expand → alias-rewrite → stubbable
→ typecheck → modecheck → elaborate → propagate → derive → mono → weave);
JVM aspects weaving, `@cfg` erasure, `?`-propagation; JVM `Float` → real
`float`; MSIL single-file type-check gating (`msil/bridge.l:145-148`).

---

## 3. MSIL backend: silent miscompiles and lossy lowering

### 3.1 BLOCKER — Restored interface/record-method signatures use the erasing encoder

`registerRestoredIfaceMethod` (`msil/codegen.l:26923`) and
`registerRestoredRecordMethod` (`:26842`) resolve parameter/return types with
the context-aware `typeExprToMsilCtx` but then encode the MemberRef blob with
the context-**free** `buildInstanceMethodSig`, whose `bufMsilType` erases
`MClass` → `ELEMENT_TYPE_OBJECT` (`lowering.l:270`) and
`MConcreteList`/`MConcreteMap`/`MGenericInstByName` → `0x1C`
(`lowering.l:326-331`). The producer side emits interface MethodDefs with the
context-aware `buildInstanceMethodSigWithCtx` (`lowering.l:3619/3640`; record
methods `:2771`), i.e. `CLASS + TypeDef` and closed `GENERICINST`. The
justifying comment (`codegen.l:26909-26915`) still claims the producer uses
"the *legacy* `typeExprToMsil`, which erases every generic / class / slice
type to `object` … (#1602)" — that was true of the F# emitter era and is
false today. CLR MemberRef resolution requires a byte-match: any
cross-package `callvirt` on a restored interface/record method whose
signature mentions a user record or concrete collection faults at runtime
with `MissingMethodException`. The sibling paths `registerRestoredFunc`
(`:26421`) and `registerStdlibFunc` (`:28103`) already use the ctx-aware
builder. Fix: switch both call sites to
`buildInstanceMethodSigWithCtx(..., cctx.lctx)`, delete the stale comment,
and add a cross-package restored-interface runtime test with a record-typed
parameter (none exists, which is why this is latent).

### 3.2 MAJOR correctness findings

- **Inline refined types always lower to `MInt`** (`codegen.l:5075`, dup
  `:5130`): `case TRefined(_, _) -> MInt` truncates `Long`/`Double` bases —
  the reference explicitly allows `type Cents = Long range 0 ..= 1_000_000_000_00`
  (`docs/01:166`); named range types correctly carry `inner: MsilType`
  (`MRangeType`, `lowering.l:879-885`). The JVM twin has the same bug
  (`jvm/codegen/01_types.l:840`, §4.5).
- **`Float` silently lowered to R8** (`codegen.l:4826-4827`) while the spec
  defines it as 32-bit and the JVM backend maps `JFloat` — the same program
  computes in different precisions per target. This is the MSIL sibling of
  the docs/44 JVM finding that was fixed on JVM only.
- **`inout`/`out Byte` read with `ldind.i1`** (`lowering.l:212-222`) —
  sign-extends although `Byte` is unsigned; array reads correctly use
  `ldelem.u1` (`codegen.l:5319`). `0xFF` reads back as `-1`. One-line fix:
  `emitLdind_U1` (exists, `opcodes.l:1147`).
- **`println(char)` prints the integer code** (`codegen.l:10549` routes
  `MChar` to `tokWriteLineInt`) vs the glyph on JVM
  (`jvm/codegen/04_calls.l:3128`) — and MSIL is internally inconsistent:
  interpolation `"${c}"` boxes and `ToString()`s, printing the glyph.
- **Extern-struct values (`MValueTypeRef`) are never boxed into object
  contexts**: `isValueType` (`codegen.l:5139-5149`) covers only the six
  primitives although `boxTypeRef` supports `MValueTypeRef` (`:5276`). `==`
  on two `Uuid`s falls back to `Object.Equals(object, object)` with two
  *unboxed* structs on the stack (`:7460-7464`) — invalid IL
  (`InvalidProgramException`); interpolation of a struct extern
  (`:10205-10207`) is the same class; `castObjectToMsil` silently no-ops for
  `MValueTypeRef` (`:5332-5347`), the inverse hazard.
- **Scalar `Byte` has a different ABI than `Byte` collection elements**:
  bare `Byte` → `MInt`/I4 (`codegen.l:4834-4835`), but `slice[Byte]`/`List[Byte]`
  elements → `MByte`/U1 (`sliceElemMsilCtx`, `:4699-4704`). Metadata-visible
  to .NET consumers, and `argTyToSig` scores a scalar `Byte` argument as
  int32 (`0x08`), so the auto-FFI overload scorer can never match a BCL
  `byte` parameter. JVM scalar `Byte` is a third representation (signed
  8-bit). Needs one decision (U1 matches docs and element paths) applied to
  `typeExprToMsilCtx`, arithmetic masking, and `argTyToSig`.
- **Locale-sensitive interpolation and `println(Double)`**: `toString(Double)`
  is pinned to InvariantCulture (#2462, `codegen.l:10620-10628`), but
  interpolation boxes and calls `Object.ToString()` (`:10194-10196`) and
  `println` uses `Console.WriteLine(double)` (`:10547`) — both
  current-culture. Under `de-DE` the same value renders `"3.14"` and
  `"3,14"` in the same program.

### 3.3 MAJOR — Missing/degraded lowering categories

- **Silent `System.Object` fallbacks in by-name token resolution**
  (`lowerMInsn`, `lowering.l:1903`): unresolved `MIsinstByName` emits
  `isinst System.Object` — which **always matches**, so a guarded pattern
  arm unconditionally fires (`:2007-2029`; W0003 goes to stdout, violating
  the #4703 stderr convention); `MCastclassByName` (`:1992-2005`) and the
  generic variants (`:2061`, `:2093`) fall back to `Object` with **no**
  diagnostic; worst, `MLdfldGeneric` with an unresolved token emits **no
  instruction at all** (`:2130-2135`) — stack imbalance surfacing as an
  `InvalidProgramException` far from the cause. All five are
  compiler-invariant violations and should panic with the type name.
- **Collections of extern structs and tuples erase to bare `object`**:
  the `List[T]` mapping residue after `collElemConcrete` (`codegen.l:4926-4932`,
  `:5361-5384`) is exactly `MValueTypeRef` and `MTuple` — so `List[Uuid]`,
  `List[Instant]`, `List[(Int, String)]` lose even the `MListOf`
  element-tracking wrapper while `slice[Uuid]` works (`MArray(MValueTypeRef)`,
  `:5017`). The `else if isValueType` branch at `:4928-4929` is dead (its
  cases all joined `collElemConcrete`) and its comment documents a
  superseded design.
- MINOR: `UInt`/`ULong`/`Nat` fall through to `MClass("<pkg>.UInt")` and get
  erased to `object` downstream (`codegen.l:4820-4839` has no arms; the
  checker models them as primitives, `typechecker_types.l:94-96`) — should
  be an explicit "unsupported on this backend" diagnostic. `SItem` (nested
  item declarations) is silently dropped with a surviving "(skip in
  bootstrap)" comment (`codegen.l:13668-13670`).

### 3.4 Performance

- **O(N²) method-body re-serialization**: `methodBodyRvas(ctx.bodies)`
  serializes *every accumulated body* on each call
  (`assembler.l:326-347`) and is called at ~20 sites in `lowering.l`,
  including inside per-method loops (`lowerMRecord`, `lowering.l:2763-2768`;
  also 2687, 2741, 2852, 2881, 2969, 2998, 3091, 3440, 4574, 4601, 4665,
  4756, 4778, 4837, 4926, 4948, 5060, 5087, 5324). The interface path was
  already fixed for exactly this (`lowering.l:3587-3592`) — the fix was
  never propagated. `isFatBody` also copies the entire serialized body to
  read byte 0 (`assembler.l:308-315`).
- **`findTypeRefRowByName` is an unmemoized linear scan** of the TypeRef
  table plus a 9-iteration arity probe (`lowering.l:3774-3832`), called from
  every `MClass`/`MConcreteList`/`MConcreteMap`/`MGenericInstByName` encode
  — O(refs × uses), the dominant lowering cost on stdlib-sized modules.
  `findTypeDefRowByName` already has the `typeDefRowByFqn` fast path
  (`:3685`); mirror it. The function also mutates state (mints `Func`/`Action`
  TypeRefs, `:3826-3830`) despite the "find" name.
- MINOR: interpolation folds N segments through N−1 `String.Concat(string,string)`
  calls (`codegen.l:10181-10219`) — O(total²); `tokConcat3` is minted into
  every emitted assembly (`:689-698`) and has zero call sites. 261
  `containsKey`-then-`mapGet` double lookups.

### 3.5 Inconsistencies and dead code

- The erasing vs ctx-aware signature-builder split (§3.1) is systemic: both
  are `pub` and the choice is per-call-site, guarded only by comments. Make
  the erasing builders non-`pub`, reserved for genuinely context-free blobs.
- Two incompatible MsilType fingerprint encoders: `msilTypeKey`
  (`lowering.l:1586-1651`, bracketed grammar) vs `msilTypeKeyStr`
  (`codegen.l:14970-15032`, underscore-joined, no arg-count/terminator —
  `gi_A_cls_B_i4` is ambiguous for underscore-bearing names like
  `Option_Some`), and the latter feeds `ffiMemberRefSigKey`
  (`:23804-23828`), the same intern-collision class as #1442/#3943. Unify
  on `msilTypeKey`. Similarly duplicated: `elementTypeByte`
  (`lowering.l:177`) vs `msilToElemByte` (`codegen.l:23517`).
- Dead: `typeExprToMsil` + `sliceElemMsil` (`codegen.l:5086-5135`,
  `:4706-4711`) — zero external callers, still mapping `TGenericApp`/`TFunction`
  → `MObject`, and cited by §3.1's stale comment as load-bearing;
  `valueTupleMsilCtx` (`:4794-4811`); `tokConcat3`. The `lowering.l:15-28`
  header still claims "Not covered: Generics, async, protected types, wire
  blocks, aspects, FFI, exception handling" — all now implemented.

---

## 4. JVM backend: silent miscompiles and lossy lowering

### 4.1 BLOCKER — Pattern bindings bypass the lexical-scope machinery

The D-progress-603 (#5191) shadowing fix brackets **blocks** with
`enterBlockScope`/`exitBlockScope` (three call sites:
`codegen/02_exprs.l:1835`, `05_stmts.l:1439`, `:1698`). Match arms are not
blocks: `lowerMatchExpr` (`03_match.l:135-252`) calls `lowerPatternBind` per
arm with no scope bracket, and pattern bindings allocate slots directly
(`bindCaseField` `03_match.l:946`, `PBinding` `:1024`). `allocSlot`'s reuse
rule (`01_types.l:568`) reuses an existing slot whenever the prior binding is
in the current enclosing block with the same frame type — so
`val v = 1; … match o { case Some(v) -> … }` writes the payload into the
outer `v`'s slot; even with differing frame types the name→slot remap is
only undone at the enclosing block's exit. `block_shadow_self_test.l:87-97`
only covers a `val` declared inside the arm's *body block*, so the hole is
untested. Same pattern: `emitCountingForJvm`'s loop-variable bind
(`05_stmts.l:722`) and `POr` re-binds (`03_match.l:1147-1164`). Fix: bracket
each arm (bind + guard + body) and the `for` bind with scope enter/exit; add
pattern-binding-shadow cases to the self-test; audit the MSIL match path for
the same hole.

### 4.2 BLOCKER — Compound assignment on `String`/`Float` locals miscompiles

The local-variable compound path (`05_stmts.l:232-240`) and the hoisted-cell
path (`:105-208`) only special-case `JLong`/`JDouble` and fall to `LIadd` —
`var f: Float = 1.0f; f += 0.5f` → `fload; …; iadd` → `VerifyError`;
`s += "b"` → `iadd` on refs → `VerifyError`. The type checker accepts both
(it ignores the assign op, `typechecker_exprs.l:3162`) and MSIL supports
both (`emitCompoundCombineMsil` has an explicit `String.Concat` arm,
`msil/codegen.l:4321-4337`). The shared helper `emitCompoundArith`
(`05_stmts.l:649-653`) **has** the `JFloat` arms but only the field/index
paths call it. Additionally, the plain `=` arm coerces the RHS
(`coerceArgTo`, `:216-224`) but no compound arm does, so
`case Some(n) -> total += n` on an erased payload leaves an `Object` under
`iadd`. Fix: route all three paths through `emitCompoundArith`, add the
`String`/`AssPlus` concat arm, coerce compound RHS, and extend
`silent_miscompile_guard_jvm_self_test.l`.

### 4.3 BLOCKER — Dual `Byte` representations, unmasked comparisons

The documented canonical form is "signed in slot, masked at widening"
(`03_match.l:828-837`, D-progress-566; `LBoxByte` narrows with `i2b`,
`lowering.l:868-880`) — but `.toByte()` produces the **unsigned** form
(`04_calls.l:2757-2760`, `& 255`), while unboxing and `baload` produce the
**signed** form (`coerceArgTo`, `:1610-1619`). Comparisons never mask either
side (`lowerCmp`, `02_exprs.l:158-169`; `reconcileCmpOperands`,
`:1348-1355`): `val b = 200.toByte(); xs[0] == b` compares `-56 == 200` →
false; `b1 < b2` is signed where MSIL is unsigned; compound `b *= 2` mints a
third (out-of-range) form. Fix: pick masked-unsigned as canonical (matches
MSIL `conv.u1`), normalize every producer, mask both operands of `JByte`
comparisons, and add ≥128 round-trip self-tests.

### 4.4 BLOCKER — Silent wrong-value fallbacks under an advisory type gate

The JVM bridge deliberately does not gate on type errors ("advisory",
`bridge.l:344-349`, `:412-415`), yet codegen has arms that produce a wrong
value instead of failing:

- **Unknown path reference → `aconst_null`** (`02_exprs.l:352-356`).
  Reachable in *well-typed* code: a cross-package `pub val` reference —
  `moduleVals` is built only from the file being lowered
  (`06_items.l:3586`) and the read hardcodes `owner = ctx.pkgName`
  (`02_exprs.l:349`). The store side was converted to panics in
  D-progress-543 (m-23); the load side was not.
- **Unknown member on a known/erased receiver → the receiver itself becomes
  the "field value"** (`02_exprs.l:955-962`) — the exact bug shape the
  `.count` intrinsic comment records having already caused once
  (`:878-885`). Any instance-field read on an extern JDK object hits this
  (JVM auto-FFI resolves only *static* fields, `:824`).
- **Member on an array/primitive receiver → `JVoid` with the receiver left
  on the stack** (`:978-985`); **primitive-receiver method-call fallback
  emits no instruction** after lowering receiver+args (`04_calls.l:3114-3116`).

Fix: convert all four to source-located panics (m-23 precedent) and register
imported packages' `pub val`s in `moduleVals` with their owning class.

### 4.5 MAJOR

- **Branch offsets silently truncate beyond ±32 KB**: `BranchInsn` writes
  the signed delta via `writerU2` which masks to 16 bits
  (`bytecode.l:766-773`, `_kernel/kernel.l:69-72`); `GotoW` exists
  (`bytecode.l:775`) but is never selected; no 64 KB method-size guard.
  Large woven/monomorphized functions plus the full-frame StackMapTable
  strategy make the threshold reachable. Cheap first step: range-check the
  delta and panic with the method name.
- **Lambda ABI is still uniform `invoke(Object[])Object`**
  (`02_exprs.l:2635-2845`): every call allocates an args array and boxes all
  primitives in/out. Captures are typed fields (that half of D113 landed),
  but docs/52/53's "MSIL + JVM parity" claim is overstated — the parity
  verified by `closure_zero_overhead_self_test.l` is semantic, not the
  zero-overhead ABI. Either synthesize per-shape typed `invoke` overloads or
  correct docs/52/53/44.
- **Auto-FFI re-reads and re-parses whole JMOD/JAR archives per
  cache-missing lookup** (`auto_ffi.l:190` documents it; `:224-241`); a miss
  on `java.base.jmod` then reads every other `.jmod` (`:261-275`), and the
  `$`-inner-class retry repeats the sweep per dot segment (`:332-356`).
  `lowerMethodCall` probes `loadClass` for every instance call on a `JRef`
  receiver (`04_calls.l:3021-3030`), so each distinct user class name costs
  one full-JDK scan before landing in `missKeys`. Cache archive bytes and
  parsed central directories per path.
- **Imprecise subscript receivers**: reads force-`checkcast` to `ArrayList`
  (`02_exprs.l:1213-1223` — CCE for erased Map payloads); writes emit
  `ArrayList.set` with **no cast at all** (`05_stmts.l:434-508`). Mirror the
  `__lyricCount` runtime-dispatch approach.
- **Default-argument expressions are lowered in the caller's context**
  (`reorderAndFillJvmArgs`, `04_calls.l:554-628`): a default referencing the
  callee's scope resolves against caller slots or hits the null fallback;
  only literal defaults are safe. Restrict to literals + panic, or
  synthesize callee-side filling thunks.
- **Unqualified cross-package call resolution is first-registration-wins**
  for same-name/same-arity functions (`collectFileSigsSeeded`,
  `06_items.l:2542-2559`; the `JvmFuncSig` doc comment at `01_types.l:38-39`
  even claims the opposite). Detect bare-key collisions among a file's
  imports and require qualification, as MSIL does.

### 4.6 MINOR

`trim` → Java `strip()` diverges from .NET `Trim()` on NBSP (untracked
sibling of #4688); `TRefined` → `JInt` always (`01_types.l:840`, Long-based
range subtypes mis-slotted — same bug as MSIL §3.2); `TArray(_, _)` → bare
`Object` (`:839`); `slice[T]` erases to `Object[]` with per-element box/copy
loops at FFI boundaries (`:818`, `04_calls.l:1130+`) where MSIL uses
`byte[]`; relational compare of two erased operands panics
(`02_exprs.l:154`); `EPath` resolution ignores qualifiers (`:283`,
`Foo.bar` with a local `bar` loads the local); erased `==` via
`Objects.equals` makes boxed `Integer 5` ≠ `Long 5` (cross-width divergence
from MSIL); intra-backend duplication where two of three compound-arith
opcode tables lack the `JFloat` arms (the direct cause of §4.2), plus
`jvmTypeToDescStr` = `typeDescriptor`, `storeInsn/loadInsn/returnInsn` =
`emitStore/emitLoad/emitReturn`, three array-element dispatch copies, two
`newarray` tables.

---

## 5. Type checker and middle-end

The structural finding: the checker's `CheckResult.symbols`/`sigs`
(`typechecker_checker.l:1753`) are discarded — bridges consume only
`.diagnostics` (`msil/bridge.l:144-148`; same on JVM) — and mono and both
codegens re-derive types from raw AST. Four independent type systems
(checker `Type`, mono `TypeExpr`, `MsilType`, `JvmType`) is the root cause
of most silent-miscompile classes in §3/§4. docs/41 C2's "RESOLVED —
remaining TyError forms now covered" overstates; the following are live.

### 5.1 `TyError` degradation (catch-all: `typechecker_types.l:72`; wildcard equivalence `:176-188`)

- **A1 MAJOR** — `for`-loop variables over ranges, `List`, and `Map` are
  untyped: `ERange → TyError` (`typechecker_exprs.l:3181`); `SFor` element
  typing handles only `TySlice`/`TyArray`/`MapKeyCollection`-style receivers
  (`typechecker_stmts.l:195-211`) — loop bodies over the two most common
  forms are unchecked.
- **A2 MAJOR** — Unannotated lambda params are `TyError` even when the call
  context fully determines them (`exprs.l:3033`); no bidirectional checking.
  MSIL codegen implements HOF propagation independently (MSIL-only, #1470)
  — the checker knows less than one backend, and JVM less than both.
- **A3 MAJOR** — Generic record field access loses instantiation:
  `inferMember` ignores the receiver's type args (`exprs.l:1251-1263`) and
  `extractRecordFields` resolves field types under an empty generic context
  with a swallowed diagnostic (`:1092-1107`) — `box.value` on `Box[Int]` is
  `TyError`. The union path does this correctly
  (`caseFieldTypesInstantiated`, `:2473-2480`); mirror it.
- **A4 MAJOR** — All method-style calls on user types are unchecked:
  `findDirectSig` handles only `EPath` callees (`exprs.l:3325`), so
  `x.method(args)` types as `TyError` with no arity/argument validation.
  `builtinMember` (`:910-975`) covers a tiny surface (no Map members, no
  String `substring`, …). The single largest unchecked surface.
- **A5 MAJOR** — Unknown members produce no diagnostic (`:1263`, `:1269`);
  multi-segment value paths are silently `TyError` (`:1286-1288`). A typo'd
  field name passes the checker.
- **A6 MAJOR** — Overload selection with `TyError`-degraded arguments
  matches every candidate (first registered wins) via `typeEquiv`'s
  wildcard semantics (`:3193-3205`); one upstream degradation flips
  downstream typing wholesale.
- MINOR: imported-signature resolution failures swallowed
  (`checker.l:1683-1710`); missing-return undetectable (#3362,
  `exprs.l:1225-1227`, `stmts.l:724`); dead `ETry → TyError` leniency
  (`exprs.l:3111`).

### 5.2 Monomorphizer (mono.l — operates on syntax, pre-resolution)

- **B1 MAJOR** — Unspecializable call sites silently fall back to erased
  generics that can crash at runtime — `mono_self_test.l:377-410` documents
  the `isinst Result_Err<object,object>` "Unable to cast" failure. Needs a
  compile-time diagnostic for crash-prone erased fallbacks.
- **B2 MAJOR** — Same-package generic `IFunc`s are dropped from the output
  file (`mono.l:2744-2761`) while the rewriter's failure mode leaves call
  sites referencing the generic name (`:2103`, `:2155`) — a dangling
  reference at codegen with no mono diagnostic.
- **B3 MAJOR** — `satisfiesMarker` is constant-`true` (`mono.l:1921-1941`;
  the doc comment claims otherwise), making the M0001 where-bound
  diagnostic unreachable. Small, real, dead-diagnostic bug.
- **B4 MAJOR** — Mono's binop inference ignores numeric widening the checker
  performs: `a + b` typed as lhs (`mono.l:955-961`) vs the checker's
  `Int + Long → Long` (`exprs.l:616-618`) → specialization `foo__Int` whose
  parameter type disagrees with the runtime value.
- Other verified gaps: `EMember`-receiver generic calls never specialize
  (`:2217`); decl maps keyed by simple name, first-in-wins with an arity
  heuristic (`:2115-2125`); the 10,000-spec budget **panics** rather than
  diagnosing (`:2884-2892`); mono invents type names (`I16 → "Short"`,
  `:915-920`) that no other pass recognizes; mangled-name keying is
  syntactic (aliased vs direct spellings duplicate specializations, and
  `extractBaseName` mis-splits user names containing `__`). Specialized
  bodies are never re-type-checked.

### 5.3 Inconsistencies

- Qualified type paths resolve by **last segment only**
  (`typechecker_resolver.l:338-357`) — `Foo.Bar.Baz` binds whatever `Baz` is
  scope-closest; the qualifier is never validated.
- Three compatibility relations (`typeEquiv` / `argSatisfiesParam` /
  `typeAssignable`) applied inconsistently by position: returns use
  `typeAssignable` (`stmts.l:144`, `:724`), `val`/`var` initialisers use
  `argSatisfiesParam` (`:118`, `:123`) — `Ok(x)` is accepted as
  `Result[Conn, E]` when returned (#2514) but rejected when assigned.
- Alias transparency differs per pass: the resolver follows aliases (64-hop
  bound), `propagate.l` unfolds same-file aliases only (`:191-193` —
  imported Result-aliases misclassify, spurious F0020), mono never unfolds
  (feeding B1).
- Constraint vocabularies disagree: checker
  {Add,Sub,Mul,Div,Mod,Compare,Hash,Equals,Default} (`checker.l:509-514`) vs
  mono {Equals,Hash,Show,Ord,Compare} (`mono.l:1910-1912`).
- MINOR: `"a" + x` returns `String` without checking the RHS
  (`exprs.l:601-606`); container builtins matched by string name rather than
  TypeId (vs the #2303 TypeId fix for interfaces).

### 5.4 Pipeline ordering per target (verified from the bridges)

| Pass | MSIL single-file | MSIL project | JVM single-file | JVM project | Native |
|---|---|---|---|---|---|
| cfg erasure | **absent** | yes | **absent** | yes | yes |
| WireExpand | yes | yes | yes | yes | **absent** |
| alias-rewrite / stubbable | yes | yes | yes | yes | alias only, **stubbable absent** |
| injectWeaveImports | **absent** | **absent** | yes | yes | absent |
| typecheck…derive | yes | yes | yes | yes | yes |
| mono variant | `…AndTypeDecls` | `…AndTypeDecls` | **`WithImports` only** | `…AndTypeDecls` | **bare `monoFile`** |
| weave | yes | yes | yes | yes | yes |

- MAJOR: JVM single-file mono is fed no interface/record decls
  (`jvm/bridge.l:211`) — the #3705/#3813 anti-crash specializations are
  missing on JVM single-file builds only.
- MAJOR: native mono runs bare `monoFile` (`llvm_bridge.l:437`) — every
  cross-package/stdlib generic call stays erased on native; native also
  skips WireExpand and Stubbable silently (no diagnostic).
- MINOR: cfg erasure never runs on single-file builds on either managed
  target — `@cfg(feature=…)` items compile unconditionally in
  `lyric build foo.l` but are erased in manifest builds; same source,
  divergent semantics. `injectWeaveImports` is JVM-only — the asymmetry
  itself is the bug.
- Post-typecheck transforms are never re-checked; the weaver already
  re-runs contract elaboration itself (D118, `weaver.l:832-872`) — evidence
  the ordering forces per-pass workarounds. Whether aspect `matches:`
  patterns are expected to match post-mono mangled names (`foo__Int`) is
  unspecified; worth a decision-log note.

### 5.5 Structural

`typechecker_exprs.l` is 3,401 lines with a monolithic `inferExpr`, and
several load-bearing arms are single physical lines (the entire `SLocal`
logic is one ~2,400-char line, `stmts.l:118`) — unreviewable and giving
diagnostics no distinct line numbers. Stringly-typed structures throughout
(sigs keyed `"name/arity@i"`, side indexes keyed `toString(TypeId.id)`,
alias entries `"alias=pkg"` parsed by scanning for `=`).
`alias_rewriter.l` self-describes as "Bootstrap-grade" and is scope-blind
(`:4`, `:27-34`). `foldArith` has no overflow detection despite `FEOverflow`
existing (`typechecker_constfold.l:77-98`).

---

## 6. FFI: capability matrix and the `@externTarget` retirement backlog

### 6.1 How the two mechanisms differ

`@externTarget` is not a thin legacy alias. The MSIL `emitExternTargetBody`
(`msil/codegen.l:15527`, resolver `msil/ffi.l:200`) layers, on top of the
plain call: F0015 signature verification (`:15665-15743`), a property
`get_<M>` probe (`:15745-15780`), static-field `ldsfld` + Int32 const
inlining (`:15782-15814`), generic declaring types via closed GENERICINST
TypeSpec (`emitGenericExternMember`, `:15206`), nested types, byref params
(`MByRef`, `:15598`), async `Task`/`Task<T>` unwrap, nullable-return unwrap,
`Option[T]` null coercion (`:15618-15622`), and D122 typed-delegate params
(`:15576-15597`). The JVM twin (`jvm/codegen/04_calls.l:182`) adds
metadata-derived staticness and `Result[T, JvmException]` auto-wrapping.

The modern path (`extern type` / `import extern` registration →
`emitAutoFfiCallMsil` `codegen.l:24288` → `Mdr.resolveExtern` over
reference-assembly bytes; JVM `lowerAutoFfi*Call` `04_calls.l:1244/1358/1460`
over `Jvm.AutoFfi`) resolves the **literal member name only** from call-site
argument types. Failure paths panic and point the user back to
`@externTarget` (`codegen.l:24347-24362`).

Orthogonal blockers: the type checker is extern-blind — every extern
member/call/`.new()` types as `TyError` and all resolution happens at
codegen (`typechecker_exprs.l:1251-1273`); and the pinned bootstrap seed
predates arg-bearing `.new()` (#5167), so even trivially-migratable externs
cannot migrate *inside* `lyric-stdlib/`/`lyric-compiler/` today.

### 6.2 Capability matrix (modern auto-FFI vs `@externTarget`)

| Capability | MSIL modern | MSIL @ET | JVM modern | JVM @ET |
|---|---|---|---|---|
| Static method call | yes (widening/boxing) | yes + F0015 | yes | yes + F0015-J |
| Instance method (extern-typed value) | ref types only (`codegen.l:12186`); value-type receivers never route | yes (incl. structs) | yes (superclass walk; but `isInterface` never consulted — `invokevirtual` emitted for JDK-interface receivers, `04_calls.l:1447`) | yes |
| Constructor `.new(args)` | ref types only; value types panic (Q48-004); seed-blocked in stdlib (#5167) | yes (`"Type..ctor"`) | yes (+ J005 abstract rejection) | yes (`<init>`) |
| **Properties (get)** | **no** — no `get_` probe anywhere in the auto-FFI path | yes (`:15745-15780`) | no `.name` sugar (getters callable as ordinary methods) | yes |
| **Properties (set)** | **no** | yes (explicit `set_X` targets) | no sugar (callable explicitly) | yes |
| Static fields / consts | **no** (member access on extern type name is `TyError`, no codegen arm) | yes (`ldsfld` + const inlining) | **yes** (`getstatic`, `02_exprs.l:820-837`) — JVM ahead of MSIL | yes |
| Instance fields | no (both) | no | no (parsed but unwired) | static only |
| Generic types/methods | no (generic args → fallback in `argTyToSig`; Q48-001) | yes (GENERICINST TypeSpec, MethodSpec #1497) | erasure only | erasure |
| Overload resolution | exact + widening + box; no `params`, no optional args (Q-MD-004) | same engine | scored widening/IS-A; no varargs | same |
| Arrays/slices | `slice[T]` args → fallback (`argTyToSig` `codegen.l:23769-23795`) | yes | yes both directions | yes |
| out/ref/byref | **no** (no call-site surface) | yes (`MByRef`) | no | partial |
| Async (Task) externs | **no** unwrap/awaitable typing | yes (D085/D091) | n/a (sync by design) | yes |
| Delegates/lambdas | no general form — **D122 is bounded to @ET params**; retiring @ET removes the only delegate bridge | yes (bounded) | **no SAM conversion at all** | no |
| Events | no (all paths, both targets) | no | no | no |
| External interfaces (`impl`) | yes (docs/51 P1–3) | n/a | yes | n/a |
| Extern enum values | no (a static-field read) | yes (const inlining) | yes (`getstatic`) | yes |
| Value types | static args/returns shipped (docs/42 step 3); receivers/`.new()` no | yes incl. `inout` struct receivers | n/a | n/a |
| Indexers | no (`EIndex` on extern → `TyError`) | expressible as `get_Item` | no | explicit method |

### 6.3 Quantified blockage (295 `@externTarget` declarations in `_kernel/`)

| Missing modern capability | Blocked decls | Share |
|---|---|---|
| Property access (get/set + property-named + static fields/consts/enums) | ~70 | ~24% |
| Value-type instance dispatch (incl. `inout` struct receivers) | ~26 | ~9% |
| Async/Task unwrap at auto-FFI sites | ~18 | ~6% |
| out/ref params | ~16 | ~5% |
| Operator methods (`op_*`, no sugar) | 10 | ~3% |
| `slice[T]` args in MSIL `argTyToSig` | ~10 | ~3% |
| Generic declaring types / methods | ~6 | ~2% |
| null→`Option[T]` coercion convention | ~5 | ~2% |
| Ref-type ctors — migratable in principle, seed-blocked (#5167) | ~18 | ~6% |
| **Plain static + ref-type instance methods — migratable today** | **~145–160** | **~50–55%** |

Worst-case files: `json_host.l` ~95% blocked (value-type receivers, `inout`
enumerators, out params, property getters); `time_host.l` ~85% blocked
(properties, static fields, operators, value-type instance methods);
`http_host.l` ~60% blocked (async, property get/set, out params);
`math_host.l` ~90% migratable (3 blocked: `Math.PI/E/Tau` consts).
`collections_host.l` is 0/7 migratable (generic constructors, Q48-001).

Notable path inconsistencies: JVM modern has static-field `getstatic` where
MSIL has nothing; MSIL @ET defaults to static unless `@externInstance` while
JVM derives staticness from metadata; ctor spelling `"Type..ctor"` (MSIL) vs
`"pkg.Class.<init>"` (JVM); `import_extern_self_test.l` **is** wired into CI
(dotnet-only — docs/57's "not wired" claim is stale) but has no JVM leg.

### 6.4 Prioritized capability backlog to retire `@externTarget`

1. **CRITICAL — Property access in auto-FFI**: port the `get_<M>` probe (and
   a `set_<M>` assignment form) from `emitExternTargetBody` into
   `tryAutoFfiFromMetadata`/`tryInstanceAutoFfiFromMetadata`, plus
   member-access (non-call) codegen for extern receivers. Unblocks ~24%.
2. **CRITICAL — Value-type receivers**: `ldloca` + `call` dispatch on
   `MValueTypeRef`, `initobj`-based value-type `.new()` (Q48-004), `inout`
   struct receivers. Unblocks time/json/uuid kernels.
3. **HIGH — Async extern calls**: Task/Task<T> detection + unwrap at auto-FFI
   sites; today the whole `Std.Http` kernel is unmovable.
4. **HIGH — out/ref at call sites + null→`Option` coercion convention**
   (needs a language-surface decision, not just codegen).
5. **HIGH — Ship a `.new(args)`-capable bootstrap seed (#5167)** — without
   it even the migratable ~50% cannot migrate inside the stdlib.
6. **MEDIUM — Generalize D122 delegates beyond @ET params; ship JVM SAM
   conversion** — otherwise retiring @ET removes delegate FFI entirely.
7. **MEDIUM — `slice[T]` args in `argTyToSig`; optional/default args +
   `params` arrays in overload scoring (Q-MD-004)**; static-field access on
   MSIL extern type names (JVM parity); generic-method MethodSpec routing.
8. **LOW — operator sugar, indexers, events, instance fields** (negligible
   kernel usage; events unused entirely).
9. **CROSS-CUTTING — extern typing in the type checker**: replace the
   blanket `TyError` with metadata-informed member typing; prerequisite for
   compile-time diagnostics and for items 3/4/6 (the delegate check today is
   a `System.Func/Action` name-prefix hack, `typechecker_symbols.l:228`).

---

## 7. Stdlib kernel boundary

### 7.1 Migration inventory (277 `@externTarget` in `_kernel/`)

~150 (54%) trivially migratable today, ~41 (15%) with minor rework
(static-property spelled `T.get_X()`, operators as `T.op_X(a,b)`), ~86 (31%)
blocked on the §6.4 capabilities. Adoption of the modern idiom inside the
kernel is effectively zero: no `import extern` statements in any kernel
tree; one `.new()` in `_kernel` (`http_server.l:152`) vs eight in
`_kernel_jvm` (which is outside the .NET bootstrap closure and hence not
seed-blocked). Overload ambiguity is a real migration hazard the matrix
alone doesn't show: `Convert.ToInt32` (~19 overloads), `TextWriter.WriteLine`
(18), `Encoding.GetBytes` (auto-FFI failure documented in-tree at
`http_server.l:252-257`).

### 7.2 BLOCKER — Three-kernel-tree parity breaks

- `Std.Format` is broken on JVM: `std/format.l:33,41,55` calls
  `hostIntToString`/`hostDoubleToString`/`hostInvariantCulture`;
  `_kernel_jvm/format_host.l:15-22` exports an obsolete surface targeting
  the phantom class `lyric.stdlib.jvm.FormatHost`. The loader prefers the
  JVM twin (`lyric-compiler/lyric/emitter.l:352`), so the .NET twin never
  fills the gap.
- `Std.Math.intToLong`/`longToInt` unresolved on JVM (absent from
  `_kernel_jvm/math_host.l`; present in the other two trees).
- Five `_kernel_jvm` files bind phantom `lyric.stdlib.jvm.*` /
  `lyric.runtime.jvm.*` classes that exist nowhere in the repo and in no
  shipped JAR: `http_host.l` (all 20 externs), `http_server.l` (8),
  `format_host.l` (3), `path_host.l` (5), `regex_host.l` (4 of 5), plus
  `_kernel/jvm_exception.l:52`. Failure mode per docs/44 m-89:
  `VerifyError: Operand stack underflow` on first call. **`Std.Http`,
  `Std.HttpServer`, `Std.Path`, `Std.Regex`, `Std.Format` are non-functional
  on `--target jvm` today.** docs/44 remediated ten other modules with the
  pure-Lyric-over-auto-FFI pattern; these are the remainder (`format_host`
  and `path_host` are small and JDK-expressible today).

MAJOR divergences: JVM `delay()` blocks eagerly at construction
(`_kernel_jvm/task.l:209-212`) vs .NET's real timer; JVM regex accepts and
**ignores** the timeout (`_kernel_jvm/regex_host.l:74-81` — ReDoS gap,
#330/#1103) vs .NET's 1-second timeout; the JVM `http_server` twin exposes 8
of 15 functions (breaks `lyric-web` static files on JVM); native kernels
silently lack functions that loaded public modules call
(`Std.Console.readLine`, `Std.File.stat` and the throwing reads,
`Std.Environment.exit`/`appBaseDirectory`/… — the loader falls back to the
.NET kernel file whose `@externTarget`s cannot compile natively). Signature
drift across twins (`hostGetUtf8Enc(): Enc` vs `(): String`;
`hostCreateDirectory: DirectoryInfo` vs `Unit`) and behavioral drift (JVM
`hostFromBase64` skips re-validation; native `hostParseCanonicalGuid`
returns `Some` unconditionally, `_kernel_native/uuid_host.l:42-44`; JVM
`hostIntToChar` returns a surrogate where .NET throws; `Dictionary`
insertion-order vs `HashMap` unordered key enumeration).

### 7.3 API shape at the kernel boundary

- **BLOCKER**: `Std.Task.scopeSpawn` on `--target dotnet` never executes the
  spawned closure — documented in-file (`_kernel/task.l:57-68`) with no
  tracking issue. A silently-not-concurrent public primitive.
- **MAJOR**: the stdlib depends on the CLI host assembly —
  `_kernel/http_host.l:247-254` binds `Lyric.Cli.Aot.UnixSocketHttpClient`;
  standalone deployments of `Lyric.Stdlib.dll` fail at runtime (#5304
  partially tracks this; the deployment coupling deserves its own issue).
- **MAJOR**: six error-signaling conventions coexist (`Result[T, IOError]`,
  `Result[T, String]`, `Option` seams, `Bool + out`, magic sentinels —
  `http_server.l:170-186` returns `"GET"`/`"/"` on error;
  `process_capture_host.l:271-292` swallows spawn failure into
  `exitCode = -1`). The #4752 Result-seam program covers only
  file/env/process/time; extend it.
- **MAJOR**: locale-dependent error classification — `hostReadTextResult`
  matches the English message prefix `"Could not find file"`
  (`file_host.l:108-114`, #601).
- The `"\u{0000}"` NUL-marker workaround for nullable `String?` returns is
  duplicated in two files on both targets because of the `case null`
  miscompile (#4775) — fix the root or centralize the seam.

### 7.4 MAJOR — Decision-F enforcement is gone

The ratchet test (`KernelBoundaryTests.fs`) promised by
`_kernel/README.md:33-48` was deleted with the F# purge and has no Lyric
replacement; CI retains only `audit-kernel-stubs.sh` and `audit-axioms.sh`,
neither of which counts extern declarations. The kernel sits at 554
declarations vs the README's 150 v1.0 cap. Restore enforcement as a
Lyric/CI ratchet, rewrite the README (it cites deleted F# files and the
wrong parent path), and re-decide or re-affirm the cap.

Ecosystem violations of "externs only in kernel files":
`lyric-web/src/web.l:72-96`, `lyric-web/tests/dispatch_tests.l:31-46`,
`lyric-db/src/db.l:41`, `lyric-proto/src/proto_main.l:52-101`,
`lyric-mail/src/mail.l:48-49`, `lyric-aws-xray/src/xray.l:72-178` (which has
a `src/_kernel/` yet declares its main extern surface outside it). If
`import extern` outside kernels is intended to be legal post-D116, write the
exemption into docs/14/Decision F — today the rule says it isn't.

### 7.5 Duplication and dead kernel code

Same extern declared in multiple kernel files: `Encoding` + `get_UTF8` ×3
(+2 in lyric-web), `CultureInfo` ×2, `Convert.ToInt64` ×2,
`TimeSpan.FromSeconds` ×2, `DateTime.op_GreaterThan` ×2,
`System.Diagnostics.Process` under two aliases, `StreamReader..ctor` ×2,
`Task` ×2 — consolidate to single owners. The ten `*Safe` wrappers are
duplicated verbatim between `_kernel/http_host.l:323-407` and
`_kernel_jvm/http_host.l:129-210` and contain no externs — hoist into
`std/http.l`. Dead: the `lyricJsonGet*Slice` family (~290 lines across both
targets, zero callers), nine .NET non-`Safe` http wrappers, `respondBytes`,
the stale JVM `setToSlice` copy; the `jvmExceptionMessage`/`Cause`/`TypeName`
accessors are unreachable through any public module (the `JvmException`
payload is publicly unreadable). Eight "only X should call this" `pub`
bridges should be privatized. ~12 stale headers (README paths to deleted F#
files, `task.l:1`/`http_server.l:1` wrong self-paths, "Bootstrap-grade"
self-descriptions).

---

## 8. Stdlib public API surface

### 8.1 BLOCKER — `Std.Log` structured fields panic

`escapeLogValue` (`log.l:58`) calls `s.substring(i, i + 1)` — the second
argument is a **count** (`string.l:115`), so for `i ≥ 1` this over-reads and
at the tail throws. Any `log(level, msg, [field(...)])` call with a key or
value of length ≥ 2 panics. Survives because the shipped tests only exercise
the zero-fields path and `lyric-logging` re-implements its own
`LogField`/`field` instead of reusing `Std.Log`. Fix: `s.substring(i, 1)`
plus a fields-path test.

### 8.2 MAJOR consistency findings

- **Four naming schemes for fallible conversion**: `parseOptInt` (Option),
  `tryParseInt` (Result), `parseUuidOpt` (Option, suffix trailing),
  `Url.tryFrom` (Result) — and `try*` means Result in parse/regex/http but
  **Option** in encoding (`tryDecodeHex`, `encoding.l:61`) and json
  (`tryGetProperty`, `json.l:50`). docs/10 specifies
  `tryParse → Result[T, ParseError]`. Codify one rule (`try<Verb>` ⇒
  Result, `<verb>Opt` ⇒ Option) with a decision-log entry and rename the
  offenders.
- **Panic vs Result drift within one failure class**: `parseJson` panics on
  malformed input (`json.l:20`) while `parseXml`/`parseYaml` return
  `Result` — no `tryParseJson` exists and `rest.l:302-347` documents the
  workaround (#984). JSON — the format most likely to carry untrusted
  input — is the only panicking parser.
- **Error-type drift**: `sha512OfFile: Result[String, String]`
  (`hash.l:32`) vs `IOError` everywhere else; `process.l:106` `runCapture`
  errors as `String` while `run` in the same module uses `IOError`; EOF is
  modeled two ways (`console.l:50` `Err(EndOfInput)` vs `stream.l:30`
  `Ok(None)`); `errors.l:15` `ParseError.OutOfRange` is dead —
  `parse.l:204,212` map overflow to `InvalidFormat`.
- **`Std.Yaml` hand-rolls integer accumulation with no overflow guard**
  (`yaml.l:317-334`, `:377-390`) — a >19-digit scalar silently wraps —
  while the file already imports `Std.Parse` whose `parseOptLong` is
  overflow-checked. It also embeds a second JSON parser whose `parseJson`
  name-collides with `Std.Json.parseJson`.

### 8.3 MAJOR structural findings

- **No string builder anywhere**: every module accumulates
  `result = result + …` in loops — `encodeHex`/`encodeBase64`/`tryDecodeUtf8`
  (`encoding.l:45-298`), `format` pads, `log`, `uuid`, the xml/yaml
  collectors — O(n²) on exactly the APIs handed large payloads. A
  kernel-backed StringBuilder is the single highest-leverage missing
  primitive.
- **`List[T]` has no combinators at all**: `collections.l` is Map-only;
  `iter.l` is slice-only, so `List` users pay an O(n) `.toArray()` per
  operation. Within `iter.l`: `sumDouble` exists but not
  `minDouble`/`maxDouble`; no `contains`/`indexOf`/`flatMap`/`zip`/`enumerate`.
- **`Std.Stream` is a dead abstraction**: five `@stable` interfaces
  (`stream.l:12-53`) with zero implementations and zero importers repo-wide.
  Implement (`File.openRead(): impl ByteReader`) or delete — `@stable` on
  never-implemented interfaces freezes an untested design.
- **`Std.Time` has no `toEpochMillis` inverse and no Clock/SystemClock** —
  CLAUDE.md's own module summary advertises both; `time.now()` is
  unmockable through the stdlib. `FileStat.modifiedAt` is an opaque
  `FileTime` inconvertible to `Instant`, and `FileStat` carries no size.
- **Dual filesystem APIs**: `file.l:83-138,212-230` vs `directory.l:28-225`
  are two complete directory APIs diverging in return type
  (`List[String]` vs `slice[String]`), verbs, missing-dir semantics, and
  path-shape guarantees; `directory.createRecursive` is a pure alias of
  `create`. Make `Std.File` file-only and `Std.Directory` the sole dir API.
- **Dual process APIs with divergent quoting**: two public `runCapture`s
  with different contracts (`process.l:106` Result+timeout vs
  `process_capture.l:88` bare `String` that swallows spawn failure and
  stderr), and `buildArgString` implemented twice with **different quoting
  policies** — only one carries the CWE-78 hardening analysis
  (`process_capture.l:15-61` vs `process.l:23-40`). Fold `ProcessCapture`
  into `Process` with the hardened quoting.
- **Dual regex modules**: two `pub union RegexError`s whose collision the
  type checker special-cases (`typechecker_exprs.l:3332-3342`,
  D-progress-434); the deprecated `regex_safe.l` leaks kernel types into
  public signatures yet holds the **only** group-capture API. Ship
  `matchOne`/`matchAll` with a pure-Lyric `Match` record on `Std.Regex`,
  delete `Std.RegexSafe` and the checker special-case.
- **`rest.l`/`http.l` layering**: `RestClient` cannot carry a custom
  `HttpClient` (`rest.l:151` hardcodes the free default-client `sendAsync`)
  so a Unix-socket or no-redirect REST client is impossible;
  `defaultHeaders: String` is a headers *collection* typed `String` and
  dead; every JSON helper hardcodes `val url = ""` degrading diagnostics.
- **`lyricJsonGet*(…, value: out T): Bool`** — six public functions on the
  Bool+`out` shape the stdlib elsewhere migrated away from as
  native-unexpressible (`time.l:40-42`), with documented O(N²) re-parse per
  field; `valueKind(elem): Int` uses magic ordinals that should be a
  `pub enum JsonKind`.

MINOR: prefix drift (`setAdd` vs `mapGet` vs unprefixed; `iterMaxInt` vs
`maxLong` vs `sumInt` vs core.l's `sumInts`); separator-first `join` in
string.l vs subject-first everywhere else; `testing.l` asserts
`(actual, expected, label)` vs `testing_snapshot.l` `(dir, label, actual)`;
`secureNextInt(max)` means what `nextIntBelow` means; missing surface
(`sha256OfFile`, `String.fromChar`, file append/copy/move/temp, `clamp`,
Double/Bool `assertEqual`); core.l's slice helpers duplicating iter.l with
divergent empty-input semantics (deprecate per its own header); xml/yaml
parallel scanner kits both re-implementing `Std.Char.hexDigitValue`; doc
coverage holes (string.l 0/27 `///`, parse.l 0/12, math.l 2/42 — plain `//`
that `lyric doc` cannot see) and "Bootstrap-grade" headers on file/testing/
json contradicting the repo standard.

---

## 9. Duplication, consolidation, and idiom (compiler-wide)

### 9.1 HIGH — MSIL↔JVM copy-paste-then-diverge

The two backends lower the same AST through structurally parallel,
hand-synchronized code; `jvm/bridge.l:461` admits the replication outright.
Divergence is not hypothetical — it has produced one-sided fixes:

- **Lambda capture analysis** (~560 lines MSIL `codegen.l:22748-23310` vs
  ~510 JVM `02_exprs.l:2059-2591`, 100% AST-level): the JVM copy walks
  match-arm **guards** (+ the #4798 `EParen` fix); the MSIL twin
  (`codegen.l:22820`) walks only arm bodies — a name referenced only in a
  match guard inside a lambda is invisible to MSIL capture analysis.
- **Pattern-match compilation** (`lowerPatternTestMsil` `codegen.l:9189` vs
  `lowerPatternTest` `03_match.l:435`): JVM has the `case null`
  refutable-test fix (`03_match.l:449-457`) with zero MSIL counterpart;
  MSIL has enum-ordinal-first `PBinding` resolution (`codegen.l:9211`) with
  no JVM counterpart.
- **String-method intrinsic tables**: 47 `memberName ==` comparisons in
  MSIL vs 37 in JVM, differently grouped — adding a String method means
  editing both chains and remembering both exist.
- Union-case identity computed stringly and independently on both sides
  (`caseParentFqnMsil` vs `caseClassName` + hand-rolled `$` scans).

Recommendation, in order: (1) extract capture analysis (pure AST, ~1,000
lines collapse to ~500); (2) a target-independent match decision-tree IR
(the pattern semantics live once; backends emit tests/binds from the tree);
(3) a declarative intrinsics table (receiver type × member name →
per-target emitter hook). Async lowering is architecturally divergent by
design and is *not* a consolidation candidate.

### 9.2 HIGH — Bridge triplication

`msil/bridge.l` (1,790) + `jvm/bridge.l` (1,752) + `llvm_bridge.l` (804)
orchestrate the same pipeline three times: `reportAndAbort`/`reportDiagnostics`
verbatim ×3, `dottedPath` ×2+, the `collect{InBundle,Stdlib,Restored}*`
families ×3, pass ordering ×3 (band J2/#2665 was literally re-porting pass
order MSIL already had), and `llvm_bridge.l:68`'s `isTypeItem` comment
confesses three-way drift on "which items are cross-package visible".
Entry-point explosion: MSIL exposes 8 compile entry points
(`With{Features,Restored,Version,Encoded}` combinatorics), JVM 4, LLVM 2.
Recommendation: a shared `Lyric.Pipeline` package owning diagnostics gating,
`runMiddleEnd` (single pass-order authority — this would also structurally
fix the §5.4 matrix), the `collect*` families, and one `CompileOptions`
record. ~600–900 lines net collapse; the pass-order and visibility rules are
correctness-bearing, making this the highest-leverage consolidation.

### 9.3 MEDIUM — CLI layer and dead scaffolding

Every `cmdX` hand-rolls `var i = 1; while i < argv.length` flag parsing;
`--manifest` is parsed independently in 15 files. Add a declarative
flag-spec helper to `cli_shared.l`. Seven protocol-bridge files whose
headers self-describe as F#-shim bridges have **zero importers** and are
outside the build closure — `manifest_bridge.l`, `test_synth_bridge.l`,
`lint_bridge.l`, `bench_synth_bridge.l`, `pack_bridge.l`,
`open_api_bridge.l`, `doc_bridge.l` (367 dead lines); delete them and fix
the stale CLAUDE.md text that still describes two of them as used by
deleted F# files. Also delete git-tracked `scripts/bootstrap.sh.{bak,orig,rej}`
and the transitively-dead `jvm/fuzzer.l`. Correction to docs/44: the
`resolver/` Maven shim is **not** orphaned — `cli_restore.l:730-751`
executes `lyric-resolver.jar`; what is absent is a pure-Lyric replacement.

### 9.4 MEDIUM — Reimplemented utilities

`List[String]`-contains has **19 local copies** across the tree — root
cause: `Std.Collections` has no list-contains (§8.3). Dotted-path join has
8+ copies while `Lyric.Parser.modulePathJoin` is already `pub` and used by
half the tree. Join-with-separator ×5 vs `Std.String.joinList`. JSON
escaping ×3. The suffix-namespaced helper names (`listContainsWE`,
`addNameOnceJvm`, `wireListContainsMsil`) are the symptom: helpers renamed
per-package to avoid collisions instead of importing one utility. Fix the
stdlib gap first, then delete the copies opportunistically.

### 9.5 CRITICAL — Orphaned numbered self-tests

`jvm/self_test_b1..b134` (132 files, 18,755 lines) and
`msil/msil_self_test_m1..m84` (~21,800 lines) are referenced by **no** CI
job, script, or Makefile target (only m85–m89 and m2a–m2d are wired); their
documented runner was the deleted F# Expecto host. ~40,000 lines of the
compiler's densest regression corpus currently execute under nothing —
equivalent to silently disabled tests under the repo's own standard. Order
of operations matters: (1) add a CI glob-run job first (it is the safety net
the §9.1/§9.2 consolidations need), (2) migrate incrementally into
feature-named `@test_module` suites (the `bitwise_self_test.l` pattern CI
already runs on both targets), (3) generate a coverage manifest from the
existing `//!` headers.

### 9.6 Idiom

The compiler sets the ecosystem's idiom; the recurring anti-patterns are:
giant functions (`lowerExprMsil` 1,425 lines; `newCodegenCtx` 1,228 — a
constructor; `msil/codegen.l` at 28k lines in one file vs the JVM backend's
six-file split, which is the better precedent); stringly-typed domains
(build kind as `"exe"/"lib"`, intrinsic dispatch via `memberName ==`
chains, union-case identity via `$`/`_` substring conventions, dual
type-key encodings); the mutable-counter-via-singleton-`List` hack
(`slotTicker`/`labelTicker`, `jvm/codegen/01_types.l:283`) deserving a real
counter abstraction; inconsistent error propagation (bridges return
`Bool`+print, CLI returns `Int`, manifest/stdlib return `Result`; panic
density 171 in `llvm_codegen.l` vs ~60 per managed backend); and manual
index loops (111 in `msil/codegen.l`) where `for`-in is used elsewhere.

---

## 10. Prioritized remediation plan

Ordered by (severity × blast radius ÷ effort). Each item should land as its
own PR/issue; none are bundled.

**Band 0 — safety net (before any consolidation)**
1. CI glob-run job for the orphaned `self_test_b*`/`msil_self_test_m*`
   corpus (§9.5, H8).

**Band 1 — silent-miscompile fixes (small, high value)**
2. MSIL H1: ctx-aware signature builders in
   `registerRestoredIfaceMethod`/`registerRestoredRecordMethod` + a
   cross-package restored-interface test (§3.1).
3. JVM H2: scope-bracket match-arm/`for` pattern binds; extend
   `block_shadow_self_test.l`; audit MSIL for the same hole (§4.1).
4. JVM H3: route compound assignment through `emitCompoundArith` + String
   concat arm + RHS coercion (§4.2).
5. JVM H4: canonical `Byte` representation + comparison masking (§4.3);
   MSIL `ldind.u1` for `out Byte` (§3.2) and the scalar-`Byte` ABI decision.
6. Stdlib H6: `log.l:58` one-char fix + fields-path test (§8.1).
7. Mono B3 (`satisfiesMarker` constant-true) and B2/B1 diagnostics (§5.2).
8. Convert the silent fallbacks to panics: MSIL by-name token resolution
   (§3.3) and JVM null/receiver-as-value fallbacks (§4.4).

**Band 2 — platform parity**
9. Stdlib H5: replace the five phantom `_kernel_jvm` kernels with
   pure-Lyric-over-auto-FFI implementations (format and path first — small
   and JDK-expressible) (§7.2).
10. H7: file and fix the `scopeSpawn` dotnet no-op (§7.3).
11. Pipeline matrix holes: `…AndTypeDecls` mono on JVM single-file and
    native; cfg erasure on single-file builds; wire/stubbable on native;
    resolve the `injectWeaveImports` asymmetry (§5.4).
12. MSIL `Float`→R8 and `TRefined`→`MInt`/`JInt` decisions (§3.2, §4.6);
    `println(char)`/locale-formatting parity (§3.2).

**Band 3 — FFI capability work to retire `@externTarget`** (§6.4)
13. Property get/set in auto-FFI (CRITICAL, ~24% of the kernel).
14. Value-type receivers + value-type `.new()` (Q48-004).
15. `.new(args)`-capable bootstrap seed (#5167) + begin the ~150
    "migratable today" kernel migrations (math, path, process,
    secure_random first).
16. Async Task unwrap; out/ref surface + null→Option convention (language
    decision); JVM SAM conversion + generalized D122 delegates.
17. Extern typing in the type checker (replaces the blanket `TyError`;
    prerequisite for most of the above having compile-time diagnostics).

**Band 4 — checker/middle-end soundness** (§5)
18. A1/A2 (`for`-loop and lambda-param typing), A3 (generic record fields),
    A4/A5 (method-call checking + unknown-member diagnostics).
19. One assignability relation across sink positions; alias transparency
    unified across resolver/propagate/mono; shared unifier or
    checker-resolved types consumed by mono (the structural fix).

**Band 5 — consolidation**
20. `Lyric.Pipeline` shared driver + `CompileOptions` (§9.2).
21. Extract capture analysis; match decision-tree IR; declarative
    intrinsics table (§9.1).
22. Delete dead code (7 protocol bridges, `typeExprToMsil`,
    `valueTupleMsilCtx`, `tokConcat3`, `jvm/fuzzer.l`, kernel dead surface
    §7.5); fix stale headers/docs (incl. CLAUDE.md bridge references and
    the docs/44 `resolver/` claim).
23. Stdlib API consolidation: StringBuilder kernel primitive; List
    combinators; file/directory, process, regex, rest/http merges; naming
    convention decision-log entry; Decision-F enforcement ratchet (§7.4,
    §8).

**Band 6 — performance**
24. MSIL `methodBodyRvas` incremental accumulator and
    `findTypeRefRowByName` memoization (§3.4); JVM auto-FFI archive caching
    (§4.5); JVM branch-offset guard then goto-widening (§4.5).

---

## 11. Corrections to earlier docs surfaced by this review

- docs/41 C2 "remaining TyError forms now covered" — overstated; see §5.1.
- docs/44 "orphaned `resolver/`" — stale; the Maven resolver JAR is the
  live resolution path (`cli_restore.l:730-751`).
- docs/52/53 "MSIL + JVM parity" for the strongly-typed lambda ABI — JVM
  still uses the boxed `Object[]` ABI; parity is semantic only (§4.5).
- docs/57 "`import_extern_self_test.l` isn't wired into CI" — stale; it is
  wired, dotnet-only (`.github/workflows/ci.yml`), missing a JVM leg.
- CLAUDE.md still describes `manifest_bridge.l`/`test_synth_bridge.l` as
  used by deleted F# shims, and advertises `Std.Time` Clock/SystemClock/
  `toEpochMillis` that do not exist.
