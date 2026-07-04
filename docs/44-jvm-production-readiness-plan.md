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
| M-7 | ~~**Maven resolver orphaned**~~ **Partially DONE (J5).** `cli_restore.l:restoreMavenJars` now invokes `lyric-resolver.jar` via `ProcessCapture.runCaptureWithDiagnosticsTimeout`, reads the JSON response, and writes `target/restore/jvm-classpath.txt`.  `cli_build.l:buildProject` reads the classpath file before `emitProject` and injects `LYRIC_FFI_JARS` for JVM auto-FFI; after a successful JVM build it also writes `<outDir>/module-path.txt`. `LYRIC_MAVEN_RESOLVER` env var or `lyric-resolver.jar` beside the binary required.  Remaining gap: `resolver/pom.xml` must be built (`make maven-resolver`) — the JAR is not yet pre-distributed with `lyric`. | `cli_restore.l:restoreMavenJars`, `cli_build.l:buildProject`; `resolver/pom.xml` | #673 |
| M-8 | ~~**F#-host kernel debt:** JVM byte-builder + constant pool via `@externTarget` into `Lyric.Jvm.Hosts` (F#), on the deletion schedule~~ **DONE (J5, D-progress-527).** `Lyric.Jvm.Hosts` project deleted entirely; `jvm/_kernel/kernel.l` is a pure-Lyric `ByteWriter`/`ConstantPool` using only arithmetic operators and audited BCL externs (`System.BitConverter`, `System.Convert.ToByte`, `System.IO.MemoryStream`). No `@externTarget` into F# host code. | `jvm/_kernel/kernel.l` | DONE |
| M-9 | ~~`Std.Hash` has **no JVM host**~~ **DONE (J6).** `lyric-stdlib/std/_kernel_jvm/hash_host.l` added: `MessageDigest.getInstance("SHA-512").digest(...)` + `HexFormat.of().withUpperCase().formatHex(...)` via JVM auto-FFI (`extern type`, no F# shim). Verified by `hash_jvm_self_test.l` (3 NIST vectors) under `java`. | `_kernel_jvm/hash_host.l` | DONE |
| M-10 | ~~`_kernel_jvm/` is **never loaded** by the self-hosted source loader~~ **DONE (J6).** `emitter.l:findStdlibSourcesForTarget(forJvm)` prefers `_kernel_jvm/<module>_host.l` and falls back to `_kernel/<module>_host.l` only when no JVM host exists; `emitJvmInProcess` threads `forJvm = true`. Required JVM `slice[Byte]↔byte[]` interop fixes in `codegen.l` (auto-FFI arg/return byte-array coercion, primitive-array index/length) and a String `==`/`!=` value-comparison fix. | `emitter.l`, `jvm/codegen.l`, `jvm/auto_ffi.l` | DONE |
| M-11 | ~~`ProcessCaptureHost` on JVM (#1065) — design done, codegen-blocked on #3307~~ **DONE (J6, D-progress-519).** `_kernel_jvm/process_capture_host.l` rewritten as pure JVM auto-FFI: `java.lang.ProcessBuilder(List<String>)` (reference-subtype match via new score-1 path in `auto_ffi.l`), `InputStream.available()` drain loop into `ByteArrayOutputStream`, `System.currentTimeMillis()` timeout poll, `Process.destroyForcibly()` kill, `JBAOS.toString("UTF-8")` output conversion. Returns a Lyric `ProcessCaptureResult` record — no F#/Java shim. `@externTarget` stubs removed. `lyric-storage` local-fs JVM kernel (#1444/#1840) **still BLOCKED on M-4** (#2444). | `_kernel_jvm/process_capture_host.l`, `jvm/auto_ffi.l` | #1065 DONE; #1444, #1840 (blocked #2444) |
| M-12 | Async generators are eager "collect-all", not lazy `IAsyncEnumerable` | `lowering.l:3493-3518` | #2469 |
| M-13 | Range/refined types erased to `JInt`, no bounds checks | `codegen.l:283` | (new) |
| M-14 | Self-hosted JVM **pipeline** coverage is ~4 programs vs 132 library self-tests; the front-end → JVM path is barely exercised | `ci.yml` (4 native `--target jvm` steps) | #2000, #2595 (per-test) |
| M-15 | `extern type` robustness gaps: `T.new()` on abstract type → runtime `InstantiationError` (no compile guard); `findBestInstanceMethod` stops before `java/lang/Object` | #2215, #2219 | #2215, #2219 |
| M-16 | Slice ABI fork: F#-built `Lyric.Stdlib.dll` uses `!0[]` arrays for generic `slice[T]` while self-hosted callers are List-backed | #2592 | #2592 |
| M-17 | `scope` (structured concurrency) panics on JDK 24+ (StructuredTaskScope became an interface); supports 21–23 only | `lowering.l:3904-3914` | #2263 |
| M-18 | JVM distribution: ~~no `lyric run --target jvm` (#674)~~ **DONE** (`cli_run.l` builds the bundled JAR via the in-process `Jvm.Bridge` and execs `java -jar`); ~~`main(slice[String])` argv `VerifyError` + `Int` return not propagated to the exit code (#3303)~~ **Fixed (D-progress-543):** `isMainFunc` accepts the `argv: slice[String]` form, the synthesised `main(String[])` wrapper forwards the incoming `String[]` to the erased `Object[]` slice parameter (JVM array covariance, no copy), `args.count` lowers to `arraylength`, and an `Int`-returning main routes through `java.lang.System.exit(int)` (branchless — no StackMapTable needed); verified by `entry_args_jvm_main.l` + the CI argv/exit-code check; ~~`lyric bench --target jvm` (#680) blocked on JVM `Std.Time` (#3302)~~ **unblocked (D-progress-543):** `_kernel_jvm/time_host.l` is now pure Lyric over the JVM auto-FFI (no static-field externs, no phantom `lyric.stdlib.jvm.*` shim classes; `Duration.ZERO` → `ofMillis(0)`, arg-order/unit divergences bridged in Lyric bodies, fractional durations preserved via `ofNanos` + `Math.round`), verified by `time_jvm_self_test.l`; GraalVM native-image path (#675/#1975) still outstanding | #675, #1975 | #674 ✅; #680 ✅ (#3302 fixed); #3303 ✅; #675/#1975 open |

### MINORS (coverage, polish, diagnostics)

| ID | Finding | Evidence | Issue |
|---|---|---|---|
| m-1 | loop `invariant:` is a runtime no-op on JVM | `codegen.l:3732` | (new) |
| m-2 | ~~Module-level `val` not emitted as `static final` on JVM~~ **DONE (J3, D-progress-472).** A module-level `val NAME = expr` emits a `public static final` field on the package host class, initialised in a synthesised `<clinit>`; bare references resolve to `getstatic <hostClass>.<name>` from any function in the package (collected by `collectFileVals`, threaded via `FuncCtx.moduleVals`). Mirrors the MSIL `.cctor` static-field path. | `codegen/06_items.l`, `lowering.l` | #2210 |
| m-3 | ~~`out`/`inout` parameter parity (holder-array lowering)~~ **DONE for free functions (#1763).** A free function's `out`/`inout` parameter of element type T is lowered to a single-element JVM *holder array* (`[I`, `[J`, `[Ljava/lang/String;`, …): the descriptor declares the array type; on entry the callee unwraps `holder[0]` into a value slot and every assignment writes through to `holder[0]` (centralised in `emitStoreLocalWriteThrough`, so no return-time epilogue is needed); the call site (`lowerStaticCallWithHolders`) allocates a holder pre-filled with the caller's local, passes it, and copies element 0 back after the call. `JvmFuncSig.paramModes` carries the declared modes so call sites know which arguments to wrap; `FuncCtx.holderArraySlot`/`holderElemType` (two parallel maps — value slot → holder array slot and value slot → element type; a record-valued map is avoided per the stage-0 bootstrap hazard) map a value slot to its holder array. Forwarding an `inout` parameter to a nested call refreshes the outer holder via the write-through readback. Guarded by `out_inout_jvm_self_test.l` (out String/Int/Long, multiple out, inout RMW, nested forwarding, mixed-mode). **Instance / interface methods are a tracked follow-up** — the dispatch-site wrap/unwrap is not yet implemented, so `rejectInstanceHolderParams` emits a hard compile error (not a silent by-value miscompile) for an `out`/`inout` parameter on a record/protected/impl/interface method or an async generator; the MSIL companion `lyric-compiler/lyric/outparam_self_test.l` covers those on `--target dotnet`. | `codegen/01_types.l`, `codegen/04_calls.l`, `codegen/05_stmts.l`, `codegen/06_items.l` | #1763 |
| m-4 | intra-impl `self.m`/bare `m` calls | #1722 | #1722 |
| m-5 | ~~nested-generic union case construction (`Result[Option[T],E]`)~~ **Fixed (D-progress-575):** #1707's closure was premature — `Map[K, V]` subscript syntax (`m[k]`, `m[k] = v`) still crashed (`VerifyError`, misrouted to `ArrayList` codegen) and compound-assignment through any reference-typed subscript silently dropped the operator. Both fixed in `EIndex` lowering (`02_exprs.l`/`05_stmts.l`); `nested_generic_self_test.l` and the new `subscript_assign_jvm_self_test.l` (10 cases) are green on `--target jvm`. Three separate, deeper, pre-existing gaps this crash had been masking are tracked in #4982. | `codegen/02_exprs.l`, `codegen/05_stmts.l` | #1707 ✅ (follow-ups: #4982) |
| m-6 | JVM regex daemon-thread timeout shim | #1103 | #1103 |
| m-7 | `splitPathList` splits on `:` and `;`, breaking Windows `LYRIC_FFI_JARS` (`C:\path` drive letter treated as separator) | #2214 | #2214 |
| m-8 | ~~negative `loadClass` results not cached (repeated JMOD scans)~~ **DONE.** `loadClass` maintains `ctx.missKeys` (linear scan); repeated lookups of unknown classes skip the JMOD scan entirely. | `auto_ffi.l:284-306` | #2181 DONE |
| m-9 | ~~`findBestConstructor` implicit score threshold vs explicit `>= 0`~~ **DONE.** `findBestConstructor` uses `if s >= 0 and s > bestScore` (#2226). | `auto_ffi.l:553` | #2226 DONE |
| m-10 | `Std.Time.sleepMillis` is a JVM stub; doc omits the limitation | #2101 | #2101 |
| m-11 | Doc contradictions: Q-J012/Q-J013 marked "shipped" in `docs/36` but "NOT present / Phase 6" in `docs/31`/`docs/03`; self-test counts drift (B124/B125/B130) across `docs/18`/`docs/33`/`docs/04`; parity count "20-program" vs "22-program" | `docs/31:409-434` vs `docs/36:123-150`; count drift | (Band J0 docs sweep) |
| m-12 | ~~`Float`/`Double` ordered comparisons used `fcmpl`/`dcmpl` for all six operators → NaN compared as less-than-everything for `<`/`<=` (IEEE 754 §5.11 violation)~~ **Fixed (D-progress-508):** `floatCmpInsn(op, isDouble)` selects `fcmpg`/`dcmpg` for `<`/`<=` and `fcmpl`/`dcmpl` otherwise, in both `lowerCmp` and `lowerCmpFail`; verified by `nan_compare_jvm_self_test.l`. | `codegen/02_exprs.l` | #2772 |
| m-13 | ~~`lowerTryCatchExpr` value-less catch arm (type-checker gap #2042) aborted with a bare `panic(...)` carrying no source location~~ **DONE (D-progress-509).** Now a source-located `error[J004]: <line>:<col>: …` built from the offending catch clause's span, re-emitted under `error[J002]` by the `Jvm.Bridge` `Bug` catch for bundled packages. `J004` is the next free code after `J001`–`J003`. Regression-guarded by `try_catch_expr_jvm_self_test.l` (4 valid cases) in CI on `--target jvm`. | `codegen/05_stmts.l` | #3193 |
| m-14 | ~~Extern/`JRef` local used across a basic-block boundary (loop back-edge / `if`) was framed as `java/lang/Object` in the `StackMapTable` → `VerifyError` on the next `invokevirtual`~~ **Fixed (D-progress-513):** `emitStore` emits `LAstoreAs(slot, cls)` so the frame carries the resolved class; verified by `extern_loop_jvm_self_test.l`. Unblocks loop-driven `_kernel_jvm` auto-FFI hosts (#1065). | `codegen/01_types.l` | #3307 (loop case) |
| m-15 | ~~`extern type` value as a function parameter/return resolved to `<pkg>/<Alias>` → `NoClassDefFoundError: Main/JBAOS`~~ **Fixed (D-progress-514):** `typeExprToJvmExtern` resolves extern aliases in both the registered `JvmFuncSig` and the emitted method descriptor; verified by `extern_param_jvm_self_test.l`. Together with m-14 this clears both #1065 JVM codegen blockers. | `codegen/01_types.l`, `codegen/06_items.l` | #3334 |
| m-16 | ~~Aliased package-method calls (`import Std.String as Str; Str.trim(s)`, and the implicit alias of a bare `import Std.Time`) panicked in the auto-FFI `Object` guess — the JVM bridge skipped `Lyric.AliasRewriter`~~ **Fixed (D-progress-543):** both `compileToJar` and `compileToJarBundledWithFeatures` run `Aliases.rewriteFile` between parse and `@stubbable` synthesis, matching the MSIL bridge; the rewrite also exposed and fixed a latent `lastSegOfKey` substring bug on qualified registry keys. Verified by `alias_import_jvm_self_test.l`. | `bridge.l` | #4606 |
| m-17b | ~~Interface dispatch on an interface-typed receiver emitted `invokevirtual` against the interface owner → class-load "Found interface X, but class was expected"~~ **Fixed (D-progress-543):** `collectFileSigs` registers every `interface` member under `<ifaceClass>#<method>` with `isIface = true` (params/return mirror the abstract-method emission exactly), and the J3 M-3 dispatch path emits `invokeinterface` (count = 1 + arg slots) for such sigs. Verified by `iface_dispatch_jvm_self_test.l`. | `codegen/01_types.l`, `codegen/04_calls.l`, `codegen/06_items.l` | #3687 |
| m-18b | ~~`Std.Collections` Map iteration helpers (`mapKeys`/`mapValues`/`mapEntries`/`mapForEach`/`mapPutAll`) had no JVM kernel; `tryGetValue`/`setToSlice` referenced phantom `lyric.stdlib.jvm.*` shim classes~~ **Fixed (D-progress-543):** `_kernel_jvm/collections_host.l` binds `dictGetKeys`/`dictGetValues` to `HashMap.keySet()`/`.values()` (both `Iterable`, iterated by the emitter's Iterable path); `tryGetValue` and `setToSlice` are plain Lyric over `containsKey`/`get` and `HashSet.toArray()`; `newListWithCapacity` added. End-to-end verification shipped with the #3229 fix (D-progress-553): `map_iteration_jvm_self_test.l` is restored and CI-wired (element consumption is count-shaped pending J4 typed erasure; value semantics covered via `mapGet`/`mapPutAll`). | `_kernel_jvm/collections_host.l` | #3676 ✅ (via D-progress-553) |
| m-19 | ~~`out`/`inout` argument that is a field access (`obj.field`) panicked `lowerStaticCallWithHolders`~~ **Fixed (D-progress-543):** `prepareHolderArg` stashes the lowered receiver, reads the field into `holder[0]`, and `writeBackHolderArg` `putfield`s the updated value after the call (both static and virtual holder call paths; JVM analog of MSIL #3547). Verified by the field-access cases in `out_inout_jvm_self_test.l`. | `codegen/04_calls.l` | #3628 |
| m-20 | ~~An extern type used in another package's signatures/locals (`Std.Time.now(): Instant` with `Instant` declared in `Std.TimeHost`) resolved to the nonexistent `<pkg>/<Alias>` class → `NoClassDefFoundError` at link~~ **Fixed (D-progress-543):** the bundled compile builds a per-package extern-type map and seeds each file's signature registration + codegen with the union of its imports' extern types (`externSeedForFile` → `collectFileSigsSeeded`/`codegenPackageWithSigsSeeded`, own declarations win); local `val`/`var` annotations, `is`-type-tests, and result-wrap returns now resolve through `typeExprToJvmExtern` with the seeded map. | `bridge.l`, `codegen/01_types.l`, `codegen/02_exprs.l`, `codegen/03_match.l`, `codegen/04_calls.l`, `codegen/05_stmts.l`, `codegen/06_items.l` | (D-progress-543) |
| m-21 | ~~`x.toString()` on a primitive receiver fell through unhandled (mis-stacked into string concat → `VerifyError`); `JByte` div/rem returned `JInt`~~ **Fixed (D-progress-543):** primitive receivers box and call `Object.toString` (Java renders `1500.0` where .NET renders `1500` for whole Doubles — a formatting divergence tracked in #4688); the masked `JByte` div/rem branches now yield `JByte`, keeping later narrowing/type-tracking exact (#4551). | `codegen/02_exprs.l`, `codegen/04_calls.l` | #4551, #4688 |
| m-22 | ~~An `if`-without-`else` (or a void-typed `if`/`else` whose else-arm produces a value) leaked its arm's trailing expression value onto the operand stack at the join label — inside a loop the leaked value reached a back-edge branch target and failed `StackMapTable` verification (`Std.ProcessCaptureHost` `proc.destroyForcibly()` poll-loop shape); separately, every discard site used `pop`, which fails verification for category-2 `long`/`double` values~~ **Fixed (D-progress-543):** `lowerIfExpr` discards a non-terminated arm's value in both void-`if` forms via the new width-correct `discardValue` helper (`pop2` for `JLong`/`JDouble`, `pop` otherwise, backed by the new `LPop2` instruction); `SExpr` statement and `PWildcard` binding discards route through the same helper. Verified by the discard cases in `extern_param_jvm_self_test.l` and `process_capture_jvm_self_test.l` end-to-end. | `lowering.l`, `codegen/02_exprs.l`, `codegen/05_stmts.l` | (D-progress-543) |
| m-23 | ~~Assignment to a local named `result` was silently dropped: `result` is a contextual keyword that parses as `EResult` even in assignment-target position, and `lowerAssignExpr` had no `EResult` arm, so the target fell to a fallback that evaluated the RHS and popped it — the stdlib's own `Std.ProcessCapture.buildArgString` accumulates into a `result` local, so every JVM ProcessCapture argument round-trip produced an empty arg string~~ **Fixed (D-progress-543):** `lowerAssignExpr` routes an `EResult` target through the named-local path (rebuilding the equivalent `EPath` target), and the three remaining evaluate-and-drop assignment fallbacks (unknown name, non-reference field receiver, unsupported target shape) now `panic` with a diagnostic instead of silently miscompiling. Verified by the `result`-local cases in `silent_miscompile_guard_jvm_self_test.l` and the ProcessCapture arg round-trip end-to-end. | `codegen/05_stmts.l` | (D-progress-543) |
| m-24 | ~~Two-arg `s.substring(start, count)` on a String receiver passed through auto-FFI to Java's `substring(begin, END-INDEX)`, silently reinterpreting the count as an end index — wrong results or `StringIndexOutOfBoundsException` for any `start > count` (the kernel's `parseArgString`, plus the cross-platform `Std.Xml`/`Std.Yaml`/`Std.Rest`/`Std.Log` substring call sites)~~ **Fixed (D-progress-543):** a String-receiver `substring` intrinsic translates Lyric's (start, count) — the `.NET`/`Std.String` semantics — to Java's (begin, begin + count); the one-arg form is semantics-identical on both platforms and still passes through auto-FFI. Verified by the substring cases in `string_methods_jvm_self_test.l` and the ProcessCapture arg round-trip end-to-end. | `codegen/04_calls.l` | (D-progress-543) |
| m-25 | ~~Monomorphizer-specialised functions unresolvable in bundled compiles: the sig registry is built pre-middle-end and only derive/weave sigs were patched afterward, so specialised copies (`mapKeys__String__Int`, …) were emitted but their call sites fell to the `(…)Object` guess — descriptor mismatch at class load ("specialisations are not emitted")~~ **Fixed (D-progress-553):** `collectMonoSpecializedSigs` patches the registry from the post-mono file at both bundled codegen sites (bare + qualified keys, extern-seeded type resolution). The restored-dependency half of #3229 is structurally N/A until the JVM bridge grows a restored-artifact path. | `bridge.l` | #3229 ✅ |
| m-26 | ~~`mapGet(m, k)` intrinsic returned the raw `HashMap.get` value — never an `Option`, so every `case Some(...)` match on a mapGet result silently failed — and boxed the key as if always `Int` (VerifyError on String keys)~~ **Fixed (D-progress-553):** containsKey-gated `Some`/`None` construction with the key boxed by its actual type; map/key/result stash to locals so the operand stack is empty at branch targets. | `codegen/04_calls.l` | (D-progress-553) |
| m-27 | ~~Mixed void/value match arms miscompiled in statement position (`case Some(v) -> xs.add(v)` returns boolean beside `case None -> ()`): a void arm under a value-typed match emitted `istore` on an empty stack; the reverse order left the result slot unwritten on one path (TOP-merge VerifyError)~~ **Fixed (D-progress-553):** the first non-terminating arm fixes the match type; later arms reconcile (value-under-void discards via `discardValue`, void-under-value stores a dummy default). | `codegen/03_match.l` | (D-progress-553) |
| m-28 | ~~`forall`/`exists` in `@runtime_checked` contracts panicked the JVM codegen~~ **Fixed (D-progress-553):** lower to `true` (sound overapproximation, matching MSIL #1506) + W0002 warning. Verified by the quantifier case in `silent_miscompile_guard_jvm_self_test.l`. | `codegen/02_exprs.l` | #3227 ✅ |
| m-29 | ~~Slice literal passed to a `slice[T]` parameter emitted `ArrayList` where the erased parameter is `Object[]` — VerifyError at class load~~ **Fixed (D-progress-553):** `coerceArgTo` gained a `JArray` arm converting via `ArrayList.toArray()`. Verified by the slice-param case in `silent_miscompile_guard_jvm_self_test.l`. | `codegen/04_calls.l` | #4700 ✅ |
| m-30 | ~~Static fields unreachable through the auto-FFI (`System.in/out/err`, `Duration.ZERO` — factory calls stood in where one existed; no workaround for `System.in`)~~ **Fixed (D-progress-555):** the class reader parses public fields, `Jvm.AutoFfi.findStaticField` walks the superclass chain, and both the bare extern-type member read and the zero-param `@externTarget` field target emit `getstatic` with the field's descriptor. | `class_reader.l`, `auto_ffi.l`, `codegen/02_exprs.l`, `codegen/04_calls.l` | (D-progress-555) |
| m-31 | ~~`in`/`out`/`inout` rejected as member names after `.` (P0081) — `System.in` unparseable~~ **Fixed (D-progress-555):** member position is unambiguous; the mode keywords join the `and`/`or`/`xor` member-name carve-out in `tryEatMemberName`. Both targets. | `parser/parser_core.l` | (D-progress-555) |
| m-32 | ~~`Std.File` and `Std.Console` unbundlable on JVM (the two named J003 skips): both `_kernel_jvm` kernels routed through phantom `lyric.stdlib.jvm.*` shim classes; `std/file.l` declared `extern type DateTime = "System.DateTime"` outside the kernel~~ **Fixed (D-progress-555):** `file_host.l` and `console_host.l` rewritten as pure Lyric over the JVM auto-FFI (java.io file streams; `getstatic System.{out,err,in}` + process-shared BufferedReader); the timestamp crosses the boundary as the kernel-owned opaque `FileTime` on both targets; dead `Std.IO` kernels deleted (no importers). Verified by `file_jvm_self_test.l` and `console_roundtrip_jvm_main.l`. | `_kernel_jvm/file_host.l`, `_kernel_jvm/console_host.l`, `_kernel/file_host.l`, `std/file.l` | #2669 (J6) |
| m-33 | ~~Module `val` of an extern type carried the in-package class guess (`Main/JBufferedReader`) → NoClassDefFoundError at `<clinit>`; indexing a reference-typed JVM array erased the element to `Object`~~ **Fixed (D-progress-555):** `collectFileValsExtern` resolves declared module-val types through the extern-type table; `EIndex` on `JArray(JRef(cls))` reports the element class. | `codegen/06_items.l`, `codegen/02_exprs.l` | (D-progress-555) |
| m-34 | ~~A terminating catch arm (`panic(...)`/`return`) in a value-yielding try-expression aborted codegen with J004 — the actual `Std.File` bundling blocker (`readTextOrPanic`'s decorated re-panic)~~ **Fixed (D-progress-555):** the lowering skips the result store and fall-through `goto` for a terminated arm; J004 still fires for genuinely value-less non-terminating arms (#2042). | `codegen/05_stmts.l` | #2042 (checker gap remains) |
| m-35 | ~~`case null` bound anything (a binding named "null") — `Std.Console.readLine` returned `EndOfInput` for real lines~~ **Fixed (D-progress-555)** on JVM: the pattern test emits `ifnonnull` (new `LIfnull`/`LIfnonnull` instructions).  MSIL appears to share the bind-anything semantics — #4759, needs CI adjudication. | `codegen/03_match.l`, `lowering.l` | #4759 (MSIL half) |
| m-36 | ~~Primitives could not flow into `Object` FFI parameters (`bytes.add(7)` on `List[Byte]` → no matching overload)~~ **Fixed (D-progress-555):** primitive→`Object` scores at low priority with boxing in `emitFfiCoerce`. | `auto_ffi.l`, `codegen/04_calls.l` | (D-progress-555) |
| m-37 | ~~`xs.toArray()` on a receiver erased to `Object` (a generic `in List[T]` parameter) panicked instance auto-FFI resolution — hit by `Std.File.writeBytes`~~ **Fixed (D-progress-555):** checkcast-ArrayList `toArray()` intrinsic on Object/ArrayList/List receivers (the `.count` → `size()` erased-receiver precedent). | `codegen/04_calls.l` | (D-progress-555) |
| m-38 | ~~Branching byte-array coercions (`Object[]`↔`byte[]` element loops) ran with values already on the operand stack in three call forms — auto-FFI constructor args (after `new; dup`; hit by `String(byte[], "UTF-8")`), plain static-call args (hit by `hostWriteAllBytes(path, stringToUtf8Bytes(s))`), and the holders-path by-value args — landing branch targets against the empty-stack StackMapTable → VerifyError~~ **Fixed (D-progress-555):** all three sites pre-lower/coerce arguments into temp slots with an empty stack and reload in order (constructors unconditionally; static calls gated on a slice-shaped parameter; the holders path pre-lowers every by-value arg). | `codegen/04_calls.l` | (D-progress-555) |
| m-39 | ~~Boxed byte elements unboxed with `checkcast Byte` — an int literal added to a `List[Byte]` boxes as `Integer` → ClassCastException in the `Object[]`→`byte[]` conversion and in `coerceArgTo`'s byte arm~~ **Fixed (D-progress-555):** both unbox through `Number.intValue()` + `i2b`, accepting either wrapper. | `codegen/04_calls.l` | (D-progress-555) |
| m-40 | ~~`@externTarget("….<init>")` constructor targets had no emission shape — the instance-method fallback consumed the first argument as a receiver (`Std.CollectionsHost.newListWithCapacity` → NoSuchMethodError)~~ **Fixed (D-progress-555):** `<init>` targets emit `new; dup; <params>; invokespecial; areturn` with slot-width-aware parameter loads; and because *generic* `@externTarget` functions are never emitted as methods at all (excluded from monomorphization, no non-generic body), `newListWithCapacity` itself is an intrinsic (`ArrayList(int)`, capacity stashed to a temp before `new; dup`) like `newList`/`newMap`. | `codegen/04_calls.l` | (D-progress-555) |
| m-41 | ~~A record/protected field typed by an IMPORTED extern type (`FileStat.modifiedAt: FileTime`) carried the in-package class guess → NoClassDefFoundError~~ **Fixed (D-progress-555):** record emission (`typeExprToJvmErasedExtern`), protected-type fields, and the bundled `collectFileCasesExtern` registration all resolve field types through own + imported extern types. | `codegen/01_types.l`, `codegen/06_items.l`, `bridge.l` | (D-progress-555) |
| m-42 | ~~`.count` / `.length` on an erased-`Object` receiver (a match binding on a generic union payload, `case Ok(rb)` on `Result[List[Byte], _]`) emitted **nothing** — the record-field fallback left the receiver itself as the "value", and the following comparison checkcast'd the collection to `Integer` (silent-until-runtime CCE)~~ **Fixed (D-progress-555):** the erased-receiver fallback dispatches on the runtime class (`Collection`/`Map` → `size()`, `String` → `length()`, last-resort `Object[]` → `arraylength`), receiver stashed to a temp so every branch target sees the empty operand stack. | `codegen/02_exprs.l` | (D-progress-555) |
| m-43 | ~~`Std.File.stat` returned `Ok` with a garbage sentinel timestamp for missing paths on **both targets** — neither host API reports absence (BCL `GetLastWriteTimeUtc` returns 1601-01-01, JDK `lastModified()` returns 0), so the documented `Err(FileNotFound)` was unreachable~~ **Fixed (D-progress-555):** `stat` probes `hostFileExists or hostDirectoryExists` before reading the timestamp (cross-target stdlib fix in `std/file.l`, found by the JVM test). | `lyric-stdlib/std/file.l` | (D-progress-555) |
| m-44 | ~~W0002 (quantifier-not-enforced warning) emitted to stdout via `println` on both backends — interleaved with program/tool output~~ **Fixed (D-progress-555):** both backends route through `Console.error`.  Rerouting exposed that `Jvm.Codegen` lacked the `Std.Console` import: stage-1 silently compiled the unresolvable `Console.error` call into a deferred runtime panic (`unsupported method 'error' on the receiver type`) that fired on **every quantifier lowering**.  The missing import is added; the silent-deferral behaviour itself is a compiler-quality gap (unresolvable member calls should be build-time diagnostics). | `codegen/02_exprs.l`, `msil/codegen.l` | #4739 ✅ |
| m-45 | ~~`assert-no-box-jvm.sh` (the epic-#1877 Stage-2 zero-overhead gate) counted `valueOf` calls across the **whole bundled JAR** — the JVM bundled compile packs the transitive stdlib closure into the same JAR, so any legitimate stdlib box (e.g. `Std.FileHost`'s opaque `FileTime`, a boxed epoch-millis `Long` by design) shifted the hand-calibrated budget~~ **Fixed (D-progress-555):** the count is scoped to the closure test's own classes (main + synthesized `$Lambda$N`); budget recalibrated to 3 (the erased `invoke(Object…)Object` ABI boxes each lambda's primitive return — deliberate, not capture overhead).  The MSIL twin was already naturally scoped (stdlib links as a DLL there). | `scripts/assert-no-box-jvm.sh` | (D-progress-555) |
| m-46 | ~~Multi-package JVM manifest builds were an **unbounded process-spawn loop**: `emitProjectJvmInProcess` fell back to `emitProjectJvmViaSubprocess` for >1 package, whose `--internal-project-build` child re-entered `emitProject` with the same multi-package request and re-spawned itself.  Never observed only because no multi-package JVM manifest build had been exercised end-to-end~~ **Fixed (D-progress-558):** the JVM bridge gained a true project entry (`compileProjectToJarBundledWithFeatures`): sibling packages ride the stdlib bundling machinery (registries, call-graph reachability, middle end, codegen) with fatal — not advisory — diagnostics and no J003 skip; the subprocess client is deleted. | `jvm/bridge.l`, `lyric/emitter.l` | #2669 (J6) |
| m-47 | ~~`ldc`'s single-byte operand truncated constant-pool indexes past 255 — `emitPushInt`'s large-literal arm never used `ldc_w` (its float/string siblings did), so a bundled class whose pool grew past 255 before its first large int literal loaded an unrelated entry (VerifyError; hit by Storage.presignedUrl's 604800 contract bound)~~ **Fixed (D-progress-558):** wide-index check added. | `jvm/bytecode.l` | (D-progress-558) |
| m-48 | ~~Bundled stdlib files never got the alias rewrite, so any stdlib package calling its kernel through an aliased import (`import Std.CharHost as Host`) fell to the instance-FFI guess and was **silently J003-skipped — `Std.Char` and `Std.Parse` had never worked on the JVM**, taking char classification and string→number parsing down with them~~ **Fixed (D-progress-558):** `Aliases.rewriteFile` runs on every stdlib file at parse time, before registry collection / call-graph / codegen consume it. | `jvm/bridge.l` | (D-progress-558) |
| m-49 | ~~Same-name overloads in one package collided in the cross-package call registry (name-only keys, first wins): a 3-arg `Std.String.substring` call linked against the 2-arg overload's descriptor — VerifyError at class load~~ **Fixed (D-progress-558):** arity-suffixed registry keys (`…@<argc>`) tried before the name keys; calls relying on parameter defaults fall back to the name key unchanged. | `codegen/06_items.l`, `codegen/04_calls.l` | (D-progress-558) |
| m-50 | ~~Assignment from an erased-`Object` match payload into a primitive-typed `var` (`case Some(n) -> contentLength = n` on `Option[Long]`) stored without unboxing — `lstore` on an `Object` operand, VerifyError~~ **Fixed (D-progress-558):** both `AssEq` arms (plain slot and hoisted cell) coerce the value to the slot type with the same `coerceArgTo` discipline as call arguments. | `codegen/05_stmts.l` | (D-progress-558) |
| m-51 | ~~Four more phantom `lyric.stdlib.jvm.*` kernels (the m-32 pattern): `Std.Math` (tau/log2/truncate/sign), `Std.Uuid` (empty/toString/tryParse), `Std.Char` (isPunctuation/charToInt/intToChar), and all 29 operations of `Std.Json`~~ **Fixed (D-progress-558):** math/uuid/char rewritten over real JDK surfaces (`Character.hashCode` for the char→int cast, `Character.toString(int)+charAt(0)` for int→char, `getType()` for punctuation, `UUID(0,0)`/`toString()`/`fromString`); `Std.Json` is pure Lyric over `Std.Yaml.parseJson` (the JDK has no JSON API) with record-typed handles and a canonical-JSON writer for `GetRawText`; dead `getNumericValue` extern deleted on **both** targets (no consumers). | `_kernel_jvm/{math,uuid,char,json}_host.l`, `_kernel/char_host.l` | #2669 (J6) |
| m-52 | ~~`lyric test` had no `--features` / `--no-default-features` / `--all-features` flags (docs/24 §3 documented them for `lyric test` since D045), so a manifest suite could not select target-gated kernels (`@cfg(feature = "jvm")`) on the non-default target~~ **Fixed (D-progress-558):** flags added with `lyric build`'s grammar and precedence, threaded into the manifest test path's CfgGate + emit requests. | `cli/cli_test.l` | #1444, docs/24 |
| m-53 | ~~Matching on an IMPORTED union through a typed scrutinee derived the case class from the in-package type guess (`Std/JsonHost/YamlValue$YMapping` for Std.Yaml's `YamlValue`) — a class that does not exist (VerifyError / NoClassDefFoundError)~~ **Fixed (D-progress-558):** `resolveCaseClassJvm` trusts the `<scrutClass>$<case>` derivation only when it names a registered case class; otherwise the bundle-wide ctor registry is authoritative. | `codegen/03_match.l` | (D-progress-558) |
| m-54 | ~~List indexing on a receiver whose static type is imprecise (an erased-`Object` match binding, an imported type's in-package guess) emitted `ArrayList.get` with no cast — VerifyError~~ **Fixed (D-progress-558):** the receiver is checkcast to `ArrayList` before the index is pushed (checkcast only reaches the stack top). | `codegen/02_exprs.l` | (D-progress-558) |
| m-55 | ~~An `if` whose then-arm yields a value but whose else-arm is void (`if a { xs.add(true) } else if b { xs.add(false) }` — the trailing else-if lowers as void) routed a result the else-path never produced: the join's store underflowed the operand stack — VerifyError~~ **Fixed (D-progress-558):** mixed-arm ifs degrade to void (the checker only admits the shape in statement position): no else store, no join reload. | `codegen/02_exprs.l` | (D-progress-558) |
| m-56 | ~~The m-42 erased-receiver `.count`/`.length` dispatch emitted its runtime-class branches INLINE at the member-access site — safe only with an empty operand stack; `i < pairs.count` in a while condition evaluates it with `i` stacked, landing branch targets against the empty-stack StackMapTable (VerifyError; hit by `Std.Yaml.getField` once Yaml became bundle-reachable)~~ **Fixed (D-progress-558):** the dispatch moved into a synthesised `__lyricCount(Object)I` static helper every package class carries; the member-access site emits one branch-free `invokestatic`. | `codegen/06_items.l`, `codegen/02_exprs.l` | (D-progress-558) |
| m-57 | ~~Match arms binding different-width payloads to the same-named local (`case YFloat(v)` / `case YInt(v)` — double and long sharing one slot) gave the slot two widths; the join's stackmap frame cannot merge them (VerifyError)~~ ~~**Worked around (D-progress-558)** in `Std.JsonHost` by distinct binding names~~ **Fixed for real (D-progress-563, m-72).** | `codegen/01_types.l` | #2667 (J4) ✅ |
| m-58 | ~~Descriptors written against an IMPORTED Lyric type (a record field `node: YamlValue` in `Std.JsonHost`, method params/returns) carried the in-package class guess (`Std/JsonHost/YamlValue`) — NoClassDefFoundError the first time the verifier checked assignability; constructions of imported union cases picked whichever same-named case registered first (`InvalidDocument` → `Std/Xml/XmlError$InvalidDocument` inside Std.Yaml)~~ **Fixed (D-progress-558):** each package's NON-GENERIC declared types are exposed as dotted FQNs in the same per-package maps the extern-type seed unions (`externSeedForFile`), so importing files' descriptors name the declaring package's real class; construction resolution gained package-scoped ctor-registry keys (`<pkg>::<name>`, own case wins) and match tests validate the derived case class against the case registry with a union-name suffix search fallback. | `bridge.l`, `codegen/06_items.l`, `codegen/01_types.l`, `codegen/03_match.l`, `codegen/04_calls.l` | (D-progress-558) |
| m-59 | ~~`var v: Long = default()` NPE'd at runtime: generic `default()` lowers to `aconst_null` (erased model) and the declared-type coercion checkcast+unboxed the null (`Long.longValue()` on null — hit by `Std.Json.tryGetLong`)~~ **Fixed (D-progress-558):** `default()` initialising a PRIMITIVE-annotated local pushes the declared type's zero value instead of going through the null. | `codegen/05_stmts.l` | (D-progress-558) |
| m-60 | ~~Relational String comparison (`a < b` in Std.Sort's string comparator) emitted `String.equals` + a `nop` placeholder — wrong result AND a stackmap mismatch from the value left on the stack (VerifyError in `Std/Sort$Lambda$2.invoke`, hit by lyric-storage's key sort)~~ **Fixed (D-progress-558):** all four relational ops lower to lexicographic `String.compareTo` vs 0 in both branch emitters (trueLabel and failLabel forms). | `codegen/02_exprs.l` | (D-progress-558) |
| m-61 | ~~Comparing a `long` against an `int` literal (`nv != 42`) fed `lcmp` a (long, int) pair — VerifyError; only ref-vs-primitive mixes were reconciled~~ **Fixed (D-progress-558):** `reconcileCmpOperands` widens the int side with `i2l` (spill-and-reload when the long is on top). | `codegen/02_exprs.l` | (D-progress-558) |
| m-62 | ~~Interface types missing from the imported-type seed: a consumer's interface-typed binding (`bucket: StorageBucket` in the storage test module) carried the in-package guess — NoClassDefFoundError~~ **Fixed (D-progress-558):** non-generic `IInterface` items join the declared-type FQN registration. | `codegen/06_items.l` | (D-progress-558) |
| m-63 | ~~`Std.Core`'s generic Option/Result predicates (`isErr`/`isOk`/`isSome`/`isNone`) linked against nothing on a call the monomorphizer could not specialize (generic functions are never emitted as JVM methods; inference needs a literal or annotated-variable argument) — NoSuchMethodError across the lyric-storage suite~~ **Fixed (D-progress-558):** the four predicates lower to `instanceof` against the runtime case class when the resolved owner is `Std/Core`. | `codegen/04_calls.l` | (D-progress-558) |
| m-64 | ~~`==` on reference operands whose static type is not literally `java/lang/String` (an erased split-segment element, an imported type) compared by IDENTITY (`if_acmpeq`) — two equal strings built independently reported unequal (`segs[i] == ".."` let path traversal through lyric-storage's `isSafeKey`; a **security-relevant** silent miscompile)~~ **Fixed (D-progress-558):** Lyric `==` is value equality on every reference type, so erased/unknown reference operands dispatch through null-safe `java.util.Objects.equals` in both branch emitters (records/unions carry synthesized `equals`, so structural semantics are preserved). | `codegen/02_exprs.l` | (D-progress-558) |
| m-65 | ~~`BAdd`'s int arm lowered its rhs with NO coercion (unlike its JDouble/JFloat siblings): `result + f(1)` fed `iadd` the lambda invoke's boxed `Object` return — VerifyError in `closure_zero_overhead_self_test`, latent on main because CI's no-box gate only DISASSEMBLES that jar, never runs it~~ **Fixed (D-progress-558):** the int arm coerces like its siblings (`checkcast Integer` + unbox for erased refs; no-op for int). | `codegen/02_exprs.l` | (D-progress-558) |
| m-66 | ~~Two-slot primitive captures (`Long`/`Double`, and `Float` via a Double intermediate) resolve to `aconst_null` inside the lambda body — the capture-local bookkeeping mishandles category-2 widths, so `closure_zero_overhead_self_test` tests 3–5 fail at runtime on JVM.  Latent, not a regression: CI's no-box gate only DISASSEMBLES this jar on the JVM side and never runs it (the Int capture case, test 1, was separately fixed by m-65).~~ **Fixed (D-progress-561, rows m-70/m-71 below) — this row was a stale duplicate left un-struck when the fix landed.** Two independent bugs: an operand-stack under-count for receiver-based invokes returning a two-slot value (m-70), and a missing `EParen` case in capture-name collection so a name referenced only inside parentheses was never captured at all (m-71). Verified on a clean rebuild: `closure_zero_overhead_self_test.l` is 18/18 on `--target jvm` (tests 3–5 pass), and `scripts/assert-no-box-jvm.sh` reports 3 boxing calls (within the Stage 2 ≤3 gate). | `codegen/02_exprs.l`, `jvm/lowering.l` | #4798 ✅ |
| m-67 | ~~A dot-named function call through a type name (`ParseError.message(e)`) resolved as a static JDK call once the imported-type seed (m-58) put bundled Lyric types into the extern map — metadata resolution panicked and `Std.Parse` was J003-skipped (#4799)~~ **Fixed (D-progress-559):** `lowerMethodCall` checks the Lyric dot-named funcSigs registration BEFORE the extern static-FFI fast path (a genuine extern JDK type never has one). | `codegen/04_calls.l` | #4799 ✅ |
| m-68 | ~~`_kernel_jvm/parse_host.l` was a phantom `lyric.stdlib.jvm.ParseHost` shim with a DIFFERENT surface than the .NET twin (2-arg vs 4-arg `hostTryParseDouble`), so `Std.Parse` never compiled on JVM even once bundled~~ **Fixed (D-progress-559):** both kernels export the same target-neutral 2-arg surface — .NET wraps its invariant-culture 4-arg `Double.TryParse` extern; the JVM twin is pure Lyric over `Double.parseDouble` with parity guards (hex floats and type suffixes rejected; "Infinity"/"NaN" kept) and a strict trimmed case-insensitive `Boolean.TryParse` mirror. | `_kernel/parse_host.l`, `_kernel_jvm/parse_host.l`, `std/parse.l` | #4799 ✅ |
| m-69 | ~~A generic function's registered JVM sig mapped its own type parameters through the in-package class guess (`unwrapOr[T]` → param/ret `Std/Core/T`), so an unmonomorphized call's descriptor referenced a phantom class — NoClassDefFoundError at link time (hit by `unwrapOr` in parse_tests)~~ **Fixed (D-progress-559):** registry sigs erase the decl's own type params to Object (`genericParamNames` threaded into param and return resolution), and `unwrapOr` lowers through a synthesised `__lyricUnwrapOr(Object, Object)Object` helper (the `__lyricCount` pattern — the monomorphizer does not specialise it here and generic functions are never emitted as methods). | `codegen/06_items.l`, `codegen/04_calls.l` | (D-progress-559) |
| m-70 | ~~Closures rejected with `VerifyError: Operand stack overflow` whenever the body produced or unboxed a TWO-SLOT value (`Double`/`Long`): `LInvokevirtual`/`LInvokespecial`/`LInvokeinterface` tracked their operand-stack effect as a flat `0`, but a receiver-based call returning a two-slot value (`Double.doubleValue()D`, `Long.longValue()J`) pops 1 and pushes 2 (net +1).  Closures pass `maxStack=0` and infer it from `peakStack`, so the under-count made the emitted `maxStack` one slot short (#4798)~~ **Fixed (D-progress-561):** all three receiver-based invokes use the precise `fieldSlotSize(ret) - slotSum(ps) - 1` net delta (the `-1` for the popped receiver), matching the existing `LInvokestatic` treatment.  Only ever RAISES `maxStack`, and only affects methods that infer it. | `jvm/lowering.l` | #4798 ✅ |
| m-71 | ~~A name referenced ONLY inside parentheses in a lambda body (`{ x -> (x.toDouble() * multiplier) }`) was never collected as a capture — `collectRefNamesExpr` had no `EParen` case — so it was read as the null/zero default (an NPE when a `Double`/`Long` capture is unboxed).  MSIL's twin walker already handled `EParen`, so this was JVM-only~~ **Fixed (D-progress-561):** `EParen(inner)` recurses in `collectRefNamesExpr` (capture collection) and `collectBoundNamesExpr` (symmetry). | `jvm/codegen/02_exprs.l` | #4798 ✅ |
| m-72 | ~~The SAME binding name across sibling match arms at DIFFERENT verifier-slot types (`case AsDouble(v)` VDouble then `case AsLong(v)` VLong, both width 2) reused one local slot — but this backend frames each slot with a single verifier type for the whole method (`storeTypes` + entry pre-init), so the match-join frame was unmergeable (VerifyError: Inconsistent stackmap frames)~~ **Fixed (D-progress-563):** `allocSlot` reuses a slot only on verifier-slot-type equality (`sameFrameSlotType`), not merely width — int-like types still share as `VInteger`; `Float`/`Long`/`Double` and distinct ref classes get fresh slots so each slot carries exactly one verifier type.  Supersedes the m-57 distinct-binding-name workaround. | `codegen/01_types.l` | #2667 (J4) ✅ |
| m-73 | ~~`Byte.toInt()` / `.toLong()` / `.toDouble()` on the JVM sign-extended the receiver: Lyric `Byte` is unsigned `0..255`, but a JVM `byte` is signed and sign-extends when reloaded from a field / local / array, so `200.toByte().toInt()` returned `-56` instead of `200` — a silent miscompile diverging from the (correct, `conv.u1`-masked) MSIL backend~~ **Fixed (D-progress-566):** the three widening emitters (`emitToIntJvm` / `emitToLongJvm` / `emitToDoubleJvm`) mask a `JByte` source with `& 0xFF` (`iconst 255; iand`) before widening, matching MSIL and the unsigned-`Byte` spec.  Same unsigned treatment #4551 applied to `JByte` div/rem.  Regression-guarded by `silent_miscompile_guard_jvm_self_test.l` ("Byte widening above 127 stays unsigned"). | `codegen/04_calls.l` | #4855 (J4) ✅ |
| m-74 | ~~`defer` produced invalid bytecode on the JVM across every non-trivial form: a value-position `defer` left the trailing value on the operand stack across the try-region `end_pc` label (VerifyError: "Current frame's stack size doesn't match stackmap"), a trailing / consecutive `defer` emitted an empty `[X, X)` protected region (ClassFormatError: "Illegal exception table range"), and a `panic`-terminated `defer` body left a dead `nop` (the JVoid-statement placeholder) after the `athrow`, creating an empty-stack fall-through into the catch-all handler that clashed with its `{Throwable}` frame.  `defer_self_test.l` passed 6/6 on `--target dotnet` but the suite was never run on `--target jvm`, so all three went unnoticed~~ **Fixed (D-progress-565):** (a) the value-position path stashes the trailing value into a temp *before* closing the region and reloads it *after* the `afterL` join, so both the region-end and join frames see an empty stack; (b) a trailing `defer` (empty suffix) runs its block inline with no handler; (c) `SExpr` statement lowering skips the JVoid placeholder `nop` when the expression already terminated.  `defer_self_test.l` now runs in CI on `--target jvm` (all six forms). | `codegen/05_stmts.l` | #4878 (J4) ✅ |
| m-75 | ~~Range-driven `for` (`for i in 0 ..< n`, `for i in a ..= b`) panicked at compile time with `Jvm.Codegen: ERange not supported in JVM codegen` — the JVM `SFor` lowering ran `lowerExpr` on the iterable, which rejects `ERange`, so any counted loop aborted the build.  `for_loop_slice_self_test.l` covered ranges (incl. `1L ..= 5L`) but was run only on `--target dotnet`, so the gap went unnoticed~~ **Fixed (D-progress-567):** `SFor` special-cases an `ERange` iterable and lowers it through a new `emitCountingForJvm` (mirrors MSIL's `emitCountingForMsil`) — evaluate `lo` into a counter and `hi` once into a bound, loop `while i < hi` (half-open) / `i <= hi` (closed) with the pattern bound from the counter, `break`/`continue` wired to exit/increment; Int and Long counters both supported (`lcmp` for Long).  Open-start / open-end ranges panic (unbounded), matching MSIL.  Covered on **both** targets by a new range-only `range_for_jvm_self_test.l` (Int + Long, half-open + closed, empty, break/continue, nesting).  (`for_loop_slice_self_test.l` stays dotnet-only — its JVM slice-iteration erased-element path is a separate open gap, #2595.) | `codegen/05_stmts.l` | #4878 follow-up (J4) ✅ |
| m-76 | ~~An **unannotated** `val` bound to an erased generic payload (the value arm of a `match` on a `Result`/`Option`, or the result of `?`) was tracked as `java/lang/Object` — a generic case's type-param field (`Ok(value: T)`) erases to `Object` on the JVM — so `x + y` picked the reference `+` and **string-concatenated** (`2 + 2` → `"22"`) and `x - y` **VerifyError'd** at class load. Hit the most common Lyric error-handling idiom (`let x = foo()?; let y = bar()?; x + y`); MSIL was correct (reifies the field).~~ **Fixed (D-progress-554):** `lowerMatchExpr` recovers the scrutinee's generic instantiation (`scrutineeGenericArgs` reads the matched callee's new `JvmFuncSig.retGenericArgs`) and threads it through `lowerPatternBind`; a `PConstructor` field whose new `JvmCaseField.paramIdx` selects a concrete scrutinee arg is `checkcast`+unboxed to its primitive at the bind site (`bindCaseField`), so the bound local is a real `int`/`long`/`double`/`float`/`boolean`. The `?` form is fixed by construction (its desugared scrutinee is the same `ECall`). Gotcha: `retGenericArgs` must carry **no default** (a defaulted record field constructed cross-package miscompiles under the self-hosted MSIL emitter — `InvalidProgramException` in `collectDeriveFreeSigs`), like `isIface`. Covered on **both** targets by `erased_generic_arith_jvm_self_test.l` (8 cases: Int/Long/Double payloads, user generic union, guard, `match` + `?` forms, `-` VerifyError case). | `codegen/{01_types,03_match,06_items}.l`, `bridge.l` | #4877 (J4) ✅ |
| m-77 | ~~m-76 fixed the *direct* `match callee(...)` and `?` forms but left the equally-common `let r = callee(...); match r { … }` variable-bound scrutinee still boxing the payload — same string-concat / VerifyError miscompile as #4877.~~ **Fixed (D-progress-569):** `FuncCtx` gains a `varGenericArgs` map; `let`/`var` binding lowering records the initialiser's `scrutineeGenericArgs` against the bound name (`recordVarGenericArgs`, remove-then-add for shadow-safety), and `scrutineeGenericArgs` gains a single-segment `EPath` case that recovers them (typed `optGenericArgs` helper), so the bind-site unbox fires for the variable-scrutinee form. No-default / typed-helper discipline per D-progress-554; verified against the pinned F# mint. Two new self-test cases (Int `val`-bound, Long `var`-bound). Method-call scrutinees (#4933) and `JChar`/`JByte` unbox (#4942/#4941) remain follow-ups. | `codegen/{01_types,03_match,05_stmts,06_items}.l` | #4938 (J4) ✅ |
| m-78 | ~~m-76/m-77 left the method-call scrutinee form `match recv.method(...) { … }` (method returning a generic instantiation) still boxing the payload — same string-concat / VerifyError miscompile.~~ **Fixed (D-progress-570):** `scrutineeGenericArgs` gains an `EMember`-callee case; an in-body / `impl` method registers under `<receiverClass>#<method>` with its `retGenericArgs`, so `receiverClassOf` (resolving a local/param via `ctx.types` or `self` via `ctx.selfClass`) + `instanceMethodRetGenericArgs` recover them and the bind-site unbox fires. Covered by a new **JVM-only** `method_scrutinee_jvm_self_test.l` — the test needs an in-body method to define the callee, and in-body methods break MSIL entry-point emission (#4947); MSIL reifies generics so never had this bug. | `codegen/03_match.l` | #4933 (J4) ✅ |
| m-79 | ~~`emitUnboxObjectTo` handled `JInt`/`JLong`/`JDouble`/`JFloat`/`JBoolean` but not `JChar`/`JByte`, so a `Char`/`Byte` erased payload stayed boxed. Surfaced a second bug: `LBoxByte`/`LBoxShort` boxed a value ≥128 via `valueOf` **without narrowing**, so `Byte.valueOf`'s cache index overran → `ArrayIndexOutOfBoundsException` at construction of e.g. `Filled(item = 200.toByte())`.~~ **Fixed (D-progress-571):** `emitUnboxObjectTo` gains `JChar` (`charValue`) and `JByte` (`byteValue`, signed — the canonical in-slot form) arms; `LBoxByte`/`LBoxShort`/`LBoxChar` emit `i2b`/`i2s`/`i2c` before `valueOf`, fixing `Byte`/`Short` boxing everywhere. Covered by Char / Byte-above-127 / Bool cases in the dual-target `erased_generic_arith_jvm_self_test.l` (Float-payload test deferred — `Convert.ToSingle` AOT-trim in source-build sandboxes, #4932 Float half). | `codegen/03_match.l`, `lowering.l` | #4942/#4941 (J4) ✅ |
| m-80 | ~~A `val`/`var`-bound generic result captured into a lambda and matched **inside** the lambda body still boxed its payload: the closure body lowers in its own `FuncCtx` whose `varGenericArgs` started empty, so `scrutineeGenericArgs` could not recover the captured binding's instantiation and `x + delta` string-concatenated / VerifyError'd one scope deep.~~ **Fixed (D-progress-574):** `lowerLambda` seeds the closure body ctx's `varGenericArgs` from the enclosing `ctx.varGenericArgs` (excluding shadowing lambda param names); `lowerGeneratorBody` needs no change (top-level body, no enclosing var scope). Follow-up #4959 (`JShort` unbox arm) closed as not-needed — `Short` is not a surface type, so `concreteTy` is never `JShort`. Covered by captured `Int`/`Long` cases in `erased_generic_arith_jvm_self_test.l` (now 15 tests, both targets). | `codegen/02_exprs.l` | #4945 (J4) ✅ |
| m-81 | ~~Record-typed `Map` keys did not hash/compare structurally on JVM: `java.util.HashMap` dispatches `hashCode()`/`equals(Object)` virtually, and a `@derive(Equals)`/`@derive(Hash)` record never got real classfile overrides for either — `Jvm.Lowering.lowerDeriveEquality` (B122) had the bytecode-emission logic but was never wired to a real user record, only to a standalone, CI-unwired self-test (`self_test_b122.l`) that hand-built its input directly.~~ **Fixed (D-progress-577):** extracted `buildDeriveEqualsFunc`/`buildDeriveHashCodeFunc` (`lowering.l`, both now uniformly `LFunc`-based — `hashCode` previously bypassed the normal pipeline via raw `Assembler` calls) and wired `appendDeriveOverridesJvm` into `Jvm.Codegen.lowerRecord`'s `IRecord`/`IExposedRec` sites, mirroring MSIL's `appendDeriveOverridesMsil` (#1480). `map_key_self_test.l` (previously "MSIL target only") is 4/4 on `--target jvm` too, now dual-target in CI. `equality_self_test.l` goes 1/10 → 5/10 on JVM (remaining failures are separate, untouched gaps: nested-record recursive `==`, distinct-type derives, `@derive(Show)`). | `jvm/lowering.l`, `codegen/06_items.l` | #4982 Finding 1 ✅ |
| m-82 | ~~`lowerConstruction` emitted `new; dup` for a union-case/record constructor call *before* lowering its arguments. An argument with internal branches (e.g. `mapGet`'s `containsKey`-gated `Some`/`None` construction, or any `if`/`match` expression nested directly as a constructor argument — `Ok(mapGet(...))`, `Ok(if p { Some(...) } else { None })`) executed those branches with the outer constructor's two uninitialized-object stack slots still present underneath, desyncing the argument's own StackMapTable (computed assuming an empty stack) from the actual runtime shape — `VerifyError: Inconsistent stackmap frames`. Reproduced independent of impl-dispatch and independent of `mapGet` specifically.~~ **Fixed (D-progress-580):** every constructor argument now evaluates into a fresh local *before* `new; dup`; the constructor loads from those temps afterward, so any argument's internal branches always see an empty stack. `map_option_self_test.l`'s "impl get()" case (the #4982 Finding 3 repro) is green, plus a new general (non-`mapGet`) case; promoted to dual-target CI. Zero regressions across ~35 JVM self-tests. | `codegen/04_calls.l` | #5003 ✅ |
| m-83 | ~~m-82's fix made every constructor argument (even a bare literal) allocate a local temp before `new; dup`. A `wire { }` block's synthesized `bootstrap()` method computes its `max_locals` as just the `@provided`-parameter slot count, ignoring any locals a binding's own construction now needs — CI (not the local sandbox, which never got this far due to an unrelated `Convert.ToSingle` limitation, D-progress-543) caught `WidgetWire.bootstrap()` `VerifyError: Local variable table overflow` for `singleton widget: Widget = Widget(size = 17)`, a plain single-field record singleton.~~ **Fixed (D-progress-581):** `lowerWireBindingInit` returns its binding's own `FuncCtx.slotTicker.count`; `LWireBinding` carries it as `tempSlots`; `bootstrap()`'s `max_locals` is now `max(providedParamSlots, max binding.tempSlots)`. Verified against a minimal standalone repro that reproduces the exact CI `VerifyError` pre-fix and passes clean post-fix; zero regressions across the JVM self-test sweep. Found (and filed separately, out of scope here) a pre-existing, unrelated gap: a wire binding referencing an earlier binding from a *nested* expression position (not the bare top-level init) still `VerifyError`s. | `jvm/lowering.l`, `codegen/06_items.l` | #5011 follow-up, #5013 (nested-ref gap) ✅ |
| m-84 | ~~Three bugs in the `wire { }` lowering path, found and fixed together (#5013/#5015/#5020): (1) a binding referencing an earlier binding from a *nested* expression position (e.g. `contents = widget` as a named constructor argument, not the bare top-level init) silently resolved to `null` instead of `getstatic`; (2) `lowerWire`'s `bootstrap()` `max_stack` was hardcoded to `3`, wrong for any constructor with 2+ fields (`2 + n_fields` after D-progress-580); (3) `registerStaticWireSig`'s `bootstrap` registration always claimed zero parameters regardless of `@provided` members, so every call site with a `@provided` param resolved against the wrong descriptor — `NoSuchMethodError`, or a corrupted operand stack that surfaced as an unrelated-looking stackmap-frame `VerifyError` later in the calling method.~~ **Fixed (D-progress-582):** (1) `FuncCtx` gained `wireClassName`/`wireBindingTypes`; the `EPath` fallback chain checks them ahead of the nullary-case/module-val fallbacks. (2) `bsMaxStack` now comes from `assembleCodeInferred`'s `asm.peakStack` tracking instead of a hardcoded constant. (3) `bootstrap`'s registered signature now includes every `@provided` param's real type. New dual-purpose test (`BoxWire` in `j3_lowering_self_test.l`) exercises all three at once; zero regressions across the JVM self-test sweep. Surfaced two further gaps while verifying, filed separately: #5021 (MSIL — wire `bootstrap()`/accessor calls have never resolved at all, on *any* wire, not just `@provided` ones — a significant gap on the primary `.NET` target) and #5022 (JVM — a record `impl`ing an interface with an empty-bodied method fails class load with `ClassFormatError`). | `jvm/lowering.l`, `codegen/{02_exprs,06_items}.l` | #5013, #5015, #5020 ✅ |
| m-85 | ~~A record implementing an interface with an **empty-bodied** method (`func log(msg: in String): Unit { }`) failed class load with `ClassFormatError: Arguments can't fit into locals` — `inferMaxLocals` scans a method's instructions for the highest load/store-referenced slot, but a body that never reads/writes one of its own parameters emits no such instruction, so it undercounted below the parameter frame's own real slot requirement (`this` + one slot per param).~~ **Fixed (D-progress-584):** `lowerFuncImpl`'s `actualMaxLocals` is now `max(paramSlotCount, inferMaxLocals(f))` — a floor derived from the already-computed parameter-slot count, not a replacement, so bodies that genuinely need more slots than their parameter frame are unaffected. `wire_di_self_test.l` (whose own `WireConsoleLogger.log` has exactly this shape) no longer hits the crash and is un-parked from placeholder assertions to real `bootstrap()`-invoking ones (`--target jvm` only in CI; `--target dotnet` blocked on #5021). Zero regressions across the JVM self-test sweep. | `jvm/lowering.l` | #5022 ✅ |
| m-86 | ~~A generic type parameter instantiated to an interface/record/union type (`Result[Shape, String]`'s `Ok` payload) erases to `Object` on the JVM; extracting the payload at a match-bind site and calling a method on it (`case Ok(s) -> s.area()`) panicked ("no matching instance or inherited method for `java.lang.Object.area()`") since no `checkcast <Shape>` was ever emitted before dispatch.~~ **Fixed (D-progress-585):** `emitUnboxObjectTo` gains a `JRef(cls)` arm emitting `checkcast <cls>` (skipped only when `cls` is the unresolved `java/lang/Object` erasure); `bindCaseField` also threads a *nested* generic instantiation (`Result[Option[Shape], String]`'s inner `Option[Shape]`) onto the bound name's `varGenericArgs` so a match-of-a-match recovers it too. A regression the `JRef` arm exposed in `mapGet` (an actually-generic function's declared return type is its own type PARAMETER name, not a resolved instantiation) was caught and fixed in the same change via `returnTypeGenericArgsFiltered`. `stdlib_generic_iface_self_test.l` (20 tests, previously JVM-skipped) is 20/20 and promoted to CI; zero regressions across the JVM self-test sweep after the safety-guard fix. A second regression (cross-package extern types, `Std.Time`'s `Instant`) and three follow-up review findings (`registerIfaceSig`/opaque accessors not covered, `registerInstanceSigErased` never saw real `externTypes`, a naming duplication) were fixed in the same D-progress-585/586 arc — see D-progress-586. | `codegen/{01_types,03_match,06_items}.l` | #3613 ✅ |
| m-87 | ~~`_kernel_jvm/file_host.l`'s `deleteRecursively` classified each directory entry via `File.isDirectory()`, which follows symbolic links — a symlink pointing at a directory was recursed into and its target's contents deleted, instead of the symlink itself being unlinked.~~ **Fixed (D-progress-587):** new `isSymlinkJvm` resolves via `java.nio.file.Files.isSymbolicLink` (`lstat` semantics, does not follow the final component); the recursion gate is now `d.isDirectory() and not isSymlinkJvm(d)`. Parity with the native-target fix (#4833/#4805). `file_jvm_self_test.l` gains a regression case creating a real directory symlink via `ln -s`; confirmed fails pre-fix, passes post-fix. Pure stdlib fix, no compiler-source rebuild needed. | `_kernel_jvm/file_host.l` | #4840 ✅ |
| m-88 | ~~`lyric-resilience`'s `Resilience.Kernel.Jvm` was a forward-declaration stub (`circuitIsOpen` always `false`, everything else a no-op) while `Resilience.Kernel.Net` was fully wired against a `ConcurrentDictionary` — `Retry`/`CircuitBreaker` silently did nothing useful on JVM.~~ **Fixed (D-progress-588):** real kernel using `java.util.concurrent.ConcurrentHashMap` as its raw erased type (no `@externTarget`-style generic-member emission needed, sidestepping the #3432 blocker) plus a per-entry `ReentrantLock` (JVM has no callable `Monitor.Enter`/`Exit` equivalent) guarding the same state-machine logic as the `.NET` kernel. New CI step runs the full `resilience_tests.l` suite on `--target jvm --features jvm` (this session's sandbox hits the same pre-existing `Convert.ToSingle` limitation other `Std.Testing`-importing JVM self-tests hit; verified instead via a standalone `Std.Testing`-free manifest exercising the real state machine end-to-end, and by inspecting the built JAR's class list). | `lyric-resilience/src/_kernel/jvm/resilience_kernel.l` | #5037 ✅ |
| m-89 | ~~`Std.Random` and `Std.SecureRandom` were completely non-functional on `--target jvm` — every function was a phantom-class `@externTarget` stub (`@externTarget("lyric.stdlib.jvm.RandomHost.…")` naming a Java class that never existed) that crashed with `VerifyError: Operand stack underflow` the moment it actually executed. #736 (CRITICAL, closed 2026-05-20) fixed the package-name-collision symptom but never replaced the phantom implementations, and no self-test exercised either module on JVM until PR #5058's new resilience JVM CI step called into `Std.Random` for the first time.~~ **Fixed (D-progress-589):** both kernels rewritten pure-Lyric over the JVM auto-FFI (`java.util.Random` / `java.security.SecureRandom`), mirroring the `time_host.l`/`file_host.l` phantom-class elimination pattern (D-progress-543). Verified via standalone repros exercising the full public surface of both modules (bypassing `Std.Testing`'s sandbox-only `Convert.ToSingle` limitation). | `_kernel_jvm/{random_host,secure_random_host}.l` | #736 ✅ |

**Update (D-progress-572):** #4947 (the MSIL entry-point corruption m-78 cites
as the reason `method_scrutinee_jvm_self_test.l` stayed JVM-only) is fixed —
`lowerRecordMsil` now emits real MethodDef rows for in-body methods, back in
sync with the row budget the entry-point pre-scan reserves. Moving
`method_scrutinee_jvm_self_test.l` to a dual-target file is unblocked but not
done as part of D-progress-572; it remains open follow-up work.

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
- **M-5/m-5 DONE (D-progress-575).** Nested-generic-union-case construction
  (`Result[Option[T], E]`) is verified working; the deeper Map/List subscript
  codegen bugs #1707's original closure had missed are fixed (see m-5 above).
  Broader cross-package generic monomorphization beyond `monoFileWithImports`
  remains an open follow-up.
- B-2/M-12: real async lowering (futures / virtual threads per `docs/18` §14)
  and lazy generator synthesis — parity with MSIL #2070 Phase 5.
- M-17: JDK 24+ `scope` support.
- **Acceptance:** async + generator + generics self-tests on `--target jvm`.

### J5 — Eliminate F# host debt and ship Maven (self-hosting + ecosystem)
- **M-8 DONE:** `Lyric.Jvm.Hosts` (`JvmHosts.fs`) byte-builder/constant-pool
  deleted; `jvm/_kernel/kernel.l` is a pure-Lyric `ByteWriter`/`ConstantPool`
  using only arithmetic and audited BCL externs. No `@externTarget` into F# host code.
- **M-6 DONE (parsing):** `manifest.l` parses `[maven]` / `[maven.options]` into
  `MavenSection` (`MavenEntry` coordinate/version pairs, `repositories` defaulting
  to `["central"]`, optional `java_version`).  Covered by `manifest_self_test.l`.
- **M-7 partial DONE (resolver wire-up):** `cli_restore.l:restoreMavenJars`
  invokes `lyric-resolver.jar` via JSON stdin/stdout protocol, writes
  `target/restore/jvm-classpath.txt`.  `cli_build.l:buildProject` injects
  `LYRIC_FFI_JARS` before `emitProject` (JVM auto-FFI) and writes
  `<outDir>/module-path.txt` after a successful JVM build.  A `make maven-resolver`
  Makefile target builds `resolver/pom.xml` into `lyric-resolver.jar`.
  - **Remaining gap:** `lyric-resolver.jar` must be pre-built and placed beside the
    `lyric` binary (or `LYRIC_MAVEN_RESOLVER` set).  Pre-distribution of the JAR
    alongside the `lyric` binary and lock-file SHA verification (`B0050`/`B0054`)
    are deferred to a follow-up.
- **m-8 DONE:** `loadClass` negative-result cache implemented (`ctx.missKeys`).
- **m-9 DONE:** `findBestConstructor` uses explicit `>= 0` threshold (#2226).
- m-7/M-15: Windows `LYRIC_FFI_JARS` path-split (`:` vs `;`) and abstract-type
  guard / `java/lang/Object` walk remain open.
- **Acceptance:** an ecosystem library with a `[maven]` table builds and runs
  on `--target jvm` from a checkout with `lyric-resolver.jar` present.

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
- **M-11 (DONE, D-progress-519):** `_kernel_jvm/process_capture_host.l` fully
  rewritten as pure JVM auto-FFI — no F#/Java shim, no `@externTarget`.
  `java.lang.ProcessBuilder(List<String>)` spawns the child (auto-FFI matches
  `List[T]`/`ArrayList` to the `List` parameter via a new reference-subtype
  score-1 path in `auto_ffi.l`); stdin is written as UTF-8 bytes via
  `stringToUtf8Bytes` intrinsic + `OutputStream.write(byte[])`; stdout/stderr
  drain incrementally inside the `isAlive()` poll loop (`InputStream.available()`-
  bounded reads into `ByteArrayOutputStream`); wall-clock timeout polled via
  `System.currentTimeMillis()` (TimeUnit enum skipped by the resolver, so
  `waitFor(long,TimeUnit)` is unavailable); timeout triggers
  `Process.destroyForcibly()` with sentinel `exitCode = -2`; output converted via
  `JBAOS.toString("UTF-8")`.  Returns a Lyric `ProcessCaptureResult` record.
  Unblocked by D-progress-513 (m-14, #3307) and D-progress-514 (m-15, #3334).
  Verified by `lyric-compiler/jvm/process_capture_jvm_self_test.l` (10 cases:
  stdout, stderr, stdin delivery, multi-word args, quoting round-trip, exit code
  0/1/42, timeout path), wired in CI.  The `lyric-storage` local-fs JVM kernel
  (#1444/#1840) remains **BLOCKED on M-4** (#2444).
- **Acceptance (MET for M-9/M-10/M-11; storage blocked on M-4/#2444):**
  `hash_jvm_self_test.l` gates M-9/M-10; `process_capture_jvm_self_test.l`
  gates M-11 (10 real subprocess assertions on `--target jvm`).  `lyric-storage`
  kernel waits on JVM `@cfg` erasure (#2444).

### J7 — Testing, distribution, and the acceptance gate
- M-14: expand the self-hosted `--target jvm` pipeline suite well beyond the
  current 4 programs; convert representative `self_test_b*.l` (or new
  `@test_module` tests) to run through the **compile pipeline**, not just the
  emission library, and delete the F# `JvmLoweringB*Test.fs` wrappers as the
  native path subsumes them.
- B-11/#676: ship the full JUnit 5 `LyricTestEngine` so `lyric test --jvm`
  executes tests.
- M-18: `lyric run --target jvm` (#674) ships; `main(args: slice[String]): Int`
  argv forwarding and `System.exit` exit-code propagation shipped in
  D-progress-543 (#3303 fixed). `lyric bench --target jvm` (#680) works — the
  JVM `Std.Time` blocker (#3302) was fixed by the pure-Lyric
  `_kernel_jvm/time_host.l` rewrite. GraalVM native-image (#675/#1975) still
  outstanding.
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
