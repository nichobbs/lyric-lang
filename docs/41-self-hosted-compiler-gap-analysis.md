# 41 — Self-hosted compiler gap analysis vs. language reference (production readiness)

_Status: **Re-audited 2026-05-29** on branch `claude/self-hosted-compiler-review-ibJii`.
This is a full re-audit of the self-hosted Lyric compiler against
`docs/01-language-reference.md` for the **`--target dotnet` (MSIL) channel only**.
It supersedes the original 2026-05-20 draft, which is now substantially stale —
the compilation-pipeline disconnect it called CRITICAL has since been fixed, the
self-hosted MSIL backend grew enum/interface/opaque/protected/aspect/derive
coverage, and the #1442 merge added closed-generic instance tracking. Where this
re-audit corrects a 2026-05-20 finding the change is called out in §11._

_JVM is **out of scope** for this audit (deliberately deferred per the review
brief). The goal measured against is a **functionally complete, production-grade
compiler written in Lyric — no F# shims, no workarounds — supporting all
language features on the .NET runtime and AOT-compilable.**_

_All file:line citations are to the working branch at the time of audit. The
audit was performed by reading the current source, not by trusting prior docs._

---

## §1  Executive summary

The headline finding of the 2026-05-20 draft — "neither self-hosted backend
invokes the self-hosted middle-end" — is **no longer true**. The default
`lyric build`/`lyric run --target dotnet` path is now **fully self-hosted and
in-process**: the AOT trampoline → Lyric-emitted `cli.l` → `emitter.l` →
`Msil.Bridge` chain runs the complete middle-end
(`parse → alias-rewrite → typecheck → modecheck → contract-elaborate → derive →
mono → weave → lambda-lift → codegen → contract-metadata embed`) and writes PE
bytes directly, with **no F# `--internal-build` subprocess hop** for .NET and no
`System.Reflection.Emit`. That is a genuine, large advance and the bands below
should not re-litigate it.

What remains between today's state and "production-grade, all features, .NET,
AOT" falls into **five bands**, ordered by how badly they break the production
bar:

1. **The front-end does not reject invalid programs (CRITICAL).** The
   self-hosted type checker is a bottom-up, error-tolerant *inference* pass, not
   a sound gatekeeper. ~12 expression forms infer `TyError`, which `typeEquiv`
   treats as "matches anything", so entire classes of type error are
   unreachable. There is no match exhaustiveness check, no visibility
   enforcement, no opaque representation-hiding, no impl/interface conformance,
   and no §5.2 parameter-mode enforcement. Worse, on the **single-file** build
   path the checker's diagnostics are downgraded to advisory
   (`msil/bridge.l:92`) while the **multi-package** path aborts on them
   (`bridge.l:395`) — the same source can build on one path and fail on the
   other.

2. **Several backend constructs silently miscompile (CRITICAL).** Not panics —
   *silent wrong code*: `?` propagation (`EPropagate`) is a no-op, `await`/`spawn`
   run synchronously and return the unwrapped/awaitable value, `async func`
   returns a bare value instead of `Task[T]`, `defer` runs its body inline
   immediately instead of at scope exit, and `==` on records/distinct types is
   reference equality (the
   derived `equals` method is never dispatched). Each of these compiles without
   error and produces a wrong program — the failure mode the project standard
   most explicitly forbids.

3. **Async/await has no self-hosted implementation (CRITICAL).** There is no
   `IAsyncStateMachine` / `ValueTask` synthesis and no lazy
   `IAsyncEnumerable[T]` generator in `lyric-compiler/msil/`. The real
   implementation (~110 KB of F#: `AsyncStateMachine.fs` + `AsyncGenerator.fs`)
   lives only on the legacy F# path, which the self-hosted CLI no longer routes
   to. This is the single largest remaining port.

4. **Generic *types*, key item kinds, and FFI shapes are erased or stubbed
   (HIGH).** User generic types (`record Box[T]`, `union Tree[T]`) are
   type-erased to a single non-generic TypeDef with `object` fields; protected
   types emit **zero locking**; `@projectable` opaque twins are never generated;
   range-subtype bounds are dropped (no validation); wire blocks drop
   `bind`/`scoped`/`provided`; default/named/`out`/`inout` arguments are
   mis-handled. _(An `@externTarget` whose signature touches a class/object
   type used to emit a runtime-throw stub; that is now resolved — #1504
   part 1 — encoding real `TypeRef`-backed MemberRefs.)_

5. **Two F# DLLs are still load-bearing at runtime and AOT is unconfigured
   (HIGH).** _(The PE `Msil.Kernel.ByteWriter` was a `Lyric.Jvm.Hosts.dll`
   boundary on every emitted byte; #1492 replaced it with a pure-Lyric
   `List[Byte]` buffer — `System.BitConverter` is the only host extern — with
   byte-identical output, so `--target dotnet` no longer routes bytes through
   that F# DLL.)_  Core stdlib kernels
   (`http`/`process` still — `console`/`env`/`log` migrated to direct BCL
   externs in #1493) extern into `Lyric.Emitter.dll` —
   the same assembly that carries the Reflection.Emit F# emitter. No
   `<PublishAot>` is set anywhere, so the "AOT-compilable" goal is currently
   aspirational.

**Bottom line.** The pipeline is now the right shape and a large slice of the
language works end-to-end on self-hosted .NET. But a non-trivial program can
today (a) pass a non-gating type check, (b) hit a silent miscompile of `?`,
`await`, `defer`, or `==`, or (c) drag two F# DLLs (one Reflection.Emit
laden) onto its runtime closure. None of those is acceptable at the project's
production bar, and AOT is not yet wired.

---

## §2  The default `--target dotnet` pipeline (verified from source)

```
lyric build foo.l                       (default target; "jvm" is the only other value, cli.l:358-365)
  └─ bootstrap/src/Lyric.Cli.Aot/Program.cs:20      pure trampoline → Lyric.Cli.Program.main
       └─ lyric-compiler/lyric/cli.l                buildOne → Emitter.emit(req, target=Dotnet)
            └─ lyric-compiler/lyric/emitter.l        Dotnet → emitMsilInProcess (NO subprocess)
                 └─ lyric-compiler/msil/bridge.l     compileToMsilWithVersion
                      ├─ parse                       reportAndAbort     → FATAL   (bridge.l:64)
                      ├─ AliasRewriter.rewriteFile                              (bridge.l:89)
                      ├─ TypeChecker.checkWithImports reportDiagnostics → ADVISORY ⚠ (bridge.l:91-92)
                      ├─ ModeChecker.checkFile        reportAndAbort     → FATAL   (bridge.l:94-95)
                      ├─ ContractElaborator.elaborateFile                       (bridge.l:97)
                      ├─ Derives.deriveFile           (transform)               (bridge.l:100)
                      ├─ Mono.monoFile                reportAndAbort     → FATAL   (bridge.l:103-104)
                      ├─ Weaver.weaveFileWithDiags    reportAndAbort     → FATAL   (bridge.l:135-136)
                      ├─ liftLambdasMsil → addPackageTokens → codegenMPackage    (bridge.l:141-148)
                      ├─ embedLyricContract (Lyric.Contract resource)            (bridge.l:162)
                      └─ lowerMPackageWithCtx → raw PE bytes → Std.File.writeBytes(bridge.l:165-168)
```

- **No `--target dotnet-legacy`.** The CLI maps anything ≠ `"jvm"` to `Dotnet`
  (`cli.l:358-365`). The string `dotnet-legacy` survives only in stale `panic`
  messages in `codegen.l` (1852/1855/1858/1931) — pointing users at a flag they
  can no longer select.
- **Project / multi-package builds are self-hosted too.** `Emitter.emitProject`
  → `emitProjectInProcess` → `Msil.Bridge.compileProjectToMsilWithRestoredAndVersion`
  (`emitter.l:531/599`, `bridge.l:280`), including cfg feature erasure, in-process
  restored-dependency loading, per-package import scoping (#1378/#1435), and
  manifest version threading. The F# `--internal-project-build` subprocess is
  invoked **only for `--target jvm`** (`emitter.l:704`).
- **PE emission is genuine direct-byte assembly** — `pe.l`/`assembler.l`/
  `tables.l`/`heaps.l` write raw ECMA-335 bytes. There is **no**
  `System.Reflection.Emit`, `PersistedAssemblyBuilder`, `ManagedPEBuilder`,
  `DynamicMethod`, or `ILGenerator` in the self-hosted MSIL tree, and extern
  resolution is table-driven, not reflection-driven (`ffi.l:191-196`). This is
  AOT-shaped.

---

## §3  Consolidated gap inventory (severity-ordered)

Severity is judged against "production-ready self-hosted .NET compiler
supporting all language features."

### CRITICAL

| # | Gap | Evidence | Effort |
|---|---|---|---|
| C1 | Type checker is advisory on the single-file build path (`reportDiagnostics`), fatal on the project path (`reportAndAbort`). Type-broken single files compile to broken IL silently; same source diverges between paths. | `bridge.l:92` vs `bridge.l:395` | S (flip) gated on C2 |
| C2 | Type checker is unsound: ~12 expr forms infer `TyError`, a universal unifier; no match exhaustiveness; no record-ctor checking; `?`/lambda/tuple-destructure/index/`if`/`match` results untyped. | `typechecker_exprs.l:680-693`, `typechecker_types.l:130-131`, `typechecker_stmts.l:14-51` | L |
| C3 | `?` propagation (`EPropagate`) and `try?` (`ETry`) are no-ops — `x?` compiles as `x`, no unwrap, no early-return. | `codegen.l:1787-1793` | M |
| C4 | `await`/`spawn` lower synchronously; `async func` returns a bare value, not `Task[T]`; no `IAsyncStateMachine`. Silent miscompile of every async program. | `codegen.l:1755-1758,1782-1784,983-999`; no state machine in `msil/*` | XL |
| C5 | Async generators use eager collect-all into `List<object>`, not lazy `IEnumerable`/`IAsyncEnumerable`; return type forced to List; unbounded generators buffer forever. | `codegen.l:1760-1780,983` | XL |
| C6 | **Fixed (#1530).** Indexed assignment `a[i] = v` previously silently discarded the store (value evaluated then popped); the `EIndex` assignment target now emits `List[object]::set_Item`. Compound indexed forms (`a[i] += v`) hard-fail with a clear build error pending element-type plumbing (#1481). | `codegen.l` `lowerAssignExprMsil` EIndex arm | Resolved |
| C7 | `defer` runs its body inline immediately, not at scope exit (and not on early-return/exception). | `codegen.l:3817-3819` | L |
| C8 | User-defined generic *types* are type-erased to one non-generic TypeDef with `object` fields; type-param field `T` resolves to a bogus `MClass("Pkg.T")`. No GenericParam rows; no per-type mono. | `codegen.l:4718-4791,1235,1268`; no GenericParam in `lowering.l` | L |
| C9 | ~~`@externTarget` whose signature mentions any class/object type emits a runtime-throw stub instead of a real call.~~ **Resolved (#1504 part 1):** class-typed params/return now encode as real `ELEMENT_TYPE_CLASS + TypeDefOrRef` MemberRefs (`buildFfiMethodSigCtx`/`resolveFfiClassTypeRef`), resolving extern types via `externTypeNames` → CLR TypeRef. Verified end-to-end (`StringBuilder` ctor + instance calls). Remaining #1504 parts: unresolved-type diagnostic (H8), instance/non-void auto-FFI (H9), generic externs (blocked on #1497). | `codegen.l` `buildFfiMethodSigCtx` | ✅ |
| C10 | Opaque representation-hiding not enforced: fields readable and types constructable from outside the declaring package. | `typechecker_exprs.l:479-487`, `typechecker_checker.l:152-155` | M |
| C11 | `impl`/interface conformance never checked (`IImpl(_) -> {}` no-op); missing/mismatched methods not reported; default-interface-method bodies discarded (emitted abstract). | `typechecker_checker.l:211`; `codegen.l:6275-6291` | M |
| C12 | Protected types emit a plain record with **no lock field and no Enter/Exit** — zero mutual exclusion despite the doc-comment promising Monitor locking. | `codegen.l:5373-5482` | L |
| C13 | §5.2 parameter modes (`in` no-rebind, `out` definite-assignment, `inout` mutable binding) entirely unenforced front-end and ignored in codegen (all params by-value). | mode checker: absent; `codegen.l:4515-4524,4594-4600` | M |

### HIGH

| # | Gap | Evidence | Effort |
|---|---|---|---|
| H1 | `==` on records/distinct types is reference equality (static `Object.Equals`); the derived `equals` method is never dispatched, and `@derive(Hash)` emits `hash` not a `GetHashCode` override. | `codegen.l:1984-1998`; `derives.l:14-23` | M |
| H2 | `@projectable` opaque twin + `toExposed`/`fromExposed` never generated — `isProjectable` is computed but never read in `lowerMOpaque`. | `codegen.l:6324-6330`, `lowering.l:1849-1944` | L |
| H3 | Range-subtype bounds dropped at every layer: `IDistinctType` arm reads only `underlying`; `lowerMRangeType` is dead and also drops bounds; no construction validation. Front-end discards range in `TRefined`. | `codegen.l:6174-6180`, `lowering.l:1592-1599`, `typechecker_resolver.l:75-78` | M |
| H4 | Wire blocks drop `bind`/`scoped`/`provided` members and do no topological ordering/cycle detection. | `codegen.l:5489-5543` (`_ -> {}` at 5528); `typechecker_checker.l:189-191` | L |
| H5 | Named args lower in positional source order (mis-bind out-of-order); default params never filled at call sites (too few args → invalid IL). | `codegen.l:2980-2984,3373-3377`; `typechecker_exprs.l:608-611` | M |
| H6 | `monoFileWithImports` is dead code (bridges pass empty imports) → cross-package generic *functions* never specialized. | `mono.l:1908`; `bridge.l:103,403` | M |
| H7 | User generic-type instantiation `Box[Int]` falls to `MObject` (same-package types are in `typeFqnByName`, not `ffiTypeRefs`); `TGenericApp` in the non-ctx `typeExprToMsil` always returns `MObject`. | `codegen.l:1290-1299,1365` | M |
| H8 | ~~Unknown extern types silently bind to `System.Runtime` with no diagnostic.~~ **Resolved (#1504 H8):** `clrAssemblyResolvable` gates the FFI cascade; a type that is neither `System.*` nor a `Lyric.*` host now fails the build with a clear, type-specific diagnostic (codegen `panic`, matching the F0002 conflict panic) instead of mis-binding to `System.Runtime` → opaque runtime `TypeLoadException`. Applied on both the `@externTarget` and auto-FFI paths. | `ffi.l` `clrAssemblyResolvable` | ✅ |
| H9 | Auto-FFI scoring only handles static void-returning methods (all args boxed); instance/non-void need explicit `@externTarget`. | `codegen.l:5957-5997` | M |
| H10 | Custom `@generate(Pkg.Name)` source generators exist (`generator/generator.l`) but are **never called from `bridge.l`** — inert on self-hosted .NET. | `generator/generator.l:1-16`; no ref in `bridge.l` | M |
| H11 | `old()`/`forall`/`exists` in `@runtime_checked` contracts **panic** in codegen (elaborator passes them through). | `codegen.l:1851-1858`; `elaborator.l:361-362` | M |
| H12 | Two F# DLLs were load-bearing at runtime. **ByteWriter resolved for MSIL (#1492):** `Msil.Kernel.ByteWriter` is now a pure-Lyric `List[Byte]` buffer (`System.BitConverter` the only host extern); a sample exercising Int/Long/Double/String compiles **byte-identical** to the old host (verified via `cmp`), and the MSIL path has zero `Jvm.Hosts` references (JVM target retains `Lyric.Jvm.Hosts`, out of scope per #1470). **Kernels partially resolved (#1493):** `console` (stderr → `Console.Error`/`TextWriter`), `env` (`verifier_env` → `Environment.GetEnvironmentVariable`), and `log` (→ console stderr) migrated to audited BCL externs, and the dead `ConsoleHelper`/`LogHelper`/`VerifierEnv` F# types were deleted. Remaining: `http` `defaultClient` singleton (blocked on a package-level class-`val` `.cctor` codegen gap — a class-typed package-level `val` compiles but its static field stays null at runtime) and `process_capture` (deadlock-safe concurrent stdout/stderr reads need async, Band 3 #1489). | `msil/_kernel/kernel.l`; `lyric-stdlib/std/_kernel/{http,process_capture}_host.l`; `scripts/bootstrap.sh` | M |
| H13 | No `<PublishAot>` configured; "AOT-compilable" unrealized and untested. | `bootstrap/src/Lyric.Cli.Aot/Lyric.Cli.Aot.csproj` | M (gated on H12) |
| H14 | Visibility (`pub`/`internal`/`private`) stored but never enforced at use sites. | `typechecker_symbols.l:61`; no V0007/V0008 logic | M |
| H15 | `where T: Marker` bound satisfaction never checked at call sites; qualified constraint paths rejected (T0051). | `typechecker_exprs.l:603-723`; `typechecker_checker.l:372-373` | L |
| H16 | `alias X = Long` unresolvable as a type — alias has no `TypeId`, so `val v: X` → T0013 "not a type". | `typechecker_symbols.l:85-98` | M |
| H17 | `break`/`continue` out of a `try` region emit `br` instead of `leave` → unverifiable IL. | `codegen.l:3804-3808` | M |
| H18 | Float/Char/Long literal *match patterns* fall to the wildcard arm → **always match**. | `codegen.l:2610` | M |
| H19 | ~~Range-for (`for i in 0..n`) and any `a..b` expression panic (`ERange`).~~ **Resolved (#1478):** `for i in lo .. hi` / `..= hi` / `..< hi` parse and lower to a counting loop (`lowerForMsil`/`emitCountingForMsil`). Only a *standalone* range value (`val r = lo .. hi`) still panics — no `Range` value type, unused in stdlib/ecosystem. | `codegen.l` `lowerForMsil`; `parser_exprs.l` for-iter | ✅ |
| H20 | Capturing closures unimplemented: lambda-lifting produces plain static methods with no display class; captures reference out-of-scope locals; not even diagnosed. | `codegen.l:5601-5645,5858` | XL |
| H21 | BCL collection method stubs return wrong results silently: `List.Contains`→false, `Dict.Remove`/`RemoveAt`→no-op, unknown method→pop+null. | `codegen.l:3482-3577` | L |
| H22 | Compound assignment ignores the operator: string `+=` emits numeric `MAdd`; field `r.f += v` only stores. | `codegen.l:2321-2354,2421-2437` | M |

### MEDIUM / LOW (selected)

| # | Gap | Evidence | Sev |
|---|---|---|---|
| M1 | In-bundle cross-package imports still fall through to `MObject` when tokens absent (Phase-1 independent-packages scope). | `bridge.l:208-214` | MED |
| M2 | `IConst` constant-folds only `Int`; `Double`/`Long`/`String`/`Bool` consts emit a literal field valued 0. | `codegen.l:6181-6204` | MED |
| M3 | `IConfig` (config blocks, D046) compile to nothing — no env-var reader, no startup validation. | `codegen.l:6349` | MED |
| M4 | `@derive(Ord)` missing on all type kinds; union/enum derives deferred to F#. | `derives.l:25-26` | MED |
| M5 | ~~No MethodSpec table (tables stop at TypeSpec 0x1B) → cannot call open generic BCL methods.~~ **Resolved (#1497):** MethodSpec (table 0x2B) + `MethodSpecRow`/`addMethodSpec`/`ctxAddMethodSpec`/`buildMethodSpecBlob` shipped in `tables.l`/`lowering.l`, with serializer wiring (bitmask bit 43, row counts, row data). First consumer: an empty typed-slice literal `val xs: slice[T] = []` lowers to `System.Array.Empty<T>()` (a GENERIC-convention MemberRef instantiated by a MethodSpec) — fixing a latent miscompile (it previously emitted a `List<object>` that mis-read as `T[]`). Verified: PE carries a MethodSpec row decoding to the concrete element type; `shm_empty_slice_array_empty` bridge test. Generic-extern (#1504) and user-generic reify paths can now build on this. | `tables.l` `MethodSpecRow`; `lowering.l` `ctxAddMethodSpec` | ✅ |
| M6 | Numeric widening not applied (arithmetic requires exact `typeEquiv`); no checked-overflow awareness. | `typechecker_exprs.l:206-211` | MED |
| M7 | `SItem` (nested item decls) and `SInvariant` runtime-check silently dropped in codegen. | `codegen.l:3827-3830` | MED |
| M8 | Weaver `config`-fields-without-default emit a `panic` stub; `call.elapsed`/`call.caller` deferred (A0043 at weave time). | `weaver.l:24,30-35,773-780` | MED |
| M9 | `pub use Foo.bar` symbol-level re-export (Q022-1) has **no AST node** at all. | `parser_ast.l` item kinds | MED |
| M10 | Stdlib-source parse errors swallowed during type-item collection → dropped symbols. | `bridge.l:780-786,795-798` | MED |
| L1 | Stale `--target dotnet-legacy` text in user-visible `panic` strings for a removed flag. | `codegen.l:1852-1931` | LOW |
| L2 | `ast.l` `ItemKind` diverges from the authoritative `parser_ast.l` (missing `IAspect`/`IConfig`) — latent maintenance hazard. | `lyric/ast.l:773` vs `parser_ast.l:623` | LOW |
| L3 | `weaver_self_test.l`/`weaver_ci_test.l` not wired into CI (#1324). | CLAUDE.md / #1324 | LOW |
| L4 | `Float` literals always lower to `MDouble` (32-bit `Float` not distinct); `BXor`/`Long` truncates to `MInt`. | `codegen.l:1459-1462,2142-2147` | LOW |

---

## §4  What is genuinely production-solid now (do not redo)

- **Pipeline shape & dispatch.** In-process self-hosted .NET codegen is the
  default and only non-JVM path; AOT-shaped trampoline; full middle-end runs
  before codegen on both single-file and project paths (mode-check, mono, weave,
  parse all correctly fatal).
- **Direct PE emission** with no Reflection.Emit anywhere in the self-hosted MSIL
  tree (`pe.l`/`assembler.l`/`tables.l`/`heaps.l`).
- **Item kinds:** `IUnion` (base + case subclasses, payloads, nullary singletons,
  pattern dispatch), `IEnum` (full CLR enum with Constant rows), `IInterface`
  abstract method headers, `IOpaque` sealed body, `IRecord`/`IExposedRec`
  construction (equality caveat H1), `IVal` (literal inlining + token-shift-safe
  `.cctor`), `IExternType`, and the correctly-skipped compile-time-only kinds.
- **Generic *functions*:** same-package monomorphization with multi-source
  inference and a worklist for nested specializations; `Option[T]`/`Result[T,E]`/
  `List[T]` over stdlib/in-bundle element types track closed generic instances
  (incl. nested) via the #1442 `MGenericInst`/`contextHintTyArgs` work.
- **Contracts:** `requires`/`ensures` (incl. nested returns), loop `invariant:`,
  and protected-entry contracts all lowered to runtime asserts and applied
  unconditionally in default builds (covered by `contract_elaborator_self_test.l`).
- **Aspect weaver:** around/proceed/contract-composition/ordering plus the
  todo/06 config, call-context, and `@inline_template` extensions, invoked before
  codegen.
- **Deriving:** `equals`/`hash`/`show`/`toJson` *methods* synthesized for records,
  exposed records, and distinct types and emitted (caveat: not wired to `==`/
  `GetHashCode` — H1).
- **Contract metadata:** both reading and writing/embedding the `Lyric.Contract`
  resource are self-hosted (`bridge.l:986-1033`, `contract_meta.l`).
- **FFI:** `@externTarget` for primitive/String **and class/object** (#1504
  part 1) static/instance/ctor calls — class-typed params/return encode as real
  `TypeRef`-backed MemberRefs; `@externStatic`/`@externInstance` dispatch with
  conflict guard; unresolved externs emit an actionable runtime-throw stub
  rather than invalid IL.
- **Mode checker:** V0001–V0006, V0009–V0011 well-enforced for proof-required code
  (the strongest part of the front end).
- **Front-end enforcement that does work:** operator typing (T0030–T0037),
  range-subtype *declaration* validation (T0090/T0091/T0093), `where`-clause
  *declaration* validity (T0050/T0051), arity-keyed overload resolution,
  generator/`yield` placement (T0094–T0096), duplicate-name detection,
  local-binding type-equality (T0060–T0063).

---

## §5  Per-area detail

### 5.1  Front-end soundness (CRITICAL band)

Root cause (verified): `TyError` is a universal unifier (`typechecker_types.l:130-131`)
and the `Type` union is too coarse to carry range bounds, the
alias/distinct/opaque distinction, fixed array size, `Future`/`Task`, or
channels (`typechecker_types.l:47-65`). So even checks that exist at declaration
time (range bounds) are discarded at use, and ~12 expression forms short-circuit
the whole `typeEquiv` machinery. The checker is a lint-grade advisory pass, not a
gatekeeper — and on the single-file path it isn't even allowed to gate the build.
Fixing this is a prerequisite for flipping `bridge.l:92` to fatal (C1) without
rejecting valid programs.

### 5.2  Backend silent miscompiles (CRITICAL band)

`?`, `await`, `spawn`, `defer`, and `==` each compile cleanly and run
wrong (C3–C5, C7, H1; indexed assignment `a[i]=v` (C6) is now fixed — #1530).
The root cause is that the bridge pipeline has **no
desugaring/lowering pass** for `?`, `await`/async, `defer`, or range iteration —
those nodes arrive at codegen raw and are handled with placeholder
pass-throughs. Per the project standard, the honest interim for anything not yet
correctly lowered is a **hard diagnostic**, never a silent pass-through.

### 5.3  Async/await (CRITICAL band)

No `IAsyncStateMachine`/`ValueTask` synthesis, no lazy `IAsyncEnumerable[T]`.
The front end parses async fine; only backend codegen is missing. Porting
`AsyncStateMachine.fs` (~78 KB) + `AsyncGenerator.fs` (~31 KB) to Lyric MSIL
codegen (state-machine class synthesis, local→field promotion across
await/yield points, `AsyncTaskMethodBuilder` protocol, `AwaitUnsafeOnCompleted`,
TCS-backed `MoveNextAsync`) is the largest single remaining item.

### 5.4  Generics & FFI (HIGH band)

The #1442 merge is a real but narrow win: closed-generic *value* tracking for
cross-assembly heads. It did **not** give user generic *types* CLI generic
identity (C8), wire cross-package generic functions (H6), add a MethodSpec table
(M5), or fix the FFI class/object signature chokepoint (C9). The decision to
make on user generic types is monomorphize-the-type (extend `mono.l`, consistent
with the function strategy) vs. reify-as-CLI-generics (GenericParam +
GenericParamConstraint + MethodSpec + `constrained.`) — see §6 band 4.

### 5.5  AOT & F# residue (HIGH band)

Two F# DLLs sit on every .NET program's runtime closure (H12). They don't break
codegen under AOT (resolution is table-driven, not reflection-driven), but they
keep F# — including the Reflection.Emit emitter assembly — in the loop, blocking
both "no F# in the .NET path" and a clean NativeAOT publish (H13). The fix is a
pure-Lyric byte accumulator for the ByteWriter boundary and audited direct-BCL
externs (`System.Console`/`Process`/`Net.Http`/`Environment`) for the kernel
helpers, then `<PublishAot>` + a native-binary CI smoke test.

---

## §6  Remediation bands (updated 2026-05-29)

Ordered by the production bar. Bands 1–2 are the soundness/correctness floor and
should precede feature-completion work, because they stop *silent* wrongness.

### Band 1 — Front-end soundness floor (CRITICAL)
- Widen the `Type` union to carry range bounds, a representation tag
  (alias/distinct/opaque), array size, and `Future`/`Task`/channel (touches an
  `@stable` surface — needs a decision-log entry).
- Type the `TyError` expression forms: `EMatch`/`EIf` branch unification, `EIndex`
  element type, `ELambda` param/return inference, `EPropagate` return-compat,
  tuple-destructure sub-bindings, record-constructor argument checking.
- Add match exhaustiveness, visibility enforcement, opaque hiding, impl/interface
  conformance, and call-site `where`-bound satisfaction.
- Add a §5.2 parameter-mode pass that runs for **all** packages (not just
  proof-required).
- Then flip `bridge.l:92` to `reportAndAbort` and reconcile the two build paths
  (C1). This is the gate that makes "bad code fails to compile" true.

### Band 2 — Backend correctness floor (CRITICAL)
- Lower `?`/`try?` in the elaborator (where types are known) to match-unwrap +
  early-return; implement `defer`-at-scope-exit, range values +
  range-for, capturing-closure display classes, `break`/`continue`-via-`leave`,
  real Float/Char/Long match-literal tests, compound-assignment operator
  honoring, and the BCL stubs (Contains/Remove/RemoveAt). Indexed assignment
  `a[i]=v` shipped in #1530 (compound `a[i] += v` tracked in #1481). Where a
  correct lowering is genuinely out of scope, replace the silent pass-through
  with a hard diagnostic.
- Wire `==`/`GetHashCode` (and `Object.Equals` overrides) to the derived methods
  so structural equality and hashing actually work (H1).

### Band 3 — Async (CRITICAL)
- Port `AsyncStateMachine.fs` + `AsyncGenerator.fs` to self-hosted MSIL codegen
  (state machine, `Task[T]`/`ValueTask[T]` builders, lazy `IAsyncEnumerable[T]`,
  `CancellationToken` threading). Until then, make `await`/`spawn`/async-generators
  **panic with a tracked-issue message** rather than miscompile.

### Band 4 — Feature completion (HIGH)
- User generic types (monomorphize or reify — decision required), protected-type
  locking, `@projectable` twins, range-subtype validation, wire
  `bind`/`scoped`/`provided` + ordering/cycle-detection, named/default/`out`/`inout`
  arguments, FFI class/object signatures + `clrAssemblyForType` hard-diagnostic
  fallback + auto-FFI beyond static-void, custom `@generate` generator wiring,
  `old()`/quantifier runtime lowering, `@derive(Ord)` + union/enum derives,
  `IConfig` lowering, MethodSpec table, cross-package generic-function mono
  (`monoFileWithImports` wiring), in-bundle cross-package token resolution.

### Band 5 — F# elimination + AOT (HIGH)
- Replace the `Lyric.Jvm.Hosts` ByteWriter boundary with a pure-Lyric byte
  accumulator; move the `Lyric.Emitter`-hosted kernel helpers to audited direct
  BCL externs; then add `<PublishAot>` (+ globalization/trim) and a CI smoke test
  that runs a real `lyric build` through the native binary.

### Band 6 — Acceptance gate
The self-hosted .NET compiler is production-ready when: every program in
`docs/02-worked-examples.md` builds and runs under `--target dotnet`; the parity
suite expands to one program per §§2–14 feature class; `lyric prove`/
`public-api-diff`/`test`/`doc` on every stdlib module match a baseline; both F#
DLLs are off the runtime closure; and `<PublishAot>` produces a working native
binary in CI.

---

## §7  Corrections to the 2026-05-20 draft

| 2026-05-20 claim | 2026-05-29 reality |
|---|---|
| "Neither backend invokes the middle-end; `--target dotnet` ships with NO compile-time validation." | False now. The full middle-end runs in-process; mode-check/mono/weave/parse are fatal. Type check runs but is advisory on the single-file path (C1). |
| "`--target dotnet-legacy` is the load-bearing path." | Removed from the CLI; only stale `panic` strings reference it. Default is self-hosted in-process. |
| §3.5 "TGenericApp defaults to MObject (`codegen.l:593`); `Lyric.Mono` not called from `Msil.Bridge`." | Stale. `monoFile` is wired (`bridge.l:103,403`); `TGenericApp` emits `MGenericInst` for cross-assembly heads (`codegen.l:1290-1313`). Erasure now applies to *user generic types* (C8), not all generics. |
| "MSIL: no `for` loops (panics)." | `for` over List/array and range-`for` (`lo .. hi` / `..= hi` / `..< hi`) both work (#1478); only a standalone `a .. b` *value* expression remains unsupported (H19). |
| "`SDefer` not implemented." | Present but semantically broken — runs inline immediately (C7). |
| "Contract elaborator defers protected-type entries and loop invariants." | Both shipped (`elaborator.l:805-819,1046-1116`). |
| "Contract metadata embedding is F#-only." | Self-hosted (`bridge.l:986-1033`). |
| "Both backends skip `IEnum`/`IInterface`/`IOpaque`/`IProtected`/`IAspect`." | All have MSIL lowering now; the gaps are correctness (protected locking C12, opaque twins H2, default-interface-method bodies C11), not absence. |

---

## §8  Out of scope for this audit

- JVM target (deferred per the review brief).
- Performance/allocation profiling; compile-time benchmarks.
- Stage-2/3 reproducibility bootstrap.
- LSP completeness (separate audit).

---

## §9  References

- `docs/01-language-reference.md` — authoritative language description.
- `lyric-compiler/msil/{bridge,codegen,lowering,ffi,tables,pe,assembler,heaps}.l`.
- `lyric-compiler/lyric/{parser,type_checker,mode_checker,contract_elaborator,weaver,derives,mono,generator}/`.
- `lyric-compiler/lyric/{cli,emitter,contract_meta}.l`.
- `lyric-stdlib/std/_kernel/*_host.l`, `lyric-compiler/msil/_kernel/kernel.l`.
- `bootstrap/src/Lyric.Cli.Aot/`, `bootstrap/src/Lyric.Emitter/{AsyncStateMachine,AsyncGenerator}.fs` (unported async).
- `scripts/bootstrap.sh` (stage-1 bundle contents).
</content>
</invoke>
