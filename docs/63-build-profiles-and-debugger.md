# 63 — Build profiles, output shapes, and the Lyric debugger

**Status:** **Band B0 shipped**, codified in **D132** (the flag surface: profile/shape axes,
`--shape` + `--aot`/`--standalone` sugar, `[build] shape`/`profile` manifest
keys, the re-scoped `--define`/`--watch`/`--rid` gates, `F0040`–`F0044`, and
the `--release` migration note). Bands B1–B7 — span plumbing, debug-information
emission, and the debugger — are unimplemented. Three framing decisions are
recorded as **settled** in §3.4, §4.4, and §8.1; the rest is open
(Q-BP-001–Q-BP-011, §13).

Deferred out of B0 with tracked follow-ups: `--shape standalone` has no
toolchain path on any target and fails loud with `F0044` (#6262); the profile
axis does not yet reach codegen, so `--release` performs no optimization and
does not relax overflow checking as the language reference describes (#6263).

**Method.** The current-state findings in §2 were produced by auditing the code
as source of truth. Every claim is grounded in a `file:line` reference, an
observed CLI behaviour, or an open issue number. Where a claim is *not* verified
it is marked **[unverified]** — see §12 for the risk register.

---

## 1. Motivation

The immediate goal is a Lyric debugger. The blocker is not the debugger itself:
it is that **Lyric emits no debug information on any target**, and that the one
flag which could reasonably gate debug-info emission — `--release` — does not
mean what its name suggests.

Today `--release` selects a *packaging mode* (self-contained Native AOT), not an
*optimization/symbol profile*. That conflation has three costs:

1. There is no way to ask for "optimized, no symbols" without also asking for
   "AOT-compiled and self-contained". An optimized framework-dependent library
   DLL — the artifact you would publish to NuGet — is unreachable today.
2. There is no way to ask for "debug symbols" at all, because no flag means it
   and no backend emits it.
3. `--define`, `--watch`, and `--target native` are each rejected against
   `--release` for reasons that are really about the *AOT path*, not about the
   *release profile*. The rejections are correct today and would be wrong after
   the axes are separated (§5.3).

This document specifies the flag refactor, the debug-information emission work
it gates, and the debugger architecture that consumes it.

---

## 2. Current state

### 2.1 `--release` is a packaging mode

`cli_build.l:1130` routes an explicit `--release` into `buildReleaseSingle`, and
`cli_build.l:1031` routes the project form into `buildReleaseProject`. Both land
in `Lyric.Release.buildRelease` (`release.l`), whose header states the intent
plainly:

> Produces a self-contained, optimized, standalone native executable from a
> compiled Lyric program — no managed runtime required on the target machine.
> Plain `lyric build` keeps emitting the fast framework-dependent DLL (the inner
> loop); `--release` is the deployable-artifact path.

So a single flag currently selects **four** independent properties at once:
optimize, strip symbols, self-contain, and AOT-compile.

The manifest carries the same conflation from the other direction:
`manifest.l:884` accepts `[build] kind = "lib" | "exe" | "bundle" | "aot"`,
mixing *what the artifact is* (lib/exe/bundle) with *how it is packaged* (aot).
`cli_build.l:1010` treats `kind = "aot"` as an implicit `--release`.

### 2.2 The profile concept already exists — bound to the wrong flag

`build_defines.l:109-129` defines a well-known `build_profile` define with the
values `debug` and `release`, surfaced to user code as
`@build_const("build_profile")` and `Std.BuildInfo.profile` (docs/60 §3.3). Its
value is currently derived *from the `--release` flag*:
`cli_build.l:1196` injects `build_profile=release` on the release path, and
`pipeline.l:112` injects the `debug` fallback otherwise.

This is the strongest single argument that the refactor is a correction rather
than an invention: **Lyric already has a profile axis**; it is simply wired to a
flag that also changes the packaging.

### 2.3 Release builds actively strip symbols

`release.l:842` passes `-Wl,--strip-debug` and `release.l:838` passes
`-Wl,--discard-all` on the Unix AOT link. Issue #4200 (closed) already noted
that `-gz=zlib` at `release.l` is defeated by the same `--strip-debug`. The
stripping behaviour is correct for a release artifact; it is listed here because
after the refactor it must key off the *profile*, not off the code path.

### 2.4 No target emits debug information

| Target | Debug info today | Evidence |
|---|---|---|
| dotnet | None. No PDB is written; the PE assembler emits no Debug Directory, so there is no CodeView/RSDS entry to point at one. | no `DebugDirectory`/`RSDS`/`codeview` match anywhere under `lyric-compiler/msil/` |
| jvm | **None.** `classfile.l` has a `makeSourceFileAttr` builder, but nothing calls it, so not even `SourceFile` reaches a class file. No `LineNumberTable`, no `LocalVariableTable`. | `makeSourceFileAttr` has zero call sites tree-wide; no line-table writer exists |
| native | None. clang is invoked with `-O<n>` and never `-g`. | `llvm_bridge.l:596` builds `clangArgs` with `-O` and no `-g` |

The `LyricSourceMap` attribute described in `docs/18-jvm-emission.md` Appendix C
("source-line ↔ bytecode-offset mapping for the Lyric debugger") is
specification-only; nothing emits it.

### 2.5 The front end has the data; the back ends discard it

`parser_ast.l` carries `span: Span` on `Statement` (`parser_ast.l:364-366`),
and on every `Expr`, `Item`, and declaration node. `Span` is a start/end
`Position` pair (`lexer.l:68`).

None of it reaches codegen. The string `span` does not occur even once in
`msil/lowering.l`, `jvm/lowering.l`, or `llvm_ir.l`. `MInsn`
(`msil/lowering.l:501`) has no source-position case.

### 2.6 The middle end destroys source fidelity

This is the finding with the largest consequence for debugger quality, and it is
independent of which debugger architecture is chosen.

- `weaver/weaver.l` opens a section titled *"Synthetic AST nodes built at a
  zero span"*, with a `synSpan()` helper used throughout. The section title was
  aspirational: `synSpan()` returned `initialPosition()`, which is line **1**,
  column 1 — not a zero span but a position that looks entirely real and points
  at the package declaration. Nothing read spans closely enough to notice until
  band B2 started emitting line tables and every woven wrapper grew spurious
  `line 1` rows (#6285). `synSpan()` now returns `noSourceSpan()` (line 0, the
  conventional "no line information" value in both JVMS §4.7.12 and DWARF), and
  backends ask `isNoSourceSpan` rather than testing a line value. That makes
  synthesized nodes *detectable*; it does not make them *attributable*, which is
  still what `SpanOrigin` (§9.3) is for.

  The names are deliberately not `syntheticSpan`/`isSyntheticSpan`:
  `Lyric.Parser` already exports a `syntheticSpan()` returning line 1, for the
  unrelated purpose of anchoring a diagnostic when the token stream is empty.
  Two public functions sharing a name with opposite meanings resolve by
  registration order with no ambiguity diagnostic in the self-hosted resolver
  (#6286), so a bundling change could have silently restored the very bug being
  fixed. Worth noting as a hazard beyond this one case: unqualified cross-package
  names in the compiler tree are resolved last-registered-wins, silently.
- `contract_elaborator/elaborator.l` propagates `e.span` when rewriting existing
  expressions (`elaborator.l:342-373`) but injects `__lyric_result_<n>`
  bindings and `assert` statements that have no natural source location.
- `Lyric.Mono` renames specialisations (`mapFoo` → `mapFoo__Int__String`), so
  even a perfect line table yields a stack frame whose *name* is not a name the
  user wrote.
- `Lyric.WireExpand` splices whole template bodies across package boundaries.

Contracts and aspects are load-bearing Lyric features. A debugger that maps
woven or contract-checked code to nowhere is not a debugger for Lyric; it is a
debugger for the subset of Lyric that uses neither. Fixing this is band B1 (§9)
and is a prerequisite for every later band.

---

## 3. The axes

The refactor's core claim is that today's `--release` is three orthogonal
questions wearing one coat.

### 3.1 Axis 1 — profile (optimization and symbols)

| Value | Optimization | Debug info | `build_profile` define |
|---|---|---|---|
| `debug` **(default)** | none / minimal | full, emitted into or beside the artifact | `debug` |
| `release` | full | stripped from the artifact; optionally written to a side symbol file (§10.2) | `release` |

### 3.2 Axis 2 — shape (packaging and deployment)

| Value | Meaning | dotnet | jvm |
|---|---|---|---|
| `portable` **(default)** | needs a runtime installed on the target machine | framework-dependent `.dll` | `.jar` |
| `standalone` | bundles a runtime; still JIT/interpreted | self-contained publish (apphost + runtime) | `jlink` image or fat JAR |
| `aot` | ahead-of-time compiled to native machine code | ILC / Native AOT (today's `--release`) | GraalVM `native-image` |

`aot` is strictly stronger than `standalone` — a Native AOT binary is
self-contained by construction. They are modelled as one ordered enum rather
than two booleans precisely so that `--aot --portable` is unrepresentable
rather than an error case to adjudicate.

### 3.3 Axis 3 — target

`--target dotnet | jvm | native`, unchanged. Target is *mostly* orthogonal to
the other two, with the exceptions tabulated in §5.

### 3.4 What this unlocks — settled

Separating the axes makes two combinations reachable that are impossible today:

- **`--release --shape portable`** — an optimized, framework-dependent library
  DLL. This is the correct artifact for `lyric publish` to NuGet, and there is
  no way to produce it at present.
- **`--debug --shape aot`** — a debuggable AOT binary. AOT-only defects
  (trimming, reflection, `ilc` behaviour) currently cannot be debugged at all.

**Settled:** profile and shape are independent axes; all six combinations are
valid and none is rejected on the grounds of the pairing alone.

---

## 4. Flag surface

### 4.1 CLI

```
lyric build [<source.l>]
            [--debug | --release]
            [--shape portable|standalone|aot]
            [--aot] [--standalone]
            [--target dotnet|jvm|native]
            ... existing flags unchanged ...
```

- `--debug` / `--release` set the profile. Mutually exclusive; passing both is
  `F0040`.
- `--shape <value>` is the canonical spelling of the shape axis. It mirrors
  `--target`'s existing enum style and gives the manifest key an obvious name.
- `--aot` and `--standalone` are sugar for `--shape aot` / `--shape standalone`.
  They are provided because they are the spellings users reach for first, and
  because Rust (`--release`) and Go (`CGO_ENABLED`/`-buildmode`) have trained
  the boolean expectation. Combining sugar with a conflicting `--shape` is
  `F0041`; combining the two sugar flags with each other is `F0041`.

`--debug` is the default and never needs to be written; it exists so that a
manifest-level `profile = "release"` can be overridden back on the command line.

### 4.2 Manifest

```toml
[build]
kind    = "lib"        # what the artifact IS   — lib | exe | bundle
shape   = "portable"   # how it is PACKAGED     — portable | standalone | aot
profile = "debug"      # optimization/symbols   — debug | release
```

`kind = "aot"` is removed. It is a hard error (`F0042`) naming
`shape = "aot"` as the replacement — see §6.

Precedence is **CLI > manifest > default**, matching docs/60's define
precedence so there is one precedence rule in the toolchain, not two.

### 4.3 Other commands

`lyric run`, `lyric test`, and `lyric bench` accept `--debug`/`--release` and
default to `debug`. `lyric test --release` is genuinely useful (optimized-build
test runs catch a different class of defect) and costs nothing to support once
`build` threads the profile.

### 4.4 Why an enum and sugar rather than pure booleans — settled

**Settled:** `--shape` is canonical; `--aot`/`--standalone` are sugar that
lowers to it. The alternative — three independent booleans — makes
`--aot --portable`, `--standalone --aot`, and `--portable --standalone`
representable states requiring diagnostics and precedence rules. The enum makes
them unrepresentable. Whether to keep the sugar at all is **Q-BP-001**.

---

## 5. Compatibility matrix

### 5.1 shape × target

|            | `--target dotnet` | `--target jvm` | `--target native` |
|---|---|---|---|
| `portable` | **default** — `.dll` | **default** — `.jar` | **error `F0043`** |
| `standalone` | self-contained publish | `jlink` image / fat JAR | **error `F0043`** |
| `aot` | ILC Native AOT | GraalVM `native-image` — **shipped** for Linux/macOS (D131; Windows still #1975) | **default and only valid shape** |

`--target native` fixes the shape at `aot`. Passing `--shape aot` explicitly is
accepted as a no-op; `portable` and `standalone` are `F0043` with a message
explaining that a native build is AOT by construction.

This replaces today's message at `cli_build.l:1124` (*"`--release` is not needed
with `--target native`"*), which becomes wrong once `--release` means "optimized
and stripped" — a perfectly meaningful request for a native build.

Note that a native binary is not *fully* static: `llvm_bridge.l:607-613` links
`-lm`, `-lpthread`, and `-ldl` dynamically. "Standalone" here means "needs no
*managed* runtime", not "no dynamic libraries". Fully-static linking
(`-static`, musl) is out of scope and tracked as **Q-BP-002**.

### 5.2 profile × target

All four combinations are valid. Profile changes optimization level and
debug-info emission only.

For `--target native` the profile also sets the clang optimization default:
`--debug` → `-O0`, `--release` → `-O2`. An explicit `--opt` continues to win
over both, and `[native] opt_level` (N6.4) continues to sit between them at
manifest precedence. **Q-BP-003** covers whether `--debug` should imply `-O0`
or `-Og`.

### 5.3 Gates that must be re-scoped, not preserved

Three current rejections key off `release` when they should key off the shape
axis. Preserving them verbatim through the refactor would be a bug.

| Gate | Today | After |
|---|---|---|
| `--define` | rejected when `release` (`cli_build.l:180-183`, `defineBuildGateError`) | rejected when `shape != portable`; `--release --shape portable --define K=V` works |
| manifest `[build.define]` | rejected when `release` or `autoAot` (`manifestDefineGateError`) | rejected when `shape != portable` |
| `--watch` | rejected when `release` (`cli_build.l:1116`) | rejected when `shape != portable` (watch is an inner-loop tool; AOT and standalone builds are too slow to watch) |
| — | — | *(as shipped: both define gates reject every non-`portable` shape, not just `aot` — `standalone` is equally a packaging path that threads no defines. Unobservable today since `standalone` is rejected earlier by `F0044`, but the predicate and its tests encode the general rule.)* |
| `--rid` | warned unless `release` (`cli_build.l:1092`, `cli_build.l:1137`) | warned unless `shape` is `standalone` or `aot` |

`defineBuildGateError` and `manifestDefineGateError` are already pure,
unit-tested predicates (#6188, `cli_build_self_test.l`). Re-scoping them is a
signature change plus test updates, not a rewrite — which is exactly why they
were factored out.

---

## 6. Compatibility: clean break

**Settled:** `--release` changes meaning in one step. There is no deprecation
window and no version in which bare `--release` still implies AOT.

Rationale: a deprecation window requires bare `--release` to keep producing an
AOT binary while warning, which means the flag means two different things
depending on the release you are on. For a pre-1.0 toolchain the silent-artifact-
change risk is smaller than the cost of shipping and then removing a compat
path. This is a deliberate acceptance of breakage, not an oversight.

Mitigations, all required in band B0:

1. **`kind = "aot"` is a hard error, not a silent behaviour change.** `F0042`
   names `shape = "aot"` explicitly. A manifest user cannot be silently
   downgraded to a portable DLL.
2. **A one-line note on every `--release` build whose shape is `portable`,**
   for one minor version: `note: --release now selects the optimization profile
   only; pass --aot for a self-contained native binary (was implied before
   <version>)`. This is a *note on a successful build*, not a deprecation
   warning on a legacy path — it costs nothing and catches the scripted case.
3. **`CHANGELOG` and `book/chapters/01-getting-started.md` migration table**
   mapping every old invocation to its new spelling.

| Old | New |
|---|---|
| `lyric build --release app.l` | `lyric build --release --aot app.l` |
| `lyric build --release` (project) | `lyric build --release --aot` |
| `[build] kind = "aot"` | `[build] shape = "aot"` (+ `profile = "release"` if desired) |
| `lyric build app.l` | unchanged — now explicitly `--debug --shape portable` |

Note that mitigation 2 is only reachable because the break is clean: under a
deprecation window the same builds would still be producing AOT binaries and the
note would be a lie.

---

## 7. Diagnostics

New codes in the `F` family. `F0040`+ is free: a sweep of quoted `"F00NN`
literals across `lyric-compiler/` finds `F0002`, `F0012`–`F0013`,
`F0015`, `F0020`–`F0027`, and `F0030`–`F0032` in use, and nothing above
`F0032`.

The family is worth looking at before extending it, because it is not one
family:

| Code | Meaning | Emitted at |
|---|---|---|
| `F0002` | conflicting `@externStatic` / `@externInstance` hints | `typechecker_stmts.l:779` |
| `F0012`–`F0013` | `@cfg` erasure: malformed predicate, undeclared feature | `cfg.l:76`, `cfg.l:94` |
| `F0015` | `@externTarget` signature mismatch (JVM variant `F0015-J`) | `msil/codegen.l:17418`, `jvm/codegen/04_calls.l:314` |
| `F0020` | **two meanings** — `?` in a non-`Result`/`Option` function, *and* FFI "not an interface" | `propagate.l:266`, `msil/codegen.l:28765` |
| `F0021` | **two meanings** — `for`-loop variable not irrefutable, *and* FFI missing impl method | `msil/codegen.l:14258`, `msil/codegen.l:28612` |
| `F0022`–`F0024` | FFI interface validation: parameter, return, and shape mismatches (docs/51) | `msil/codegen.l:28641`, `:28670`, `:28744` |
| `F0025` | try-catch-as-expression whose catch arm yields `Unit` (type-checker gap #2042) | `msil/codegen.l:15594` |
| `F0026` | non-literal argument where a delegate-bridged parameter needs a lambda literal | `msil/codegen.l:12862` |
| `F0027` | warning: hint-less `@externTarget` | `msil/codegen.l:28704` |
| `F0030`–`F0032` | build defines: non-`String` `val`, non-module-level `val`, malformed define (docs/60) | `build_defines.l:486`, `:516`, `:479` |

Two observations that bear on where the new codes should go. First, `F0020`
and `F0021` are each **already double-assigned** to unrelated diagnostics —
a pre-existing numbering collision, out of scope here but evidence that the
family is not being administered. Second, the remaining codes span FFI hints,
conditional compilation, pattern irrefutability, a type-checker gap, a lambda
ABI restriction, and build defines. Proposed new codes:

| Code | Condition |
|---|---|
| `F0040` | `--debug` and `--release` both passed |
| `F0041` | conflicting shape spellings (`--aot --standalone`, `--aot --shape portable`, …) |
| `F0042` | `[build] kind = "aot"` — removed; use `shape = "aot"` |
| `F0043` | shape incompatible with target (`--target native --shape portable`) |
| `F0044` | shape requested whose implementation does not exist — `standalone` on every target today (#6262). A *toolchain* that is merely absent (e.g. GraalVM `native-image` not installed) is not this code: `Lyric.Release` runs its own preflight and reports that itself. |

Whether build-shape diagnostics deserve their own family letter rather than
extending `F` is **Q-BP-004** — and the table above is the argument that they
might. `F` is not a family so much as a default bucket, and it already contains
two double-assigned codes. Adding a seventh unrelated concern to it is the path
of least resistance, not obviously the right call.

---

## 8. Debugger architecture

### 8.1 Settled: hybrid, staged

**Settled:** the compiler emits **both** standard host debug formats **and**
Lyric-owned side tables, from a single span-threading pass. A thin host-debugger
shim ships first. A Lyric-aware DAP *proxy* — which rewrites the host debugger's
frames and locals rather than replacing its execution control — is a defined
later stage, not a rewrite.

The reasoning that selected this over the two pure options:

- **The expensive, risky parts of a debugger are execution control** —
  breakpoint insertion, single-stepping, stack unwinding, thread suspension. A
  Lyric-native debugger reimplements all of them three times. On .NET and the
  JVM they cannot be implemented in Lyric at all: they require ICorDebug (COM,
  out-of-process) or JVMTI (a C agent via `-agentpath`). `lyric-rt/` establishes
  that C runtime code is acceptable in this repo, so it is not a hard block —
  but it is a policy expansion for a component whose value is presentational.
- **A pure host-format approach solves execution control for free but shows the
  lowered program.** Given §2.6, users would see `__aspect_target` frames,
  `mapFoo__Int__String`, `__Closure_*` environment classes (docs/53), and
  `__lyric_result_0` locals. For a language whose headline features are
  contracts and aspects, that is a poor first impression.
- **Both approaches need the same span work (§2.5, §2.6), and once spans reach
  codegen, writing a Lyric side table is the same plumbing into a second
  encoder.** The marginal cost of keeping the option open is close to zero.
- **Standard formats are needed regardless.** Crash symbolication, profilers,
  `dotnet-dump`, `llvm-dwarfdump`, and IDE interop all consume them. A
  Lyric-native debugger would not remove that requirement, so the pure-native
  option is realistically "host formats *plus* a whole debugger".

The proxy in stage S3 therefore buys most of the presentational benefit at a
fraction of the cost, and never requires a JVMTI or ICorDebug agent.

### 8.2 Stages

**S1 — host-debugger shim.** `lyric debug [<source.l>]` builds with
`--debug` and launches the program under the host debugger: `netcoredbg` for
dotnet, JDWP (`-agentlib:jdwp`) for jvm, `lldb` for native. Lyric ships a thin
DAP passthrough that fixes up source paths. `lyric-vscode/` gains a
`debuggers` contribution point. At this stage the user sees lowered names, and
that is an accepted, documented limitation.

**S2 — side tables and symbol distribution.** `LyricSourceMap`-style tables
(docs/18 Appendix C) are emitted alongside the host formats from the same pass.
Release builds write symbols to a side file rather than discarding them (§10.2),
enabling crash symbolication of stripped binaries — which is plausibly worth
more to production users than interactive stepping.

**S3 — Lyric-aware DAP proxy.** A Lyric process sits between the editor and the
host debug adapter, rewriting DAP messages using the S2 tables:

| Host debugger shows | Proxy shows |
|---|---|
| `mapFoo__Int__String` | `mapFoo[Int, String]` |
| `__aspect_target` + wrapper frame | one frame, annotated with the applied aspect |
| `__Closure_7` environment object | the captured variables, by their source names |
| `__lyric_result_0` local | hidden |
| opaque type's fields | `<opaque>`, per §10.1 policy |

The proxy is pure Lyric, target-independent, and testable against recorded DAP
transcripts without a running debuggee.

---

## 9. Bands

| Band | Content | Gates |
|---|---|---|
| **B0** ✅ | Flag surface: profile/shape axes, `--shape` + sugar, manifest keys, re-scoped gates (§5.3), `F0040`–`F0044`, migration note, docs + book. **No debug info yet.** | — |
| **B1** | Span plumbing (§2.5) and `SpanOrigin` provenance through the middle end (§2.6). Also owns source-*path* threading, which three later bands need — see §9.5. | B0 |
| **B2** | JVM debug info: `LineNumberTable` ✅, `SourceFile` (needs B1's path threading), `LocalVariableTable`. | partially B1 — see §9.2 |
| **B3** | dotnet: portable-PDB writer (`msil/pdb.l`), PE Debug Directory + RSDS in `msil/assembler.l`, `DebuggableAttribute`. | B1 |
| **B4** | native: LLVM debug-metadata subsystem in `llvm_ir.l`, `-g` to clang, profile-gated `--strip-debug`. | B1 |
| **B5** | `lyric debug` + DAP shim + VS Code contribution (S1). | any one of B2–B4 |
| **B6** | `LyricSourceMap` side tables + symbol-file distribution (S2). | B2–B4 |
| **B7** | Lyric-aware DAP proxy (S3). | B6 |

### 9.1 Why B0 ships alone

Band B0 is independently valuable and independently reviewable: it fixes the
`--define`/`--release` mis-gating (§5.3), unlocks the optimized-portable-DLL
artifact (§3.4), and removes the `kind` conflation — none of which depend on a
single line of debug-info work. It is also the only band that breaks
compatibility, so it should not be entangled with a large feature landing.

### 9.2 Why JVM debug info goes first among B2–B4

Deliberate sequencing, not alphabetical accident:

- It adds attributes to an **existing, working class-file writer** rather than
  introducing a new file format. (An earlier revision of this document said
  `classfile.l` "already emits `SourceFile`" — it defines a builder for one,
  which nothing calls. The writer is real; the attribute was not.)
- It is **independently verifiable with a standard tool** — `javap -l` prints
  the line table, so B2 has a real oracle rather than "the debugger seemed to
  work".
- **JDWP is already in every JVM.** B2 plus B5 produces a working end-to-end
  debug experience with no runtime agent written, which validates the whole
  architecture — including the S3 presentation problems — before committing to
  a portable-PDB writer (B3) or an LLVM metadata subsystem (B4).

**Why B2's line tables shipped before B1.** The band table originally gated all
of B2 on B1. That gate turned out to be wrong for the line-table half: a
statement's `stmt.span.startPos.line` is already correct where the JVM backend
lowers it, so `LineNumberTable` needed no new span plumbing at all. What B1
actually governs is *fidelity* — synthesized statements (woven, elaborated,
specialised) carry a meaningless span and so are simply omitted from the table
rather than given a wrong line, and multi-file packages inherit #6282's merged-
blob line numbers. Those are real limits, and they are limits on *which*
statements get rows, not on whether the rows that exist are right.

The `SourceFile` half does gate on B1, for a reason worth recording: the
backend has no filename to write. `Jvm.Codegen.codegenPackage` takes a
`SourceFile` AST node, and that record has no path field; the real path is read
in `cli_build.l` and dropped before `EmitRequest` is built. So the attribute is
not a missing call to `makeSourceFileAttr` — it is missing data, and the fix is
the same path-threading change #6282 needs. Until it lands, a JVM stack trace
from Lyric code still prints `(Unknown Source)` even though JDWP line
breakpoints work off the shipped tables.

B3 and B4 are each substantially larger. `msil/pdb.l` is a new binary-format
writer comparable in scope to the existing `assembler.l`/`tables.l` — see §9.4
for the surveyed detail. B4 is larger than
it looks: `llvm_ir.l` currently has **zero** metadata support (no `!dbg`, no
`metadata` occurrences at all), so DWARF requires building
`!DICompileUnit`/`!DIFile`/`!DISubprogram`/`!DILocation`, the `!llvm.dbg.cu`
named metadata, and the `Debug Info Version` module flag from scratch.

### 9.3 `SpanOrigin` (band B1)

The proposal for §2.6. Every AST node reaching codegen carries not just a span
but its provenance:

```
union SpanOrigin {
  case Direct(span: Span)
  case Synthesized(from: Span, by: PassName)
}
```

`Direct` is user-written code. `Synthesized` records the span of the construct
that *caused* the synthesis — the `requires:` clause for an elaborated assert,
the aspect declaration for a woven wrapper, the generic function for a
specialisation. Debuggers default to stepping *over* synthesized code and
attribute it to its cause, so a contract violation stops at the contract the
user wrote rather than at no position at all.

This replaces `weaver.l`'s `synSpan()` and gives the S3 proxy the information it
needs to collapse aspect frames. It is the single highest-leverage item in the
plan and the one most likely to be underestimated.

### 9.4 B3 survey: what a portable-PDB writer actually costs

A code survey ahead of scheduling B3 settled four things the band table above
could only estimate.

**The PE writer to modify is `msil/assembler.l`, not `msil/pe.l`.** There are
two PE writers in the tree; `pe.l` is a fixed-layout stage-M1 relic that emits
one hardcoded program, while `assemblePe` in `assembler.l` is the generic
writer every `lyric build --target dotnet` actually goes through. Earlier
revisions of this document named the wrong one.

The Debug Directory slot is available without disturbing the header layout:
`writePeHdrs` zeroes data directories 0–13 as a single `bufZero(w, 112)`, so
directory 6 becomes 24 zero bytes, an 8-byte entry, and 56 zero bytes — the
same 112 total, leaving `SizeOfOptionalHeader` and the directory count
untouched. The 28-byte `IMAGE_DEBUG_DIRECTORY` records themselves go in
`.text` (the only section), which extends the `textVSize`/`mdRva` arithmetic in
`assemblePe`.

**Standalone `.pdb`, not embedded.** An embedded PDB must be DEFLATE-*compressed*
into the PE. `lyric-compiler/jvm/deflate.l` is decompress-only — its entire
public surface consumes a compressed bitstream, and no compressor exists
anywhere in the repo for either target. Embedding is therefore not the cheaper
option but a strictly larger one, gated on writing an LZ77 matcher and Huffman
encoder first. B3 ships a sibling `.pdb` plus a CodeView RSDS entry; embedding
is a later follow-up if it is ever wanted.

**Heaps are reusable, tables are not.** `heaps.l`'s `#Strings`/`#Blob`/`#GUID`
writers and its compressed-uint encoder carry straight over, and the
sequence-point blob encoding reuses that same encoder. But `tables.l` is
hardcoded per table — one row record, one `addX` allocator, and one hand-written
serialization block each — with no table-id-generic path to extend, and the
metadata-root writer is fixed at exactly five streams, so admitting a `#Pdb`
stream means generalizing it. Document (0x30), MethodDebugInformation (0x31),
LocalScope (0x32), and LocalVariable (0x33) are all absent, with nothing partial
to build on. Realistic cost: **1200–1800 new lines of Lyric**, which is the
band table's "comparable to `assembler.l`/`tables.l`" claim confirmed rather
than revised.

**IL offsets are free; source lines are not.** `serializeMethodBody`'s pass 1
already computes an exact IL offset at every instruction boundary, which is
precisely the input a sequence-point table needs — and `Insn` already has a
zero-byte `Label(id)` case, the same shape B2 used on the JVM side. What is
missing is the other half: no instruction is associated with a source line,
because `Span` is dropped long before it reaches `Msil.Codegen`. B3's real
prerequisite is B1, not the binary format. Plumbing it also means
`serializeMethodBody` growing a second output channel — it returns `Unit`
today and writes only to a `ByteWriter`.

**Verification oracle.** `netcoredbg` is absent from this environment, as are
`ildasm`, `monodis`, and `dotnet-symbol`; `llvm-pdbutil` is present but reads
the MSF container format used by native PDBs, not ECMA-335 portable PDBs, so it
is not the oracle it looks like. What *is* available is
`System.Reflection.Metadata`, shipped inside the installed SDK: its
`MetadataReaderProvider.FromPortablePdbStream` is a conformant reader and can
assert that a produced PDB parses and that its method tokens resolve against
the paired DLL. The stronger end-to-end check needs no tooling at all — run the
assembly with its `.pdb` alongside and confirm the runtime's own stack-trace
formatter prints `in <file>:line N`, since the .NET runtime consumes portable
PDBs directly. That check also partially retires the `netcoredbg` risk in §12
for the symbolication case, though not for interactive debugging.

### 9.5 B1 survey: four sub-problems, only two of them large

A survey of the four items §9.3 folds into B1 found the estimates uneven, and
one of them wrong.

**Source-path threading is the item everything else waits on.** No file path
reaches any backend. `cli_build.l` reads the source by path and even passes
that path to the generator preprocessor, then drops it when building
`EmitRequest`. `Span`/`Position` (`lexer.l`) carry offset/line/column and no
file identity; `Diagnostic` has no file field either, and `diagFormat` prints
`severity[code] line:col: message` with no filename **even for single-file
builds** — the finest attribution that exists today is the package name. This
one gap is simultaneously B2's missing `SourceFile`, B3's `Document` table, and
B4's `DIFile`, which is the argument for fixing it once here rather than three
times downstream.

**#6282 (multi-file line numbers) is confirmed and structural.**
`ProjectPackage` holds `sources: List[String]` — file *contents*, no path — and
`mergePackageSources` concatenates them into one blob before parsing, so every
span in a multi-file package is relative to the merged text. The path is in
scope at every `File.readText` call in `readProjectPackageSources` and thrown
away immediately. Of the two candidate fixes, parsing each file separately and
merging `SourceFile` ASTs is preferred over building line-offset tables and
rebasing after the fact: it is correct by construction with no rebase
arithmetic, and it deletes the string-splicing helpers in `emitter.l` that
already carry scars from #4525 and #2514. It does not by itself give
per-*item* file attribution — for that, a boundary table of
`(itemStartIndex, path)` recorded at merge time is far smaller than adding a
path field to every `Item`.

**The contract-elaborator fix is small and self-contained — do it first.**
`CCRequires`/`CCEnsures` already carry a per-clause span; `collectRequires` and
`collectEnsures` bind it to `_` and discard it, and the synthesized asserts are
then anchored at `body.span` (requires) or the enclosing statement's span
(ensures). `mkAssertCall` already takes a span argument, so the whole fix is
preserving what the parser produced. One file, no schema change: all four
functions are private to `elaborator.l` with no callers anywhere else in the
tree, and no existing test pins the current (wrong) position. The pair is
carried as a small `SpannedExpr` record rather than a tuple, following
`lexer.l`'s `SpannedToken` and `llvm_ir.l`'s deliberate move away from tuples
for values threaded through many match sites.

B2's line tables make this verifiable end to end rather than by inspection: a
`requires:` on line N now produces a table row on line N, which
`assert-jvm-line-numbers.sh` asserts directly.

**The weaver's `synSpan()` sites split three ways, and none are irreducible.**
This corrects the framing in §9.3: there is no site where no real span exists.

But an earlier revision of this section made a worse error in the other
direction, and it is worth recording because acting on it would have broken
B2. It said "~24" sites "already have a usable span sitting unused in scope,
making those a direct substitution." Two things were wrong with that.

The count itself was an estimate, and low. Counted exactly, the three functions
hold **27** `synSpan()` call sites: 3 in `buildWrapper`, 15 in
`buildBModeSpecializedFunction`, 9 in `buildBModeCallSite`. (The file has 59 in
total; the other 32 are in the generic AST builders discussed below.)

More importantly, **five of the 27 are not substitutable at
all** — `weaver.l:1759`, `3676`, `3904`, `3913`, and `3915` construct
`Statement` nodes, and every `Statement` span feeds `lowerStmt`'s
`isNoSourceSpan` guard (§2.6). Giving one a real span emits a `LineNumberTable`
row for a statement the user never wrote, which is the #6285 defect again;
substituting at `1759` alone would fail `assert-jvm-line-numbers.sh`'s
`EXPECT_wovenAdd="25"`. The distinction is invisible from `weaver.l` — it only
shows up by reading the JVM backend's guard and the oracle's fixture.

So of the 27: **22 are safe**, being `Block`, `Param`, `TypeExpr`, `ModulePath`,
`LambdaParam`, and non-statement `Expr` nodes that no backend turns into a line
row. Two of them can do better than the obvious span —
`buildBModeSpecializedFunction`'s synthetic params should take
`paramTypes[pi].span` (the real original parameter type) rather than the
whole-function span, and its `finalBody` should take `rewiredBody.span`,
mirroring `buildWrapper`'s already-shipped choice for the identical field.

The five `Statement` sites need `SpanOrigin`, not a raw span: what they want to
record is "synthesized, caused by *this* aspect", which is a different claim
from "this is a real source position" and is exactly the distinction §9.3
exists to draw. The remaining sites are generic low-level AST builders with
multiple callers each; every chain reaches a real `aspect.span` or target
`FunctionDecl.span` within three frames, but threading them means a span
parameter on ~15 helpers and ~90 call-site updates — also `SpanOrigin`'s job.

Note the coverage asymmetry: `assert-jvm-line-numbers.sh` guards
`buildWrapper`'s ordinary `matches:` path, so a mistake at `1759` fails CI. The
B′-mode statement sites (`3676`, `3904`, `3913`, `3915`) have **no** automated
guard — the case for leaving them alone rests on the backend's design, not on a
test that would catch the error.

**Monomorphizer spans are fine — the brief was wrong.** `specializeFunc` sets
`span = decl.span` from the original generic declaration, and every
substitution helper threads the original per-node span through unchanged. The
"synthetic span in specialised code" problem is specific to the weaver and does not
apply here. What *is* missing is the original **name**: `FunctionDecl` has no
display-name field, the specialised decl keeps only the mangled name, and the
only two recovery paths are both unusable — `MonoResult.rewrites` is a
`Map[String, String]` that keeps just the first specialisation per generic
(and its own comment claims it keeps the last, so comment and code disagree),
and `extractBaseName` is a string heuristic with zero callers outside `mono.l`.
B1 should replace that with a non-lossy per-specialisation record carrying
`specName`, `originalName`, type arguments, and the declaration span, so a
debugger is never asked to re-derive a user-facing name from a mangling
convention.

Suggested order: elaborator fix and the 24 drop-in weaver sites first (small,
contained, independently valuable), then `SpanOrigin` designed once and applied
to both the remaining weaver builders and mono's specialisation metadata, then
the path-threading/#6282 change, which is the largest and the most independent.

### 9.6 B4 survey: what LLVM actually requires, verified

The DWARF requirements were checked empirically rather than from the LLVM
reference, by hand-writing a minimal `.ll`, compiling it with the installed
`clang` 18.1.3, and reading back the result with `llvm-dwarfdump --debug-line`
and `gdb`.

Four things are **strictly required**, and two of the failure modes are silent:

- The `"Debug Info Version"` module flag. Without it clang warns and then
  discards all debug info.
- `!llvm.dbg.cu` listing the `!DICompileUnit`. Without it, same outcome, also
  with a warning.
- `!DICompileUnit` + `!DIFile`.
- **`!DISubprogram` attached to the `define` itself via a trailing `!dbg`.**
  This is the trap: with the module flags present, the CU listed, and correct
  `!DILocation` on every instruction, removing *only* the function's own `!dbg`
  attachment produces **no warning, exit 0, and an empty `.debug_line`**.
  Per-instruction locations are silently inert unless their enclosing function
  carries a `DISPFlagDefinition` subprogram.

`"Dwarf Version"` turned out to be optional (clang picks a working default),
and `!DILocalVariable`/`llvm.dbg.declare` are only needed for variable
inspection, not for stepping.

**Spans already reach the native lowering** — contrary to the reading that
`llvm_ir.l` never mentions `span`, which is true only of the *renderer*.
`llvm_codegen.l` already reads `expr.span`/`stmt.span` at several sites and
threads a bare `line: Int` down through the lowering helpers — but only to bake
into `lyric_panic_msg` calls, after which it is dropped. `NInsn` and `NFunc`
carry no line field. So a first B4 slice can reuse data that already exists;
the recommended shape is a single `NDbgMark(line)` case inserted at the sites
that already compute a line, with the renderer forward-filling `!dbg` onto
subsequent instructions — which avoids touching `emitInsn`'s 37-case match.
(Note the panic path passes the *package name* where a file argument is
expected, a pre-existing bug the same path-threading fix from §9.5 resolves.)

**`-g` is passed nowhere.** The clang invocation in `llvm_bridge.l` has no
`-g`, and `compileToNativeWithFlags` has no profile parameter at all, so B0's
profile axis currently has no channel to reach the native compile — it only
feeds a `build_profile` compile-time define. Separately, `lyric-rt/Makefile`
compiles the runtime with `-O2 -std=c11 ... -fPIC` and **no `-g`**, so even a
fully-DWARF'd user object links against a symbol-less runtime archive: every
frame inside ARC, panic, or the collection kernels shows raw addresses. That
file is in B4's blast radius even though it is not a `.l` file.

**Native runs the full middle end**, contrary to what a direct grep of
`llvm_bridge.l` suggests: mono, weaving, and contract elaboration are reached
indirectly through `pipeMiddleEnd`. So the §2.6 provenance problem applies to
native exactly as it does to MSIL and JVM, and B4's gate on B1 is real for
woven/elaborated/generic code — but, as with B2, a first slice covering plain
straight-line statements does not have to wait for it.

Oracle: `llvm-dwarfdump --debug-line` for the cheap structural check, and
`gdb -batch -ex "info line …"` for the real one. Both are installed, along with
`objdump`, `readelf`, and `lldb`.

### 9.7 Source-path threading survey (#6284): the plan, and two traps

The single gap blocking JVM `SourceFile`, MSIL `Document`, and native `DIFile`
at once. Surveyed before implementation; the findings change the obvious
approach twice.

**Do not add a path to `SourceFile` or `parse()`.** The obvious move — put the
path on the AST root — costs 20 `SourceFile(` construction sites, which is
survivable. The blocker is one level down: `parse(source: in String)` has
**hundreds** of callers (every `*_self_test.l`, the LSP, `doc.l`), nearly all
passing inline literal source with no file on disk. Adding a mandatory path
parameter ripples through all of them for no benefit. Thread the path as a
sibling parameter through the bridge layer instead, using the codebase's own
`WithX`-suffix idiom (`compileToMsilWithVersion`,
`compileToJarBundledWithFeatures`) so existing callers never change.

**The JVM half is cheaper than it looks.** `ClassFile.attrs` is a
`List[Attribute]`, and `.add()` mutates through an `in` binding (docs/01
§766, §870). So a single loop after `lowerPackage` returns covers all 11
`ClassFile(` construction sites in `lowering.l` — records, unions, enums,
distinct/range wrappers, interfaces, closures, config blocks — with **zero**
edits inside that file. `makeSourceFileAttr` already exists and is still
uncalled.

**Bounded, not unbounded.** Construction sites needing an explicit new field:
`EmitRequest` 6, `ProjectPackage` 22, `EmitProjectRequest` 21 — **49 total**,
43 of them cross-package. Mostly one-line additions in self-tests. That is the
answer to "is this 6 edits or 200": it is 49, mechanical.

**A caution that may be stale — verify before relying on it.** `EmitRequest`
and `EmitProjectRequest` both carry a comment saying the seed miscompiles an
*omitted* defaulted field on cross-package construction, so every site must set
it explicitly. D-progress-704 (2026-07-19) fixed exactly that class of bug, and
its own text says the in-bundle cross-package walk — which is our case — was
never broken; the comment predates that fix by two days. It may still hold for
the *seed binary* until re-baked, which is not verifiable without a bootstrap
run. Set every field explicitly regardless: it is cheap, it matches the
existing convention, and it avoids re-litigating a bootstrap invariant on a
guess.

**Multi-file is a design question, not an oversight.** JVMS §4.7.10 permits at
most one `SourceFile` per class, so a package built from N files has no correct
single answer. Options: pick the first file (arbitrary, actively misleading for
members from later files); emit none (honest); or split into per-file classes
plus a facade, as Kotlin's `@JvmMultifileClass` does (a much larger codegen
change, orthogonal to this). **Recommendation: emit none for genuinely
multi-file packages**, preserving today's PENDING state rather than shipping a
plausible-looking wrong filename, and revisit when #6282's per-file parse lands.
Note that `ProjectPackage.sources.count == 1` is the *common* case, so "single
file" here means any package with one file — not just the CLI's single-file
argument mode.

**Slices, smallest first.**

1. **Filename in diagnostics.** Independent of all codegen work. `Diagnostic`
   has no file field and `diagFormat` prints `severity[code] line:col: message`
   with no filename **even for single-file builds** — the finest attribution
   available today is the package name. Reuse the existing
   `diagReportAndAbortInPkg` prefix mechanism via `Lyric.Pipeline.gate`; note
   `pipeParseAndErase` hardcodes `gate("", …)` three times, bypassing
   `pkgLabel`, and it handles the *earliest* and most common diagnostics (parse
   errors). ~15–20 sites. Acceptance: a syntax error prints the path.
2. **JVM `SourceFile`** for single-file packages, per above. Acceptance: this
   must rewrite `assert-jvm-line-numbers.sh`'s pending-guard **in the same
   commit** — it currently asserts the attribute is *absent* and fails the
   moment one appears — plus confirm `printStackTrace` stops saying
   `(Unknown Source)`.

   One refinement from tracing the JVM bridge, which the "sibling parameter"
   phrasing above understates: the path must be a **`List[String]` parallel to
   `pkgSrcs`**, not a single string, and it must be resolved **per package
   rather than per call site**.

   `compileProjectToJarBundledWithFeatures` parses every project package into
   `userFiles`, selects the entry package as `userFiles[mainIdx]`, and reaches
   codegen through two distinct `codegenPackageInto` call sites. The tempting
   reading — "one call site is the user's code, the other is stdlib" — is
   wrong, and wrong in the common case. Only the *entry* package goes through
   the first; every **sibling project package** is appended to `stdlibFiles` /
   `stdlibByPkg` (with `projectOwners` marking it, purely to keep diagnostics
   fatal rather than skippable) and reaches codegen through the *second*, the
   same one real stdlib files use. Since one-file-per-package is the common
   shape, most user code in a project build flows through the "stdlib" call
   site.

   So gating on the call site would blank `SourceFile` for sibling packages
   whose paths are already known — they come from the same `pkgSrcs` list the
   entry package's does. Key the lookup by package name instead (`stdlibByPkg`
   is already keyed that way) and emit no attribute only where no path is
   known, which today means genuine stdlib sources.

   A single scalar path is the worse failure: it would attribute every class in
   the JAR — stdlib included — to the user's file. Emitting nothing beats
   emitting a confident wrong filename, for the same reason the multi-file
   policy above lands where it does.
3. **Multi-file policy**, after #6282's per-file parse.
4. **Confirm the path reaches the MSIL and native bridge entry points**
   (`compileToMsilWithVersion`, `compileToNativeWithFlags`) so B3 and B4 do not
   re-derive this plumbing. No user-visible behaviour; verified by call-site
   inspection.

**Status (D-progress-804).** Slices 1 and 2 shipped as surveyed above:
`pipeParseAndErase` takes the `label` parameter directly (no separate
`gate("", …)` bypass to fix — the label threads straight through), and
JVM `SourceFile` is keyed by package name off a `pkgPathByName` map
built once each project package's own `package` declaration is known,
exactly the refinement this section called out over the plain
"sibling parameter" phrasing. Slice 3 (multi-file) is still open — see
§9.5's "correct by construction" recommendation, not yet attempted;
slice 4 (MSIL/native path confirmation) is satisfied for MSIL and
partially for native (`EmitRequest.path` reaches
`emitNativeInProcess`, but `compileToNativeWithFlags` itself does not
yet take it — no B3/B4 codegen consumes it either way, so the data is
available without re-plumbing when that band starts).

---

## 10. Two policy questions the design must answer

### 10.1 Opaque types versus debuggers

`docs/00-overview.md` states that an opaque type's representation is
unreachable — "not by reflection, not by serialization, **not by debugger
hooks**". A standard portable PDB plus a standard debugger cracks an opaque type
open: the fields are simply there.

This is a genuine conflict with a stated design principle and must be resolved
explicitly rather than by accident. The proposed resolution:

1. The principle constrains **the artifact you ship**. `--release` strips debug
   info, so the guarantee holds for shipped artifacts.
2. `--debug` artifacts are development artifacts. Opaque fields are visible to a
   raw host debugger, and this is documented, not hidden.
3. Under S3 the proxy renders opaque fields as `<opaque>` **by default**, with
   an explicit `lyric debug --show-opaque` opt-in for debugging an opaque type's
   own package.

This requires an amendment note in docs/00 and a decision-log entry. Adopting it
without one would leave the codebase quietly contradicting its own overview.
Tracked as **Q-BP-005**.

### 10.2 Where release symbols go

`--release` strips debug info from the artifact. It should not *discard* it:
crash symbolication of a stripped production binary is arguably the highest-value
debug-info use case. Proposal: `--release` writes symbols beside the artifact
(`app.pdb`, `app.debug`, `app.jar.map`) and the artifact retains only the build
ID needed to match them. Whether this is default-on or opt-in via
`--symbols <dir>` is **Q-BP-006**.

---

## 11. Documentation obligations

Per CLAUDE.md, a feature is not complete until docs and book reflect it. For
band B0 that means, in the same PR:

- `docs/01-language-reference.md` — the CLI section: profile/shape flags, the
  compatibility matrix, `F0040`–`F0044`.
- `book/chapters/01-getting-started.md` — toolchain table + migration table.
- `book/chapters/appendix-b-quick-reference.md` — CLI reference.
- `docs/10-bootstrap-progress.md` — tier status.
- `docs/24-build-features.md` §8 and `docs/22-distribution-and-tooling.md` —
  cross-links to this document.
- `docs/60-build-defines.md` §3.3 — `build_profile` is now sourced from the
  profile axis, not from the `--release` code path.

Band B0 shipped with all of the above landed in the same PR (D132).

Band B2's line-table slice carries a lighter obligation, because it changes no
user-facing surface: no new flag, no new diagnostic, no changed CLI output. The
only externally visible effect is that JVM class files now contain a
`LineNumberTable`, which is a prerequisite for a debugger rather than a feature
a reader can use yet — stack traces still print `(Unknown Source)` until B1
threads the source path (§9.2). It is recorded in `docs/10-bootstrap-progress.md`
and the decision log's progress entries; the language reference and book get
their update when the user-visible behaviour arrives with `SourceFile`.

---

## 12. Risk register

| Risk | Severity | Note |
|---|---|---|
| `netcoredbg` may not handle a portable PDB from a non-Roslyn compiler | **high** | **[unverified]** — the central technical assumption of B3+B5 on dotnet. A spike must confirm this before B3 is scheduled, and `netcoredbg` is not installed in the current dev environment, so the spike needs it fetched first. §9.4 names a weaker check that *is* available (`System.Reflection.Metadata` + runtime stack traces); it covers symbolication, not interactive debugging, so it narrows this risk without closing it. |
| An embedded PDB is unreachable without a DEFLATE compressor | low | Settled in §9.4: B3 ships a standalone `.pdb`. Recorded because "just embed it" reads as the simpler option and is not. |
| No source path reaches any backend | **high** | §9.5. Blocks JVM `SourceFile`, MSIL `Document`, and native `DIFile` simultaneously, and is the same change #6282 needs. Fixing it once in B1 is the whole argument for B1's scope. |
| `lyric_rt.a` is built without `-g` | medium | §9.6. B4 can give user code perfect DWARF and still show raw addresses for every ARC/panic/collection frame. The fix is in `lyric-rt/Makefile`, outside the `.l` tree, so it is easy to miss when scoping B4. |
| A `!DILocation` without a `!DISubprogram` on its function fails silently | medium | §9.6. Verified: no warning, exit 0, empty `.debug_line`. A B4 implementation can look correct and emit nothing, so the `llvm-dwarfdump` assertion must be wired into CI from the first commit, not added later. |
| B1 (`SpanOrigin`) is larger than estimated | high | Touches weaver, elaborator, mono, wire-expand, and three backend IRs. Every later band depends on it. |
| GraalVM `native-image` shape is host-dependent (shipped Linux/macOS in D131; Windows #1975) | medium | `--shape aot --target jvm` must fail loud when the toolchain is missing or the host is unsupported, never silently emit a JAR. That is **not** `F0044`, which only covers a shape whose implementation does not exist at all (`standalone`): a merely-absent driver is reported by `Lyric.Release.jvmReleasePreflightError`, which already implements this check. |
| MSIL/JVM divergence | medium | docs/59 documents one-sided fixes between the backends. Debug info doubles the surface where they can drift. |
| Clean break surprises scripted users | medium | Accepted per §6; mitigated by `F0042` and the build note. |
| Optimization at `--release` is currently a no-op for dotnet/jvm | low | Lyric has no IL/bytecode optimizer; `--release` on those targets means "strip symbols" only, and the docs must say so rather than implying optimization that does not happen. |

---

## 13. Open questions

- **Q-BP-001:** Keep the `--aot`/`--standalone` sugar, or require `--shape`
  only? Sugar is friendlier; enum-only is one spelling per concept (D051
  precedent).
- **Q-BP-002:** Fully-static native linking (`-static`, musl) — a fourth shape,
  a `[native]` key, or out of scope?
- **Q-BP-003:** Should `--debug --target native` use `-O0` or `-Og`?
- **Q-BP-004:** Do build-shape diagnostics warrant their own family letter
  rather than extending `F`?
- **Q-BP-005:** Ratify the §10.1 opaque-type resolution and amend docs/00.
- **Q-BP-006:** Are release symbol side-files default-on or opt-in?
- **Q-BP-007:** Does `lyric publish` default to `--release --shape portable`
  once that combination exists?
- **Q-BP-008:** Should `[profile.dev]` / `[profile.release]` manifest tables
  (Cargo-style, allowing per-profile `opt_level`) supersede the flat
  `[build] profile` key?
- **Q-BP-009:** Does the `debug` profile disable the contract-elision modes, or
  are `[contracts]` flags fully independent of profile?
- **Q-BP-010:** Should `LyricSourceMap` be a single cross-target format, or
  three target-idiomatic encodings behind one reader interface?
- **Q-BP-011:** Does `lyric debug` need a `--attach <pid>` mode in S1, or is
  launch-only acceptable for the first release?

---

## 14. References

- `docs/00-overview.md` — the opaque-type principle in tension with §10.1.
- `docs/18-jvm-emission.md` Appendix C — `LyricSourceMap`, specified but unemitted.
- `docs/22-distribution-and-tooling.md` — artifact distribution; consumes §10.2.
- `docs/24-build-features.md` — `@cfg` erasure; sibling of the profile axis.
- `docs/53-epic-1877-implementation-plan.md` — `__Closure_*` synthesis, an S3 rewrite case.
- `docs/59-compiler-stdlib-deep-review.md` — MSIL/JVM divergence risk.
- `docs/60-build-defines.md` §3.3 — the existing `build_profile` define.
- Issues: #1975 (GraalVM `native-image`), #4200 (`-gz=zlib` vs `--strip-debug`),
  #6188 (`defineBuildGateError` unit tests).
