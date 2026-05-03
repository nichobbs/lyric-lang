# CLAUDE.md

Guidance for Claude Code (and future agents) working in this repository.

## What this repository is

Lyric is a safety-oriented application language targeting .NET. **It is in
the design phase.** No compiler exists. The repository currently contains:

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

## Reading order (for Claude)

When picking up cold, follow the README's newcomer order: **00 → 02 → 01 → 03**.
For implementation work consult **05** (phasing) and **06** (open questions).
For "is this in scope?" questions consult **04**.

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
- `compiler/src/Lyric.Stdlib/` — the F#-side standard-library shim. The emitter
  targets methods on this assembly (e.g. `Lyric.Stdlib.Console::Println`) for
  IO, contract assertions, and FFI-style BCL access. Hand-curated; grows as
  M1.4 brings the banking example up to working order.
- `compiler/src/Lyric.Emitter/` — the MSIL emitter (Phase 1, milestone M1.3,
  complete). Lowers a parsed + type-checked Lyric source to a `dotnet exec`-
  runnable PE via `System.Reflection.Emit`'s `PersistedAssemblyBuilder` and
  `ManagedPEBuilder`.
- `compiler/src/Lyric.Cli/` — the `lyric` command-line tool. `Manifest.fs`
  parses `lyric.toml`; `Pack.fs` lowers it to a generated `.csproj` for
  `lyric publish` / `lyric restore`; `Program.fs` is the command dispatch.
  `lyric build --manifest <lyric.toml>` resolves `import <Pkg>` declarations
  against restored Lyric packages (D-progress-078) via the
  `Lyric.Emitter.RestoredPackages` module, which reads each restored DLL's
  embedded `Lyric.Contract` resource (D-progress-031) and feeds the surface
  into the existing import pipeline.  `lyric prove <source.l>` runs the
  Phase 4 verifier (M4.1 fragment).
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
  bindings parsed from Z3's `(get-model)` output.
- `compiler/tests/Lyric.Lexer.Tests/`, `compiler/tests/Lyric.Parser.Tests/`,
  `compiler/tests/Lyric.TypeChecker.Tests/`,
  `compiler/tests/Lyric.Emitter.Tests/`, `compiler/tests/Lyric.Lsp.Tests/`,
  `compiler/tests/Lyric.Cli.Tests/`, and
  `compiler/tests/Lyric.Verifier.Tests/` — Expecto-based tests (console-app
  projects; F# does not coexist cleanly with the new Microsoft.Testing.Platform
  xunit runner — Expecto is the F#-native alternative).

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
