# CLAUDE.md

Guidance for Claude Code (and future agents) working in this repository.

## What this repository is

Lyric is a safety-oriented application language targeting .NET. The bootstrap
compiler is written in F# and lives in `bootstrap/`. The repository contains:

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

#### Closing the originating issue when a PR merges

The auto-close logic above only runs against review-finding
issues (the `review-finding`-labeled ones the workflow files).
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

Do **not** push empty commits or trivial no-op changes to get the
check to pass — fix the actual underlying issues.  If a REQUIRED
finding is incorrect or based on a misunderstanding of the
codebase, comment on the GitHub issue explaining why, then ask the
user whether to override it.

Re-poll `get_comments` after each new push to confirm the review
verdict changed.  Declare the review loop done only when:
- The `review:changes-required` label is absent from the PR, AND
- The `Claude Code Review / claude-review` check shows green.

### F# surface is frozen — new logic goes in Lyric

The F# bootstrap compiler surface is closed to new logic. All new
functionality must be implemented in Lyric (`.l` files). The only
acceptable new F# code is thin bridge shims (`SelfHosted*.fs`) and
infrastructure that has no Lyric equivalent yet (e.g. MSBuild
integration, NuGet plumbing that talks directly to the host runtime).

Rules:

- **New stdlib modules** → `lyric-stdlib/std/<module>.l` (public) and
  `lyric-stdlib/std/_kernel/<module>_host.l` (externs, only when a BCL
  boundary is unavoidable).
- **New CLI logic** → implement in `lyric-compiler/lyric/<feature>.l`
  (as a `Lyric.<Feature>` package), expose a single string-in /
  string-out bridge function, then wire it up via a thin
  `bootstrap/src/Lyric.Cli/SelfHosted<Feature>.fs` shim that compiles
  the Lyric driver, loads the DLL by reflection, and calls the bridge.
  Follow the pattern in `SelfHostedFmt.fs`, `SelfHostedManifest.fs`,
  and `SelfHostedTestSynth.fs`.
- **New externs** → `lyric-stdlib/std/_kernel/` only; no `@externTarget`
  or `extern type` declarations outside the kernel boundary.
- **Do not** add new modules, types, or functions to any existing
  `bootstrap/src/Lyric.*/` F# project unless they are pure shim
  infrastructure with no domain logic.

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
  blocked, or when an action falls outside the scope of the assigned
  task (e.g. modifying CI policy, force-pushing, touching another
  repo).
- Honour the existing safety rules (no `--no-verify`, no force-push
  without permission, etc.) — autonomy is about throughput, not
  about side-stepping guardrails.

### Tools and build

The bootstrap compiler (Phase 1, in F# on .NET 10) lives in `bootstrap/`:

- `bootstrap/Bootstrap.sln` — the solution.
- `bootstrap/global.json` — pins SDK to 10.0.x.
- `bootstrap/Directory.Build.props` — `TargetFramework=net10.0`,
  `TreatWarningsAsErrors=true`, `Nullable=enable`.
- `.claude/hooks/session-start.sh` — bootstraps the SDK + runtime
  pinned by `bootstrap/global.json` into `~/.dotnet` so Claude Code
  on the web sessions can build / test without manual setup.
  Idempotent.
- `bootstrap/src/Lyric.Lexer/` — the lexer (Phase 1, milestone M1.1, complete).
- `bootstrap/src/Lyric.Parser/` — the parser (Phase 1, milestone M1.1, complete).
- `bootstrap/src/Lyric.TypeChecker/` — the type checker (Phase 1, milestone M1.2, complete).
- `lyric-stdlib/std/` — Lyric-language standard library source (`.l` files).
  The emitter resolves `import Std.X` by locating `lyric-stdlib/std/<x>.l` here,
  walking up from the binary's base directory or honoring `LYRIC_STD_PATH`.
  The `lyric-stdlib/std/_kernel/` subdirectory holds the audited extern boundary
  (see `docs/14-native-stdlib-plan.md` Decision F): only kernel files may
  contain `@externTarget` / `extern type` declarations.
  Key modules: `Std.Core` (Option, Result), `Std.Collections` (List, Map),
  `Std.String`, `Std.Char`, `Std.Json` (BCL-backed, `.NET`-only),
  `Std.Time` (Instant, Duration, Clock, SystemClock, toEpochMillis),
  `Std.Uuid` (newUuid, uuidToString, parseUuidOpt),
  `Std.Xml` (pure-Lyric XML 1.0 parser, cross-platform, D065),
  `Std.Yaml` (pure-Lyric YAML 1.2 + JSON parser, cross-platform, D065).
- `lyric-stdlib/tests/` — Lyric-language test suite for the stdlib. Each
  `*_tests.l` file is a standalone Lyric program that imports the modules
  it covers and asserts correctness via `Std.Testing`. The F# runner
  `bootstrap/tests/Lyric.Emitter.Tests/StdlibLyricTests.fs` discovers and
  executes these files automatically as part of the emitter test suite.
- The F# `bootstrap/src/Lyric.Stdlib/` project was deleted entirely
  (D-progress-140).  Every former `Lyric.Stdlib.*` host target has
  migrated to direct BCL externs in `lyric-stdlib/std/_kernel/*.l` or
  inline codegen, so the assembly was empty of types and adding nothing.
  The Lyric-compiled stdlib bundle (per `lyric-stdlib/lyric.toml`) now ships
  as `Lyric.Stdlib.dll` directly — the SDK's `lib/Lyric.Stdlib.dll` is
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
    prints TAP-shaped output.  Mirrors the F# `bootstrap/src/Lyric.Cli/TestSynth.fs`
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
  - `cli.l` — `Lyric.Cli` full command dispatcher (M5.3, D-progress-260).
    Handles all CLI commands: `build`, `run`, `fmt`, `lint`, `prove`
    (including `--json`, `--explain`, `--goal`), `doc`, `public-api-diff`,
    `restore`, `publish`, `repl`, `test`, `bench`, `openapi`, and
    `--version`.  Wired as the primary dispatcher via `SelfHostedCli.fs`.
  - `repl/repl.l` — `Lyric.Repl` interactive REPL (D-progress-260).
    Script-accumulation loop; entry point `pub func runRepl(argv)`.
    `lyric repl` routes through this package via `SelfHostedCli`.
  - `emitter.l` — `Lyric.Emitter` self-hosted emitter shim (D-progress-260).
    Shells out to `--internal-build` to compile Lyric source from within
    the self-hosted CLI.
  - `contract_meta.l` — `Lyric.ContractMeta` package (D-progress-260).
    Reads embedded `Lyric.Contract` metadata from compiled DLLs and diffs
    public API surfaces for `public-api-diff`.
  - `verifier/` — `Lyric.Verifier` package (M5.3, D-progress-234).  Self-hosted
    port of the Phase 4 proof system: `vcir.l` (VC IR types), `vcgen.l`
    (WP/SP calculus, loop invariant goals, Hoare call rule), `smt.l`
    (SMT-LIB v2.6 renderer), `solver.l` (trivial syntactic discharger),
    `driver.l` (`prove(source): VerifySummary` entry point).
  - `lexer_self_test.l`, `parser_self_test.l`,
    `typechecker_self_test.l`, `modechecker_self_test.l`,
    `contract_elaborator_self_test.l`, `test_synth_self_test.l`,
    `manifest_self_test.l`, `fmt_self_test.l`, `verifier_self_test.l` —
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
  `lyric-compiler/lyric/parser/parser_cst.l`.  The F# bootstrap
  parser/lexer are deliberately untouched.
- `bootstrap/src/Lyric.Cli/` — the `lyric` command-line tool. `Manifest.fs`
  parses `lyric.toml`; `Pack.fs` lowers it to a generated `.csproj` for
  `lyric publish` / `lyric restore`; `Program.fs` is the command dispatch.
  `lyric build --manifest <lyric.toml>` resolves `import <Pkg>` declarations
  against restored Lyric packages (D-progress-078) via the
  `Lyric.Emitter.RestoredPackages` module, which reads each restored DLL's
  embedded `Lyric.Contract` resource (D-progress-031) and feeds the surface
  into the existing import pipeline.  `lyric prove <source.l>` runs the
  Phase 4 verifier (M4.1 fragment).  `lyric fmt` routes through the
  self-hosted `Lyric.Fmt` package via `SelfHostedFmt.fs` (in-process
  compile + reflection): walks the red/green CST, preserves `//` and
  `/* */` comments at item / member / statement / nested-block
  boundaries, preserves intentional blank lines (max one per spot,
  Black-style), width-driven multi-line expression layout at 120-char
  budget.  `--write` and `--check` flags.  `Lint.fs` is the linter
  (`lyric lint`): five AST-only rules (L001–L005), `--error-on-warning`
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
  - `SelfHostedCli.fs` — primary CLI dispatcher bridge; compiles a tiny
    `Lyric.CliBridge` driver, loads `Lyric.Lyric.Cli.dll` by reflection,
    and dispatches all CLI commands through `Lyric.Cli.Program.main`.
    Falls back to the F# bootstrap dispatcher only on bridge failure
    (compile or reflection error).
- The Phase 4 proof system (`Lyric.Verifier`) is fully self-hosted in
  `lyric-compiler/lyric/verifier/` (see entry above).  The F# `Lyric.Verifier`
  project and its test project have been deleted; `lyric prove` routes
  through the self-hosted verifier via `SelfHostedCli.fs`.
- `bootstrap/tests/Lyric.Lexer.Tests/`, `bootstrap/tests/Lyric.Parser.Tests/`,
  `bootstrap/tests/Lyric.TypeChecker.Tests/`,
  `bootstrap/tests/Lyric.Emitter.Tests/`, and
  `bootstrap/tests/Lyric.Cli.Tests/` — Expecto-based tests (console-app
  projects; F# does not coexist cleanly with the new Microsoft.Testing.Platform
  xunit runner — Expecto is the F#-native alternative).

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

Build: `cd bootstrap && dotnet build Bootstrap.sln`.

Run tests:
```
cd bootstrap
dotnet run --project tests/Lyric.Lexer.Tests
dotnet run --project tests/Lyric.Parser.Tests
dotnet run --project tests/Lyric.TypeChecker.Tests
dotnet run --project tests/Lyric.Emitter.Tests
dotnet run --project tests/Lyric.Cli.Tests
```

M1.4 shipped contract elaboration, async, FFI, variant-bearing unions,
interfaces, and monomorphised generics in the F# bootstrap emitter.
One construct remains bootstrap-grade per `docs/03-decision-log.md` D035:
FFI is hand-routed through BCL externs instead of reflection-driven.
Async ships with real `IAsyncStateMachine` state machines (Phase A–B+++,
D-progress-033..260), including `IAsyncEnumerable<T>` generator synthesis.
All new language features beyond this point are implemented in the
self-hosted Lyric compiler under `lyric/` — the F# surface is
frozen to bootstrap shims only.

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
