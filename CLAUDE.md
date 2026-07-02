# CLAUDE.md

Guidance for Claude Code (and future agents) working in this repository.

## What this repository is

Lyric is a safety-oriented application language targeting .NET. The self-hosted
compiler is written in Lyric and lives in `lyric-compiler/lyric/`. The repository contains:

- `README.md` — entry point. Lists the documentation map and reading order.
- `docs/00-overview.md` — design philosophy, target audience.
- `docs/01-language-reference.md` — authoritative language description (v0.1).
- `docs/02-worked-examples.md` — non-trivial programs in proposed-Lyric.
- `docs/03-decision-log.md` — every significant design decision with rationale.
- `docs/04-out-of-scope.md` — what we deliberately don't do.
- `docs/05-implementation-plan.md` — phased plan from v0.1 to self-hosting.
- `docs/06-open-questions.md` — unresolved design questions for Phase 0.
- `docs/07-references.md` — external standards and prior art.
- `docs/grammar.ebnf` — formal grammar (Phase 0 deliverable #4).
- `docs/08-contract-semantics.md` — operational semantics for contracts (Phase 0 deliverable #5).
- `docs/09-msil-emission.md` — MSIL emission strategy (Phase 0 deliverable #7).
- `docs/10-bootstrap-progress.md` — shipped-milestone status against the phased plan.
- `docs/10-stdlib-plan.md` — standard library module design and stability cut plan.
- `docs/11-stdlib-examples.md` — worked examples that exercise the standard library.
- `docs/12-todo-plan.md` — running task list for in-flight and upcoming work.
- `docs/13-tutorial.md` — narrative tutorial walking from hello-world to contracts.
- `docs/14-native-stdlib-plan.md` — `lyric-stdlib/std/_kernel/` extern-boundary design.
- `docs/15-phase-4-proof-plan.md` — Phase 4 verifier design (VC IR, SMT bridge).
- `docs/16-lsp-vscode-plan.md` — LSP server and VS Code extension plan.
- `docs/17-axiom-audit.md` — audit checklist for `@axiom` declarations.
- `docs/18-jvm-emission.md` — JVM bytecode emission strategy (Phase 6; self-hosted Lyric emitter shipped in `lyric-compiler/jvm/`).
- `docs/19-multi-file-packages.md` — multi-file package linking design.
- `docs/20-project-as-dll.md` — `lyric.toml`-driven multi-package build and DLL bundling.
- `docs/21-nuget-linking.md` — NuGet dependency resolution and `[nuget]` table design.
- `docs/22-distribution-and-tooling.md` — CLI distribution, install, and update design.
- `docs/23-fsharp-shim-elimination.md` — plan for removing F#-side shims as the self-hosted compiler matures.
- `docs/24-build-features.md` — `--features` / `[features]` conditional-compilation design.
- `docs/24-test-runner-plan.md` — `lyric test` design (single-file v1, multi-file v2).
- `docs/25-config-blocks.md` — `config { }` block design for compile-time DI configuration.
- `docs/26-aspects.md` — aspect-oriented cross-cutting concern design.

### Exploratory sketches (numbered ≥ 27)

These are pressure-test docs that surface design tensions before any
implementation. Each sketch builds on a base spec doc and is cited
from that doc's open-questions section. A sketch starts unbacked and
becomes the source-of-truth design for its slice once a decision-log
entry codifies its tensions; the sketch's status header carries the
backing entry's id.

- `docs/27-aspect-libraries.md` — cross-package aspect distribution design (extends D047). _Specced in D050._
- `docs/28-std-aspects-sketch.md` — `Std.Aspects` worked-example pressure-test for D047 + 27. _Drafted (worked example, not spec)._
- `docs/29-config-v2-sketch.md` — file-based source + layered precedence v2 sketch (extends D046). _Specced in D048._
- `docs/30-aspect-contract-inheritance-sketch.md` — aspect-to-aspect contract inheritance v1.x sketch (extends D047, addresses Q-aspects-006). _Specced in D049._
- `docs/31-maven-linking.md` — Maven Central dependency resolution and `[maven]` table design (JVM target). _Specced in D053._
- `docs/32-junit-runner-sketch.md` — JUnit 5 `TestEngine` adapter for `lyric test --jvm` (extends Q-J007 from `docs/18-jvm-emission.md`). _Partially implemented in D-progress-206 (B126): `@LyricTest` annotation class + `Jvm.TestEngine` shipped; full `LyricTestEngine` deferred to B127+._
- `docs/33-platform-parity-remediation.md` — platform-parity remediation plan (docs audit, JVM/MSIL self-hosted pipeline R1–R6). _Backed by D058 (MSIL PE emitter) and D-progress-227–239._
- `docs/34-distribution-strategy.md` — compiler and stdlib distribution channels (NuGet global tool, standalone ZIP, future AOT binary, bootstrap pipeline). _Specced in D059._
- `docs/35-js-wasm-component-sketch.md` — JS ecosystem integration via WASM Component Model: WIT generation from Lyric types, `[npm]` table, NPM extern shims, degraded-semantics policy, async lowering. _Unbacked (Q-JS-001–Q-JS-006 open)._
- `docs/35-lambda-library.md` — `lyric-lambda`, `lyric-aws-secrets`, and `lyric-aws-xray` design: API Gateway v1/v2/ALB → lyric-web Router bridge; SQS, SNS, S3, EventBridge, DynamoDB, Kinesis event handlers; TOKEN/REQUEST/HTTP API authorizers; `@secretsManager`/`@parameterStore` config-block annotations; AOT-safe handler registration (`Lambda.Direct`); response streaming (`Lambda.Stream`); JVM target (`feature = "jvm"`); AWS X-Ray active tracing aspect (`AwsXRay.Tracing`). _Specced in D062, D063, D064._
- `docs/36-v1-roadmap.md` — v1.0 release roadmap: gate decisions, six critical-path milestones (Q011 surface freeze, CST formatter sunset, JVM channel resolution, M5.3 stage-6 finish, Q022/Q021 language gaps, distribution/signing), and bootstrap-grade gaps with explicit workarounds.
- `docs/37-grpc-proto-sketch.md` — gRPC and Protobuf binding design: Lyric ↔ proto type mapping, `Result[T,E]` → gRPC Status, enum-with-payload → `oneof`, hybrid field-numbering (declaration-order default + lock file + `@proto_field` override), async streaming model (forward-looking, M1.4+), `lyric-grpc` library structure, `RequiresGrpcAuth` and `GrpcCircuitBreaker` aspect templates, tooling (`lyric grpc spec`, `lyric generate grpc`). _Unbacked (Q-G-001–Q-G-007 open)._
- `docs/38-workspace.md` — workspace (root `[workspace]` table, auto-discovery, member opt-out), git dependency form (`git`, `tag`/`rev`/`branch`, `subdir`), workspace overrides, transitive native dep propagation, and an exploratory sketch of eliminating `[nuget]`/`[maven]` from application manifests. _Specced in D073. Open questions Q-W-001–Q-W-004._
- `docs/39-package-registry.md` — Lyric package registry design: NuGet.org as the .NET channel, GitHub Packages Maven as the JVM channel, `lyric publish` and `lyric restore` flows, package naming convention, `lyric search` via NuGet tag filter, lock-file checksums, private feeds, and first-party ecosystem publish order. _Specced in D074. Open questions Q-R-001–Q-R-004._
- `docs/40-source-generators.md` — custom source generator API: `@generate` unified annotation form (replaces `@derive`), built-in vs custom generator resolution, `Lyric.GeneratorSdk` types, subprocess bridge model, security and trust, phasing, and open questions Q-SG-001–Q-SG-004. _Specced in D075._
- `docs/41-self-hosted-compiler-gap-analysis.md` — static audit (2026-05-20) of the self-hosted compiler vs. the language reference. Documents the pipeline disconnect (self-hosted backends bypass middle-end), per-feature MSIL and JVM coverage, F#-only constructs, and a seven-band remediation plan toward a production-ready self-hosted compiler on both targets. _Unbacked — see §9 bands for planned remediation._
- `docs/42-extern-metadata-resolution.md` — metadata-based extern signature resolution design (epic #1622, Band 4 of #1470): replaces the hardcoded `clrAssemblyForType` table + the auto-FFI `(object…) : void` guess with a **pure-Lyric CLI-metadata reader** that parses reference-assembly bytes directly (inverting the emitter's `pe.l`/`tables.l`/`heaps.l` writer). Resolves the D-progress-268 `Type.GetType`-null blocker (pure byte reading, no runtime type loading), rejects `System.Reflection.Metadata` (struct-FFI-hostile) and `MetadataLoadContext` (NuGet-only/AOT-risk), and lays out a five-phase plan. _Unbacked — see §5 for the phased plan; open questions Q-MD-001–Q-MD-005._
- `docs/43-in-bundle-generics-plan.md` — execution plan for emitting *truly generic* in-bundle types (GenericParam table 0x2A + VAR fields + instantiated TypeSpec construction/field/match) in the self-hosted MSIL backend, so generic records/unions and the stdlib `Option`/`Result` byte-match the F# emitter. The prerequisite for full Stage 3 (#2362) byte-match within epic #2359 (Stages 1/2/4 merged; Stage 5 #2364 pending). Recommends an `MGenericInstByName`/`MNewobjGenericByName` by-name encoding (TypeDef resolved at lowering), documents the validated GenericParam wire format vs `Lyric.Stdlib.dll`, and sequences Box[T] → Maybe[T] → stdlib stage-3 byte-match. _Implemented for in-bundle types (D-progress-453 records, D-progress-455 unions): in-bundle generic **records and unions** ship (GenericParam table 0x2A + VAR fields + arity-suffixed names + TypeSpec construction/field-read; union cases extend the open base instantiation `Maybe`1<!0>`, nullary cases are `newobj`-each-time with no singleton), verified by `inbundle_generics_self_test.l` (16 cases). #2362 is closed: the exact stage-3 stdlib byte-match was **not pursued** — the self-hosted emitter already produces structurally-correct generic `Option`/`Result` but carries the arity-suffix correctness fix F# omits, and self-compiling the whole stdlib is blocked on self-hosted front-end completeness (docs/41 §R7). Plan corrections: the `` `<arity> `` name suffix is required for multi-field value-type layout, and a generic type's ctor must `stfld` through the open self-TypeSpec. **Q-GEN-001 resolved** (F# emits no singleton for `Option_None`; nullary generic cases are constructed via `newobj`). Open questions Q-GEN-002–Q-GEN-005 (linked from docs/41 Band 4)._
- `docs/44-jvm-production-readiness-plan.md` — JVM production-readiness audit and remediation plan: the JVM counterpart to docs/41 (which excludes JVM) and docs/33 (narrow 20-program parity). Audits the self-hosted JVM backend code-as-source-of-truth (validated by building/running real programs on JDK 21), catalogues BLOCKER/MAJOR/MINOR findings (closures panic, async/`?` synchronous stubs, aspects not woven, `Float`→`double` and complex-assignment silent miscompiles, generics erased, `_kernel_jvm` never loaded by the self-hosted source loader, Maven self-hosting absent + orphaned `resolver/`, F#-host `Lyric.Jvm.Hosts` debt, CLI emits `.dll`+`runtimeconfig.json` for JVM), and sequences remediation into bands J0–J7. Documents the two JVM code paths (emission library vs user compile pipeline); J0 items are done and the JVM umbrella epic is #2663 (sub-tasks #2664–#2670). _Unbacked — needs a decision-log entry codifying band order and the G1 channel decision._
- `docs/45-contract-metadata-direct-resolution.md` — contract metadata distribution design for restored Lyric packages: migrates from current synthesis → parse → recheck per consumer to metadata-direct symbol table construction (mirroring auto-FFI for external types). Adds explicit `visibility` field and dependency manifest to metadata; validates once at library build. Breaks v2 support immediately (format version 3). Eliminates per-consumer overhead, simplifies preamble logic, strengthens visibility guarantees. _Specced in D098. Phase 1 (`Lyric.ContractMetaEmit` v3 emitter) shipped in D-progress-471. Phases 2–5 deferred pending #2580._
- `docs/46-const-patterns.md` — const patterns in match arms: `@Ident` syntax to reference compile-time `val` constants instead of raw literals, disambiguated from variable bindings, zero runtime overhead via type-check-time constant resolution. _Shipped in D-progress-523. Q-MP-001 resolved._
- `docs/47-import-extern-syntax.md` — `import extern` syntax for external types: unify Lyric package imports and external-type imports under one mechanism, with aliasing at the import site. Reduces boilerplate and makes the FFI boundary clearer. _Specced in D116 (Q47-001–Q47-004 resolved); Phase 1 parser support in PR #3728; Phase 2 type-checker integration deferred._
- `docs/48-constructor-shorthand.md` — Constructor shorthand for extern types: enable `.new(args)` calls on external types, eliminating `@externTarget` wrapper functions and aligning MSIL with JVM behavior. _Specced in D117 (Q48-003 resolved); Q48-001 (generic constructors) and Q48-002 (async constructors) deferred to follow-up._
- `docs/49-methods-in-types.md` — Methods inside type definitions: design space that led to D037. Documents how methods in type bodies desugar to UFCS-style functions, with explicit receiver (`self: in Type`) and zero new semantic surface area. Pressure-test record of design tensions (principle vs. pragmatism, parser simplicity, compatibility) that influenced the shipped design. _Specced in D037 (accepted 2026-04-30)._
- `docs/50-ffi-delegates-proposal.md` — Proposal to pass Lyric lambdas/method references to .NET methods expecting strongly-typed delegates via auto-FFI: once lambdas are strongly typed (Epic #1877), a Lyric `TFunction` signature structurally matches a .NET delegate's `.Invoke` signature, so FFI bridging collapses to a direct `ldftn`/`newobj` delegate instantiation with no adapter-thunk synthesis. Depends on `docs/52`/`docs/53`. _Proposal; Epic #1877 prerequisite shipped (D113), this doc's specific FFI-bridging simplification not separately confirmed shipped._
- `docs/51-ffi-interfaces-proposal.md` — Implementing external .NET interfaces from Lyric: an `impl <ExternInterface> for Record { … }` block emits an `InterfaceImpl` row against the existing TypeRef, with the CLR FQN resolved through the `import extern` / `extern type` table. _Specced in D105. Phases 1 (non-generic emission), 2 (metadata-based signature validation, `F0020`–`F0023`), and 3 (widening to extern-interface-typed bindings / parameters) shipped; closed generic external interfaces (`IEquatable<T>`, `IComparable<T>`, `IEnumerable<T>`-shaped) ship via TypeSpec emission + CLR name-matching through the TypeSpec; structural validation substitutes `STVar` against the iface's resolved type args and lifts F0024 for `STSzArray` / `STByRef` / `STNamedGenericInst` shapes. `F0024` was removed: TypeSpec emission produces structurally-valid IL for any closed instantiation, Phase 2 F0020–F0023 catches every build-time-detectable structural mismatch (with `STVar` substitution + recursive `STSzArray` / `STByRef` / `STNamedGenericInst` handling), and the runtime catches the rest as `TypeLoadException`.  `STMVar` (method-generic iface methods) and exotic shapes (`STPtr`, `STFnPtr`, `STArray` rank > 1) silent-skip per-method F0022/F0023 validation; F0021 still fires for any missing impl methods on the iface. Bridge-thunk synthesis is confirmed N/A for the current Lyric MSIL ABI; LSP "Implement Interface" scaffolding shipped in #3861. Remaining-work implementation plans live in docs/51 §"Remaining work" with concrete file/line references._
- `docs/52-strongly-typed-lambdas-proposal.md` — Proposal to replace the interim uniform `Func<object, ..., object>` lambda ABI with a strongly-typed MSIL lambda ABI: eliminates primitive boxing/unboxing on captures and call args, lets the JIT inline/optimize lambda bodies, and removes FFI adapter-thunk friction against nominal .NET delegates. _Shipped as Epic #1877 Phase 2 (D113 — closure class synthesis for zero-overhead lambda captures; see `docs/53` for the concrete implementation plan)._
- `docs/53-epic-1877-implementation-plan.md` — Concrete implementation plan for `docs/52`'s strongly-typed lambda ABI (Option 2A: synthesize custom MSIL `.class` closure-environment types instead of `object[]` arrays). _Shipped (D113); verified by `closure_zero_overhead_self_test.l` (16 cases, MSIL + JVM parity)._
- `docs/54-docker-client-library-sketch.md` — Design for `lyric-docker`, a type-safe Docker daemon API client over Unix sockets (Linux/macOS) / named pipes (Windows), with OpenAPI-generated bindings and `Result[T, Error]`-returning async operations. _Phase 1 shipped (D-progress-541); Phase 2 planned._
- `docs/55-bmode-aspect-libraries-plan.md` — implementation plan for cross-package library aspect distribution's B-mode half (extends docs/27 §6.1, Q-aspectlib-001/-009). B-mode was speced (D047-revision 2026-05-08) but, until this shipped, only C-mode (`@inline_template`) existed — reified generic *methods* (MVAR), the originally-envisioned B-mode artifact, aren't buildable (only generic *types* are reified; docs/43 Q-GEN-002). Ships **B′-mode**: a monomorphisation-based variant implemented as a weaver-native shape cache (not `Lyric.Mono` — an aspect body is never itself generic-typed AST, so Mono's `TVar`-substitution engine doesn't apply), getting B-mode's zero-boxing/type-safety/dedup properties without the MVAR prerequisite (but not the "callable from non-Lyric consumers" property, which only true reified generics would provide). _Specced and implemented in D114 (contract-metadata `bmode` discriminator, weaver `CollectedTemplate` ground truth + A0046 diagnostic, shape-keyed specialisation, no new MSIL/JVM codegen needed). `docs/56`'s row-typed `args` is the next follow-on extension of this path._
- `docs/56-row-typed-aspect-args-sketch.md` — pressure-test sketch for row-polymorphic (`where TArgs has {field: Type}`) named-field access on B′-mode aspect `args`, extending docs/55. Scopes the constraint-satisfaction check to compiler-synthesized `TArgs` only (never user-nameable), keeping it a bounded per-specialisation-site structural check rather than general row-type unification; compares against a narrower "auto-synthesized marker interface" alternative (reusing docs/51's `InterfaceImpl` emission) that gets the same functional result with zero new language surface. _Specced and shipped in D115: Option 1 (the row constraint) was chosen over the marker-interface alternative and implemented end-to-end (grammar, weaver `__LyricBModeArgs_<template>` record synthesis + A0047 diagnostic, formatter), with `Auth.Aspects.ValidateKey` converted off `@inline_template` as the ecosystem proof-of-value. Q-row-001–005 all resolved — see D115. D118 fixed a pre-existing gap where aspect `requires:`/`ensures:` referencing `args.<field>` was never enforced at runtime (in either C-mode or B′-mode), then retired `@inline_template` from every other field-accessing ecosystem library aspect across `lyric-web`, `lyric-validation`, `lyric-mq`, `lyric-ws`, `lyric-grpc`, `lyric-storage`, and `lyric-lambda`._


## Reading order (for Claude)

When picking up cold, follow the README's newcomer order: **00 → 02 → 01 → 03**.
For implementation work consult **05** (phasing) and **06** (open questions).
For "is this in scope?" questions consult **04**.
Numbered docs ≥ 27 are sketches and not part of the reading order;
read one only when working on (or implementing) the slice it specs,
and pair it with its backing decision-log entry (e.g. docs/29 ↔ D048,
docs/30 ↔ D049). When opening a new sketch, link it from the relevant
spec doc's open-questions section and add an entry to the list above.

## Status of Phase 0 deliverables

From `docs/05-implementation-plan.md` §"Phase 0":

| # | Deliverable | Status |
|---|---|---|
| 1 | Language reference v0.1 | Drafted (`docs/01-language-reference.md`) |
| 2 | Decision log | Drafted (`docs/03-decision-log.md`) |
| 3 | Worked examples | Drafted (`docs/02-worked-examples.md`) — 11 examples covering both happy-path and edge cases |
| 4 | Formal grammar in BNF/EBNF | Drafted (`docs/grammar.ebnf`) |
| 5 | Operational semantics for contracts | Drafted (`docs/08-contract-semantics.md`) |
| 6 | Resolution of 12 [TBD] items in §13 of the language reference | Q001–Q010 resolved (see `docs/01-language-reference.md` §13 status table); Q011, Q012 deferred to Phase 3 |
| 7 | MSIL emission strategy | Drafted (`docs/09-msil-emission.md`) |

The language reference is the source of truth for syntax and semantics.
The grammar implements its lexical and syntactic descriptions; if the
grammar and the reference disagree, fix the grammar (or, if a genuine spec
ambiguity is uncovered, fix the reference and append a decision-log entry).

## Working conventions

### Production-readiness standard — no shortcuts, no bootstrap-grade fixes

The goal is a **production-ready compiler, standard library, and ecosystem,
fully self-hosted in Lyric.** This is the bar every change is measured
against. Bootstrap-grade workarounds, "good enough for now" fixes,
temporary hacks, stubbed implementations, and TODO-laden landings are
**no longer acceptable**. Treat the codebase as if it ships to external
users tomorrow.

Concretely, the following are **not acceptable** as a way to close out a
task:

- Hand-routed BCL externs added to plug a stdlib gap "for now" instead of
  a properly audited `lyric-stdlib/std/_kernel/` boundary with the public
  Lyric API on top.
- **Any new F# code at all**, regardless of size or purpose. The legacy F#
  bootstrap compiler has been completely removed. New functionality — domain logic,
  test infrastructure, MSBuild plumbing, "thin shims" — all goes in Lyric.
- "Bootstrap-grade" caveats in commit messages, PR bodies, or docs
  ("we'll do this properly later", "leaving the hand-routed path in
  place for now", "MSIL-only for this release"). If the proper version
  is out of scope for the current PR, file a tracked issue with a
  concrete plan and link it — do **not** ship the shortcut as if it
  were the final state.
- Disabled, skipped, or `Ignore`-attributed tests added to make a build
  go green. Either fix the underlying issue or, if the test is wrong,
  delete it with a justification in the commit message.
- Diagnostics, error messages, or CLI output that are placeholders
  ("TODO: better message", `printfn "%A"`-style dumps, untyped panics).
  User-visible surfaces ship at production quality.
- One-platform implementations (MSIL-only or JVM-only) of constructs that
  the language reference defines for both targets. If parity is genuinely
  out of scope, the gap is a tracked, dated issue — not an undocumented
  silent skip.

- "Make the test pass" patches that paper over a real bug instead of
  fixing it. Reach for the root cause every time.

When in doubt, prefer landing **less scope** at production quality over
landing **more scope** at bootstrap quality. A smaller, fully-finished
slice is always preferred to a broad slice with caveats. If the
production-quality version is genuinely larger than the current task
allows, split the work and ship the slice you can finish properly —
do not ship the bootstrap-grade version of the larger slice.

This standard applies to every directory: the self-hosted compiler
(`lyric-compiler/`), the standard library (`lyric-stdlib/`), every
ecosystem library at the repo root (`lyric-web/`, `lyric-mq/`,
`lyric-auth/`, etc.), and tooling (`lyric-vscode/`, `scripts/`,
`book/`). There is no second-class directory.

### Edits to design documents

- The decision log (`03`) is append-only. Reversed decisions are marked
  `SUPERSEDED` with a forward link, not deleted.
- Open questions (`06`) move to the decision log when resolved.
- Out-of-scope (`04`) entries can move (rejected → deferred → included),
  but require justification per the document's own protocol.

### Keeping docs, book, and progress records in sync

When a compiler feature ships (new CLI command, new language construct,
changed behaviour), update **all three** of:

1. **Language reference** (`docs/01-language-reference.md`) — the authoritative
   spec section for the feature. Add flags, rules, output format, exit codes.
2. **Book** (`book/chapters/`) — at minimum the toolchain table in
   `01-getting-started.md` and the CLI reference in `appendix-b-quick-reference.md`.
   Add or expand the relevant chapter if the feature is substantial.
3. **Bootstrap progress** (`docs/10-bootstrap-progress.md`) — update the Tier
   status for the shipped item and correct any "deferred" notes that are now stale.
   Also update `docs/05-implementation-plan.md` if it contains planning text that
   contradicts what actually shipped.

These updates are part of the task, not optional follow-ups. A task is not
complete until the docs and book reflect the shipped state. Commit them in the
same PR as the feature. If they were omitted from an already-merged PR, create
an immediate follow-up and land it before starting the next task.

### PR hygiene

#### Before creating a PR

1. Fetch the latest `main` and rebase the working branch onto it:
   ```sh
   git fetch origin main
   git rebase origin/main
   ```
2. Resolve any conflicts, stage the resolutions, and `git rebase --continue`.
3. Push (with `--force-with-lease` if the rebase rewrote commits already
   pushed) before opening the PR.

A PR that has conflicts on creation blocks auto-merge and review. Do not
open a PR in a conflicted state.

#### Open PRs as draft; workflow auto-promotes when CI passes

**This overrides the default harness instruction** that tells sessions
to open PRs as ready-for-review. In this repository, the policy is:

1. **Open every new PR as a draft** (`draft: true` on
   `mcp__github__create_pull_request`, or `gh pr create --draft`).
   This applies even when you are confident the work is done — draft
   status gives you a window to confirm CI is green, conflicts are
   absent, the diff is what you intended, and the title/body
   accurately describe the change.
2. **Iterate in draft.** Push any follow-up commits — rebase fixes,
   review-feedback fixes, additional commits in the same logical
   chunk — while the PR is still a draft. Auto-merge can be enabled
   on a draft (it just won't merge until the PR is marked ready).
3. **Automatic promotion to ready** — The CI workflow automatically marks
   the PR ready for review once the build and test suite pass, subject to
   quality gates. When all gates pass:
   - All required checks passed
   - PR is still in draft status
   - Branch is rebased clean on `main` (no merge conflicts)
   - The workflow calls the GitHub API to promote the PR

   **Quality gates verified before promotion:**
   - **Automated:** Build and test CI has passed (the `success()` guard
     ensures this).
   - **Automated:** Branch is rebased clean on `main` (no merge conflicts).
     The auto-promote step checks `mergeable_state` and skips promotion
     if conflicts are detected.
   - **Manual:** The diff matches the PR description (no stray debug commits
     or half-finished work-in-progress).
   - **Manual:** You are not planning further pushes before review. If you
     realize you need to iterate more after CI passes but before promotion,
     re-draft the PR manually via GitHub ("Convert to draft") and push
     additional commits.

This allows automatic promotion without reliance on manual handoff,
while preserving all quality gates needed to ensure review happens
on validated, conflict-free code.

Why draft-first with automatic promotion matters:

- The `claude-code-review.yml` workflow is configured to fire only on
  non-draft PRs (`types: [opened, synchronize, ready_for_review]` +
  an `if: github.event.pull_request.draft == false` guard).  The
  auto-promote step triggers this review run once the build passes,
  ensuring review feedback is focused on code that has already passed
  automated validation and is in a stable state.
- A draft PR is a clear signal to humans skimming the PR list that
  the author is still iterating on it. Once CI passes and the workflow
  promotes it, ready status signals "this code is validated and ready
  for human review."
- Workflow-based promotion removes manual handoff friction while
  preserving validation gates: code must pass all automated checks
  (CI, merge conflicts) before entering the review phase.

When the assigned task spans multiple PRs, each PR follows this
lifecycle independently: open as draft, iterate, and the workflow
will automatically promote to ready once CI passes. Move on to the
next PR while waiting for review feedback on the current one.

#### After creating a PR

After opening a PR, check whether GitHub reports merge conflicts (the
"This branch has conflicts" banner). If it does:

1. Fetch and rebase:
   ```sh
   git fetch origin main
   git rebase origin/main
   ```
2. Resolve conflicts, stage, and `git rebase --continue`.
3. Push with `--force-with-lease` to update the PR branch.

Repeat until GitHub shows the branch as mergeable. If auto-merge was
enabled before the conflict appeared, re-enable it after pushing the
resolution.

#### If CI checks haven't started, suspect conflicts first — don't wait

When you open a PR (or push to one) and the expected status checks
(`claude-review`, build, tests, etc.) do **not** appear within ~30
seconds of the push landing, the overwhelmingly common cause is a
**merge conflict with `main`**. GitHub's checks don't run on a PR
that can't be merged — and **no `<github-webhook-activity>` event
will ever arrive** for a workflow that was never queued. Waiting
on webhooks in that state is waiting forever.

Be proactive. The moment a check looks stuck, **don't sit on
webhooks** — go check the PR state directly:

```sh
git fetch origin main
git log --oneline HEAD..origin/main   # is main ahead?
```

Or, via the GitHub MCP, call
`mcp__github__pull_request_read` with `method: "get"` and inspect
`mergeable` / `mergeable_state`:

- `mergeable: false` or `mergeable_state: "dirty"` → the PR has
  conflicts. Rebase onto `main`, resolve, force-with-lease,
  re-poll.
- `mergeable_state: "unknown"` → GitHub is still computing.
  Re-poll once after a few seconds; if it stays `unknown` for
  more than a minute it usually means a conflict is being
  detected.
- `mergeable_state: "behind"` → branch is out of date but not
  conflicted. Rebase and push.
- `mergeable_state: "blocked"` → mergeable but blocked by a
  required check or review (different problem; see the review
  loop below).
- `mergeable_state: "clean"` and no checks → the workflow
  trigger may not match (paths filter, branch filter, draft
  state). Investigate `.github/workflows/` rather than waiting.

Decision rule: **if a check that was expected hasn't started
within ~30s, actively diagnose. Do not wait for a webhook that
will never fire.** Always check first:

1. Is the branch in conflict? (most common)
2. Is the PR a draft when the workflow only fires on ready PRs?
3. Did a paths/branches filter exclude the change?
4. Did the workflow fail at the setup/parse stage before queuing
   any job?

Resolve whichever one applies, push, and only **then** lean on
webhook events. Treat a silent CI as a problem to investigate
immediately, not as a state to wait through.

#### Watching an open PR

Treat **any of these signals** as a cue to fetch `main` and rebase
the open PR:

- A `<github-webhook-activity>` event arrives mentioning the PR (in
  particular: a new push or a CI failure on a PR that previously
  passed).
- A `<github-webhook-activity>` event shows the `claude-review`
  check completing — whether it passed or failed.  A failure means
  REQUIRED findings were raised; see "Handling failed review checks"
  below.
- The user pings the session about an open PR.
- A `git status` / `git fetch` shows new commits on `origin/main`
  while you have an open PR on the current branch.
- You've just resumed a session and the current branch has an open
  PR.

Action:

```sh
git fetch origin main
git rebase origin/main
```

If conflicts appear, resolve them in line with the existing rebase
instructions (stage, `git rebase --continue`), build, run the
impacted test suites, then `git push --force-with-lease`.  Open
PRs that have gone stale because of unrelated docs / progress-log
churn on `main` are the typical case — renumber any
`D-progress-N` entries that collide with main, keep both the
incoming and your-branch entries, and delete only your own
duplicate hunk.

If you only need to verify the surface state without fetching, the
GitHub MCP `mcp__github__pull_request_read` tool with `method:
"get"` reports `mergeable` / `mergeable_state` directly.

#### Polling for PR feedback (review comments, claude-review)

Comment-polling timing matters.  Three separate surfaces exist
on `mcp__github__pull_request_read`, and they don't overlap:

- `get_review_comments` — line-level review threads (PR diff
  comments).
- `get_reviews` — formal review submissions (Approve / Request
  Changes / Comment with body).
- `get_comments` — **issue-level comments on the PR body**.
  This is where the `claude-review` workflow posts its summary.

Treat them as three independent buckets — one being empty does
**not** mean there's no feedback.  In particular,
`claude-review` posts to `get_comments`, not the review surfaces.

Timing:

- The `claude-review` check fires *after* the PR is opened and
  takes 1-3 minutes to land its comment.  An immediate poll
  after `create_pull_request` will show `[]` because the review
  hasn't run yet.
- Re-poll `get_comments` when the `claude-review` check run
  transitions from `queued` / `in_progress` to `completed`
  (the `<github-webhook-activity>` event for that check
  completing is a clean trigger), or when the user pings the
  session about review feedback.
- If you've polled once and seen `[]` while CI was pending,
  poll again at least once more after CI completes.  Don't
  declare "no review feedback" until every relevant check is
  `completed` and all three comment surfaces are empty.

#### Handling failed review checks (review:changes-required)

The `Claude Code Review / claude-review` workflow is a required
status check.  When it finds **REQUIRED** findings it:

1. Creates a GitHub issue per finding, labeled `pr-N` and
   `review-finding`, so findings are never lost across commits.
2. Posts a summary comment on the PR linking every issue number.
3. Applies the `review:changes-required` label to the PR.
4. **Fails the workflow**, blocking auto-merge.

When you are subscribed to a PR (`subscribe_pr_activity`) and the
`claude-review` check fails, treat it as a full work item, not a
notification to skip:

1. **Read the summary comment** (`get_comments` on the PR) and
   the linked issues (`gh issue view <n>`) to understand each
   finding.
2. **Fix every REQUIRED finding** in code.  When the fix lands in
   the *same* PR before merge, the review workflow auto-closes the
   finding on the next `claude-review` run (it detects the finding
   is gone from the new diff).  When you push fixes *after* a PR has
   merged, or when a finding turns out to already be fixed on `main`,
   the auto-closer cannot see them — close the issue manually
   with a one-line comment pointing at the fixing commit / PR.
3. **Commit and push** the fixes.  The push triggers a new
   `claude-review` run automatically (the workflow fires on
   `pull_request: synchronize`).
4. **Wait for the new run** (1-3 min).  A
   `<github-webhook-activity>` check-run event signals completion.
   If it passes (no `review:changes-required` label), auto-merge
   resumes.  If it fails again, repeat from step 1.
5. **SUGGESTION findings** are tracked as issues too but do not
   block merge.  Address them if they are low-effort or if the
   user asks; otherwise note them for follow-up.

Do **not** push empty commits or trivial no-op changes to get the
check to pass — fix the actual underlying issues.  If a REQUIRED
finding is incorrect or based on a misunderstanding of the
codebase, comment on the GitHub issue explaining why, then ask the
user whether to override it.

Re-poll `get_comments` after each new push to confirm the review
verdict changed.  Declare the review loop done only when:
- The `review:changes-required` label is absent from the PR, AND
- The `Claude Code Review / claude-review` check shows green.

#### Closing the originating issue when a PR merges

The auto-close logic above only runs against review-finding
issues (the `review-finding`-labeled ones the review workflow creates).
**Issues that originated *outside* the review loop** — e.g. the
hand-authored CRITICAL / HIGH / MEDIUM / LOW tickets like #311,
#316, #345, etc. — are *not* touched by the workflow, even when a
PR explicitly fixes them.

When you watch a PR through to merge, close every issue it
addresses immediately after the merge webhook fires:

1. Identify the originating issues — the PR description's
   "Closes #N" / "Fixes #N" lines, plus any issues the PR body
   references in its "Cross-references" / "Related" sections.
2. For each, call `mcp__github__issue_write` with
   `method: "update"`, `state: "closed"`, and
   `state_reason: "completed"`.
3. Follow with `mcp__github__add_issue_comment` carrying a
   one-paragraph note that names the merged PR and summarises how
   it was fixed (the fix, not the diff).  This makes the issue
   self-explaining when someone lands on it from a search.
4. If the PR only partially addresses the issue (the typical
   parent-issue case — e.g. #318 covering 24 libraries while the
   PR ships tests for two), leave it OPEN and add a status comment
   listing what's done and what remains.
5. For review-finding issues that addressed concerns the merged
   PR fixed *after* the auto-close window (or were already stale
   on `main`), close them manually with `state_reason: completed`
   and a comment pointing at the resolving commit or the existing
   state on `main`.

Do this as part of the same turn that handles the merge webhook
— don't wait for a separate "tidy issues" pass.  The audit
runs cleaner when an open issue list always reflects in-flight
work, not historical bookkeeping debt.

### No F# code allowed

**The repository has been fully transitioned to the self-hosted compiler. F# is completely gone.**

**No F# code.** This is absolute. All production surface — compiler, standard library, ecosystem libraries, tooling — is written in Lyric (`.l`). Any new files or changes must be implemented in Lyric. Do not introduce any F# code or shims under any circumstances.
is ready, at which point the F# file is deleted.

**Production-grade self-hosted, not bootstrap-grade anything.** The
project standard is that every shipped feature works end-to-end
through the self-hosted toolchain, with production-quality
diagnostics, documentation, tests, and parity across MSIL and JVM
targets. "Good enough for bootstrap" is not a deliverable level;
either ship the production-quality slice, or split the work and
ship the slice you can finish properly.

Rules for where new code goes:

- **New stdlib modules** → `lyric-stdlib/std/<module>.l` (public) and
  `lyric-stdlib/std/_kernel/<module>_host.l` (externs, only when a BCL
  boundary is unavoidable, and the externs are declared with
  `extern type` / `extern package` in Lyric — not via an F# host
  shim).
- **New CLI logic** → implement in `lyric-compiler/lyric/<feature>.l`
  (as a `Lyric.<Feature>` package).  The AOT entry-point project
  (`bootstrap/src/Lyric.Cli.Aot/`) trampolines into the Lyric-emitted
  `Lyric.Cli.Program.main`, so new commands land in
  `lyric-compiler/lyric/cli/cli_main.l`'s dispatcher (the `Lyric.Cli`
  package lives in `lyric-compiler/lyric/cli/`).
- **New externs** → `lyric-stdlib/std/_kernel/` only, via `extern type`
  / `extern package` in `.l`. No `@externTarget` declarations pointing
  at F# host code.
- **New self-tests** → `lyric-compiler/lyric/<package>_self_test.l`
  (or wherever the package lives). Discovery is Lyric's job; do not
  add an F# runner shim.
- **New ecosystem-library code** → the appropriate `lyric-*/` root
  directory in `.l`.

### Style

- No emojis in any file unless the user asks.
- No new markdown documents unless the user asks for one.
- Prefer editing existing files to creating new ones.
- Don't write code comments that restate what code does — only comments
  for non-obvious *why*.

### Formatting — run `lyric fmt` before every commit

Before committing, run the **self-hosted** formatter over every `.l`
file you changed:

```sh
# after `make lyric` (gives ./bin/lyric):
for f in $(git diff --name-only --diff-filter=ACM -- '*.l'); do
  ./bin/lyric fmt --write "$f" || echo "SKIPPED (unsafe to format): $f"
done
```

`lyric fmt` (the self-hosted formatter in `lyric-compiler/lyric/fmt/`) is
the single source of truth for Lyric source layout. Key properties:

- It **auto-fixes** a file's plain `//` module-level header block to the
  canonical `//!` form (the language reference, §1.3, makes `//!` the
  inner/module doc form; a plain `//` banner before `package` is
  otherwise discarded by the AST). A `///` before `package` is a P0020
  parse error (no item to document) — `fmt` refuses such a file rather
  than auto-fixing it; change the `///` to `//!` yourself.
- It is **loss-checked**: `--write` re-parses its own output and
  **refuses to write** (non-zero exit, prints the reason, leaves the file
  untouched) if formatting would drop a comment, a contract clause
  (`requires:`/`ensures:`/…), or any token such as a `pub` modifier or
  identifier, or if the input or output does not parse cleanly. See
  `Lyric.Fmt.formatSourceChecked`.

A refusal means the file hit a self-hosted parser gap or a formatter bug
— **fix the underlying issue or leave the file unstaged; never
hand-format around a refusal**, and never reintroduce an ad-hoc
formatter (the F# bootstrap formatter that stripped `//` comments was
removed). Do not use any other formatter on `.l` files.

**Sandbox exception:** a session that cannot build `./bin/lyric` from
source (network-policy-blocked release download, no working F#
mint-fallback) has only the published NuGet `lyric` global tool available,
whose `lyric fmt` has been observed to diverge from `main`'s canonical
style for at least one file. `docs/03-decision-log.md` D-progress-543
documents the verified trigger, the interim hand-formatting substitute,
and the three conditions that must hold before it applies — read that
entry before skipping or hand-rolling formatting in this situation.

### Branches

The user assigns the working branch via the session prompt
(e.g., `claude/define-language-spec-5DbnS`). Develop, commit, and push
to that branch. Never push elsewhere without explicit permission.

### Autonomous-work default

When the user assigns a multi-stage task on a working branch, the
default is to **work through it without check-ins until you genuinely
need direction and have nothing else productive to do**.  Specifically:

- Plan the work (TodoWrite or equivalent), then execute. Do not pause
  between stages for "should I continue?" approvals.
- Commit and push regularly in coherent chunks; group related commits
  into a single PR when they belong together (e.g. one PR per
  milestone-stage), and open a fresh PR when the next chunk is
  scoped differently.
- **After opening a PR**, immediately call `subscribe_pr_activity` so
  that check-run completions, review comments, and CI events wake this
  session.  The subscription must cover the `claude-review` check: if
  it fails (REQUIRED findings), action the feedback and push fixes
  (potentially several times) until the check goes green.  See
  "Handling failed review checks" above for the full loop.
- If a stage hits a real blocker (missing decision, ambiguous spec,
  external dependency), park it with a clear note and move on to the
  next independent stage rather than stopping the session.
- Only stop and ask the user when **every** remaining task is
  blocked, or when an action falls The self-hosted compiler and runtime libraries make up the entire build chain:

- `lyric-stdlib/std/` — Lyric-language standard library source (`.l` files).
  The emitter resolves `import Std.X` by locating `lyric-stdlib/std/<x>.l` here,
  walking up from the binary's base directory or honoring `LYRIC_STD_PATH`.
  The `lyric-stdlib/std/_kernel/` subdirectory holds the audited extern boundary
  (see `docs/14-native-stdlib-plan.md` Decision F): only kernel files may
  contain `@externTarget` / `extern type` declarations or `import extern` statements.
  Key modules: `Std.Core` (Option, Result), `Std.Collections` (List, Map),
  `Std.String`, `Std.Char`, `Std.Json` (BCL-backed, `.NET`-only),
  `Std.Time` (Instant, Duration, Clock, SystemClock, toEpochMillis),
  `Std.Uuid` (newUuid, uuidToString, parseUuidOpt),
  `Std.Xml` (pure-Lyric XML 1.0 parser, cross-platform, D065),
  `Std.Yaml` (pure-Lyric YAML 1.2 + JSON parser, cross-platform, D065).
- `lyric-stdlib/tests/` — Lyric-language test suite for the stdlib. Each
  `*_tests.l` file is a standalone Lyric program that imports the modules
  it covers and asserts correctness via `Std.Testing`.
- The Lyric-compiled stdlib bundle (per `lyric-stdlib/lyric.toml`) ships
  as `Lyric.Stdlib.dll` directly — the SDK's `lib/Lyric.Stdlib.dll` is
  this bundle. `lib/Lyric.Stdlib.dll` is
  this bundle, not the retired F# shim.
- `bootstrap/src/Lyric.Emitter/` — the MSIL emitter (Phase 1, milestone M1.3,
  complete). Lowers a parsed + type-checked Lyric source to a `dotnet exec`-
  runnable PE via `System.Reflection.Emit`'s `PersistedAssemblyBuilder` and
  `ManagedPEBuilder`.
- `lyric-compiler/lyric/` — the **self-hosted Lyric compiler** sources.
  M5.1 (lexer / parser / type checker / CST) and M5.2 stages 1–2
  (mode checker, contract elaborator) have shipped:
  - `lexer.l` — full self-hosted lexer: identifiers (NFC-normalised,
    UAX #31 XID_Start/Continue), keyword table, all integer/float
    literal forms, plain/interpolated/triple/raw strings, character
    literals (BMP `\u{…}`), punctuation, line and nested block
    comments, doc/module-doc comments, statement-end insertion, and
    diagnostics L0001–L0040 (PR #190, D-progress-093–D-progress-121).
  - `parser/` — self-hosted parser as a five-file `Lyric.Parser`
    library: `parser_ast.l` (the authoritative self-hosted AST type
    declarations, mirroring `Ast.fs`; the earlier standalone `ast.l` /
    `Lyric.Ast` mirror from PR #185 was a never-imported duplicate and
    was deleted), `parser_core.l`, `parser_exprs.l`,
    `parser_items.l`, `parser_cst.l` (PR #190, D-progress-128;
    CST layer added in D-progress-130).
  - `type_checker/` — self-hosted type checker `Lyric.TypeChecker`
    (PR #195, D-progress-132); nine files: `typechecker_checker.l`,
    `typechecker_constfold.l`, `typechecker_exprs.l`,
    `typechecker_resolver.l`, `typechecker_scope.l`,
    `typechecker_signature.l`, `typechecker_stmts.l`,
    `typechecker_symbols.l`, `typechecker_types.l`.
    **This is the type checker used for all user-code compilation** —
    `Msil.Bridge` (for `--target dotnet`) and `Jvm.Bridge` (for
    `--target jvm`) both `import Lyric.TypeChecker` and call
    `checkFile`.  Any T004x type error reported during `lyric build /
    lyric test` comes from    `typechecker_exprs.l` (or the other files
    in this directory).
  - `mode_checker/` — self-hosted mode checker `Lyric.ModeChecker`
    (PR #198, D-progress-133); two files: `modechecker_mode.l`,
    `modechecker_check.l`.  Enforces V0001–V0006 / V0009–V0011
    against the parsed AST.
  - `contract_elaborator/elaborator.l` — `Lyric.ContractElaborator`
    (M5.2 stage 2).  Walks each `IFunc` item and produces an AST
    where `requires:` / `ensures:` clauses are lowered into runtime
    `assert(...)` statements: requires asserts are prepended to the
    body block, and each top-level `SReturn` / trailing implicit
    fall-off is rewritten to bind the produced value into a synthetic
    `__lyric_result_<n>` local, run every ensures assert (with
    `EResult` substituted for the local), then yield / return the
    local.  The original `contracts` list on each `FunctionDecl` is
    preserved so the verifier and contract-meta consumers see the
    source-level clauses unchanged.  `@axiom` functions and
    body-less signatures are passed through untouched.  Nested
    returns inside `if` / `match` / loop bodies, protected-type
    entries, and loop `invariant:` lowering are deferred to a
    follow-up stage (the bootstrap emitter still inserts runtime
    checks for those via the exit-label routing in `Emitter.fs`).
  - `test_synth/test_synth.l` — `Lyric.TestSynth` library: source-text
    rewriter that backs `lyric test`.  Walks a `@test_module` file's
    AST, replaces each `ITest` with a synthesised `func __lyric_test_<i>`,
    and appends a synthesised `func main(): Int` that runs them and
    prints TAP-shaped output. This is fully self-hosted and handles `lyric test` completely.
  - `mono.l` — `Lyric.Mono` monomorphizer (M5.2 stage 4, D-progress-229).
    Call-site monomorphizer for generic functions defined in the same
    compilation unit.  Collects all generic `IFunc` items, walks non-generic
    bodies to infer concrete type arguments (from literals and explicitly-
    annotated variables), produces specialised copies (e.g. `mapFoo__Int__String`),
    and rewrites call sites.  Public entry: `monoFile(file): MonoResult`.
  - `manifest.l` — `Lyric.Manifest` TOML parser for `lyric.toml`
    (M5.3 stage 1, D-progress-129).  Parses the subset of TOML used by the
    Lyric package system (`[package]`, `[project]`, `[dependencies]`,
    `[nuget]`, `[nuget.options]`, `[maven]`, `[maven.options]`,
    `[features]`).  `[maven]` parsing (D053 / `docs/31-maven-linking.md`;
    J5 M-6 parsing slice, #2668) mirrors `[nuget]`: `assembleMaven`
    yields a `MavenSection` of `MavenEntry` coordinate/version pairs
    plus `repositories` (default `["central"]`) and an optional
    `java_version`.  The Maven resolution/download path (M-7) is not
    yet wired.
  - `cfg.l` — `Lyric.Cfg` compile-time feature erasure (D045 /
    D-progress-299).  Self-hosted port of `bootstrap/src/Lyric.Emitter/Cfg.fs`.
    Provides `applyCfgErasure(active, declared, sf): CfgErasureResult`
    used by `Msil.Bridge.compileProjectToMsilWithFeatures` to drop
    `@cfg(feature = "X")`-annotated items whose feature is inactive.
    Emits `F0012` for malformed predicates and `F0013` for features
    absent from the manifest's `[features]` table (typo guard, opt-in
    via a non-empty declared set).  File-level `@cfg` annotations erase
    every item in the file.  Boolean composition (`any` / `all` /
    `not`) deferred to v1.1 per D045.
  - `manifest_bridge.l` — `Lyric.ManifestBridge` protocol bridge used by
    `SelfHostedManifest.fs` (D-progress-231).
  - `fmt/` — self-hosted formatter `Lyric.Fmt` (M5.3 stages 2–5);
    three files: `fmt.l`, `fmt_core.l`, `fmt_items.l`.
  - `test_synth/test_synth.l` — `Lyric.TestSynth` rewriter (see above).
  - `test_synth_bridge.l` — `Lyric.TestSynthBridge` protocol bridge used
    by `SelfHostedTestSynth.fs` (D-progress-231).
  - `cli/` — `Lyric.Cli` full command dispatcher (M5.3, D-progress-260);
    split into 13 files: `cli_shared.l` (helpers), `cli_build.l`,
    `cli_run.l`, `cli_fmt.l`, `cli_lint.l`, `cli_prove.l`, `cli_doc.l`,
    `cli_restore.l`, `cli_publish.l`, `cli_test.l`, `cli_bench.l`,
    `cli_openapi.l`, `cli_main.l` (dispatcher).  Handles all CLI commands:
    `build`, `run`, `fmt`, `lint`, `prove` (including `--json`,
    `--explain`, `--goal`), `doc`, `public-api-diff`, `restore`, `publish`,
    `repl`, `test`, `bench`, `openapi`, `lsp` (dispatched into
    `Lyric.Lsp.lspRunLoop`), and `--version`.  Also handles the internal
    flag `--internal-perpackage-build <entry.l> <outDir> [--target jvm]`
    (emit a driver's transitive `Std.*` import closure into per-package
    `Lyric.Stdlib.<X>.dll` assemblies; used by the self-hosted stdlib build
    pipeline, not user-facing).  Wired as the primary dispatcher via
    `SelfHostedCli.fs`.
  - `repl/repl.l` — `Lyric.Repl` interactive REPL (D-progress-260).
    Script-accumulation loop; entry point `pub func runRepl(argv)`.
    `lyric repl` routes through this package via `SelfHostedCli`.
  - `emitter.l` — `Lyric.Emitter` self-hosted emitter shim (D-progress-260).
    Shells out to `--internal-build` to compile Lyric source from within
    the self-hosted CLI.
  - `contract_meta.l` — `Lyric.ContractMeta` package (D-progress-260,
    D-progress-300 in-process JSON parser, D-progress-302 in-process
    resource readers).  Reads embedded `Lyric.Contract` metadata from
    compiled DLLs in-process via `Std.AssemblyResources` (no subprocess
    hop), parses to structured `Contract` / `ContractDecl`, and diffs
    public API surfaces for `public-api-diff`.
  - `contract_meta_emit.l` — `Lyric.ContractMetaEmit` package
    (D-progress-471 / docs/45).  Emits contract metadata version 3 with
    SHA-256 integrity hashing via a two-pass protocol: serializes with blank
    contractHash, computes SHA-256 of the blank JSON, then re-serializes with
    hash embedded.  Public entry point: `emitContractMetadata(contract): String`.
  - `contract_meta_emit_self_test.l` — `@test_module` covering the two-pass
    hashing protocol and JSON structure consistency (`testEmitSimpleContract`,
    `testHashConsistency`).  **Currently not wired into CI** — requires the
    in-process MSIL bridge to load `Lyric.ContractMeta` (a compiler package)
    when running via `lyric test`.  Tracked in issue #2580.
  - `restored_packages.l` — `Lyric.RestoredPackages` package
    (#1229 Phase A.3.2, D-progress-303).  Composes the contract-meta
    in-process readers into a single
    `loadRestoredPackage(dllPath): Result[List[RestoredArtifact], RestoredLoadError]`
    entry point for the self-hosted MSIL bridge's restored-dependency
    resolution path.  Mirrors
    `bootstrap/src/Lyric.Emitter/RestoredPackages.fs::loadRestoredPackage`.
  - `verifier/` — `Lyric.Verifier` package (M5.3, D-progress-234).  Self-hosted
    port of the Phase 4 proof system: `vcir.l` (VC IR types), `vcgen.l`
    (WP/SP calculus, loop invariant goals, Hoare call rule), `smt.l`
    (SMT-LIB v2.6 renderer), `solver.l` (trivial syntactic discharger),
    `driver.l` (`prove(source): VerifySummary` entry point).  The
    driver invokes `Lyric.Weaver.weaveFile` before VC generation so
    proofs discharge against the woven body (D-progress-292 / #336).
  - `stubbable.l` — `Lyric.Stubbable` AST transform (D-progress-433): for each
    non-generic `@stubbable` interface, appends a synthesised `Stub` record +
    `impl` before type-check; entry point `stubbableRewriteFile(file): SourceFile`.
    For each supported method, the synthesised record adds a `_value` field (for
    non-Unit returns) and a `_counter: StubCounter = makeStubCounter()` field;
    the `impl` increments the counter on entry before returning the value.
    `import Std.Testing.Mocking` is injected automatically (deduplicated) whenever
    any stub is synthesised, so `StubCounter` / `makeStubCounter()` /
    `stubCounterIncrement` are always in scope without requiring the user to add
    the import.  Generic interfaces, `Self`-bearing and async methods are skipped.
  - `weaver/weaver.l` — `Lyric.Weaver` package (D-progress-292).
    Self-hosted port of `bootstrap/src/Lyric.Emitter/Weaver.fs`.
    Replaces each aspect-matched IFunc with a renamed
    `__aspect_target` plus a wrapper carrying the composed
    (aspect ++ target) contracts; called from the verifier driver
    so `lyric prove` sees the woven body (#336).
  - `lexer_self_test.l`, `parser_self_test.l`,
    `typechecker_self_test.l`, `modechecker_self_test.l`,
    `contract_elaborator_self_test.l`, `cfg_self_test.l`,
    `derives_self_test.l`, `mono_self_test.l`, `fmt_self_test.l`,
    `result_generic_specialization_self_test.l`, `stubbable_self_test.l` —
    `@test_module` self-tests run in CI via native `lyric test`
    (linking the compiler DLLs as restored deps, #2364 / D-progress-456);
    their former F# `SelfHosted*Tests.fs` wrappers were deleted.
  - `test_synth_self_test.l`, `manifest_self_test.l`,
    `contract_meta_self_test.l`, `restored_packages_self_test.l`,
    `verifier_self_test.l`, `generator/generator_self_test.l` —
    `func main` self-test consumers still run by the F# emitter test suite
    via `SelfHosted*Tests.fs`; their migration to native `lyric test` is
    deferred (each surfaces a real self-hosted gap, tracked in #2580).
  - `weaver_self_test.l` — `@test_module` covering the todo/06
    weaver features (config wiring #683, call context #682,
    `@inline_template` #681) plus regression cases for the
    duplicate-key crash (#1296) and duplicate-diagnostic
    emission (#1299).  **Currently not wired into CI** —
    requires the in-process MSIL bridge to load
    `lyric-compiler/lyric/**/*.l` so the test's `Lyric.Weaver`
    imports resolve when run via `lyric test`.  Tracked in
    issue #1324.  Manual-run instructions are in the test
    file's header.
  - `weaver_ci_test.l` — regular `func main(): Int` companion program
    (not `@test_module`) that exercises the same three todo/06 weaver
    features: config-block prelude injection (A0044 on missing default),
    call-context short-name injection (A0043 on unknown field), and
    `@inline_template` argument rewriting (A0042 on arity mismatch).
    Written as a plain program so it can be compiled and run without `Lyric.TestSynth` rewriting.
    **Not yet wired into CI** — pending the `lyric test` infrastructure
    in #1324 that would let the CI runner resolve `Lyric.Weaver` imports.
    Manual-run instructions are in the file's header.
  - `bitwise_self_test.l` — `@test_module` and the first executable
    regression test for a self-hosted-only *language feature*: the
    bitwise integer methods `.and/.or/.xor/.shl/.shr` (#1610).  Run in
    CI via native `lyric test` (issue #1611) on **both targets**:
    `--target dotnet` compiles it in-process through the self-hosted
    `Msil.Bridge`; `--target jvm` compiles it in-process through the
    self-hosted `Jvm.Bridge` (`compileToJarBundled` bundles the user
    package plus its transitive stdlib-import closure into one runnable
    JAR) and runs it under `java`.  Both assert every runtime value.
    Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed. The JVM path required a round of
    JVM-backend hardening (expression-position if/match/try, union
    field binding, i64 literals, comparison materialization, basic-block
    stackmap frames, String predicate methods).
  - `aspect_weave_self_test.l` — `@test_module` end-to-end regression test
    for aspect weaving (#3402).  Runs real woven functions and asserts
    runtime values: out-variable `ret = proceed()` advice (the headline
    #3402 form that produced `InvalidProgramException` before the weaver
    lowered the `around(...) -> ret` binding), the `call.proceed()` library-
    template spelling, short-circuit advice (target not run), a
    `call.shortName`-gated proceed, expression-style advice, and a
    `Unit`-returning woven function.  Run in CI via native `lyric test` on
    **both targets** (like `bitwise_self_test.l`): `--target dotnet` through
    `Msil.Bridge`, `--target jvm` through `Jvm.Bridge` `compileToJarBundled`.
    Imports only `Std.*` (no `LYRIC_LOAD_COMPILER=1`).
    Cross-package `from`-instance library aspects are now supported by the
    weaver (D-progress-525, #3414); `aspect_weave_self_test.l` does not yet
    exercise the multi-file scenario where a consumer package imports a
    library template — a runtime test is tracked separately (#3498).
  - `auto_ffi_self_test.l` — `@test_module` covering self-hosted
    metadata-based auto-FFI resolution (epic #1622, Phase 3c): the MSIL
    emitter resolves `ExternTypeName.method(args)` calls from real .NET
    reference-assembly metadata (`Msil.MetadataReader`) at compile time
    and emits the real MemberRef instead of the legacy guess.  Run in CI
    via native `lyric test` (compiles `extern type Math = "System.Math"` /
    `Math.Max(2,5)` through the self-hosted `Msil.Bridge`, whose codegen
    reads the reference pack at compile time, then asserts the runtime
    values).  Imports only `Std.*`.
  - `auto_ffi_jvm_self_test.l` — `@test_module` covering the JVM analog of
    epic #1622: the self-hosted JVM emitter resolves
    `extern type T = "java.lang.Math"` / `T.method(args)` calls from real JDK
    metadata at compile time and emits the real
    `invokestatic owner.name(desc)` (static), `invokevirtual` (instance), or
    `new + invokespecial <init>` (constructor via `T.new(args)`) instead of the
    legacy `([Object…])Object` guess.  Also covers Maven/non-JDK JAR resolution
    via `LYRIC_FFI_JARS`.  The resolver (`lyric-compiler/jvm/auto_ffi.l`
    + `zip_reader.l` + `class_reader.l` + `deflate.l`) is a pure-Lyric stack
    that reads the `.class` entry straight out of `java.base.jmod` (a ZIP of
    DEFLATE-compressed class files behind a 4-byte JMOD magic header),
    enumerating entries via the ZIP **central directory** (JMOD entries use
    streaming data descriptors, so local-header sizes are zero) and scoring
    overloads in `Jvm.AutoFfi.findBestMethod` / `findBestConstructor`.  Run in
    CI via native `lyric test --target jvm` (compiles the module in-process
    through the self-hosted `Jvm.Bridge` `compileToJarBundled` and runs it
    under `java`).  Imports only `Std.*`.
  `Lyric` is registered as a built-in head in `Emitter.fs:isBuiltinHead`,
  so `import Lyric.<X>` resolves under this directory.  The
  `Lyric.<X>` namespace is reserved for the self-hosted compiler
  tree alone; do not add unrelated packages here.
  Phase 5 §M5.1 stage 5' (D-progress-130) layers a red/green CST on
  top of the self-hosted lexer + parser: `SpannedToken.leadingTrivia`
  preserves whitespace, newlines, and non-doc comments; the parser
  builds a `GreenNode` tree alongside the AST at the
  file/import/item/annotation granularity and exposes it as
  `ParseResult.cst` (with `ParseResult.source` for byte-faithful
  reconstruction via `nodeSourceText`).  CST types and the
  event-based builder live in
  `lyric-compiler/lyric/parser/parser_cst.l`.
- `bootstrap/src/Lyric.Cli/` — bootstrap-only entry point.  Track A
  A1.4 (#860) deleted the F# user-facing CLI dispatcher; every user
  command (`lyric build`, `lyric run`, `lyric fmt`, `lyric publish`,
  `lyric restore`, `lyric prove`, `lyric doc`, `lyric lint`,
  `lyric test`, `lyric bench`, `lyric openapi`, …) now flows through
  the **AOT entry-point project** at `bootstrap/src/Lyric.Cli.Aot/`,
  which trampolines straight into the Lyric-emitted
  `Lyric.Cli.Program.main` (in `Lyric.Lyric.Cli.dll`, produced by
  `bootstrap.sh -stage 1`).  What remains in this project:
  - `Program.fs` — bootstrap entry; only handles the three internal
    flags `--internal-build`, `--internal-project-build`,
    `--internal-contract-meta`, plus `--internal-manifest-build`
    (used by stage 1 to compile the multi-package stdlib bundle).
    Any other argv prints a one-line error pointing at the AOT
    binary and exits non-zero.
  - `Manifest.fs` — TOML parser for `lyric.toml`; consumed by
    `--internal-manifest-build`.  Self-hosted equivalent lives in
    `lyric-compiler/lyric/manifest.l`.
  - `SelfHostedBridge.fs` / `SelfHostedMsil.fs` / `SelfHostedJvm.fs` —
    test-infrastructure shims that drive the self-hosted MSIL / JVM
    pipeline in-process via reflection.  Used by
    `bootstrap/tests/Lyric.Cli.Tests/SelfHosted{Msil,Jvm}BridgeTests.fs`.
- `bootstrap/tests/Lyric.Emitter.Tests/` — test project that hosts and runs self-hosted self-tests.

### Other top-level directories

These directories exist at the repo root alongside `bootstrap/`, `lyric/`,
`lyric-stdlib/`, `book/`, and `docs/`:

- `lyric-cache/` — `lyric-cache` library: in-memory and disk-backed
  caching utilities (D-progress-225 / D056).
- `lyric-db/` — `lyric-db` library: typed SQL query helpers over
  `System.Data` / JDBC (D-progress-225 / D056).
- `lyric-health/` — `lyric-health` library: health-check endpoint
  and liveness/readiness probe helpers (D-progress-225 / D056).
- `lyric-logging/` — `lyric-logging` library: structured logging
  adapters (`Lyric.Logging`) backed by `Std.Log` (D-progress-222 / D054).
- `lyric-otel/` — `lyric-otel` library: OpenTelemetry trace and metric
  exporters (D-progress-221 / D055); OTLP exporter (`OTel.Otlp` package) added
  in D069 — exports traces/metrics/logs to any OTLP collector via gRPC or
  HTTP/protobuf transport using the OTel .NET SDK pipeline.
- `lyric-proto/` — `lyric-proto` library: pure-Lyric Protocol Buffer (proto3)
  wire-format encoder and decoder (D067).  Kernel helpers: ProtoBuffer
  (MemoryStream accumulator) + IEEE 754 bit extraction (BitConverter).  Used
  by lyric-grpc for payload framing and available directly for manual OTLP or
  other protobuf message construction.
- `lyric-grpc/` — `lyric-grpc` library: general-purpose gRPC client (D068).
  Wraps `Grpc.Net.Client` on .NET with a pass-through `byte[]` marshaller;
  `io.grpc.ManagedChannel` on JVM (Phase 6).  Accepts and returns raw
  `slice[Byte]` payloads — compose with lyric-proto for protobuf encoding.
- `lyric-web/` — `lyric-web` library: HTTP server framework
  (`Lyric.Web`) built on `Std.Http` (D-progress-223 / D057).
- `lyric-mq/` — `lyric-mq` library: transport-agnostic message queue
  (`Lyric.Mq`). RabbitMQ, Azure Service Bus, SQS, and Kafka via feature
  flags; `MessageQueue`/`QueueConsumer`/`DeadLetterStore` interfaces;
  `Idempotent` and `DeadLetter` aspect templates; .NET and JVM kernel
  boundaries.
- `lyric-jobs/` — `lyric-jobs` library: background job scheduling
  (`Lyric.Jobs`). Hangfire and Quartz.NET backends; `JobHandler`/
  `JobScheduler` interfaces; `InProcessJobScheduler` for tests;
  `Retryable` and `Timed` aspects.
- `lyric-mail/` — `lyric-mail` library: email sending (`Lyric.Mail`).
  SMTP (MailKit), Amazon SES, and SendGrid providers; typed
  `EmailMessage`/`EmailAddress`/`Attachment`; `sendSimple`/`sendHtml`
  helpers.
- `lyric-storage/` — `lyric-storage` library: object storage
  (`Lyric.Storage`). S3, Azure Blob, and local filesystem backends;
  `StorageBucket` interface with put/get/delete/list/presignedUrl/exists;
  `AuditAccess` and `ValidateKey` aspects.
- `lyric-auth/` — `lyric-auth` library: transport-agnostic authentication
  (`Auth`). JWT verification (`verifyJwt`) with algorithm pinning (RFC 8725
  §3.1; prevents alg=none forgery and HS256/RS256 confusion); claim extraction
  (`extractClaim`); constant-time API key comparison (`verifyApiKey`); role
  allow-list helper (`rolesContain`). `.NET` and JVM backends via
  `Auth.Kernel.Net` / `Auth.Kernel.Jvm`.
- `lyric-resilience/` — `lyric-resilience` library: retry and circuit-breaker
  aspect templates (`Lyric.Resilience`). `Retry` aspect template with
  configurable `maxAttempts`, `initialDelayMs`, `maxDelayMs` (cap), and
  `jitterFraction` (uniform jitter, default 10 %); `CircuitBreaker` aspect
  template with `failureThreshold` and `cooldownMs`; `backoffDelay` helper.
  Applies to functions returning `Result[T, String]`.
- `lyric-validation/` — `lyric-validation` library: declarative input
  validation (`Lyric.Validation`). String and numeric combinators;
  `combine`/`all`/`toResult` helpers; `ValidateInput` and `ValidateEmail`
  aspects. Distinct from contract `requires:` — produces user-facing
  error messages.
- `lyric-ws/` — `lyric-ws` library: WebSocket server (`Lyric.Ws`).
  ASP.NET Core WebSockets on .NET, Undertow on JVM (Phase 6);
  `WsHandler`/`WsRegistry` interfaces; `WsAuth` and `WsRateLimit`
  aspects.
- `lyric-session/` — `lyric-session` library: distributed session
  management (`Lyric.Session`). Redis-backed (StackExchange.Redis) and
  in-process stores; `SessionStore` interface; session config (TTL,
  cookie name, SameSite, Secure, HttpOnly).
- `lyric-search/` — `lyric-search` library: search engine integration
  (`Lyric.Search`). Elasticsearch (Elastic.Clients.Elasticsearch) and
  Meilisearch backends; `SearchClient` interface with index/search/
  suggest/delete/createIndex.
- `lyric-feature-flags/` — `lyric-feature-flags` library: runtime feature
  toggles (`Lyric.Flags`). In-process and remote (HTTP polling) stores;
  `FlagGated` aspect; `getBool`/`getString`/`getInt` typed accessors.
- `lyric-i18n/` — `lyric-i18n` library: internationalization (`Lyric.I18n`).
  `TranslationStore` interface; `{placeholder}` variable substitution;
  locale fallback chain; JSON-based translation loading; BCP 47 locale
  parsing.
- `lyric-testing/` — `lyric-testing` library: test helpers and mocks
  (`Lyric.Testing`). `MockMailSender`, `MockStorageBucket`,
  `MockMessageQueue`, `MockSessionStore`, `MockFlagStore`, `TestClock`;
  `TestContext` factory; `assertOk`/`assertErr`/`assertSome`/`assertEq`/
  `assertTrue`/`assertFalse` assertion helpers.
- `lyric-vscode/` — VS Code extension (LSP client) for the Lyric language
  server (`docs/16-lsp-vscode-plan.md`).
- `resolver/` — Java-side Maven resolver JAR that the F# `MavenShim.fs`
  shell-outs to for `--target jvm` dependency resolution (D053).
- `scripts/` — build and release automation, including
  `scripts/bootstrap.sh` which implements the three-stage reproducibility
  bootstrap (F# → self-hosted → self-hosted² binary comparison).
- `examples/` — standalone Lyric example programs referenced from the
  book and README.
- `native/` — native (LLVM) backend planning documents.
  - `native/plan/` — complete implementation plan for the LLVM native backend:
    `README.md` (overview), `01-design-decisions.md` (D-N-001–D-N-013),
    `02-architecture.md` (IR types, pipeline, Hello World example),
    `03-type-mapping.md` (Lyric → LLVM IR type map),
    `04-arc-design.md` (ARC runtime, lyric_rt.h),
    `05-ffi-design.md` (extern func, NativePtr, _kernel_native/),
    `06-async-design.md` (LLVM coro.*, Phase 2 async),
    `07-stdlib-port.md` (@cfg(target=...) conditional imports),
    `08-work-items.md` (43 ordered work items, N0–N8).
    All 13 decisions are mirrored in `docs/03-decision-log.md` (D-N-001–D-N-013).
    **Agents implementing the native backend must read this directory before starting.**
    Phase 1's first slice (N0, N1, N4.1/N4.6, and the console/math/libc +
    bridge/CLI subsets) **shipped** in D-progress-540 with three plan
    corrections codified in D-N-014: the backend lives at
    `lyric-compiler/lyric/llvm_*.l` as `Lyric.Llvm*` packages (a new `Llvm`
    package head is unbootstrappable — every stage-0 seed must already
    resolve the head, and only `Lyric`/`Msil`/`Jvm`/`Std` qualify), native
    kernel selection is loader-based (`_kernel_native/<basename>` preferred
    over `_kernel/<basename>`, same package name — the `_kernel_jvm/`
    model) rather than `@cfg`-gated imports, and the entry points are
    `codegenNativePackage`/`codegenNativeBundle`/`lowerNativePackage`
    (bare-name collision with the MSIL/JVM entry points in the
    restored-bundle resolver).  Read D-N-014 and D-progress-540 alongside
    the plan.
- `lyric-rt/` — the native runtime C library (`lyric_rt.a`): ARC
  intrinsics, LyricString, NativeWeak upgrade, List/Map kernels, POSIX
  helpers, console writes.  `make -C lyric-rt` builds it;
  `make -C lyric-rt test` runs its C unit tests.  The native bridge
  resolves it via `$LYRIC_RT_PATH`, the installed `lib/` layout, or the
  dev tree (`lyric-rt/build/lyric_rt.a`).
- `lyric-stdlib/std/_kernel_native/` — native-target stdlib kernels
  (`extern func` C-symbol boundary, D-N-007): each file declares the
  SAME package as its `_kernel/` twin and wins by basename in the
  native source loader (`Lyric.Emitter.findStdlibSourcesNative`).

Build: `make lyric`.

Run tests:
```bash
# Run a specific self-test
make self-test NAME=parser

# Run the emitter tests (which hosts self-tests)
dotnet run --project bootstrap/tests/Lyric.Emitter.Tests
```

#### Iteration loops — pick the smallest one that exercises your change

A full `lyric` binary rebuild is **stage-1 (self-hosted DLLs + CLI bundle) → AOT entry-point build**. The expensive part is stage-1, so don't rebuild more than the change needs. The
`Makefile` at the repo root wraps these with the gotchas baked in
(`make help` lists every target):

- **Inner loop — front-end changes** (lexer / parser / type checker /
  mode checker / formatter).  After editing a `lyric-compiler/lyric/**`
  compiler package, rebuild only the self-hosted DLLs and run the
  relevant self-test — no AOT binary required:
  ```
  make stage1-fast              # SKIP_CLI_BUNDLE=1 ./scripts/bootstrap.sh --stage 1
  make self-test NAME=parser    # compiles parser_self_test.l vs the new DLLs (~2s)
  ```
  The `*_self_test.l` consumers (run by the Emitter suite) are the fast
  feedback path: each compiles a single `.l` against the freshly built
  stage-1 DLLs in seconds.  Prefer adding/extending a self-test over a
  full end-to-end repro.
- **End-to-end loop — CLI behaviour** (`lyric build/test/...`, ecosystem
  repros).  You need the AOT binary because user commands trampoline
  through it:
  ```
  make lyric                                  # stage1 + AOT -> ./bin/lyric
  ./bin/lyric test --manifest lyric-session/lyric.toml
  ```
  Equivalently by hand: `./scripts/bootstrap.sh --stage 1` then
  `dotnet build bootstrap/src/Lyric.Cli.Aot`.  **Rebuild both** after a
  compiler `.l` change or you'll run stale DLLs.
  `make lyric` also stages the self-hosted per-package compiler DLLs
  under `<libdir>/selfhosted/` (~80 s, #3086) — needed by `lyric test`
  for `@test_module`s that reference module-level `pub val` constants
  from compiler packages.
  Skip it with `SKIP_SELFHOSTED_COMPILER=1 make lyric` when iterating
  on something else; re-stage later with `make selfhosted-compiler`.

`scripts/bootstrap.sh` honours `$TMPDIR`, so run it with whatever `$TMPDIR` your environment sets.

All language features are implemented in the self-hosted Lyric compiler under `lyric-compiler/lyric/`. The legacy F# bootstrap compiler has been completely removed. F# is completely gone. Do not add F# files, F# tests, F# CLI dispatch, or F# externs host shims. See the "No F# code allowed" section above for the full rule and rationale.

## Glossary (project-specific terms)

- **Opaque type** — a type whose representation is invisible outside its
  package and (per design) cannot be cracked by .NET reflection.
- **Exposed record** — a flat, host-visible, reflection-friendly record;
  the wire-level counterpart of an opaque type.
- **Projectable** — an opaque type with a compiler-generated exposed twin.
- **Wire** — a `wire { ... }` block declaring a compile-time DI graph.
- **Protected type** — Ada-style structurally-locked shared mutable state.
- **Distinct type** — `type X = Long` produces a nominally distinct type;
  `alias X = Long` does not.
- **Range subtype** — a numeric type narrowed to a contiguous range
  (`type Age = Int range 0 ..= 150`).
- **Contract** — `requires` / `ensures` / `invariant`; runtime asserts in
  `@runtime_checked` modules, SMT proof obligations in `@proof_required`.
- **Module / package** — synonyms here. A package corresponds to a directory.
