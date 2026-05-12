# CLAUDE.md

Guidance for Claude Code (and future agents) working in this repository.

## What this repository is

Lyric is a safety-oriented application language targeting .NET. The bootstrap
compiler is written in F# and lives in `compiler/`. The repository contains:

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
- `docs/10-bootstrap-progress.md` — append-only log of shipped milestones.
- `docs/10-stdlib-plan.md` — standard library module design and stability cut plan.
- `docs/11-stdlib-examples.md` — worked examples that exercise the standard library.
- `docs/12-todo-plan.md` — running task list for in-flight and upcoming work.
- `docs/13-tutorial.md` — narrative tutorial walking from hello-world to contracts.
- `docs/14-native-stdlib-plan.md` — `stdlib/std/_kernel/` extern-boundary design.
- `docs/15-phase-4-proof-plan.md` — Phase 4 verifier design (VC IR, SMT bridge).
- `docs/16-lsp-vscode-plan.md` — LSP server and VS Code extension plan.
- `docs/17-axiom-audit.md` — audit checklist for `@axiom` declarations.
- `docs/18-jvm-emission.md` — JVM bytecode emission strategy (Phase 6; self-hosted Lyric emitter shipped in `compiler/lyric/jvm/`).
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

#### Watching an open PR

`.github/workflows/auto-rebase.yml` rebases every open PR onto `main`
on each push to `main`, but it only performs *clean* rebases — if a
PR has conflicts the action skips it and the branch stays in a
conflicted state.  Don't wait for the user to flag the conflict.

Treat **any of these signals** as a cue to fetch `main` and rebase
the open PR:

- A `<github-webhook-activity>` event arrives mentioning the PR (in
  particular: a new push or a CI failure on a PR that previously
  passed).
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
  This is where the `claude-review` GitHub App posts its
  findings.

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

### Style

- No emojis in any file unless the user asks.
- No new markdown documents unless the user asks for one.
- Prefer editing existing files to creating new ones.
- Don't write code comments that restate what code does — only comments
  for non-obvious *why*.

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
- If a stage hits a real blocker (missing decision, ambiguous spec,
  external dependency), park it with a clear note and move on to the
  next independent stage rather than stopping the session.
- Only stop and ask the user when **every** remaining task is
  blocked, or when an action falls outside the scope of the assigned
  task (e.g. modifying CI policy, force-pushing, touching another
  repo).
- Honour the existing safety rules (no `--no-verify`, no force-push
  without permission, etc.) — autonomy is about throughput, not
  about side-stepping guardrails.

### Tools and build

The bootstrap compiler (Phase 1, in F# on .NET 10) lives in `compiler/`:

- `compiler/Lyric.sln` — the solution.
- `compiler/global.json` — pins SDK to 10.0.x.
- `compiler/Directory.Build.props` — `TargetFramework=net10.0`,
  `TreatWarningsAsErrors=true`, `Nullable=enable`.
- `.claude/hooks/session-start.sh` — bootstraps the SDK + runtime
  pinned by `compiler/global.json` into `~/.dotnet` so Claude Code
  on the web sessions can build / test without manual setup.
  Idempotent.
- `compiler/src/Lyric.Lexer/` — the lexer (Phase 1, milestone M1.1, complete).
- `compiler/src/Lyric.Parser/` — the parser (Phase 1, milestone M1.1, complete).
- `compiler/src/Lyric.TypeChecker/` — the type checker (Phase 1, milestone M1.2, complete).
- `stdlib/std/` — Lyric-language standard library source (`.l` files).
  The emitter resolves `import Std.X` by locating `stdlib/std/<x>.l` here,
  walking up from the binary's base directory or honoring `LYRIC_STD_PATH`.
  The `stdlib/std/_kernel/` subdirectory holds the audited extern boundary
  (see `docs/14-native-stdlib-plan.md` Decision F): only kernel files may
  contain `@externTarget` / `extern type` declarations.
- `stdlib/tests/` — Lyric-language test suite for the stdlib. Each
  `*_tests.l` file is a standalone Lyric program that imports the modules
  it covers and asserts correctness via `Std.Testing`. The F# runner
  `compiler/tests/Lyric.Emitter.Tests/StdlibLyricTests.fs` discovers and
  executes these files automatically as part of the emitter test suite.
- The F# `compiler/src/Lyric.Stdlib/` project was deleted entirely
  (D-progress-140).  Every former `Lyric.Stdlib.*` host target has
  migrated to direct BCL externs in `stdlib/std/_kernel/*.l` or
  inline codegen, so the assembly was empty of types and adding nothing.
  The Lyric-compiled stdlib bundle (per `stdlib/lyric.toml`) now ships
  as `Lyric.Stdlib.dll` directly — the SDK's `lib/Lyric.Stdlib.dll` is
  this bundle, not the retired F# shim.
- `compiler/src/Lyric.Emitter/` — the MSIL emitter (Phase 1, milestone M1.3,
  complete). Lowers a parsed + type-checked Lyric source to a `dotnet exec`-
  runnable PE via `System.Reflection.Emit`'s `PersistedAssemblyBuilder` and
  `ManagedPEBuilder`.
- `compiler/lyric/lyric/` — the **self-hosted Lyric compiler** sources.
  M5.1 (lexer / parser / type checker / CST) and M5.2 stages 1–2
  (mode checker, contract elaborator) have shipped:
  - `lexer.l` — full self-hosted lexer: identifiers (NFC-normalised,
    UAX #31 XID_Start/Continue), keyword table, all integer/float
    literal forms, plain/interpolated/triple/raw strings, character
    literals (BMP `\u{…}`), punctuation, line and nested block
    comments, doc/module-doc comments, statement-end insertion, and
    diagnostics L0001–L0040 (PR #190, D-progress-093–D-progress-121).
  - `ast.l` — self-hosted AST type declarations mirroring `Ast.fs`
    (PR #185).
  - `parser/` — self-hosted parser as a five-file `Lyric.Parser`
    library: `parser_ast.l`, `parser_core.l`, `parser_exprs.l`,
    `parser_items.l`, `parser_cst.l` (PR #190, D-progress-128;
    CST layer added in D-progress-130).
  - `type_checker/` — self-hosted type checker `Lyric.TypeChecker`
    (PR #195, D-progress-132); nine files: `typechecker_checker.l`,
    `typechecker_constfold.l`, `typechecker_exprs.l`,
    `typechecker_resolver.l`, `typechecker_scope.l`,
    `typechecker_signature.l`, `typechecker_stmts.l`,
    `typechecker_symbols.l`, `typechecker_types.l`.
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
    prints TAP-shaped output.  Mirrors the F# `compiler/src/Lyric.Cli/TestSynth.fs`
    (which the F# CLI still calls today; routing `lyric test` through
    this Lyric implementation is a follow-up stage, matching the
    formatter's pattern in D-progress-131).
  - `mono.l` — `Lyric.Mono` monomorphizer (M5.2 stage 4, D-progress-229).
    Call-site monomorphizer for generic functions defined in the same
    compilation unit.  Collects all generic `IFunc` items, walks non-generic
    bodies to infer concrete type arguments (from literals and explicitly-
    annotated variables), produces specialised copies (e.g. `mapFoo__Int__String`),
    and rewrites call sites.  Public entry: `monoFile(file): MonoResult`.
  - `manifest.l` — `Lyric.Manifest` TOML parser for `lyric.toml`
    (M5.3 stage 1, D-progress-129).  Parses the subset of TOML used by the
    Lyric package system (`[package]`, `[project]`, `[dependencies]`,
    `[nuget]`, `[nuget.options]`, `[features]`).
  - `manifest_bridge.l` — `Lyric.ManifestBridge` protocol bridge used by
    `SelfHostedManifest.fs` (D-progress-231).
  - `fmt/` — self-hosted formatter `Lyric.Fmt` (M5.3 stages 2–5);
    three files: `fmt.l`, `fmt_core.l`, `fmt_items.l`.
  - `test_synth/test_synth.l` — `Lyric.TestSynth` rewriter (see above).
  - `test_synth_bridge.l` — `Lyric.TestSynthBridge` protocol bridge used
    by `SelfHostedTestSynth.fs` (D-progress-231).
  - `cli.l` — `Lyric.Cli` command-dispatch stub (M5.3 stage 1).
  - `lexer_self_test.l`, `parser_self_test.l`,
    `typechecker_self_test.l`, `modechecker_self_test.l`,
    `contract_elaborator_self_test.l`, `test_synth_self_test.l`,
    `manifest_self_test.l`, `fmt_self_test.l` —
    self-test consumers run by the F# emitter test suite.
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
  `compiler/lyric/lyric/parser/parser_cst.l`.  The F# bootstrap
  parser/lexer are deliberately untouched.
- `compiler/src/Lyric.Cli/` — the `lyric` command-line tool. `Manifest.fs`
  parses `lyric.toml`; `Pack.fs` lowers it to a generated `.csproj` for
  `lyric publish` / `lyric restore`; `Program.fs` is the command dispatch.
  `lyric build --manifest <lyric.toml>` resolves `import <Pkg>` declarations
  against restored Lyric packages (D-progress-078) via the
  `Lyric.Emitter.RestoredPackages` module, which reads each restored DLL's
  embedded `Lyric.Contract` resource (D-progress-031) and feeds the surface
  into the existing import pipeline.  `lyric prove <source.l>` runs the
  Phase 4 verifier (M4.1 fragment).  `Fmt.fs` is the legacy AST-based
  formatter (`lyric fmt --legacy` or `LYRIC_FMT_LEGACY=1`): canonical
  style rules, `--write`/`--check` flags; non-doc `//` comments are
  not preserved.  The default `lyric fmt` path (M5.3 stages 2–5)
  routes through the self-hosted `Lyric.Fmt` package via
  `SelfHostedFmt.fs` (in-process compile + reflection): walks the
  red/green CST, preserves `//` and `/* */` comments at item /
  member / statement / nested-block boundaries, preserves intentional
  blank lines (max one per spot, Black-style).  `Lint.fs` is the
  linter (`lyric lint`): five AST-only rules (L001–L005), `--error-on-warning`
  flag, runs on non-compiling code.  Additional modules in the same project:
  - `Doc.fs` — `lyric doc` documentation generator.
  - `Maven.fs` / `MavenShim.fs` — Maven Central dependency resolution and
    JAR discovery for `--target jvm` builds; backed by the Java-side
    `resolver/` JAR (D-progress-224 / D-progress-225 / D053).
  - `NugetAssets.fs` / `NugetShim.fs` — NuGet asset resolution, DLL path
    extraction from `project.assets.json`, and extern shim generation
    (D-progress-075 / D-progress-078 / D023).
  - `TestSynth.fs` — F# implementation of the test-synthesis rewriter
    (backs `lyric test`; self-hosted mirror is `Lyric.TestSynth`).
  - `SelfHostedJvm.fs` — in-process JVM bridge; reflects
    `Jvm.Bridge.Program.compileToJar` for `--target jvm` (D-progress-239).
  - `SelfHostedManifest.fs` — in-process manifest bridge; reflects
    `Lyric.ManifestBridge.Program.serializeManifest` (D-progress-231).
  - `SelfHostedMsil.fs` — in-process MSIL bridge; reflects
    `Msil.Bridge.Program.compileToMsil` for `--target dotnet` (D-progress-227 /
    D-progress-240).
  - `SelfHostedTestSynth.fs` — in-process test-synth bridge; reflects
    `Lyric.TestSynthBridge.Program.synthesizeToProtocol` (D-progress-231).
- `compiler/src/Lyric.Verifier/` — the Phase 4 proof system (M4.1+;
  see `docs/15-phase-4-proof-plan.md` and the D-progress-084/085
  entries in `docs/10-bootstrap-progress.md`).  `Mode.fs` parses
  `@runtime_checked` / `@proof_required[(modifier)]` / `@axiom`
  package-level annotations into a `VerificationLevel`.  `ModeCheck.fs`
  enforces the call-graph rules (V0002), `@axiom`-with-body (V0004),
  loops without an `invariant:` clause (V0005), and unbounded
  quantifier domains in proof-required code (V0006).  `Vcir.fs` is
  the solver-agnostic Lyric-VC IR; `Theory.fs` maps Lyric source types
  and operators to IR sorts and builtins (range subtypes lift to
  `SInt` plus a closed-range hypothesis); `VCGen.fs` runs the wp/sp
  calculus over the imperative fragment (`let`/`val` then `return`,
  `if`/`else`, `match` over wildcard / literal / bare-binding
  patterns, `assert φ`, and the Hoare call rule §10.4 — assert
  callee `requires:` at the call site, assume callee `ensures:` for
  the rest of the wp); `Smt.fs` emits SMT-LIB v2.6; `Solver.fs` ships
  a trivial syntactic discharger (closes `true`, `P ⇒ P`, reflexive
  comparisons, hypothesis matches, and conjunctions thereof) plus an
  optional `z3` shell-out (set `LYRIC_Z3` or put `z3` on `$PATH`);
  `Driver.fs` is the entry point used by `lyric prove`.  Failed
  proofs are rendered as `name : sort = value` counterexample
  bindings parsed from Z3's `(get-model)` output.  Two additional
  modules: `Imports.fs` reads the embedded `Lyric.Contract` resource
  from restored-package DLLs to surface their verification contracts
  (so `lyric prove` can reason across package boundaries); `StabilityCheck.fs`
  enforces S0001 (`@stable` code may not call `@experimental` in the
  same file) and S0002 (cross-package stability policy — currently
  a warning, deferred to Phase 3 hard enforcement).
- `compiler/tests/Lyric.Lexer.Tests/`, `compiler/tests/Lyric.Parser.Tests/`,
  `compiler/tests/Lyric.TypeChecker.Tests/`,
  `compiler/tests/Lyric.Emitter.Tests/`, `compiler/tests/Lyric.Lsp.Tests/`,
  `compiler/tests/Lyric.Cli.Tests/`, and
  `compiler/tests/Lyric.Verifier.Tests/` — Expecto-based tests (console-app
  projects; F# does not coexist cleanly with the new Microsoft.Testing.Platform
  xunit runner — Expecto is the F#-native alternative).

### Other top-level directories

These directories exist at the repo root alongside `compiler/`, `stdlib/`,
`book/`, and `docs/`:

- `lyric-cache/` — `lyric-cache` library: in-memory and disk-backed
  caching utilities (D-progress-225 / D056).
- `lyric-db/` — `lyric-db` library: typed SQL query helpers over
  `System.Data` / JDBC (D-progress-225 / D056).
- `lyric-health/` — `lyric-health` library: health-check endpoint
  and liveness/readiness probe helpers (D-progress-225 / D056).
- `lyric-logging/` — `lyric-logging` library: structured logging
  adapters (`Lyric.Logging`) backed by `Std.Log` (D-progress-222 / D054).
- `lyric-otel/` — `lyric-otel` library: OpenTelemetry trace and metric
  exporters (D-progress-221 / D055).
- `lyric-web/` — `lyric-web` library: HTTP server framework
  (`Lyric.Web`) built on `Std.Http` (D-progress-223 / D057).
- `lyric-vscode/` — VS Code extension (LSP client) for the Lyric language
  server (`docs/16-lsp-vscode-plan.md`).
- `resolver/` — Java-side Maven resolver JAR that the F# `MavenShim.fs`
  shell-outs to for `--target jvm` dependency resolution (D053).
- `scripts/` — build and release automation, including
  `scripts/bootstrap.sh` which implements the three-stage reproducibility
  bootstrap (F# → self-hosted → self-hosted² binary comparison).
- `examples/` — standalone Lyric example programs referenced from the
  book and README.

Build: `cd compiler && dotnet build Lyric.sln`.

Run tests:
```
cd compiler
dotnet run --project tests/Lyric.Lexer.Tests
dotnet run --project tests/Lyric.Parser.Tests
dotnet run --project tests/Lyric.TypeChecker.Tests
dotnet run --project tests/Lyric.Emitter.Tests
dotnet run --project tests/Lyric.Lsp.Tests
dotnet run --project tests/Lyric.Cli.Tests
dotnet run --project tests/Lyric.Verifier.Tests
```

M1.4 (in progress) layers contract elaboration, async, FFI, variant-bearing
unions, interfaces, and monomorphised generics onto the M1.3 emitter. Three
constructs ship in *bootstrap-grade* form per `docs/03-decision-log.md` D035:
generics are monomorphised at call sites instead of reified in metadata; async
is lowered to a blocking `.GetAwaiter().GetResult()` shim instead of a real
state machine; FFI is hand-routed through `Lyric.Stdlib` instead of
reflection-driven. The full lowerings are tracked into Phase 2 / Phase 4 work.

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
