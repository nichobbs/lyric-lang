# 41 — Self-hosted compiler gap analysis vs. language reference (production readiness)

_Status: Drafted 2026-05-20 on branch `claude/review-lyric-compiler-6KhaC`.  Comprehensive review of the self-hosted Lyric compiler in `lyric-compiler/lyric/`, `lyric-compiler/msil/`, and `lyric-compiler/jvm/` against `docs/01-language-reference.md` and `docs/grammar.ebnf` for both the `--target dotnet` and `--target jvm` channels._

_This document is a static audit — it lists every gap found between the spec and what the self-hosted compiler actually emits at the time of writing.  It does **not** repeat planning notes already captured in `docs/36-v1-roadmap.md` or `docs/10-bootstrap-progress.md`; those documents remain authoritative for sequencing.  When this audit and an existing planning doc disagree, the planning doc wins and this audit should be updated._

---

## §1  Executive summary

Production readiness of the self-hosted compiler is **not** "self-hosted middle-end + backend missing a few features".  It is the following six independent bands of work, ordered by severity:

1. **Pipeline disconnect (CRITICAL).**  Neither self-hosted backend invokes the
   self-hosted middle-end.  `Msil.Bridge.compileToMsil` and
   `Jvm.Bridge.compileToJar` both run `parse → codegen → lowering` directly
   and skip the type checker, mode checker, contract elaborator, and
   monomorphizer entirely.  Today the F# emitter is the only path that
   enforces these.  `--target dotnet` ships with NO compile-time validation
   of the source.
2. **MSIL backend feature coverage (CRITICAL).**  Approximately fifteen of
   the language reference's twenty-five top-level item kinds are stubbed or
   skipped in `Msil.Codegen`.  The backend is currently fit for the
   twenty-program parity smoke-test set and very little else (D-progress-241).
3. **JVM backend feature coverage (HIGH).**  Wider coverage than MSIL
   (async generators, protected types, wire blocks, FFI, Maven all wired)
   but still stubs enums, distinct types, interfaces, impl blocks, aspects,
   non-generator async, general closures, and rejects `func main(): Long/Double`.
4. **Contract enforcement parity (HIGH).**  Self-hosted contract elaborator
   covers `requires:` and `ensures:` (including nested returns) but defers
   protected-type entries.  Even with the elaborator complete, the
   self-hosted backends never run it on production builds because of band 1.
5. **F#-only constructs (HIGH).**  Async state machines, async generators,
   aspect weaver, wire/DI synthesis, opaque-twin generation, contract
   metadata emission, deriving synthesis, and closure lowering live only
   in the F# emitter.  Each needs a self-hosted port before `--target
   dotnet-legacy` can be retired.
6. **Cross-package + multi-file (MEDIUM).**  Self-hosted middle-end is
   single-package-only; cross-package symbol resolution, cross-package
   generics specialisation, and multi-file package linking remain F#-only.

**Bottom line.**  A program that goes beyond the smoke-test set will today
either (a) silently produce broken IL/bytecode under `--target dotnet` (no
type check runs), (b) work only because the F# emitter co-builds the same
source and surfaces errors before the JVM JAR is written under `--target
jvm`, or (c) require `--target dotnet-legacy` (the F# escape hatch) which
is the only path that runs the full middle-end.

_Update (D-progress-276):_ Band 1 partially landed.  The MSIL and JVM
bridges now run `Lyric.ModeChecker.checkFile` (fatal) and
`Lyric.ContractElaborator.elaborateFile` (lowers `requires:` / `ensures:`)
on every build.  `Lyric.TypeChecker.check` runs but its diagnostics are
advisory until Band 6 plumbs cross-package import resolution into the
self-hosted resolver.  `Lyric.Mono.monoFile` wiring is deferred — the F#
bootstrap parser cannot compile `mono.l`'s literal-pattern match arms
followed by further arms, so importing the package breaks the bridge
precompile (see Band 1's status block in §9).

---

## §2  Compilation pipeline reality (verified from source)

The actual flow for each `--target` flag.  Verified by reading
`bootstrap/src/Lyric.Cli/Program.fs:1232-1283`,
`bootstrap/src/Lyric.Cli/SelfHostedMsil.fs`,
`bootstrap/src/Lyric.Cli/SelfHostedJvm.fs`,
`lyric-compiler/msil/bridge.l:24-69`, and
`lyric-compiler/jvm/bridge.l:63-129`.

### 2.1  `--target dotnet` (default)

```
lyric build foo.l
  └─ F# Program.fs:1232   if selfHostedDotnet && Emitter.Dotnet
       └─ SelfHostedMsil.compileToDll(source, dllOutPath)
            └─ reflects out Msil.Bridge.compileToMsil(source, outputPath)
                 ├─ Lyric.Parser.parse(source)
                 ├─ if any DiagError -> return false
                 ├─ Msil.Codegen.codegenMPackage(file, ctx)   ← NO type check
                 ├─ Msil.Lowering.lowerMPackageWithCtx(...)
                 └─ Std.File.writeBytes(path, bytes)
```

The self-hosted middle-end (`Lyric.TypeChecker`, `Lyric.ModeChecker`,
`Lyric.ContractElaborator`, `Lyric.Mono`) is **not invoked**.  Verified by:

```sh
$ grep -n "TypeChecker\|ModeChecker\|ContractElaborator\|Mono\." \
       lyric-compiler/msil/bridge.l
# (no output)
```

Implication: a type-incorrect program compiles to (broken) MSIL without
diagnostics.  `requires:` / `ensures:` clauses are never lowered to
runtime asserts — they remain in the AST as `CCRequires` / `CCEnsures`
nodes that the codegen ignores.  Mode violations (`V0001`–`V0011`) are
not enforced.  Generic functions emitted on this path lose their type
arguments to `MObject` (see §3.5).

### 2.2  `--target dotnet-legacy`

```
lyric build foo.l --target dotnet-legacy
  └─ F# build() -> Emitter.emit
       ├─ parse (F# Lyric.Parser)
       ├─ Cfg.applyCfgErasure
       ├─ resolveRestoredImports + resolveStdlibImports
       ├─ Lyric.TypeChecker.Checker.checkWithImports   (F# typechecker)
       └─ emitAssembly (F# Emitter.fs + Codegen.fs)
             └─ inline: mode checking, monomorphization, async SM,
                aspect weaving, contract emission, opaque-twin synthesis,
                wire/DI lowering, …
```

Full middle-end; full feature coverage.  This is the load-bearing path
today.  Marked deprecated in `docs/01-language-reference.md` §11 and
`docs/36-v1-roadmap.md` G3 (D066) but slated to survive through 1.0 and
be removed in 1.1.

### 2.3  `--target jvm`

```
lyric build foo.l --target jvm
  └─ build()  (full F# Emitter.emit pipeline — produces .dll as side effect)
       └─ if exit == 0:
            SelfHostedJvm.compileToJar(source, jarPath, packageName)
                 └─ reflects out Jvm.Bridge.compileToJar
                      ├─ Lyric.Parser.parse(source)
                      ├─ reject `func main(): Long/Double`
                      ├─ Jvm.Codegen.codegenPackage(file)   ← NO type check
                      ├─ Jvm.Lowering.lowerPackage(...)
                      └─ Jvm.Driver.writeJarFromClasses(...)
```

The F# emitter co-runs and produces a `.dll`.  Because the F# pipeline
runs first, any type / mode / contract error from the F# middle-end aborts
the build before the JVM JAR is written.  The JAR itself is emitted from a
parallel pipeline that skips the self-hosted middle-end the same way the
MSIL bridge does.  When the F# pipeline succeeds but the self-hosted JVM
codegen rejects a construct (aspects, interfaces, distinct types, …), the
JAR build fails and the user sees a JVM-side panic message; the `.dll`
remains as a half-built artefact.

### 2.4  What this means for production readiness

The self-hosted Lyric pipeline that ships today is closer to a
"reparse-then-emit" assembler than a self-hosted compiler.  It works
because:

- For `--target jvm`, the F# emitter pre-validates every build.
- For `--target dotnet`, users build programs that happen to lie within
  the 20-program parity smoke-test envelope.

Both safety nets vanish when:

- The F# emitter is removed (the explicit goal in `docs/23-fsharp-shim-elimination.md` and `docs/36-v1-roadmap.md` R4).
- Users write non-trivial programs against `--target dotnet` and discover
  that bad code compiles to broken IL.

Wiring the self-hosted middle-end into `Msil.Bridge` and `Jvm.Bridge` is
**band 1** of remediation and must precede any other work on the
self-hosted backends.

---

## §3  Self-hosted MSIL backend (`lyric-compiler/msil/`)

Files surveyed: `bridge.l:24-69`, `codegen.l` (2641 LoC), `lowering.l` (942
LoC), `ffi.l` (261 LoC).  Per-line citations below are to `codegen.l`
unless noted.

### 3.1  Top-level items

| Item kind | Handled by | Status |
|---|---|---|
| `IFunc` | `lowerMsilFunc`, `:2599-2604` | Supported (primitive params/returns) |
| `IRecord` | `lowerRecordMsil`, `:2287-2410, 2595` | Supported (fields + ctor) |
| `IUnion` (sealed) | `lowerUnionMsil`, `:2527-2560` | Supported (abstract base + case classes) |
| `IDistinctType` | `:2609-2615` | Supported (thin wrapper) |
| `IEnum` | `lowerEnumMsil` | **Supported** — CLR int enum TypeDef; cases as static literal int32 fields (Band 2, PR #872) |
| `IRange` | `:2627` | **Skipped** — no codegen branch (`MRangeType` IR exists in `lowering.l:295` but unused) |
| `IOpaque` | `lowerOpaqueMsil` | **Supported** — sealed TypeDef; private fields + .ctor; exposed-twin synthesis deferred to Band 3 (Band 2, PR #872) |
| `IInterface` | `lowerInterfaceMsil` | **Supported** — abstract interface TypeDef with abstract method stubs (Band 2, PR #872) |
| `IImpl` | `lowerMImpl` (`msil/lowering.l`) | **Supported** — emits InterfaceImpl + MethodImpl rows on the implementing type (Band 2, PR #872) |
| `IProtected` | `lowerProtectedTypeMsil` | **Supported** — Monitor-backed sealed TypeDef; lock field + entry methods (Band 2, PR #872) |
| `IWire` | — | **Placeholder** — static factory class stub; full DI graph lowering deferred to Band 3 |
| `IAspect` | `weaveAspectsMsil` | **Supported** — weaver renames target to `__aspect_target_N_<name>`; synthesises wrapper with around-body (Band 2, PR #872) |
| `ITypeAlias` | `:2616` | Skipped (correctly compile-time only) |
| `IConst` | `:2613` | **Skipped** — no static-field emission |
| `IVal` | `lowerMsilFunc` (literal inlining + .cctor) | **Supported** — literal vals inlined via `constValues` map; non-literal vals get static `.cctor` (Band 2, PR #872) |
| `IProperty` | `:2631` | **Skipped** |
| `IScopeKind` | `:2625` | **Skipped** |

### 3.2  Statements

| Statement | Status | Citation |
|---|---|---|
| `SLet`, `SLocal`, `SAssign` | Supported | `:1920-1962` |
| `SExpr` | Supported | — |
| `SIf`, `SWhile`, `SLoop`, `SBreak`, `SContinue` | Supported | `:1989-2029` |
| `SFor` | **Panics** — "not supported in bootstrap" | `:2002` |
| `STry`/`SCatch`/`SFinally`/`SThrow` | Supported | `:2063-2120, 2032-2034` |
| `SReturn` | Supported | — |
| `SItem` (nested item decls) | Skipped | `:2040` |
| `SDefer` | **Not implemented** (search returns nothing) | — |
| `SInvariant` (loop invariants) | Not lowered to runtime asserts | depends on elaborator parity |

### 3.3  Expressions

| Expression | Status | Citation |
|---|---|---|
| Literals (Int/Long/Float/Double/Bool/Char/String) | Supported | `:725-787` |
| `EBinop` arithmetic / comparisons | Supported | `:725-747` |
| `EIf` | Supported | `:789-793` |
| `EMember` field access | Supported | `:755-787` |
| `ECall` (static / ctor / variant ctor) | Supported | `:1537-1550` |
| `EMatch` (literal + binding + variant payload) | Supported | `:1335-1464` |
| `EInterpolated` string interpolation | Supported (rewrites to concat chain) | `:861` |
| `EAwait` | **Panics** | `:833-838` |
| `EYield` | **Panics** — "async generators (yield) not supported in self-hosted MSIL R5" | `:838-839` |
| `ELambda` | **Placeholder** — falls back to `MObject`; display-class capture deferred to Band 3 | `:902-903` |
| `ESelf` | **Panics** | `:895-898` |
| `EForall`, `EExists` | **Panics** (proof constructs; correct) | `:886-890` |
| `EOld` | **Panics** in codegen (should be consumed by elaborator) | `:892-894` |
| `EResult` | **Panics** in codegen (should be substituted by elaborator) | — |
| `EPropagate` (`?`) | **Supported** — desugars to match-unwrap for `Result[T,E]` and `Option[T]` (Band 2, PR #872) | `:851-855` |
| `ERange` | **Panics** | `:905-906` |

### 3.4  Contracts and verification

Contract clauses (`CCRequires`, `CCEnsures`, `CCInvariant`) are present in
the AST consumed by `Msil.Codegen`, but `codegenMPackage` and `lowerFunc`
do not consult them.  The expectation is that the elaborator has already
lowered them to `assert(cond)` statements before codegen runs — but per
§2.1, the elaborator does **not** run in the self-hosted MSIL pipeline.
Net effect: `@runtime_checked` contract enforcement is **completely
absent** from `--target dotnet` today.  Source-level `assert(cond)` calls
written by hand do get lowered (`:1783-1827`).

### 3.5  Generics, monomorphization, FFI

- **Generics.**  `TGenericApp` in `typeExprToMsil` defaults to `MObject`
  (`codegen.l:593`).  The self-hosted MSIL backend does not emit CLI
  generic-method tokens (`GenericMethodSpec`, `MethodGenericArgument`,
  `TypeSpec` with `GENERICINST`).  `Lyric.Mono` (`lyric-compiler/lyric/mono.l`)
  is not called from `Msil.Bridge`, so the source-level specialisation
  step is also skipped.  Code that uses `map[Int, String](xs, f)` will
  compile, but the resulting IL will operate on `object` references with
  no static type guarantees.
- **FFI (`@externTarget`).**  Handled by `Msil.Ffi.resolveExternTarget`
  (`ffi.l:229-261`).  Hardcoded type→assembly table; static/instance
  dispatch via `@externStatic`/`@externInstance` hints.  No auto-FFI
  scoring (C4 phase 1–2 from `docs/01-language-reference.md` §11.3) —
  every BCL method must be declared with an explicit `@externTarget`
  annotation.  Cross-assembly types not in `Msil.Ffi.clrAssemblyForType`
  default to `System.Runtime`, which silently breaks for non-forwarded
  types.
- **`@externTarget` on Lyric generic functions.**  Q022-4 (`docs/36-v1-roadmap.md`):
  not implemented — only fully-monomorphised externs resolve.

### 3.6  Test coverage shape

`ls lyric-compiler/msil/msil_self_test_m*.l | wc -l` reports 84 self-test
files covering PE structural validation, multi-method assemblies,
exception handling, boxing/unboxing, instruction prefixes, floating-point
operations.  **None** exercise generics, async, aspects, opaque types,
interfaces, impl blocks, wire blocks, protected types, or cross-package
linking.

---

## §4  Self-hosted JVM backend (`lyric-compiler/jvm/`)

Files surveyed: `bridge.l:63-129`, `codegen.l` (3103 LoC), `lowering.l`
(3668 LoC), `driver.l` (60 LoC).  Per-line citations below are to
`codegen.l` unless noted.

### 4.1  Top-level items

| Item kind | Status | Citation |
|---|---|---|
| `IFunc` | Supported | `:2745-2750` |
| `IRecord` / `IExposedRec` | Supported | `:2592-2673` |
| `IUnion` | Supported (sealed interface + case subclasses) | `:2675-2714` |
| `IAsyncGenerator` | Supported (collect-all `Iterable`/`Iterator` model) | `:2974-2999`; `lowering.l:2903-3100` |
| `IProtected` | Supported (`ReentrantLock`-backed entries) | `lowering.l:1232-1308` |
| `IWire` | Supported (static factory class) | `lowering.l:1310-1405` |
| `IEnum` | **Skipped** | `:3027` |
| `IDistinctType` | **Skipped** | `:3026` |
| `IOpaque` | Partial — Q-J005 opaque facade lowering exists in `lowering.l` but `codegen.l:3028` skips the dispatch | |
| `IInterface` | **Skipped** | `:3030` |
| `IImpl` | **Skipped** | `:3031` |
| `IAspect` | **Skipped** | `:3040` |
| `IRange`, `IProperty`, `IScopeKind` | **Skipped** | — |
| `ITypeAlias`, `IConst`, `IVal` | Ignored (resolved at type-check time) | `:3023-3025` |

### 4.2  Expressions

| Expression | Status | Citation |
|---|---|---|
| Literals, arithmetic, control flow | Supported | `:302-550, 1000-1200` |
| Pattern matching (literal, variant, binding) | Supported | `:1157-1361` |
| `EInterpolated` (StringBuilder chain) | Supported | `:1361-1442` |
| `EAwait`, `ESpawn` | Lowered as sync (blocking) — no virtual-thread / CompletableFuture state machine | `:655-676` |
| `EYield` (in `@async_generator`) | Supported via collect-all model | `:2974-2999` |
| `ELambda` | **Panics** except for `Std.Jvm.catch(\() -> …)` special case | `:718` |
| `EPropagate` (`?`) | Pass-through (no-op); `Result` wrapping only emitted for `@externTarget` with declared `Result[T, JvmException]` | `:678-685` |
| `EForall`, `EExists` | **Panics** (correct) | `:698-705` |
| `EOld`, `EResult` | **Panics** (should be elaborator-consumed) | `:705, 712` |
| `ERange` | **Panics** | `:751` |

### 4.3  FFI and Maven

- `@externTarget("java.Class.method")` is supported — `codegen.l:1539-1730`
  emits `invokestatic`/`invokevirtual` and wraps in try/catch when the
  declared return type is `Result[T, JvmException]` (D-progress-254, R3
  in `docs/36`).
- Checked-exception wrapping currently catches `java.lang.Exception` only
  (`:1714`); `Throwable` opt-in is Q-J009.
- Maven resolution via `MavenShim.fs` and the `resolver/` Java JAR is
  load-bearing; classes are placed on the JAR classpath at build time.

### 4.4  JVM-specific corner cases

- `func main(): Long/Double` is rejected at the bridge (`bridge.l:22-52`)
  with a `J001` error.  Workaround documented in the printed hint.
- Primitive arrays vs. `Object[]`: `Array[Int]` is erased to `Object[]`
  (Q-J001 Valhalla deferral).  Numeric loops over `Array[Int]` incur
  boxing.

### 4.5  Generics, async (non-generator)

- Generics: `Jvm.Codegen` assumes monomorphisation has happened upstream
  (per `:2745-2750` comments) but `Jvm.Bridge.compileToJar` does **not**
  call `Lyric.Mono` (verified by grep).  In practice this works because
  the F# emitter co-runs and rejects programs that the JVM backend
  cannot lower; but it is structurally broken and will fail once
  `--target dotnet-legacy` is removed.
- Async functions (non-generator) fall back to sync emission — no
  virtual-thread or `CompletableFuture` state machine.  This silently
  produces a blocking program where the user expected concurrency.
  No diagnostic is emitted (compare F# emitter behaviour:
  `bootstrap/src/Lyric.Emitter/AsyncStateMachine.fs:1-100`).

---

## §5  Self-hosted middle-end (`lyric-compiler/lyric/`)

The middle-end libraries are well-implemented but, per §2, are **not
invoked from production builds**.  Their status, separate from the
plumbing problem, is:

### 5.1  Parser (`lyric-compiler/lyric/parser/`)

Full surface coverage per `docs/grammar.ebnf`.  Red/green CST shipped
(D-progress-130) with per-token leading trivia preserved.  Known
limitations:

- Per-expression CST cursor granularity for the formatter is deferred to
  v1.1 (R2 in `docs/36`, D066) — leading trivia inside `EBinop`, `ECall`,
  `EIndex`, `EPrefix`, `EField`, `EAs` nodes is hoisted to the enclosing
  statement.

### 5.2  Type checker (`lyric-compiler/lyric/type_checker/`)

Covers primitives, range subtypes, distinct types, opaque types,
generics with bounds, interface dispatch, UFCS, async types, protected
types.  Known limitations:

- Cross-package qualified type resolution: multi-segment type names now
  resolve via last-segment symbol-table lookup (D-progress-285).
  `import Pkg.Module` import-statement resolution (registering all
  exports of a restored package) is deferred to Track A.
- Q022-1 (`pub use Foo.bar` symbol-level re-export) — parser accepts but
  the typechecker implements package-level only.  Same gap exists in the
  F# `Lyric.TypeChecker.Resolver.fs`; tracked in `docs/36-v1-roadmap.md`
  R5.
- Q022-3 (UFCS on opaque-with-generic-param) — silent T0050 "method not
  found" instead of substitution-then-dispatch.

### 5.3  Mode checker (`lyric-compiler/lyric/mode_checker/`)

V0001–V0011 enforcement present.  Conservative fallback for unknown
cross-package callees (`modechecker_check.l:81`, M4.1 deferral) — V0002
call-graph rules cannot verify calls to imported functions.  Low severity
because the fallback is safe.

### 5.4  Contract elaborator (`lyric-compiler/lyric/contract_elaborator/`)

Per `elaborator.l:19-47`:

- `requires:` — fully elaborated to `assert()` prepended to body.
- `ensures:` — fully elaborated **including nested returns** (the
  `docs/36-v1-roadmap.md` R4 note about nested returns being deferred is
  stale; the file header at `elaborator.l:25-34` documents the nested
  rewrite).  **Update `docs/36` accordingly.**
- Loop `invariant:` (`SInvariant`) — left as-is, no runtime check (`:39-41`).
- Protected-type entries (`PMEntry` with `barrier:` / `invariant:`) —
  **deferred** (`:43-47`).  Equivalent F# emitter logic still load-bearing.

### 5.5  Monomorphizer (`lyric-compiler/lyric/mono.l`)

Same-package monomorphisation only (G-07 in `docs/36`).  Cross-package
generics, value generics (`GPValue`), and constraint propagation deferred.
The F# emitter handles cross-package generics correctly via reified CLR
generics.

---

## §6  F#-only constructs (need self-hosted ports)

These features have full F# implementations in `bootstrap/src/Lyric.Emitter/`
and **no** equivalent in `lyric-compiler/msil/` or `lyric-compiler/jvm/`.
A v1.0 self-hosted-only build cannot ship without each one.

| Feature | F# location | Why it matters |
|---|---|---|
| Async state machines (`IAsyncStateMachine` + `ValueTask`) | `AsyncStateMachine.fs` (1699 LoC) | `async`/`await` non-functional under `--target dotnet` |
| Async generator (`IAsyncEnumerable<T>`) | `AsyncGenerator.fs` (686 LoC) | F# parity; JVM has a different collect-all model |
| Aspect weaver | `Weaver.fs` (398 LoC) | `@aspect`, `wraps:`, `inside:`, contract augmentation; both backends silently skip `IAspect` |
| Wire / DI block lowering (MSIL) | `Emitter.fs` (C2 region) | JVM has it; MSIL does not |
| Opaque-type synthesis + projectable twin (`@projectable`, `@projectionBoundary`) | `Emitter.fs` (M2.0–M2.2 region) | Critical safety story |
| Protected-type entries (MSIL) | `Emitter.fs` (C3 region) | Ada-style barriers; JVM has it; MSIL does not |
| Interface impl-block emission | `Emitter.fs` (M2.1 region) | Both backends skip `IInterface`/`IImpl` |
| Generic monomorphization (call-site) | `Codegen.fs:736-984` | Both backends pass-through `MObject`/`Object` |
| Auto-FFI scoring (C4 phase 1–2) | `Codegen.fs:1842-1972` | Explicit `@externTarget` required on both backends today |
| Contract metadata emission (`Lyric.Contract` resource) | `ContractMeta.fs` (895 LoC) | Required for `lyric prove`, `lyric public-api-diff`, and cross-package contract reads |
| Deriving (`@derive(Equals)`, `@generate(Json)`) | `Records.fs:162-165` + emitter sites | Equality, hashing, JSON round-trips |
| Closure / lambda lowering (display-class synthesis) | `Codegen.fs` (lambda region) | Both backends panic on `ELambda` |
| Cross-package symbol resolution | `RestoredPackages.fs` (255 LoC) | Multi-package consumption |

---

## §7  Cross-cutting / spec-level gaps

These are not bound to a single backend; they affect both targets.

### 7.1  Contract semantics (`docs/08-contract-semantics.md`)

- `@runtime_checked` is the module default (`docs/01-language-reference.md` §6.4).
  Production builds under `--target dotnet` do not insert runtime checks
  because the elaborator does not run (§2.1).  Critical for the safety
  story.
- `@proof_required` requires the Phase 4 verifier.  The verifier
  (`lyric-compiler/lyric/verifier/`) is self-hosted but only invoked by
  `lyric prove`, not by `lyric build`.  This is correct per spec.

### 7.2  Wire / DI (`docs/01-language-reference.md` §10)

- MSIL backend: `IWire` skipped.  No DI graph synthesis under `--target
  dotnet`.
- JVM backend: wire blocks lower to a static factory class (`lowering.l:1310-1405`).
  Verified at smoke-test level but not at production-program complexity.

### 7.3  Aspects (`docs/01-language-reference.md` §14, `docs/26-aspects.md`)

Both backends skip `IAspect` (`codegen.l:2634` for MSIL; `:3040` for JVM).
Aspect weaver, `proceed(args)` rewriting, contract augmentation, and
`wraps:`/`inside:` ordering are F#-only (`Weaver.fs`).  Per
`docs/36-v1-roadmap.md` G-06, four sub-constructs are also parsed-but-inert
even in the F# emitter; the self-hosted backends are further behind.

### 7.4  FFI (`docs/01-language-reference.md` §11)

- `@externTarget`: supported on both backends.
- Auto-FFI scoring (C4 phase 1–2): F#-only.
- Generic `@externTarget` on BCL generic methods (Q022-4): not implemented
  anywhere.
- Phase-3 BCL shapes (`Span<T>`, `params`, `in`/`ref`/`out` struct methods,
  extension methods): on-demand only, even in F# emitter.

### 7.5  Tooling commands and their self-hosting status

| Command | Self-hosted? | Notes |
|---|---|---|
| `lyric build` | Partial — middle-end bypassed (§2.1) | Critical band 1 |
| `lyric run` | Same as build | — |
| `lyric fmt` | Yes (`fmt/fmt.l` via `SelfHostedFmt.fs`) | `--legacy` Fmt.fs sunset deferred to v1.1 |
| `lyric lint` | Yes (`lint/lint.l` via `SelfHostedLint.fs`) | Five rules L001–L005 (D-progress-255) |
| `lyric doc` | Yes (`doc/doc.l` via `SelfHostedDoc.fs`) | Single-file only (G-03) |
| `lyric prove` | Yes (`verifier/` via `SelfHostedCli.fs`) | Trivial syntactic discharger only; quantifier/cross-call deferred |
| `lyric test` | Yes (`test_synth/` via `SelfHostedTestSynth.fs`) | `property` skipped, `fixture` is T0901 (G-04) |
| `lyric bench` | Yes (`bench_synth/` via bridge) | — |
| `lyric repl` | Yes (`repl/repl.l`) | Script-accumulation only |
| `lyric publish` | F# (`Pack.fs` and `Lyric.Cli/SelfHostedPack` partial) | Self-hosted Pack shipped per D-progress-255; verify |
| `lyric restore` | F# | Cross-package contract metadata reader is F# (`RestoredPackages.fs`) |
| `lyric public-api-diff` | Yes via `contract_meta.l` | Reads embedded `Lyric.Contract` resource emitted by F# |
| `lyric openapi` | Yes (`open_api_*.l`) | — |
| `lyric --internal-build` (subprocess entry) | F# | Dispatches into either F# emitter or self-hosted MSIL/JVM bridges |

The CLI dispatch is self-hosted (`cli.l` via `SelfHostedCli.fs`,
D-progress-260) but every command that needs to emit code shells back to
the F# `--internal-build` for the actual compilation step
(`lyric-compiler/lyric/emitter.l:5-12` documents this explicitly).

### 7.6  Standard library boundary

`lyric-stdlib/std/_kernel/` and `_kernel_jvm/` extern boundaries are
parity-correct after Phase R3 (`docs/33-platform-parity-remediation.md` §4).
A handful of `Std.*` modules still emit `@externTarget` declarations that
neither self-hosted backend's FFI table recognises by default — they work
because the F# emitter co-runs (JVM) or because the FFI table has been
hand-extended (MSIL).  A self-hosted-only build will surface these as
unresolved externs.

---

## §8  Risk and impact matrix

Severity is judged against the goal "production-ready self-hosted compiler
supporting all language features on both targets".

| Gap | Severity | Affects | Workaround | Where it lives |
|---|---|---|---|---|
| Self-hosted backends bypass middle-end | **CRITICAL** | both | use `--target dotnet-legacy` | `msil/bridge.l`, `jvm/bridge.l` |
| MSIL: no generics monomorphisation | **CRITICAL** | dotnet | dotnet-legacy | `msil/codegen.l:593` |
| MSIL: no async / yield | **CRITICAL** | dotnet | dotnet-legacy | `msil/codegen.l:833-839` |
| MSIL: no closures (`ELambda` display-class) | **CRITICAL** | dotnet | dotnet-legacy | `msil/codegen.l:902-903` |
| MSIL: no wire blocks (full DI graph) | **MEDIUM** | dotnet | dotnet-legacy | `msil/codegen.l` |
| MSIL: no `for` loops | **HIGH** | dotnet | dotnet-legacy or `while` | `msil/codegen.l:2002` |
| MSIL: no auto-FFI scoring | **MEDIUM** | dotnet | explicit `@externTarget` | `msil/ffi.l` |
| MSIL: no `IConst` static-field emission | **HIGH** | dotnet | dotnet-legacy | `msil/codegen.l:2613` |
| JVM: no interfaces / impl blocks | **CRITICAL** | jvm | dotnet-legacy + dotnet | `jvm/codegen.l:3030-3031` |
| JVM: no aspects | **CRITICAL** | jvm | dotnet-legacy + dotnet | `jvm/codegen.l:3040` |
| JVM: no closures (except `Std.Jvm.catch`) | **CRITICAL** | jvm | dotnet-legacy + dotnet | `jvm/codegen.l:718` |
| JVM: no enums, distinct types | **HIGH** | jvm | dotnet-legacy + dotnet | `jvm/codegen.l:3026-3027` |
| JVM: non-generator async is sync | **HIGH** | jvm | use generator form or blocking is OK | `jvm/codegen.l:655-676` |
| JVM: `func main(): Long/Double` rejected | LOW | jvm | `Int` or `Unit` | `jvm/bridge.l:22-52` |
| Contract elaborator: protected entries deferred | **HIGH** | both | dotnet-legacy | `contract_elaborator/elaborator.l:43-47` |
| Cross-package type resolution | **HIGH** | both | single-package only | `typechecker_resolver.l:129` |
| Cross-package generics monomorphisation | **MEDIUM** | both | dotnet-legacy uses reified CLR generics | `mono.l:6-27` |
| Cross-package generics + opaque + interfaces in metadata (Q022-2, R5) | **HIGH** | both | dotnet-legacy | F# `Codegen.fs::satisfiesMarker`, `ContractMeta.fs` |
| `pub use Foo.bar` symbol-level (Q022-1) | **MEDIUM** | both | re-export whole package | `typechecker_resolver.l` |
| Auto-FFI scoring | MEDIUM | both | explicit `@externTarget` | F# `Codegen.fs:1842-1972`; no self-host port |
| `@derive(Equals)`, `@generate(Json)` | **HIGH** | both | hand-written equality / `Json.parse` | F# `Records.fs` + emitter sites |
| Opaque-twin generation (`@projectable`) | **HIGH** | both | dotnet-legacy | F# `Emitter.fs` |
| Contract metadata embedding | **HIGH** | both | dotnet-legacy | F# `ContractMeta.fs` |

---

## §9  Remediation plan (production-ready self-hosted compiler)

The remediation sequence is dictated by the critical path: **band 1 is a
hard precondition for every other band**, because without the middle-end
running on self-hosted builds, none of the other features can be safely
exercised end-to-end.

### Band 1 — Wire the self-hosted middle-end into both bridges

_Status: partially shipped in D-progress-276._

Touch points:

- `lyric-compiler/msil/bridge.l:24-69` and `lyric-compiler/jvm/bridge.l:63-129`.
- Insert (in order, after parse, before codegen):

  1. `Lyric.TypeChecker.check(file)` — surface type-check diagnostics.
     **Shipped advisory only:** typechecker raises T0020 / T0050 for
     references to builtin names like `newList` (no Lyric source
     defines them).  Band 6 (D-progress-284/285) added stdlib *type*
     resolution and qualified-name lookup; builtin *function* coverage
     remains incomplete.  Promote to fatal once builtin coverage lands.
  2. `Lyric.ModeChecker.checkFile(file)` — surface V-prefixed
     diagnostics.  **Shipped fatal.**  Verified by
     `SelfHostedMsilBridgeTests.[shm_mode_check_v0004]`.
  3. `Lyric.ContractElaborator.elaborateFile(file)` — lower
     requires/ensures.  **Shipped.**
  4. `Lyric.Mono.monoFile(file)` — same-package monomorphisation.
     **Shipped (D-progress-286).**  `mono.l` was restructured to
     compile under the F# bootstrap parser (replaced `&&` with `and`,
     wrapped unbraced mutation match arms in braces, renamed `result`
     and `out` locals that collided with Lyric keywords `KwResult` /
     `KwOut`).  Both `msil/bridge.l` and `jvm/bridge.l` now import
     `Lyric.Mono` and call `monoFile(elaborated)` between
     `elaborateFile` and the backend codegen step.
  5. Then `codegenMPackage(file, ctx)` / `codegenPackage(file)`.

- Smoke tests landed in `SelfHostedMsilBridgeTests`:
  - `[shm_mode_check_v0004]` compiles a `@proof_required` program with
    an `@axiom` function carrying a body and asserts the bridge
    rejects it.
  - `[shm_parse_error]` compiles a trailing-`+` expression and asserts
    the bridge rejects it.
  - `requires false { … }` runtime panic test is still TODO — the
    self-hosted MSIL emitter doesn't yet support user-defined function
    calls in non-trivial shape (Band 2 §3.6), so the test would fail
    on backend, not on the elaborator.  Re-add once Band 2 lands.

The Band 1 change is in `msil/bridge.l` + `jvm/bridge.l` (~70 LoC each)
plus `SelfHostedMsilBridgeTests.fs` (~35 LoC of new tests).  This is the
single highest-leverage change in the entire remediation.

### Band 2 — MSIL backend feature parity

_Status: shipped in PR #872 (D-progress-282). Items 1–2, 3, 4–5, 7, 8, 11 complete; items 6 (ELambda display-class capture), 9 (EAwait async state machine), 10 (EYield async generator), 12 (auto-FFI scoring) deferred to Band 3._

Order of attack (cheap → expensive):

1. `IEnum` (`docs/01-language-reference.md` §2.6) — emit named-constant
   class with static fields.
2. `IConst`, `IVal` at module scope — synthesise `.cctor` initialiser.
3. `IInterface` and `IImpl` — emit interface `TypeDef` rows; impl blocks
   become method overrides.
4. `IProtected` — port the F# Monitor-based emission from
   `Emitter.fs` C3 region.
5. `IWire` — port the F# DI graph synthesis.
6. `ELambda` — display-class synthesis (capture analysis already lives
   in the type checker; port the emission step from F#
   `Codegen.fs`).
7. `EPropagate` (`?`) — desugar to `match res { Ok(v) -> v; Err(e) ->
   return Err(e) }` in elaborator or codegen.
8. `IOpaque` + projectable twin synthesis — port the F# `Emitter.fs`
   M2.0–M2.2 region.
9. `EAwait` + async state machine — port `AsyncStateMachine.fs` to
   Lyric.  This is the largest single port (~2000 LoC).
10. `EYield` + `IAsyncGenerator` — port `AsyncGenerator.fs`.
11. `IAspect` + weaver — port `Weaver.fs`.
12. Auto-FFI scoring — port from F# `Codegen.fs:1842-1972`.

Each item gets parity smoke tests under `ParityTests.fs` (extend the
existing 20-program suite to ~200 programs covering each feature class).

### Band 3 — JVM backend feature parity

Mostly the same list but shorter, because the JVM backend already has
async generators, protected types, wire blocks, and FFI:

1. `IEnum`, `IDistinctType`.
2. `IInterface`, `IImpl`.
3. `IAspect` + weaver (JVM-shaped).
4. General `ELambda` (non-`Std.Jvm.catch`).  Use `invokedynamic` +
   `LambdaMetafactory` (Java 8+) or synthetic inner classes.
5. Non-generator async via virtual threads or `CompletableFuture` (Q-J002
   gate).
6. `EPropagate`.
7. `Throwable` opt-in for FFI (Q-J009).

### Band 4 — Contract elaborator parity

_Status: loop-invariant lowering shipped in D-progress-277.  Protected-type
entries still deferred._

- ~~Add loop `invariant:` runtime check insertion (the `:39-41` deferral)
  — produces `assert(inv)` at loop-head and at every `continue` /
  fall-through edge.~~ **Shipped.**  `elaborator.l:elaborateStmtDeep`
  now rewrites `SInvariant(inv)` to `mkAssertCall(inv, span)`, and a
  new `functionBodyHasInvariant` predicate opts the function into the
  deep-walk even when the function carries no requires/ensures clauses.
- Add protected-type entry lowering in
  `contract_elaborator/elaborator.l` (the `:43-47` deferral).  **Still
  deferred.**
- Update `docs/36-v1-roadmap.md` R4 to reflect that nested-return
  ensures already work (the current text is stale).

### Band 5 — Self-hosted ports of F# domain logic

These can run in parallel with Bands 2–4.  Each gets a self-hosted Lyric
package + bridge protocol + F# shim, per `SelfHostedFmt.fs` pattern:

- `Lyric.ContractMeta` — partially shipped (`contract_meta.l`); finish
  per `docs/36-v1-roadmap.md` R4.
- ✅ `Lyric.Derives` — `@derive(Equals)`, `@derive(Hash)`, `@derive(Show)`,
  `@generate(Json)` on records, exposed records, and distinct types;
  wired into both MSIL and JVM bridges after contract elaboration
  (D-progress-287).
- `Lyric.Generics.Monomorphizer` — cross-package + value-generic
  extensions.  (Same-package mono via `Lyric.Mono.monoFile` is now
  wired in both bridges — D-progress-286; cross-package and
  value-generic specialisation remain F#-only.)
- `Lyric.RestoredPackages` — cross-package symbol resolution.

### Band 6 — Cross-package support

- ✅ `lyric-compiler/lyric/type_checker/typechecker_resolver.l` —
  multi-segment qualified type names (e.g. `Std.Collections.List`) now
  resolve via last-segment symbol-table lookup; no longer deferred to
  T7+ (D-progress-285).
- ✅ Multi-file packages (`docs/19`) and project-as-DLL bundling
  (`docs/20`) — `emitProject` routes through `--internal-project-build`
  → F# `internalProjectBuild` → F# `Emitter.emitProject`; parity
  verified by `ProjectBuildTests.fs` (D-progress-285).  In-process
  multi-file bridge deferred to Track A A1.x.

### Band 7 — Acceptance gate

The self-hosted compiler is production-ready for both targets when:

- Every item in `docs/02-worked-examples.md` builds and runs under
  `--target dotnet` and `--target jvm` **without** the F# emitter
  pre-validating (so disable `--target dotnet-legacy` in the test
  harness).
- The 20-program parity suite expands to one program per feature
  class in `docs/01-language-reference.md` §§2–14 (target ~200
  programs).
- `lyric prove`, `lyric public-api-diff`, `lyric test`, `lyric doc`
  on every stdlib module produces output identical to the F#-emitter
  baseline.
- `--target dotnet-legacy` is removed and `Emitter.fs` is deleted, per
  the `docs/23-fsharp-shim-elimination.md` plan.

---

## §10  Specific corrections needed in existing docs

While auditing, the following authoritative docs were found to contradict
the actual state of the code.  Each should be patched as part of band 1
(low-risk doc work):

| Doc | Line range | Current text | Reality | Status |
|---|---|---|---|---|
| `docs/36-v1-roadmap.md` | R4 §"Critical dependency" paragraph (~lines 181-191) | "self-hosted `contract_elaborator/elaborator.l` (M5.2 stage 2) does not yet replicate these three cases" | Elaborator now covers nested-return ensures (was already true) and loop `invariant:` lowering (D-progress-277); only protected-type entries remain deferred | ✅ Patched in D-progress-277 commit |
| `docs/10-bootstrap-progress.md` | tier table referencing `Lyric.Mono` | "M5.2 stage 4 — D-progress-229" | Per `mono.l:6-27` mono runs same-package-only; not wired into `Msil.Bridge` / `Jvm.Bridge`. Add explicit "not invoked from production builds" note | ✅ Patched in D-progress-276 |
| `docs/33-platform-parity-remediation.md` | §7 Parity milestone | "Both self-hosted emitters have reached Phase R parity" | True for 20-program smoke-test set only; not true for full M1.4 language surface. Section should explicitly bracket "Phase R parity" as the smoke-test subset | ✅ Patched in D-progress-276 / PR #830 (Scope-clarification block; "Phase R parity" now bracketed as the 20-program subset) |
| `docs/05-implementation-plan.md` | Phase 1 / Phase 5 status text | implies self-hosting milestones for codegen | self-hosted backend production-readiness blocker is band 1 (middle-end plumbing), partly addressed in D-progress-276 (typechecker / modechecker / elaborator wired; mono and cross-package still deferred) | ✅ Patched in PR #830 (new "Phase 5 production readiness" subsection cross-links docs/41 §9 bands) |

---

## §11  Out of scope for this audit (deferred deliberately)

- Performance / allocation profiling of self-hosted vs F# pipeline.
- Compile-time benchmarks (Q011 surface-freeze gate covers this for
  stdlib).
- Stage-2/3 reproducibility bootstrap (`scripts/bootstrap.sh`) — gated by
  G5 (D066) post-v1.0.
- JS/WASM target (`docs/35-js-wasm-component-sketch.md`) — unbacked.
- LSP completeness (`docs/16-lsp-vscode-plan.md`) — separate audit.

---

## §12  References

- `docs/01-language-reference.md` — authoritative language description.
- `docs/05-implementation-plan.md` — phasing plan.
- `docs/10-bootstrap-progress.md` — shipped-milestone log (13,374 lines).
- `docs/23-fsharp-shim-elimination.md` — F# surface freeze and sunset.
- `docs/33-platform-parity-remediation.md` — Phase R parity story.
- `docs/36-v1-roadmap.md` — v1.0 gate decisions and critical-path
  milestones; this audit refines but does not replace.
- `lyric-compiler/msil/bridge.l`, `codegen.l`, `lowering.l`, `ffi.l`.
- `lyric-compiler/jvm/bridge.l`, `codegen.l`, `lowering.l`, `driver.l`.
- `lyric-compiler/lyric/{lexer,parser,type_checker,mode_checker,contract_elaborator,mono}.l`
  — self-hosted middle-end packages.
- `bootstrap/src/Lyric.Emitter/{Emitter,Codegen,AsyncStateMachine,AsyncGenerator,Weaver,ContractMeta,Records,RestoredPackages}.fs`
  — F# bootstrap emitter (load-bearing today).
- `bootstrap/src/Lyric.Cli/{Program,SelfHostedMsil,SelfHostedJvm,SelfHostedCli}.fs`
  — CLI dispatch and bridge plumbing.
