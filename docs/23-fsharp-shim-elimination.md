# 23 — F# Shim Elimination

**Status: STDLIB SHIM ELIMINATED.** The original target —
`bootstrap/src/Lyric.Stdlib/Stdlib.fs` — was deleted entirely in
D-progress-140 (2026-04 era). The plan below describes the
multi-stage journey; sections 4.1–4.3 are now **historical record**
of how each bucket was retired.

What remains, and the **current policy** (per `CLAUDE.md` §"F# is
for the existing bootstrap compiler only"):

- The F# stdlib shim project is **gone**. `Lyric.Stdlib.dll` is now
  the Lyric-compiled bundle from `lyric-stdlib/lyric.toml`, with no
  F# code and no `FSharp.Core.dll` runtime dep.
- Ecosystem-library host shims still exist under
  `bootstrap/src/Lyric.<X>.Host/` for: Auth, Jobs, Jvm.Hosts, Mq,
  Session, Web, Ws. `Lyric.Storage.Host` was removed by PR #1170
  (#733): the local-filesystem backend is now a fully native Lyric
  implementation against direct BCL externs in
  `lyric-storage/src/_kernel/net/storage_kernel.l`. The remaining
  ecosystem shims are on the same deletion schedule as the stdlib
  shim was — they're tolerated until the self-hosted replacement is
  ready, then deleted. **No new host shims** are permitted; new BCL
  externs go in `lyric-stdlib/std/_kernel/*.l` via `extern type` /
  `extern package` declarations directly.
- The F# stage-0 bootstrap compiler under `bootstrap/src/Lyric.{Lexer,
  Parser,TypeChecker,Emitter,Cli}/` continues to exist solely so the
  stage-0 binary can build the self-hosted Lyric compiler from `.l`
  sources. It is closed to new code; only mechanical bug fixes that
  unblock stage-0 → stage-1 bootstrap are accepted.
- The AOT entry point `bootstrap/src/Lyric.Cli.Aot/` is a thin
  trampoline into the Lyric-emitted `Lyric.Cli.Program.main`; it
  contains no F#.

**Implementation:** Phase 5 §M5.4 (stdlib shim elimination shipped
per D-progress-140). Ecosystem-library shim elimination is ongoing
under per-library tracking issues.

**Builds on:** `docs/14-native-stdlib-plan.md`, `docs/20-project-as-dll.md`,
`docs/03-decision-log.md` D035 / D038.

---

## 0. Remaining load-bearing F# — live inventory

Every F# project still in the tree, why it's tolerated, and the concrete
thing that unblocks its deletion. **Keep this table current**: when a row's
blocker is resolved, delete the F# and strike the row. Nothing here is
"owned" — it's debt on a deletion schedule.

| F# project | Why it still exists | Deletion unblocked by |
|---|---|---|
| `Lyric.Lexer`, `Lyric.Parser`, `Lyric.TypeChecker`, `Lyric.Emitter` | The stage-0 bootstrap compiler. Stage-0 compiles the self-hosted `.l` compiler (and stdlib bundle) into DLLs; the self-hosted lexer/parser/checker/MSIL backend already exist in `lyric-compiler/` but are *built by* this F#. | A reproducible way to produce a stage-0 `lyric` binary without F# (e.g. a checked-in/cached bootstrap artefact or a prior self-hosted release building the next), plus the stage-2 reproducibility check (currently blocked — see `scripts/bootstrap.sh` stage 2). |
| `Lyric.Cli` — `Program.fs` | Bootstrap-only entry point handling the four internal flags `--internal-build`, `--internal-project-build`, `--internal-contract-meta`, `--internal-manifest-build` that stage 1 and the emitProject subprocess hop rely on. The F# *user-facing* CLI dispatcher was already deleted (#860). | The self-hosted MSIL bridge handling project/manifest/contract-meta builds fully in-process (no subprocess hop), so the internal flags are no longer invoked. |
| `Lyric.Cli` — `Manifest.fs` | TOML parser consumed by `--internal-manifest-build` (stage-1 stdlib bundle). Self-hosted equivalent already exists at `lyric-compiler/lyric/manifest.l`. | Same as the `Program.fs` row — once the in-process bridge drives the manifest build, this goes with it. |
| `Lyric.Cli` — `SelfHosted*.fs` | Test-infrastructure bridges that drive the self-hosted MSIL/JVM pipeline in-process via reflection (used by `bootstrap/tests/**`). Not on any compiled program's runtime closure. | Native test harness (Lyric-side) that exercises the self-hosted pipeline without an F# reflection bridge. |
| `Lyric.Cli.Aot` — `Program.cs` | Thin C# trampoline into the Lyric-emitted `Lyric.Cli.Program.main`. Not F# code; included here so the dependency picture is complete (#1526). | Retires together with the internal-flag handling above; the trampoline itself shrinks to nothing once NativeAOT publishing of the Lyric CLI is the shipping path. |
| `Lyric.Jobs.Host`, `Lyric.Mq.Host`, ~~`Lyric.Session.Host`~~, `Lyric.Web.Host`, `Lyric.Ws.Host`, `Lyric.Jvm.Hosts` | `@externTarget` host shims for ecosystem libraries' BCL/JVM boundaries. `Lyric.Storage.Host` was removed (#1170 / #733), `Lyric.Auth.Host` was removed (#1622 follow-up), and `Lyric.Session.Host` was removed (PR #3016 / #1777) by porting their backends to native `_kernel/*.l` BCL externs. | Each remaining library porting its kernel to native `extern type` / `extern package` declarations in `lyric-<lib>/src/_kernel/**`, the way Storage, Auth, and Session did. Tracked per-library. |
| `bootstrap/tests/Lyric.{Lexer,Parser,TypeChecker,Emitter,Cli}.Tests` | Expecto runners. The Emitter suite also discovers and runs every self-hosted `*_self_test.l`; the Cli suite drives the self-hosted bridges. | Native `lyric test` discovering the `.l` self-tests directly (partially landed; see #1324) plus a Lyric-side runner for the F# unit coverage worth keeping. |

---

## 1. Motivation (historical)

The discussion below describes the world in which
`bootstrap/src/Lyric.Stdlib/Stdlib.fs` still existed. As of
D-progress-140 this file and project are deleted; the section is
retained as the rationale that drove the migration.

After `docs/14`'s P0–P3 (D-progress-104 closes P3) the F# shim
`bootstrap/src/Lyric.Stdlib/Stdlib.fs` was **1473 LoC across 23 types**.
The stdlib bundle proof (D-progress-103) demonstrated that pure
Lyric source compiles end-to-end into a single
`Lyric.StdlibBundle.dll` — but that bundle still depends on a
sibling `Lyric.Stdlib.dll` (the F# shim) for the host-grade
methods Lyric can't yet express, plus `FSharp.Core.dll` (≈2.4 MB)
for F#'s runtime types.

The user's stated milestone — *"compile the stdlib into a single
project DLL, reference it from an arbitrary lyric program so the
source isn't always required"* — has two remaining gaps:

1. The F# shim is a separate DLL.
2. `FSharp.Core.dll` rides along.

Closing **(1)** fully without a permanent F# runtime tax means
either (a) a Cecil ILMerge step that pulls F# IL into the bundle
(keeps the FSharp.Core dep), or (b) a C# rewrite of the kernel
that merges into the bundle without F# runtime types, or
**(c) growing Lyric to express what's left of the kernel and
porting it to Lyric source**. This document specifies (c).

The path is multi-stage and gated on language work, but the end
state is the cleanest:

- One bundled `Lyric.Stdlib.dll`.
- No `FSharp.Core.dll` runtime dep.
- Every public stdlib surface is Lyric source — verifiable, contract-
  enforceable, self-hosting-friendly.
- A small irreducible BCL kernel (`@externTarget` declarations only)
  remains in `lyric-stdlib/std/_kernel/`.

---

## 2. Definitions

| Term | Meaning |
|---|---|
| **F# shim** | `bootstrap/src/Lyric.Stdlib/Stdlib.fs`. The host-grade methods that the emitter targets via `@externTarget("Lyric.Stdlib.<Class>.<Method>")`. |
| **Kernel boundary** | Per `docs/14` §3 — the irreducible set of `@externTarget` declarations bottoming out at the BCL. Audited; `@axiom`-marked. |
| **Native port** | Replacing an F#-shim type with pure Lyric source under `Std.*` packages, possibly with `@externTarget` declarations against BCL types directly (skipping the F# intermediate). |
| **G-item** | A boundary-primitive language feature, numbered following `docs/14` §4 (G1–G7). New items below extend the sequence (G8+). |

---

## 3. The irreducible kernel after this plan ships

These F#-or-BCL surfaces stay extern forever per `docs/14` §3.
Their `@externTarget` declarations live in
`lyric-stdlib/std/_kernel/*.l` and target BCL types directly — no F#
intermediate.

| Surface | Why irreducible | Approx. extern count |
|---|---|---|
| Console / file / network / process / time syscalls | Syscalls. | ~30 |
| `System.Text.Json` tokenizer + slice readers | Perf cliff; BCL has SIMD-tuned forms. | ~15 |
| `System.Net.Http` (TLS, conn pool) | TLS / cert path is multi-year work. | ~15 |
| `System.Net.HttpListener` server | Same. | ~10 |
| `System.Math` transcendentals | Hardware-tuned BCL forms. | ~20 |
| `System.Threading.Tasks.Task` scheduler | TPL by D001. | ~10 |
| `System.Random` entropy source | Crypto-grade entropy. | ~5 |
| `System.Threading.AsyncLocal<T>` | Runtime-supplied call-context primitive. | ~3 |
| `System.Security.Cryptography` primitives | Audit cost. | ~10 |
| `System.Globalization.NumberStyles` for `Double.ToString("R", InvariantCulture)` | Round-trip float rendering edge case. | ~1 |

**Hard cap (Decision F):** ≤150 extern declarations across
`lyric-stdlib/std/_kernel/`. The `RenderDoubleSlice` carve-out from P3
counts; everything else here is already in `_kernel/`.

---

## 4. Type-by-type port plan (historical — completed in D-progress-140)

The original plan partitioned the 23 F# shim types into three
buckets: portable to Lyric today (Bucket B), gated on new language
features (Bucket C), and out-of-scope (Bucket D). All three buckets
have shipped — the entire `Lyric.Stdlib` F# project was deleted in
D-progress-140 once the last extern was migrated. The tables below
remain as a record of which types went where and what gating
work each one needed.

After P3 the F# shim had 23 types (1473 LoC). Six of those were
genuinely portable to Lyric today; nine required new language
features (G-items §5); three were JVM emit helpers that didn't
belong in the stdlib at all; the rest stayed extern via direct BCL
targeting.

### 4.1 Bucket B — portable to Lyric source today

| F# type | LoC | Replacement | Gating | Notes |
|---|---|---|---|---|
| `Console.PrintlnAny` / `ToStr` | 29 | Codegen-only: emit `null`-check + `WriteLine(string)` inline at `println(non-string)` / `toString(any)` call sites. | none | Pure emitter change. The F# `Console` type retires. **Pre-G work — could ship today.** |
| `Contracts.Expect` / `Assert` / `Panic` | 20 | Lyric source under `Std.Contracts` calling the existing `panic` / `assert` builtins; throws `LyricAssertionException` (see G9). | G9 | Trivial body once exception types work. |
| `LyricAssertionException` | 3 | User-defined exception type in Lyric (G9). | G9 | One-liner once G9 lands. |
| `RandomHost` | 14 | Direct `@externTarget("System.Random.…")` declarations in `_kernel/random.l`. | none | Already mostly there; the F# shim adds zero value. |
| `CancelHost` | 52 | Direct `@externTarget("System.Threading.CancellationToken{,Source}.…")` declarations in `_kernel/task.l`. | none | Pure passthrough; F# shim adds zero value. |
| `MapHelpers<K, V>` | 31 | Replaced by native `Std.HashMap[K, V]` per `docs/14` P2. | G1, G2, G3 (shipped), Decision B | Already in `docs/14` plan. |

**Bucket B subtotal:** ~150 LoC removed.

### 4.2 Bucket C — gated on new language features

| F# type | LoC | Gating G-item | Replacement |
|---|---|---|---|
| `TryHost<T>` | 39 | G10 (try/catch FFI) | Lyric `try { Result.Ok(extCall()) } catch (e: System.Exception) { Result.Err(e.Message) }`. |
| `FileHost` | 107 | G10 | Same pattern as `TryHost`: each `read*` / `write*` becomes a Lyric function with try/catch around the BCL call. |
| `StubCounter` / `StubCounterHost` | 24 | G7 (`protected type` codegen) | Lyric `protected type StubCounter { var count: Int = 0; … }`. |
| `LyricTaskScope` / `TaskScopeHost` | 111 | G7 + G12 (delegate lowering) | Lyric `protected type Scope { var tasks: List[Task]; … }`. |
| `AmbientHost` | 35 | G11 (`AsyncLocal[T]` primitive) | Lyric `@asyncLocal val ambient: CancellationToken`. |
| `TaskHost` | 25 | G12 (delegate lowering completeness audit) | Direct `@externTarget("System.Threading.Tasks.Task.…")` declarations. |
| `JsonHost.Get*Slice` family + readers | ~150 | shipped per D-progress-139 (no G-item — fixed via three small emitter changes: leading-param exact-type filter on default-arg overload selection; `Ldarg`-not-`Ldarga` for inout-mode value-type receivers; culture-invariant `toString(Double | Float)`) | Pure-Lyric `lyricJsonGet*Slice` in `_kernel/json_host.l` driving `JsonElement+ArrayEnumerator` via a `while hostEnumMoveNext(en) { … }` loop. `Parse` / `EncodeString` / `RenderDoubleSlice` also retired (Parse → direct extern with default-arg struct; EncodeString → split into `JsonEncodedText.Encode` + `ToString` + Lyric concat; RenderDoubleSlice → inline `mkSliceHelperInline` with culture-invariant `toString`). |
| `HttpClientHost`, `HttpServerHost` | 200 | G12 audit | `HttpClientHost.fs` deletion deferred until #3027 (F# emitter `EPath` → `ldsfld` gap for reference-typed module vals) lands; `hostDefaultClient()` still routes through the F# `Lazy<HttpClient>` singleton. Once #3027 ships, `hostDefaultClient()` returns `defaultClient` directly and `HttpClientHost.fs` deletes. `HttpServerHost`: direct `@externTarget` against `System.Net.HttpListener.…` once delegate handling is audited. |

**Bucket C subtotal:** ~691 LoC eliminated (or migrated to direct
`@externTarget` declarations, which moves them out of `Stdlib.fs`
into `lyric-stdlib/std/_kernel/*.l`).

### 4.3 Bucket D — JVM emit helpers (move out of stdlib)

| F# type | LoC | Action |
|---|---|---|
| `JvmInternals` | 44 | Move to `lyric-compiler/jvm/` source tree (currently F#; eventually Lyric). |
| `JvmByteBuilder`, `JvmByteHost` | 127 | Same. |
| `JvmZipHost` | 25 | Same. |
| `JvmConstantPool`, `JvmPoolHost` | 234 | Same. |

**Bucket D subtotal:** 430 LoC moves out of the stdlib bundle
entirely. Lives in the JVM emitter's own project. The stdlib
bundle no longer carries JVM-only code — a separate
`Lyric.Jvm.dll` (or eventually a Lyric-source equivalent) ships
with the JVM emit subsystem.

### 4.4 Net F# shim trajectory

| Stage | F# shim LoC | Notes |
|---|---|---|
| Pre-P0 | ~1700 | Per `docs/14` §6 P0 baseline. |
| Post-P3 (today, D-progress-104) | 1473 | Parse / Format / 4× Render*Slice retired. |
| After Bucket B (no language work) | ~1320 | Console / Contracts / RandomHost / CancelHost trivially ported; LyricAssertionException stays until G9. |
| After Bucket D split-out | ~890 | Jvm* moves to JVM project. |
| After G7 | ~755 | StubCounter / TaskScope ported. |
| After G9 | ~735 | LyricAssertionException ported. |
| After G10 | ~440 | TryHost / FileHost / JsonHost out-path ported. |
| After G11 | ~405 | AmbientHost ported. |
| After G12 audit | ~150 | TaskHost / HttpClientHost / HttpServerHost direct-extern'd. |
| **End state** | **~150** | Tokenizer-coupled JsonHost methods only (Parse / EncodeString / RenderDoubleSlice + the `JsonElement` readers). |

The end-state ~150 LoC of F# is the irreducible kernel from §3.
At that point we can decide whether to:

- **Keep it as F#** (smallest delta, ships as a tiny separate
  DLL alongside the Lyric stdlib bundle).
- **Rewrite it in C#** (eliminates the F# runtime dep —
  FSharp.Core no longer ships).
- **Cecil-merge it into the bundle** (single DLL, but C# version
  pulls only `System.*`).

That decision is **out of scope for this plan** — it's a
distribution-shape question better answered after the shim has
shrunk to its irreducible floor.

---

## 5. Language gaps (the new G-items)

Each gap below is a discrete piece of compiler work. They are
ordered by leverage (most-LoC-eliminated first).

### G7. `protected type` codegen (already in `docs/14` §4.3 P2)

Lyric's `protected type` is the Phase 3-shaped primitive for
"Ada-style structurally-locked shared mutable state" (per
`docs/03-decision-log.md` D-progress-049 onward).  The parser /
type checker / emitter all support `protected type` already
(shipped as D-progress-079 and follow-ups; ProtectedTypeTests.fs
has 14 test cases covering fields, invariants, barriers, generics,
and the tri-modal lock-flavour split).

**StubCounter — shipped (D-progress-123).**  `lyric-stdlib/std/testing_mocking.l`
(new top-level file, shadows `_kernel/testing_mocking.l` on .NET)
defines `pub protected type StubCounter { var count: Int = 0; … }`
and thin wrapper functions.  `Emitter.fs` gained `IProtected`
scanning in the artifact-import loop so cross-package references to
a `protected type` resolve to the correct CLR type.  F#
`StubCounter` + `StubCounterHost` (~24 LoC) are now dead code;
removal deferred until `LyricTaskScope` (next step) is ported so
the shim rebuild stays atomic.

**Remaining:** `LyricTaskScope` / `TaskScopeHost` (~111 LoC).
Gates on G12 delegate-lowering being complete (not yet shipped).

**Unblocks:** `StubCounter` ✅; `LyricTaskScope` / `TaskScopeHost`
pending. ~135 LoC of F# shim retired when both are done.

### G8. Codegen-emitted `null`-aware `println` / `toString` ✅ shipped (D-progress-105)

Today the emitter calls `Lyric.Stdlib.Console.PrintlnAny(obj)` /
`ToStr(obj)`. Replace with inline IL at the call site:

```text
println(value):
  ldarg value
  brfalse  printNull
  ldarg value
  callvirt System.Object::ToString()
  call System.Console::WriteLine(string)
  br end
printNull:
  ldstr "()"
  call System.Console::WriteLine(string)
end:
```

**Unblocks:** `Console.PrintlnAny` / `ToStr` (29 LoC).

**Cost estimate:** ~80 LoC of codegen change in the
`println` / `toString` builtin sites. **Smallest G-item — could
ship as a P0 follow-up before any other work.**

### G9. User-defined exception types

A Lyric type that inherits from `System.Exception` and can be
constructed via `new` in Lyric source. Two surface options:

```lyric
@exception
type AssertionFailed { message: String }
```

or:

```lyric
extern type Exception = "System.Exception"
type AssertionFailed extends Exception { message: String }
```

**Unblocks:** `LyricAssertionException` (3 LoC); also unblocks
`Contracts.Expect` / `Assert` / `Panic` once paired with the
existing `panic` builtin.

**Cost estimate:** ~250 LoC of typechecker + emitter work to
recognise the inheritance shape and emit the right CLR class.

### G10. try/catch FFI bridging

Lyric's `try { … } catch (e: T) { … }` syntax already exists for
Lyric-thrown exceptions. The gap is making it work for exceptions
thrown by `@externTarget`-routed BCL calls — specifically:

- `e: System.Exception` as a catch pattern.
- `e.message` / `e.GetType().Name` accessible from the Lyric
  `catch` block.
- `finally { … }` clause running on both success and failure
  paths.

**Unblocks:** `TryHost<T>` (39 LoC), `FileHost` (107 LoC),
`JsonHost.Get*Slice` (~150 LoC). ~296 LoC retired.

**Cost estimate:** ~400 LoC. The IL pattern is well-known
(`try { … } finally { … }` in CIL); the work is teaching the
type checker about exception type hierarchies and making
`@externTarget` calls look the same as Lyric calls from the
`try` block's perspective.

### G11. `AsyncLocal[T]` primitive

A Lyric-level surface for the BCL's
`System.Threading.AsyncLocal<T>` slot. Two options:

- **Annotation form:** `@asyncLocal val ambient: CancellationToken`
  declares a thread-local-ish slot accessible to the running
  async task and its children.
- **Type form:** `extern type AsyncLocal[T] =
  "System.Threading.AsyncLocal\`1"` plus methods `current`,
  `setCurrent`, `restore`. Already shippable as kernel
  declarations once Lyric's generic-extern type machinery
  handles `AsyncLocal<T>` correctly (G3 should suffice, already
  shipped).

**Unblocks:** `AmbientHost` (35 LoC).

**Cost estimate:** Type-form is ~30 LoC of `_kernel/task.l`
declarations + a verifier pass over the existing typechecker
generic-extern path. Annotation-form is ~150 LoC of new
attribute machinery; the type-form is preferred for the
bootstrap.

### G12. Closure → `System.Action` / `System.Func<…>` lowering audit

Lyric closures lower to delegate types today (per
`TaskScopeHost.SpawnAction` / `SpawnFunc` use), but the
boundary cases for `Task.ContinueWith(Action<Task>)` etc. need
auditing. Concretely:

- `() -> Unit` closures lower to `System.Action`.
- `() -> T` closures lower to `System.Func<T>`.
- `(T) -> Unit` lowers to `System.Action<T>` (especially
  `Action<Task>` for continuations).

Once the audit confirms all three shapes work, every BCL method
that takes a delegate becomes directly `@externTarget`-able from
Lyric source.

**Unblocks:** `TaskHost` (25 LoC), `HttpClientHost` (139 LoC),
`HttpServerHost` (61 LoC). ~225 LoC retired.

**Cost estimate:** ~50 LoC of typechecker fixes if any boundary
case is missing; pure verification work otherwise.

---

## 6. Phasing

Each phase is a self-contained PR sequence with green tests at
every commit boundary. Phases 1–3 are independent; Phase 4 is
gated on Phase 3.

### Phase 1 — Bucket B (no language work, ~3 PRs)

1. **G8 codegen + retire `Console`** — ~80 LoC. Smallest, lowest-
   risk slice. Ships first.
2. **`RandomHost` / `CancelHost` direct-extern** — replace the
   F# shim methods with `@externTarget` declarations in the
   matching `_kernel/*.l` file. Mostly mechanical.
3. **Bucket D split** — move `Jvm*` types out of
   `bootstrap/src/Lyric.Stdlib/Stdlib.fs` into
   `lyric-compiler/jvm/Jvm.Hosts.fs` (new F# project under the
   JVM tree) and update the JVM emitter's `@externTarget`
   declarations to point there. **Frees the stdlib bundle from
   ~430 LoC of JVM-specific code that doesn't belong.**

**Exit criterion:** F# shim down to ~890 LoC. Stdlib bundle
unchanged in surface; JVM emitter unchanged in functionality.

### Phase 2 — G7 (`protected type` codegen) and follow-ups

Already on the Phase 3 roadmap per `docs/03-decision-log.md`.
Lands `protected type` codegen with monitor-based locking on
field access. Then port `StubCounter` / `LyricTaskScope` to
Lyric source.

**Exit criterion:** F# shim down to ~755 LoC.

### Phase 3 — G9 (user exception types) + G10 (try/catch FFI)

Two PRs, in sequence (G9 first because G10's tests want to throw
user-defined exceptions across the FFI):

1. **G9 — user-defined exception types.** Adds the type-checker
   recognition + emitter pattern. Port `LyricAssertionException`
   + `Contracts.*` to Lyric.
2. **G10 — try/catch FFI bridging.** Lyric `try { ext.call() }
   catch (e: System.Exception) { … }` works. Port `TryHost`,
   `FileHost`, `JsonHost.Get*Slice` to Lyric source.

**Exit criterion:** F# shim down to ~440 LoC.

### Phase 4 — G11 (`AsyncLocal`) + G12 audit

1. **G11 — `AsyncLocal[T]` extern type** in
   `_kernel/task.l`. Port `AmbientHost`.
2. **G12 audit.** Verify delegate lowering for the three closure
   shapes. Direct-extern `TaskHost`, `HttpClientHost`,
   `HttpServerHost`.

**Exit criterion:** F# shim down to ~150 LoC — the irreducible
kernel surface (`JsonHost` tokenizer-coupled methods +
`RenderDoubleSlice`).

**Update (D-progress-139):** the `JsonHost` carve-out also
retired — the eight remaining live methods migrated to pure Lyric
in `_kernel/json_host.l` (Parse, EncodeString, RenderDoubleSlice,
and the five `Get*Slice` readers).  No new G-item was needed; the
migration was unblocked by three small emitter fixes (default-arg
overload disambiguation, `Ldarg` vs `Ldarga` for inout-mode value-
type receivers, culture-invariant `toString` for floating-point).
Net F# shim is now zero LoC of host types.

### Phase 5 — F# shim project deleted (D-progress-140)

Decision: **delete entirely.**  With the shim empty of host types,
keeping the project around added zero value — no IL hosted, no
runtime resolution required.  D-progress-140 ships:

- Removal of `bootstrap/src/Lyric.Stdlib/` (project + source).
- `<ProjectReference>` lines pulled from `Lyric.Cli`,
  `Lyric.Emitter`, and `Lyric.Emitter.Tests`.
- Solution entry / configuration / nesting tag scrubbed from
  `Bootstrap.sln`.
- CLI + test infrastructure (`Cli/Program.fs`, `EmitTestKit.fs`,
  `ProjectAsDllTests.fs`, `NugetShimTests.fs`) drop their
  `Lyric.Stdlib.dll` copy / probe paths.
- `lyric-stdlib/lyric.toml` reverts `output_assembly` to the canonical
  `Lyric.Stdlib.dll`; the Lyric-compiled stdlib bundle now ships
  under that name with no F# shim to clobber.

End state: the only `Lyric.Stdlib.dll` the SDK ever ships is the
Lyric-compiled bundle.  No F# host code, no FSharp.Core dep at
runtime, no Cecil-merge step needed.

---

## 7. Validation strategy

The same three-layer strategy `docs/14` §7 establishes for the
native stdlib applies here:

1. **Property-based parity tests.** For each ported type, run
   the same operation sequence on the Lyric port and the
   pre-port F# shim, assert equivalent results. Lives in
   `bootstrap/tests/Lyric.StdlibParity.Tests/` (already created
   per `docs/14`).
2. **Contract assertions.** Each port declares its invariants
   in `@runtime_checked` mode. Contract failures during parity
   testing are a parity bug.
3. **Snapshot tests for `@generate(Json)` synthesised output.**
   The synthesiser already changed shape in P3-3 (D-progress-104);
   Phase 3's G10 work changes it again. Snapshot tests catch
   accidental output drift.

---

## 8. Risk register

| Risk | Probability | Impact | Mitigation |
|---|---|---|---|
| G7 (`protected type` codegen) blocks Phase 2 indefinitely | Medium | High | Phase 1 is independent of G7; banks all of Bucket B before Phase 2 starts. |
| Lyric's exception type story (G9) needs more design than ~250 LoC | Medium | Medium | Carry the design discussion as a Q-item; delay Phase 3 until resolved. |
| try/catch FFI (G10) surfaces `System.Exception` hierarchy edge cases (e.g., `AggregateException` from `Task` continuations) | Medium | High | G10 spec MUST cover `AggregateException` unwrapping for async. Tested by porting `TaskScopeHost.AwaitAll`. |
| AsyncLocal semantic mismatch between BCL and Lyric (e.g., propagation across `Task.Run`) | Low | High | Document the inherited BCL semantics in `_kernel/task.l`. No Lyric-level abstraction over them. |
| Distribution-shape decision (Phase 5) keeps a permanent F# shim | Low | Low | Acceptable end state — ~150 LoC of F# bridging is below the noise floor. |

---

## 9. Open questions

- **Q-shim-A: Should `LyricAssertionException` be a Lyric-side
  type or a kernel `extern type`?** The user-facing surface is
  the same; the codegen difference is whether `panic` /
  `assert` constructs the exception via a Lyric `new` (G9) or a
  kernel `@externTarget`. Recommend G9 because the intent
  ("user-defined exception") generalises to other stdlib uses.

- **Q-shim-B: Do we need `AggregateException` unwrapping at the
  G10 layer, or in `Std.Task`?** BCL `Task.WhenAll` always wraps
  child failures in `AggregateException`; the Lyric stdlib
  surfaces individual `Bug` / domain-specific errors. Most
  pragmatic answer: G10 catches `AggregateException` and
  re-raises the first inner exception, with a follow-up
  refinement to surface the full set when needed.

- **Q-shim-C: When does G7 (`protected type` codegen) actually
  ship?** Already on the Phase 3 roadmap but not yet underway.
  This plan assumes a Phase-3 sprint allocation; if Phase 3
  slips, Phase 2 of *this* plan slips with it.

- **Q-shim-D: After Phase 5 ships, do we keep a tiny `Lyric.
  Stdlib.Kernel.dll` separately or merge it via Cecil?** Pure
  packaging decision; defer until Phase 4 completes.

- **Q-shim-E: Should the JVM helper split-out (Bucket D) move to
  Lyric source eventually?** Yes — once the JVM emitter itself
  ports to Lyric (`lyric-compiler/jvm/`), the helpers ride
  along. Until then they stay as F#.

---

## 10. References

- `docs/14-native-stdlib-plan.md` — the plan whose P3 trio shipped
  in D-progress-104. This document continues the same trajectory.
- `docs/03-decision-log.md` D035 (M1.4 scope cuts), D038 (native
  stdlib umbrella), D-progress-049+ (`protected type` history),
  D-progress-104 (P3 trio).
- `docs/05-implementation-plan.md` Phase 3 (where G7 lives) and
  Phase 5 (M5.4+ self-hosting context for this plan).
- `docs/06-open-questions.md` Q021 (`where` clauses, shipped),
  Q022 (extern visibility), Q-stdlib-bundle-consume (consumer-
  side bundle resolution).
- `docs/20-project-as-dll.md` — the bundling design that defines
  the "single DLL" target.
- `bootstrap/src/Lyric.Stdlib/Stdlib.fs` — the F# shim being
  eliminated.
- `lyric-stdlib/std/_kernel/` — the audited extern boundary that this
  plan grows incrementally.
