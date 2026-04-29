# Lyric

A safety-oriented application language targeting .NET, drawing on Ada's design principles while maintaining familiar syntax and ecosystem interoperability.

**Status:** Design phase (v0.1). No compiler exists yet. This repository contains the language specification, design rationale, and implementation plan.

## What Lyric is

A general-purpose application language for building services and APIs, with:

- **Strong type system** with range-constrained subtypes and distinct nominal types
- **Representational privacy** via opaque types — no reflection can crack them open
- **Design-by-contract** as a first-class language feature (`requires`, `ensures`, invariants)
- **Compile-time dependency injection** baked into the language
- **Structured concurrency** with `async`/`await` and Ada-style `protected type` for shared state
- **Tiered visibility** — opaque domain types coexist with exposed wire-level types via compiler-generated projections
- **Optional formal verification** via SMT-solver-backed proof of contracts (per-module opt-in)

Lyric targets the .NET runtime initially, leveraging reified generics, value types, and Native AOT.

## Documentation map

- [00-overview.md](docs/00-overview.md) — design philosophy, target audience, what Lyric is and is not
- [01-language-reference.md](docs/01-language-reference.md) — syntax, type system, semantics
- [02-worked-examples.md](docs/02-worked-examples.md) — non-trivial programs in proposed-Lyric
- [03-decision-log.md](docs/03-decision-log.md) — every significant design decision with rationale
- [04-out-of-scope.md](docs/04-out-of-scope.md) — what we deliberately don't do, and why
- [05-implementation-plan.md](docs/05-implementation-plan.md) — phased plan from v0.1 to self-hosting
- [06-open-questions.md](docs/06-open-questions.md) — unresolved design questions
- [07-references.md](docs/07-references.md) — external standards and prior art

## Reading order

Newcomers: 00 → 02 → 01 → 03.
Implementers: 01 → 05 → 06.
Reviewers: 03 → 04 → 06.

## Contributing to the design

The decision log (03) is the canonical record of *why* the language is the way it is. Any proposal to change a fundamental design decision should reference the relevant decision-log entry and explain why the original reasoning no longer holds. New decisions get appended; reversed decisions are not deleted but marked superseded with a forward reference.
