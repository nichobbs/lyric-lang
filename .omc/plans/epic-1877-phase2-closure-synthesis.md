# Epic #1877 Phase 2 — Closure Class Synthesis & Zero-Overhead Captures

**Status:** Work plan, ready for execution
**Targets:** MSIL (`--target dotnet`) and JVM (`--target jvm`) — feature parity required
**Date:** 2026-06-24
**Builds on:** Phase 1 (strongly-typed lambda method signatures, HOF type propagation, FFI delegate type safety, methods-in-types D037)
**Backing docs:** `docs/52-strongly-typed-lambdas-proposal.md`, `docs/53-epic-1877-implementation-plan.md` (this plan supersedes the thin `docs/53` and grounds it in the actual code), `docs/42-extern-metadata-resolution.md` (epic #1622), `docs/44-jvm-production-readiness-plan.md` (J2b follow-up).

---

## 1. Executive Summary

Phase 1 made lambda *method signatures* strongly typed and propagated function types through HOFs. Phase 2 eliminates the remaining boxing/allocation overhead in the closure **environment and invocation ABI** on both targets, and removes the last hardcoded delegate-type guesswork at the FFI boundary.

The two backends are at different starting points, and the plan accounts for that asymmetry rather than pretending they are symmetric:

- **MSIL today** lifts each lambda to a *static* `__lambda_<i>` method, passes captures as a single `object[] __caps` parameter (slot 0), boxes every value-type capture on store and unboxes on read, and constructs a `System.Func<object,…,object>` / `System.Action<object,…>` delegate. Invocation boxes args and `unbox.any`s the return. There is **no** closure class today. (`lyric-compiler/msil/codegen.l` — `liftLambdasMsil` @ ~19648, capture array build @ ~6160–6193, `boxIfNeededMsil` @ ~4427, `castObjectToMsil` @ ~4462, delegate type selection @ ~6125–6155.)
- **JVM today** already synthesizes a per-lambda inner class `<pkg>$Lambda$<n>` with **typed capture fields** and a typed constructor (`lyric-compiler/jvm/codegen/02_exprs.l` `lowerLambda` @ ~1908; `lyric-compiler/jvm/lowering.l` `lowerClosure*` @ ~2142–2257). But the *invoke ABI is still uniform*: every closure implements `<pkg>/Lyric$Lambda.invoke([Ljava/lang/Object;)Ljava/lang/Object;`, so params/returns are boxed at the boundary (`coerceArgTo`/`boxIfNeeded`, `lowerLambdaInvoke` @ `04_calls.l:381`). **By-reference `var` capture is entirely missing** on JVM (it snapshots by value — D-progress-474 / docs/44 J2b open item).

**High-level approach.** Bring MSIL up to a typed-field closure class (matching what JVM already does for *captures*), then upgrade *both* backends from the uniform `Object[]`/`object[]` invoke ABI to strongly-typed delegate / functional-interface invocation (zero box on the hot path). Close the JVM by-reference-capture parity gap. Finally, replace the hardcoded delegate-type guess at the FFI boundary with metadata-driven detection (docs/42). The phase is sequenced so each stage is independently testable and lands production-quality (no MSIL-only or JVM-only slices left undocumented).

**What "zero-overhead" means concretely (the measurable bar):**
- A non-generic primitive lambda such as `(Int) -> Int` invoked in a hot loop emits **zero `box` / `unbox.any` (MSIL)** and **zero `Integer.valueOf` / `intValue` (JVM)** instructions on the call path and capture-read path.
- Captured primitives are stored in typed fields (`int32` / `int` `J`-slots), not boxed into `object` / `Object`.
- Verified by IL/bytecode inspection in CI (`ilverify`-adjacent disassembly grep on MSIL; `javap -c` grep on JVM), not by eyeballing.

---

## 2. RALPLAN-DR Principles (mode: DELIBERATE)

This is a structural codegen change on the hottest path in the language. Treated as **DELIBERATE** (high-risk: every lambda in every program is affected, both backends, FFI ABI surface). Hence the pre-mortem + expanded test plan below.

1. **Parity is non-negotiable, asymmetry is acknowledged.** Both targets must reach the same observable semantics and the same "zero box on the hot path" guarantee. The two backends start from different places, so stages are scoped per-backend but gated on a *shared parity test corpus* that must pass identically on both.
2. **Correctness before allocation-elimination, always.** Capture semantics (by-value `val`, by-reference `var` cells, multi-level nesting) must remain bit-for-bit correct as established by `closure_correctness_self_test.l` *before* any boxing is removed. No optimization may regress a capture-correctness test.
3. **No new uniform-ABI debt; remove it incrementally and verifiably.** Each stage that claims "removed a box" ships with a disassembly assertion proving the instruction is gone. We never declare a hot path "zero-overhead" by inspection alone.
4. **Reuse existing synthesis machinery; do not invent a second class-emitter.** MSIL closure-class synthesis reuses the in-bundle-generics TypeDef/Field/TypeSpec machinery (D-progress-453/455, `lowerMRecord`/`MNewobjGenericByName`/`MStfld`/`MLdfld`). JVM reuses `lowerClosure`/`makeClassFullWithInterfaces`. No bespoke parallel emitter.
5. **Metadata-driven over hardcoded.** Delegate/`Func`/functional-interface target types are resolved from real reference-assembly / JDK metadata (docs/42 reader, `metadata_reader.l`) rather than the current fixed `(object…)` guess, wherever the FFI boundary demands a nominal delegate.

---

## 3. Decision Drivers (top 3)

1. **Hot-path allocation is the whole point.** The motivating cost is per-invocation boxing and per-construction `object[]`/`Object[]` allocation in tight loops (iterators, `map`/`filter`, HOFs). Any design that does not provably remove these from the common monomorphic case fails the epic. → drives Options toward typed closure classes + typed delegates.
2. **Two backends, one semantics, finite review budget.** MSIL and JVM diverge in machinery (TypeSpec/PE-bytes vs class-file pool) but must not diverge in behavior. The cost of keeping them in sync is the dominant engineering constraint. → drives a shared test corpus and per-backend stage scoping rather than a single mega-change.
3. **Generic / polymorphic lambdas defeat full monomorphization.** A `[T] (T) -> T` lambda, or a lambda stored in an erased generic container, cannot always be fully unboxed (.NET reified generics help; JVM erasure does not). The design must degrade gracefully to boxing *only* for the genuinely-polymorphic case, never for the monomorphic primitive case. → drives the "specialize the common case, box the residual" split below.

---

## 4. Viable Options for Closure Synthesis

### Option A — Per-lambda synthesized closure class with typed instance method (chosen)

Each capturing lambda gets a dedicated synthesized class (`__Closure_<i>` on MSIL; the existing `<pkg>$Lambda$<n>` on JVM) holding one **typed field per capture**. The lifted lambda body becomes an **instance method** (`HASTHIS`) on that class; captured reads become `ldarg.0; ldfld` (MSIL) / `aload_0; getfield` (JVM). The delegate/functional-interface target is the strongly-typed `System.Func<int,int>` / `System.Action<int>` (MSIL) or a typed functional interface (JVM). Non-capturing lambdas keep a static method + `ldnull` target.

- **Pros:**
  - Eliminates the `object[]`/`Object[]` allocation *and* per-capture box/unbox entirely for the monomorphic case.
  - Mirrors the C# / Roslyn closure model and the JVM's existing capture-field model → minimal conceptual novelty, reuses both backends' class synthesis.
  - JVM is already ~70% here for captures; MSIL gets brought to the same shape. Convergent.
  - Plays naturally with the typed-delegate invoke ABI (Stage 3): `this` becomes the delegate target, `ldftn` the instance method.
- **Cons:**
  - One synthesized type per capturing lambda → metadata/class-count growth (mitigated: non-capturing lambdas stay static; nested lambdas reuse one class each).
  - MSIL must allocate `GenericParam`/`TypeSpec` rows when a closure field is a generic instantiation (reuses D-progress-453/455 machinery but adds wiring).
  - By-reference `var` capture still needs a heap cell *field* (typed cell, not `object[]`).

### Option B — Strongly-typed closure *struct/record* passed by ref (rejected, partially)

Synthesize a value-type `struct` (MSIL) holding typed capture fields, passed `byref` to a still-static lambda method; JVM analog is a typed carrier object whose fields are read directly.

- **Pros:**
  - No heap allocation for the environment at all (struct on stack) when the closure does not escape.
  - Zero box for captures.
- **Cons:**
  - **Escape analysis required.** A lambda that outlives its defining frame (returned, stored, captured by an inner lambda) cannot use a stack struct — it must be boxed/heap-promoted. Lyric closures routinely escape (HOFs, returned adders). Determining non-escape is a whole-program analysis Phase 2 does not have.
  - Delegate construction needs a *target object*; a `byref struct` cannot be a delegate target. Would force a second wrapper allocation, defeating the saving.
  - JVM has no by-ref struct; parity would require a totally different mechanism per backend → violates Principle 1.
  - **Verdict: rejected as the primary mechanism.** Retained only as a *future* (post-Phase-2) optimization for provably-non-escaping closures behind escape analysis; documented in Follow-ups.

### Why a third option is not viable

A "keep `object[]` but only strongly-type the arguments" interim (docs/52 Option B / 2B) was considered and **invalidated**: it leaves the capture allocation and capture box/unbox in place, so it fails Decision Driver #1 (the dominant cost is in the capture path for closures that capture primitives in loops). It is strictly dominated by Option A and would create exactly the "uniform-ABI debt" Principle 3 forbids. Recorded here per the RALPLAN-DR single-survivor rule.

---

## 5. Implementation Stages

Six stages. Each names the files it touches, its dependencies, and binary acceptance criteria. "AC verified by" lists the concrete check.

### Stage 0 — Parity test corpus + disassembly harness (foundation)

**Goal:** Establish the shared, dual-target test corpus and the IL/bytecode inspection harness *before* changing codegen, so every later stage has a regression net and a "zero box" oracle.

- **Files:**
  - New: `lyric-compiler/lyric/closure_zero_overhead_self_test.l` (`@test_module`, imports only `Std.*`) — primitive captures in loops, multi-arg primitive lambdas, `Result`/`Option` payloads, returned/escaping closures, by-ref `var` mutation, multi-level nesting (port the structure from `closure_correctness_self_test.l` and `lyric-compiler/jvm/closure_jvm_self_test.l`, unified).
  - New: `scripts/assert-no-box-msil.sh` — compiles a fixture with `lyric build --target dotnet`, disassembles, asserts zero `box`/`unbox.any` on the marked methods.
  - New: `scripts/assert-no-box-jvm.sh` — `lyric build --target jvm` then `javap -c` greps for absence of `valueOf`/`intValue`/`doubleValue` on marked methods.
  - Wire both into `.github/workflows/ci.yml`.
- **Dependencies:** none.
- **AC:**
  - `closure_zero_overhead_self_test.l` passes on **both** `lyric test --target dotnet` and `lyric test --target jvm` (it will pass at the boxed baseline — it tests *behavior*, the scripts test *allocation*).
  - The two disassembly scripts run in CI and *currently fail loudly* against the boxed baseline (they are the moving target). They are marked as expected-fail at Stage 0 and flip to required-pass at the stage that removes the relevant box. (Tracked with an explicit `# EXPECT-FAIL until Stage N` header — not an `Ignore` attribute.)
- **AC verified by:** CI run shows the behavior test green on both targets; the box-assertion scripts produce the expected non-zero baseline counts (recorded as the metric to beat).

### Stage 1 — MSIL closure class synthesis with typed fields (instance method)

**Goal:** Replace `object[] __caps` with a synthesized `__Closure_<i>` class holding typed fields; relocate the lambda body to an instance method. Captures of *value* types are stored unboxed.

- **Files:** `lyric-compiler/msil/codegen.l` (primary), `lyric-compiler/msil/lowering.l` (reuse `lowerMRecord`-style TypeDef/Field emission, `MStfld`/`MLdfld`, `MNewobj`).
  - `liftLambdasMsil` (~19648) and `collectLambdasBfsExpr` (~18770): synthesize a `__Closure_<i>` TypeDef per *capturing* lambda alongside the lifted method; build `captureNameToField: Map[String, FieldToken]`.
  - Lambda method emission (~16531–16566): drop the `object[] __caps` slot-0 prepend; set `HASTHIS = true` for capturing lambdas; flags `0x0016` → instance for capturing, stay static for non-capturing.
  - Capture read/write inside body (~5080–5103): replace `ldarg.0; ldc.i4 i; ldelem.ref; (unbox)` with `ldarg.0; ldfld <field>` (and `stfld` for writes). Value-type fields read with **no** `unbox.any`.
  - `ELambda` construction (~6160–6193): replace `newarr/dup/stelem.ref` loop with `newobj __Closure_<i>::.ctor` then per-capture `dup; <load value>; stfld`. No `boxIfNeededMsil` on value-type captures.
- **Dependencies:** Stage 0.
- **AC:**
  - All `closure_correctness_self_test.l` + `closure_zero_overhead_self_test.l` behavior cases green on `--target dotnet` (multi-level nesting, by-ref cells still correct — by-ref still uses a typed cell *field*, see Stage 4 for the full by-ref cleanup).
  - `scripts/assert-no-box-msil.sh` reports **zero box on the capture-store path** for primitive `val` captures (the EXPECT-FAIL flips to required-pass for the capture path).
  - No `object[]` `newarr` emitted for any capturing lambda (grep the disassembly: `newarr [^]]*Object` count == 0 in lambda-construction methods).
- **AC verified by:** `make stage1-fast && make self-test NAME=closure_zero_overhead`; disassembly script.

### Stage 2 — JVM by-reference (`var`) capture parity

**Goal:** Close the documented JVM gap (docs/44 J2b): captured `var`s mutated after closure creation must be observed through the closure. Implement heap-cell hoisting matching MSIL's `#1479 v2` semantics, with a **typed cell** field.

- **Files:** `lyric-compiler/jvm/codegen/02_exprs.l` (`lowerLambda` ~1908, capture analysis `lambdaCaptureNamesJvm` ~1870), `lyric-compiler/jvm/lowering.l` (`lowerClosureCaptures`/`lowerClosureCtor` ~2142–2224), `lyric-compiler/jvm/codegen/06_items.l` (var-decl hoisting pre-pass).
  - Add a hoist pre-pass mirroring MSIL `hoistedVarNames`: a `var` referenced inside any lambda is allocated as a one-element typed cell (a synthesized `Lyric$Cell` carrier or a 1-element typed array `int[]`/`Object[]` chosen per type) on the heap.
  - Closure field for a by-ref capture is the cell reference; reads/writes go through the cell.
- **Dependencies:** Stage 0. Independent of Stage 1 (different backend) — can run in parallel.
- **AC:**
  - The "nested closure captures mutable (cell) from outer scope" and counter-mutation cases of `closure_zero_overhead_self_test.l` pass on `--target jvm` (they pass on MSIL already).
  - A new e2e fixture: build a `var counter` incremented inside a returned closure, call twice, assert `2` — passes on both targets identically.
- **AC verified by:** `make lyric && ./bin/lyric test --target jvm <fixture>`; behavior parity diff against `--target dotnet`.

### Stage 3 — Strongly-typed invoke ABI (both targets)

**Goal:** Remove boxing on the *call* path. MSIL: build `System.Func<int,int>`/`System.Action<int>` from the closure instance via `ldftn` instance method + delegate `newobj`; invoke with typed args, no `box`/`unbox.any`. JVM: replace the uniform `Lyric$Lambda.invoke([Object)Object` with **typed functional interfaces** per arity/signature shape (e.g. `Lyric$IntInt`), or use typed bridge methods, so `invokeinterface` takes/returns primitives where possible.

- **Files:**
  - MSIL: `lyric-compiler/msil/codegen.l` delegate-type selection (~6125–6155) → pick the typed `Func`/`Action` arity from the lambda's resolved `TFunction`; invoke site (~10052) → drop arg box and return `unbox.any`/`castObjectToMsil`; `typeExprToMsilCtx` mapping `TFunction(params,ret)` → typed `System.Func`/`System.Action` (the `TFunction([],TUnit)->System.Action` mapping from `closure_correctness_self_test.l` already exists; generalize).
  - JVM: `lyric-compiler/jvm/codegen/06_items.l` interface emission (~3273) → emit a typed functional interface per distinct signature shape used; `lyric-compiler/jvm/codegen/04_calls.l` `lowerLambdaInvoke` (~381) → call the typed interface method with primitive args; `lyric-compiler/jvm/codegen/02_exprs.l` closure method (~1986–2008) → drop `Object[]` unpack and result box for the typed shapes.
- **Dependencies:** Stage 1 (MSIL needs the instance method as delegate target); Stage 2 (JVM cell semantics stable). 
- **AC:**
  - `scripts/assert-no-box-msil.sh` and `scripts/assert-no-box-jvm.sh` report **zero box on the invoke path** for monomorphic primitive lambdas; both EXPECT-FAIL markers flip to required-pass.
  - Polymorphic/erased-generic lambdas (e.g. lambda returning `Result[Int,String]` through a generic container) still compile and run correctly, falling back to boxing *only* for the genuinely-erased payload (assert the *typed* cases are unboxed and the *erased* cases still pass behaviorally).
  - `closure_correctness_self_test.l` + zero-overhead corpus green on both targets.
- **AC verified by:** disassembly scripts (zero box) + behavior corpus (both targets) in CI.

### Stage 4 — Typed by-reference cells + nested-closure field threading (both targets)

**Goal:** Finish capture correctness under the new model: by-ref cells are typed (not `List[object]`/`Object[]` of boxed values where avoidable), and a nested inner closure reads outer captures through the outer closure's typed *fields* (not re-boxed). Unifies the MSIL `#1479 v2` cell with the JVM cell from Stage 2 so both use the same typed-cell shape.

- **Files:** MSIL `codegen.l` `finishHoistedCellMsil` (~3461–3479) and cell read (~5099–5103) → typed cell where the captured type is a value type; JVM `lowering.l` cell handling from Stage 2. Multi-level threading: ensure `lambdaCaptureNamesMsil` (~19615) / `lambdaCaptureNamesJvm` continue to re-capture outer captures, now as field copies/cell refs.
- **Dependencies:** Stages 1, 2, 3.
- **AC:**
  - All five `closure_correctness_self_test.l` nesting cases + the mutable-cell case green on both targets.
  - For a value-type by-ref capture mutated in a loop, the disassembly shows the cell field typed to the primitive (no per-iteration box) where the cell carrier permits; where boxing is genuinely required (heap cell of a reified-generic), it is documented and limited to one box at cell init, not per access.
- **AC verified by:** behavior corpus both targets + targeted disassembly on the by-ref fixtures.

### Stage 5 — Metadata-based delegate / functional-interface type detection (FFI boundary)

**Goal:** Replace the hardcoded `(object…)` FFI delegate guess with metadata-driven detection so a Lyric lambda passed to a .NET `Predicate<int>` / `Func<int,bool>` (or a JVM `java.util.function.*` / Maven-resolved functional interface) structurally matches the real nominal delegate. Aligns with docs/42 / epic #1622.

- **Files:** MSIL `lyric-compiler/msil/metadata_reader.l` (`decodeMethodSigAt` ~1281, `decodeType` ~1136) → add delegate detection: a parameter typed as a class extending `System.MulticastDelegate`/`System.Delegate` → read its `Invoke` method signature, expose `params`/`ret` so codegen can build a structurally-matching lambda + delegate ctor; `lyric-compiler/msil/codegen.l` FFI call lowering uses the resolved delegate signature instead of the fixed guess. JVM `lyric-compiler/jvm/auto_ffi.l` → detect single-abstract-method interfaces from JDK/Maven metadata and target them with `invokedynamic`/`LambdaMetafactory` *or* a synthesized adapter implementing the SAM.
- **Dependencies:** Stages 1–4 (the strongly-typed closure machinery is the thing being targeted at the FFI boundary).
- **AC:**
  - MSIL: a Lyric lambda passed to a real BCL method expecting `Predicate<int>` / `Func<int,bool>` compiles and runs (manual + automated fixture) with the correct nominal delegate, no adapter thunk, no box on the monomorphic path.
  - JVM: a Lyric lambda passed to a JDK SAM interface (`java.util.function.IntUnaryOperator`) resolves the SAM from metadata and runs.
  - `auto_ffi_self_test.l` / `auto_ffi_jvm_self_test.l` extended with a delegate/SAM case, green in CI on both targets.
- **AC verified by:** extended auto-FFI self-tests on both targets; manual BCL/JDK interop fixture.

---

## 6. Critical Risks (with mitigations)

1. **Capture-correctness regression while removing boxing.** Removing `unbox.any`/`intValue` can silently produce wrong values if a type is mis-tracked (the docs/44 "Float→double silent miscompile" class of bug). 
   - *Mitigation:* Stage 0 corpus runs every stage on both targets; box-removal AC is gated behind behavior-green. Add explicit `Float`/`Double`/`Long` capture cases (the historically-broken types) to the corpus.
2. **MSIL `GenericParam`/`TypeSpec` wiring for generic capture fields is fiddly.** A closure capturing a `List[Int]` or a generic-instantiated value needs correct TypeSpec field signatures or the PE fails `ilverify`/`TypeLoadException`.
   - *Mitigation:* Reuse the validated D-progress-453/455 in-bundle-generics path (`MNewobjGenericByName`, arity-suffix rule); run `scripts/ilverify-selfhosted.sh` on every closure fixture; start with non-generic captures (Stage 1) before generic ones.
3. **JVM typed functional interfaces explode in count / collide.** Emitting one interface per signature shape per package risks name collisions or class-count blowup.
   - *Mitigation:* Canonicalize interface names by erased-signature shape (`Lyric$Fn$<descriptor-hash>`); emit once per package; cap with a fallback to the existing uniform `Lyric$Lambda` for rare/polymorphic shapes.
4. **Escaping closures + struct temptation.** A future contributor may "optimize" to a stack struct (Option B) and break escaping closures (returned adders, HOFs).
   - *Mitigation:* Option B is explicitly rejected in the ADR with rationale; the corpus includes returned/escaping closures that would crash under a naive stack-struct.
5. **FFI delegate metadata resolution depends on docs/42 reader maturity.** The metadata reader (`metadata_reader.l`) does not yet specialize delegate detection; Stage 5 depends on extending it, and delegate `Invoke`-signature reading could hit unhandled signature shapes.
   - *Mitigation:* Stage 5 is last and independently shippable; if the reader hits an unhandled delegate shape it emits a *loud, tracked diagnostic* (matching #1504 H9 stopgap policy) rather than a silent wrong bind. The monomorphic in-language closure work (Stages 1–4) does not depend on Stage 5 and ships value on its own.
6. **Cross-backend behavioral drift undetected.** A change could pass on MSIL and silently diverge on JVM.
   - *Mitigation:* Every behavior fixture asserts identical observable output under both `--target dotnet` and `--target jvm` in CI; the corpus is single-source, run twice.

---

## 7. Pre-mortem (3 failure scenarios)

1. **"It shipped MSIL-only."** Stage 1 lands the MSIL closure class, the deadline looms, JVM Stages 2–4 get deferred "for now," and the phase ships with a MSIL/JVM behavioral gap (by-ref capture on JVM still broken). This violates the project's no-one-platform-slice rule and Principle 1.
   - *Prevention:* The phase exit criterion is "the shared corpus passes identically on both targets." Stages 1 (MSIL) and 2 (JVM) are parallelizable specifically so JVM does not lag. No stage is "done" until its AC passes on both targets where the stage is cross-cutting.
2. **"Zero-overhead by inspection."** Boxes get removed on the obvious path, the team declares victory, but a non-obvious path (e.g. capture inside a `match` arm, or the by-ref cell read) still boxes every iteration, and a hot benchmark regresses vs. C#/Java.
   - *Prevention:* The `assert-no-box-*.sh` scripts are CI-required and assert on *all* marked methods including by-ref and nested cases; the corpus includes loop-hot cases. "Zero box" is a machine-checked claim, never a human one (Principle 3).
3. **"The generic case poisoned the common case."** In trying to handle `[T] (T)->T` and erased-generic containers, the implementation falls back to boxing *everywhere* (including monomorphic `(Int)->Int`) to keep one code path, silently undoing the whole epic.
   - *Prevention:* The corpus separates monomorphic-primitive fixtures (must be box-free, CI-required) from polymorphic fixtures (must be correct, boxing allowed). The split is explicit in Stage 3 AC; a regression on the monomorphic box-free assertion fails CI even if behavior is correct.

---

## 8. Expanded Test Plan

### Unit (self-tests, `@test_module`, run via `lyric test` on both targets)
- **MSIL:** extend `closure_correctness_self_test.l`; new `closure_zero_overhead_self_test.l` (capture by value, by ref, multi-arg primitives, `Float`/`Long`/`Double` captures, nested 3-deep, returned/escaping).
- **JVM:** extend `closure_jvm_self_test.l` with the by-ref `var` mutation cases (Stage 2) and typed-invoke cases (Stage 3).
- Each capture-correctness assertion checks the exact runtime value, not just non-crash.

### Integration (compiler-internal, via `make self-test` / bridge)
- Closure-class TypeDef/Field emission verified through `Msil.Bridge` in-process compile of fixtures with generic capture fields; run `scripts/ilverify-selfhosted.sh` to confirm verifiable IL.
- JVM functional-interface emission + `invokeinterface` dispatch verified through `Jvm.Bridge.compileToJarBundled` and run under `java`.

### End-to-end (`./bin/lyric build/test`, real programs)
- A returned-counter program (`var` captured, mutated, observed) — identical output on both targets.
- An iterator/HOF hot-loop program (`map`/`filter` with primitive lambda) — runs, correct result, **and** disassembly box-free.
- FFI fixture (Stage 5): Lyric lambda → BCL `Predicate<int>` (MSIL) and JDK `IntUnaryOperator` (JVM).

### Observability / verification harness (per platform)
- **MSIL:** `scripts/assert-no-box-msil.sh` — disassemble emitted PE, assert `box`/`unbox.any`/`newarr …Object` counts == 0 on marked methods; `scripts/ilverify-selfhosted.sh` for IL validity.
- **JVM:** `scripts/assert-no-box-jvm.sh` — `javap -c` assert absence of `valueOf`/`intValue`/`doubleValue`/`anewarray java/lang/Object` on marked methods.
- Both scripts emit the current box-count as a metric so regressions are visible (count must be monotonically non-increasing across stages).
- All wired into `.github/workflows/ci.yml` as required checks (flipping from EXPECT-FAIL to required-pass at the stage that earns it).

---

## 9. Verification Strategy

For each stage, "meets AC" is established by, in order:
1. **Behavior gate (required, both targets):** the relevant self-test corpus passes under `lyric test --target dotnet` *and* `lyric test --target jvm`. A stage that touches one backend still runs the full corpus on both to catch drift.
2. **Allocation gate (required where the stage claims a box removal):** the matching `assert-no-box-*.sh` script's EXPECT-FAIL marker flips to required-pass; box count for the named methods is 0.
3. **IL/bytecode validity gate:** `scripts/ilverify-selfhosted.sh` (MSIL) green; `java` runs the JAR without `VerifyError` (JVM).
4. **Parity diff:** for every behavior fixture, captured stdout under both targets is byte-identical (a small CI step diffs the two runs).
5. **No-regression gate:** the full existing self-test suite (`make self-test` across compiler packages) stays green; `closure_correctness_self_test.l` never regresses.

The phase is complete only when all six stages' gates are green on both targets and `docs/53`, `docs/01-language-reference.md` (lambda ABI section), `docs/10-bootstrap-progress.md`, `docs/44` (J2b marked done), and the book's CLI/reference are updated to reflect the shipped ABI (per CLAUDE.md docs-sync rule).

---

## 10. ADR — Phase 2 Closure ABI

- **Decision:** Synthesize a per-capturing-lambda **closure class with typed instance fields and a typed instance invoke method** on both backends (Option A), construct strongly-typed `System.Func`/`System.Action` (MSIL) and typed functional interfaces (JVM) for the invoke ABI, hoist captured `var`s into **typed heap cells**, and resolve FFI delegate/SAM targets from **reference-assembly / JDK metadata**.
- **Drivers:** (1) eliminate hot-path boxing and environment allocation; (2) maintain MSIL/JVM behavioral parity within a finite review budget; (3) degrade to boxing only for genuinely-polymorphic/erased cases, never the monomorphic primitive case.
- **Alternatives considered:**
  - *Option B — stack/by-ref closure struct:* rejected as primary mechanism — Lyric closures routinely escape; delegates require a heap target; no JVM by-ref-struct analog (breaks parity). Retained as a future escape-analysis-gated optimization only.
  - *Interim "typed args, keep `object[]` captures" (docs/52 Option B):* rejected — leaves the dominant capture-path allocation and box/unbox in place; strictly dominated by Option A; creates the uniform-ABI debt Principle 3 forbids.
- **Why chosen:** Option A is the only approach that provably removes both the environment allocation and per-capture/per-invoke boxing for the common monomorphic case on *both* targets, reuses each backend's existing class-synthesis machinery (MSIL in-bundle-generics D-progress-453/455; JVM `lowerClosure`), and converges the two backends (JVM is already most of the way there for captures) instead of diverging them.
- **Consequences:**
  - One synthesized type per capturing lambda → metadata/class-count growth (bounded: non-capturing lambdas stay static; canonicalized JVM interface names).
  - The lambda ABI becomes a stable, documented surface that FFI and the verifier depend on — changing it later is a breaking change requiring a decision-log entry.
  - CI gains required disassembly-based allocation checks — a new class of test the project must maintain.
  - `docs/53` is superseded by this grounded plan; the language reference's lambda ABI section must be updated to describe typed closure classes.
- **Follow-ups:**
  - Escape-analysis-gated stack/struct closures for provably-non-escaping lambdas (post-Phase-2, references Option B rationale here).
  - Generic/polymorphic lambda specialization beyond boxing (monomorphization of `[T] (T)->T` at hot call sites) — separate epic.
  - JVM `invokedynamic`/`LambdaMetafactory` adoption for SAM targets where it beats synthesized adapters (Stage 5 may stub with adapters first).
  - A decision-log entry (`docs/03-decision-log.md`) codifying this ADR as the backing entry for docs/52/53, flipping their status from proposal/thin-plan to specced.
