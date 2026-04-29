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

There is no compiler, no test runner, no build system. Document changes
are reviewed by reading. When the bootstrap compiler exists (Phase 1),
this section will need to grow.

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
