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
| B-1 | ~~Closures / lambdas panic on the user path (`ELambda` unhandled in `codegen.l`)~~ **Fixed (D-progress-474):** `ELambda` lowers to a `<pkg>$Lambda$<n>` inner class implementing a package-shared `Lyric$Lambda` functional interface (uniform `Object[]`-packing ABI); capture analysis binds free `val`/param references as ctor fields; call sites route lambda-typed callees through `invokeinterface`. `val`/param by-value capture done; by-reference `var` capture deferred. **#2864 (resolved):** lambdas inside record-method / protected-entry / wire-binding bodies now thread the real package closure accumulator (no more throwaway → no silent dropped closure class); bare-field captures inside instance-method bodies are captured by value via `selfFieldType`. | `codegen/02_exprs.l` (`lowerLambda`), `codegen/04_calls.l` (`lowerLambdaInvoke`), `codegen/06_items.l` (`lowerRecord`/`buildProtected`/`buildWire`), `lowering.l` (`lowerClosure`) | #2665, #2864 (resolved) |
| B-2 | `async`/`await`/`spawn`/`?` lower to **synchronous pass-throughs** — wrong semantics, not just missing (no future, no Err/None short-circuit) | `codegen.l:912-941` | #2469 (generators), (new: sync-stub) |
| B-3 | Aspects are **not woven** on JVM (`bridge.l` never imports `Lyric.Weaver`); `IAspect` no-ops | `bridge.l:8-25`; `codegen.l:4994` vs `msil/bridge.l:168` | (new) |
| B-4 | ~~`Float` emitted as JVM `double` — silent precision/semantics bug~~ **Fixed (D-progress-464):** real 32-bit `float`. | `codegen/01_types.l`,`02_exprs.l` | #1615, #2664 |
| B-5 | ~~Complex assignment targets (`obj.field = …`, `arr[i] = …`) silently dropped (value popped)~~ **Fixed (D-progress-464).** | `codegen/05_stmts.l` | #2664 |
| B-6 | ~~stdlib packages that fail JVM codegen are swallowed → runtime `NoSuchMethodError` instead of build error~~ **Fixed (D-progress-465):** function-level call reachability + fatal `error[J002]` for referenced packages. | `bridge.l` `compileToJarBundled` | #2664 |
| B-7 | ~~Named-argument record construction can corrupt cross-typed fields (MSIL `reorderCtorNamedArgs` pass not ported)~~ **Fixed (D-progress-464):** `orderCtorArgs` permutes named args to field order. | `codegen/04_calls.l` | #1793, #2664 |
| B-8 | ~~Union construction emits a call to a non-existent factory in some paths → `NoSuchMethodError`~~ **Fixed (D-progress-464):** field-bearing + nullary cases emit `new`+`invokespecial`. | `codegen/02_exprs.l`,`04_calls.l` | #1675, #2664 |
| B-9 | No auto-FFI resolution for `extern type` method calls beyond the JDK-class fast path on some receivers; user `extern type` libraries mis-bind | #1708; `auto_ffi.l` JDK-first | #1708 |
| B-10 | ~~`lyric build --target jvm foo.l` (no `-o`) writes the JAR as `foo.dll`; spurious .NET `runtimeconfig.json` emitted~~ **RESOLVED** | `cli.l:712`, `cli.l:545`; observed | #2664 (resolved) |
| B-11 | JUnit tests do not actually execute on JVM — `lyric test --jvm` annotates `@LyricTest` but `LyricTestEngine` is deferred; generated test bodies are stub `return` | `test_engine.l:17-21`; `docs/18` Q-J007 | #676 |
| B-12 | ~~Record instance methods (`RMFunc`) emitted as **static** but called via `invokevirtual` → `VerifyError "Expecting non-static method"`; records-with-methods unusable~~ **Fixed (D-progress-475):** `lowerRecord` now lowers each `RMFunc` through `lowerRecordMethod` as a true non-static instance method (slot 0 = `this`, `selfClass` field reads, generic params erased to `Object` matching the registered `<class>#<method>` `invokevirtual` sig); non-static methods route through `lowerFuncForClass` so slot 0 is typed as the record class in the StackMapTable (also hardens protected entries). | `codegen/06_items.l` (`lowerRecord`/`lowerRecordMethod`/`registerInstanceSigErased`), `lowering.l` (`lowerRecord`) | #2865 |
| B-13 | ~~A function/method whose tail `if`/`else` (or `match`) `return`s on every arm got a stray trailing void `return` appended → `VerifyError`~~ **Fixed (D-progress-476):** the `if`/`match` lowering no longer lands the unreachable `afterL` join label (its `StackMapTable` frame pointed past the method body) when every arm terminates, and an AST-level `blockTerminates` predicate is consulted alongside `endsWithReturn` at every function-body return-decision point so the implicit return is suppressed when control is already terminated. The implicit-return / fall-off path (`Unit` fall-off, else-less `if` + tail value) is unchanged. | `codegen/02_exprs.l` (`lowerIfExpr`), `codegen/03_match.l` (`lowerMatchExpr`), `codegen/06_items.l` (`blockTerminates`) | #2870 |

### MAJORS (real parity gap or missing subsystem)

| ID | Finding | Evidence | Issue |
|---|---|---|---|
| M-1 | ~~Generics **erased to `Object`**; the erased model was **incorrect** — generic `Result`/`Option` and user generic records/unions VerifyError'd at class load (construction did not box primitive payloads into the `Object` field; match-extraction read the `Object` field without `checkcast` + unbox)~~ **DONE (J4 M-1, D-progress-473).** Generic type params now erase to `java/lang/Object` via `typeExprToJvmErased` (decl `generics` threaded through `lowerUnion`/`lowerRecord`/`collectFileCases`); construction boxes a primitive payload into the `Object` field (`coerceArgTo` primitive→ref); match-extraction + erased-operand use-sites (`reconcileCmpOperands` for compare/arith, function-return/`SReturn` coercion, mixed-arm `match` result boxing, `return`-terminated arms skipped) `checkcast` + unbox to the binding's concrete type. The `?`-propagation JVM runtime now runs. Verified by `generic_jvm_self_test.l` (13 cases). Async/generic interplay (M-12) and `scope` (M-17) remain. Still erased (no `Signature` attrs / reified generics — Q-J001), matching `docs/18` §6.1/§10. | `jvm/codegen/{01_types,02_exprs,03_match,04_calls,06_items}.l` | #1707, #2574, #2667 |
| M-2 | ~~`defer` panics on JVM~~ **DONE (J3, D-progress-472).** `defer { D }` runs `D` on every non-exception exit (normal fall-off, early `return`, `break`/`continue`) plus exception unwind, mirroring MSIL #1477: statement blocks route through `lowerBlockStmtsFrom`/`lowerDeferRegion` and value-producing blocks through `lowerBlockExprWithDefer`; the suffix after a defer runs inside a catch-all-rethrow region, and `FuncCtx.deferStack` lets early transfers replay the pending blocks first. | `codegen/05_stmts.l` | #1833 |
| M-3 | ~~Opaque / protected / wire / config types recognized but **not emitted** (no-op)~~ **DONE (J3, D-progress-472).** `06_items.l`'s `IOpaque`/`IProtected`/`IWire` arms now dispatch to the real lowering: opaque → `lowerOpaqueType`/`lowerOpaqueFacade` (construction + `$<name>()`-accessor field reads, public ctor for in-package construction); protected → record-shaped class (field-args ctor + lock-wrapped instance entries; bare-name field reads/writes resolve via `selfClass`); wire → `lowerWire` DI factory (`bootstrap()` + exposed-binding accessors, callable as `AppWire.bootstrap()`/`AppWire.<binding>()`). `IConfig` stays an intentional no-op (DI-phase-consumed, parity with MSIL). | `codegen/06_items.l`, `lowering.l` | (#2666) |
| M-4 | `@cfg(feature=…)` erasure not applied on JVM (`bridge.l` has no cfg stage) | `bridge.l`; vs `msil/bridge.l:402` | #2444 (target-gate seam) |
| M-5 | Cross-package / generic-type monomorphization is same-package only on JVM | `bridge.l:159` | #1707 |
| M-6 | **Maven self-hosting absent:** `[maven]` parsed only by F# `Manifest.fs`; `manifest.l` cannot read ecosystem `[maven]` tables (`lyric-web`, `lyric-mq`, `lyric-grpc`, `lyric-lambda`, …). **Parsing slice DONE (#2668):** `manifest.l` now parses `[maven]` / `[maven.options]` into `MavenSection` (`MavenEntry` + `repositories` default `["central"]` + optional `java_version`), mirroring `[nuget]`; covered by `manifest_self_test.l`. The resolution/download path (M-7) remains. | `manifest.l` `assembleMaven`; `Manifest.fs:121+` | #1622/#1708 cluster |
| M-7 | **Maven resolver orphaned:** `resolver/` Java project not built/invoked by any script, F#, Lyric, or CI; only `LYRIC_FFI_JARS` works | `resolver/pom.xml`; no references | #673 |
| M-8 | **F#-host kernel debt:** JVM byte-builder + constant pool via `@externTarget` into `Lyric.Jvm.Hosts` (F#), on the deletion schedule | `jvm/_kernel/kernel.l:19-28` → `JvmHosts.fs`; `docs/41` H12 | (Band 5 / #1470 parity) |
| M-9 | ~~`Std.Hash` has **no JVM host**~~ **DONE (J6).** `lyric-stdlib/std/_kernel_jvm/hash_host.l` added: `MessageDigest.getInstance("SHA-512").digest(...)` + `HexFormat.of().withUpperCase().formatHex(...)` via JVM auto-FFI (`extern type`, no F# shim). Verified by `hash_jvm_self_test.l` (3 NIST vectors) under `java`. | `_kernel_jvm/hash_host.l` | DONE |
| M-10 | ~~`_kernel_jvm/` is **never loaded** by the self-hosted source loader~~ **DONE (J6).** `emitter.l:findStdlibSourcesForTarget(forJvm)` prefers `_kernel_jvm/<module>_host.l` and falls back to `_kernel/<module>_host.l` only when no JVM host exists; `emitJvmInProcess` threads `forJvm = true`. Required JVM `slice[Byte]↔byte[]` interop fixes in `codegen.l` (auto-FFI arg/return byte-array coercion, primitive-array index/length) and a String `==`/`!=` value-comparison fix. | `emitter.l`, `jvm/codegen.l`, `jvm/auto_ffi.l` | DONE |
| M-11 | `ProcessCaptureHost` on JVM (#1065) — **design done, codegen-blocked on #3307.** The production design is pure JVM auto-FFI (`java.lang.Runtime.exec(String)` + incremental `InputStream.available()`-bounded drain into a `ByteArrayOutputStream` + `Process.isAlive()`/`System.currentTimeMillis()` timeout poll + `destroyForcibly()`), returning a Lyric `ProcessCaptureResult` record like the .NET kernel — no F#/Java shim (the never-built `lyric.stdlib.jvm.*` shim plan is removed from the kernel doc). It cannot land because every drain/poll loop carries an extern handle across the loop back-edge and the JVM backend types extern-type locals as `java/lang/Object` in the `StackMapTable` frame → `VerifyError` (#3307, `jvm/codegen/*`). `lyric-storage` local-fs JVM kernel (#1444/#1840) **BLOCKED on M-4** (JVM `@cfg(feature=…)` erasure, #2444): `storage.l` hard-imports `Storage.Kernel.Net` and its local-fs data plane calls those `host*` primitives directly, so a JVM backend needs per-target import erasure that does not exist on JVM yet. | `_kernel_jvm/process_capture_host.l`; blockers #3307 + #2444 | #1065 (blocked #3307); #1444, #1840 (blocked #2444) |
| M-12 | Async generators are eager "collect-all", not lazy `IAsyncEnumerable` | `lowering.l:3493-3518` | #2469 |
| M-13 | Range/refined types erased to `JInt`, no bounds checks | `codegen.l:283` | (new) |
| M-14 | Self-hosted JVM **pipeline** coverage is ~4 programs vs 132 library self-tests; the front-end → JVM path is barely exercised | `ci.yml` (4 native `--target jvm` steps) | #2000, #2595 (per-test) |
| M-15 | `extern type` robustness gaps: `T.new()` on abstract type → runtime `InstantiationError` (no compile guard); `findBestInstanceMethod` stops before `java/lang/Object` | #2215, #2219 | #2215, #2219 |
| M-16 | Slice ABI fork: F#-built `Lyric.Stdlib.dll` uses `!0[]` arrays for generic `slice[T]` while self-hosted callers are List-backed | #2592 | #2592 |
| M-17 | `scope` (structured concurrency) panics on JDK 24+ (StructuredTaskScope became an interface); supports 21–23 only | `lowering.l:3904-3914` | #2263 |
| M-18 | JVM distribution: ~~no `lyric run --target jvm` (#674)~~ **partially DONE** (`cli_run.l` builds the bundled JAR via the in-process `Jvm.Bridge` and execs `java -jar`; the no-arg / stdout path works, but a `main(slice[String])` taking arguments hits a JVM `VerifyError` and the `Int` return is **not** propagated to the process exit code — both tracked in #3303); `lyric bench --target jvm` (#680) dispatch is **wired but blocked** on JVM `Std.Time` support (#3302), so #680 stays open; GraalVM native-image path (#675/#1975) still outstanding | #675, #1975, #3302, #3303 | #674 (no-arg path) ✅; #680 open (#3302); #675/#1975/#3303 open |

### MINORS (coverage, polish, diagnostics)

| ID | Finding | Evidence | Issue |
|---|---|---|---|
| m-1 | loop `invariant:` is a runtime no-op on JVM | `codegen.l:3732` | (new) |
| m-2 | ~~Module-level `val` not emitted as `static final` on JVM~~ **DONE (J3, D-progress-472).** A module-level `val NAME = expr` emits a `public static final` field on the package host class, initialised in a synthesised `<clinit>`; bare references resolve to `getstatic <hostClass>.<name>` from any function in the package (collected by `collectFileVals`, threaded via `FuncCtx.moduleVals`). Mirrors the MSIL `.cctor` static-field path. | `codegen/06_items.l`, `lowering.l` | #2210 |
| m-3 | ~~`out`/`inout` parameter parity (holder-array lowering)~~ **DONE for free functions (#1763).** A free function's `out`/`inout` parameter of element type T is lowered to a single-element JVM *holder array* (`[I`, `[J`, `[Ljava/lang/String;`, …): the descriptor declares the array type; on entry the callee unwraps `holder[0]` into a value slot and every assignment writes through to `holder[0]` (centralised in `emitStoreLocalWriteThrough`, so no return-time epilogue is needed); the call site (`lowerStaticCallWithHolders`) allocates a holder pre-filled with the caller's local, passes it, and copies element 0 back after the call. `JvmFuncSig.paramModes` carries the declared modes so call sites know which arguments to wrap; `FuncCtx.holderBindings` maps a value slot to its holder array. Forwarding an `inout` parameter to a nested call refreshes the outer holder via the write-through readback. Guarded by `out_inout_jvm_self_test.l` (out String/Int/Long, multiple out, inout RMW, nested forwarding, mixed-mode). **Instance / interface methods are a tracked follow-up** — the dispatch-site wrap/unwrap is not yet implemented, so `rejectInstanceHolderParams` emits a hard compile error (not a silent by-value miscompile) for an `out`/`inout` parameter on a record/protected/impl/interface method or an async generator; the MSIL companion `lyric-compiler/lyric/outparam_self_test.l` covers those on `--target dotnet`. | `codegen/01_types.l`, `codegen/04_calls.l`, `codegen/05_stmts.l`, `codegen/06_items.l` | #1763 |
| m-4 | intra-impl `self.m`/bare `m` calls | #1722 | #1722 |
| m-5 | nested-generic union case construction (`Result[Option[T],E]`) | #1707 | #1707 |
| m-6 | JVM regex daemon-thread timeout shim | #1103 | #1103 |
| m-7 | `splitPathList` splits on `:` and `;`, breaking Windows `LYRIC_FFI_JARS` | #2214 | #2214 |
| m-8 | negative `loadClass` results not cached (repeated JMOD scans) | #2181 | #2181 |
| m-9 | `findBestConstructor` implicit score threshold vs explicit `>= 0` | #2226 | #2226 |
| m-10 | `Std.Time.sleepMillis` is a JVM stub; doc omits the limitation | #2101 | #2101 |
| m-11 | Doc contradictions: Q-J012/Q-J013 marked "shipped" in `docs/36` but "NOT present / Phase 6" in `docs/31`/`docs/03`; self-test counts drift (B124/B125/B130) across `docs/18`/`docs/33`/`docs/04`; parity count "20-program" vs "22-program" | `docs/31:409-434` vs `docs/36:123-150`; count drift | (Band J0 docs sweep) |
| m-12 | ~~`Float`/`Double` ordered comparisons used `fcmpl`/`dcmpl` for all six operators → NaN compared as less-than-everything for `<`/`<=` (IEEE 754 §5.11 violation)~~ **Fixed (D-progress-508):** `floatCmpInsn(op, isDouble)` selects `fcmpg`/`dcmpg` for `<`/`<=` and `fcmpl`/`dcmpl` otherwise, in both `lowerCmp` and `lowerCmpFail`; verified by `nan_compare_jvm_self_test.l`. | `codegen/02_exprs.l` | #2772 |
| m-13 | ~~`lowerTryCatchExpr` value-less catch arm (type-checker gap #2042) aborted with a bare `panic(...)` carrying no source location~~ **DONE (D-progress-509).** Now a source-located `error[J004]: <line>:<col>: …` built from the offending catch clause's span, re-emitted under `error[J002]` by the `Jvm.Bridge` `Bug` catch for bundled packages. `J004` is the next free code after `J001`–`J003`. Regression-guarded by `try_catch_expr_jvm_self_test.l` (4 valid cases) in CI on `--target jvm`. | `codegen/05_stmts.l` | #3193 |
| m-14 | ~~Extern/`JRef` local used across a basic-block boundary (loop back-edge / `if`) was framed as `java/lang/Object` in the `StackMapTable` → `VerifyError` on the next `invokevirtual`~~ **Fixed (D-progress-513):** `emitStore` emits `LAstoreAs(slot, cls)` so the frame carries the resolved class; verified by `extern_loop_jvm_self_test.l`. Unblocks loop-driven `_kernel_jvm` auto-FFI hosts (#1065). The extern-type-**parameter** descriptor sub-gap from #3307 (param `JBAOS` → `Main/JBAOS`) is separate and still open. | `codegen/01_types.l` | #3307 (loop case) |

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
  `lowerExpr` mega-function (~600 lines, `codegen/02_exprs.l:124-912`) that J2
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
- [x] B-4: emit `Float` as JVM `float` (`freturn`/`fload`/`F` descriptors), not
  `double`; add a Float round-trip self-test. **Done (D-progress-464):**
  `typeExprToJvm` maps `Float`→`JFloat`; float load/store/return/arith/compare
  opcodes + `d2f`/`f2d`/`i2f` conversions; `1.0f32` literal emits `LFconst`.
- [x] B-5: implement `member =` / `index =` assignment lowering (or, if genuinely
  out of scope short-term, emit a hard error — never a silent pop).
  **Done (D-progress-464):** `obj.field = e` → `putfield`; `arr[i] = e` →
  `Xastore` / ArrayList `set`; compound forms supported.
- [x] B-6: make stdlib codegen failures **fatal** for the packages a build
  actually references; surface which symbol failed.  **Done (D-progress-465):**
  `jvm/bridge.l`'s `compileToJarBundled` now computes function-level call
  reachability over the user package plus the bundled import closure (mirroring
  the JVM's lazy per-method linking), using the same cross-package call registry
  the codegen resolves against.  A codegen panic for a package that declares a
  reachable function is fatal (`error[J002]`, naming the package and the panic
  message — which carries the failing symbol/construct); a package with no
  reachable function is skipped silently instead of producing a JAR that throws
  `NoSuchMethodError` at runtime.  Composed with B-10's success-path verbosity
  cut: bundled packages run the middle-end with `reportTcAdvisories = false`,
  and the unreached-skip path prints no `note:`, so a successful build stays
  clean while a referenced-package failure aborts loudly.
- [x] or-pattern binding no-op (m-1 sibling, `codegen.l:2060`): bind the variable
  or reject the pattern. **Done (D-progress-464):** the `POr` bind arm re-tests
  each alternative and binds from the matching one.
- [x] B-7/B-8: port the MSIL `reorderCtorNamedArgs` pass; fix union construction to
  `new` + `invokespecial <init>`. **Done (D-progress-464):** `orderCtorArgs`
  permutes named args to field order; nullary-case bare-path construction
  (`Empty`/`None`) now emits `new`+`invokespecial <init>()V` instead of `null`.
- B-10 (**done**, #2664): the single-file build output extension and
  `runtimeconfig.json` emission are now **target-aware** — `--target jvm`
  defaults the output to `<name>.jar` and emits no `runtimeconfig.json`,
  `--target dotnet` keeps `<name>.dll` + its `runtimeconfig.json`, and an
  explicit `-o` is honoured verbatim (`cli.l` `cmdBuild`/`buildOne`). The
  JVM bridge no longer echoes advisory stdlib parse / type-check noise or the
  "skipped bundling" note on a *successful* build (`jvm/bridge.l`
  `compileToJarBundled`/`runMiddleEnd`); real user-file errors still surface.
- **Acceptance:** a `silent_miscompile_guard_jvm_self_test.l` covering Float,
  complex assignment, named-arg records, union construction, and or-patterns,
  run in CI on `--target jvm`. **Done (D-progress-463):** 8/8 pass; wired into
  CI beside the `auto_ffi_jvm` / `hash_jvm` steps.

### J2 — Bring `jvm/bridge.l` to MSIL-bridge parity (architectural, the linchpin)
Port the middle-end stages `msil/bridge.l` runs that `jvm/bridge.l` omits:
- [x] Aspect weaving (`Lyric.Weaver.weaveFileWithDiags`) — B-3.  Wired into both
  the single-file (`compileToJar`) and bundled (`compileToJarBundled` via
  `runMiddleEnd`) paths, at the MSIL pass position (after mono, before codegen);
  weave-time diagnostics A0042/A0043/A0044 surface like MSIL.
- [x] Lambda lifting / closures — B-1.  **Done (J2b, D-progress-474):** rather
  than an MSIL-style lambda-lifting pre-pass, the JVM backend lowers each
  `ELambda` directly to a `<pkg>$Lambda$<n>` inner class implementing a
  package-shared `Lyric$Lambda` functional interface (uniform `Object[]`-packing
  ABI).  Capture analysis (`lambdaCaptureNamesJvm`) binds free `val`/param
  references as ctor fields; call sites route lambda-typed callees through
  `invokeinterface`.  `val`/param by-value capture ships; by-reference `var`
  capture (heap-cell hoisting, MSIL `#1479 v2`) is the remaining follow-up.
- [x] `?` / `try` error-propagation lowering — part of B-2.  Wired into both
  paths at the MSIL position (after the elaborator, before mono) via
  `lowerPropagateFile`.  The lowering is target-agnostic and is verified on MSIL
  by `propagate_self_test.l`; its lowered output constructs/matches the generic
  `Result`/`Option` types, so a *runtime* JVM `?` assertion is blocked on JVM
  generics (M-1, scheduled for J4) and is deferred there.
- [x] `@cfg` erasure (`Cfg.applyCfgErasure`) — M-4.  Wired into
  `compileToJarBundledWithFeatures` before `@stubbable`/type-check; the
  single-file `EmitRequest` path threads an empty feature set (parity with the
  MSIL single-file `compileToMsilWithVersion`, which likewise runs no cfg).
- [x] Cross-package generic collection into mono — M-5.  Both JVM paths now call
  `monoFileWithImports` fed `collectStdlibGenericFuncsJvm(...)` (mirroring the
  MSIL bridge's `collectStdlibGenericFuncs`) instead of bare `monoFile`.
- **Acceptance:** weaving / `@cfg` runtime assertions pass on `--target jvm` via
  `lyric-compiler/jvm/middle_end_passes_jvm_self_test.l`; the four wired passes
  mirror the MSIL bridge's order.  Closures/lambda values now compile and run
  (`lyric-compiler/jvm/closure_jvm_self_test.l`, D-progress-474).  A runtime `?`
  assertion is the remaining J2 gap — it awaits J4 generics (now landed in
  D-progress-473, so a JVM `?` runtime test is unblocked as follow-up).

### J3 — Wire the capabilities `lowering.l` already has (low-effort parity) — **DONE (D-progress-472)**
- [x] M-3: dispatch `06_items.l`'s `IOpaque`/`IProtected`/`IWire` arms to the
  real lowering. The work was larger than "only the dispatch is missing": each
  construct also needed the front-end → class plumbing that the hand-built
  Path-A self-tests bypassed — opaque/protected type **registration** (so
  `Counter(value = …)` construction + field reads resolve), `selfClass`
  bare-name field resolution for protected entries, an instance-method
  signature registry (`<class>#<method>`) so entry calls emit a precise
  `invokevirtual` instead of the `()Object` guess, opaque field reads through
  the `$<name>()` accessor, a **public** opaque ctor (cross-JVM-package
  access), and wire static-call resolution (`AppWire.bootstrap()` /
  `AppWire.<binding>()`). `IConfig` stays an intentional no-op (DI-phase
  consumed, parity with MSIL — no `lowerConfig` in either backend).
- [x] M-2: `defer` via try/finally + defer-replay (mirror MSIL #1477) — runs on
  normal fall-off, early `return`/`break`/`continue`, and exception unwind.
- [x] m-2: module-level `val` as `static final` (read via `getstatic`).
- **Acceptance:** `lyric-compiler/jvm/j3_lowering_self_test.l` (6/6) on
  `--target jvm`, wired into CI; no regression on the four existing JVM
  self-tests (silent-miscompile 8/8, auto-FFI 13/13, hash 3/3, bitwise 10/10).

### J4 — Generics, async, and the harder semantics (largest effort)
- M-1: **DONE (D-progress-473).** Erased + `checkcast` JVM generics strategy
  (Q-J001 — Valhalla deferral documented). Generic type params erase to
  `java/lang/Object`; construction boxes primitive payloads into the `Object`
  field; match-extraction + erased-operand use-sites `checkcast` + unbox to the
  binding's concrete type. The `?`-propagation JVM runtime runs. Covers
  `Result`/`Option`, user generic records/unions, and same-unit + stdlib
  generics (`monoFileWithImports`). Verified by `generic_jvm_self_test.l`.
- M-5/m-5: nested-generic-union-case construction (`Result[Option[T], E]`) and
  broader cross-package generic monomorphization beyond `monoFileWithImports`
  remain open follow-ups.
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
  - **Parsing slice DONE (#2668):** `manifest.l` now parses `[maven]` and
    `[maven.options]` into a `MavenSection` (`MavenEntry` coordinate/version
    pairs, `repositories` defaulting to `["central"]`, optional `java_version`),
    mirroring how `[nuget]` / `[nuget.options]` are parsed (`assembleMaven`
    parallels `assembleNuget`). Both the plain `group:artifact = "version"`
    and extended `{ version = "..." }` inline-table forms are accepted, per
    `docs/31-maven-linking.md` §2 (D053). Covered by `manifest_self_test.l`
    (single coordinate, multiple coordinates + options, extended form, and
    absence → `None`).
  - **Remaining (resolver slice):** consume the parsed `MavenSection` from the
    JVM build pipeline — revive or replace the orphaned Java `resolver/`,
    download + checksum-verify JARs (`B0050`/`B0054`), generate `_extern/*.l`
    auto-shims (§4), and wire the resolved classpath into
    `lyric build --target jvm`.
- M-15/m-7/m-8/m-9: `extern type` robustness (abstract-type guard,
  `java/lang/Object` walk, path-split, negative-cache), Windows path handling.
- **Acceptance:** an ecosystem library with a `[maven]` table builds and runs
  on `--target jvm` from a clean checkout with no manual classpath.

### J6 — stdlib JVM kernel parity (cross-platform stdlib actually works on JVM)
- **M-9 (DONE):** added `_kernel_jvm/hash_host.l` (Java SHA-512 via
  `java.security.MessageDigest`, uppercase hex via `java.util.HexFormat`),
  declared with `extern type` JVM auto-FFI (no F# shim).
- **M-10 (DONE):** the self-hosted source loader is now **target-aware**
  (`emitter.l:findStdlibSourcesForTarget(forJvm)`): JVM builds prefer
  `_kernel_jvm/<module>_host.l` and fall back to `_kernel/<module>_host.l`
  only when no JVM host exists; `emitJvmInProcess` passes `forJvm = true`.
  Closing M-10 also required JVM-backend `slice[Byte]↔byte[]` interop in
  `jvm/codegen.l` + `jvm/auto_ffi.l` (auto-FFI byte-array arg/return
  coercion, primitive-array index `baload` / `.length`, receiver stash so the
  coercion loop runs at empty operand stack) and a String `==`/`!=`
  value-comparison fix (was reference equality).
- **M-11 (`ProcessCaptureHost` design done, codegen-blocked; storage blocked):**
  the production design for JVM `Std.ProcessCaptureHost`
  (`_kernel_jvm/process_capture_host.l`, #1065) is pure JVM auto-FFI —
  `java.lang.Runtime.getRuntime().exec(String)` spawns the child, stdout/stderr
  drain incrementally inside the wait loop (`InputStream.available()`-bounded
  reads into a `ByteArrayOutputStream`, so a >pipe-buffer child cannot deadlock
  a single-threaded drain), the wall-clock cap is polled via `Process.isAlive()`
  + `System.currentTimeMillis()` (TimeUnit is an enum the resolver skips, so
  `waitFor(long, TimeUnit)` is unavailable), and a timeout triggers
  `Process.destroyForcibly()` with sentinel `exitCode = -2`, returning a Lyric
  `ProcessCaptureResult` record (no opaque POJO, no Java/F# shim — the
  never-built `lyric.stdlib.jvm.*` shim plan is removed from the kernel doc).
  **It cannot land yet:** every drain/poll loop carries a `Process` /
  `InputStream` / `ByteArrayOutputStream` extern handle across the loop
  back-edge, and the JVM backend currently types extern-type locals as
  `java/lang/Object` in the `StackMapTable` frame at a loop boundary, so the
  emitted `invokevirtual` fails bytecode verification. Tracked as **#3307**
  (`jvm/codegen/*`), with a minimal repro (a bare `while` loop writing to a
  `ByteArrayOutputStream` local). The `lyric-storage` local-fs JVM kernel
  (#1444/#1840) remains **BLOCKED on M-4**: `storage.l` statically
  `import Storage.Kernel.Net` and the local-fs data plane calls those `host*`
  primitives directly, so a JVM backend needs the import swapped per target —
  JVM `@cfg(feature=…)` erasure (M-4 / #2444, in `bridge.l`) must land first.
  M-16 slice-ABI reconciliation (#2592); m-6/m-10 regex/time stubs.
- **Acceptance (MET for M-9/M-10; M-11 pending #3307 + #2444):**
  `lyric-compiler/lyric/hash_jvm_self_test.l` imports `Std.Hash` (resolving to
  `_kernel_jvm/hash_host.l` on JVM), builds via the self-hosted `Jvm.Bridge`, and
  runs under `java` asserting three NIST SHA-512 vectors — closing the "no native
  JVM test depends on `_kernel_jvm`" gap. The M-11 `ProcessCaptureHost` self-test
  is deferred behind #3307 (a loop-driven process kernel cannot compile to valid
  JVM bytecode until the extern-local stackmap typing is fixed), and the storage
  kernel behind #2444.

### J7 — Testing, distribution, and the acceptance gate
- M-14: expand the self-hosted `--target jvm` pipeline suite well beyond the
  current 4 programs; convert representative `self_test_b*.l` (or new
  `@test_module` tests) to run through the **compile pipeline**, not just the
  emission library, and delete the F# `JvmLoweringB*Test.fs` wrappers as the
  native path subsumes them.
- B-11/#676: ship the full JUnit 5 `LyricTestEngine` so `lyric test --jvm`
  executes tests.
- M-18: `lyric run --target jvm` (#674) ships for the no-arg / stdout path;
  arg-forwarding and exit-code propagation hit a JVM `VerifyError`, tracked in
  #3303. `lyric bench --target jvm` (#680) dispatch is wired but blocked on
  JVM `Std.Time` support (#3302), so #680 stays open. GraalVM native-image
  (#675/#1975) still outstanding.
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
`lowerExpr` function (`codegen/02_exprs.l:124-912`) is edited by both J2 (`ELambda`)
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
acceptance gate). The JVM production-readiness epic is #2663 (with band sub-tasks #2664–#2670).
