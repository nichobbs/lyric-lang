# 05 — Implementation Plan

This document describes the phased implementation plan for Lyric, from current state (design v0.1) through self-hosting and ecosystem maturity.

## Overall trajectory

| Phase | Goal | Duration (est.) | Cumulative |
|---|---|---|---|
| 0 | Design freeze, language reference v0.1 | 3-6 months | 6 mo |
| 1 | Bootstrap compiler MVP (subset of language) | 6-12 months | 18 mo |
| 2 | Type system completion | 6-9 months | 27 mo |
| 3 | Contracts, concurrency, DI, tooling — v1.0 ships | 9-12 months | 39 mo |
| 4 | Proof system | 12-18 months | 57 mo |
| 5 | Self-hosting | 18-24 months | 81 mo |
| 6+ | Ecosystem | open-ended | — |

For a small full-time team (3-5 engineers), v1.0 is realistic at year 3-4. With the proof system, year 4-5. Self-hosting, year 6-7.

These estimates assume a funded team. A side-project effort with a single contributor multiply by 2-3×. A solo language project should plan for v1.0 at year 5-7 and accept that it may never reach Phase 4-5.

## Phase 0: Design freeze (months 0-6)

**Goal:** Produce the artifacts that allow Phase 1 to start without churning on language design.

### Deliverables

1. **Language reference v0.1** — already in this repository at `docs/01-language-reference.md`. Iterate based on review.
2. **Decision log** — already exists at `docs/03-decision-log.md`. Append as decisions are made.
3. **Worked examples** — already exists at `docs/02-worked-examples.md`. Add 5-10 more covering edge cases.
4. **Formal grammar in BNF or similar** — does not yet exist; needs writing. Target: a parseable grammar that can be implemented unambiguously.
5. **Operational semantics for contracts** — does not yet exist. Define what `requires`/`ensures`/`invariant` *mean* in formal notation. This is the hardest single Phase 0 deliverable and the most underrated.
6. **Resolved TBD items from the language reference** — all 12 listed in §13 of the language reference.
7. **MSIL emission strategy document** — how Lyric's value types, opaque types, generics, async, and protected types lower to MSIL. Target: enough specificity that the Phase 1 implementer doesn't need to make new design decisions.

### Phase 0 review

The language reference goes out for review to:
- Compiler implementers (≥3 with experience building a language)
- Working programmers in the target user community (≥10)
- Formal methods practitioners (≥2 — for the contracts/proof story)
- People who hate verbose languages (≥2 — to surface ergonomic objections)

Iterate based on feedback. Do not start Phase 1 with unresolved fundamentals.

### Risks

- **Scope expands during review.** Mitigation: maintain the out-of-scope list; reject expansions explicitly with rationale.
- **Operational semantics is hard.** Mitigation: copy SPARK's approach where applicable; consult formal methods experts; accept that the v0.1 semantics will need refinement.
- **Decision paralysis on TBDs.** Mitigation: pick a default for each, document the alternatives, ship the default. Imperfect decisions resolved are better than perfect ones unresolved.

## Phase 1: Bootstrap compiler MVP (months 6-18)

**Goal:** Smallest language subset that can compile useful programs. Implemented in F# on .NET.

### Language subset for Phase 1

**Included:**
- Primitives (Bool, Int, Long, Double, String, Unit)
- Records (no opaque types, no projections — everything `pub` is a flat record)
- Sum types with exhaustive matching
- Functions with mode parameters
- `pub` visibility and module imports
- Generics with monomorphization (type parameters only, no value generics, no constraints — `where` clauses ignored or unsupported)
- `async` and `await` mapped to `Task<T>`
- Pattern matching with exhaustiveness
- Runtime contracts (`requires`/`ensures` as runtime asserts; no proof)
- Simple FFI via `extern` declarations

**Deferred:**
- Range subtypes (compile to underlying primitive without checks; types are distinct nominally)
- Distinct nominal types (compile to underlying primitive; only nominal-level checking)
- Opaque types (treat as records with `pub` fields invisible)
- `@projectable`, `@stubbable` (manually written DTOs and stubs)
- `protected type` (use raw locks via FFI)
- `wire` blocks (manual DI by passing dependencies)
- Property-based testing (use plain tests)
- LSP (use plain text editing; minimal CLI compiler errors)
- Formatter
- Package manager (single project, manual dependency resolution)

### Architecture

```
.l files
   │
   ▼
Lexer (F#) → Tokens
   │
   ▼
Parser (F# with FParsec or hand-written) → AST
   │
   ▼
Resolver (F#) → Resolved AST (names bound, imports resolved)
   │
   ▼
Type Checker (F#) → Typed AST
   │
   ▼
Mode Checker (F#) → Verified AST (parameter modes consistent)
   │
   ▼
Contract Elaborator (F#) → AST with assertion checks inserted
   │
   ▼
Monomorphizer (F#) → AST with generics specialized
   │
   ▼
MSIL Emitter (F# using System.Reflection.Emit or similar) → .NET assembly
```

Single-pass per file; parallel across files. No optimizations beyond what the .NET JIT provides.

### Phase 1 milestones

1. **M1.1 (month 6-9):** Lexer + parser. Can parse all the worked examples without semantic checking.
2. **M1.2 (month 9-12):** Type checker for primitives, records, sum types, generic monomorphization. Compiler accepts or rejects programs with type errors but doesn't yet emit code.
3. **M1.3 (month 12-15):** MSIL emitter. Hello World runs. Increasingly complex programs compile and run.
4. **M1.4 (month 15-18):** Contract elaboration, async, FFI to .NET BCL. The banking example (sans proof) compiles and runs. Three constructs ship in *bootstrap-grade* form (monomorphised generics, blocking-shim async, hand-curated FFI shim); see `docs/03-decision-log.md` D035 for the full scope-cut rationale and the gaps that Phase 2 / Phase 4 picks up.

### Phase 1 standard library

Hand-written in Phase-1-Lyric, very minimal:
- `std.core`: option, result, basic collections (List, Map)
- `std.io`: console, basic file IO
- `std.testing`: minimal test harness

### Exit criteria for Phase 1

- All worked examples in `docs/02-worked-examples.md` (sans proof annotations) parse, type-check, compile, and run.
- A simple HTTP service can be written end-to-end (using .NET BCL via FFI) and respond to requests.
- Compile times for a 1000-line program are under 5 seconds.
- A small group of early adopters (5-10 engineers) is using Phase 1 Lyric for non-production projects.

## Phase 2: Type system completion (months 18-27)

**Goal:** The features that make Lyric distinctively itself.

### Deliverables

- **Range subtypes** with runtime check insertion at construction
- **Distinct types** with conversion rules and `derives` clauses
- **Opaque types** with representational privacy enforcement (sealed metadata)
- **`@projectable`** with auto-generated views and conversion functions
- **Interfaces** and `impl` declarations
- **`@stubbable`** with stub builder generation
- **Generic constraints** via `where` clauses

### Standard library expansion

- `std.collections`: full Map, Set, List, Queue, immutable variants
- `std.text`: regex (RE2), encoding utilities
- `std.time`: Instant, Duration, ISO 8601, IANA tzdata bindings
- `std.json`: source-generated serializers, RFC 8259 conformant
- `std.http`: client and server primitives over .NET BCL

### Compiler architecture changes

- Type checker extended for range constraints (delegate to a constraint solver — likely a simple interval lattice for now; full SMT comes in Phase 4)
- Code generation for opaque types: emit sealed wrapper with internal field access only via package-internal helpers
- `@projectable` derive: AST transformation that emits the view type and conversion functions before main code generation
- `@stubbable` derive: similar AST transformation emitting stub builder

### Phase 2 milestones

1. **M2.1 (month 18-22):** Range subtypes and distinct types. The full money/account/transfer example from worked examples compiles with proper type distinctness.
2. **M2.2 (month 22-25):** Opaque types and `@projectable`. The boundary between domain and HTTP works as intended.
3. **M2.3 (month 25-27):** Interfaces, `@stubbable`, and standard library expansion.

### Exit criteria for Phase 2

- Full worked examples (without proof and without `protected type`) compile and run.
- The standard library is sufficient for writing a real REST API service.
- Early adopters can write production-shaped code, even if not yet for production deployment.

## Phase 3: Contracts, concurrency, DI, tooling — v1.0 (months 27-39)

**Goal:** Ship a v1.0 that real teams could adopt.

### Deliverables

- **`protected type`** with barrier semantics (no proof yet — runtime barrier evaluation)
- **Structured concurrency scopes** with cancellation
- **Wire blocks** with compile-time resolution and lifetime checking
- **Property-based testing** built in
- **Snapshot testing** built in
- **LSP server** with code completion, go-to-definition, hover, diagnostics
- **Package manager** (`lyric` CLI handling dependencies, `lyric.toml`)
- **`lyric doc`** documentation generator
- **`lyric public-api-diff`** for SemVer enforcement
- **Tutorial documentation** and a "real" Lyric book

### Compiler architecture changes

- Wire resolver: graph algorithm that takes wire declarations and produces generated factory code
- Lifetime checker for wires: rejects singleton-depends-on-scoped, etc.
- Async-local scope tracking for runtime
- Property generator framework: derives generators from invariants

### Phase 3 milestones

1. **M3.1 (month 27-30):** `protected type` and structured scopes
2. **M3.2 (month 30-33):** Wire blocks
3. **M3.3 (month 33-36):** LSP, doc generator
4. **M3.4 (month 36-39):** Package manager, polish, v1.0 release

### Exit criteria for Phase 3 / v1.0

- A team can build, test, and deploy a real production service in Lyric.
- Tooling is good enough that newcomers can be productive within a week.
- Documentation is comprehensive: language reference, tutorial, standard library reference.
- Compile times and runtime performance are competitive with C#.
- Public release. Conferences, blog posts, social work.

## Phase 4: Proof system (months 39-57)

**Goal:** Add the SMT-backed verification that distinguishes Lyric from "Kotlin with better types."

### Deliverables

- **Verification condition generator**: takes Lyric functions with contracts, produces SMT formulas
- **SMT solver integration**: Z3 or CVC5 (decide based on licensing — CVC5 is more permissive)
- **Counterexample reporting**: when a proof fails, produce a concrete input violating the contract
- **`@proof_required` module mode**: enforces that proof obligations are discharged
- **`@axiom` boundaries**: the only way to call from proof-required code into unverified code
- **Decidability fragment**: define and enforce the subset of contract expressions that can be reliably proved

### Hiring

You will hire someone with formal methods background for this phase. It's not learnable on the job at the level required. Expect to publish 1-2 academic papers on the verification approach if you want credibility in the formal methods community.

### Phase 4 milestones

1. **M4.1 (month 39-45):** Basic VC generator and SMT integration. Simple arithmetic contracts (the `Transfer.execute` conservation property) prove successfully.
2. **M4.2 (month 45-51):** Quantifiers and structural reasoning. Contracts on collections and recursive structures work.
3. **M4.3 (month 51-57):** Counterexample reporting, polish, documentation. v2.0 release with proof system.

### Realistic expectations

The proof system will work for arithmetic-heavy domain code, simple data structure invariants, and small algorithms. It will not work for code that interacts heavily with collections, strings, async, or external libraries. This is where SPARK and Frama-C are after decades; expect the same.

The framing for users: "use proof for the parts where it's easy, runtime checks for the parts where it's hard."

## Phase 5: Self-hosting (months 57-81)

**Goal:** Port the compiler from F# to Lyric.

### Deliverables

- **Self-hosted parser, type checker, mode checker, contract elaborator, monomorphizer, MSIL emitter** — all written in Lyric
- **Bootstrap compiler retained** for emergency use, no longer the primary build path
- **Self-hosted standard library**, including the LSP server and formatter
- **`lyric fmt`** (CST-faithful, round-trip-preserving) with the full CST layer it requires. The bootstrap shipped an AST-based formatter (`Fmt.fs` in `Lyric.Cli`) that covers the canonical style rules and is idempotent, but does not preserve non-doc comments. The self-hosted v1.0 formatter will use a CST for full fidelity.

### Phase 5 strategy

Port piece by piece, not big-bang. Order roughly:
1. Lexer (smallest, highest test coverage available)
2. Parser
3. Type checker
4. Mode checker
5. Contract elaborator
6. Monomorphizer
7. MSIL emitter
8. LSP/tooling

The proof system is *not* ported in Phase 5. SMT solver bindings are awkward in any host; the proof system is also the most likely place to need significant changes during this period. Keep it in F# until Phase 6 or later.

### Phase 5 milestones

1. **M5.1 (month 57-66):** Self-hosted lexer, parser, type checker
2. **M5.2 (month 66-75):** Self-hosted mode checker, contract elaborator, monomorphizer, MSIL emitter
3. **M5.3 (month 75-81):** Self-hosted standard library, LSP, formatter, package manager

### Exit criteria

- `lyric build` builds itself (`lyric build --self-host`)
- All tests pass
- Performance within 50% of the F# bootstrap

## Phase 6 and beyond: ecosystem

Open-ended. Successful languages spend most of their lifetime here.

### Likely areas

- **JVM backend** (separate codegen path, post-v1)
- **Industrial sponsorship and certifiable conformance** (annex-style)
- **Framework ecosystem**: HTTP framework, ORM-shaped persistence layer, observability libraries, message queue clients
- **Domain-specific tooling**: editor plugins beyond LSP basics, debugger UI, performance profiler integration
- **Standards work**: pinning the language reference into a versioned spec, possibly with ISO involvement at very high maturity

## Cross-cutting concerns

### Documentation

Documentation work runs continuously, not as a phase. Each milestone ships docs. The "real Lyric book" target for Phase 3 is a milestone, not the start.

### Testing the compiler

The compiler has its own test suite, sized by phase:
- Phase 1: ~200 end-to-end test programs (compile and run, check output)
- Phase 2: ~500 (each new feature gets ~20 tests)
- Phase 3: ~1000+ (LSP, wire all get extensive coverage)
- Phase 4: ~500 verification-specific tests, including the formal-methods-style soundness checks
- Phase 5: the self-hosted compiler is tested by being able to build itself plus the standard library plus the test suite

### Community building

Starts in Phase 0, not Phase 4. The languages that succeed have a coherent story before they have a working compiler.
- Phase 0: design discussions, RFCs, talks at language design meetups
- Phase 1: closed alpha with friendly users
- Phase 2: open alpha, early adopters
- Phase 3: v1.0 release, broader community
- Phase 4+: industrial users, conferences, books

### Funding

A serious language project is a 5-10 year commitment. Realistic models:
- **Industrial sponsor**: a company with safety-critical software needs funds the project; they get input on direction and early access
- **Foundation**: nonprofit governance (like the Rust Foundation post-1.0), funded by member donations
- **Startup**: VC-backed, language as a wedge into a tooling or services business
- **Academic**: research grants, particularly for the proof system phase
- **Open source side project**: doable but expect Phase 1 to take 2-3 years instead of 1, and Phase 4+ to be uncertain

The bootstrap compiler in F# can be built by a small team without funding. The proof system effectively requires funded work — the formal methods expertise is expensive and the integration is months of focused effort.

### Risks and mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Scope creep during design | High | High | Aggressive use of out-of-scope list; defer aggressively |
| Phase 1 takes 2× longer | High | Medium | Set conservative milestone targets; ship the smallest viable subset |
| Proof system slips indefinitely | Medium | Low | Phase 4 is post-v1; v1.0 ships without proof |
| Self-hosting reveals language gaps | High | Medium | Treat as feedback; iterate v1.x with the gaps fixed |
| Ecosystem fragmentation between Lyric and .NET | Medium | High | Strong stdlib; encourage curated wrappers over raw FFI |
| Funding dries up mid-project | Medium | Critical | Modular phases; each phase exit point produces shippable artifacts |
| Key team members leave | Medium | High | Documentation discipline; bus factor > 1 for every component |
| Formal methods expert hard to hire | High | High for Phase 4 | Consider partnership with academic group; budget for this early |
