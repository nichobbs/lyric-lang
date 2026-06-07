# 44 — JVM Production-Readiness Remediation Plan

**Status:** Unbacked plan (audit + remediation sequencing). File a decision-log
entry to codify the band ordering and the G1 channel decision before band J1
lands.

**Method.** This plan was produced by auditing the **code as source of truth**
(docs and issues were treated as possibly-stale corroboration), cross-checked
against the open issue tracker and the JVM design docs, and **validated
empirically** by building and running real programs through `lyric build/test
--target jvm` on JDK 21. Every claim below is grounded in one of: a code
reference (`file:line`), an observed CLI result, a doc citation, or an open
issue number.

This is the JVM counterpart to `docs/41-self-hosted-compiler-gap-analysis.md`
(which **explicitly excludes JVM**, `docs/41` §1 line 24) and
`docs/33-platform-parity-remediation.md` (whose R1–R7 work shipped a narrow
20-program common-subset parity suite, `docs/33` §7). It defines what
"production-ready `--target jvm`" means and sequences the work to get there.

---

## 1. Executive summary

The self-hosted JVM backend (`lyric-compiler/jvm/`, ~600 KB of `.l` across 12
packages) is **real and partially working**, not a stub: a clean program with
records, unions, pattern matching, arithmetic, bitwise ops, `for`/`while`, and
string handling compiles to a runnable JAR and produces correct output under
`java`. Verified empirically:

- `lyric test --target jvm lyric-compiler/lyric/bitwise_self_test.l` →
  **10/10 pass**, executing real bytecode under `java`.
- A record + `union` + `match` program built with
  `lyric build --target jvm -o out.jar` ran under `java` and printed the
  correct results (`12`, `15`).

But the path is **MSIL-minus** and carries several **silent-miscompile** and
**user-facing-UX** defects that disqualify it from a production bar. The
headline problems:

1. **The user-facing JVM compile path is a strict subset of the language.**
   `lyric build/test --target jvm` runs through `jvm/bridge.l` →
   `jvm/codegen.l`, which **does not** weave aspects, lift lambdas, lower `?`
   propagation, erase `@cfg`, or emit generics/opaque/protected/wire/config
   types — all of which the MSIL bridge does. Closures, async, aspects, and
   `defer` either **panic** or **silently no-op**. (Verified: a closure program
   fails to build on `--target jvm`.)

2. **Silent miscompiles.** `Float` is emitted as JVM `double`
   (`jvm/codegen.l:261,302`); or-pattern variable binding is a no-op
   (`codegen.l:2060`); complex assignment targets (`member =`, `index =`) are
   silently dropped (`codegen.l:1442`); stdlib packages that fail JVM codegen
   are swallowed and only fail at runtime (`bridge.l:408-413`). These compile
   to **wrong-but-running** output rather than erroring.

3. **CLI UX is bootstrap-grade.** `lyric build --target jvm foo.l` (no `-o`)
   writes the JAR to `foo.dll` (`cli.l:712` always appends `.dll`), writes a
   spurious .NET `runtimeconfig.json` next to it (`cli.l:545`), and leaks
   advisory stdlib parse errors to stdout. `lyric run --target jvm` is not
   wired at all (#674).

4. **The self-hosted JVM pipeline is barely tested.** Of ~132
   `jvm/self_test_b*.l`, **all** are driven by F# `JvmLoweringB*Test.fs`
   wrappers that test the **emission library** (compiled by the F# stage-0
   emitter to .NET, then asked to *emit* a JAR) — **not** the self-hosted
   front-end → JVM pipeline. Only **4** programs (bitwise, conv-methods,
   pattern-lowering, auto-ffi-jvm) actually exercise `--target jvm`
   end-to-end in CI.

5. **F#-host and Maven debt.** The JVM byte-builder / constant pool route
   through `@externTarget` into F# host code (`jvm/_kernel/kernel.l:19,24,28`
   → `bootstrap/src/Lyric.Jvm.Hosts/JvmHosts.fs`) — exactly the pattern
   CLAUDE.md forbids for new boundaries, and an F#-residue parity gap the
   MSIL path already eliminated (#1492; `docs/41` H12). Automated Maven
   resolution is **non-functional**: the `[maven]` table is parsed only by F#
   `Manifest.fs` (absent from `manifest.l`), and the `resolver/` Java project
   is **orphaned** (no script, F#, Lyric, or CI references it). The only
   working JVM-dependency mechanism is the manual `LYRIC_FFI_JARS` env var.

6. **No JVM production-readiness epic exists.** Unlike .NET (#1470), JVM work
   lives as scattered "parity with MSIL #N" follow-ups. This plan proposes the
   missing umbrella.

**Verdict:** `--target jvm` is a *working demo of a language subset*, not a
production target. Closing the gap is tractable — much of the missing
capability already exists in `jvm/lowering.l` but is unwired from
`codegen.l`, and the architectural fix is to bring `jvm/bridge.l` up to
`msil/bridge.l`'s middle-end. The work is sequenced into bands J1–J7 below.

---

## 2. What works today (empirically verified)

| Capability | Evidence |
|---|---|
| Records, fields, constructors, accessors | `jvm/codegen.l:3166-3184`; built+ran |
| Unions / enums with payloads (sealed interface + case classes) | `codegen.l:75,3164,4928`; built+ran (`area(Circle/Rect)` correct) |
| Pattern matching (wildcard/binding/literal/range/ctor/record/tuple/type-test/or) | `codegen.l:1640-2061`; ran |
| Interfaces + `impl` | `codegen.l:4942-4974` |
| try / catch / finally / throw | `codegen.l:3727-3729,3899-3924` |
| Bitwise `.and/.or/.xor/.shl/.shr` (Int + Long) | `codegen.l:3367-3405`; `bitwise_self_test.l` 10/10 |
| String interpolation | `codegen.l:949` |
| Arithmetic, locals, if/while/for/loop | `codegen.l:3490-3676` |
| `requires:` / `ensures:` runtime asserts (via elaborator) | `bridge.l:153` |
| Distinct types | `lowering.l:2215`; `codegen.l:4924` |
| Auto-FFI into JDK classes (read from `java.base.jmod`) | `auto_ffi.l` + `zip_reader.l`/`class_reader.l`/`deflate.l`; `auto_ffi_jvm_self_test.l` green |
| End-to-end `lyric build --target jvm -o x.jar` → runnable JAR | built+ran (`file` reports "Java archive data"; correct output) |

This is a substantial, genuinely-working core. The bands below are about the
gap between this core and the full language the reference defines for both
targets.

---

## 3. The two-path architecture (read this first)

Understanding the gaps requires distinguishing two JVM code paths:

- **Path A — emission library (well-tested).** `jvm/lowering.l` +
  `jvm/classfile.l` + `jvm/bytecode.l` are a bytecode-emission library. The
  ~132 `self_test_b*.l` programs *call this library* to emit class files; the
  F# `JvmLoweringB*Test.fs` wrappers compile those programs **with the F#
  stage-0 emitter to .NET**, run them, and `java -jar` the JAR they emit. This
  proves the *library* works. `lowering.l` contains working `lowerOpaqueType`,
  `lowerOpaqueFacade` (`lowering.l:2554`, D-progress-226), etc.

- **Path B — the user compile pipeline (under-tested, MSIL-minus).**
  `lyric build/test --target jvm` runs `jvm/bridge.l` → `jvm/codegen.l`
  (AST→IR) → `jvm/lowering.l` (IR→class) → JAR. **This** is what users invoke,
  and it is where the gaps live: `codegen.l` erases generics and **no-ops** the
  item kinds that `lowering.l` can actually emit, and `bridge.l` omits the
  middle-end stages `msil/bridge.l` runs.

**Key consequence:** capability existing in Path A does **not** mean it works
for users. E.g. `lowering.l` can emit opaque types, but `codegen.l:4938`
no-ops `IOpaque`, so `--target jvm` silently drops opaque-type bodies. Several
"shipped" claims in `docs/18`/`docs/04` describe Path A; the
production-readiness bar is Path B.

---

## 4. Findings by severity

Issue numbers reference the existing tracker; "(new)" marks gaps with no
tracking issue today (band J0 files them).

### BLOCKERS (silent miscompile, or a defined-for-both-targets construct is unusable)

| ID | Finding | Evidence | Issue |
|---|---|---|---|
| B-1 | Closures / lambdas panic on the user path (`ELambda` unhandled in `codegen.l`); no lambda-lifting stage in `bridge.l` | `codegen.l:985-989`; empirically `--target jvm` closure build fails | #1675 (closure dispatch) |
| B-2 | `async`/`await`/`spawn`/`?` lower to **synchronous pass-throughs** — wrong semantics, not just missing (no future, no Err/None short-circuit) | `codegen.l:912-941` | #2469 (generators), (new: sync-stub) |
| B-3 | Aspects are **not woven** on JVM (`bridge.l` never imports `Lyric.Weaver`); `IAspect` no-ops | `bridge.l:8-25`; `codegen.l:4994` vs `msil/bridge.l:168` | (new) |
| B-4 | `Float` emitted as JVM `double` — silent precision/semantics bug | `codegen.l:261,302` | #1615 (int-opcode fallthrough), (new: Float) |
| B-5 | Complex assignment targets (`obj.field = …`, `arr[i] = …`) silently dropped (value popped) | `codegen.l:1441-1446` | (new) |
| B-6 | stdlib packages that fail JVM codegen are swallowed → runtime `NoSuchMethodError` instead of build error | `bridge.l:408-413`; observed `Std.File`/`Std.Errors` "codegen unsupported" notes | (new) |
| B-7 | Named-argument record construction can corrupt cross-typed fields (MSIL `reorderCtorNamedArgs` pass not ported) | per #1793 | #1793 |
| B-8 | Union construction emits a call to a non-existent factory in some paths → `NoSuchMethodError` | per #1675 | #1675 |
| B-9 | No auto-FFI resolution for `extern type` method calls beyond the JDK-class fast path on some receivers; user `extern type` libraries mis-bind | #1708; `auto_ffi.l` JDK-first | #1708 |
| B-10 | `lyric build --target jvm foo.l` (no `-o`) writes the JAR as `foo.dll`; spurious .NET `runtimeconfig.json` emitted | `cli.l:712`, `cli.l:545`; observed | (new) |
| B-11 | JUnit tests do not actually execute on JVM — `lyric test --jvm` annotates `@LyricTest` but `LyricTestEngine` is deferred; generated test bodies are stub `return` | `test_engine.l:17-21`; `docs/18` Q-J007 | #676 |

### MAJORS (real parity gap or missing subsystem)

| ID | Finding | Evidence | Issue |
|---|---|---|---|
| M-1 | Generics **erased to `Object`** (no `Signature` attrs, no generic instantiation); Option/Result type args erased, unlike MSIL true generics | `codegen.l:278`; `docs/18` §6.1/§10 | #1707, #2574 |
| M-2 | `defer` panics on JVM | `codegen.l:3716-3724` | #1833 |
| M-3 | Opaque / protected / wire / config types recognized but **not emitted** (no-op), though `lowering.l` can emit opaque | `codegen.l:4938,4940,4978,4992` | (new; opaque ≈ low-effort wiring) |
| M-4 | `@cfg(feature=…)` erasure not applied on JVM (`bridge.l` has no cfg stage) | `bridge.l`; vs `msil/bridge.l:402` | #2444 (target-gate seam) |
| M-5 | Cross-package / generic-type monomorphization is same-package only on JVM | `bridge.l:159` | #1707 |
| M-6 | **Maven self-hosting absent:** `[maven]` parsed only by F# `Manifest.fs`; `manifest.l` cannot read ecosystem `[maven]` tables (`lyric-web`, `lyric-mq`, `lyric-grpc`, `lyric-lambda`, …) | `manifest.l` (no `[maven]`); `Manifest.fs:121+` | #1622/#1708 cluster |
| M-7 | **Maven resolver orphaned:** `resolver/` Java project not built/invoked by any script, F#, Lyric, or CI; only `LYRIC_FFI_JARS` works | `resolver/pom.xml`; no references | #673 |
| M-8 | **F#-host kernel debt:** JVM byte-builder + constant pool via `@externTarget` into `Lyric.Jvm.Hosts` (F#), on the deletion schedule | `jvm/_kernel/kernel.l:19-28` → `JvmHosts.fs`; `docs/41` H12 | (Band 5 / #1470 parity) |
| M-9 | `Std.Hash` has **no JVM host** (`_kernel/hash_host.l` exists; `_kernel_jvm/hash_host.l` does not) yet `Std.Hash` is imported by `cli.l` | filesystem; agent-verified | (new) |
| M-10 | `_kernel_jvm/` is **never loaded** by the self-hosted type-resolution source loader; only the F# emitter honors it. Self-hosted JVM type-checking sees only .NET kernel declarations | `SelfHostedBridge.fs:182-222`, `emitter.l:743-790` | (new) |
| M-11 | `lyric-storage` local-fs backend has no JVM kernel; `ProcessCaptureHost.runCaptureWithTimeout` unimplemented on JVM | #1444/#1840, #1065 | #1444, #1840, #1065 |
| M-12 | Async generators are eager "collect-all", not lazy `IAsyncEnumerable` | `lowering.l:3493-3518` | #2469 |
| M-13 | Range/refined types erased to `JInt`, no bounds checks | `codegen.l:283` | (new) |
| M-14 | Self-hosted JVM **pipeline** coverage is ~4 programs vs 132 library self-tests; the front-end → JVM path is barely exercised | `ci.yml` (4 native `--target jvm` steps) | #2000, #2595 (per-test) |
| M-15 | `extern type` robustness gaps: `T.new()` on abstract type → runtime `InstantiationError` (no compile guard); `findBestInstanceMethod` stops before `java/lang/Object` | #2215, #2219 | #2215, #2219 |
| M-16 | Slice ABI fork: F#-built `Lyric.Stdlib.dll` uses `!0[]` arrays for generic `slice[T]` while self-hosted callers are List-backed | #2592 | #2592 |
| M-17 | `scope` (structured concurrency) panics on JDK 24+ (StructuredTaskScope became an interface); supports 21–23 only | `lowering.l:3904-3914` | #2263 |
| M-18 | JVM distribution: no `lyric run --target jvm` (#674), no GraalVM native-image path (#675/#1975), no `lyric bench --target jvm` (#680) | #674, #675, #1975, #680 | as listed |

### MINORS (coverage, polish, diagnostics)

| ID | Finding | Evidence | Issue |
|---|---|---|---|
| m-1 | loop `invariant:` is a runtime no-op on JVM | `codegen.l:3732` | (new) |
| m-2 | Module-level `val` not emitted as `static final` on JVM (M5.2 stage-3 parity) | per #2210 | #2210 |
| m-3 | `out`/`inout` parameter parity (holder-array lowering) | #1763 | #1763 |
| m-4 | intra-impl `self.m`/bare `m` calls | #1722 | #1722 |
| m-5 | nested-generic union case construction (`Result[Option[T],E]`) | #1707 | #1707 |
| m-6 | JVM regex daemon-thread timeout shim | #1103 | #1103 |
| m-7 | `splitPathList` splits on `:` and `;`, breaking Windows `LYRIC_FFI_JARS` | #2214 | #2214 |
| m-8 | negative `loadClass` results not cached (repeated JMOD scans) | #2181 | #2181 |
| m-9 | `findBestConstructor` implicit score threshold vs explicit `>= 0` | #2226 | #2226 |
| m-10 | `Std.Time.sleepMillis` is a JVM stub; doc omits the limitation | #2101 | #2101 |
| m-11 | Doc contradictions: Q-J012/Q-J013 marked "shipped" in `docs/36` but "NOT present / Phase 6" in `docs/31`/`docs/03`; self-test counts drift (B124/B125/B130) across `docs/18`/`docs/33`/`docs/04`; parity count "20-program" vs "22-program" | `docs/31:409-434` vs `docs/36:123-150`; count drift | (Band J0 docs sweep) |

---

## 5. Remediation bands

Bands are ordered by dependency and risk. **Stop-the-bleeding (J1) before
new capability (J2–J4).** Each band ends with an acceptance criterion that a
self-test enforces in CI on `--target jvm`.

### J0 — Establish the umbrella, split codegen, stop the doc drift (prereq, ~days)
- File a single **JVM production-readiness epic** (the missing #1470 analog)
  linking every issue in §4; convert each "(new)" finding into a tracked issue.
  (Done: epic #2663 with band sub-tasks #2664–#2670.)
- **Split `jvm/codegen.l` (~5,060 lines) into ~6 files under the same
  `Jvm.Codegen` package**, along its existing section boundaries:
  `codegen_types.l` (`FuncCtx`/sigs/slot+type lookup/`typeExprToJvm`/emit
  helpers), `codegen_exprs.l` (`lowerExpr`, comparisons, bool conditions,
  interpolation, box), `codegen_match.l` (match + pattern test/bind),
  `codegen_stmts.l` (`lowerStmt`, `lowerAssignExpr`, blocks, try/catch),
  `codegen_calls.l` (calls, builtins, auto-FFI, construction, method calls),
  `codegen_items.l` (`lowerFunc`/`lowerRecord`/`lowerUnion`, generators,
  `codegenPackage`). This is precedented (`Lyric.Parser` = 5 files,
  `Lyric.TypeChecker` = 9, all one package; intra-package cross-file mutual
  recursion already works) and is a pure mechanical refactor proven by the
  existing self-tests. It is the **prerequisite that makes Track A
  parallelizable** (§6) — land it *before* J1–J4 branch off so everyone
  rebases onto the new layout once. Residual hotspot after the split: the
  `lowerExpr` mega-function (~600 lines, `codegen.l:439-1034`) that J2
  (`ELambda`) and J4 (async) both edit — decompose by expr-kind sub-dispatch
  only if that contention actually bites.
- Resolve the doc contradictions (m-11): reconcile Q-J012/Q-J013 to their true
  shipped state, fix the self-test-count and parity-count drift across
  `docs/18`/`docs/31`/`docs/33`/`docs/04`/`docs/03`, and cross-link this doc
  from `docs/41` §8 and `docs/33`. (Done: cross-links landed in #2656.)
- **Decision required (G1, `docs/36`):** is `--target jvm` a v1.0 SemVer
  channel, or a Phase-6 ecosystem target with independent versioning? This
  gates how strict the acceptance bar (J7) is. Land a decision-log entry.

### J1 — Stop the silent miscompiles (highest priority, scoped, low-risk)
These produce wrong-but-running output today and must fail loudly or be fixed:
- B-4: emit `Float` as JVM `float` (`freturn`/`fload`/`F` descriptors), not
  `double`; add a Float round-trip self-test.
- B-5: implement `member =` / `index =` assignment lowering (or, if genuinely
  out of scope short-term, emit a hard error — never a silent pop).
- B-6: make stdlib codegen failures **fatal** for the packages a build
  actually references; keep the "skipped" note only for genuinely-unreached
  packages, and surface which symbol failed.
- or-pattern binding no-op (m-1 sibling, `codegen.l:2060`): bind the variable
  or reject the pattern.
- B-7/B-8: port the MSIL `reorderCtorNamedArgs` pass; fix union construction to
  `new` + `invokespecial <init>`.
- B-10: make the single-file build output extension and `runtimeconfig.json`
  emission **target-aware** (`.jar` + no `runtimeconfig.json` for JVM); stop
  leaking advisory stdlib parse errors to stdout on a successful build.
- **Acceptance:** a `silent_miscompile_guard_jvm_self_test.l` covering Float,
  complex assignment, named-arg records, union construction, and or-patterns,
  run in CI on `--target jvm`.

### J2 — Bring `jvm/bridge.l` to MSIL-bridge parity (architectural, the linchpin)
Port the middle-end stages `msil/bridge.l` runs that `jvm/bridge.l` omits:
- Aspect weaving (`Lyric.Weaver.weaveFileWithDiags`) — B-3.
- Lambda lifting — unblocks B-1.
- `?` / `try` error-propagation lowering — part of B-2.
- `@cfg` erasure (`Cfg.applyCfgErasure`) — M-4.
- Cross-package generic collection into mono — M-5.
- **Acceptance:** the existing weaver/cfg/propagate self-tests run on
  `--target jvm`; a closure program builds and runs under `java`.

### J3 — Wire the capabilities `lowering.l` already has (low-effort parity)
- M-3: call the existing `lowerOpaqueType`/`lowerOpaqueFacade`/protected/wire
  lowering from `codegen.l`'s `IOpaque`/`IProtected`/`IWire`/`IConfig` arms
  (the lowering exists and is self-tested; only the dispatch is missing).
- M-2: implement `defer` via try/finally (mirror MSIL #1477).
- m-2: module-level `val` as `static final`.
- **Acceptance:** opaque/protected/wire/defer self-tests on `--target jvm`.

### J4 — Generics, async, and the harder semantics (largest effort)
- M-1/M-5/m-5: decide and implement the JVM generics strategy (erased +
  `checkcast` is acceptable for v1; document the Valhalla deferral, Q-J001) and
  close the nested-generic-union and cross-package gaps. At minimum, make the
  erased model **correct** (it currently is for the tested subset).
- B-2/M-12: real async lowering (futures / virtual threads per `docs/18` §14)
  and lazy generator synthesis — parity with MSIL #2070 Phase 5.
- M-17: JDK 24+ `scope` support.
- **Acceptance:** async + generator + generics self-tests on `--target jvm`.

### J5 — Eliminate F# host debt and ship Maven (self-hosting + ecosystem)
- M-8: replace `Lyric.Jvm.Hosts` (`JvmHosts.fs`) byte-builder/constant-pool
  with a pure-Lyric `_kernel_jvm` boundary (mirror the MSIL ByteWriter win,
  #1492). No `@externTarget` into F# host code.
- M-6/M-7: port `[maven]` parsing into `manifest.l`; build a self-hosted Maven
  resolution path (revive or replace `resolver/`), wired into
  `lyric build --target jvm`. Until then, document `LYRIC_FFI_JARS` as the only
  supported mechanism rather than implying automated resolution.
- M-15/m-7/m-8/m-9: `extern type` robustness (abstract-type guard,
  `java/lang/Object` walk, path-split, negative-cache), Windows path handling.
- **Acceptance:** an ecosystem library with a `[maven]` table builds and runs
  on `--target jvm` from a clean checkout with no manual classpath.

### J6 — stdlib JVM kernel parity (cross-platform stdlib actually works on JVM)
- M-9: add `_kernel_jvm/hash_host.l` (Java SHA-512/hex).
- M-10: make the self-hosted type-resolution source loader **target-aware** so
  it loads `_kernel_jvm/` for JVM builds (today it only ever loads `_kernel/`).
- M-11: `lyric-storage` local-fs JVM kernel; `ProcessCaptureHost` on JVM;
  M-16 slice-ABI reconciliation (#2592); m-6/m-10 regex/time stubs.
- **Acceptance:** a self-hosted JVM self-test that imports a `_kernel_jvm`-only
  module (e.g. `Std.File`/`Std.Http`/`Std.Hash`) builds and runs under `java`
  in CI — closing the "no native JVM test depends on `_kernel_jvm`" gap.

### J7 — Testing, distribution, and the acceptance gate
- M-14: expand the self-hosted `--target jvm` pipeline suite well beyond the
  current 4 programs; convert representative `self_test_b*.l` (or new
  `@test_module` tests) to run through the **compile pipeline**, not just the
  emission library, and delete the F# `JvmLoweringB*Test.fs` wrappers as the
  native path subsumes them.
- B-11/#676: ship the full JUnit 5 `LyricTestEngine` so `lyric test --jvm`
  executes tests.
- M-18: `lyric run --target jvm` (#674), `lyric bench --target jvm` (#680),
  GraalVM native-image (#675/#1975).
- Make the native JVM CI steps **fail loud** (they currently `::warning` +
  `exit 0` on a missing bundle, so an infra regression silently drops JVM
  coverage).
- **Acceptance gate:** the per-feature parity suite (#1495) runs the **full**
  worked-examples set on `--target jvm`, all green, with no soft-skips; the
  JVM path has zero `@externTarget`-into-F# references; `lyric build/run/test
  --target jvm` work end-to-end from a clean checkout.

---

## 6. Parallelization and sequencing

The bands are **partially parallelizable across ~3 tracks**, bounded by two
constraints: logical dependencies, and shared-file contention (J1–J4 all edit
`jvm/codegen.l` and `jvm/bridge.l`). The J0 codegen split (§5) is what unlocks
most of the available parallelism; do it first.

**Tracks (run concurrently after J0):**

| Track | Bands | Primary files | Parallel? |
|---|---|---|---|
| **A — codegen core** | J1 → J2 → J3 → J4 | `codegen_*.l`, `bridge.l`, `lowering.l` | internally serial (J1‖J3 possible after the split); the critical path |
| **B — self-hosting/ecosystem** | J5 | `jvm/_kernel/kernel.l`, `manifest.l`, `resolver/` | fully parallel with A & C |
| **C — stdlib kernel + infra** | J6 + J7-infra | `_kernel_jvm/*`, source loader (`emitter.l`), CI, `cli.l` run/bench wrappers | parallel with A & B |
| **D — acceptance gate** | J7 gate | per-feature parity suite (#1495) | last — after A/B/C converge |

**Dependencies to respect:**

- **J2 is the linchpin.** It ports lambda-lifting (unblocks closures), aspect
  weaving (unblocks aspects), and `?`-propagation (feeds J4 async). Land it
  early on Track A.
- **J4 builds on J2** — async reuses J2's `?`-propagation lowering; generics
  reuse J2's cross-package monomorphization.
- **J6's source-loader fix comes first within Track C.** Making the
  self-hosted source loader target-aware (so it loads `_kernel_jvm/`) is a
  prerequisite for verifying any cross-platform stdlib module on JVM, and
  underpins J7's acceptance tests.
- **J7's acceptance gate (Track D) depends on everything** and runs last.

**Residual serial core (irreducible):** even after the codegen split, the
`lowerExpr` function (`codegen.l:439-1034`) is edited by both J2 (`ELambda`)
and J4 (async), and the J2→J4 logical dependency holds — so Track A
(J1→J2→J4) is the critical path. Realistic throughput is ~3 tracks in flight
(≈3× over strict sequential), bounded by Track A's length.

## 7. Definition of "production-ready `--target jvm`"

1. Every language construct the reference defines for both targets compiles and
   runs correctly on JVM, or is a tracked, dated, documented exception (no
   silent no-ops, no panics on valid programs, no wrong-but-running output).
2. `lyric build`, `lyric run`, and `lyric test` all support `--target jvm` with
   correct artifacts (JARs, not `.dll`, no stray `runtimeconfig.json`).
3. The cross-platform stdlib works on JVM (the `_kernel_jvm` boundary is loaded
   and complete for every module the reference marks cross-platform).
4. Ecosystem `[maven]` dependencies resolve automatically; no manual classpath.
5. Zero F#-host externs on the JVM runtime path (`Lyric.Jvm.Hosts` deleted).
6. CI exercises the self-hosted front-end → JVM **pipeline** across the full
   worked-examples suite, failing loud, with the JUnit engine executing tests.

---

## 8. Open decisions for the maintainer

- **G1 (gating):** Is `--target jvm` a v1.0 SemVer-guaranteed channel, or a
  Phase-6 target with independent versioning? (`docs/36` §G1.) Determines the
  J7 bar and whether JVM blocks the v1.0 release.
- **Generics on JVM:** accept erased + `checkcast` for v1 (recommended; matches
  `docs/18`), or invest in specialised helpers / await Valhalla (Q-J001/Q-J003)?
- **Maven resolver:** revive the orphaned Java `resolver/` (pragmatic, but adds
  a JVM build dependency), or build a pure-Lyric resolver (aligns with the
  self-hosting standard, larger effort)?

---

## 9. Issue cross-reference

Blockers: #1675, #1793, #1708, #676, plus the new silent-miscompile tickets
(Float, complex-assignment, swallowed-codegen, CLI extension/runtimeconfig).
Major clusters: generics (#1707, #2574), kernel parity (#1444, #1840, #1065,
#2592), async/generators (#2469, #2070), FFI/Maven (#1622, #673, #2215, #2219),
distribution (#674, #675, #1975, #680), F#-host elimination (`docs/41` H12,
#1470 parity). Gating: #1495 (per-feature parity suite), #859 (Band-7
acceptance gate). There is currently **no** JVM umbrella epic — J0 creates it.
