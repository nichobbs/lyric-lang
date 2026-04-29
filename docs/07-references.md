# 07 — References

External standards Lyric conforms to, and prior art Lyric draws from. Each entry includes what the reference is for, what version is pinned, and whether the conformance is strict or best-effort.

## External standards (strict conformance)

### Unicode UAX #31 — Identifier Syntax
**Used for:** Character classes for identifiers (§1.2 of language reference)
**Version pinned:** Latest stable (currently UAX #31, Unicode 15.1)
**Conformance:** Strict; identifiers normalize to NFC

### IEEE 754-2019 — Floating-Point Arithmetic
**Used for:** Float and Double semantics, NaN handling, rounding modes
**Version pinned:** IEEE 754-2019
**Conformance:** Strict; default rounding mode round-to-nearest-even, traps disabled

### ISO 8601:2019 — Date and Time Representation
**Used for:** `std.time` parsing and formatting
**Version pinned:** ISO 8601:2019 (the 2004 amendment is also widely deployed; we accept both on input)
**Conformance:** Strict on output; lenient on input (accept trailing-Z, missing seconds, etc.)

### IANA Time Zone Database (tzdata)
**Used for:** Timezone definitions in `std.time`
**Version pinned:** Whatever ships with the runtime; updated with .NET releases
**Conformance:** Strict; we use the runtime's tzdata, not our own

### RFC 8259 — JSON Data Interchange
**Used for:** `std.json` parsing and serialization
**Version pinned:** RFC 8259 (December 2017)
**Conformance:** Strict. Reject duplicate keys (RFC 8259 §4 says implementations may; we choose to). Reject NaN and Infinity in numbers (the spec requires this). UTF-8 only.

### SemVer 2.0.0 — Semantic Versioning
**Used for:** Package versioning (`lyric.toml`)
**Version pinned:** SemVer 2.0.0
**Conformance:** Strict. The compiler emits warnings on attempted SemVer-violating changes (detected via `lyric public-api-diff`).

### Microsoft Language Server Protocol
**Used for:** `lyric lsp` (editor integration)
**Version pinned:** Latest stable LSP version at v1.0 release
**Conformance:** Strict; no Lyric-specific extensions in v1

### CommonMark — Markdown specification
**Used for:** Doc comment parsing (`///` and `//!`)
**Version pinned:** CommonMark 0.31 or latest stable
**Conformance:** Strict, with GitHub Flavored Markdown extensions for tables and code-block syntax highlighting

### RE2 — Regular expression syntax
**Used for:** `std.text.Regex` regex parsing
**Version pinned:** RE2 spec (Google's spec, not PCRE)
**Conformance:** Strict. No backreferences, no lookbehind, linear-time guaranteed

## External standards (best-effort)

### .NET Common Type System (CTS)
**Used for:** Interop with .NET BCL and ecosystem libraries
**Conformance:** Best-effort; some Lyric types do not have direct CTS analogs (range-constrained subtypes, opaque types). The compiler emits the closest CTS-compatible representation and documents the deviations.

### .NET Native AOT
**Used for:** Production deployment
**Conformance:** All Lyric programs are AOT-compatible; the compiler does not emit reflection, runtime code generation, or other AOT-incompatible patterns

## Languages drawn from for design

### Ada (1983-2022)
**What we draw from:**
- Range subtypes and distinct types (D010, D011)
- Opaque types and representational privacy (D003, D006)
- Package specification/body separation as a *concept*, even though we unified the source files (D005)
- Protected types with barriers (D009)
- Design-by-contract (origins traceable to Eiffel; mechanism via Ada 2012)
- Mandatory parameter modes (D004)
- Annex-style organization for optional features (deferred to v2+)
- Steelman/Strawman process discipline (informs Phase 0)

**What we don't take:**
- Ada 83 syntax (verbose, off-putting to modern audiences)
- Generic packages with package parameters (deferred to v2)
- Tasking model with rendezvous as the primary primitive (we use async + protected types)
- Annex H high-integrity profile (no current need)

### SPARK Ada
**What we draw from:**
- Per-module verification opt-in (D013)
- Axiom boundaries for unverified code (D013, language reference §6.5)
- SMT-backed proof system (Phase 4)
- The principle that proof obligations are part of the language

**What we don't take:**
- SPARK's restrictions on aliasing (we don't have ownership; we rely on GC)
- Information flow analysis (deferred indefinitely)

### Rust
**What we draw from:**
- `Result[T, E]` for recoverable errors (D007)
- `?` operator for error propagation
- Sum types (`union`, akin to `enum`) with exhaustive matching (D012)
- Monomorphized generics
- Distinct types via `newtype`-style separation (D011)
- Strict comparison chaining rules (D017)
- AOT-only mental model
- `const` evaluation and zero-cost abstractions philosophy
- Test-in-same-module pattern (Lyric's `@test_module` files)
- Doc comment conventions (`///`, `//!`)

**What we don't take:**
- Ownership/borrowing (we rely on GC)
- Lifetimes (no need with GC)
- Macros (rejected; we use `@derive` instead)

### Swift
**What we draw from:**
- Operator precedence table (D017)
- Optional types via `T?` syntax
- ARC mental model influenced our memory model decision even though we chose GC

**What we don't take:**
- ARC itself (we use .NET GC)
- `\(expr)` string interpolation (chose `${expr}` instead — D018)
- Existential types (out of scope)
- Protocol extensions beyond defaults (no plan to copy)

### Kotlin / TypeScript
**What we draw from:**
- `${expr}` string interpolation (D018)
- `val`/`var` distinction
- `:` for type annotation
- Expression-oriented `if`/`else` and pattern matching
- Async/await syntax style
- Familiar developer ergonomics for the .NET-adjacent audience

**What we don't take:**
- TypeScript's structural typing (we are nominal)
- Kotlin's class inheritance (rejected — D012)
- TypeScript's `any` (rejected — D-permanent-rejected)
- Kotlin's `lateinit` (anti-feature in our model)

### F#
**What we draw from:**
- ML-family pattern matching style
- Record syntax conventions
- Discriminated union shape (informs `union` semantics)
- The fact that you can write a compiler in F#, which we'll do for the bootstrap

**What we don't take:**
- ML-family syntax for code (we adopted Kotlin-style braces)
- Computation expressions (handled by `async` plus structured concurrency)
- Active patterns (deferred)

### CLU (1977)
**What we draw from:**
- Parameterised abstractions (origin of generics)
- Type-safe variant forms
- Structured exception handling (origin of much of what Ada and later languages have)

**What we don't take:**
- CLU's specific syntax
- Iteration via clusters

### Pascal / Modula-3
**What we draw from:**
- Range subtypes (origin in Pascal)
- Strong typing discipline
- Module systems (Modula-3 had module signatures distinct from implementations, similar to our `pub` model)

### Eiffel
**What we draw from:**
- Design-by-contract terminology and concepts (`requires`, `ensures`, invariants)
- The principle of contracts as part of class/module interface

**What we don't take:**
- Eiffel's syntax
- Eiffel's class model (we don't have classes)

### Go
**What we draw from:**
- Structured concurrency principles (although different mechanism)
- Tooling integration (`go fmt`, `go test`, `go doc` as inspiration for `lyric fmt`, etc.)
- Single-binary deployment story (matches AOT)

**What we don't take:**
- Go's interface satisfaction (structural; we are nominal)
- Go's error handling (manual `if err != nil` is not better than `?`)
- GOPATH-era module system

### Haskell
**What we draw from:**
- Sum types as a primary data modeling technique
- Pure expression sublanguage for contracts (informed by Haskell's purity)
- Property-based testing inspiration (QuickCheck origin)

**What we don't take:**
- Lazy evaluation
- Type classes (we use interfaces with default methods instead)
- Monadic effects beyond `async`

### Dafny / F*
**What we draw from:**
- Verification-friendly language design
- Proof obligation model
- Counterexample reporting expectations

**What we don't take:**
- Their specific syntax
- Their full power as research languages (Lyric is more conservative for tractability)

### Erlang / Elixir
**What we draw from:**
- The "let it crash" mentality for `Bug`s in protected entries
- Fault isolation principles influenced our task-aborts-on-bug decision

**What we don't take:**
- Actor model (out of scope)
- Hot code reload (out of scope)
- Dynamic typing

## Reference documents to consult during Phase 0

When resolving open questions or refining the language reference, the following documents are the authoritative external sources:

- **Ada Reference Manual (current ISO version)** — for verifying that our Ada-inspired features have idiomatic Ada equivalents
- **Ada 2012 Rationale (Tucker Taft, AdaCore)** — for understanding why Ada's contracts are the way they are
- **Steelman document (1978)** — historical context for what requirements Ada was designed to meet
- **SPARK 2014 Reference Manual** — for proof system design
- **Swift Language Reference** — for operator precedence base table
- **Rust Reference** — for distinct type and `Result` patterns; AOT-friendly design
- **C# Language Specification** — for understanding what .NET offers natively
- **F# Language Specification** — for the bootstrap implementation
- **The Rustonomicon** — for understanding the corner cases of monomorphization, async, and trait-based generics
- **CLR via C# (Jeffrey Richter)** — for understanding the .NET runtime model in depth, particularly value types vs reference types

## Reference implementations to study

When implementing specific features, the following reference implementations are worth studying:

- **GNAT (GNU Ada compiler)** — for protected type lowering, contract elaboration patterns
- **Roslyn (C# compiler)** — as an example of what *not* to do (too large, too deep), but also for MSIL emission patterns
- **F# compiler** — for ML-family compiler architecture in .NET
- **rustc** — for monomorphization implementation, error reporting style, LSP integration patterns
- **Swift compiler** — for async/await lowering, value type optimization
- **Dafny** — for SMT-backed verification integration
- **GNATprove** — for SPARK-style proof obligation generation

## Books and papers worth reading

For language designers and contributors:

- *Programming with Abstract Data Types* — Liskov & Zilles (CLU foundations)
- *Communicating Sequential Processes* — Hoare (concurrency lineage)
- *Object-Oriented Software Construction* — Meyer (DbC foundations)
- *Types and Programming Languages* — Pierce (foundational type theory)
- *Software Foundations* — Pierce et al. (verification foundations)
- *The Practice of Programming* — Kernighan & Pike (general systems design)
- *Engineering a Compiler* — Cooper & Torczon (compiler implementation)
- *Modern Compiler Implementation in ML* — Appel (ML-family compilers)
- *Rust for Rustaceans* — Gjengset (advanced Rust patterns relevant to monomorphization)
- *The Quiet Colossus* — the essay that motivated this project; required context for understanding what we're trying to revive

For users of the language (eventually):
- *The Lyric Programming Language* — Phase 3 deliverable; doesn't exist yet

## Versioning of this document

This references list is updated as Lyric evolves. New external standards adopted are added here. Standards versioning bumps (e.g., a new Unicode version) are tracked here and in the decision log if they have user-visible effects.
