# 36 — v1.0 Roadmap

This document is the actionable pre-release checklist.  Every item either
blocks the `v1.0` tag or is a tracked production-quality gap deferred to
a specific 1.x milestone with an open issue.  Per `CLAUDE.md`,
"bootstrap-grade shortcut that ships" is not an acceptable resting
state for a v1.0 deliverable — items below either ship at production
quality before v1.0, or are explicitly deferred to a tracked 1.x
milestone with a linked issue.

Per `docs/05-implementation-plan.md`, v1.0 = end of Phase 3.  The exit
criteria are:

- A team can build, test, and deploy a real production service in Lyric.
- Tooling is good enough that newcomers can be productive within a week.
- Documentation is comprehensive: language reference, tutorial, stdlib reference.
- Compile times and runtime performance are competitive with C#.
- Public release.

Phase 4 (proof), Phase 5 (self-hosting), and Phase 6 (JVM/VS Code/ecosystem)
are post-v1.0 or parallel tracks; many of their milestones have already shipped
as Phase 6 early work and are listed in §4 below.

> **⚠ Critical-path correction (2026-06-03).** §R1–R6 below are all DONE, but
> they are **not sufficient for a v1.0 tag.** Since the self-hosted compiler
> became the default and only `--target dotnet` path (the F# `--internal-build`
> subprocess was retired, D-progress-317), the v1.0 exit criterion "a team can
> build, test, and deploy a real production service in Lyric" is gated on the
> self-hosted compiler being **sound and correct**, which it is not yet. The
> 2026-06-03 re-verification in `docs/41-self-hosted-compiler-gap-analysis.md`
> §10 shows the front end is still advisory (does not reject invalid programs)
> and `?` / `await` / `defer` / `==` still **silently miscompile**. These are
> now tracked as **§R7** below and are the true remaining v1.0 blockers.

---

## §1  Gate decisions — answer these before sequencing work

The five questions below determine which items in §2 are blocking and which
are 1.x.  Record the answers as decision-log entries.

| # | Question | Stakes |
|---|---|---|
| G1 | Is `--target jvm` a v1.0 supported channel, or is it Phase-6 ecosystem work with its own versioning? | If yes, Q-J012 and Q-J013 (§2-R3) are release-blocking. If no, document JVM as "supported but not v1.0 SemVer-guaranteed" in the language reference §0.1. |
| G2 | Which `@experimental` items graduate to `@stable(since="1.0")` and which stay experimental? | Triggers R1.  Until this list exists, SemVer is unenforceable and any user relying on an `@experimental` item has no compatibility guarantees. |
| G3 | Does `--legacy` / `LYRIC_FMT_LEGACY=1` survive as a supported flag past 1.0, or does it sunset with `Fmt.fs`? | **Resolved (D066):** Flag survives as deprecated through v1.0; removed in v1.1.  Per-expression CST gap deferred to 1.1. |
| G4 | Do the `lyric-*` service libraries (`lyric-web`, `lyric-cache`, `lyric-db`, `lyric-health`, `lyric-logging`, `lyric-otel`, `lyric-lambda`, `lyric-aws-secrets`, `lyric-aws-xray`) ship under v1.0 SemVer, or under their own independent versioning? | **Resolved (D066):** Independent versioning per library; each declares its own stability policy in `lyric.toml`. |
| G5 | Must the three-stage reproducibility bootstrap (`scripts/bootstrap.sh`: F# stage 0 → self-hosted stage 1 → self-hosted² binary comparison) produce a passing diff before v1.0? | **Resolved (D066):** Not required for v1.0.  Stage 0 (F# bootstrap) compiles the self-hosted compiler from `.l` sources; user-facing CLI flows through the AOT entry point that loads the Lyric-emitted `Lyric.Cli.Program.main` (Track A A1.4, #860).  Stage-2 binary-identity reproducibility is a Phase-7 (2.0) gate. |

---

## §2  Critical-path milestones

### R1 — Declare the v1.0 stdlib API surface  *(Q011)*

**Status:** Done (D-progress-252).  `stdlib/STABILITY.md` lists every module.
`Std.Core` and `Std.Testing.Mocking` were missing `pub`/`@stable` annotations;
both are now annotated `@stable(since="1.0")`.  All other modules were already
annotated.

**What to do:**

1. Walk every `pub` item in `lyric-stdlib/std/*.l` and `lyric-stdlib/std/_kernel/*.l`.
   For each item decide stable or experimental.  The current `@experimental`
   markers from D040 are a starting point; they are not comprehensive.
2. Produce a `stdlib/STABILITY.md` table (or equivalent decision-log entry)
   listing every module and its stability tier at 1.0.
3. Commit the final `@stable(since="1.0")` / `@experimental` annotations.
   After this commit, `lyric public-api-diff` will enforce the boundary on
   all future PRs.

**Known items currently `@experimental` (per D040 + analyst audit):**

- `Std.Testing.Property` — entire module (generators, shrinking deferred)
- `Std.Testing.Snapshot` — entire module (diff/normalise deferred)
- `Std.Core.Proof` — entire module (structural-induction support deferred)
- `Std.Http` retry / cancel / timeout helpers — specific overloads TBD
- `Std.Time` DTO helpers — specific helpers TBD
- `Std.Jvm.catch` — declared experimental; emitter not yet wired (Q-J012)

**Acceptance criteria:** `lyric public-api-diff` run against an empty prior
baseline prints a clean "no breaking changes" for the `@stable` surface and
lists every `@experimental` item as out-of-scope.

---

### R2 — Formatter: per-expression CST granularity + legacy sunset

**Status:** Deprecation notices shipped (D-progress-253).  `--legacy` is now
documented as deprecated in §13.7 of the language reference and in
`appendix-b-quick-reference.md`.  Per-expression CST granularity is deferred to
v1.1 per G3 (D066).  `Fmt.fs` and the `--legacy` flag remain in the codebase
through the 1.0 release and will be removed in v1.1.

**What to do:**

1. **Per-expression CST granularity** in `lyric-compiler/lyric/fmt/fmt.l` and
   `lyric-compiler/lyric/fmt/fmt_core.l`: extend the `FmtCtx` cursor so that
   leading trivia on tokens inside `EBinop`, `ECall`, `EIndex`, `EPrefix`,
   `EField`, and `EAs` nodes is reproduced at the token boundary rather than
   hoisted to the enclosing statement.  The CST infrastructure already carries
   `leadingTrivia` on every `SpannedToken`; this is a traversal-depth issue
   in the formatter, not a CST gap.
2. Once the gap closes, **sunset `Fmt.fs`** in `bootstrap/src/Lyric.Cli/`:
   - Remove the `--legacy` flag from `Program.fs`.
   - Remove `LYRIC_FMT_LEGACY` environment-variable check from `SelfHostedFmt.fs`.
   - Delete `bootstrap/src/Lyric.Cli/Fmt.fs`.
   - Update `docs/01-language-reference.md` §11 (tooling table) to remove the
     `--legacy` flag.
   - Update `book/chapters/appendix-b-quick-reference.md` similarly.
3. If G3 resolves to "legacy flag survives one release", defer step 2 to 1.1
   and ship only step 1 before the tag.

**Dependency:** Resolving G3 determines the gate.

**Workaround (until closed):** `LYRIC_FMT_LEGACY=1 lyric fmt` or
`lyric fmt --legacy` to use the AST formatter.  Caution: `--legacy` drops all
non-doc `//` comments.  If `//` comments are present in expression sub-trees,
run without `--legacy` and accept that comments anchor at the statement level.

---

### R3 — JVM channel: Q-J012 + Q-J013 call-site wrappers

**Status:** Both shipped (D-progress-249, D-progress-254).  Q-J012 (`Std.Jvm.catch`
intrinsic) was implemented in a prior milestone.  Q-J013 (`@externTarget` call-site
try-catch wrapper for `Result[T, JvmException]` returns) shipped in D-progress-254:
`lowerExternTargetBody` in `codegen.l` emits `invokestatic`/`invokevirtual` plus an
inline try-catch when the return type is `Result[T, JvmException]`.  Validated by
stage B128.

**Q-J013 — try-catch wrapper for checked-exception `@externTarget` calls**

The gap: `MavenShim.fs` correctly declares `Result[T, JvmException]` as the
return type for Maven methods with checked exceptions, but
`lyric-compiler/jvm/lowering.l` never wraps the call site in a JVM
`try-catch` block.  Without the wrapper, the JVM verifier rejects the
classfile or the exception propagates unhandled.

What to do in `lyric-compiler/jvm/lowering.l`:

- In the `ECall` lowering path, detect when the callee's resolved method
  descriptor has a non-empty `throws` list (obtained from the Maven JAR's
  constant pool via the `MavenResolver` type info surface).
- Emit: `try { <call> } catch (Throwable e) { <construct JvmException(e)>; <wrap in Err> }`.
- The catch block must call the Lyric-side `JvmException` constructor (in
  `lyric-compiler/jvm/_kernel/kernel.l`) and wrap the result in the `Err`
  variant of the declared `Result` type.
- Add tests to `bootstrap/tests/Lyric.Emitter.Tests/` exercising a Maven
  method with a declared checked exception (e.g. `java.io.IOException`).

**Q-J012 — `Std.Jvm.catch[T]` emitter recognition**

`Std.Jvm.catch[T]` is declared `@experimental` in `lyric-stdlib/std/jvm.l` but the
JVM emitter does not yet recognise the call as an intrinsic.  The intrinsic
must lower to a JVM `try-catch` block wrapping the lambda body.

What to do in `lyric-compiler/jvm/lowering.l`:

- Add `Std.Jvm.catch` to the known-intrinsic table (alongside the existing
  `Std.Jvm.*` intrinsics).
- Lower to: invoke the lambda argument inline inside a `try` block; on
  `Throwable`, construct `JvmException` and return `Err(e)`.

**If G1 resolves to "JVM is Phase-6":**  Add a note to
`docs/01-language-reference.md` §0.1 (or §"Platform support matrix") stating:
"`--target jvm` is supported and tested but carries no v1.0 SemVer guarantee;
breaking changes may land in minor releases until JVM support is declared
stable in a future release."

**Workaround (until closed):** Avoid Maven methods with declared checked
exceptions in `--target jvm` builds.  Wrap the call from Java glue code
and expose a non-throwing wrapper as a `@externTarget`.

---

### R4 — M5.3 stage 6: last F# domain-logic items

**Status:** COMPLETE (D-progress-255). `Lyric.Doc`, `Lyric.Lint`, and
`Lyric.Pack` csproj XML generation are now self-hosted in Lyric.
`ContractMeta` and `Fmt.fs` sunset remain deferred (see notes below).

| Item | F# location | Target Lyric location |
|---|---|---|
| `Lyric.Lint` | `bootstrap/src/Lyric.Cli/Lint.fs` | `lyric-compiler/lyric/lint/lint.l` |
| `Lyric.Doc` | `bootstrap/src/Lyric.Cli/Doc.fs` | `lyric-compiler/lyric/doc/doc.l` |
| `Lyric.ContractMeta` | embedded resource reader in `bootstrap/src/Lyric.Cli/` (multiple sites) | `lyric-compiler/lyric/contract_meta/contract_meta.l` |
| `Pack.l` | `bootstrap/src/Lyric.Cli/Pack.fs` | `lyric-compiler/lyric/pack/pack.l` |
| F# `Fmt.fs` sunset | `bootstrap/src/Lyric.Cli/Fmt.fs` | gated on R2 |

**Sequencing:** `Lyric.Doc` depends on nothing external; do it first.
`Lyric.Lint` is five AST-only rules (L001–L005); do it second.
`Lyric.ContractMeta` (cross-package contract resource reader) is a dependency
of `Pack.l`; port in order.

**`--target dotnet-legacy` removal — contract-elaborator parity reached:**
`Emitter.fs::emitContractCheck` handles nested-return `ensures:` clauses, loop
`invariant:` lowering, and protected-type entries for the F# (`--target
dotnet-legacy`) path.  The self-hosted `contract_elaborator/elaborator.l`
(M5.2 stage 2) now covers every one of those:
  * `requires:` and `ensures:` (including nested returns at any depth inside
    `if` / `match` / `try` / `for` / `while` / `loop` bodies — see the file
    header at `elaborator.l:25-34`),
  * loop `invariant:` lowering (D-progress-277, docs/41 Band 4), and
  * **protected-type entries** — `elaborateProtectedMember`
    (`elaborator.l:1035-1073`) elaborates each `PMEntry` against its own
    `contracts` list plus the surrounding `PMInvariant` clauses lifted to
    `CCEnsures`, covered by `testProtectedEntryRequiresLowered` and
    `testProtectedInvariantAppendedToEntries`.
`when:` barrier clauses survive in `ed.contracts` for the verifier but are
not lowered to runtime asserts — they become `Monitor.Wait` conditions in
the backend, matching the F# emitter's shape.  Band 4 is now complete on
both axes; removing `--target dotnet-legacy` is no longer gated by a
contract-elaborator deferral.

**Additional structural blocker (added by `docs/41-self-hosted-compiler-gap-analysis.md`):**
`Msil.Bridge.compileToMsil` and `Jvm.Bridge.compileToJar` historically went
`parse → codegen → lowering` directly and skipped the self-hosted
middle-end entirely.  D-progress-276 wired `Lyric.ModeChecker` (fatal),
`Lyric.ContractElaborator` (lowering), and `Lyric.TypeChecker` (advisory,
pending Band 6 cross-package resolution) into both bridges.  `Lyric.Mono`
wiring is still deferred (the F# bootstrap parser cannot compile mono.l;
see docs/41 Band 1 status block).  Production builds under `--target
dotnet` now enforce V0001–V0011 and run `requires:` / `ensures:` /
`invariant:` runtime asserts; cross-package type resolution and same-package
monomorphisation remain on the Band 6 / Band 5 follow-up list.

**Bridge pattern** (follow `SelfHostedFmt.fs` / `SelfHostedManifest.fs`):

For each item:
1. Implement the Lyric package under `lyric-compiler/lyric/<item>/`.
2. Write a `<item>_bridge.l` protocol file (string-in / JSON-out or string-in /
   string-out as appropriate).
3. Write a thin `bootstrap/src/Lyric.Cli/SelfHosted<Item>.fs` shim that
   compiles the Lyric driver on first call, loads the DLL by reflection, and
   calls the bridge entry point.
4. Wire the shim into the relevant command in `Program.fs`.
5. Remove the F# `<Item>.fs` source file.

**Acceptance criteria:** `dotnet build Bootstrap.sln` succeeds after each F#
file deletion; all `bootstrap/tests/Lyric.Cli.Tests/` and
`bootstrap/tests/Lyric.Emitter.Tests/` tests pass; `StdlibLyricTests.fs`
exercises each new self-test file.

---

### R5 — Language gaps: Q022 and Q021 cross-package

**Status:** COMPLETE (D-progress-256). Q022-2 deferred post-v1.0.

These are not complete breakages but will surface as user-visible footguns
within the first week of adoption.

**Q022 sub-questions 1–4**

| Sub-question | Gap | Impact |
|---|---|---|
| Q022-1 | `pub use Foo.bar` at the symbol level: parser accepts it, typechecker implements package-level re-export only | Users who write `pub use Pkg.specificFunc` get the whole-package surface exposed, not the named symbol. |
| Q022-2 | Opaque-type emit + reflection: opaque types over generic parameters don't produce the right CLR generic type arguments in the embedded `Lyric.Contract` resource | Cross-package generic opaque types are invisible to the contract reader. |
| Q022-3 | UFCS dispatch on opaque-with-generic-param: `myOpaque.method()` fails silently when `myOpaque` is `OpaqueType[T]` | Users see a T0050 "method not found" error with no guidance. |
| Q022-4 | Generic `@externTarget` on BCL generic methods: `@externTarget("System.Collections.Generic.List`1::Add")` with a Lyric generic type parameter doesn't resolve correctly | Requires explicit monomorphised `@externTarget` per type. |

**What to do for Q022-1:** In `bootstrap/src/Lyric.TypeChecker/Resolver.fs`
(or the Lyric `typechecker_resolver.l` equivalent), implement symbol-level
`pub use`: when `pub use Pkg.name` is present, add only the resolved `name`
symbol to the exporting package's public table, not the whole `Pkg` surface.

**What to do for Q022-3:** In `bootstrap/src/Lyric.TypeChecker/` (pass A.4
receiver resolution), when the receiver type is a closed opaque generic
(`OpaqueInfo` with non-empty `TypeArgs`), substitute the type arguments into
the method signature before attempting dispatch.

For Q022-2 and Q022-4: these are lower priority.  If they do not close before
1.0, add explicit diagnostic guidance to T0050 (UFCS failure on generic
opaque) and document the `@externTarget` monomorphisation requirement in
`docs/01-language-reference.md` §4 (FFI).

**Fix target for Q022-2 and Q022-4:** v1.1.  Budget two milestones (one engineer-quarter each) for: (a) opaque-type CLR generic type argument emission in the `Lyric.Contract` resource writer, and (b) `@externTarget` resolution for Lyric-generic BCL methods.  FFI phase-3 escape-hatch tickets will be pre-filed before the v1.0 branch cut.

**Q021 #4 — cross-package distinct types + imported interfaces in contract metadata**

The gap: `satisfiesMarker` works for same-package type arguments but does not
look up cross-package `derives` lists or imported interface impls.  This means
`f[T] where T: Hash` fails when `T` is a distinct type from another package
even if it `derives Hash`.

What to do: in `bootstrap/src/Lyric.Emitter/Codegen.fs::satisfiesMarker`,
extend Path 1 (distinct-type derives) to load the `DistinctTypeInfo` from the
caller's `RestoredPackages` map (the embedded `Lyric.Contract` resource),
not only from `ctx.DistinctTypes` (in-compilation).

---

### R6 — Distribution and signing

**Status:** COMPLETE (D-progress-257).

Primary channel `dotnet tool install lyric` ships (D059 / D-progress-228).
Gaps below are now closed.

| Item | File / location | What to do |
|---|---|---|
| Standalone ZIP/tarball | `.github/workflows/` | Wire a GitHub Actions workflow that publishes a `lyric-<version>-<rid>.zip` (win-x64, linux-x64, osx-arm64) to each GitHub Release.  Follow the `dotnet publish -r <rid> --self-contained` pattern already in `scripts/bootstrap.sh`. |
| NuGet package signing | `.github/workflows/publish.yml` (or equivalent) | Add `dotnet nuget sign` step using a code-signing certificate stored as a repository secret.  Document the certificate fingerprint in `docs/34-distribution-strategy.md`. |
| Authenticode (Windows) | Same workflow | Sign the Windows executable with `signtool` after `dotnet publish`. |
| macOS notarisation | Same workflow | Run `xcrun notarytool submit` after `dotnet publish` for the `osx-arm64` artifact. |
| `curl \| sh` installer | `scripts/install.sh` | Thin script: detect platform, download the appropriate ZIP from the GitHub Release, extract to `~/.lyric/bin`, add to `$PATH`.  Mirrors `rustup-init.sh` in structure. |

**Q-dist-001 (self-hosted AOT binary):** Gated on the three-stage bootstrap
(`scripts/bootstrap.sh`) producing a bit-identical binary from the self-hosted
pipeline.  Depends on G5.  This is a Phase-7 deliverable and does NOT block
1.0 — `dotnet tool install lyric` is the primary channel.

---

### R7 — Self-hosted `--target dotnet` soundness & correctness floor  *(NEW; the real v1.0 blocker)*

**Status:** OPEN.  This is the gating milestone the original §R1–R6 list missed.
Authoritative tracking and per-gap evidence live in
`docs/41-self-hosted-compiler-gap-analysis.md` §10 (re-verified 2026-06-03).
Because the self-hosted compiler is now the default and only non-JVM path, every
gap below ships to users at the v1.0 tag unless closed.

The work splits into the five bands from `docs/41` §6, ordered by the production
bar (soundness/correctness before feature completion, because they stop *silent
wrongness*):

| Band | Severity | Blocks v1.0? | Summary |
|---|---|---|---|
| **R7.1 Front-end soundness** | CRITICAL | **Yes** | Type checker is an advisory inference pass, not a gatekeeper: `TyError` matches anything, no match-exhaustiveness, no visibility/opaque/impl-conformance enforcement, no §5.2 parameter-mode pass. Single-file path is advisory (`bridge.l`), project path is fatal — same source diverges. Gaps C1, C2, C10, C11, H14, H15, H16, M6 + front-end half of C13. |
| **R7.2 Backend correctness** | CRITICAL | **Yes** | `?`/`try?` are no-ops (C3); `defer` runs inline not at scope exit (C7); `==` doesn't dispatch the derived `equals` (H1); capturing closures unimplemented (H20); compound-assign ignores the operator — string `+=` silently emits numeric add (H22); `SItem`/`SInvariant` dropped (M7). H17 (`break`/`continue` out of `try`) needs a targeted test. **The honest interim for any not-yet-lowered node is a hard diagnostic, never a silent pass-through.** |
| **R7.3 Async** | CRITICAL | **Yes** | No `IAsyncStateMachine` / lazy `IAsyncEnumerable` in `lyric-compiler/msil/`. `await`/`spawn`/`async func` lower synchronously and silently miscompile (C4, C5). Largest single port (~110 KB of F# `AsyncStateMachine.fs`/`AsyncGenerator.fs` to port). Until ported, these must **panic with a tracked-issue message**, not miscompile. |
| **R7.4 Feature completion** | HIGH | Per-feature | User generic *types* type-erased (C8); `@projectable` twins (H2); range-subtype validation (H3); custom `@generate` never invoked (H10); `old()`/quantifiers panic (H11); `config{}` no-op (M3); `@derive(Ord)`/union-enum derives (M4); cross-package generic-fn mono for user code (H6); wire `bind`/`scoped`/`provided` (H4); call-site named/default args (H5). |
| **R7.5 F# elimination + AOT** | HIGH | **Yes** (AOT goal) | Two-plus F# DLLs still load-bearing: `Lyric.Emitter.dll` via `http_host.l` (`HttpClientHost`, blocked on package class-`val` `.cctor` codegen) and `process_capture_host.l` (needs async, R7.3); plus newly-found `StubCounterHost` (broken `@stubbable`, L5) and `Lyric.Session.Host.dll` (L6). No `<PublishAot>` is configured anywhere (H13) — the "AOT-compilable" exit criterion is unrealised and untested. |

**Acceptance gate (from `docs/41` §6 Band 6):** every program in
`docs/02-worked-examples.md` builds and runs under `--target dotnet`; the parity
suite has one program per §§2–14 feature class; `lyric prove` /
`public-api-diff` / `test` / `doc` on every stdlib module match a baseline; both
F# DLLs are off the .NET runtime closure; and `<PublishAot>` produces a working
native binary in a CI smoke test.

**Sequencing:** R7.1 and R7.2 are the soundness/correctness floor and precede
feature work.  R7.3 (async) can run in parallel.  R7.5 (AOT) is gated on R7.3
(ProcessCapture) and the `HttpClientHost` `.cctor` fix.  Where a correct lowering
is genuinely out of scope for the v1.0 branch, replace the silent pass-through
with a hard diagnostic and file a dated 1.x issue — do **not** ship the silent
miscompile.

---

## §3  Bootstrap-grade gaps with workarounds

These items work but have known fidelity gaps relative to what the language
reference promises.  Each ships with a documented workaround.  The fix target
column is the first release the gap is expected to close.

---

### G-01  `@stubbable` — recording / argument-matching DSL missing

**Current behavior:** `@stubbable` synthesises a stub builder that supports
single-arity constant return values and call count assertions only
(D-progress-016).

**Impact:** Cannot express "return different values for different arguments"
or "assert the argument value was X" without calling the SUT multiple times.

**Workaround:** Implement argument-capturing manually:
```
record MyServiceStub {
    val receivedArg: String  // capture last call arg
    val returnValue: String
}
func stubCall(s: inout MyServiceStub, arg: in String): String {
    s.receivedArg = arg
    return s.returnValue
}
```
For multi-call scenarios, use a `slice[String]` to accumulate arguments.

**Fix target:** 1.1.  Port the DSL from the design in D-progress-016 to
`lyric-compiler/lyric/stubbuilder/stub_derive.l`.

---

### G-02  `@generate(Json)` `fromJson` re-parses the document on every field access

**Current behavior:** The synthesised `fromJson` deserialiser re-parses the
full JSON document on each call to access a single field (D-progress-046
explicit note).

**Impact:** Deserialising a large JSON payload with N fields costs O(N)
re-parses.  Negligible for small records; can be material for deeply nested
structures or hot paths.

**Workaround:** For performance-sensitive paths, parse to a `Std.Json.Value`
once and project fields manually:
```
let raw: Json.Value = Json.parse(input)?
let name: String = raw.getStr("name")?
let age: Int = raw.getInt("age")?
```
Or batch the deserialization outside a hot loop.

**Fix target:** 1.1.  Rewrite `fromJson` synthesis in the emitter to parse
into a `Json.Object` once and look up each field by key.

---

### G-03  `lyric doc` — single-file only; cross-file roll-ups missing

**Current behavior:** `lyric doc <source.l>` emits a single Markdown file
covering the named source's `pub` surface (D-progress-023).  Cross-file
roll-ups, inter-item anchor links, and doctest extraction do not exist.

**Impact:** Multi-file packages produce N disconnected Markdown files with no
index or hyperlinks between them.

**Workaround:** Run `lyric doc` per file; concatenate output files manually
or use a Markdown site generator (mkdocs, mdBook) that handles nav from a
YAML/TOML config.

**Fix target:** R4 (port `Lyric.Doc` to Lyric) delivers single-file parity.
Cross-file roll-ups and anchor links are 1.2.

---

### G-04  `lyric test` — `property` declarations emit `# skip`; `fixture` is T0901

**Current behavior:** In a `@test_module`, a `property` declaration is parsed
and recognised, but `TestSynth.fs` emits `# skip (property not yet supported)`
in TAP output.  A `fixture` declaration produces a T0901 diagnostic ("not
supported").

**Impact:** Property tests and fixture-based setup/teardown require manual
workarounds.

**Workaround for property tests:** Use the `Std.Testing.Property` helpers
directly inside an `@test` function:
```
@test
func propEncodeDecodeRoundTrip(): Bool {
    forAllIntRange(0, 1000, rng, (n) => {
        let encoded = encode(n)
        decode(encoded) == n
    })
}
```
`forAllIntRange`, `forAllBool`, `forAllDouble`, and `forAllIntPair` are in
`Std.Testing.Property` (marked `@experimental`).

**Workaround for fixtures:** Extract setup/teardown into plain helper functions
and call them explicitly at the top and bottom of each `@test`:
```
@test
func myTest(): Bool {
    let ctx = setupMyFixture()
    let result = runTest(ctx)
    teardownMyFixture(ctx)
    result
}
```

**Fix target:** 1.1.  `property` execution gates on shrinking support in
`Std.Testing.Property`.  `fixture` support follows.

---

### G-05  Protected type barriers — finite 1 s timeout instead of Ada infinite-wait

**Current behavior:** A protected-type barrier call uses a 1 s
`Monitor.Wait(timeout: 1000)` instead of infinite-wait Ada semantics.  A
single-threaded misuse (caller and callee on the same thread) raises an
exception after 1 s rather than deadlocking.

**Impact:** Ada conformance only.  In practice, single-threaded misuse is a
programming error that should be caught at compile time.  The 1 s timeout
surfaces it as a runtime exception instead of a silent hang.  For correct
multi-threaded code the semantics are identical.

**Workaround:** Design protected types so entries are only called from threads
other than the one that holds the object.  The existing mode-checker rules
(V0003) enforce thread-boundary correctness statically; a T0900 diagnostic
fires on any static violation the mode checker can detect.

**Fix target:** 1.x when Ada infinite-wait semantics are decided under Q008.

---

### G-06  Aspect weaver — four constructs parsed but inert

**Current behavior:** The aspect weaver (D-progress-206a..209) ships
wrapper synthesis, `@no_aspect`, contract augmentation, and multi-aspect
`wraps:`/`inside:` ordering.  Four constructs parse but the weaver ignores
them:

| Construct | Spec reference | Weaverstate |
|---|---|---|
| `call.shortName` / `call.elapsed` ambient bindings | `docs/01-language-reference.md` §14 | Parsed; weaver does not inject ambient values |
| `config { }` blocks inside `aspect` bodies | `docs/25-config-blocks.md` §7 | Parsed; aspect config DI not wired |
| `except name in { ... }` exclusion clause | `docs/01-language-reference.md` §14.2 | Parsed; exclusion set not consulted during weaving |
| `pub aspect Foo(...)` template form | `docs/27-aspect-libraries.md` §3 | Parsed; template instantiation inert |

**Workarounds:**

- `call.shortName`: pass the function name as an explicit aspect argument:
  `use Trace with (name: "MyFunc.doThing")`.
- `call.elapsed`: instrument manually with `Std.Time.now()` at entry and exit
  inside the wrapped body.
- `config { }` in aspects: use aspect constructor arguments instead.
- `except name in { }`: apply `@no_aspect(Trace)` on individual functions
  that need exclusion.
- `pub aspect` templates: copy the aspect body per package; use a shared
  helper function for the repeated logic.

**Fix target:** `call.shortName`/`call.elapsed` ambients in 1.1;
`except name in { }` in 1.1; `pub aspect` templates and `config {}` in 1.2.

---

### G-07  `Lyric.Mono` — same-package generic functions only

**Current behavior:** `Lyric.Mono` (D-progress-229) monomorphises call sites
for generic functions defined in the same compilation unit.  It does not handle
value generic parameters (`GPValue`) or constraint propagation, and it does not
monomorphise calls to generic functions imported from other packages.

**Impact:** Cross-package generic specialisation (e.g. calling
`Collections.map[Int, String]` from user code) goes through the reified CLR
generic path rather than a monomorphised copy.  Performance is identical;
the gap is relevant only to the self-hosting correctness story.

**Workaround:** No user-visible workaround needed.  The CLR reified-generic
path is correct for all current stdlib generics.  For the self-hosted pipeline,
the F# `Emitter.fs` handles cross-package generics correctly.

**Fix target:** Q-mono-001.  Tracked as a Phase-5 M5.2 stage-4 follow-up.

---

### G-08  `Std.Yaml` — float values return `YString` (raw text)

**Current behavior:** YAML floating-point scalars (e.g. `3.14`) parse to
`YString("3.14")` rather than `YFloat(3.14)` because the `toDouble` BCL
extern is not yet wired (D065 note, Q-yaml-001).

**Impact:** Code that pattern-matches on `YFloat(v)` never matches.  Numeric
YAML configs that use floats will silently read as strings.

**Workaround:** Match on `YString(s)` and call `parseDouble(s)`:
```
match node {
    YString(s) => parseDouble(s).map((v) => process(v))
    YFloat(v)  => Ok(process(v))  // future-proof: won't match until fixed
    _          => Err(YamlError.TypeMismatch)
}
```

**Fix target:** 1.1.  Add `toDouble` BCL extern to
`lyric-stdlib/std/_kernel/string_host.l` and wire it into the YAML parser at
`lyric-stdlib/std/yaml.l::parseScalar`.

---

### G-09  `async` over generic instance impl methods

**Current behavior:** `asyncSmEligible` in `bootstrap/src/Lyric.Emitter/Codegen.fs`
gates on `sg.Generics.IsEmpty` — an `async func` inside an `impl[T] Foo for Bar[T]`
block falls back to the blocking `.GetAwaiter().GetResult()` shim (D-progress-141
close-out note).  Non-generic async impl methods are unaffected.

**Impact:** An `async` method on a generic interface implementation silently
becomes blocking at runtime.  No diagnostic is emitted.

**Workaround:** Extract the async logic into a free-standing generic `async func`
and delegate from the impl method:
```
async func doWorkImpl[T](t: T): Async[Result[T, Error]] { ... }

impl[T] Worker for Box[T] {
    async func doWork(): Async[Result[T, Error]] {
        doWorkImpl(self.value)
    }
}
```
The free-standing function gets a real state machine; the impl method becomes
a thin trampoline.

**Fix target:** The SM threading is mechanical once the type checker / interface
emitter / impl-block emitter pass through impl-block and method-level generics
correctly.  Tracked under Tier 6 in `docs/12-todo-plan.md`.

---

### G-10  `@projectionBoundary` — `asId` rename semantic not implemented

**Current behavior:** `@projectionBoundary` enforces cycle detection (T0092)
but does not rename the `id` field in the projected view to the source opaque
type as specified in `docs/01-language-reference.md` §7.3 / D026.  The source
opaque type is kept verbatim in the projection (B2 close-out note in
`docs/12-todo-plan.md`).

**Impact:** Code that calls `view.asId()` to obtain the boundary type's ID
value receives the wrong type.  This is an edge case in the projection DSL
that affects only multi-hop projections across `@projectionBoundary` markers.

**Workaround:** Do not rely on `asId()` for type-narrowing across a boundary.
Instead, expose a `pub func toSourceId(v: in ViewType): SourceId` function in
the boundary package and call it explicitly.

**Fix target:** 1.1.  Implement the `asId` rename in the projection-synthesis
pass in `bootstrap/src/Lyric.Emitter/Codegen.fs` under the `IProjectable`
synthesis block.

---

### G-11  FFI phase 3 shapes — by-ref structs, `Span<T>`, `params`, extension methods

**Current behavior:** C4 phase 3 (score-based matching for special BCL shapes)
is Tier 6 on-demand (D-progress-061 note).  Auto-FFI (C4 phase 1/2) resolves
most BCL methods.  The following shapes require explicit `@externTarget`:

- `in`/`ref`/`out` struct methods (by-ref structs)
- `Span<T>` / `ReadOnlySpan<T>` parameters
- `params T[]` variadic parameters
- Extension methods (e.g. `System.Linq.Enumerable.*`)
- Explicit interface implementations

**Workaround:** Write an explicit `@externTarget` declaration for any BCL
method that uses these shapes.  Auto-FFI score matching will not find it; the
declaration bypasses matching entirely:
```
@externTarget("System.MemoryExtensions::AsSpan[Char]")
extern func asSpan(s: in String): Span[Char]
```
For LINQ extension methods, declare each overload individually or write a
Lyric wrapper function that calls the BCL helper through a non-extension form
(`Enumerable.Where(xs, predicate)`).

**Fix target:** Phase 3 shapes land on-demand when a real Lyric program
surfaces the need.

---

## §4  Explicitly post-v1.0 (not blocking; no workaround needed)

These items are decided-deferred per `docs/04-out-of-scope.md`,
`docs/05-implementation-plan.md`, or decision-log entries.  They require no
workaround in user code because Lyric does not advertise them in v1.0.

| Item | Gate | Reference |
|---|---|---|
| Self-hosted AOT binary | Phase 7; `scripts/bootstrap.sh` three-stage diff | Q-dist-001; `docs/34-distribution-strategy.md` |
| Homebrew / winget / apt formulas | Gated on AOT binary | Q-dist-002..004 |
| `curl \| sh` installer | R6 work; not AOT-gated | Q-dist-005 |
| `Std.Regex` RE2 engine | On-demand (no attacker-controlled regex yet) | C5 Tier-6; `docs/12-todo-plan.md` |
| `property` full shrinking + generators | After `Std.Testing.Property` graduates from `@experimental` | Q011; G-04 above |
| Aspect contract inheritance | v1.x; sketch in `docs/30` | Q-aspects-006; D049 |
| `pub aspect` template libraries | v1.2 | Q-aspectlib-005'; `docs/27` |
| `Lyric.Verifier` cross-call / quantifier discharge | Phase 4 proof system; F# `Lyric.Verifier` is the v1.0 verifier | `docs/15-phase-4-proof-plan.md` |
| JUnit 5 full `LyricTestEngine` | B127+ | D-progress-206; `docs/32` |
| JS / WASM Component Model target | Entirely unbacked; Q-JS-001..006 open | `docs/35-js-wasm-component-sketch.md` |
| Package generics (module-level parameterisation) | Phase 5+ | `docs/04-out-of-scope.md` |
| Effect system beyond `async` | Post-v1.0 | `docs/04-out-of-scope.md` |
| REPL | Post-v1.0 | `docs/04-out-of-scope.md` |
| Hot reload | Post-v1.0 | `docs/04-out-of-scope.md` |
| Compile-time evaluation beyond constants | Post-v1.0 | `docs/04-out-of-scope.md` |
| IntelliJ / other-IDE plugins | Post-v1.0 | Q-J007e |
| `lyric fix` / structural refactoring | Post-v1.0 | `docs/12-todo-plan.md` C7 decision |
| ISO standardisation | Phase 6+ | `docs/05-implementation-plan.md` |

---

## §5  Milestone ordering and dependencies

```
G1, G2, G3, G4, G5   (gate decisions — no code; answer in sequence)
     │
     ├── R1  (Q011 surface freeze)          ← G2 required
     │
     ├── R2  (CST per-expression + sunset)  ← G3 required
     │
     ├── R3  (JVM Q-J012/Q-J013)            ← G1 required; can run parallel with R1/R2
     │
     ├── R4  (M5.3 stage 6 finish)          ← independent; Lyric.Doc first, then Lint,
     │        ContractMeta, Pack.l, Fmt.fs        ContractMeta, Pack.l, then Fmt.fs sunset
     │        sunset gated on R2;                 gated on R2; --target dotnet-legacy
     │                                            removal ALSO gated on contract-
     │                                            elaborator parity (nested returns,
     │                                            loop invariants, protected types)
     │
     ├── R5  (Q022 / Q021 language gaps)    ← independent; do Q022-1 and Q021-#4 first
     │
     ├── R6  (distribution / signing)       ← independent; can run parallel with all above
     │
     └── R7  (self-hosted soundness/correctness floor)  ← THE remaining blocker
              R7.1 (front-end soundness) → R7.2 (backend correctness)
              R7.3 (async) ∥  →  R7.4 (features) → R7.5 (F# elimination + AOT)
```

**§R1–R6 are all DONE.** The remaining critical path for the tag is now **R7**:

`R7.1 + R7.2 (correctness floor) → R7.3 (async) → R7.5 (AOT) → tag`
`(R7.4 feature items close per-feature; non-blocking ones defer to 1.x with a dated issue)`

R7.3 (async state-machine port) is the longest item and can start in parallel
with R7.1/R7.2.  The litmus test for the tag is the §R7 acceptance gate: every
`docs/02-worked-examples.md` program builds and runs under `--target dotnet`,
no silent miscompiles remain (anything unlowered hard-errors), and a
`<PublishAot>` native binary passes a CI smoke test.
