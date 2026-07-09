# 03 — Decision Log

This document records every significant design decision, the alternatives considered, the rationale, and any subsequent revisions. It is the canonical record of *why* Lyric is the way it is.

Format for each entry:
- **Status**: ACCEPTED | SUPERSEDED | OPEN
- **Decision**: what was decided
- **Alternatives**: what was considered
- **Rationale**: why this won
- **Revisions**: changes over time, with forward links if superseded

---

## D001: Target the .NET runtime as the primary backend

**Status:** ACCEPTED

**Decision:** Lyric's primary compilation target is .NET (CLR/CoreCLR). MSIL is the emitted intermediate. Native AOT is the production deployment target.

**Alternatives:**
- JVM
- LLVM-native with C ABI
- WASM-first
- Polyglot via multiple backends

**Rationale:**
- Reified generics align with Lyric's monomorphization strategy. JVM erases generics, which would force either Scala-style specialization gymnastics or accepting that range subtypes lose their distinct identity at runtime.
- Value types (`struct`) are first-class on .NET, allowing range subtypes and small records to compile to zero-allocation forms.
- C# already has `in`/`out`/`ref` parameter modes — the runtime knows how to represent them.
- Native AOT is mature and aligns with our no-reflection stance.
- The .NET ecosystem has been migrating toward AOT-compatible source-generator-based libraries (System.Text.Json SG, ASP.NET request delegate generator, EF Core compiled models, FluentValidation SG). We benefit from this migration without driving it.
- LLVM-native would require building a runtime from scratch; WASM-first would isolate us from server ecosystems; polyglot is too much complexity at v1.

**Revisions:** None. JVM remains a stretch goal post-v1 (D023).

---

## D002: Use the host runtime's tracing GC; do not implement memory management

**Status:** ACCEPTED

**Decision:** Lyric uses .NET's tracing GC. No ownership/borrowing system, no ARC, no manual memory management.

**Alternatives:**
- ARC (Swift-style)
- Ownership/borrowing (Rust-style)
- Region/arena allocation

**Rationale:**
- Bolting ARC on top of a tracing GC runtime is a self-inflicted complexity wound — it buys nothing, costs everything.
- Ownership/borrowing is hostile to the application domain (services, APIs) we're targeting. Rust's value proposition depends on no-runtime systems work; we don't need that.
- The complexity budget is better spent on the verification story (proof system) than on memory management.
- For application code, GC pause times are not the bottleneck; correctness is.

**Revisions:** None.

---

## D003: Tiered visibility — opaque domain types and exposed wire types

**Status:** ACCEPTED

**Decision:** The type system has two visibility tiers. `opaque type T` has its representation invisible to clients and to host reflection. `exposed record T` is flat, host-visible, reflection-friendly. Boundary code converts between them.

**Alternatives:**
- Pure (a): allow ecosystem libraries unconditionally; ban reflection inside Lyric only
- Pure (b): no representation visible to host; force users to write boundary types manually for every interaction
- Single visibility tier with annotations to opt out

**Rationale:**
- Pure (a) gives up the safety story at the language boundary — Jackson/Hibernate-equivalents would crack open opaque types via reflection.
- Pure (b) is too punishing; every DTO becomes manual work, killing ergonomics.
- Tiered visibility encodes the discipline mature DDD codebases already follow informally (entities vs DTOs).
- Combined with `@projectable` (D015), the developer experience is single-keyword.

**Revisions:** None. Initially the visibility was implicit on the package boundary; D015 made the projection mechanism explicit.

---

## D004: Mandatory parameter modes (`in`/`out`/`inout`)

**Status:** ACCEPTED

**Decision:** Every function parameter declares a mode (`in`, `out`, `inout`) explicitly. There is no implicit default mode.

**Alternatives:**
- C#-style optional modes (`in`/`out`/`ref` opt-in, default by-value)
- Mode inference

**Rationale:**
- Modes are part of the function's contract. Knowing whether a parameter is read-only, write-only, or read-write changes how callers reason about the function and how the prover models it.
- C#'s opt-in modes mean most code never uses them, and the information is lost. Lyric chose to require them because the cost is small (one keyword per parameter) and the benefit is consistent visibility.
- Inference would lose the information at the source level, defeating the purpose.

**Revisions:** None.

---

## D005: Combine spec and body into a single source file by default

**Status:** ACCEPTED (revised from D005-original)

**Decision:** Lyric source files are unified by default. Public visibility is marked with `pub`. Contract metadata is emitted as a compiler artifact, not authored by hand.

**Alternatives:**
- Ada-style mandatory `.lspec`/`.lbody` split files
- Header-file-style separation
- Module signatures as separate optional artifact

**Rationale:**
- Information hiding is a binary/metadata concern, not a source-layout concern. Whether the public surface is in a separate file does not change what consumers see at the binary level — that's controlled by emit logic regardless.
- Incremental compilation benefits (the main practical payoff of split files) can be achieved by having the compiler emit a contract metadata artifact automatically. Swift's `.swiftinterface`, OCaml's `.cmi`, Rust's `rmeta` all do this.
- Forcing the design step via file count is cultural, not structural; you cannot make developers commit to contracts first by giving them two files. Discipline comes from review, not layout.
- Modern developers expect single-file modules. Adding a file split tax for symbolic value is wrong.
- A project-level opt-in for split files (D025) preserves the option for teams that want it.

**Revisions:**
- *D005-original (SUPERSEDED):* Required `.lspec` and `.lbody` files following the Ada model. Superseded after recognizing that the binary contract emission, not the source split, is what matters for information hiding. The split was paying for itself in ceremony rather than guarantees.

---

## D006: No reflection in the language; opaque types are sealed against host reflection

**Status:** ACCEPTED

**Decision:** Lyric programs cannot use reflection. Opaque types compile to forms that resist .NET reflection (sealed metadata, no public properties, no exposed constructors).

**Alternatives:**
- Permit reflection but restrict it to specific scenarios
- Allow reflection only in `@unsafe` blocks
- Don't bother sealing against host reflection — trust the developer

**Rationale:**
- Without sealing, the "opaque" guarantee is purely advisory. Any third-party library can crack it open.
- Banning reflection is what makes compile-time DI viable, AOT compatibility automatic, and the safety story coherent.
- The cost is real but bounded: most `@reflection`-driven .NET libraries have AOT-compatible source-generator alternatives in 2026.
- Source generators (`@derive(Json)`, etc.) cover the legitimate use cases that reflection used to handle.

**Revisions:** None.

---

## D007: Drop `raises:` clauses; recoverable errors via `Result[T, E]`, bugs propagate freely

**Status:** ACCEPTED (revised from D007-original)

**Decision:** Functions do not declare which exceptions they may throw. Recoverable errors are encoded in the return type as `Result[T, E]`. Bugs (precondition violations, contract violations, unwrap failures) propagate uniformly and are not part of function signatures.

**Alternatives:**
- Java-style checked exceptions
- Soft `raises:` clauses (warn but don't enforce)
- Effect system with `raises` as one effect

**Rationale:**
- Java's checked exceptions failed for well-documented reasons: refactoring friction, lambda/HOF awkwardness, async amplification, the `RuntimeException` escape hatch culture.
- Soft `raises:` reproduces these problems without the enforcement. Either it's checked (Java problems) or it's not (lying annotations).
- Full effect systems are powerful but cost a whole extra type-system axis; out of scope for v1.
- `Result[T, E]` works. Rust validates this. The cost is real (every error path explicit) but it's localized and consistent.

**Revisions:**
- *D007-original (SUPERSEDED):* Functions declared `raises: ErrorType` in their signatures, checked at the boundary but not at every call site. Superseded after recognizing this would reproduce Java's failure mode. The `raises:` clause was attractive because it preserved Ada flavor, but it would have been a footgun that future developers would have routed around with wrapper exceptions.

---

## D008: Compile-time dependency injection via `wire` blocks

**Status:** ACCEPTED

**Decision:** Dependency injection is a language feature, not a runtime container. `wire` blocks declare the object graph; the compiler resolves it at compile time and emits straight-line factory code.

**Alternatives:**
- Runtime DI container (Spring/ASP.NET style)
- Explicit hand-wiring with no language support
- Capability-based passing (effect-system style)

**Rationale:**
- Reflection ban (D006) makes runtime DI containers impossible anyway.
- Compile-time DI gives better errors, faster startup, AOT compatibility, and zero runtime overhead.
- The lifetime checking ("singleton can't depend on scoped[Request]") catches captive-dependency bugs that Spring/ASP.NET diagnose at runtime.
- The cost is one new construct (`wire`), which is well-bounded.

**Revisions:** None.

---

## D009: `protected type` for shared mutable state, no raw locks

**Status:** ACCEPTED

**Decision:** Shared mutable state is wrapped in `protected type` declarations with declared invariants and barrier conditions. Raw locks (`Monitor.Enter`, `lock` statement) are not directly available; access requires `@axiom` boundaries.

**Alternatives:**
- C#-style `lock` blocks plus library types
- Rust-style `Arc<Mutex<T>>` plus library
- Actor model (Erlang-style)
- Ada-style protected types (chosen)

**Rationale:**
- Raw locks invite forgetting to lock, locking the wrong thing, holding locks across foreign calls. The defensive coding required is real.
- Protected types make mutual exclusion structural — there is no way to access the state without going through the protected interface. Bug class eliminated.
- Barrier conditions (`when:` clauses) handle the "wait until predicate true" pattern without manual condition variables.
- Actors are powerful but a different architectural commitment; protected types are the local primitive.

**Revisions:** None.

---

## D010: Range subtypes as a first-class language feature

**Status:** ACCEPTED

**Decision:** `type X = Long range a ..= b` declares a distinct type whose values must lie in `[a, b]`. Construction outside the range fails (`tryFrom` returns `Err`, `from` panics). Inside `@proof_required` modules, range obligations are discharged statically.

**Alternatives:**
- Newtype wrappers (Rust/Haskell style)
- Refinement types via a separate annotation system
- Don't bother — let users build it themselves

**Rationale:**
- This is one of Ada's most distinctive features and a huge driver of the language's safety story.
- It's much cleaner than `newtype Cents = Cents(Long)` patterns because the range is part of the type, not part of a private constructor.
- Combined with distinct nominal types (D011), it solves "I'm passing a year where I meant an age" at compile time.

**Revisions:** None.

---

## D011: Distinct nominal types separate from aliases

**Status:** ACCEPTED

**Decision:** `type X = Long` creates a distinct type. `alias X = Long` creates a type synonym. The keywords are separate.

**Alternatives:**
- TypeScript-style branded types via phantom parameters
- Rust-style newtype always
- Treat all type declarations as aliases (Java-style)

**Rationale:**
- Distinct types are the common case in Lyric idioms; aliases are the exception (mostly for shortening generic types in signatures).
- Separating the keywords removes ambiguity. `type Cents = Long` and `type UserId = Long` should be different types — the keyword choice makes that explicit.

**Revisions:** None.

---

## D012: Sum types with exhaustive matching, no inheritance

**Status:** ACCEPTED

**Decision:** Polymorphism is via interfaces and sum types. There is no class inheritance. Sum types use `union` keyword; pattern matching is exhaustive.

**Alternatives:**
- Java-style class inheritance plus interfaces
- Rust-style enums with traits
- Both inheritance and sum types

**Rationale:**
- Class inheritance is widely recognized as overused. Composition + interfaces + sum types covers the use cases without the fragility.
- Sum types model "data that can be one of several things" correctly; class hierarchies model it incorrectly (open extension when closed semantics were wanted).
- Exhaustiveness checking catches the bug class where adding a variant silently breaks downstream code.

**Revisions:** None.

---

## D013: Optional formal verification per module, not at function granularity

**Status:** ACCEPTED

**Decision:** Verification level is declared at the package level (`@runtime_checked`, `@proof_required`). The proof system can only reason about code in proof-required modules; calls into other modules require axiom boundaries.

**Alternatives:**
- Function-level verification opt-in
- Project-wide verification
- No verification at all

**Rationale:**
- SPARK's actual model. It works in practice because the boundaries are clear.
- Function-level opt-in is too granular — a verified function calling unverified helpers gives you nothing.
- Project-wide verification is unrealistic — you can't verify code that calls into the .NET BCL.
- Per-module is the right granularity: domain modules can be `@proof_required`; application modules with I/O are `@runtime_checked`.

**Revisions:** None.

---

## D014: Property-based testing built into the language

**Status:** ACCEPTED

**Decision:** `property` declarations and `forall` are language-level constructs. The compiler auto-derives generators for opaque types from their invariants. Contract `ensures` clauses are runnable as auto-generated property tests via `lyric test --properties`.

**Alternatives:**
- Property testing as a library (Hypothesis/QuickCheck style)
- No built-in property support

**Rationale:**
- Property testing pairs naturally with a contract-rich type system.
- Auto-derived generators that respect invariants is something a library cannot do without ugly metaprogramming. Built-in is meaningfully better.
- Running contracts as property tests is free correctness — the spec is already there.
- The cost (a few language constructs) is small relative to the safety benefit.

**Revisions:** None.

---

## D015: `@projectable` for compiler-generated exposed twins

**Status:** ACCEPTED

**Decision:** Opaque types annotated `@projectable` automatically have a sibling `exposed record` generated by the compiler, plus `toView()` and `tryInto()` conversion functions.

**Alternatives:**
- Hand-written DTOs always
- Macros that users write
- Procedural source generators

**Rationale:**
- Without this, tiered visibility (D003) is too verbose. Every type needs a hand-written DTO.
- Compiler-driven generation handles field drift, recursive projection, and invariant enforcement at the boundary correctly.
- The `@hidden` field annotation handles the "don't expose this" case explicitly.
- This is the bridge that makes D003 ergonomic enough to be the default.

**Revisions:** None.

---

## D016: `@stubbable` for compiler-generated test stubs

**Status:** ACCEPTED

**Decision:** Interfaces annotated `@stubbable` have a stub builder generated by the compiler with `.returning { ... }`, `.recording()`, `.failing { ... }` methods.

**Alternatives:**
- Mocking framework (impossible without reflection — D006)
- Hand-written stubs
- Macro-based stub generation

**Rationale:**
- Without `@stubbable`, banning reflection-driven mocking would mean every interface needs a hand-written stub for every test scenario. Real friction.
- Compiler-generated stubs are statically typed (signature changes break tests at compile time, not runtime), AOT-compatible, and predictable.
- We deliberately omit Mockito-style argument-matching DSLs (`when(eq(...)).thenReturn(...)`) — they encourage brittle tests and don't fit a static system.

**Revisions:** None.

---

## D017: Swift operator precedence + Rust chained-comparison rules

**Status:** ACCEPTED

**Decision:** The base operator precedence table is Swift's, with Rust's rule that comparison operators do not chain (`a < b < c` is a parse error).

**Alternatives:**
- C/Java/JavaScript family (most familiar but inherits known flaws)
- Custom precedence
- User-definable operator precedence (Scala/Haskell style)

**Rationale:**
- Swift's table is already a cleanup of the C family — fewer levels, no ternary, no assignment-as-expression.
- Rust's chained-comparison rule catches a real bug class for free.
- User-definable precedence is a footgun.
- Citing an external standard (Swift's docs) is preferable to inventing our own table.

**Revisions:** None.

---

## D018: JS/Kotlin-style string interpolation `${expr}`

**Status:** ACCEPTED (revised from D018-original)

**Decision:** String interpolation uses `${expr}` syntax inside `"..."` strings. `\${...}` escapes the interpolation.

**Alternatives:**
- Swift-style `\(expr)` interpolation
- C#-style `$"..."` prefix with `{expr}`
- Python-style f-strings

**Rationale:**
- TS, Kotlin, shell, Groovy, and others all use `${...}`. The vast majority of developers arriving at Lyric have it in muscle memory.
- Swift's `\(...)` is slightly cleaner syntactically but unfamiliar to non-Swift developers.
- C#'s `$` prefix means string literals are non-interpolating by default, which is consistent but also less ergonomic.
- Familiarity wins where the technical differences are minor.

**Revisions:**
- *D018-original (SUPERSEDED):* Initially proposed Swift's `\(expr)` syntax. Reversed in favor of `${expr}` based on user familiarity argument.

---

## D019: Bitwise operators as named methods, not symbolic

**Status:** ACCEPTED

**Decision:** Bitwise AND, OR, XOR, shift operations are methods on integer types (`a.and(b)`, `a.shl(3)`), not symbolic operators.

**Alternatives:**
- C-style `&`, `|`, `^`, `<<`, `>>`
- Different symbolic operators

**Rationale:**
- Sidesteps the C-family precedence trap (`a & b == c` parses as `a & (b == c)`).
- Bitwise operations are uncommon in application code; the verbosity penalty is small in practice.
- The change makes Lyric look slightly different from C-family languages but in a place where the difference is justifiable.

**Revisions:** None.

---

## D020: Bootstrap compiler in F#, not C#

**Status:** ACCEPTED

**Decision:** The Phase 1 bootstrap compiler will be implemented in F#.

**Alternatives:**
- C# (more ecosystem familiarity)
- Rust (better tooling for compilers)
- OCaml (the historical "compiler-implementation language")

**Rationale:**
- ML-family languages are dramatically better for compiler implementation: pattern matching on AST, sum types for AST nodes, immutable data, fold patterns over recursive structures.
- Roslyn (C# in C#) is enormous because C# is a hostile language for writing compilers in. Don't repeat that mistake.
- F# gives full .NET interop, which we need for emitting MSIL and integrating with the .NET tooling ecosystem.
- Rust is also a good choice but introduces a non-.NET dependency for the bootstrap and offers no advantage over F# for our targets.

**Revisions:** None.

---

## D021: Self-hosting at v3, not before language stability

**Status:** ACCEPTED

**Decision:** The compiler will not be self-hosted in Phase 1-3. Self-hosting is targeted for Phase 5, after the language is stable.

**Alternatives:**
- Self-host from day one
- Self-host after Phase 1 (full language MVP)
- Never self-host

**Rationale:**
- Every language change costs double during pre-stability self-hosting (bootstrap + self-hosted both updated).
- Languages that self-host too early either freeze prematurely or thrash. Rust took ~5 years to self-host; Go waited until 1.5 (4 years post-release).
- Dogfooding is real value, but it's worth more once the language is stable enough that compiler changes are mostly bug fixes.

**Revisions:** None.

---

## D022: Adopt external standards aggressively where decisions are conventional

**Status:** ACCEPTED

**Decision:** Lyric adopts external standards (Unicode UAX #31, IEEE 754-2019, ISO 8601, IANA tzdata, RFC 8259, SemVer, LSP, RE2, Markdown for docs) rather than inventing replacements where the decision is conventional rather than load-bearing.

**Alternatives:**
- Custom decisions everywhere
- Adopt some standards, invent others ad-hoc

**Rationale:**
- Most language-design effort goes into things that didn't actually need to be redesigned. Adopting a stable standard is free correctness for our users.
- Citing external documents in the spec is more compact than restating the rules.
- Pinning to standards is defensible to skeptics (regulators, conservative teams).

**Revisions:** None.

---

## D023: JVM backend is post-v1

**Status:** ACCEPTED

**Decision:** The JVM is a post-v1 stretch goal. v1 ships .NET only.

**Alternatives:**
- Multi-target from day one
- JVM as primary target

**Rationale:**
- Erased generics on JVM mean range subtypes and distinct nominal types lose their identity at runtime.
- Reflection culture on JVM is much stronger than .NET; the AOT-compatible-library ecosystem migration is less complete.
- Building two backends in parallel is a way to ship neither. Pick one, do it well.

**Revisions:** None. Revisit after v1 ships if there's user demand.

---

## D024: No global escape hatches for time, randomness, IO

**Status:** ACCEPTED

**Decision:** `Clock`, `RandomSource`, `FileSystem`, etc. are interfaces obtained via DI. There is no `@global_clock_unsafe`-style escape hatch for direct access to system primitives.

**Alternatives:**
- Permit a documented escape hatch for `main`/CLI tools
- Make global access easier "for ergonomic reasons"

**Rationale:**
- Every escape hatch I've seen in production languages becomes the norm somewhere. The friction of DI is the feature.
- `main` ergonomics will need to be good enough that this isn't painful — that's a tooling investment worth making.

**Revisions:** None.

---

## D025: Optional split-file mode at project level

**Status:** ACCEPTED

**Decision:** Projects may opt into authoring `.lspec`/`.lbody` split files via `lyric.toml` configuration. Default is unified files.

**Alternatives:**
- Force unified everywhere
- Force split everywhere

**Rationale:**
- Some teams (safety-critical, conservative engineering cultures) genuinely prefer the discipline of separate spec files.
- The implementation cost is small — the parser handles either layout, the rest of the pipeline is unchanged.
- Provides an upgrade path for teams migrating from Ada.

**Revisions:** None.

---

## D026: Mandatory `@projectionBoundary` annotation breaks projection cycles

**Status:** ACCEPTED

**Decision:** When the compiler detects a cycle in the `@projectable`
graph (e.g. `User` is `@projectable` and contains `Team`, which is
`@projectable` and contains `slice[User]`), it emits an error pointing
at both sides of the cycle and requires the author to mark one side
with `@projectionBoundary(asId)`. The marked field projects as an ID
reference instead of recursively expanding.

**Alternatives:**
- Silently default to a "shallow" projection that emits opaque handles.
- Auto-generate two views (full one-level + reference-only).
- Accept the cycle and leave it to runtime to break.

**Rationale:**
- Silent defaulting hides surprise in the wire shape (different JSON than
  the user expects). Explicit annotation surfaces the choice in the type
  declaration where it can be reviewed.
- Auto-generating two views adds API surface and naming churn.
- Promotes Q003 from `06-open-questions.md`. The recommended option (3)
  was already accepted; this entry pins it.

**Revisions:** None.

---

## D027: `?` in a non-error-returning function is a compile error

**Status:** ACCEPTED

**Decision:** The error-propagation operator `?` is rejected at compile
time when the enclosing function's return type is not a compatible
`Result[_, _]` or `T?`. Users who want to fail loudly use `unwrap()`
explicitly; users who want to handle the error use `match` or `?` with
a propagating signature.

**Alternatives:**
- Implicit panic (treat `?` as `unwrap()`).
- Implicit unwrap with no warning.

**Rationale:**
- Conflating `?` with `unwrap()` would silently change error semantics
  on signature edits — refactoring a function from `Result`-returning to
  `T`-returning would turn explicit error-propagation into hidden
  panics.
- `unwrap()` is already the language's "I know this can't fail" affordance.
  Two affordances would be noise.
- Promotes Q006 from `06-open-questions.md`. Recommended option (1).

**Revisions:** None.

---

## D028: Doctests run by default; opt out with `// no_test`

**Status:** ACCEPTED

**Decision:** Code blocks inside `///` doc comments are executed by
`lyric test` by default. A doc-comment author opts a block out via a
`// no_test` line at the head of the block.

**Alternatives:**
- Opt-in (require `// doctest`) — keeps `lyric test` faster but lets
  examples bit-rot.
- No doctests at all.

**Rationale:**
- Examples in documentation are a liability when they go stale; running
  them is a free correctness check.
- Rust's experience with `rustdoc` is that default-on is the right
  default; the opt-out covers the unusual cases (examples that mention
  external services, are pseudocode, or document API misuse).
- Promotes Q013 from `06-open-questions.md`.

**Revisions:** None.

---

## D029: Operator overloading allowed only via the closed numeric trait set

**Status:** ACCEPTED

**Decision:** Users may write `impl Add for MyType`, `impl Sub for MyType`,
`impl Mul for MyType`, `impl Div for MyType`, `impl Mod for MyType` —
and these enable the corresponding binary operators on `MyType`. No
other operator-defining interfaces exist; `<<`, `>>`, custom symbolic
operators, etc. are not user-extensible. The `Add`/`Sub`/`Mul`/`Div`/
`Mod` interfaces require numeric-shaped signatures (`MyType + MyType
-> MyType` and so on) — the compiler rejects implementations that
diverge.

**Alternatives:**
- No `impl`-based overloading; `derives` only on numeric distinct types
  (the original design).
- Allow arbitrary operator-defining traits.

**Rationale:**
- Vector and matrix types are real; forcing them through method calls
  (`v.add(w)`) reads worse than `v + w` in math-heavy code without
  buying any safety.
- Restricting the trait set to the closed numeric markers blocks the
  worst abuses (`<<` for "stream insertion", `+` for "config merge")
  while admitting the genuine cases.
- The compiler's "numeric semantics" requirement is a social check, not
  a mechanical one — users who write a non-numeric `Add` are violating
  a documented convention; the language doesn't enforce the algebra.
- Promotes Q014 from `06-open-questions.md`.

**Revisions:** None.

---

## D030: Built-in `Error` interface and auto-derived `Display` on union errors

**Status:** ACCEPTED

**Decision:** `std.core` defines

```
pub interface Error {
  func message(): String
  func source(): Error?     // default: None
}
```

Any type used in the `E` position of `Result[T, E]` must implement
`Error`. For `union` types so used, the compiler auto-derives `Error`
from each variant's name and payload (`message()` returns
`"Variant(field1=..., ...)"` by default; users may override with an
explicit `impl Error for MyError`). A separate `Display` interface for
general string formatting may follow in v2; for v1, `Error.message()`
is the only formatting affordance built into the language.

**Alternatives:**
- No `Error` interface — any type is admissible in `Result[T, E]`.
- Auto-derive only `Debug`-style formatting, no `Error`.
- Require manual `impl Error` everywhere.

**Rationale:**
- A common interface lets stdlib utilities (`Result.context(...)`,
  logging) work uniformly across error types without runtime
  reflection.
- Auto-derive on unions covers the typical case; explicit `impl` is
  available for the few cases where a custom message is wanted.
- Promotes Q015 from `06-open-questions.md`.

**Revisions:** None.

---

## D031: Synchronous implementations auto-lift to async at interface boundaries

**Status:** ACCEPTED

**Decision:** A synchronous function may satisfy an `async`-declared
interface method. The compiler wraps the synchronous return value in
`Task.fromValue(...)` (or the `ValueTask` equivalent for `@hot`
interfaces) at the impl boundary. The reverse — an `async` function
satisfying a synchronous interface — is rejected; calling
`.result`-style blocking conversions are not provided.

**Alternatives:**
- Strict signature match in both directions.
- Allow async-to-sync via implicit blocking (rejected; deadlock-prone).

**Rationale:**
- The wrap is zero-cost in the synchronous-completion path on .NET.
- Removes the friction of writing `async func findById(...): User? =
  Task.fromValue(myMap.get(id))` for every in-memory test stub.
- The asymmetry (sync→async lifts, async→sync rejects) reflects the
  asymmetry of the runtime: lifting is safe; lowering courts deadlock.
- Promotes Q016 from `06-open-questions.md`.

**Revisions:** None.

---

## D032: `///` for item docs, `//!` for module docs

**Status:** ACCEPTED

**Decision:** Documentation comments use `///` for the following item
and `//!` for the enclosing package/module. Both are CommonMark with
GFM tables and code blocks.

**Alternatives:**
- `////` for module docs.
- `@doc(...)` annotation on the package declaration.
- Single style with a positional rule.

**Rationale:**
- Matches Rust's conventions, which the .NET/Lyric audience is
  increasingly familiar with.
- Tooling (LSP, formatters, doc generators) already understands the
  `///` / `//!` distinction.
- Promotes Q018 from `06-open-questions.md`.

**Revisions:** None.

---

## D033: Z3 is the proof-system SMT backend for v2.0

**Status:** ACCEPTED

**Decision:** When the proof system ships in v2.0 (Phase 4), it
integrates Z3 as the SMT backend. Z3 is consumed via its .NET
bindings; the verifier emits SMT-LIB v2.6 queries on top of Z3's
incremental solver API.

**Alternatives:**
- CVC5 (more permissive license, comparable performance).
- Multiple-backend support from day one.

**Rationale:**
- Z3 is the precedent in the verification community we draw from
  (Dafny, Boogie, F*, Lean's tactics).
- Microsoft Research maintains Z3 actively; the .NET bindings track
  upstream.
- CVC5 remains a viable fallback if licensing or performance changes
  later; the verifier's translation to SMT-LIB is solver-agnostic by
  design, so a swap is feasible at modest cost.
- Promotes Q020 from `06-open-questions.md`.

**Revisions:** None.

---

## D034: Closed list of built-in generic constraint markers

**Status:** ACCEPTED

**Decision:** The set of built-in markers usable in `derives` clauses
on distinct types and `where` clauses on generics is closed at:

`Equals`, `Compare`, `Hash`, `Default`, `Copyable`, `Add`, `Sub`,
`Mul`, `Div`, `Mod`

with the following semantics:

| Marker     | Sense | Derivable? | Constraint? |
|------------|-------|-----------:|-------------:|
| `Equals`   | Value equality. Generates `==`/`!=` and `IEquatable<T>`. | yes | yes |
| `Compare`  | Total ordering. Generates `<`/`<=`/`>`/`>=` and `IComparable<T>`. | yes | yes |
| `Hash`     | Stable hash code consistent with `Equals`. | yes | yes |
| `Default`  | Canonical default value via `T.default()`. Rejected as a derive on range subtypes whose underlying default is out of range. | yes | yes |
| `Copyable` | Type lowers to a CLR value type (per `09-msil-emission.md` §5). Structural property; cannot be opted into. | no  | yes |
| `Add`      | `T + T -> T`. | yes | yes |
| `Sub`      | `T - T -> T`; admits unary `-T` when underlying is signed. | yes | yes |
| `Mul`      | `T * T -> T`. | yes | yes |
| `Div`      | `T / T -> T`. | yes | yes |
| `Mod`      | `T % T -> T`. | yes | yes |

User-defined interfaces are usable as `where` constraints. They are
not derivable; the language has no auto-implementation mechanism for
arbitrary interfaces. To make a distinct type satisfy a user-defined
interface, write an `impl` block.

**Alternatives considered:**

- **Add `Send`** (Rust-style thread-safety marker). Rejected:
  Lyric's thread-safety is structural via `protected type` and the
  default-immutable `val` binding; a `Send` marker would be a no-op
  in nearly all programs and a misleading half-measure where it
  wasn't.
- **Add a `Numeric` umbrella.** Rejected: the canonical idiom
  (`type Cents = Long range … derives Add, Sub, Compare`) requires
  the user to *opt in* to each operator. A coarse umbrella would
  over-derive (e.g. `Cents * Cents` is meaningless).
- **Built-in `Iterable`, `Sized`, `Indexable`.** Rejected: these
  receive no special compiler support — `for x in xs` desugars to
  ordinary method calls. They live as plain interfaces in
  `std.collections`.
- **Naming as `Comparable`/`Hashable`/`Addable`.** Rejected:
  bare-noun (`Compare`, `Hash`, `Add`) is the established style
  used throughout the worked examples; consistency wins over the
  marginal precision of `-able` suffixes.

**Rationale:**

- Each marker maps to a specific lowering pattern (`09-msil-emission.md`
  §6.2 for derives on distinct types, §9.4 for generic constraints), so
  the implementer can emit the corresponding CLR member or constraint
  without ambiguity.
- Closing the list precludes a long tail of low-value markers
  (`Iterable`, `Numeric`, `Send`, etc.) accumulating over the
  language's lifetime.
- Opening the list later is cheap (add an entry to the table); closing
  it later is expensive (existing user code may rely on the loose
  rules).
- Closes Q004 from `06-open-questions.md`.

**Revisions:**

**2026-06-10 — `Ord` added to closed marker set (PR #2966).** `Ord` was
added as an eleventh marker. It generates a total-order comparison (a single
`compare(other: T): Int` method returning negative/zero/positive) and is
derivable for records (lexicographic by field declaration order, same ordering
policy as `Compare`). Unlike `Compare`, `Ord` does not auto-generate the
four relational operators (`<`/`<=`/`>`/`>=`) — those are the domain of
`Compare`. Rationale: the stdlib `Std.Sort` generic sort and similar
higher-order utilities need a caller-supplied or derived total-ordering
function; `Ord` is the canonical way to express that constraint. The addition
is within the spirit of the closed list (specific lowering, CLR backing
member) and does not open the list to arbitrary user-defined additions.
Alternatives considered and rejected: re-using `Compare` (conflates operator
synthesis with ordering), a plain interface `Ordering` (not derivable).

---

## D035: M1.4 scope cuts — bootstrap-grade lowering for generics, async, and FFI

**Status:** ACCEPTED — async row SUPERSEDED (see Revisions).

**Decision:** The bootstrap compiler's M1.4 milestone (per
`docs/05-implementation-plan.md`) ships *bootstrap-grade* lowerings for
three constructs that the language reference describes in their full
form. The reduced-fidelity lowerings unblock the banking example and
let the type checker / parser / emitter pipeline verify the broad
shape of v0.1 end-to-end; the full lowerings land in Phase 2 polish.

| Construct | M1.4 lowering | v0.1-target lowering | Where the gap lives |
|---|---|---|---|
| Generics | **Monomorphisation per call site** — the type checker rewrites each generic call into a synthesised concrete instantiation; the emitter sees only monomorphic methods. | Reified generics with `DefineGenericParameters`, JIT specialisation as the strategy doc §9.1 calls for. | `Lyric.Emitter.Codegen.emitCall` has no `ldtoken`/generic-arg handling. |
| `async` / `await` | ~~**Blocking shim**~~ **SUPERSEDED** — real `IAsyncStateMachine` state machines ship for await-free bodies (Phase A, D-progress-033) and bodies with awaits at safe positions (Phase B through B+++, D-progress-034..076). The M1.4 blocking `.GetAwaiter().GetResult()` fallback is retained only for ineligible await shapes (awaits in expression positions where stack-spilling fails). Generators with `await` in the body remain deferred (Gap-4a, D070). | A C#-style state machine per the strategy doc §13. | Fully implemented in `Lyric.Emitter.AsyncStateMachine`. |
| `extern package` (FFI) | **Hand-extended `Lyric.Stdlib`** — every BCL surface the banking example needs (`std.io.File`, `std.collections.List`, …) is added to the F#-side stdlib shim and the emitter resolves `extern package` references against that table. | Reflection-driven binding to arbitrary BCL types named in `extern package` blocks. | `Lyric.Stdlib.Interop` carries the curated list; out-of-table externs surface as `E0030`. |

Two further M1.4 simplifications are documented but smaller in
mechanism:

* `@runtime_checked` mode is the only contract evaluation mode in M1.4;
  `@proof_required` parses but produces no proof obligations. (`@axiom`
  contracts are trusted, matching their Phase 4 behaviour.)
* `old(_)` inside ensures-clauses is rejected with a `T0080` diagnostic
  rather than evaluated against a snapshot. The snapshot machinery
  belongs to the full proof obligations work and would otherwise sit
  here as half-implemented dead code.

**Rationale:**

- Each full lowering is multi-week work that the strategy doc treats
  as Phase 2 / Phase 4 territory. Doing them in M1.4 would either
  push the milestone out by months or yield half-built versions that
  later have to be torn out.
- The bootstrap-grade lowerings preserve the *interface* the rest of
  the compiler sees: monomorphic generics still type-check identically;
  blocking async still satisfies `Task<T>` consumers; the FFI shim
  presents the same `extern package` shape user code references.
- The banking example (per `docs/02-worked-examples.md` §1) compiles
  and runs end-to-end with these lowerings — the M1.4 exit criterion
  per the implementation plan.

**Alternatives considered:**

- **Reified generics in M1.4.** Rejected: the `DefineGenericParameters`
  + `MakeGenericMethod` machinery interleaves with how method tables
  are emitted in the M1.3 backend; building it correctly under
  `PersistedAssemblyBuilder` is non-trivial and would block
  contracts/async/FFI behind a refactor.
- **Real async state machines.** Rejected: state-machine generation
  needs a control-flow-graph pass, async-state-table emission, and
  `IAsyncStateMachine`/`AsyncTaskMethodBuilder` plumbing — a slice
  larger than M1.3 itself.
- **Reflection-driven `extern package`.** Rejected: the M1.3 emitter
  doesn't yet read `[Lyric.Contract]`-style attribute metadata, and
  the banking example covers a closed set of BCL surface that a
  hand-list resolves cleanly.

**Tracked follow-ups:**

- Phase 2 work plan (per `docs/05-implementation-plan.md` §"Phase 2")
  picks up reified generics.
- Phase 4 work plan picks up `@proof_required` proof-obligation
  generation and `old(_)` snapshotting.
- The Stdlib shim's contents become the seed of `std.core` /
  `std.io` once the package manager lands (Phase 3).
**Revisions:** The `async` / `await` row is SUPERSEDED. Real
`IAsyncStateMachine` state machines landed across D-progress-033
(Phase A, await-free), D-progress-034..040 (Phase B, suspend/resume),
D-progress-041..043 (Phase B+, loop-with-await + promoted locals),
D-progress-054..058 (Phase B++, defer+await; B+++ try/catch+await;
for-with-await), D-progress-074..076 (stack-spilling, generic async),
and D-progress-261 (Gap-4a: async generators with internal `await`).
The blocking shim now applies only to ineligible fall-through shapes.

---

## D036: Bracketed generic-parameter syntax + default `in` parameter mode

**Status:** Accepted
**Date:** 2026-04-30
**Supersedes:** part of D004 (parameter mode mandatoriness)

### Context

Two ergonomic frictions surfaced once the bootstrap compiler had enough
syntax to write meaningful programs:

1. Generic-parameter declarations required the `generic` keyword as a
   prefix (`generic[T] func id(x: in T): T = x`).  At call/use sites
   the bracket form is already canonical (`Box[Int]`, `id[Int](42)`),
   so the prefix kept the declaration site visually misaligned with
   how everyone reads the type elsewhere.
2. Parameter mode (`in`/`out`/`inout`) was mandatory per D004.  In
   practice ~all parameters are `in`; the keyword was repeated so
   often that it functioned as visual noise rather than as
   intentional documentation of the rare cases where mode actually
   matters.

### Decision

1. **Generic-parameter declarations** accept a bare-bracket form
   immediately after the declared name:
   ```
   func id[T](x: T): T = x
   record Box[T] { value: T }
   union Result[T, E] { case Ok(value: T) | Err(code: E) }
   ```
   The legacy `generic[T]` prefix continues to parse; both produce
   identical ASTs.  New code prefers the bracket form.

2. **Parameter modes** are now optional.  An omitted mode keyword is
   taken as `in`.  Explicit `out` and `inout` remain required where
   wanted; the parser still preserves explicit `in` keywords so
   migration is incremental.  Per-param mixed-style is legal:
   ```
   func divmod(n: Int, d: Int, q: out Int, r: out Int) { ... }
   ```

### Rationale

- Aligns with C# / F# / Rust / TypeScript conventions for both type
  parameters and parameter modes (which all of those default to
  read-only).
- Eliminates two classes of syntactic noise without losing
  expressiveness; explicit modes remain available for the cases that
  actually need them.
- Parser ambiguity is bounded.  The bare `[` only appears at
  declaration-name position where no other production starts that
  way, and array sizes always follow a *type expression* (`Int[10]`),
  not a declared identifier.

### Consequences

- Language reference §2.11 and §5.1 updated accordingly.
- Grammar `Param` and `GenericParams` productions accept both forms.
- `core.l` and worked examples retain their explicit `in` keywords
  for now; the convention will drift toward terse style as new code
  lands.
- Diagnostic `P0160` (missing parameter mode) is retired: there is
  no longer any "missing" mode.

### Tracked follow-ups

- A `lyric fmt` rule once the formatter exists may rewrite legacy
  forms toward the new canonical style.

**Revisions:** None.

---

## D037: Methods in type body desugar to UFCS-style `Type.method` functions

**Status:** Accepted
**Date:** 2026-04-30

### Decision

A `record`, `opaque type`, or `exposed record` body may include
`func` members alongside fields and invariants:

```
record Point {
  x: Int
  y: Int

  func length(self: in Point): Int = self.x * self.x + self.y * self.y
  func translate(self: in Point, dx: Int, dy: Int): Point =
    Point(x = self.x + dx, y = self.y + dy)
}
```

Methods inside the type body are pure syntactic sugar.  The parser
hoists each `func` member to a top-level function whose name is
`<TypeName>.<methodName>` — exactly the form already accepted at
top level today (`pub func ParseError.message(e: in ParseError):
String = …`).  Calls of the form `value.method(args)` resolve via
the existing UFCS dispatch (D036 / PR #22): the codegen looks up
the dotted function name on `ctx.Funcs` / `ctx.ImportedFuncs` and
emits a direct static call.

The receiver is **explicit** in v1: the first parameter must be
named `self` and typed against the enclosing type.  Implicit
`self` injection (so the user can write `func length(): Int =
self.x * self.x + …`) is a follow-up that needs AST rewriting of
`self` references inside the method body — tracked but not in
this slice.

### Rationale

- C# / Kotlin / Swift / Rust all support data + behaviour at one
  declaration site; Lyric's split between `record` and `impl` is
  technically clean but cognitively noisy for the overwhelmingly
  common case of "this function operates on this type."
- Pure syntactic sugar means the type checker, emitter, and proof
  system see the same UFCS-style top-level functions they already
  understand.  No new dispatch path, no new metadata, no new
  semantic surface area.
- `impl` blocks remain the canonical form for interface
  satisfaction (`impl Repository[User, UserId] for PgRepo { … }`);
  inline methods are inherent only.

### Alternatives considered

- **Add a new `RMMethod` AST node and dedicated codegen path.**
  Rejected — duplicates work for no semantic gain.  The hoist-to-
  top-level approach is one parser pass and zero downstream
  changes.
- **Auto-inject `self: in <Type>` and rewrite `self` references
  inside the body.**  Rejected for v1 — needs an AST walk that
  rebinds `ESelf` to the parameter named "self".  Cleaner to
  ship explicit-self first and layer the sugar on top once the
  rest of the desugar is stable.
- **Class-style inheritance syntax (`record Foo : Base[T] { … }`).**
  Rejected — superficial familiarity at the cost of misleading C#
  developers into expecting `override` and `base` calls (which
  Lyric explicitly rejects per D012).  The `impl X for Y` form
  stays as the only way to declare an interface relationship.

### Consequences

- Language reference §2.3 / §2.5 / §2.10 will note inline-method
  syntax as accepted.
- Grammar `RecordMember` adds `FunctionDecl` as a valid member.
- Parser hoist runs once per `SourceFile` after item parsing
  completes; the resulting `Item list` is indistinguishable from
  hand-written UFCS-style functions.
- Diagnostic surface unchanged — typos in the method body or
  signature surface as ordinary parse / type / codegen errors
  against the synthesised top-level function.

### Tracked follow-ups

- Implicit `self`: after this lands, add an AST pass that
  rewrites `self` inside hoisted methods to a parameter named
  "self", and inject the parameter automatically when the user
  omits it.
- `opaque type` and `exposed record` bodies should accept the
  same method syntax as `record` once it lands; the parser
  already handles all three through `parseRecordMembers`.

**Revisions:** None.

---

## D038: Native stdlib over BCL wrappers — phased migration

**Status:** ACCEPTED

**Decision:** The stdlib's *implementation depth* migrates from
"Lyric API surface over BCL types and an F# shim" (D035 / the
`10-stdlib-plan.md` "BCL underneath" stance) to "Lyric API surface
over Lyric implementations down to a small audited extern kernel."
The phased plan, language-gap inventory, module-by-module table,
validation strategy, and perf budgets live in
`docs/14-native-stdlib-plan.md`. Seven sub-decisions resolved
together, summarised here:

| Sub-decision | Resolution |
|---|---|
| **A: G3 timing** | A1 — land `where` clauses before native module work. |
| **B: HashMap collisions** | B2 — chaining for first cut. |
| **C: Perf budget** | C1 — "reasonable" (~2-5× BCL). |
| **D: Naming** | A — replace (`Std.List[T]` is native; `Std.Bcl.List[T]` for raw BCL). |
| **E: Tracking** | E1 — D038 (this entry); Q021 opened for G3 specifically. |
| **F: Kernel cap** | Original: 150 extern declarations as a v1.0 release gate. **Amended (2026-06):** actual ceiling raised to 317 as stdlib scope exceeded the original estimate; see `docs/14-native-stdlib-plan.md` §10 Decision F annotation and `KernelBoundaryTests.fs`. |
| **G: Start order** | P0 immediately; G3 begins toward end of P0. |

**Alternatives considered:**

- **Status quo (D035 indefinitely).** Keep the F# shim as the stdlib
  implementation; add to it as needed. Rejected: forfeits the
  verification surface (each shim entry is a reasoning black box for
  the prover), forfeits the range-subtype perf payoff, and pushes
  the entire stdlib reimplementation cost into Phase 5 self-hosting.
- **All-Lyric stdlib (no kernel).** Implement everything in Lyric,
  including transcendentals, regex, JSON tokenizer, TLS. Rejected:
  multi-year reimplementation of mature, hardware-tuned BCL surfaces
  with no language-level payoff. Every language has a syscall floor;
  pretending otherwise is a lie.
- **Pivot per-module without a plan.** Convert modules opportunistically
  as language features land. Rejected: leads to inconsistent
  treatment across the stdlib and no shared budget for the externs
  that remain. The §3 kernel-and-cap structure forces explicit
  trade-offs.

**Rationale:**

- **Verification surface.** Native data structures carry invariants
  (`length >= 0`, `length <= capacity`) the prover sees and uses;
  `@axiom`-marked extern targets are reasoning black boxes. This is
  load-bearing for Phase 4 (`docs/05-implementation-plan.md`).
- **Range-subtype payoff.** A native `List[T]` indexed via
  `Int range 0 ..= length - 1` discharges bounds checks at compile
  time per `01-language-reference.md` §2.7. Wrapped BCL types
  cannot tell this story.
- **Self-hosting (Phase 5).** Doing data structures in Lyric earlier
  de-risks the Phase 5 rewrite of the bootstrap compiler in Lyric.
- **Audit cost is finite.** Decision F caps the trusted extern boundary;
  the CI ratchet in `KernelBoundaryTests.fs` enforces it by requiring every
  addition to update the hard ceiling with a justification comment.
- **Bootstrap-grade is not v1.0.** D035 explicitly framed the F#
  shim as a Phase 1 / M1.4 expedient. D038 sets the direction for
  the post-bootstrap stdlib without contradicting D035.

**Relation to D035:** D038 does not supersede D035. D035 governs
M1.4-era lowerings (generics, async, FFI shim) shipped in
*bootstrap-grade* form; D038 governs how those shims are dismantled
once the language features needed to replace them land. The F# shim
shrinks across P0-P3 of the §6 plan; the residual is the audited
kernel of §3.

**Relation to `10-stdlib-plan.md`:** That doc owns *what* the stdlib
offers (API surface, error model, phasing of Result/Option). D038 +
`14-native-stdlib-plan.md` own *how deep* each surface is implemented
in Lyric. Both docs coexist; cross-references added.

**Revisions:**
- **2026-06 (Decision F amendment):** The original ≤150 cap predated the
  full stdlib scope. After shipping `Std.Http.Server`, `Std.Char` / `Std.Unicode`,
  `Std.AssemblyResources`, `Std.Task` async-local, and testing-mock surfaces, the
  actual ceiling stands at 317.  `KernelBoundaryTests.fs` now enforces this as a
  hard ratchet (any addition must update the ceiling constant and add a comment).
  The v1.0 gate is "no unreviewed growth" (ratchet passes), not "≤150."  See
  `docs/14-native-stdlib-plan.md` §3 and §10.

---

## D039: `lyric fmt` and the CST infrastructure deferred to Phase 5

**Date:** 2026-05-04.

**Decision.** The `lyric fmt` formatter (and the Concrete Syntax
Tree layer it depends on) moves from a Phase 3 / v1.0 deliverable
to a Phase 5 deliverable. v1.0 ships without `lyric fmt`.

**Context.** `05-implementation-plan.md` listed `Formatter
(lyric fmt)` as a Phase 3 v1.0 deliverable and assigned it to
M3.3 alongside LSP and the doc generator. The C7 decision in
`12-todo-plan.md` (D-progress-029) already deferred `lyric fmt` to
Tier 6 because a round-trip-faithful printer needs a CST layer the
bootstrap parser doesn't carry, and the CST is a multi-week
project that pays off most when the LSP and refactor tools want
token-position-faithful traversal. Holding the formatter at v1.0
priority while shipping it Tier-6 was a contradiction.

**Why Phase 5 specifically.** The self-hosting port (Phase 5)
re-implements the lexer and parser in Lyric. Building the CST
into the *self-hosted* parser from day one is cheaper than
retrofitting it into the bootstrap parser and then porting both
pieces. The LSP / refactor tools that the CST primarily benefits
also live on the self-hosted side. Phase 5 already lists "LSP and
formatter" as part of M5.3 (`05-implementation-plan.md` §"Phase
5"); D039 makes the formatter half of that line authoritative.

**Consequence.** v1.0 release criteria no longer block on
`lyric fmt`. The Phase 3 testing budget of "~1000+ tests (LSP,
formatter, wire all get extensive coverage)" drops `formatter`.
Users who need formatting in v1.0..v1.x rely on community
conventions; no first-party tool. Tracked as Phase 5 / Tier 6 in
`12-todo-plan.md` (entry 11) and as M5.3 in
`05-implementation-plan.md`.

**Alternatives considered.**

- **Ship a stopgap line-based formatter without CST.** Rejected:
  building the formatter twice costs more than waiting, and a
  stopgap that loses comments / blank lines is worse than no
  formatter (users would distrust both the tool and the canonical
  style it produces).
- **Build the CST during Phase 3 to keep the formatter at v1.0.**
  Rejected: 1500-2500 LOC of plumbing across the lexer, parser,
  and every AST consumer (per D-progress-029) competes with the
  Phase 4 proof-system push for the same maintainers' time and
  doesn't unblock anything else on the v1.0 critical path.

**Revisions:** None.

---

## D040: `@stable(since="X.Y")` / `@experimental` stability annotations

**Status:** ACCEPTED
**Date:** 2026-05-04

### Decision

Stability is expressed through two annotations on `pub` items:

- `@stable(since="X.Y")` — the item's API will not break without a SemVer major bump from version X.Y onward.
- `@experimental` — the item may change or be removed at any time; no SemVer guarantee.

Unannotated `pub` items are treated as stable for enforcement purposes (conservative: omitting `@experimental` is not license to depend on one).

The compiler enforces one direction: a non-experimental `pub` function may not call an `@experimental` item in the same source file. Diagnostic `S0001` is emitted at the call site. `S0002` fires when both `@stable` and `@experimental` are present on the same item.

`lyric public-api-diff` (D-progress-062) uses the `Stability` field in `Lyric.Contract` metadata to decide whether a removal or signature change is SemVer-major: removing / changing `@experimental` surface is a no-op SemVer-wise; removing / changing `@stable` surface is a major bump.

### stdlib cut (Q011)

Every `pub` item in `stdlib/std/` is annotated. See `docs/10-stdlib-plan.md` §"Stability cut" for the full table.

Summary:
- **Experimental:** `Std.Testing.Property`, `Std.Testing.Snapshot`, `Std.CoreProof`; HTTP retry/cancel/timeout helpers; time DTO-conversion and timezone-lookup helpers.
- **Stable (`since="1.0"`):** `Std.Errors`, `Std.Parse`, `Std.Testing` (assertEqual/assertEqualInt/assertTrue/assertPanics/assertPanicsWith — see #1176 for the latter two), `Std.Collections`, `Std.String`, `Std.Console`, `Std.File`, `Std.Iter`, `Std.Math`, `Std.Stream`, `Std.Log`, `Std.Path`, `Std.Environment`, `Std.App`, `Std.Directory`, `Std.Json`, core HTTP types and methods, core time operations.

### Alternatives considered

- **Doc-comment convention (`// stability: stable`).** Rejected: invisible to the compiler; cannot be enforced or embedded in contract metadata; hard to diff.
- **Package-level stability (all-or-nothing).** Rejected: too coarse. `Std.Http` has a stable core and an experimental cancel/timeout wing; splitting into two packages would be worse for discoverability.
- **Opt-in stable (default experimental).** Rejected: too noisy. Requiring `@stable` on every production function would make new code look experimental by default.

### Rationale

- An annotation on the declaration is the right scope: it appears in source, in LSP hover, and in generated docs.
- Embedding the stability string in `Lyric.Contract` metadata is load-bearing: `lyric public-api-diff` and future package tooling read it without re-parsing source.
- The one-direction enforcement rule (stable must not call experimental intra-package) catches the most common mistake — accidentally depending on something you intend to stabilize — without over-constraining experimental code.
- Cross-package stability enforcement (a stable package can't import an experimental package) is deferred until the contract-metadata reader (`Lyric.Verifier.Imports`) can carry the stability field per-decl.

### Tracked follow-ups

- Cross-package S0001 (stable code depending on experimental cross-package declaration) requires extending `Imports.fs` to carry per-decl stability from the embedded `Lyric.Contract` resource.
- `lyric doc` (future) should render stability badges next to items.
- Synthesised `fromJson` / `toJson` from `@derive(Json)` should carry `@experimental` in the emitted contract until Phase 2 stabilizes the derive mechanism.

**Revisions:** None.

---

## D041: JVM stdlib kernel uses platform-selected directories

**Status:** ACCEPTED
**Date:** 2026-05-06

### Decision

The JVM stdlib kernel lives in `stdlib/std/_kernel_jvm/`.  The build
driver selects the directory based on the active compilation target:
`--target=jvm` uses `_kernel_jvm/`, the default .NET path uses
`_kernel/`.  Package names inside both trees are identical (`Std.IO`,
`Std.MathHost`, `Std.CollectionsHost`, etc.) so the safe-API layer
(parent `std/` files) requires no changes.

`@externTarget` strings remain single-platform — one string per
declaration.  Platform-selection happens at the file level, not the
annotation level.

### Alternatives considered

- **Stacked `@externTarget` with `platform=` qualifier.**  A single
  declaration would carry `@externTarget("System.Math.Sin",
  platform=dotnet)` and `@externTarget("java.lang.Math.sin",
  platform=jvm)` on the same function.  More DRY for 1:1 mappings,
  but requires a language change (new optional parameter on the
  annotation), and breaks down for `extern package` blocks and
  `extern type` aliases where structural divergence between platforms
  is not merely a string difference — the JVM kernel does not use
  `extern package` pointing to BCL-style static classes; it points to
  `lyric.stdlib.jvm.*` shims or direct `java.*` methods depending on
  the operation.

- **Fully separate kernel package (`Std.Kernel.Jvm`).**  Would force
  conditional `import` in every safe-API file, spreading
  platform-conditional logic into code that should be
  platform-neutral.

### JVM shim layer

The JVM kernel targets `lyric.stdlib.jvm.*` wrapper classes
(analogous to `Lyric.Stdlib.*` on .NET) for operations where the JVM
API differs structurally from the declared Lyric surface:

- **Parse**: Java's `Integer.parseInt` throws on failure; the shim
  provides `TryParse`-style out-parameter + Bool semantics.
- **Time**: `java.time.*` method names differ from .NET's
  `System.DateTime`/`System.TimeSpan`; duration constructors take
  `long` where Lyric declares `Double`; shims handle conversion.
- **Collections**: Java's `HashMap.get` returns `null` on miss; the
  shim provides `tryGetValue`'s out-parameter + Bool pattern.
- **Math**: `sign` (Java returns `double`, Lyric declares `Int`),
  `log2`, `tau`, and `truncate` (absent from `java.lang.Math`) route
  through `lyric.stdlib.jvm.MathHost`.

Where the JVM provides a direct static-method or static-field
equivalent the kernel points to it directly (e.g.
`@externTarget("java.lang.Math.sin")`,
`@externTarget("java.time.Instant.now")`) without an intermediate
shim.

### Kernel cap

The 150-declaration cap (D038) applies per directory; the JVM kernel
has its own budget.  Before the JVM target ships, a parallel
`KernelBoundaryTests` probe for `_kernel_jvm/` must be added to
`compiler/tests/Lyric.Emitter.Tests/KernelBoundaryTests.fs`.

### Tracked follow-ups

- `KernelBoundaryTests.fs` needs a JVM-kernel probe once
  `--target=jvm` is wired into the build driver.
- `lyric.stdlib.jvm.*` shim classes (Java-side) are a Phase 6
  deliverable; their API surface is determined by the `@externTarget`
  strings in `_kernel_jvm/`.
- Q011 in `docs/18-jvm-emission.md` ("Stdlib API surface: deferred to
  a separate JVM stdlib doc") is partially addressed by this
  directory; a follow-up doc should cover the full safe-API surface
  for the JVM target.

**Revisions:** None.

---

## D042: Phase 6 stdlib distribution — SDK root discovery + `Lyric.SdkVersion`

**Status:** ACCEPTED
**Date:** 2026-05-07

### Decision

Phase 6 distribution tooling (`docs/22-distribution-and-tooling.md`)
ships as three cohesive pieces:

1. **SDK root discovery** (`Lyric.Emitter.SdkRoot`): `LYRIC_SDK_ROOT`
   env-var first; binary-relative `lib/Lyric.Stdlib.dll` walk second;
   `NotFound` otherwise.  B0040 fires (error) when `LYRIC_SDK_ROOT` is
   set but the DLL is absent.

2. **`Lyric.SdkVersion` embedded resource**: `emitProject` writes a
   compact JSON resource into every project-mode DLL immediately after
   the per-package `Lyric.Contract.*` resources.  Four fields:
   `language_version`, `stdlib_version`, `compiler_version`,
   `build_date`.  B0042 fires (warning) when `tryReadSdkVersion` can
   read a DLL but finds no such resource.

3. **`lyric --sdk-info` command**: reads the SDK root, prints the four
   version fields, and exits 1 when `LYRIC_SDK_ROOT` is set but the
   DLL is not found.

The VS Code extension (§6 of `docs/22`) is deferred: it requires a
separate TypeScript build toolchain outside the F# solution.

### Rationale

- Mono.Cecil's `InMemory = true` flag is used for all DLL reads so
  there is no file lock on Windows and no AppDomain pollution.
- Binary DLL fast path in `ensureStdlibArtifact` means a deployed SDK
  skips source-tree re-compilation entirely; the `stdlibArtifactCache`
  ensures the DLL is read at most once per process.
- `itemConflictKey`-based dedup on `mergedImportedItems` in
  `emitProject` fixes a latent duplicate-symbol error that surfaced
  when in-project packages both (a) explicitly import `Std.Core` and
  (b) depend on a kernel package whose stdlib artifact auto-adds
  `Std.Core` through `resolveStdlibImports`.

### Alternatives considered

- **Embed version via Cecil post-process rather than in-emitter.**
  Rejected: the emitter already calls `ContractMeta.embedIntoAssemblyAs`
  and adding a second resource in the same pass avoids a second Cecil
  open/save cycle.
- **Walk `$PATH` for the SDK root.**  Rejected: convention-over-PATH
  discovery adds OS-specific complexity; env-var + binary-relative
  covers both installed and developer-tree deployments cleanly.

### Stdlib bundle exclusions

`Std.Environment` and `Std.Log` are excluded from `stdlib/lyric.toml`
because their kernel packages (`Std.EnvironmentHost`, `Std.LogHost`)
use `extern package {}` syntax.  The type checker's `registerItem`
returns `None` for `IExtern`, so the `EMSig` members inside the block
are never entered into the symbol table.  Re-inclusion path: rewrite
`environment_host.l` and `log_host.l` to use `@externTarget pub func`
declarations, matching the pattern in `math_host.l`.

**Revisions:** None.

---

## D043: Stdlib expansion — sort, set, char, format, encoding, uuid

**Date:** 2026-05-07
**Status:** Accepted

**Context:**
The initial stdlib (`Std.Core`, `Std.Collections`, `Std.Math`, `Std.String`,
`Std.Testing`) covered only the constructs needed by the worked examples and
bootstrap compiler.  Compared to the Java and .NET base class libraries several
broadly-useful capability areas were missing: ordered sequence manipulation,
set algebra, character classification, formatted number and string output,
binary encoding (Base64, hex, UTF-8), and UUID generation.  These are needed
by realistic application code and by the stdlib tests themselves.

**Decision:**
Add six new top-level packages and three new combinators to `Std.Core`:

| Package | File | Content |
|---|---|---|
| `Std.Sort` | `stdlib/std/sort.l` | Top-down stable merge sort (`sort[T]`, `sortInts`, `sortBy`) |
| `Std.Set` | `stdlib/std/set.l` | Unordered set backed by `HashSet<T>` (`setContains`, `setAdd`, `setRemove`, `setUnion`, `setIntersect`, `setDifference`, `setFromSlice`, `setSize`, `setIsEmpty`) |
| `Std.Char` | `stdlib/std/char.l` | Character classification and conversion (`isLetter`, `isDigit`, `isWhiteSpace`, `isUpper`, `isLower`, `toUpper`, `toLower`, `charToInt`, `intToChar`, `digitValue`, `isAscii`, `isAsciiAlpha`, `isAsciiAlphaNum`, `isPunctuation`) |
| `Std.Format` | `stdlib/std/format.l` | Number and string formatting (`toHexString`, `toHexStringUpper`, `formatFixed`, `padLeft`, `padRight`, `zeroPad`, `hexPad`, `hexPadUpper`) |
| `Std.Encoding` | `stdlib/std/encoding.l` | Binary encoding (`encodeBase64`, `tryDecodeBase64`, `encodeHex`, `tryDecodeHex`, `encodeUtf8`, `tryDecodeUtf8`) |
| `Std.Uuid` | `stdlib/std/uuid.l` | UUID generation and parsing (`newUuid`, `nilUuid`, `uuidToString`, `parseUuidOpt`) |

`Std.Core` additions: `andThen[T,U]`, `orElse[T]`, `andThenResult[T,U,E]` —
monadic flatmap/chaining combinators for `Option[T]` and `Result[T,E]`.

Kernel additions (`./_kernel/` and `./_kernel_jvm/`):
- `char_host.l` (`Std.CharHost`) — `System.Char` and `System.Convert` bridges
- `format_host.l` (`Std.FormatHost`) — formatting via F# `FormatHost` shim
- `encoding_host.l` (`Std.EncodingHost`) — Base64, hex, UTF-8 via F# `EncodingHost` shim
- `uuid_host.l` (`Std.UuidHost`) — `System.Guid` extern type + helpers
- `collections_host.l` additions — `Set[T]` extern type, `newSet`, `setToSlice` via F# `SetHost.SetToArray` shim

Each kernel file carries `@axiom` to document trust in the BCL/JVM contracts.
JVM mirrors added under `./_kernel_jvm/`, routing through `lyric.stdlib.jvm.*`
shim classes where the JDK API shape differs.

New F# shim types added to `compiler/src/Lyric.Stdlib/Stdlib.fs`:
`SetHost`, `FormatHost`, `EncodingHost`.  Shims are needed where the BCL target
is a LINQ extension method, requires a static-property accessor chain, has
overload-resolution ambiguity, or requires a try/catch boundary.

Tests added to `stdlib/tests/`: `sort_tests.l`, `set_tests.l`, `char_tests.l`,
`format_tests.l`, `encoding_tests.l`, `uuid_tests.l`, plus extensions to
`core_tests.l` for the three new combinators.

**Rationale:**

*Sort*: Sort is the single most commonly needed algorithm; implementing it in
pure Lyric (top-down merge sort over `slice[T]`) exercises generics, closures,
and recursive calls and doubles as a self-test of the emitter's generics path.
Merge sort was chosen over quicksort for stability and worst-case O(n log n)
guarantees.

*Set*: Hash-based sets are part of every practical general-purpose stdlib.
Backing by `HashSet<T>` / `java.util.HashSet` gives O(1) amortised membership
for free; the conversion-to-slice pattern avoids requiring the emitter to
support `IEnumerable<T>` directly.

*Char*: Applications almost always need to inspect individual characters.
Routing through `System.Char` / `java.lang.Character` ensures Unicode-correct
behaviour for classification; ASCII fast-paths are implemented purely in Lyric
to keep the kernel footprint small.

*Format*: `Int.ToString("x")` and `Double.ToString("F2")` have overloads that
are tricky to target directly; wrapping in F# shims is cleaner than encoding
format-string overload selection in the emitter.

*Encoding*: Base64, hex, and UTF-8 are the three encoding primitives most
frequently needed for wire interchange and logging.  `Option`-returning decode
functions match the Lyric idiom for fallible operations.

*UUID*: UUIDs are the standard primary-key type for distributed systems;
`System.Guid` / `java.util.UUID` provide cryptographically-random generation
on both targets.

**Alternatives considered:**

- *Route sort through BCL `Array.Sort`*: rejected because it requires a
  `Comparison<T>` delegate, which the current emitter does not yet lower
  closures to; pure-Lyric merge sort avoids this and is more instructive.

- *Expose `IEnumerable<T>` iteration directly*: rejected for now; the emitter's
  `for` loop is currently array-specialised.  `setToSlice` bridges the gap
  without changing the emitter.

- *Single `Std.Extras` umbrella package*: rejected; separate packages let
  callers import only what they need and keep kernel files under the 150-
  declaration audit limit.

**Follow-up tracked:**

- When the emitter supports `IEnumerable<T>`, replace `setToSlice` + `for` with
  direct set iteration in `set.l`.
- If closure-to-delegate lowering lands, consider adding a BCL-backed sort path
  (`Array.Sort`) as an alternative to the merge sort for large slices.
- JVM shim classes (`lyric.stdlib.jvm.*`) need to be published alongside the
  BCL shim DLL as part of the Phase 6 SDK package (see D042).

---

## D044 — CLI migration strategy: pure BCL externs, no new F# shim

**Date:** 2026-05-07  
**Branch:** claude/migrate-lyric-cli-3WDhT

### Context

Phase 5 §M5.3 targets a self-hosted Lyric CLI.  The F# bootstrap CLI
(`compiler/src/Lyric.Cli/Program.fs`) spawns child processes via
`ProcessStartInfo.ArgumentList.Add(...)` — a mutable generic collection.
The straightforward port would have required either a new F# shim method
(against the G-series shim-elimination direction) or a complex generic-FFI
path that the emitter's `paramsExactMatch` doesn't support for covariant
types.

### Decision

Use `Process.Start(string, string)` — the two-argument overload — so child
process creation goes through a BCL extern with an exact CLR type signature
(`[typeof<string>, typeof<string>]`).  Argument quoting (spaces, embedded
double-quotes) is handled in pure Lyric in `buildArgString`.  The kernel
boundary is:

```
stdlib/std/_kernel/process_host.l   @axiom + extern type ProcessHandle + 3 extern funcs
stdlib/std/process.l                Std.Process — run / runChecked surface API
```

No new F# shim was added.  `Lyric.Manifest` (TOML parser) and `Lyric.Cli`
(command dispatch) are written entirely in Lyric under
`compiler/lyric/lyric/`.

### Forward imports

`Lyric.Cli` imports `Lyric.Parser`, `Lyric.Emitter`, `Lyric.Fmt`,
`Lyric.Lint`, `Lyric.Verifier`, `Lyric.Doc`, and `Lyric.ContractMeta` with
`as` aliases.  These packages do not yet exist; they are the deliverables for
the remainder of M5.2 and M5.3.  The CLI file is compiled only by the
self-hosted compiler (which won't run until those packages ship), so forward
references are safe.  The CLI source documents the expected API surface in
header comments, acting as the consumer contract that future packages must
satisfy.

### Rationale

- Consistent with the G-series shim-elimination work (`docs/23-fsharp-shim-elimination.md`).
- Keeps the kernel boundary reviewable; `KernelBoundaryTests` enforces the
  count.
- Writing the CLI consumer first (before the packages it calls) pins the API
  surface early and keeps Phase 5 milestones aligned.

**Revisions:** None.

---

## D058: Self-hosted MSIL PE emitter — Stage M1 approach

**Date:** 2026-05-07
**Status:** Accepted

**Context:**
Phase 5 §M5.2 requires a self-hosted MSIL emitter written in Lyric itself.
Three implementation approaches were considered:

a) **Full reflection-driven emitter** — mirror `System.Reflection.Emit` calls
   from pure Lyric, requiring extensive FFI surface and a non-trivial
   extern-type footprint.

b) **Raw PE bytes ("option b, raw")** — emit the PE/COFF/CLR binary directly
   as a sequence of little-endian byte writes, analogous to how the JVM emitter
   produces raw `.class` files.  No new F# host code needed; reuses the
   existing `Lyric.Jvm.Hosts.JvmByteBuilder` infrastructure.

c) **Hybrid** — Lyric-side metadata tables serialised to a byte buffer, handed
   off to a thin F# host that assembles the final PE.

**Decision:**
Adopt option (b).  Stage M1 ships a fixed-layout, 1024-byte PE image for a
"Hello, World!" assembly.  The `Msil.Kernel` package declares
`extern type ByteWriter = "Lyric.Jvm.Hosts.JvmByteBuilder"` and re-exports
the existing LE write helpers; no new F# code is required.  `Msil.Pe`
implements the full ECMA-335-conformant binary layout in pure Lyric.
Later stages (M2+) parameterise the serialiser to accept arbitrary type
tables; Stage M1 provides the structural foundation and smoke test.

**Rationale:**
- The JVM kernel already provides all the byte-write primitives needed for
  little-endian PE output; adding a second extern type pointing at the same
  CLR class is zero-cost.
- A raw-bytes approach keeps the Lyric surface minimal (no `Reflection.Emit`
  dependency), is easily auditable, and matches the existing JVM emitter
  design precedent.
- The fixed-layout Stage M1 file gives a complete, runnable test of the PE
  format knowledge before parameterisation complexity is introduced.

**Constraints noted:**
- `List[Byte].length` is not directly available; size checking uses
  `bufLen(w: ByteWriter): Int` on the raw buffer before conversion.
- Multi-line boolean expressions must use the `and` keyword; `&&` is not a
  valid binary infix operator in Lyric (the lexer does not tokenise it as a
  single token, and the parser currently sees `& &` as two prefix-ref ops).
- `isBuiltinHead` in `Emitter.fs` extended to include `"Msil"`, mapping
  `import Msil.X` to `compiler/lyric/msil/`.

**Follow-up tracked:**
- Stage M2: parameterise `Msil.Pe` to accept a `PeModule` record with
  arbitrary type/method/field tables.
- Stage M3: integrate into the self-hosted type-checker output pipeline so
  `lyric build` can drive the pure-Lyric MSIL path end-to-end.

**Revisions:** None.

---

## D045 — Build-time feature gating via `[features]` + `@cfg(...)`

**Date:** 2026-05-07
**Branch:** claude/compile-time-aspects-logging-SIhqA

### Context

`docs/26-aspects.md` (compile-time aspects) needs a way to compile
out unwanted aspects without runtime overhead — a build flag that
erases an item entirely when off. Platform-specific code in the
stdlib (Windows vs Unix process shims, future) wants the same
mechanism. No existing primitive in Lyric serves both.

The Cargo precedent is well-understood: features declared in the
manifest, selectable via CLI, and source items gated via a
`@cfg(...)` annotation. Lyric's existing `lyric.toml` schema
(D-progress-077) extends naturally.

### Decision

Add a compile-time feature mechanism with three parts:

- A `[features]` section in `lyric.toml` declaring named features
  with implication arrays. `default = [...]` names the auto-active
  set.
- CLI flags `--features`, `--no-default-features`, `--all-features`
  on `lyric build` / `run` / `test` / `prove` / `publish`. The
  active feature set is fixed for one build and recorded in the
  output's `Lyric.BuildInfo` resource.
- A `@cfg(...)` annotation on top-level items (`func`, `type`,
  `aspect`, `wire`, `config`, `package`). Predicate grammar:
  `feature = "X"`, `all(...)`, `any(...)`, `not(...)`. When false,
  the item is erased — no metadata, no IL, imports referencing
  it fail at the import site.

Cross-package feature plumbing is **deferred** (Q-features-001).
Statement- and expression-level `@cfg` is **out of scope**.

Full specification in `docs/24-build-features.md`.

### Rationale

- **Aspects need it.** The aspect feature `docs/26-aspects.md` is
  blocked without compile-time gating; runtime-only gating leaves
  cost in builds that don't want the aspect.
- **General-purpose.** Feature gating recurs across language design;
  Cargo's fifteen years of experience is the strongest body of
  evidence for the additive-conjunctive shape.
- **Builds on existing infra.** `lyric.toml` already exists; the
  manifest parser (D-progress-077) is small. The `Lyric.BuildInfo`
  resource is parallel to the existing `Lyric.Contract` resource.
- **Cargo's cross-package unification problem is real.** Deferring
  it explicitly is better than half-implementing it; aspects
  (the immediate consumer) only need single-package gating.

### Alternatives considered

- **Aspect-only gating (no general feature mechanism).** An aspect
  could declare a flag and the compiler would gate the wrapper.
  Rejected: doesn't help the platform-specific stdlib case; bakes
  aspect assumptions into a primitive that should be general.
- **Boolean cfg flags only, no implications.** Simpler, but every
  Cargo user knows you need `tracing` to imply `logging` after
  about a week. Pre-empt the request.
- **Statement/expression-level `@cfg`.** Rust's design. More
  flexible, much more parser surface, more diagnostic complexity.
  Two functions with `@cfg` at the item level cover the use case.

**Revisions:**

- 2026-05-08 — **Q-features-001 closed** (cross-package feature
  unification).  Not applicable to Lyric's binary-distribution
  model: published `.dll`s pin the library's feature set at
  `lyric publish` time, so consumers cannot toggle features on
  a dependency the way Cargo allows (Cargo's source-distribution
  model is fundamentally different).  Library authors who want
  consumer-toggleable behaviour should use D046 runtime config
  instead.  Spec: `docs/24-build-features.md` §1.1 + §7 + §8;
  user-facing equivalent: book chapter 20 §20.7.1.

---

## D046 — Typed env-backed config blocks

**Date:** 2026-05-07
**Branch:** claude/compile-time-aspects-logging-SIhqA

### Context

Service-shaped Lyric programs need a typed way to read configuration
at startup — ports, DB URLs, log levels, sample rates, secrets.
Today the only path is hand-rolled `Std.Environment.getVar` calls
sprinkled across startup, with manual `tryParseInt` per field, no
fail-fast, and no central declaration of what a service reads.

Aspects (`docs/26-aspects.md`) need typed config to support runtime
toggles (log levels, sample rates) without inventing a new
mechanism. Promoting "typed env-var config" to a general primitive
serves both.

### Decision

Add a `config` block as a top-level item, peer to `func`, `type`,
`wire`, `aspect`. Each block declares a named record of typed
fields:

- **Field types:** primitives (`Bool`, `Int`, `Long`, `Float`,
  `Double`, `String`), range subtypes, simple enums, and lists
  `[T]` of any of the above. Records, maps, and nested lists are
  rejected.
- **Required vs defaulted:** a field with no `=` default is
  required; the process aborts with exit code 78 before `main`
  runs if the env var is unset / empty / unparseable.
- **Visibility:** package-private. `pub config` is rejected.
- **Env var derivation:** auto-derived as
  `LYRIC_CONFIG_<PKG>_<BLOCK>_<FIELD>`. A `via "NAME"` clause on a
  field overrides the auto-derived name.
- **Read-once-at-startup:** all fields populated once, before
  `main`; immutable thereafter.
- **Multiple named blocks per package** allowed; each independent.
- **`@sensitive` field marker** is parsed and recorded but
  declarative-only in v1 (no behaviour bound to it).

File-based sources, layered config, hot reload, and richer field
types are out of scope. Full specification in
`docs/25-config-blocks.md`.

### Rationale

- **Single mechanism for two consumers.** Application config and
  aspect runtime parameters share parsing, fail-fast behaviour,
  and env-var conventions. Building two parallel mechanisms would
  be wasted work.
- **Fail-fast over half-initialised.** A service that boots with
  half its config missing is worse than one that doesn't boot.
  Exit code 78 (sysexits.h `EX_CONFIG`) is the conventional signal.
- **Read-once keeps the verifier sane.** `Settings.port` is an
  opaque static `Int` from the verifier's perspective; no
  control-flow analysis needed for `@proof_required` packages.
- **Package-private avoids action-at-a-distance.** Cross-package
  config sharing is ambient global state; if package B wants
  package A's config, it should receive it through a wire
  parameter. Forcing this composes better with `@proof_required`.

### Alternatives considered

- **`Std.Config` library, not a language feature.** A function
  `Std.Config.read[T](field-name): T` with reflection-driven
  binding. Rejected: Lyric has no reflection (D006); a build-time
  primitive avoids the issue entirely.
- **Lazy / on-demand config reads.** Read each field the first
  time it's accessed. Rejected: hides startup-time errors until
  whichever code path first touches the field. Fail-fast is the
  right default.
- **Cross-package public config.** `pub config` exposing fields
  to importers. Rejected: encourages ambient global state and
  conflicts with the per-package contract model.

**Revisions:**

- 2026-05-08 — **Q-config-004 resolved.**  Config block field
  names, types, defaults, and `@sensitive` markers ship in
  the `Lyric.BuildInfo` resource so ops tooling can enumerate
  the env-var surface of a binary without running it.  Field
  *values* are not recorded (those are runtime-only).  Spec:
  `docs/25-config-blocks.md` §10.

- 2026-05-08 — **v2 sketch published** at
  `docs/29-config-v2-sketch.md` covering Q-config-001 (file
  source) and Q-config-002 (layered precedence).  Six
  tensions surfaced; four flagged as needing resolution
  before any v2 implementation.  v1 contract shift
  (required-field semantics across layers) flagged as
  needing its own decision-log entry on adoption.

---

## D047 — Compile-time aspects (`aspect` blocks)

**Date:** 2026-05-07
**Branch:** claude/compile-time-aspects-logging-SIhqA

### Context

Cross-cutting concerns — logging, timing, validation, authorisation,
metrics — recur in every service-shaped Lyric program. Today the
only way to apply them is per-method boilerplate, which violates
DRY and rots silently when new methods are added without it.

Lyric already has two precedents for "package-level declaration the
compiler reads and emits derived code from": `wire` blocks and the
`@projectable` / `@stubbable` annotation pair. Aspects extend the
same family.

The design tension is between AOP's classic cross-cutting cleanliness
and Lyric's safety-oriented ethos (explicit contracts, predictable
behaviour, no spooky action at a distance). The chosen design
resolves the tension by **scoping aspects to a single package**,
**making the composed contract the published contract**, and
**requiring strong tooling visibility** (LSP code-lens, `lyric
explain`).

### Decision

Add an `aspect` block as a top-level item, peer to `func`, `type`,
`wire`, `config`. The full specification is `docs/26-aspects.md`;
key points:

- **Package-scoped weaving.** An aspect declared in package P
  weaves only over P's own targets. Cross-package aspect
  application is rejected (not deferred).
- **`around`-only advice.** `before` / `after` desugar trivially
  and are not separate primitives. Skip / replace via early
  `return` or omitting `proceed(args)`.
- **Pattern selector via `matches:`.** v1 supports
  `name like "<glob>"` plus `except name in {...}`. Reserved syntax
  for `signature:`, `annotated:`, `visibility:` predicates in v2.
- **Per-target opt-out via `@no_aspect` / `@no_aspect("X")`.**
- **Contract augmentation.** Aspects may declare aspect-level
  `requires:` / `ensures:` clauses. The wrapper's effective
  contract is the conjunction of target + every matched aspect.
  Aspects cannot weaken or remove existing clauses but **can add
  to either side, including strengthening preconditions**. The
  composed contract is the published contract.
- **Composition order: lexical within file; explicit `wraps:` /
  `inside:` clauses across files.** Cross-file overlap without
  explicit ordering is a compile error (`A0007`).
- **Compile-time gating** via `@cfg(...)` (D045): erased aspects
  emit no wrapper, no metadata, no overhead.
- **Runtime configuration** via per-aspect `config { ... }`
  block (D046) with env prefix `LYRIC_ASPECT_<NAME>_<FIELD>`. No
  implicit `enabled` flag; aspects opt in to toggling explicitly.
- **`args` and `ret` are ordinary `let`-bindings.** Rebinding is
  allowed and triggers compiler-inserted contract-preservation
  checks at the boundary; no `mut` modifier.
- **Verifier integration.** Woven body + composed contract is the
  input to the VC pipeline (`docs/15-phase-4-proof-plan.md`).
- **Async aspects emit a warning until Phase 2's real
  state-machine async lowering ships** (D035 → ?).

### Rationale

- **DRY without invisibility.** A module-scoped declaration is
  visible at the file header (like `wire`). LSP code-lens makes
  the woven set discoverable per-method. Aspects scattered across
  the call graph (AspectJ-style) would defeat the safety story.
- **Composed contract preserves modular reasoning.** The wrapper
  *is* the API. The verifier and runtime see one contract; the
  caller sees one contract; the published `Lyric.Contract`
  resource records one contract. Aspects don't sneak around the
  type system; they extend it visibly.
- **Strengthening preconditions is a feature, not a bug.** An
  aspect that adds `requires: nonNull(args.user)` across every
  public handler is the entire point. Callers see a stricter API;
  the compiler enforces it at every call site.
- **Package-scoped weaving keeps separate verification possible.**
  Cross-package aspects would require closed-world re-verification
  at link time and break the published-contract model
  (D-progress-031). Not worth the power.
- **`around` only.** Subsumes `before` / `after`; one mental
  model; one inlining strategy. Cleaner spec, cleaner verifier
  story.
- **No implicit runtime toggle.** An automatic `enabled` flag
  would make security-critical aspects (`Validation`,
  `Authorization`) silently switchable from the env. Opt-in
  toggling forces aspect authors to declare disableability
  intentionally.

### Alternatives considered

- **Per-method derive (`@derive(Logging)`).** Doesn't solve "no
  manual annotation." Rejected as the *only* mechanism; remains
  available as a future shape.
- **AspectJ-style cross-package pointcuts.** Maximal power.
  Rejected: breaks package isolation, hostile to separate
  verification, hostile to the published-contract model.
- **General macros.** Aspects-as-a-macro-library. Rejected for
  v1: macro hygiene, sandboxing, error-message quality, and IDE
  support are each multi-year projects. Aspects are a small,
  bounded primitive that ships sooner.
- **Trait-based with blanket impl.** `impl Logged for fn matching
  "*"`. Rejected: methods aren't first-class on .NET; the
  syntax is novel and awkward; doesn't compose with contracts,
  async, or generics without bespoke rules.
- **Manifest-driven weaving.** Aspect rules in `lyric.toml`.
  Rejected: source no longer self-describes behaviour; worst
  case for local readability.
- **Codegen tool.** `lyric gen-aspect` writes wrapper functions
  to disk. Rejected: not really aspects; merge-conflict prone;
  re-run requirements. Remains available as a user-space pattern
  if someone wants it.

### Consequences

- **Phase 2** gains a substantial feature: parser, weaver,
  contract-composition pass, verifier integration, LSP support,
  `lyric explain` extension.
- **Published contract format** (D-progress-031) gains a
  composed-contract path. Restored packages already consume
  `Lyric.Contract`; aspect-affected functions surface their
  composed contract through the same channel transparently.
- **Diagnostic catalogue** gains the `A####` series. Existing
  contract-failure diagnostics gain a provenance field naming the
  aspect.
- **D035 async-lowering follow-ups** explicitly accept aspect
  awareness as a design constraint. The Phase 2 state-machine
  work lifts the `A0020` warning.
- **Self-hosted compiler (Phase 5)** must implement aspects in
  Lyric. The package-scoped scope keeps this tractable; the
  weaving pass is a tree transformation peer to the existing
  contract-elaboration pass.

### Tracked follow-ups

- **Q-aspects-001:** Aspects on type constructors and operator
  overloads. Defer.
- **Q-aspects-002:** Mangling scheme for `<name>_target`.
- **Q-aspects-003:** `call.elapsed` shape before `proceed`
  (zero, `Option`, panic).
- **Q-aspects-004:** Aspects across packages within a single
  multi-package project (`docs/20-project-as-dll.md`). Defer.
- **Q-aspects-005:** `call.contractValues` for the values of
  `requires:` / `ensures:` predicates at the weave point. Defer
  behind an `@expensive` marker if shipped.
- **Q-aspects-006:** Inheritance of contracts *across* aspects
  (one aspect's clauses visible to subsequent aspects' bodies).

**Revisions:**

- 2026-05-08 — Resolved seven open questions across D047 / 27 /
  28 (PRs #234, #235, #241):

  - **Q-aspects-003** — `call.elapsed` is `Option[Int]`
    (`None` before `proceed`, `Some(ms)` after).  Worked
    examples updated to use `call.elapsed.unwrapOr(0)` for
    printing.  Spec: `docs/26-aspects.md` §4.3.

  - **Q-aspects-006** — Aspect-to-aspect contract
    inheritance: status changed to "desirable, deferred."
    Each aspect's contract clauses augment the *target's*
    contract in v1, not the cumulative wrapper-so-far.
    v1.x revisit.

  - **Q-aspectlib-001** — Library ABI: hybrid B + C, resolved at
    the *spec* level.  Default is B-mode; opt individual aspects
    into source-template via `@inline_template` (C-mode).
    Typed-erased delegate (option A) rejected.  Spec:
    `docs/27-aspect-libraries.md` §6.  **B-mode's *implementation*
    is B′-mode** (a monomorphisation-based variant, not the
    reified-generic-method artifact this note originally
    described) — see D114 / `docs/55`.

  - **Q-aspectlib-002** — Contract-only `pub aspect` (no
    `around` body) uses the same syntax as a body-bearing
    `pub aspect`; no `pub aspect_contract` fork.

  - **Q-aspectlib-005** — Required (no-default) library-aspect
    config fields propagate D046 §4's runtime fail-fast rule;
    no compile-time override mechanism.  Compile-time-required
    fields are tracked as Q-aspectlib-005' for v2.

  - **Q-aspectlib-§5.1 (sketch)** — In B-mode library
    aspects, `args` is an **anonymous parametric record**
    opaque to field access (`args.x` reserved for local /
    C-mode aspects).  Refines D047 §4.2 ("`args` and `ret`
    are ordinary `let`-bindings"): the `let`-binding rule
    holds for *local* aspects and C-mode `@inline_template`
    library aspects; B-mode bodies see `args` parametrically.
    Spec: `docs/27-aspect-libraries.md` §6.1.1.

  - **Q-aspectlib-§5.2 (sketch)** — `@inline_template` bodies
    require **explicit consumer-side imports**; auto-hoist
    rejected.  Spec: `docs/27-aspect-libraries.md` §6.2.1.
    Diagnostic `A0041`.

  - **Q-aspectlib-§5.4 (sketch)** — `call.*` is in scope
    inside `ensures:` clauses but **not** inside `requires:`
    (footgun: `call.elapsed` is always `None` before
    `proceed`).  Spec: `docs/26-aspects.md` §4.3.1.
    Diagnostic `A0040`.

  - **Q-aspectlib-§5.6 (sketch)** — Use-site shape
    verification of library `requires:` / `ensures:`
    clauses is mandatory.  Consumer's compiler shape-checks
    every `args.<field>` reference against each matched
    target before the wrapper is emitted.  Spec:
    `docs/27-aspect-libraries.md` §9.1.  Diagnostic
    `A0042`.

  (Q-config-004 originally listed here was a D046 question;
  moved to the D046 revisions block above.)

- 2026-05-08 — **v1.x sketch published** at
  `docs/30-aspect-contract-inheritance-sketch.md` extending
  Q-aspects-006's "desirable, deferred" status with a
  pre/post-symmetric inheritance rule: pre-`proceed` inherits
  every aspect's `requires:` (wrapper-boundary check
  guarantees them), post-`proceed` inherits only
  strictly-inner aspects' `ensures:` (temporal walk back).
  Conservative `mut args` lean (inheritance breaks at
  upstream rewrites; aggressive `@preserves` deferred to v2).
  Four "before-implementation" tensions flagged.

---

## D048 — Config v2 semantics (file source + layered precedence)

**Date:** 2026-05-08
**Branch:** claude/compile-time-aspects-logging-SIhqA

### Context

D046 specifies env-only / read-once / fail-fast config blocks.
The v2 sketch at `docs/29-config-v2-sketch.md` extends D046
with file-based source + layered precedence
(CLI > env > file > defaults), addressing Q-config-001
and Q-config-002.  Four §9 "before-implementation" tensions
need binding answers so future implementation doesn't
re-litigate them.

### Decision

Adopt `docs/29-config-v2-sketch.md` as the v2 design.  The
four §9 tensions resolve as follows:

- **§7.1 — Required-field semantics across layers.** A
  required field (no `=` default) is satisfied if **any
  layer** (CLI / env / file) supplies a value; otherwise
  exit 78.  This is a v1→v2 contract shift — v1's
  "required = env must be set" loosens to "required = some
  layer supplies a value."  Operators may need to retest
  deployments where env was the audit surface.

- **§7.2 — TOML type-coercion strictness.**  Strict at
  parse time.  TOML supplied a string but the field expects
  Int → reject with `G0014`.  No coercion.  Range-subtype
  validation runs at the same config-resolution phase as
  type checking; out-of-range values fail the same way
  type mismatches do (exit 78, diagnostic naming the field
  + source layer + failing range).

- **§7.3 — File-env conflict diagnostics.** Silent override
  by default; `LYRIC_CONFIG_VERBOSE=1` opt-in prints the
  layer trail at startup for diagnosis.

- **§7.5 — `@cfg` × file-source mismatch.** Warn, don't
  error.  Production configs need to span environments
  where features differ at compile time.

- **§3.4 — `@sensitive` opt-out from file source.** CLI /
  build-time flag (`--config-sensitive-env-only` or
  `[build] config_sensitive_env_only` in `lyric.toml`),
  not in-file metadata.  When set, any `@sensitive` field
  whose **TOML key is present in the file source** is
  rejected loudly with exit code 78.

Format restricted to TOML in v2; YAML / JSON / env-files
out of scope.  Multi-file composition deferred to v2.x.
Hot reload (Q-config-003) remains explicitly out of scope.

### Rationale

- **Field-granularity layering** matches every comparable
  tool (Cargo, Spring, Rails); industry-standard,
  low-surprise.
- **Strict-at-parse-time** keeps the fail-fast contract
  tight; coercion would muddy the audit story (`"8080"`
  vs `8080` is exactly the kind of audit-grade surprise
  this avoids).
- **Silent-by-default** for env-overrides-file is what
  container deployments expect; the verbose opt-in handles
  dev / debug.
- **Warn-on-feature-mismatch** is operator-friendly;
  hard-error would break common workflows where a single
  file ships across environments with different feature
  sets.
- **CLI flag** for sensitive-from-env-only beats a magic
  TOML section because it doesn't break the §3.2 1:1
  mapping between TOML sections and declared `config { … }`
  blocks, and because the policy is a deployment concern
  (not a per-file concern).

### Alternatives considered

- **Strict at use time, not parse time** — rejected;
  fail-fast must happen before `main` runs.
- **Auto-coerce TOML primitives** to declared field types
  — rejected per audit-grade reasoning above.
- **Hard error on `@cfg` × file-source mismatch** —
  rejected; production configs span environments.
- **Magic `[__lyric_meta]` TOML section** for sensitive
  opt-out — rejected per the docs/29 §3.4 review feedback;
  CLI / build-time flag is cleaner.
- **Multi-file composition** as v2 baseline — rejected;
  defer to v2.x once a real consumer needs it.

### Consequences

- Implementation gates on M5.2 stage 3+ (the AST→MSIL
  bridge in the self-hosted compiler) — until then, this
  decision is the spec future implementation will follow,
  not running code.
- D046's `Lyric.BuildInfo` schema recording (Q-config-004,
  resolved 2026-05-08) extends naturally — names + types
  + defaults + `@sensitive` markers + the new
  `--config-sensitive-env-only` flag's setting are all
  recorded; runtime resolution (which layer supplied
  which value) is not.
- D047 aspect runtime config blocks inherit v2 layering
  for free via the consumer's synthesised `config { … }`
  block.

### Tracked follow-ups

- **Q-config-001'** (multi-file composition) — v2.x
  extension.
- **Q-config-002'** (richer validation beyond range
  subtypes — regex strings, enum-conditional fields, etc.)
  — v3 conversation.

**Revisions:** None.

---

## D049 — Aspect contract inheritance (v1.x semantics)

**Date:** 2026-05-08
**Branch:** claude/compile-time-aspects-logging-SIhqA

### Context

D047 §11 verifies each aspect's body individually against
the *target's* bare contract — no upstream aspect's clauses
flow into a downstream aspect's body.  Q-aspects-006 was
earmarked "desirable, deferred."  The v1.x sketch at
`docs/30-aspect-contract-inheritance-sketch.md` proposes a
pre/post-symmetric inheritance rule.  Four §8
"before-implementation" tensions need binding answers.

### Decision

Adopt `docs/30-aspect-contract-inheritance-sketch.md` §3 as
the v1.x semantic rule.  For wrapper `W = A₁ ⊃ A₂ ⊃ ... ⊃
Aₙ ⊃ T`:

- **Pre-`proceed` assumption set for Aₖ.around:**
  `T.requires ∧ ⋀_{i=1..n} A_i.requires`.  Every aspect's
  `requires:` is part of the wrapper's composed precondition,
  checked once at boundary 1 — they all hold from that point
  on, regardless of nesting position.

- **Post-`proceed` assumption set for Aₖ.around:**
  `T.ensures ∧ ⋀_{i>k} A_i.ensures` (against `ret`).  Only
  strictly-inner aspects' ensures inherit; outer aspects'
  after-halves haven't run yet when Aₖ.after runs.

The four §8 tensions resolve as follows:

- **§6.1 — Mut-args inheritance.** Conservative.
  Inheritance breaks at any upstream `mut args` rewrite
  (D047 §4.2); downstream aspects fall back to T-only
  assumptions for the rewritten args.  Aggressive
  `@preserves(<aspects>)` annotation deferred to v2.

- **§6.3 — Diagnostic provenance.** When the verifier
  proves a fact about Aₖ's body using an upstream aspect's
  clause, the diagnostic names the originating aspect plus
  the consumer's `use` site (mirroring D047 §5.3
  contract-failure provenance), e.g.
  `verified: args.user.permissions is non-null because
  nonNull(args.user) holds (Validating, from Std.Aspects,
  used at app.l:7) inherited at this point in the
  composition`.

- **§6.5 — Async opt-in.**  No inheritance through async
  aspects for v1.x.  Async aspects already warn under
  D047 §13's bootstrap-grade lowering; inheritance lights
  up when proper async lowering ships in Phase 2.

- **§6.6 — Args-only `requires:` inheritance.**  Inheritance
  only works on `args.*` / `call.*`-referencing clauses
  (constants up to `proceed`).  Clauses referencing
  globals or external state don't participate; the verifier
  falls back to T-only assumptions for those specific
  clauses.

### Rationale

- The pre/post asymmetry is justified by the temporal
  asymmetry that already governs D047's wrapper-boundary
  semantics: the composed precondition is checked once at
  entry (every `requires:` available pre-proceed); the
  composed postcondition is established as the call
  unwinds (only inner ensures available post-proceed).
- Conservative mut-args inheritance subsumes the aggressive
  rule (strictly less expressive but always sound); can
  relax later without breaking existing aspects.
- Args-only restriction prevents inheritance from leaking
  global state into the assumption set — keeps the
  contract surface declarative and verifier-friendly.

### Alternatives considered

- **No inheritance** (v1 status quo) — rejected; the
  canonical `Validating` + `Auth` pattern (28 §3) requires
  every auth-flavoured aspect to repeat preconditions
  without it.  Library aspects don't reuse cleanly.
- **Symmetric inheritance** (post-proceed inherits all
  ensures, including outer) — rejected; outer aspects'
  after-halves haven't run when Aₖ.after runs, so their
  ensures aren't established yet.
- **Aggressive mut-args inheritance** with `@preserves`
  — deferred to v2; rare use case, can land later.
- **Always-on inheritance through async** — rejected;
  bootstrap-grade async lowering doesn't preserve
  enough to make inheritance sound.

### Consequences

- D047 §11 step (3) gains the inheritance-aware
  assumption set logic — small mechanical extension.
  Wrapper-level VCs (D047 §11 steps 1, 2) and the
  composition graph (D047 §6) are unchanged.
- The `Std.Aspects` ecosystem becomes ergonomic:
  declaring `nonNull(args.user)` once on `Validating`
  is enough; downstream `Auth` / `Logging` / etc. inherit
  it.  Per docs/28 §10.
- Implementation gates on M5.2 stage 3+ (the AST→MSIL
  bridge in the self-hosted compiler).  Until then, this
  decision is the spec future implementation will follow.

### Tracked follow-ups

- **Q-aspects-006'** (mut-args `@preserves` annotation) —
  v2 extension.
- **Q-aspects-006''** (inheritance through async lowering)
  — Phase 2, when proper async state machines ship.

**Revisions:** None.

---

## D050 — Aspect templates (`pub aspect_template`) — SUPERSEDED in D051 (syntax only)

**Date:** 2026-05-08
**Branch:** claude/opentelemetry-design-Fgww0

### Context

D047 established that aspects are package-scoped: an aspect declared
in package P weaves only over P's own functions. This was the right
call for safety and separate verification, but it left library packages
unable to ship reusable cross-cutting logic. Every consumer would need
to hand-write the same `around` body to instrument their handlers —
exactly the DRY problem aspects were meant to solve.

The motivating case is observability: an `Std.OTel` package should be
able to ship a `Tracing` template that any consumer can bind to a local
`matches:` selector without reproducing the span-start / span-end
boilerplate. The same pattern applies to logging templates, auth
templates, metrics templates.

### Decision

Add `aspect_template` as a top-level item peer to `aspect`. Specify
full semantics in `docs/26-aspects.md` §19. Key points:

- **`pub aspect_template Name { ... }`** — declares an exportable
  advice body. Contains `config { }`, `around`, `requires:`, `ensures:`
  in any combination (same as a standalone `aspect`), but **no
  `matches:` clause** (`A0021`). May also be package-private (no `pub`)
  for intra-package reuse across multiple files.
- **`aspect Name from Pkg.Template { matches: ... }`** — instantiates a
  template in the consumer's package. The body must contain exactly one
  `matches:` clause and may contain a `config { }` block to override
  field defaults. `around`, `requires:`, `ensures:` in the instantiation
  body are rejected (`A0022`).
- **Config field overrides** — the consumer redeclares individual fields
  with new defaults. Field name and type must match the template's
  declaration (`A0023` / `A0024`). Runtime env vars always win, using
  the **local instantiation name**: `LYRIC_ASPECT_<NAME>_<FIELD>`.
  Two packages instantiating the same template under different local
  names have independent env-var namespaces.
- **`@cfg` on both sides** — template-level `@cfg` erases the template
  and all its instantiations silently. Instantiation-level `@cfg` erases
  only that instantiation. If a template is erased but an instantiation's
  predicate would have been true, the instantiation is silently erased
  too (not an error — the feature flag is the signal).
- **Cross-package weaving still rejected.** Templates share advice
  *logic*; the weaving authority remains package-local. An instantiation
  in package B weaves over B's functions only; the template in A has no
  reach into B. The compiled output is identical to a consumer who
  hand-wrote the `around` body locally.
- **Ordering clauses allowed on instantiations.** `wraps:` / `inside:`
  may reference other local aspects (whether standalone or
  template-derived) by their local name, following §6 exactly.

### Rationale

- **Shares logic, not weave authority.** The key insight is that the
  package-isolation rule is about *where weaving happens*, not about
  *where the advice code comes from*. A template is syntactic sugar:
  the compiler inlines the template body into the consumer's aspect
  declaration at build time. No cross-package action; no closed-world
  re-verification; no impact on the published-contract model.
- **Local naming for env vars.** Using the instantiation's local name
  (`LYRIC_ASPECT_TRACING_*`) rather than the template's qualified name
  (`LYRIC_ASPECT_STD_OTEL_TRACING_*`) gives operators a stable,
  per-service namespace. Two services can have different sampling rates
  for the "same" Tracing template without either seeing the other's
  configuration.
- **No implicit `enabled` — still.** Inherited from D047. A template
  that wants runtime toggling declares `enabled: Bool = true` in its
  `config`. Security-critical templates (e.g. a blanket `Validation`
  template) deliberately omit the field.
- **Override rather than merge.** Config field override replaces the
  default value; the type is invariant. Allowing type widening would
  create surprising coercions at the extern boundary; allowing new
  fields would imply the template and the instantiation share a schema
  that neither party owns.

### Alternatives considered

- **Import-and-re-export the `around` helper function.** Consumers call
  `Std.OTel.spanAround(call, proc)` inside their own locally-declared
  aspect. Already possible today; templates are ergonomic sugar that
  eliminate the local aspect declaration boilerplate entirely.
- **Project-level aspects (Q-aspects-004).** Would allow a single
  aspect to weave across all packages in a multi-package project.
  Deferred; templates address the library-sharing use case without
  opening that scope.
- **Parameterised aspects (arguments to the aspect block).** Allow
  `aspect Tracing(sampleRate: Float) from ...`. Rejected for v1:
  adds a new call-site syntax, complicates the `matches:` evaluation
  order, and the `config { }` block with env-var override covers the
  runtime-parameterisation need without new syntax.

### Consequences

- **Grammar** gains `aspect_template` keyword, `from` clause on
  `AspectDecl`, `AspectTemplateDecl` production, `MatchesClause`,
  `AspectConfigDecl`, `ConfigField`, `AroundAdvice`, `OrderingClause`
  (`docs/grammar.ebnf` §10.2).
- **Diagnostic catalogue** gains `A0021`–`A0026`.
- **`Std.OTel`** becomes the canonical motivating example in
  `docs/26-aspects.md` §19.5.
- **Self-hosted compiler (Phase 5)** must implement template resolution
  and inlining. The implementation is a straightforward substitution pass
  over the aspect AST node after import resolution.

### Tracked follow-ups

- **Q-aspects-007:** Ordering clause interaction between two
  template-derived instantiations in the same package when the template
  declares `requires:` / `ensures:`. Defer to v1 implementation pass.

**Revisions:** None.

---


## D051 — Unify `aspect_template` into `aspect` — template = `pub aspect` without `matches:`

**Date:** 2026-05-08
**Branch:** claude/aspect-unified-keyword
**Amends:** D050 (syntax only; all semantic decisions in D050 stand unchanged).

### Context

D050 introduced `aspect_template` as a new top-level keyword for
exportable aspect bodies. On reflection, a separate keyword adds
unnecessary cognitive overhead: the `aspect` block already handles
standalone aspects and instantiations, and the template form is
simply an aspect body that has no `matches:` clause and is `pub`.
The distinction the language needs is already captured by two
existing signals — `pub` and the presence or absence of `matches:`.

### Decision

**Retire the `aspect_template` keyword.** Templates are declared
using the same `aspect` keyword as standalone aspects and
instantiations. The three forms are distinguished post-parse by
visibility and the presence of `matches:`:

| Form | `pub` | `matches:` | `from` | Meaning |
|---|---|---|---|---|
| Standalone | no | yes | no | Package-private; weaves in this package. |
| Template | yes (or no for intra-package) | no | no | Exported advice body; never weaves. |
| Instantiation | no | yes | yes | Binds a template to a local selector. |

The `pub` + `matches:` combination is rejected (`A0001`, updated):
`pub` is not allowed on a matching aspect. All other semantic rules
from D050 (config overrides, `@cfg` interaction, env-var naming,
ordering clauses, `from` clause, diagnostics A0022–A0026) are
unchanged.

**Grammar change:** `AspectTemplateDecl` production removed.
`AspectDecl` covers all three forms. `aspect_template` removed from
the soft-keyword table. `from` remains a soft keyword.

### Rationale

- **One keyword, one mental model.** `aspect` is already the word
  for "a cross-cutting thing the compiler weaves." A template is
  just an unbound aspect — a `pub aspect` with no selector. Users
  don't need a new word; they need to know that `pub` without
  `matches:` means "I'm offering this body for others to bind."
- **Less parser complexity.** Two productions (`AspectDecl` +
  `AspectTemplateDecl`) collapse to one. The three forms are
  syntactically identical up to `pub` and the presence of `matches:`
  / `from`; post-parse disambiguation is a single predicate check.
- **Consistent with `wire`.** `wire` doesn't have a separate
  `wire_template` keyword for parameterised wires. The same "one
  keyword, different modifiers" convention applies here.

### Alternatives considered

- **Keep `aspect_template`.** Maximally explicit; no ambiguity about
  intent from a glance at the keyword. Rejected: the extra keyword
  solves a problem readers don't have (the absence of `matches:` and
  the presence of `pub` already communicate "template" unambiguously).

### Consequences

- `docs/26-aspects.md` §2.2 updated: A0001 now reads "pub rejected
  on matching aspects" (not "pub always rejected").
- `docs/26-aspects.md` §18 prose and all examples updated.
- `docs/grammar.ebnf` §10.2 updated.
- D050's entry title retains `pub aspect_template` for historical
  accuracy; this entry supersedes D050's syntax choice only.
- Both parsers (F# + self-hosted) implement all three forms:
  `From: ModulePath option` and `Config: ConfigField list` added to
  `AspectDecl`. Parser error codes P0306–P0308 added.

---

## D052 — Maven Central linking design decisions

**Date:** 2026-05-08
**Branch:** claude/java-dependency-support-MC6Xz

### Context

`docs/31-maven-linking.md` specifies how JVM-targeted Lyric projects
consume Java libraries from Maven Central, parallel to the NuGet linking
design in `docs/21-nuget-linking.md`.  Three design decisions required
explicit resolution before the spec could be written.

### Decision 1: Bundled resolver, not `mvn` shell-out

**Decision:** Ship `lyric-resolver.jar` in the SDK (`$LYRIC_SDK/lib/`).
The JAR embeds Apache Maven Resolver 2.x (Apache-2.0 licensed) and is
invoked via `java -jar` — the only runtime requirement is `java` on
`PATH`, which is guaranteed for any JVM-targeted build. No `mvn`
installation is required.

**Alternatives considered:**
- Shell out to `mvn dependency:resolve`. Simple, but adds a mandatory
  `mvn` installation requirement. Inconsistent with the `.NET` side,
  which shells out to `dotnet` (always available alongside the runtime,
  not a separate install).
- Embed Gradle tooling API. More powerful but pulls in a large footprint
  and Gradle daemon lifecycle that is disproportionate for dependency
  resolution alone.

**Rationale:** The `dotnet restore` analogy holds: on the .NET side, the
runtime and restore tool are co-installed. On the JVM side, `java` is
always co-installed with the runtime; `mvn` is not. Embedding Apache Maven
Resolver — the library that backs `mvn` itself — gives full Maven Central
resolution semantics without the installation requirement. The resolver JAR
is an implementation detail of the SDK; the user-visible API is
`lyric restore`.

### Decision 2: Full group ID retained in Lyric package name

**Decision:** A Maven coordinate `groupId:artifactId` maps to a Lyric
package path `{PascalGroup}.{PascalArtifact}`, where the full group ID is
PascalCased and concatenated (dots dropped). The group is never dropped or
truncated.

**Alternatives considered:**
- Drop group ID entirely: `jackson-databind` → `JacksonDatabind`. Used by
  the NuGet naming convention (package IDs are already globally unique).
  Maven artifact IDs are not globally unique — `guava`, `commons-lang3`,
  and others exist under multiple group IDs — so dropping the group creates
  collisions.
- Use only the last group segment: `core:jackson-databind` →
  `Core.JacksonDatabind`. Shorter but still ambiguous (`org.apache.core`
  and `com.example.core` would collide).

**Rationale:** Maven Central's uniqueness guarantee lives at the full
`groupId:artifactId` coordinate level. The Lyric package name must be
derivable deterministically and without collisions from the coordinate.
Retaining the full group — at the cost of verbose names for deeply-nested
groups — is the only approach that preserves uniqueness in general. Users
who find a generated name unwieldy can declare a `type alias` at import
time.

### Decision 3: Checked exceptions wrapped as `Result[T, JvmException]`

**Decision:** Java methods that declare checked exceptions (`throws`
clause with non-`RuntimeException` / non-`Error` types) get a shim return
type of `Result[T, JvmException]`. Methods with only unchecked exceptions
or no `throws` clause return `T` directly. `JvmException` is a single
opaque extern wrapper over `java.lang.Exception` declared in the JVM
stdlib kernel.

**Alternatives considered:**
- Let checked exceptions propagate as unhandled bugs (same as unchecked).
  Loses the "checked" signal entirely; callers cannot recover.
- Generate a per-method union type listing the declared exception classes.
  Precise but fragile: Java exception hierarchies are deep, frequently
  contain dozens of subclasses, and change between library versions.
  Generating union types per-method would produce enormous shim files and
  break on upstream upgrades.
- Map each declared exception class to a distinct Lyric `extern type` and
  generate a library-wide union. Better precision but still generates
  large, volatile shim surface.

**Rationale:** `Result[T, JvmException]` gives callers an explicit
recovery path while keeping the shim surface stable and concise. The
single-wrapper approach mirrors how most JVM languages (Kotlin, Scala)
treat Java checked exceptions at the language boundary: as something the
caller must handle but need not enumerate in detail. Callers that need
finer-grained dispatch call `JvmException.typeName` and match on the
string — an escape hatch that avoids coupling Lyric code to Java exception
class hierarchies.

### Consequences

- `docs/31-maven-linking.md` is the canonical spec for Maven linking.
- `docs/18-jvm-emission.md` §24 gains `Q-J008` referencing the spec.
- `$LYRIC_SDK/lib/lyric-resolver.jar` is added to the SDK distribution
  manifest (see `docs/22-distribution-and-tooling.md`).
- The JVM stdlib kernel gains `stdlib/std/_kernel/jvm_exception.l`
  declaring `extern type JvmException`.
- Diagnostics `B0050`–`B0054` are added to the error catalogue.

**Revisions:**

2026-05-10 (branch claude/java-dependency-support-MC6Xz):
- `ClassScanner.java` extended with `HasCheckedExceptions` detection using a
  conservative `KNOWN_UNCHECKED` set; `MavenResolver.java` serialises the
  field into the JSON surface; `Maven.fs` parses it.
- `MavenShim.fs` extended to generate instance-method stubs (not just static)
  using the `methodName(recv: in TypeName, args…)` convention per spec §4;
  checked-exception methods wrap return in `Result[T, JvmException]` or
  `Result[Unit, JvmException]` per spec §5; `import Std.JvmExceptionHost`
  emitted only when at least one method has checked exceptions.
- `stdlib/std/_kernel/jvm.l` added: `Std.Jvm` package with `@experimental`
  `catch[T](action: func(): T): Result[T, JvmException]` per Q-J012.
- `docs/31-maven-linking.md` Q-J012 marked resolved; Q-J013 added to track
  the JVM emitter call-site try-catch generation (Phase 6 deliverable).

---

## D053 — `lyric-logging` library: structured logging with runtime config and aspect templates

**Date:** 2026-05-09
**Branch:** claude/logging-library-runtime-config-SPkIA
**Builds on:** D046 (config blocks), D047 (aspects), D050/D051 (pub aspect templates), D-progress-142 (`lyric-otel` precedent).

### Context

`Std.Log` (stdlib) is deliberately minimal: four levels, best-effort
output, no named loggers, no level filtering, no structured formatting
beyond key=value fields in a flat string.  That is correct for the
stdlib's role but insufficient for service-shaped applications that
need per-component level control, JSON output for log aggregators, and
automatic instrumentation without hand-written boilerplate.

The `lyric-otel` library (D-progress-142) established the pattern for
a first-party library that is physically separate from the stdlib DLL.
A logging library fits the same pattern: rich enough to be a real
dependency, but not general-purpose enough to deserve stdlib residency.

### Decision

Ship `lyric-logging/` as a standalone `Std.Logging.dll` containing
two packages:

- **`Std.Logging`** — named loggers, a six-level scale (Trace / Debug /
  Info / Warn / Error / Fatal), structured fields, text and JSON
  formatters, a global level filter backed by a `config` block.
  Writes through `Std.LogHost` (same host boundary as `Std.Log`).
- **`Std.Logging.Aspects`** — three `pub aspect` templates:
  - `CallLogging` (B-mode) — logs `→ name` / `← name (Nms)` around
    every matched call; config: `enabled`, `level`, `loggerName`.
  - `SlowCallAlert` (B-mode, carries `ensures: call.elapsed.unwrapOr(0) >= 0`)
    — logs a warning when a call exceeds `thresholdMs`; config:
    `enabled`, `thresholdMs`, `alertLevel`, `loggerName`.
  - `ErrorResultLogging` (`@inline_template`, C-mode) — logs when a
    matched function returns `Err(...)`; body reads `ret.isErr` directly
    because it is re-compiled inside the consumer's package; only
    applicable to Result-returning functions (shape-verified at the
    `use` / `aspect … from` site per D050 §9.1).

### Key design decisions

**Why not extend `Std.Log`?**  `Std.Log` is intentionally opaque —
its host boundary is `extern package System.Diagnostics { ... }` which
cannot currently be bundled into `Lyric.Stdlib.dll` (see `stdlib/lyric.toml`
deferred list).  Adding named loggers and level filtering to `Std.Log`
would grow its surface considerably and block the bundling fix.  A
separate library avoids that entanglement.

**Six levels vs. four.**  `Std.Log` has Debug/Info/Warn/Error.
`Std.Logging` adds Trace (below Debug, for per-call tracing) and Fatal
(above Error, for unrecoverable conditions).  Trace and Fatal map to
Debug and Error respectively at the `Std.LogHost` boundary so the
underlying sink needs no changes.

**`Logger` as a pure value type.**  A `Logger` record holds only a
name string.  `getLogger(name)` is pure (creates no shared state).
Per-logger level configuration (different loggers filtering at different
levels) is deferred to v2; the global `Defaults.level` config block
applies to all loggers uniformly in v1.  This keeps the library free
of mutable global state, which is important for `@proof_required`
consumers.

**`loggerName` config field on aspects.**  All three templates accept
an optional `loggerName` config override.  When empty (the default),
the aspect uses `call.modulePath` (the containing package) as the
logger name.  This means every package that instantiates `CallLogging`
automatically gets a logger named after itself without any configuration.

**`SlowCallAlert` carries `ensures:`.**  The `ensures: call.elapsed.unwrapOr(0) >= 0`
clause is trivially true but deliberately included: it surfaces the
elapsed-time measurement in the composed contract, allowing downstream
`@proof_required` consumers to reason about latency bounds when they
import a package that uses this aspect.  It also pressure-tests the
contract-propagation path of the template distribution mechanism (D050 §9).

**`ErrorResultLogging` is `@inline_template`.**  B-mode bodies cannot
access named fields on the parametric return value; reading `ret.isErr`
requires C-mode re-compilation in the consumer's package.  This
matches the division-of-labour principle from D050 §6.1.1: observer
aspects (CallLogging, SlowCallAlert) are B-mode; field-inspecting
aspects are C-mode.

### Consequences

- `lyric-logging/` directory added at the repo root, following
  `lyric-otel/` precedent.
- `lyric-logging/lyric.toml` declares `Std.Logging.dll` as the output
  assembly with `Lyric.Stdlib` as a dependency.
- `lyric-logging/src/logging.l` — `Std.Logging` package.
- `lyric-logging/src/logging_aspects.l` — `Std.Logging.Aspects` package.
- `lyric-logging/README.md` — installation, usage, config reference.
- No changes to stdlib; no changes to the compiler.
- Implementation gated on the same milestones as `lyric-otel`: config-block
  emitter and aspect weaver must ship before the library is fully functional.

### Alternatives considered

- **Extend `Std.Log`.**  Rejected; see "Why not extend Std.Log?" above.
- **Single package (no aspects sub-package).**  Would require consumers
  to import all aspect templates even if they only want the core API.
  Two packages keeps imports explicit.
- **`Logger` as an interface** (allowing custom sink implementations).
  Deferred; the interface approach requires the consumer to wire a
  concrete implementation via `wire {}`, which adds friction for the
  common case.  A v2 `LogSink` interface can be added without breaking
  the v1 API.

**Revisions:** None.

---

## D054 — lyric-web library design

**Status:** ACCEPTED
**Date:** 2026-05-09
**Extends:** D046 (config blocks), D047 (aspects), D050 (aspect libraries)

### Context

Lyric needs an HTTP web-service library that is idiomatic — leveraging
annotations, config blocks, and aspect templates — while remaining practical
for everyday API development.  Two development workflows must coexist:
*code-first* (write handlers, extract the OpenAPI spec from the compiled DLL)
and *spec-first* (import an OpenAPI spec, generate typed handler stubs).

### Decisions

**Hybrid routing model.**  Route annotations (`@get`, `@post`, `@put`,
`@delete`, `@patch`) mark individual handlers declaratively; `Router` values
are built programmatically via `Web.addGet / addPost / …` and composed with
`Web.prefix` and `Web.merge`.  Consumers choose the style that fits their
scale; the two approaches are not mutually exclusive.  Pure declarative
auto-discovery via reflection is deferred to a future milestone.

**Flat typed parameters.**  The kernel extracts path segments, query
parameters, and request body by matching the Lyric handler's parameter names
against the URL pattern and query string.  Body deserialization uses the
`@body`-annotated parameter (or the last non-path, non-query parameter for
POST/PUT/PATCH when `@body` is absent).  This avoids the `HttpRequest` wrapper
object that would force every handler to do manual extraction.

**Handler dispatch by qualified name.**  `Route.handlerName` is a `String`
holding the fully-qualified Lyric function name.  The kernel resolves it via
DLL reflection at server startup and registers it with ASP.NET Core minimal
APIs.  Type-safe route registration helpers (`addGet`, etc.) wrap the string
but callers bear responsibility for correctness today; a typed macro is planned
for Phase 2.

**Full contract bridge.**  OpenAPI constraints (`minimum`, `maxLength`, etc.)
are mapped bidirectionally to Lyric `requires:` clauses.  In the code-first
direction, `requires:` clauses are reflected into the generated spec.  In the
spec-first direction, the generator emits matching `requires:` clauses in
stubs, bridging OpenAPI's constraint vocabulary to Lyric's contract system.
The `pattern:` constraint has no v1 `requires:` equivalent — emitted as a
`// TODO` comment.  When `minimum` and `maximum` appear together on an integer
parameter, the generator emits `Int range N..=M` as a subtype instead of two
separate clauses.

**Both spec generation modes.**  Build-time (`lyric web spec --output
openapi.yaml`) extracts the spec from the compiled DLL's embedded
`Lyric.Contract` resource and annotation metadata.  Runtime
(`Server.swaggerEnabled = true`) serves a live `/openapi.json` and Swagger
UI at `/swagger`.  The runtime mode is controlled by a `config Server` env var
(`LYRIC_CONFIG_WEB_SERVER_SWAGGERENABLED`) and does not require a separate
build step.

**`ApiError` as a plain record.**  Status code, message, and optional
`detail [String]` are three fields on a record.  A union of case classes per
status code was considered and rejected: it would force consumers to write
exhaustive pattern matches when they only care about the error value, and it
would prevent the `apiError(status, msg)` escape hatch for custom codes.  The
10 named constructor helpers (`badRequest`, `notFound`, etc.) cover the common
cases without the boilerplate tax of case classes.

**CORS as a config block, not an aspect.**  CORS headers must appear on
*every* HTTP response — including 404 responses for unmatched routes and
OPTIONS preflight requests that never reach a Lyric handler.  Aspects operate
at the Lyric function boundary, which is too late for preflight and 404.
`config Cors { … }` values are read once at startup and passed to the Kestrel
middleware layer via `HttpKernel.serve(…)`, which applies them unconditionally
to all responses.

**Auth and rate-limit as aspect templates.**  Authentication (`RequiresAuth`)
and rate limiting (`RateLimit`) are cross-cutting and declarative — matching
the aspect model.  `RequiresAuth` is C-mode (`@inline_template`) because it
must read `args.authToken` (a named field on the concrete handler parameter
list).  A compiler shape error (A0042) is emitted if the aspect is applied to
a handler without an `authToken: String` parameter.  `RateLimit` is B-mode
because it uses `call.qualifiedName` as the rate-limit key, which requires no
named field access.

**`jwtSecret` is `@sensitive`.**  The JWT signing secret must not appear in
`lyric explain` output or Swagger UI metadata.  Marking the config field
`@sensitive` causes the compiler to redact it in all diagnostic and introspection
output while still making it available to the aspect body.

**`spec-first` type mapping.**  The code generator maps OpenAPI schema types to
Lyric types as follows: `integer/int32`→`Int`, `integer/int64`→`Long`,
`number/float`→`Float`, `number/double`→`Double`, `boolean`→`Bool`,
`string`→`String`, `string nullable:true`→`Option[String]`,
`string enum:[…]`→generated `pub enum`, `object properties:{…}`→generated
`pub record`, `array items:T`→`[T]`, `$ref`→the generated Lyric type name.

### Consequences

- `lyric-web/` directory added at the repo root.
- `lyric-web/lyric.toml` — `Web.dll`, four packages, `dotnet` feature flag.
- `lyric-web/src/web.l` — `Web` package: `ApiError`, `Router`, config blocks, `start`.
- `lyric-web/src/openapi.l` — `Web.OpenApi`: full OpenAPI 3.1 type vocabulary,
  builder helpers, bidirectional mapping documented in module docstring.
- `lyric-web/src/aspects.l` — `Web.Aspects`: `RequiresAuth` (C-mode) and
  `RateLimit` (B-mode) template aspects.
- `lyric-web/src/_kernel/net/web_kernel.l` — `Web.Kernel.Net`: `@cfg(feature
  = "dotnet")` extern boundary to Kestrel, JWT, and rate-limit NuGet packages.
- `lyric-web/README.md` — full workflow documentation.
- No changes to stdlib or compiler.
- HTTP serving and aspect weaving take effect once the Kestrel integration
  milestone and aspect weaver ship.

### Alternatives considered

- **`HttpRequest` / `HttpContext` wrapper objects.**  Rejected in favour of
  flat typed parameters; see above.
- **Auto-discovery of routes via reflection.**  Appealing for large services
  but requires a stable annotation-reflection API that does not exist yet.
  Deferred to Phase 2.
- **CORS as an aspect.**  Rejected; see above.
- **Separate error union per status code.**  Rejected; see above.
- **`LoggingAspect` bundled in `Web.Aspects`.**  Consumers should bring their
  own logging library (`lyric-logging`, `lyric-otel`); bundling would create a
  forced dependency.

**Revisions:** None.

---

## D055 — `lyric-cache` library: typed key-value cache with pluggable store

**Date:** 2026-05-10
**Branch:** claude/service-libraries-cache-db-health-SPkIA
**Builds on:** D045 (`@cfg` features), D046 (config blocks), D047 (aspects), D050/D051 (pub aspect templates).

### Context

Many Lyric services need a shared, in-process key-value cache for rate-limiting
state, session data, computed results, and feature flags.  Consumers also need
the ability to swap in Redis or another remote store without changing application
code.

### Decision

A `lyric-cache/` library is added.  It ships two packages:

- `Cache` — `CacheStore` interface, `InProcessCacheStore` (in-memory, LRU
  eviction), factory functions `inProcess()` / `inProcessWithCapacity(n)`,
  and the public API (`get`, `set`, `setWithTtl`, `delete`, `clear`).
- `Cache.Aspects` — two pub aspect templates: `FunctionCache` (B-mode, caches
  by `call.qualifiedName`) and `ItemCache` (C-mode, `@inline_template`, reads
  `args.cacheKey: String` from the matched handler).

**`CacheStore` as the extension point.**  The `CacheStore` interface exposes
`get/set/delete/clear`.  `InProcessCacheStore` is the v1 concrete type.
Consumers who need Redis or Memcached implement `CacheStore` and use the
`Cache.get/set` functions directly in a custom aspect body.

**`var entries` field on `InProcessCacheStore`.**  Lyric records are normally
immutable, but `var` fields allow in-place mutation when the binding is `var`.
Using a mutable `entries` field on the record lets the store be passed by
reference through multiple aspect invocations without copying the entire map.

**Aspect templates share a module-level store.**  Both `FunctionCache` and
`ItemCache` read from `var store = Cache.inProcess()` declared at the
`Cache.Aspects` module scope.  This is the simplest possible wiring for
the common case.  Consumers who need per-store isolation implement their
own aspect body calling `Cache.get/set` with an explicitly-scoped store.

**`FunctionCache` is B-mode; `ItemCache` is C-mode.**  `FunctionCache` only
needs `call.qualifiedName` (the function's stable identifier), which is
available in B-mode.  `ItemCache` must read `args.cacheKey` by name, which
requires C-mode re-compilation in the consumer's package (`@inline_template`).
Attempting to read named `args.*` in B-mode would be a shape error (A0042).

**TTL 0 means no expiry.**  Avoids a separate `Option[Int]` parameter;
0 is unambiguous since negative TTLs are nonsensical and excluded by the
config range constraint.

### Consequences

- `lyric-cache/` directory added at the repo root.
- `lyric-cache/lyric.toml` — `Cache.dll` manifest.
- `lyric-cache/src/cache.l` — `Cache` package with `CacheStore` interface
  and `InProcessCacheStore` implementation.
- `lyric-cache/src/cache_aspects.l` — `Cache.Aspects` package with
  `FunctionCache` and `ItemCache` templates.
- `lyric-cache/README.md` — usage, interface guide, aspect reference.

### Alternatives considered

- **`CacheStore` as a config field on aspect templates.**  Interfaces are not
  primitive config types; the field would need to be a string handle.  Too
  complex for the common case.  Rejected in favour of the module-level store.
- **`Option[Int]` for TTL.**  More explicit, but adds noise at every call site.
  0-means-no-expiry is a widely-used convention (Redis, Memcached).
- **Redis implementation in v1.**  Deferred; the extern boundary for Redis
  requires a new `_kernel` package and NuGet dependency.  `CacheStore` allows
  it to be added without any API changes.

**Revisions (2026-07-05):** The `Cache.Aspects` design shipped differently
from this entry's original description, once the two templates were
actually implemented (docs/57-stdlib-ecosystem-library-review.md §4/§7
item 4; this entry had shipped only `FunctionCacheConfig`/`ItemCacheConfig`
config records with no `pub aspect` bodies until then):

- **`ItemCache` shipped as row-constrained B'-mode (docs/56 / D115),
  not C-mode.**  C-mode (`@inline_template`) predates B'-mode's row-typed
  `args.<field>` access (D115), which didn't exist yet when this entry was
  written. `ItemCache` reads `args.cacheKey` via a
  `where TArgs has { cacheKey: String }` row clause instead; a mismatched
  handler shape is reported as **A0047**, not A0042 (A0042 is C-mode's
  arity-mismatch diagnostic and doesn't apply here).
- **`FunctionCache` and `ItemCache` do *not* share a single store.**  Each
  template holds its own module-level `InProcessCacheStore`
  (`functionCacheStore`, `itemCacheStore`) — a `val` binding to a
  mutable-field record, since Lyric has no module-level `var` primitive
  (contrary to this entry's `var store` / `var entries` phrasing, written
  before that constraint was worked out in practice). Every instantiation
  of the *same* template shares that template's one store, exactly as this
  entry anticipated; the two templates just don't share each other's.
- **`ItemCache`'s key includes function identity.**  The effective key is
  `call.qualifiedName + ":" + keyPrefix + args.cacheKey`, not just
  `keyPrefix + args.cacheKey` — without the `qualifiedName` component, two
  differently-matched handlers sharing `itemCacheStore` could collide on an
  identical `cacheKey` (found via review on the shipping PR, tracked as
  issue #5146).
- **`InProcessCacheStore` enforces `ttlSeconds` as real expiry**, not just a
  capacity-eviction-only value as this entry's "TTL 0 means no expiry"
  section implies without stating the enforcement mechanism: a positive
  `ttlSeconds` is tracked as an epoch-millis expiry (`Std.Time`) and lazily
  evicted on `get` once elapsed (issue #5139).

---

## D056 — `lyric-db` library: driver-agnostic database access with typed rows

**Date:** 2026-05-10
**Branch:** claude/service-libraries-cache-db-health-SPkIA
**Builds on:** D045 (`@cfg` features), D046 (config blocks), D047 (aspects), D050/D051 (pub aspect templates), D053 (logging layer).

### Context

Database access is one of the most common cross-cutting concerns in Lyric
services.  The design must support multiple drivers (PostgreSQL, SQLite) without
forcing the consumer to choose at compile time, and must expose a safe, typed
API that works with the mode checker's `in`-mode parameter rules.

### Decision

A `lyric-db/` library is added.  It ships three packages:

- `Db` — `DbError`, `DbValue` (null / int / long / float / double / bool /
  text / bytes), `DbRow`, `col(row, name)`, `DbTransaction` interface,
  `DbConnection` interface, `NativeConnection` and `NativeTransaction` wrappers,
  `config Connection { url; poolSize; connectTimeoutMs; queryTimeoutMs; password }`,
  and feature-gated factory functions `connectPostgres()` / `connectSqlite()`.
- `Db.Aspects` — two pub aspect templates: `QueryLogging` (B-mode, logs
  handler entry/exit with elapsed time) and `SlowQueryAlert` (B-mode, warns when
  total elapsed time exceeds `thresholdMs`; carries `ensures: call.elapsed.unwrapOr(0) >= 0`).
- `Db.Kernel.Net` — extern boundary: `Npgsql` (Postgres, `@cfg feature="postgres"`),
  `MicrosoftDataSqlite` (SQLite, `@cfg feature="sqlite"`), and the shared
  `Db.Kernel.Ado` package for query/execute/transaction operations.

**Integer handle pattern at the extern boundary.**  The kernel functions return
`Result[Int, String]` connection and transaction IDs.  `NativeConnection` and
`NativeTransaction` records in `db.l` wrap these IDs and implement the public
interfaces.  This avoids crossing the managed boundary with complex Lyric types
and keeps the kernel contract minimal.

**Two separate factory functions (`connectPostgres` / `connectSqlite`).**  Each
is gated by its own `@cfg` feature flag.  Both can be active simultaneously;
the consumer calls the right factory for their use case.  A single
`connect(url)` that dispatches on the URL scheme was considered but rejected
because it would require both drivers to be linked even if only one is needed.

**`@sensitive` on `Connection.password`.**  The password override is marked
`@sensitive` so it is excluded from diagnostic output, config dumps, and logs.

**`parseRows` is a stub.**  The kernel serialises result rows to JSON and
`parseRows` is responsible for deserialising them to `[DbRow]`.  The function
returns `Err(DbError(code = "NOT_IMPLEMENTED"))` today so callers see the gap
rather than silently receiving empty rows; full implementation is gated on
`Std.Json` being finalised.

**`SlowQueryAlert` carries `ensures:`.**  Same rationale as
`Std.Logging.Aspects.SlowCallAlert` (D053): the trivially-true postcondition
surfaces elapsed-time measurement in the composed contract for `@proof_required`
consumers.

### Consequences

- `lyric-db/` directory added at the repo root.
- `lyric-db/lyric.toml` — `Db.dll` manifest with `postgres` and `sqlite` features.
- `lyric-db/src/db.l` — `Db` package.
- `lyric-db/src/db_aspects.l` — `Db.Aspects` package.
- `lyric-db/src/_kernel/net/db_kernel.l` — `Db.Kernel.Net` package.
- `lyric-db/README.md` — usage, feature flags, config reference, aspect guide.

### Alternatives considered

- **Single `Db.connect(url: String)` dispatching on scheme.**  Simpler call
  site but requires both drivers to be linked and makes feature-gating
  impossible.  Rejected.
- **`DbValue` as a flat tagged union** (e.g. `(tag: Int, value: String)`).
  Less type-safe; pattern matching on an enum is idiomatic Lyric.
- **`parseRows` in the kernel.**  The kernel already returns JSON strings.
  Deserialisation is a Lyric-side concern; keeping it in `db.l` lets the
  implementation be replaced without touching the extern boundary.

**Revisions:** None.

---

## D057 — `lyric-health` library: liveness and readiness health-check endpoints

**Date:** 2026-05-10
**Branch:** claude/service-libraries-cache-db-health-SPkIA
**Builds on:** D046 (config blocks), D054 (`lyric-web` — router and `ApiError`).

### Context

Kubernetes and other orchestrators probe `/health/live` and `/health/ready` to
determine whether to restart a pod or remove it from the load balancer.  A
shared library avoids each service reimplementing this boilerplate and ensures
consistent response shapes across the fleet.

### Decision

A `lyric-health/` library is added with a single `Health` package.  Key design
choices:

**`HealthRegistry` is immutable.**  Build it with `Health.create()`, extend
with `addLivenessCheck` / `addReadinessCheck`, then hand it to
`Health.registerRoutes`.  The same builder-pattern used by `Web.Router`.

**Check functions are referenced by fully-qualified name.**  `handlerName` is
a `String` resolved by the kernel via DLL reflection at request time — the
same dispatch model as `Web.Route.handlerName`.  This keeps `HealthCheck`
a plain value record with no function-type fields, which is important for
serialisation and config inspection.

**Check function signature is `(): Result[Unit, String]`.**  The return type
is `String` rather than `DbError` or a domain-specific type so that any
package can register a health check without taking a dependency on `Db` or
any other library.

**Two check groups: `Liveness` and `Readiness`.**  Liveness failures signal
that the process should be restarted; readiness failures signal that the
instance should be removed from the load balancer.  The distinction is
well-established in Kubernetes health probe semantics.

**`registerRoutes` attaches the registry to the router.**  The `attachRegistry`
helper is a stub with a TODO: encoding the registry into router metadata
requires the router to support arbitrary route annotations, which is a
follow-up milestone.

**Configurable paths.**  `config Endpoints { livePath; readyPath }` allows
the standard paths to be overridden via env vars without recompilation.

**Response shape is JSON.**
`{ "status": "ok"|"degraded", "checks": { "<name>": { "status": "ok"|"fail", "detail": "..." } } }`.
HTTP 200 for `"ok"`, HTTP 503 for `"degraded"`.

### Consequences

- `lyric-health/` directory added at the repo root.
- `lyric-health/lyric.toml` — `Health.dll` manifest; depends on `Lyric.Web`.
- `lyric-health/src/health.l` — `Health` package.
- `lyric-health/README.md` — usage, check function contract, response format,
  check groups, config reference, API table.

### Alternatives considered

- **Check functions as `(): Bool`.**  Simpler but loses the detail string.
  `Result[Unit, String]` is negligibly more complex and far more useful.
- **`HealthRegistry` as a mutable global.**  Simpler wiring, but breaks
  composability.  The immutable-registry + `registerRoutes` pattern follows
  the web router.
- **Per-check timeout.**  Deferred; requires async support.  Added to the
  follow-up milestone list.

**Revisions:** PARTIALLY SUPERSEDED by D099 — the name-based
`handlerName: String` registration and the planned DLL-reflection kernel
dispatcher (with `registerRoutes` / `attachRegistry` / `config Endpoints`)
were replaced by function-reference registration; `runChecks` invokes
handlers directly.  The check-group split, immutable registry, and JSON
response shape are unchanged.

---

## D059 — Compiler and stdlib distribution strategy

**Date:** 2026-05-10
**Branch:** claude/review-docs-platform-parity-UuNIO
**Closes:** open question "Distribution channels" in `docs/22-distribution-and-tooling.md` §10.
**Spec:** `docs/34-distribution-strategy.md`

### Context

`docs/22-distribution-and-tooling.md` specified the SDK filesystem layout and
the stdlib pre-compilation approach but deferred the choice of distribution
channels to a Phase 6 decision doc.  With the self-hosted MSIL pipeline
(R6 / D-progress-227) now wired, the bootstrap pipeline and distribution story
need to be concrete enough for CI integration.

### Decision

**Primary channel: `dotnet tool install -g lyric` (NuGet global tool).**
Lowest-friction cross-platform path; requires the .NET SDK but no additional
tooling.  The NuGet package bundles the compiled CLI DLLs, `lib/Lyric.Stdlib.dll`,
`lib/Lyric.Stdlib.Jvm.jar`, and the stdlib source fallback.

**Secondary channel: self-contained ZIP/tarball via GitHub releases.**
`dotnet publish --self-contained true --runtime <RID>` bundles the .NET runtime;
no SDK required by the end user.  Published for five RIDs
(linux-x64, linux-arm64, osx-x64, osx-arm64, win-x64).

**Future: self-hosted AOT binary (Q-dist-001).**  Once the stage-2 bootstrap in
`scripts/bootstrap.sh` produces byte-for-byte reproducible output, the
self-hosted MSIL emitter is promoted to default and an AOT compile (`dotnet
publish --aot`) produces a native binary with no .NET runtime dependency.
Package manager formulas (Homebrew/winget/apt) are deferred until Q-dist-001
resolves — a native binary makes the formula trivial.

**Bootstrap pipeline (`scripts/bootstrap.sh`):**

- Stage 0: F# bootstrap compiler via `dotnet publish`.
- Stage 1: compile all Lyric compiler packages (stdlib + self-hosted lexer /
  parser / type checker / mode checker / contract elaborator / MSIL backend)
  with the stage-0 `lyric --target dotnet-legacy`.
- Stage 2: recompile stage-1 sources with `lyric --target dotnet` (self-hosted
  MSIL path); compare with `cmp -s` for reproducibility.  `STRICT_VERIFY=1`
  fails the script on any diff.

CI runs stage-1 on every push to `main`; stage-2 is nightly until
reproducibility is achieved, then promoted to the standard gate.

### Alternatives considered

- **Ship stdlib source only, no pre-compiled DLL.** Simpler distribution but
  cold-build time grows with stdlib size.  Rejected: every user project would
  recompile the stdlib on the first `lyric build`.
- **Homebrew tap as primary channel.** Requires maintaining an external tap
  repo and a formula.  Deferred: the NuGet global tool has better CI story and
  cross-platform uniformity today.
- **Single `dotnet tool` channel only, no ZIP.** Forces every user to install
  the .NET SDK.  Rejected: embedded-systems and air-gapped environments need
  a standalone binary.

**Revisions:** None.

---

## D060 — JVM output extension: plain `.jar`, not `.lyrjar`

**Status:** Decided.

**Context:** `docs/18-jvm-emission.md` §2.1 originally specified that the
JVM emitter writes `<P>.lyrjar` (a JAR with a non-standard extension) to
"distinguish Lyric output from Java output" and avoid polluting the `.jar`
namespace.  On closer examination this was unnecessary and actively harmful.

**Decision:** The JVM emitter produces plain `<P>.jar` files.

**Rationale:**

1. **The metadata is already sufficient.** Every Lyric-emitted JAR carries
   `Lyric-Lang-Version`, `Lyric-Package-Name`, and `Lyric-Package-SemVer`
   in `MANIFEST.MF`, plus the embedded `META-INF/lyric/*.lyric-contract`
   sidecar.  The build driver checks `Lyric-Lang-Version` to identify Lyric
   JARs; no extension signal is needed.

2. **Ecosystem compatibility.** Maven, Gradle, IDEs, `java --module-path`,
   and `javac -classpath` understand `.jar`, not `.lyrjar`.  Every other
   JVM language (Kotlin, Scala, Clojure, Groovy) publishes plain JARs.
   A `.lyrjar` extension would require custom repository configuration and
   tooling wrappers for every Java consumer.

3. **Java interoperability.** A Java project wanting to depend on a Lyric
   library just adds it to its classpath or module path as a `.jar`.  No
   adapter, no special plugin, no extension rename.

4. **Maven Central.** Publishing to Maven Central requires `.jar` artifacts.
   A `.lyrjar` would be rejected by the repository's artifact-type
   validation.

**Consequences:**

- `docs/18-jvm-emission.md` §2.1 and §2.2 updated.
- `docs/31-maven-linking.md` §7 updated.
- `book/chapters/14-jvm-target.md` documents `.jar` from day one.

---

## D061 — Self-hosted monomorphizer design: call-site AST-level specialisation

**Context:** Phase 5 §M5.2 stage 4.  The F# bootstrap emitter uses real CLR
generic types and methods (reified generics via `DefineGenericParameters`,
`MakeGenericType`, `MakeGenericMethod`).  The self-hosted MSIL PE emitter
(`Msil.Codegen`, `Msil.Lowering`) currently erases all generic type
applications to `MObject` (System.Object), which is sufficient for the M1–M83
PE-layer self-tests but fails for real programs that use typed generic values.

**Decision:** Implement a call-site monomorphizer at the TypeExpr (AST) level
rather than at the resolved-Type (checker) level or via PE-level TypeSpec/
MethodSpec metadata.

**Rationale:**

1. **Simpler PE emitter.** TypeSpec and MethodSpec rows in PE metadata require
   bespoke signature blob encoding for generic instantiations, extended table
   coverage, and coordinated row numbering across five metadata tables.
   Monomorphisation avoids all of this: the output PE contains only concrete
   (non-generic) types and methods, which the existing self-hosted emitter
   already handles.

2. **AST-level substitution.** The Lyric type checker records generic parameter
   names as strings in `ResolvedSignature.generics` and as `TyVar(name)` in
   resolved types, but does NOT annotate `ECall` nodes with inferred type
   arguments.  Working at the TypeExpr level (AST before type-checking) means
   substitution is a straightforward structural transformation (TRef to single-
   segment paths that match a generic param name → concrete TypeExpr) with no
   dependency on the checker output.

3. **Scope.** Only same-package generic functions are specialised.  Imported
   generic functions (from the F# bootstrap standard library) use real CLR
   generic types at runtime — correct because the bootstrap emitter already
   emits proper .NET generic metadata for those.

**Tradeoffs:**

- Output size grows with the number of distinct specialisations (no shared
  generic code).  Acceptable for a bootstrap-grade compiler.
- Type inference at call sites is limited to literals and explicitly-annotated
  variables.  Call sites where the argument type is not directly inferrable are
  left un-specialised (the original generic name is preserved; CLR's native
  generics handle them at runtime for imported functions).
- Does not handle value generic parameters (`GPValue`) or constraint
  propagation.  Tracked as Q-mono-001 for a follow-up.

**Implementation:** `compiler/lyric/lyric/mono.l` — `Lyric.Mono` package.
Public entry: `monoFile(file: in SourceFile): MonoResult`.  Shipped in
D-progress-229.

---

## D062 — lyric-lambda library: AWS Lambda runtime adapter design

**Date:** 2026-05-12
**Status:** Decided

### Context

Lyric services built with `lyric-web` run on Kestrel.  Deploying those same
services to AWS Lambda required either a heavy ASP.NET Core shim
(`Amazon.Lambda.AspNetCoreServer`) or hand-written glue code for each event
source.  Neither option was idiomatic Lyric.

### Decisions

**D062-1 — Custom runtime (not AspNetCoreServer)**
The kernel uses the AWS Lambda custom runtime protocol
(`Amazon.Lambda.RuntimeSupport`) rather than `AspNetCoreServer`.  This
eliminates Kestrel from the critical path for non-HTTP workloads and reduces
cold start.  The `serve()` loop polls the Runtime API directly.

**D062-2 — Zero-change lyric-web router reuse**
A `Web.Router` attached with `Lambda.withRouter()` is dispatched using the
same route-match and reflection-based handler-invocation logic as Kestrel.
API Gateway v1 (REST API), v2 (HTTP API), and ALB events are all normalised
to `method + path + headers + body` before dispatch.  The same handler
functions work on both runtimes without modification.

**D062-3 — Custom event handlers registered by qualified name**
Non-HTTP event sources (SQS, SNS, S3, EventBridge, DynamoDB Streams) are
registered with `onSqs / onSns / onS3 / onEventBridge / onDynamoDb / onRaw`.
Handlers are identified by fully-qualified Lyric function name and resolved
via DLL reflection at startup, consistent with `Web.Route.handlerName`.

**D062-4 — Event source detection by JSON structure inspection**
The kernel detects the event source from the raw JSON payload before
deserialising, using the detection rules in `docs/35-lambda-library.md §4.1`.
This avoids a discriminated union wrapper around every payload and lets the
typed event records in `Lambda.ApiGw` and `Lambda.Events` be clean records.

**D062-5 — Both modes coexist in one LambdaApp**
A single `LambdaApp` may have an `httpRouter` and custom event handlers.  The
kernel routes HTTP events to the router and all other events to the handler
table.  This lets a single Lambda function handle both API requests and
background queue processing.

**D062-6 — Feature-gated kernel (aws vs local)**
Two files both declare `package Lambda.Kernel.Runtime`, gated on `@cfg(feature
= "aws")` and `@cfg(feature = "local")` respectively.  The production build
uses `Amazon.Lambda.RuntimeSupport`; the local build starts an HTTP server
compatible with `sam local invoke` and `aws lambda invoke --endpoint-url`.

**D062-7 — SQS partial-batch-failure via return type**
SQS handlers may return `Result[SqsBatchResponse, LambdaError]` instead of
`Result[Unit, LambdaError]` to report per-message failures.  The kernel
serialises `batchItemFailures` into the Lambda response.  No separate handler
registration is needed; the kernel infers the intent from the return type.

**D062-8 — DeadlineGuard as a C-mode aspect (not kernel policy)**
The kernel does not enforce a global deadline margin.  Handlers opt in to the
`DeadlineGuard` aspect, which checks `ctx.remainingTimeMs` before proceeding.
This gives handlers control over the threshold and lets them compose logging
around the guard.

### Tradeoffs

- Custom runtime means the process bootstrap is in Lyric's kernel, not
  ASP.NET Core.  Kestrel's mature HTTP/2 and connection handling are not
  available for HTTP events, but API Gateway terminates TLS and HTTP/2 before
  reaching Lambda, so this is not a limitation in practice.
- Dispatch by qualified-name string is not AOT-compatible.  Q-lambda-001
  tracks a future `onSqsDirect` / `withRouterDirect` API accepting function
  references for AOT builds.

### Implementation

Library at `lyric-lambda/`.  Design document at `docs/35-lambda-library.md`.

---

## D063 — lyric-lambda v2: authorizers, secrets integration, and Kinesis

**Date:** 2026-05-12
**Status:** Decided

### Context

After the initial lyric-lambda library (D062), three feature gaps remained:
Lambda authorizer functions (Q-lambda-005), Secrets Manager / Parameter Store
config integration (Q-lambda-002), and Kinesis stream event support (Q-lambda-006).

### Decisions

**D063-1 — Both REST API and HTTP API authorizer types**
`Lambda.Authorizer` ships three event types and two response types:
- `TokenAuthorizerEvent` + `RequestAuthorizerEvent` → `AuthorizerResponse`
  (IAM `PolicyDocument` with `IamStatement` list; `allow`, `allowAll`, `deny`,
  `withContext`, `withUsageKey` helpers)
- `HttpAuthorizerEvent` → `HttpAuthorizerResponse`
  (`{ isAuthorized: Bool, context: Map[String, String] }`; `authorized`,
  `authorizedWithContext`, `denied` helpers)

REST API authorizers return full IAM policy documents; HTTP API authorizers
return the simpler payload format 2.0 boolean response.  Both are registered
via `LambdaApp` builder methods (`onTokenAuthorizer`, `onRequestAuthorizer`,
`onHttpAuthorizer`); the kernel detects authorizer invocations in the same
dispatch pass as event source handlers.

**D063-2 — `LambdaApp.authorizerHandlers` as a first-class field**
Rather than overloading `eventHandlers` with special source keys, authorizer
handlers are stored in a separate `authorizerHandlers: [AuthorizerHandler]`
field on `LambdaApp`.  This keeps event routing and authorizer routing
semantically distinct in the kernel dispatch.

**D063-3 — Config-block annotation model for secrets**
`lyric-aws-secrets` ships as a separate library with two annotations
(`@secretsManager`, `@parameterStore`) and an `init()` entry point.
`init()` scans the compiled DLL's config block metadata, fetches annotated
field values from AWS, and populates the process-level config cache under
the env-var key (`LYRIC_CONFIG_<PACKAGE>_<FIELD>`).  The existing config-block
access mechanism reads from the cache unchanged.  Env var overrides take
precedence (local dev without credentials).

**D063-4 — Secrets library is separate from lyric-lambda**
`lyric-aws-secrets` is a standalone library usable by any Lyric service
(ECS, Kubernetes, Kestrel on EC2) — not just Lambda.  The user calls
`AwsSecrets.init()` explicitly in `main()` before `Lambda.serve()` or
`Web.start()`.  No kernel magic required.

**D063-5 — Both Secrets Manager and Parameter Store in one library**
Both backends ship in `lyric-aws-secrets` under the same `AwsSecrets` package.
They are conceptually distinct (Secrets Manager for JSON blobs and rotation;
Parameter Store for simple strings and hierarchical paths) but similar enough
to ship together.  The `@secretsManager` and `@parameterStore` annotations
are unambiguous about which backend to call.

**D063-6 — In-process cache with configurable TTL**
Fetched values are cached for `SecretCache.ttlSeconds` (default 300 s).
TTL = 0 disables caching.  Chosen TTL should be a fraction of the rotation
period so stale values are refreshed in time.

**D063-7 — Kinesis via typed event record**
`KinesisEvent` / `KinesisStreamRecord` / `KinesisRecord` are added to
`Lambda.Events` and `onKinesis()` is added to the `LambdaApp` builder.
No partial-batch-failure equivalent; Kinesis retries the full batch on error.

### Implementation

`Lambda.Authorizer` in `lyric-lambda/src/authorizer.l`.
`lyric-aws-secrets` library at `lyric-aws-secrets/`.
`KinesisEvent` in `lyric-lambda/src/events.l`.
`onKinesis`, `onTokenAuthorizer`, `onRequestAuthorizer`, `onHttpAuthorizer` in `lyric-lambda/src/lambda.l`.
`docs/35-lambda-library.md` updated with §6 (Authorizers), §7 (Secrets), and resolved Q-lambda-002, Q-lambda-005, Q-lambda-006.

---

---

## D064 — lyric-lambda v3: AOT handlers, response streaming, JVM target, and X-Ray tracing

**Status:** ACCEPTED
**Date:** 2026-05-12

### Context

After D063, four feature gaps remained:
- Q-lambda-001: AOT-compatible handler registration (function references)
- Q-lambda-004: Lambda response streaming for Function URLs / HTTP API
- Q-lambda-JVM: JVM target support for lyric-lambda and lyric-aws-secrets
- Q-lambda-003: AWS X-Ray active tracing

The JVM emitter is complete (`compiler/lyric/jvm/`, D-progress-229+).

### Decisions

**D064-1 — Dual registration: string names (default) + function references (opt-in AOT)**
`Lambda.Direct` ships as a new package exposing typed factory functions that
accept function references (`func sqsHandler(h: func(...): ...): DirectHandler`).
`LambdaApp` gains a fifth field `directHandlers: [Lambda.Direct.DirectHandler]`.
The string-based `on*()` builders remain unchanged.  Both registration styles
may coexist in the same `LambdaApp`.  When `PublishAot=true`, use `withDirect()`
exclusively — string-named handlers would fail at startup because DLL reflection
metadata is stripped in AOT builds.

**D064-2 — Response streaming via `Lambda.Stream.StreamWriter`**
`Lambda.Stream` ships as a new package with an opaque `StreamWriter` type and
`setContentType`, `write`, `writeBytes`, `close` functions.
`LambdaApp` gains a `streamingHandler: Option[String]` field; the string-named
`withStreamingHandler()` and AOT-safe `Lambda.Direct.streamingHandler()` builders
register a single streaming handler.  Streaming handlers receive
`(rawEvent: String, ctx: LambdaContext, writer: StreamWriter)`.  The kernel
writes chunks directly to the runtime response stream; no buffering occurs.
`withStreamingHandler` and `withRouter` are mutually exclusive — streaming
handlers receive all HTTP traffic.

**D064-3 — JVM kernels for lyric-lambda and lyric-aws-secrets**
Both libraries gain a third kernel file gated on `feature = "jvm"`:
- `lambda_kernel_jvm.l` — extern to the Java managed runtime
  (`com.amazonaws.lambda.serve(app, localPort)`).  The Lyric JVM emitter
  generates `<RootPackage>$LambdaHandler implements RequestStreamHandler`.
  Handler discovery, dispatch logic, and streaming are identical to the .NET
  kernel.
- `secrets_kernel_jvm.l` — extern to AWS SDK for Java v2
  (`software.amazon.awssdk:secretsmanager` + `ssm`).
  `initFromAnnotations`, `fetchSecret`, `fetchParameter` mirror the .NET API.
Maven dependencies added to `[maven]` tables in respective `lyric.toml` files.

**D064-4 — X-Ray tracing as a separate `lyric-aws-xray` library**
AWS X-Ray active tracing is implemented as a B-mode pub aspect template
(`AwsXRay.Tracing`) in a standalone `lyric-aws-xray` library.  Rationale for
separation: X-Ray is useful for any Lyric service (not just Lambda), and the
library is optional — a service that doesn't need active tracing does not pay
the dependency cost.  The `lyric-otel` library remains for vendor-neutral
OpenTelemetry; `lyric-aws-xray` is the AWS-specific complement.
The aspect wraps matched calls as X-Ray subsegments; `annotate()` and
`metadata()` helpers allow handlers to attach indexed/non-indexed data.
Three kernels ship: `aws` (.NET Amazon.XRay.Recorder.Core), `jvm`
(com.amazonaws:aws-xray-recorder-sdk-core), `local` (no-op).

### Implementation

`Lambda.Direct` in `lyric-lambda/src/direct.l`.
`Lambda.Stream` in `lyric-lambda/src/stream.l`.
`lambda_kernel_jvm.l` in `lyric-lambda/src/_kernel/`.
`secrets_kernel_jvm.l` in `lyric-aws-secrets/src/_kernel/`.
`lyric-aws-xray/` library at project root.
`lyric-lambda/lyric.toml` updated: 8 packages, 3 features (aws/local/jvm), `[maven]` table.
`lyric-aws-secrets/lyric.toml` updated: 3 features (aws/local/jvm), `[maven]` table.
`docs/35-lambda-library.md` updated with §10 (AOT), §11 (Streaming), §12 (JVM),
§13 (X-Ray), §14 (runtime config), §15 (design notes), §16 (resolved open questions).

---

## D065 — Pure-Lyric XML and YAML/JSON parsers in the standard library

**Context:** `Std.Json` (shipped at M1.3) wraps `System.Text.Json` via a
`_kernel/json_host.l` extern boundary.  That approach works on .NET but
requires a separate kernel bridge for every target (JVM, native), doubling
maintenance and diverging the API surface.  An XML library following the same
pattern would need `System.Xml.Linq` on .NET and `javax.xml` / `org.w3c.dom`
on JVM — two bridges, two slightly-different APIs, no shared code.

A viability probe (`stdlib/tests/xml_viability_tests.l`, PR #269) confirmed
that the emitter supports all the primitives a pure-Lyric parser needs:
self-referential union types (`XmlNode` with `List[XmlNode]` children),
recursive tree traversal, and character-level string walking (`s[i]`,
`isWhiteSpace`, `substring`).  Two syntax constraints were discovered during
the probe: multi-statement match-arm bodies require `-> { }` braces, and
chained `else if` must keep `} else if` on the same line.

**Decision:** Ship `Std.Xml` and `Std.Yaml` as pure-Lyric libraries with no
kernel externs.  Both target both MSIL and JVM without any extra plumbing.
`Std.Yaml` covers YAML 1.2 including the JSON subset (YAML 1.2 §1.2: "JSON
is YAML"), so `parseJson` and `parseYaml` share the same data model.

**Scope of the initial implementation:**

`Std.Xml` (`stdlib/std/xml.l`):
- Full XML 1.0 subset: elements, attributes, text, comments, CDATA, entity
  references (&amp; &lt; &gt; &apos; &quot; &#NNN; &#xNNN;), self-closing
  tags, XML declarations, DOCTYPE (consumed, not represented), PIs (consumed).
- No namespace prefix resolution; `ns:name` treated as a plain name.
- No DTD validation or entity expansion beyond the five built-in entities
  plus numeric code-point entities.
- API: `parseXml`, `documentRoot`, `elementTag`, `elementAttrs`,
  `elementChildren`, `getAttribute`, `textContent`, `findFirst`, `findAll`.

`Std.Yaml` (`stdlib/std/yaml.l`):
- JSON strict mode (`parseJson`): objects, arrays, strings with escape
  sequences, numbers (integer and float), booleans, null.
- YAML mode (`parseYaml`): JSON flow style + YAML block mappings and
  sequences, unquoted/single-quoted/double-quoted scalars, YAML boolean
  aliases (yes/no/on/off), null alias (~).  Anchors, aliases, directives,
  and tags return `UnsupportedFeature`.
- API: `parseJson`, `parseYaml`, `isNull`, `asString`, `asBool`, `asInt`,
  `asSequence`, `asMapping`, `getField`, `getString`, `getInt`, `getBool`.

**Type-generation tooling (deferred to a follow-up):** The natural next step
is `lyric gen-types` — a CLI command that infers Lyric record/union
declarations from a JSON/YAML sample or JSON Schema / XSD.  The inference
rules are straightforward: `YMapping` → `record`, `YSequence` → `List[T]`,
scalar kinds → primitive types, nullable fields (`YNull` in a sample) →
`Option[T]`.  JSON Schema support would use `$ref` to name nested records.
This will be implemented as a self-hosted `Lyric.GenTypes` library (following
the pattern of `Lyric.Fmt` and `Lyric.TestSynth`) with a `lyric gen-types`
CLI entry point.

**Tradeoffs:**
- Pure Lyric parsers are slightly slower than BCL-backed ones for large
  documents, but benchmarks are not a concern at this stage.
- The existing `Std.Json` (BCL-backed) is retained for backward compatibility;
  new cross-platform code should prefer `Std.Yaml.parseJson`.
- Float parsing in `Std.Yaml` returns `YString` for floating-point literals
  (the raw text) because a `toDouble` BCL bridge is not yet wired.  Tracked
  as Q-yaml-001; fix will land when the float-conversion extern ships.

---

## D066 — v1.0 gate decisions G3–G5: formatter flag, service library versioning, bootstrap reproducibility

**Context:** `docs/36-v1-roadmap.md` listed five gate decisions (G1–G5) required
before v1.0 can be tagged.  G1 and G2 were resolved in D058–D065 (JVM channel
policy and `@experimental`→`@stable` graduation list).  This entry records G3,
G4, and G5.

### G3 — Legacy formatter flag fate

**Decision:** `--legacy` / `LYRIC_FMT_LEGACY=1` survives as a supported but
deprecated flag through v1.0 and is removed in v1.1.

**Rationale:** The CST-based self-hosted formatter (`lyric fmt`, backed by
`Lyric.Fmt`) handles all top-level items and block structures.  The remaining
per-expression CST gap (complex nested match arms) is real but affects a small
subset of programs.  Forcing that gap to close before 1.0 would stall the
release by 2–4 weeks.  Shipping with the escape hatch documented as deprecated
gives adopters a working formatter path on day one and closes the gap cleanly
in 1.1 without SemVer pressure.

The flag is documented in the language reference §CLI as:
> `--legacy` / `LYRIC_FMT_LEGACY=1` — use the AST-based fallback formatter.
> Deprecated as of v1.0; will be removed in v1.1.

### G4 — Service library versioning policy

**Decision:** The `lyric-*` service libraries (`lyric-web`, `lyric-cache`,
`lyric-db`, `lyric-health`, `lyric-logging`, `lyric-otel`, `lyric-lambda`,
`lyric-aws-secrets`, `lyric-aws-xray`) version **independently** of the compiler
and core stdlib.  Each library's stability policy is declared in its own
`lyric.toml` under a `[package.stability]` annotation.  `@experimental` surfaces
in those libraries do not freeze with the Q011 surface freeze.

**Rationale:** These libraries evolve at a different cadence from the language
itself.  Coupling them to the compiler's SemVer would either freeze their API
prematurely or delay 1.0 until every service library API is stable — neither is
acceptable.  The JVM target policy (G1) applies only to the core compiler and
`Std.*` modules.

### G5 — Bootstrap reproducibility requirement

**Decision:** The three-stage reproducibility bootstrap (`scripts/bootstrap.sh`:
F# → self-hosted → self-hosted² binary comparison) is **not required** to produce
a passing diff before v1.0.  The F# bootstrap remains the primary build path
for the 1.0 release.

**Rationale:** The self-hosted pipeline (M5.1–M5.3) is at stage-5 of 6 (MSIL
emitter through `SelfHostedMsil.fs`; JVM emitter through `SelfHostedJvm.fs`).
The codegen stage of the self-hosted compiler is substantially complete, but
binary-identical output between F#-compiled and self-hosted-compiled compiler
binaries requires the final codegen parity work that is a Phase-7 deliverable
(Q-dist-001).  Blocking 1.0 on this would delay the release by months while
providing no benefit to end users of the language.  The bootstrap script ships
as a Phase-7 target; the CI pipeline gates on it before any 2.0 tag.

---

## D067 — lyric-proto: pure-Lyric Protocol Buffer wire-format library

**Status:** Accepted.
**Builds on:** D038 (kernel boundary), D056 (lyric-db byte-slice patterns).

### Context

The OTLP gRPC transport and general-purpose gRPC RPC calls require binary
protobuf encoding and decoding.  Options considered:

1. **BCL-backed kernel only** — delegate all protobuf work to `Google.Protobuf`
   NuGet at the kernel boundary.  Simple but opaque; no Lyric-level inspection
   of message structure.
2. **Schema-driven codegen** — generate Lyric types from `.proto` files at
   build time.  Powerful but requires a codegen tool that does not exist yet.
3. **Pure-Lyric wire-format library** — implement varint, fixed-width, and
   length-delimited encoding in Lyric arithmetic, with only two kernel helpers:
   IEEE 754 bit extraction (System.BitConverter) and a ProtoBuffer accumulator
   (System.IO.MemoryStream).

**Decision: option 3.**

The pure-Lyric approach keeps all encoding logic inspectable and testable in
Lyric.  The kernel is minimal and audited (D038 Resolution F).  No extra NuGet
packages are needed.  Schema-driven codegen remains a future option and is not
blocked by this decision.

### Key decisions

**D067-1 — ProtoBuffer as an opaque accumulator**
`Proto.Kernel.Net` exposes `newProtoBuffer()`, `bufWriteByte`, `bufWriteBytes`,
`bufToBytes`, and `bufLength` backed by `System.IO.MemoryStream`.  The pure
Lyric encoder writes to the buffer without knowing its implementation.

**D067-2 — Float/double as IEEE 754 bits via BitConverter**
`floatToInt32Bits` and `doubleToInt64Bits` are the only arithmetic operations
that cannot be implemented in pure Lyric integer arithmetic without a kernel
helper.  They map to `System.BitConverter.SingleToInt32Bits` /
`DoubleToInt64Bits` on .NET and `java.lang.Float/Double` on JVM.

**D067-3 — Raw byte indexing in the decoder**
`byteAt`, `int32LE`, `int64LE`, and `sliceCopy` provide the primitive reads
the decoder needs from a `slice[Byte]`.  These are kernel-provided to avoid
exposing a mutable indexer on `slice[T]` in the public stdlib API.

**D067-4 — proto3 subset only; Groups deprecated**
Wire types 3 (StartGroup) and 4 (EndGroup) are deprecated in proto3 and are
not supported.  The decoder returns `Err` if it encounters them.  proto2
extensions and `oneof` are not modelled at the type level; callers inspect
`DecodedField` directly.

**D067-5 — ZigZag helpers in Proto.Types**
`zigzag32`, `zigzag64`, `unzigzag32`, `unzigzag64` are pure Lyric integer
arithmetic provided in `Proto.Types` so callers handle sint32/sint64 without
needing to know the wire-format detail.

### Files shipped

- `lyric-proto/lyric.toml`
- `lyric-proto/src/types.l` — `WireType`, `ProtoField`, `DecodedField`, `DecodeStep`
- `lyric-proto/src/_kernel/net/proto_kernel.l` — .NET extern boundary
- `lyric-proto/src/_kernel/jvm/proto_kernel.l` — JVM Phase 6 stub
- `lyric-proto/src/encoding.l` — pure-Lyric encoder
- `lyric-proto/src/decoding.l` — pure-Lyric decoder
- `lyric-proto/src/proto.l` — public API re-exports

---

## D068 — lyric-grpc: general-purpose gRPC client library

**Status:** Accepted.
**Builds on:** D067 (lyric-proto), D038 (kernel boundary), D056 (library structure).

### Context

The OTLP gRPC transport needs a gRPC channel.  More broadly, Lyric services
increasingly call gRPC backends (internal microservices, Google Cloud APIs,
etcd, etc.).  A library is needed.

Options:

1. **Embed gRPC logic in lyric-otel** — tight coupling; not reusable.
2. **Use raw HttpClient with manual HTTP/2 framing** — avoids extra NuGet
   dependency but requires implementing gRPC message framing, trailer parsing,
   and flow control in the kernel.
3. **Wrap Grpc.Net.Client** — the standard .NET gRPC client; handles HTTP/2,
   TLS, connection pooling, and flow control.  Uses a pass-through
   `Marshaller<byte[]>` so callers supply and receive raw bytes.

**Decision: option 3** for .NET; `io.grpc.ManagedChannel` for JVM (Phase 6).

The pass-through marshaller pattern (`Marshallers.Create(x => x, x => x)`)
is well-known in the Grpc.Net.Client ecosystem and requires no generated stub
code.  All protobuf encoding/decoding remains in the caller (using lyric-proto
or any other mechanism).

### Key decisions

**D068-1 — Raw slice[Byte] payloads**
`callUnary` takes `payload: slice[Byte]` and returns `Result[slice[Byte], GrpcStatus]`.
The library is encoding-agnostic.  The lyric-proto library is the recommended
encoding layer but is not a hard dependency.

**D068-2 — Metadata as comma-separated key:value string at the kernel boundary**
The kernel receives metadata as a single `String` in `"k1:v1,k2:v2"` format to
avoid exposing `List[GrpcMetadataEntry]` across the extern boundary (which
would require a complex marshalling shim).  The pure Lyric `metadataString`
helper serialises the `List[GrpcMetadataEntry]` before calling the kernel.

**D068-3 — Server-streaming but no client-streaming or bidi**
`openServerStream` + `nextMessage` + `closeStream` cover the server-streaming
pattern needed by the OTel live-tail API and similar.  Client-streaming and
bidirectional streaming are deferred; they require a mutable send stream that
does not fit naturally into Lyric's mode system today.

**D068-4 — Blocking unary call at the kernel boundary**
`netCallUnary` is synchronous (blocking).  Callers who want async behaviour
should wrap it in a `Task` or use a background thread.  A future `async`
variant (`netCallUnaryAsync`) is straightforward to add when the emitter's
`async` support stabilises (M1.4+).

**D068-5 — Separate from lyric-otel OTLP export**
The OTLP exporter kernel (D069) uses the OTel SDK's built-in transport, not
lyric-grpc.  lyric-grpc is for application-level gRPC calls.  Applications can
use both libraries simultaneously without conflict.

### Files shipped

- `lyric-grpc/lyric.toml`
- `lyric-grpc/src/types.l` — `GrpcChannel`, `GrpcStatus`, `GrpcStatusCode`, `GrpcCallOptions`, `GrpcStream`
- `lyric-grpc/src/_kernel/net/grpc_kernel.l` — .NET Grpc.Net.Client boundary
- `lyric-grpc/src/_kernel/jvm/grpc_kernel.l` — JVM Phase 6 stub
- `lyric-grpc/src/grpc.l` — public API

---

## D069 — lyric-otel: OTLP exporter (OTel.Otlp package)

**Status:** Accepted.
**Builds on:** D-progress-142 (lyric-otel precedent), D067, D068.

### Context

The existing `lyric-otel` library wraps `System.Diagnostics.ActivitySource`
(on .NET) for span creation but has no export pipeline: spans are only visible
to OTel diagnostic listeners attached to the process.  To send telemetry to an
OTel collector (Collector, Jaeger, Tempo, Honeycomb, Datadog, etc.) an OTLP
exporter is needed.

OTLP is the standard OTel wire protocol.  It uses protobuf encoding over two
transports: gRPC (port 4317) and HTTP/1.1 (port 4318).

Options for the .NET implementation:

1. **Manual OTLP protobuf encoding** — use lyric-proto to encode
   `ExportTraceServiceRequest` and lyric-grpc to send it.  Requires mapping
   the 100+ OTLP message types and managing batching and retry manually.
2. **OTel SDK + built-in OTLP exporter** — call
   `Sdk.CreateTracerProviderBuilder().AddOtlpExporter(…).Build()` at startup.
   The SDK then automatically picks up all `ActivitySource` activity from the
   existing `OTel.Kernel.Net` code, batches it, and exports it.

**Decision: option 2 for production .NET export.**

The OTel .NET SDK is the standard implementation.  It already knows how to
encode spans to OTLP protobuf, manage the batch queue, handle retries with
exponential backoff, and negotiate transport.  Reimplementing this in Lyric
would be a substantial effort with no user-visible benefit.  lyric-proto and
lyric-grpc remain the correct tools for application-level gRPC calls.

### Key decisions

**D069-1 — Provider stored in a .NET static field**
The `TracerProvider`, `MeterProvider`, and `LoggerProvider` returned by the
SDK builder calls must be kept alive for the process lifetime.  The kernel
stores each provider in a static field.  `netFlushOtlp` calls `ForceFlush`
on all three; they are disposed on process exit.

**D069-2 — Three separate configure functions + a combined convenience**
`configureOtlpTraces`, `configureOtlpMetrics`, `configureOtlpLogs` each set
up one signal independently.  `configureOtlp` calls all three and
short-circuits on the first error.  Applications that only emit traces (common
in library code) pay no overhead for the metric/log pipelines.

**D069-3 — OtlpHeader list serialised as "key=value" comma-string**
The OTel SDK's `options.Headers` property is a comma-separated string.  The
Lyric `headersString` helper converts `List[OtlpHeader]` to this format before
crossing the kernel boundary.  Header values must not contain commas (a known
SDK limitation).

**D069-4 — config block OtlpDefaults for environment override**
Standard OTel environment variables (`OTEL_EXPORTER_OTLP_ENDPOINT`,
`OTEL_EXPORTER_OTLP_PROTOCOL`) are read by the .NET SDK automatically and
take precedence.  The `OtlpDefaults` config block provides Lyric-level
defaults for code that does not set these env vars.

**D069-5 — JVM kernel is a Phase 6 stub**
The JVM kernel mirrors the .NET API using `io.opentelemetry.exporter.otlp`.
It is not compiled today.

### NuGet packages added to lyric-otel

- `OpenTelemetry` 1.9.0 — SDK (TracerProvider, MeterProvider, LoggerProvider)
- `OpenTelemetry.Exporter.OpenTelemetryProtocol` 1.9.0 — OTLP exporter
  (pulls in `Grpc.Net.Client` transitively for the gRPC transport)

### Files shipped

- `lyric-otel/src/otlp.l` — `OtlpProtocol`, `OtlpExporterConfig`, `OtlpHeader`,
  configure/flush functions, `config OtlpDefaults`
- `lyric-otel/src/_kernel/net/otlp_kernel.l` — .NET OTel SDK wrapper
- `lyric-otel/src/_kernel/jvm/otlp_kernel.l` — JVM Phase 6 stub
- `lyric-otel/lyric.toml` — updated with new packages and NuGet dependencies

---

## D-progress-261 — Band F post-review follow-ups (F1–F11)

Addresses all tractable items from `docs/12-todo-plan.md` Band F.

**F1 — B128 `/tmp` path portability.**  `JvmLoweringB128Test.fs` now
generates a unique per-run temp dir via `Guid.NewGuid()` and passes it as
`argv[0]` to the compiled Lyric program via the new `runDllWithArgs` helper
in `EmitTestKit.fs`.  `compiler/lyric/jvm/self_test_b128.l` `main()` changed
from `(): Unit` to `(args: in slice[String]): Int`; it reads `args[0]` if
present, falling back to the original path.

**F2 — `in` mode spec clarification.**  Added a paragraph to
`docs/01-language-reference.md` §5.2 (Parameter modes) clarifying that `in`
prohibits rebinding the parameter but does not prevent mutation through a
mutable container type (e.g., `list.add(x)` on an `in List[T]` is allowed).
The V0001 diagnostic note is updated to match.

**F3 — `@externTarget` static-vs-instance naming convention.**  Added
documentation to `docs/01-language-reference.md` §11.3 describing the JVM
PascalCase-prefix-before-underscore convention used by `isStaticExternByName`
in `codegen.l`, with examples.

**F4 — Lint bridge multi-line message escaping.**  `lint_bridge.l` now calls
`replace(d.message, "\n", "\\n")` before serialising.  `SelfHostedLint.fs`
`parseLine` unescapes with `.Replace("\\n", "\n")`.

**F5 — ProcessExit cleanup for all bridges.**  Added
`AppDomain.CurrentDomain.ProcessExit.Add` handlers (same pattern as
`SelfHostedCli.fs`) to `SelfHostedDoc.fs`, `SelfHostedFmt.fs`,
`SelfHostedPack.fs`, `SelfHostedManifest.fs`, `SelfHostedTestSynth.fs`, and
`SelfHostedLint.fs`.

**F6 — Test coverage.**  Added `DocTests.fs` (three fixture cases) to
`Lyric.Cli.Tests`.  Pack XML coverage was already substantial via
`PackTests.fs`.

**F7 — GitHub Actions SHA pinning.**  Pinned `actions/checkout`,
`actions/setup-dotnet`, and `softprops/action-gh-release` to commit SHAs in
`.github/workflows/publish.yml`.  Added `.github/dependabot.yml` (weekly
`github-actions` ecosystem scan) to automate future SHA updates.

**F8 — JVM `Error` vs `Exception` limitation documented.**  Added Q-J009 to
`docs/18-jvm-emission.md` §24 and Appendix B describing the known limitation
that `@externTarget` catch handlers target `java/lang/Exception`, not
`java/lang/Throwable`, so JVM `Error` subclasses escape.

**F9 — `findExternTarget` double-walk.**  Already resolved in a previous
refactor; only one walk of `decl.annotations` exists in `codegen.l`.  No
code change needed.

**F10 — `Std.String.join` for `List[String]`.**  Added
`pub func join(xs: in List[String], sep: in String): String` to
`stdlib/std/string.l` (marked `@stable(since="1.0")`).  `doc/doc.l`'s
private `joinStrs` helper removed and all call sites updated to `Str.join`.

**F11 — Regression tests.**  Added two cases to `RestoredPackageE2ETests.fs`:
- `Q021-4 Path 1.5`: cross-package distinct type with `derives Compare`
  satisfies `where T: Compare` in the importing package (exercises
  `satisfiesViaImportedDistinct` in `Codegen.fs`).
- `Q022-1 pubUseDecls`: a `pub use Pkg.{name}` re-export appears in the
  emitted `Lyric.Contract` resource of the re-exporting package (exercises
  `pubUseDecls` in `ContractMeta.fs`).

---

## D-progress-262 — Self-hosted parser: `var` mutable record fields (#1473)

The self-hosted parser rejected `var`-prefixed mutable record fields
(language reference §3.4 "Mutable record fields") with `P0103` / `P0120`
/ `P0050`: `parseFieldDecl` in `lyric-compiler/lyric/parser/parser_items.l`
read the field name directly and choked on the `var` keyword.  This broke
every `lyric test --manifest` build whose library package declared a mutable
record field — the headline symptom was `error[P0103] 272:3: expected an
identifier for field name` on all three `lyric-session` test files, which
share `src/session.l`'s `record InProcessSessionStore { var sessions: … }`.
The F# bootstrap parser already consumed `var` here (`Parser.fs`
`parseRecordMembers`), so this was a self-hosted parity gap, not a spec
question.

**Fix.**
- `FieldDecl` (`parser/parser_ast.l`) gains an `isMutable: Bool` field.
- `parseFieldDecl` consumes an optional `var` marker after visibility and
  records it, so `var x: T`, `pub var x: T`, and annotation/doc-prefixed
  forms all parse.
- `Lyric.Fmt` (`fmt/fmt_items.l` `fieldDeclStr`) renders the `var ` prefix
  so the marker survives a format round-trip instead of being silently
  dropped (the previous AST carried no mutability, so `lyric fmt` would have
  rewritten a mutable field to immutable).
- `Lyric.AliasRewriter` (`alias_rewriter.l`) threads `isMutable` through.
- `docs/grammar.ebnf` `FieldDecl` updated to `[ 'var' ] IDENT ':' Type …`,
  reconciling the grammar with the language reference per CLAUDE.md.

Mutability *enforcement* (e.g. rejecting reassignment of a non-`var` field)
is a separate concern handled by the mode checker and is unchanged here; the
emitter continues to treat all record fields uniformly.

**Tests.** `parser_self_test.l` gains `testMutableRecordField`,
`testImmutableRecordField`, and `testPubMutableRecordField`;
`fmt_self_test.l` gains `testFormatMutableRecordField` (round-trip).  With
the fix, the `lyric-session` test files parse and build; the remaining
runtime failures (missing `Lyric.Stdlib.Testing` probe, "invalid program"
from cross-package generic widening) are tracked separately in #1509 and
#1471.

---

## D070 — Gap-4a: async generators with internal `await`

**Status:** ACCEPTED — shipped (D-progress-261).  **Date:** 2026-05-16 (deferred); 2026-05-17 (resolved).

**Builds on:** D035 (async row now superseded — real SM shipped), D-progress-260 (Gap-1..4 closure), D-progress-261 (Gap-4a implementation).

### Context

The async-generator emitter (`AsyncGenerator.fs`, `lowerAsyncGenerator`
in `compiler/lyric/jvm/lowering.l`) uses an "eager producer" model: `RunBody()`
(MSIL) or `runBody()` (JVM) is called synchronously inside `GetAsyncEnumerator`
/ `iterator()`, so all `yield` expressions execute before the first
`MoveNextAsync` / `hasNext` call returns.  This is correct and sufficient for
generator comprehensions and async-producer scenarios where the body contains
no `await`.

A generator body that contains an `await` expression requires a true coroutine
suspension point between successive `yield`s.  The eager model produces
incorrect sequencing in that case: the body runs to completion before any
consumer sees the first element, and any intermediate `await` suspensions
occur inside `RunBody()` rather than interleaved with consumer `MoveNextAsync`
calls.

### Decision

Gap-4a is **resolved** (D-progress-261).  The emitter now synthesises a combined
`IAsyncStateMachine` + `IAsyncEnumerable<T>` class (`<f>__AsyncIter_N`) for
generators whose body contains `await`.  The concrete implementation:

- **Builder**: `AsyncTaskMethodBuilder` (void) — used only for
  `AwaitUnsafeOnCompleted`; `SetResult`/`SetException` are never called on it.
- **Signaling**: `TaskCompletionSource<bool>` field `_tcs`.  `MoveNextAsync`
  creates a fresh TCS, calls `this.MoveNext()`, returns `ValueTask<bool>(_tcs.Task)`.
- **State layout**: states 0..A-1 are await-resume states (Phase-B protocol);
  states A..A+Y-1 are yield-resume states.
- **`yield e`** stores `e` to `<>2__current`, sets state to `A+i`,
  flushes promoted locals to their fields, calls `_tcs.SetResult(true)`,
  then `Leave`s past the try/catch and returns.
- **End-of-body** calls `_tcs.SetResult(false)` (generator exhausted).
- **Exception** calls `_tcs.SetException(ex)`.
- **Promoted locals**: any local live across an await *or* a yield boundary is
  promoted to a field on the class.  Fields are loaded at MoveNext entry and
  flushed at every suspend point.

See `docs/09-msil-emission.md` §14.6.2 for the full structure.

### Single-use `GetAsyncEnumerator` constraint

Both the eager-producer and the async-iterator strategies produce a class where
`GetAsyncEnumerator` returns `this`.  Calling `GetAsyncEnumerator` twice
concurrently (sharing the same generator instance) is not supported.

The `for x in f(args)` desugaring creates a new generator instance per loop
(the kickoff stub runs on each call to `f`), so well-formed Lyric code is
unaffected.  Code that captures the `IAsyncEnumerable<T>` value and passes it
to two concurrent consumers at once is an unsupported pattern; it violates the
single-enumerator contract of the interface.

---

## D071 — `yield` uses expression precedence; `await` uses postfix precedence

**Status:** Accepted.  **Date:** 2026-05-17.

**Builds on:** D-progress-260 (yield keyword added), grammar.ebnf.

### Decision

`yield` binds its argument with full expression (assignment) precedence:
`yield a * 2` is `yield (a * 2)`.  This matches Rust, Python, and C# iterator
behaviour and is the natural reading for a statement-level keyword.

`await` uses postfix (primary) precedence: `await a * 2` is `(await a) * 2`.
This is consistent with the existing Lyric grammar where `await` is a
postfix-only operator applied to a single expression, matching the "await this
task, then do arithmetic on the result" reading.

The asymmetry is intentional and documented in §7.2 of the language reference.
Users coming from C# may find `await` surprising (C# `await` also has low
precedence, matching Lyric's `yield`).  No change planned: `yield` as a
statement-level construct with expression-scope binding is the correct design.

---

## D072 — `Auth.verifyJwt` requires explicit `allowedAlgorithms`

**Status:** Accepted.  **Date:** 2026-05-17.

**Builds on:** D056 (lyric-auth shipped), lyric-lang #315.

### Decision

`Auth.verifyJwt` (and the matching `Auth.Kernel.Net` / `Auth.Kernel.Jvm`
externs) gains a fifth parameter, `allowedAlgorithms: in String`, with
contract `requires: allowedAlgorithms.length > 0`.  The string is a
comma-separated allow-list of JWT `alg` values (e.g. `"HS256"` or
`"HS256,RS256"`) that the caller is prepared to honour.

The pre-#315 surface accepted only a `secret`; the algorithm was read
from the token header.  That surface admitted three classic JWT attack
classes — `alg=none` forgery, HS256/RS256 confusion (signing with a
known public key as the HMAC secret), and `kid` injection — across
every endpoint protected by `RequiresAuth`, `RequiresRole`, `WsAuth`,
`RequiresGrpcAuth`, and `RequiresGrpcRole`.

### Security rationale

RFC 8725 (JWT Best Current Practices) §3.1 mandates an explicit
allow-list of algorithms — naming "alg=none" specifically as a
disallowed default.  Without an allow-list parameter at the API
boundary, even a correctly-implemented host shim cannot enforce the
restriction; callers have no way to express which algorithms they
deployed against.  The contract precondition at the Lyric boundary
makes "no algorithm specified" a contract violation rather than a
silent allow-all path.

### Migration

`Auth.verifyJwt` carried `@stable(since="0.1")` and the new positional
parameter is a breaking change for any direct caller.  Across the
in-tree ecosystem the only callers are the five aspect templates in
`lyric-web`, `lyric-grpc`, and `lyric-ws`; each grows a
`allowedAlgorithms: String = "HS256"` config field with a safe default
that matches existing HMAC-SHA256 deployments.  External callers must
pass an explicit allow-list — for HS256-only deployments that's
`"HS256"`; for RS256-only, `"RS256"`; for transitional setups,
`"HS256,RS256"`.

`@stable(since="0.1")` remains intact: the 0.1 stability band has
historically permitted breaking changes for credibility-critical
security fixes (cf. D-progress-126 SDK-version embedding).  The shim
ecosystem is still pre-1.0; the v1.0 surface freeze (Q011) is the
forward stability boundary, and the new signature lands inside that
window.

### Outstanding work

The kernel-side `.NET` and `JVM` host shim implementations still need
to pipe `allowedAlgorithms` through to
`TokenValidationParameters.ValidAlgorithms` (.NET) and the JJWT
`SignatureAlgorithm` whitelist (JVM).  The Lyric-level contract
barrier closes the user-facing API gap immediately; the host wiring
follows in a separate PR.

---

## D073 — Workspace, git dependencies, and local library resolution

**Date:** 2026-05-18
**Sketch:** `docs/38-workspace.md`

### Decision

Three orthogonal mechanisms are added to the Lyric package system to address
in-repo cross-library dependencies, external unregistered packages, and the
goal of keeping NuGet / Maven out of application manifests.

**Workspace.** A `[workspace]` table in a root `lyric.toml` (no `[package]`
section — a "virtual workspace") enables a monorepo workflow. Members are
auto-discovered by walking subdirectories for `lyric.toml` files; directories
are excluded via `[workspace].exclude` (path-prefix list) or by setting
`workspace = false` in a member's `[package]` table. A single `lyric.lock` at
the workspace root unifies resolution for all members.

**Workspace dependency form.** Members declare cross-member deps with
`{ workspace = true }`:

```toml
"Lyric.Cache" = { workspace = true }
"Lyric.Cache" = { workspace = true, version = "0.1.0" }  # version validates local manifest
```

The registry form (`"Lyric.Cache" = "0.1.0"`) is not redirected through the
workspace — it always resolves from the registry. This lets a package pin a
specific published version of a sibling without implicit substitution.

**Git dependency form.** External packages can be depended on directly from a
git source:

```toml
"SomeLib" = { git = "https://github.com/user/repo", tag = "v1.0.0" }
"MonoLib" = { git = "https://...", tag = "v0.2.0", subdir = "lyric-somelib" }
```

Supported ref keys: `tag` (immutable, preferred), `rev` (pinned commit),
`branch` (mutable, warns at build time, rejected in published packages). Git
sources are cached in `~/.lyric/git-cache/` keyed on resolved commit. The lock
file records the resolved commit SHA for every git dep.

**Workspace overrides.** `[workspace.overrides]` in the root manifest redirects
any dep (registry, git, or path) to a local directory for fork/patch
development. Overrides trigger a warning during `lyric publish`.

**Transitive native deps.** `[nuget]` and `[maven]` entries in library
manifests are propagated transitively through the dep graph. Application
manifests do not need to repeat native entries for libraries they consume.
Published packages embed their native dep lists in registry metadata so
downstream resolvers can reconstruct the NuGet / Maven graph without fetching
source.

### Alternatives considered

**Explicit member list.** Cargo's `members = ["lyric-*"]` glob form. Rejected
in favour of auto-discovery with an exclusion list — the ecosystem already has
20+ member directories and explicit listing adds maintenance cost with no safety
benefit (the opt-out per-member mechanism provides the precision when needed).

**Go-style GitHub URL deps as the primary mechanism.** Go resolves packages
directly by URL (`require github.com/user/repo v1.0.0`). Considered but
rejected for the primary in-repo case: workspace-local resolution is more
ergonomic and doesn't couple the build to a network fetch for packages that
are already on disk. The git dep form provides the same URL-based escape hatch
for external packages.

**Automatic workspace substitution of registry deps.** Any dep on a package
that happens to be a workspace member could be silently redirected to the local
source. Rejected: implicit substitution makes it hard to pin a specific
published version of a sibling or to test against a released artifact. The
explicit `{ workspace = true }` opt-in is clearer.

### Open questions

Q-W-001 through Q-W-004 track the path toward eliminating `[nuget]` / `[maven]`
from application manifests entirely (renaming to `[platform.dotnet]` /
`[platform.jvm]`, enforcement at publish time, migration tooling). See
`docs/38-workspace.md` §8.

---

## D074 — Lyric package registry: NuGet.org (.NET) and GitHub Packages Maven (JVM)

**Date:** 2026-05-18
**Spec:** `docs/39-package-registry.md`

### Decision

Third-party and first-party Lyric library packages are published to and
consumed from existing package infrastructure rather than a bespoke registry:

- **.NET target** → NuGet.org. Lyric DLLs are valid .NET assemblies; `lyric
  publish` wraps them in `.nupkg` files tagged `lyric-package` and pushes via
  `dotnet nuget push`. `lyric restore` resolves from the NuGet.org V3 feed.
- **JVM target** → GitHub Packages Maven (short-term); Maven Central (Phase 6,
  once GPG signing and namespace claim are set up — Q-R-002).

Package identity is direct: the Lyric package name (`Lyric.Cache`) maps 1:1 to
the NuGet package ID, and to the Maven artifact ID by lowercased kebab-case
under the `io.lyric-lang` group.

`[nuget]` / `[maven]` entries in library manifests are embedded in the
published `.nupkg` as NuGet `<dependencies>` so that `lyric restore` propagates
them transitively to consumers. Application developers never need to repeat
native dep entries for libraries they consume.

Discovery uses `lyric search`, which queries the NuGet.org search API filtered
by `tags=lyric-package`. No separate registry site is required for v1.0.

The lock file (`lyric.lock`) pins every resolved package to a version and
SHA-512 checksum. `lyric restore --locked` (the CI flag) refuses to update the
lock file and fails if any hash mismatches, providing supply-chain integrity.

Private registries are supported via `[registry]` in `lyric.toml` and
credentials in `~/.lyric/credentials.toml` or environment variables.

### Alternatives considered

**Bespoke registry.** Building a custom package index and file store (equivalent
to crates.io) would give complete control but requires ongoing infrastructure
maintenance, CDN costs, and security operations. Rejected for v1.0 in favour of
piggy-backing on NuGet.org and GitHub Packages.

**Static JSON index + GitHub Releases.** A minimal "registry" could be a JSON
file committed to a repo with artifacts attached to GitHub Releases. Simpler
than a bespoke registry but still requires a publish workflow and custom resolver
code in the CLI. Rejected in favour of using existing NuGet tooling, which is
already available in the F# bootstrap and requires no new infrastructure.

**Go-style direct git resolution for all packages.** Every dep references a git
URL with a version tag; no registry. Workable in the short term but poor for
discoverability, requires network access for every build, and offers no
checksum-based supply-chain guarantees. Retained as the git-dep escape hatch
(docs/38-workspace.md §3.3) but not the primary registry mechanism.

### Open questions

Q-R-001 (GitHub Packages Maven auth friction), Q-R-002 (Maven Central GPG
setup), Q-R-003 (GitHub Pages discovery site), Q-R-004 (`lyric publish
--workspace` bulk tooling) — see `docs/39-package-registry.md` §10.

---

## D075 — Custom source generator API; `@derive` renamed `@generate`

**Date:** 2026-05-18
**Spec:** `docs/40-source-generators.md`

### Decision

The `@derive` annotation is renamed `@generate` across the language. Built-in
generators use bare single-segment names (`@generate(Json)`, `@generate(Sql)`,
`@generate(Proto)`, `@generate(Equals)`). Custom generators use dotted names that
resolve to source-generator packages (`@generate(Proto.Derive)`,
`@generate(Acme.MyGenerator)`).

The resolver rule is mechanical: no dot → built-in; contains dot → package reference.

### Custom source generator API

Any Lyric package may act as a compile-time code generator by declaring
`kind = "source-generator"` in its `lyric.toml` and exporting a single entry point:

```lyric
import Lyric.GeneratorSdk

pub func generate(req: GeneratorRequest): GeneratorResponse { ... }
```

`Lyric.GeneratorSdk` (new package, `lyric-generator-sdk/`) provides the
`GeneratorRequest`, `GeneratorResponse`, `TypeDescriptor`, `FieldDescriptor`, and
related descriptor types. Generator output is a string of complete Lyric source items
(`lyricSource`) and an optional list of additional imports. The compiler re-parses
this output and injects it into the file before type checking, so all generated code
goes through the full type-checker and mode-checker. No AOT-safety exemptions are
granted to generated items.

### Pipeline position

Custom generators run at the end of the pre-type-check synthesis chain, after the
built-in passes:

```
hoistInlineMethods
  → Stubbable.synthesizeItems
  → Wire.synthesizeItems
  → Generate.synthesizeItems   (replaces JsonDerive.synthesizeItems)
```

The `Generate.synthesizeItems` pass handles both built-in (inline) and custom
(in-process bridge, following the `SelfHostedFmt.fs` pattern) generators.

### Rationale

`@derive(Json)` has proven the model: AOT-compatible, type-checked output, no runtime
reflection. Third-party libraries need the same capability for custom wire formats,
ORM column mappers, OpenAPI schema generation, etc. Maintaining a closed compiler
built-in list for every use case is not sustainable.

Renaming `@derive` → `@generate` eliminates the ambiguity with the `derives` clause
on distinct types (which is a different mechanism: `type UserId = Long derives Hash`).
`@generate` more clearly communicates intent — it runs a generator — whereas `@derive`
sounds like a structural inheritance concept.

Moving "user-defined attributes" from `docs/04-out-of-scope.md` DEFERRED into the
language via this mechanism satisfies the original deferral condition: a concrete use
case (cross-library source generation) has emerged, and the source-generator approach
achieves it without a macro language or runtime reflection.

### Security and trust

Generator packages are opt-in (declared in `lyric.toml` and applied via `@generate`).
Lock-file SHA-512 checksums cover generator packages identically to library
dependencies. Generator output is fully validated by the compiler. Generators cannot
observe the full AST; they receive only the structured `GeneratorRequest` descriptor
for the annotated type.

### Open questions

Q-SG-001 through Q-SG-004 are tracked in `docs/40-source-generators.md` §10.

---

## D076 — Bootstrap F# changes for 24-library build (PR #687)

**Context:** PR #687 compiled all 24 Lyric library packages through the bootstrap
emitter for the first time.  Several changes were required in the F# bootstrap to
unblock those builds.  CLAUDE.md §"F# surface is frozen" prohibits new domain logic
in `bootstrap/src/`; this entry documents each change and its justification so the
set of permitted F# edits is explicit and auditable.

**Changes and justifications:**

| File | Change | Justification |
|------|--------|---------------|
| `Parser.fs` | Accept `var` keyword in record member position | Bootstrap parser must parse valid Lyric source; the self-hosted parser already handles this.  No new semantics — `var` is silently passed through (AST tracking deferred to T6+). |
| `Codegen.fs` | `BCoalesce` (`??`) IL emission | IL-level code generation for an existing Lyric operator that had no emitter branch.  Purely an emitter completeness fix; no new language surface. |
| `Codegen.fs` | `case null` pattern in match | Same: completeness fix for a pattern form already in the language spec.  The self-hosted emitter inherits this from the Lyric-side codegen. |
| `Emitter.fs` | Cross-package enum case registration | Registers imported enum cases so `EnumName.CaseName` can resolve across package boundaries.  No new language semantics; fixes a missing loop in the bootstrap multi-package path. |
| `Emitter.fs` | `@cfg` erasure before import resolution | Correctness fix: feature-gated overloads were reaching the type checker as duplicates.  The erasure step existed; the ordering was wrong. |
| `Checker.fs` | Extern-sig registration in `registerItem`; `externSigToDecl` for cross-package preambles | Infrastructure to thread restored-package type anchors (extern / opaque / record / enum / union) through the type checker when checking cross-package imports.  This has no self-hosted equivalent yet because the self-hosted type checker runs on single compilation units; a follow-up will move this to `typechecker_resolver.l`. |
| `Program.fs` | `--internal-project-build` command (114 lines) | Shim infrastructure required because `lyric build --manifest` in the F# CLI must delegate to the self-hosted CLI for project builds, then receive back the resolved DLL paths over a line-based protocol.  The domain logic lives in `lyric-compiler/lyric/cli.l`; the F# side is a parser for the protocol response (permitted shim infrastructure per CLAUDE.md). |

**Status:** All F# changes in this entry are bootstrap-grade infrastructure.
Domain logic equivalents belong in the self-hosted compiler and will migrate there
as the corresponding self-hosted stages mature (type checker resolver: T5.3+;
parser `var` field AST: T6+).  No further F# domain logic additions are permitted
beyond this set without a new decision-log entry.

---

## D077 — Widen the type checker's `Type` union with refinement (range) bounds (#1482)

**Context:** `Type` (`lyric-compiler/lyric/type_checker/typechecker_types.l`) is
`@stable(since="0.1")`, and per the editing protocol any change to a stable
type requires a decision-log entry.  Band-1 of the self-hosted prod-readiness
epic (#1470, `docs/41` §5.1) identified that `Type` was too coarse to carry
declaration-time refinements to the use site: the resolver discarded the range
bound of an inline refined type (`TRefined → underlying`,
`typechecker_resolver.l`), so a check like inline-range construction validation
had nothing to consult.  This is the FOUNDATION task that unblocks Band-1
follow-ups (TyError typing #1483, alias-as-type, match exhaustiveness) and
Band-4 range-subtype validation.

**Decision:** Add one append-only case to the `Type` union:

```
case TyRefined(underlying: Type, lo: Option[Long], hi: Option[Long], hiInclusive: Bool)
```

- `lo` / `hi` carry the integer-literal endpoints when statically extractable
  (`None` for `MIN` / `MAX` or a non-literal endpoint); `hiInclusive`
  distinguishes `..=` (closed) from `..` (half-open).
- **Refinement is transparent to `typeEquiv`.**  `typeEquiv` unwraps `TyRefined`
  to its underlying representation on both operands before comparing, so a
  refined type is equivalent to its underlying and vice versa.  This is the
  deliberate gate-safety property: widening the union introduces **zero** new
  type-equivalence false positives, which matters because Band-1's terminal task
  (#1488) flips single-file typecheck to fatal.
- The bounds are consumed by exactly one new check in this slice: **T0015**,
  which rejects a binding (`val`/`var`/`let`) whose declared type is an inline
  refined type and whose initialiser is an integer literal outside the bounds.
- `renderType` (and the LSP hover renderer) render the refined form
  (`Int range 0 ..= 9`).

**Scope boundaries (deliberately deferred, not shortcuts):**

- Named distinct range subtypes (`type Age = Int range 0 ..= 150`) still resolve
  to `TyUser`, not `TyRefined`; carrying their bounds onto the named type and
  validating their constructions is **Band-4** work and out of scope here.  The
  T0015 check therefore fires only for *inline* refined annotations.
- The representation tag (alias vs distinct vs opaque) and async (`Future`/
  `Task`) / channel carrier cases named in the #1482 scope are **not** added in
  this slice: an unconsumed union case is itself a half-measure under the
  project's no-stubs standard.  Each downstream consumer (e.g. alias-as-type,
  opaque hiding) adds the case it needs as append-only widening, each backed by
  its own decision-log entry, when it has a check to consume it.  `TyArray`
  already carries `size: Option[Int]`, so the array-size sub-part of #1482 was
  pre-existing.

**Consequence:** `Type` remains `@stable`; future additions stay append-only and
each requires a decision-log entry.  All matches over `Type` in the self-hosted
tree either carry a wildcard arm or were given a `TyRefined` arm in this change.

---

## D078 — Project-aware CLI defaults: bare `lyric` builds, manifest auto-discovery (#1968, #1969, #1970, #1976)

**Context:** The everyday CLI flow required either `cd`-ing to the manifest
directory or passing `--manifest`/a positional source. Bare `lyric` printed
usage and exited non-zero (`lyric-compiler/lyric/cli.l`), and only
`Lyric.Workspace.findWorkspaceRoot` walked the directory tree — and only for a
`[workspace]` root, not an ordinary package manifest. This is the foundational
slice of the ecosystem-DX epic #1968.

**Decision:**

- **Bare `lyric` builds the discovered project.** With no command, the CLI
  discovers the nearest `lyric.toml` by walking up from the current directory
  and dispatches to `lyric build`. Outside a project (no manifest in the tree)
  it prints help and exits non-zero — a usage error, not a silent no-op.
- **`lyric run` is unchanged** and remains the build-and-execute dev loop with
  an explicit source file. The build/run split is deliberate: bare `lyric`
  produces an artifact predictably; execution stays opt-in.
- **Manifest auto-discovery** is a new `Lyric.Discovery.findNearestManifest`
  that returns the nearest `lyric.toml` parsing with a `[package]` section
  (a pure `[workspace]` root is skipped). `lyric build` and `lyric restore`
  use it when given no source/`--manifest`. Explicit `--manifest`/positional
  always wins.
- **Improved UX:** `lyric --help`/`-h`/`help` print the grouped command list
  to stdout and exit 0 (`usageText` is the single source of truth shared with
  the stderr error paths); an unknown command prints a Levenshtein
  "did you mean '…'?" suggestion when within edit distance 2.

This is a user-facing surface change that touches the Q011 CLI freeze
(`docs/36-v1-roadmap.md`); it is additive (no existing invocation changes
meaning) and recorded here per the surface-freeze protocol. AOT release
binaries (`--release`), `lyric init`/`add`, `--watch`, and auto-restore-on-build
are tracked as the remaining children of #1968 and land in their own slices.

**Consequence:** The CLI dispatcher's no-args and unknown-command paths now have
behaviour, not just help. Future command additions must be added to
`knownCommands()` so the suggestion list stays in sync with the dispatcher.

---

## D079 — `lyric build --release`: self-contained Native AOT binaries, with a target seam for GraalVM (#1968, #1975)

**Context:** `lyric build` emitted only a framework-dependent `.dll` run via
`dotnet exec`; there was no command to produce a deployable standalone native
binary. The compiler already AOT-publishes *itself* (`bootstrap/src/Lyric.Cli.Aot`),
so the pipeline is proven — we expose the same capability for user programs.

**Decision:**

- **`lyric build --release <source.l>`** produces a self-contained Native AOT
  executable. Plain `lyric build` is unchanged (fast managed DLL — the inner
  loop); `--release` is the deployable-artifact path. `--rid` overrides the host
  RID (default: MSBuild `$(NETCoreSdkPortableRuntimeIdentifier)`); `-o` overrides
  the output (default: the source stem with no extension).
- **Mechanism** (`Lyric.Release`, `lyric-compiler/lyric/release.l`): build the
  managed DLL, generate a host project (`host.csproj` + a C# `Trampoline.cs`
  into the program's emitted `<package>.Program.main()`) referencing the program
  DLL + `Lyric.Stdlib.dll`, then run `dotnet publish -p:PublishAot=true`. The
  host assembly is named `__lyric_aot_host` — deliberately distinct from any
  user package, because ILC resolves assembly identities case-insensitively and
  a same-name host would shadow the program's entry type. ILC trim/AOT warnings
  are surfaced (`IlcTreatWarningsAsErrors=false`), not swallowed.
- **Target seam:** `union ReleaseTarget { DotnetAot | JvmNativeImage }` with a
  target-agnostic `buildRelease`. `DotnetAot` is implemented; `JvmNativeImage`
  (GraalVM `native-image` over the bundled JAR) is defined but **fails loud**
  (`#1975`) rather than silently producing a managed artifact — honouring the
  no-silent-one-platform rule. Adding GraalVM later fills the `JvmNativeImage`
  arm without touching the dispatcher or the .NET path.
- **Scope this slice:** single-file programs on .NET. **Project-mode `--release`**
  (entry-package detection across a bundle + path-dependency referencing) and the
  JVM path are tracked in #1975; both emit a clear non-zero error today.

**Consequence:** `lyric build` now has two artifact modes — debug DLL (default)
and release native binary (`--release`). This is a user-facing surface addition
touching the Q011 freeze (`docs/36-v1-roadmap.md` §R7.5 / `docs/41` H13, which
move from "planned" to "shipped for single-file/.NET"). Recorded here per the
freeze protocol.
## D080 — Auto-restore on `lyric build` when the lock is missing or stale (#1968, #1971)

**Context:** `lyric build` did not resolve dependencies — a clean checkout (or a
just-edited `[dependencies]` set) required a manual `lyric restore` first, or the
build failed on unresolved deps. `cmdRestore` already did the full job; builds
should trigger it automatically.

**Decision:**

- **`cmdRestore` is split** into argument parsing + a reusable
  `runRestore(mfPath, lockedMode)` that does the resolve-and-lock work. The CLI
  command and the build path share it.
- **Project-mode `lyric build` auto-restores** when the manifest declares
  `[dependencies]` and `lockNeedsRestore` reports the lock missing or out of
  sync. The staleness check is cheap and read-only: `lyric.lock` absent → restore;
  otherwise every declared dependency must be present in the lock (and a registry
  dependency's locked version must match), else restore. It is conservative — any
  lock read/parse failure triggers a fresh restore. The lock is resolved at the
  workspace root when one is found, else beside the manifest (matching
  `runRestore`'s own placement).
- **`--no-restore`** opts out and builds against the lock as-is.
- Single-file builds are unaffected (dependencies live in a project manifest).
  `[nuget]`/`[maven]`-table changes do not trigger auto-restore in this slice (only
  `[dependencies]`); documented, revisit if needed.

**Consequence:** `lyric build` and bare `lyric` "just work" on a fresh checkout
with dependencies. The staleness heuristic favours a redundant restore over a
stale build; `--locked` (on `lyric restore`) remains the strict-verification path
for CI.

---

## D081 — Carry enclosing-function context (`returnTy` / `genericNames`) on the type checker's `Scope` (#1483, #1943)

**Context:** Several value-position expression forms — `EBlock` / `EUnsafe`
brace blocks, `EResult` (`result` in `ensures:`), and the forthcoming branch
unification of `EIf` / `EMatch` — need the enclosing function's declared return
type and type-parameter names in order to type their bodies (a block's
statements are checked via `checkBlock`, which already takes `genericNames` /
`returnTy`; `result` *is* the return type). `inferExpr` did not have that
context, so these forms inferred the universal `TyError` unifier, leaving whole
classes of error unreachable. `inferExpr` has ~34 call sites, so adding a
parameter would ripple widely; the `Scope` it already threads is constructed in
exactly one place.

**Decision:** Add `returnTy: Type` and `genericNames: List[String]` to the
`@stable(since="0.1")` `Scope` record. They are **Scope-level**, set once at
function entry (`newScopeForFunction`, called from `checkFunctionBody`) and left
untouched by frame `push`/`pop`, so a nested block sees the same enclosing
context. `newScope()` (the context-free constructor used outside a function
body) defaults `returnTy` to `TyError` (keeping a stray read lenient) and an
empty generic list. With this, `inferExpr` types `EBlock`/`EUnsafe` via
`checkBlock` and `EResult` as `sc.returnTy`. `checkBlock` is also made
**divergence-aware**: a block whose final statement is `return`/`throw`/`break`/
`continue` has type `Never` (bottom), so an early-exit branch unifies cleanly
once `EIf`/`EMatch` branch typing lands.

**Stability note:** `Scope` is `@stable`; this widens the record with two new
fields. It is an additive, source-compatible change for every in-tree
constructor (the sole construction site is `newScope`/`newScopeForFunction`),
and `Scope` is an internal compiler type, not a published API surface — so the
`@stable` contract (no breaking change to consumers) holds. Logged here per the
`@stable` editing protocol.

**Consequence:** the type-checker infrastructure for value-position block and
branch typing is in place. `EBlock`/`EUnsafe`/`EResult` ship with it;
`EIf`/`EMatch` branch unification (which additionally needs the parser
statement-end fix for `EIf`, #1943, and pattern-variable binding for `EMatch`)
build on the same divergence-aware `checkBlock` in follow-ups.
## D082 — `lyric add` — cargo-style dependency insertion (#1968, #1973)

**Context:** Adding a dependency meant hand-editing the `lyric.toml`
`[dependencies]`/`[nuget]` tables. A cargo-style `add` command is a large
ergonomics win and pairs with auto-restore (D080).

**Decision:**

- **`lyric add <name>[@<version>] [--path <dir>] [--git <url> [--tag|--rev|--branch <ref>]]
  [--nuget] [--manifest <m>] [--no-restore]`** discovers the manifest (like
  `build`/`restore`), inserts or updates a single dependency entry, and runs
  `runRestore` afterward (D080's shared body) unless `--no-restore`.
- **Source forms** map to the TOML shapes `parseManifest` accepts: bare/`@version`
  → registry string (`name = "<v>"`, missing version written as `"*"`); `--path`
  → `{ path = "..." }`; `--git` + optional ref → git inline-table; `--nuget` →
  `[nuget]` table entry.
- **Editing is text-level, not a re-serialize**, to preserve the rest of the file:
  `upsertTomlEntry` replaces an existing key line in place (idempotent re-add),
  appends to the table if present, or appends a new section at EOF, and keeps a
  single trailing newline. The result is re-parsed and the write is **refused**
  if it would not parse — no half-written manifest.
- Conflicting selectors (`--path`/`--git`/`--nuget`/`@version`) are rejected;
  `--tag`/`--rev`/`--branch` require `--git`.

**Deferred:** `--registry <url>` (no per-dependency registry field exists in the
manifest — registry is a global `[registry]` setting), and `lyric remove`. Both
tracked as follow-ups.

**Consequence:** `lyric add Foo@1.2.0 && lyric build` resolves `Foo` with no
manual TOML editing. Path/git/nuget forms round-trip through `parseManifest`.

---

## D083 — `lyric run/build --watch` — rebuild-on-change dev loop (#1968, #1974)

**Context:** No watch loop existed; iterating meant re-running `lyric run`/`build`
by hand. The stdlib exposed neither a file-modified-time getter nor a
synchronous sleep, so a watch loop needed new primitives.

**Decision:**

- **Change detection by content hash, not mtime.** The watch loop fingerprints
  each watched file with `Std.Hash.sha512OfFile` (already cross-target, reused
  from lock integrity) rather than adding a file-metadata/`mtime` primitive.
  This sidesteps the cross-target `DateTime`/`FileTime` conversion mismatch and
  reuses proven infrastructure.
- **One new stdlib primitive: `Std.Time.sleepMillis(ms: Int)`** (synchronous
  thread sleep), backing the poll interval. `.NET` binds
  `System.Threading.Thread.Sleep`; JVM routes through the
  `lyric.stdlib.jvm.TimeHost.sleepMillis` Phase 6 shim (`Thread.sleep((long)ms)`)
  because `java.lang.Thread.sleep` takes a `long` and an `Int` argument would
  mismatch the descriptor. Both kernels declare it; the JVM runtime shim is part
  of the existing Phase 6 host-shim deliverable (the JVM host layer is uniformly
  Phase-6-pending, not a new gap).
- **Scope of watched files:** `run --watch` → the source file; project
  `build --watch` → the manifest + every `[project.packages]` source; single
  `build --watch` → the source. The loop runs the action once, then re-runs on
  any fingerprint change until interrupted.
- **The watch loop runs in the CLI process** (always the .NET AOT host), so the
  feature is fully functional today regardless of the JVM host-shim status; only
  the `sleepMillis` primitive's JVM *runtime* awaits the Phase 6 shim.

**Consequence:** `lyric run --watch app.l` gives an edit-rebuild-rerun loop with
no new file-watch OS binding and no mtime primitive.

---

## D084 — `lyric init` — project scaffolder (#1968, #1972)

**Context:** A newcomer had to hand-write `lyric.toml` and the source layout —
the steepest part of the first-run experience. `lyric init` removes it.

**Decision:**

- **`lyric init [<dir>] [--name <Name>] [--lib] [--force]`** scaffolds a package
  in `<dir>` (default the current directory, created via
  `Std.Directory.createRecursive` if absent): a `lyric.toml`
  (`[package]` + `[project]` + `[project.packages]` + empty `[dependencies]`),
  `src/main.l` (a `func main(): Int` hello-world) or `src/lib.l` with `--lib`,
  and a `.gitignore`.
- **Name derivation:** the package name comes from the directory basename, with a
  lowercase leading letter capitalised to the `UpperCamelCase` convention (so
  `lyric init demo` yields package `Demo`). `--name` overrides it. A candidate
  that is not a valid identifier (e.g. contains `-`) is rejected with a message
  pointing at `--name` rather than emitting a manifest the formatter would reject.
- **Non-destructive:** an existing `lyric.toml` is not overwritten without
  `--force`; a pre-existing `.gitignore` is always left untouched.
- Implemented as a new `Lyric.Init` package (`lyric-compiler/lyric/init.l`)
  dispatched from `cli.l`, and registered in `knownCommands` for did-you-mean.
- The scaffold includes a `[project]` section so the result builds with bare
  `lyric` / `lyric build` immediately, and `lyric run src/main.l` runs it.

**Consequence:** `lyric init demo && cd demo && lyric run src/main.l` works
end-to-end with no hand-editing.

---

## D085 — Band 3 Phase A: synchronous async unwrapping for `@externTarget async` (#2070)

**Context:** Epic #2070 (self-hosted async/await) identified that
`@externTarget async func` functions were a silent miscompile — the BCL method
returns `Task<T>` but the function's declared return type is `T`, and the
emitter was returning the Task object as if it were T.  The original plan
(described in `docs/41-self-hosted-compiler-gap-analysis.md` §Band 3) called
for full `IAsyncStateMachine` synthesis as the first step.

**Decision (Phase A):** Ship a correct, production-quality Phase A that fixes the
silent miscompile without introducing full SM synthesis:

1. **`@externTarget async func f(): T`** — after calling the BCL method (which
   returns `Task<T>`), emit `callvirt Task<T>::get_Result()` (for non-void) or
   `callvirt Task::Wait()` (for `Unit` return) to synchronously unwrap the result.
   The function's declared Lyric return type T is now what's actually on the stack.
2. **User-defined `async func f(): T { body }`** — compile the body normally.
   All inner `await` calls receive T (since inner async funcs all return T
   directly); `EAwait` is a semantic no-op (correct because every async func is
   synchronous in the caller's view).
3. **`EAwait`** — remains a no-op pass-through.  This is now correct: every async
   callee already returns T directly, so `await callResult` = `callResult`.
4. **`IAsyncStateMachine` synthesis** — deferred to Phase B (future PR).
   Phase B will make async funcs return `Task<T>` for C# interop and proper async
   concurrency.

**Rationale for synchronous-first:** The stdlib has no tests that exercise
real-network async (HTTP); all async tests are pinned to synchronous paths or
explicitly excluded.  The synchronous approach:
- Is correct for Lyric-only call chains (no C# interop needed yet).
- Fixes the "silent miscompile" immediately — `@externTarget async` now produces
  valid MSIL where the stack type matches the declared return.
- Keeps all 847 stdlib tests green.
- Does NOT use `Task.Run` blocking (which would be deadlock-prone in sync
  contexts); `get_Result()`/`Wait()` on a Task that has already completed returns
  immediately without blocking.
- Provides the `MLdflda` instruction needed by Phase B (already added).

**Consequence:** `@externTarget async func` no longer silently miscompiles.
`EAwait` is correct for Lyric-to-Lyric async chains.  Phase B (SM synthesis,
`Task<T>` return types, proper concurrency) remains a tracked TODO in epic #2070.

---

## D-N-001 — LLVM integration strategy: emit `.ll` text, shell out to clang

**Status:** ACCEPTED — native backend Phase 1.

**Decision:** The native backend emits textual LLVM IR (`.ll` files) and shells
out to `clang` as a universal driver to compile and link the result. No LLVM
library headers or linkage are required by the Lyric compiler itself.

**Alternatives:**
- Link against `libLLVM` and call the LLVM C API directly.
- Use `llc` and `lld` separately.
- Emit native assembly by hand without LLVM.

**Rationale:**
- `clang` is universally available (macOS ships with Xcode CLI tools; Linux
  needs one `apt install clang`). `llc` and `lld` are NOT bundled with clang.
- Zero runtime dependency on LLVM headers — LLVM version upgrades do not require
  recompiling the Lyric compiler.
- `clang` handles optimization, object emission, linking, ABI, and startup code
  with a single invocation.
- The `.ll` format is stable across LLVM major versions.

Full detail: `native/plan/01-design-decisions.md` §D-N-001.

---

## D-N-002 — Union/tagged-union memory layout: in-place tagged struct

**Status:** ACCEPTED — native backend Phase 1.

**Decision:** Union values are heap-allocated structs with: ARC header (rc +
dtor), a 32-bit discriminant, and an inline payload sized to the largest case.

**Alternatives:**
- Pointer-to-payload (indirect boxing of case data — extra allocation per case).
- Fat pointer with out-of-line storage.

**Rationale:**
- No extra allocation beyond the union itself.
- Discriminant and payload are in the same cache line for the common case.
- Matches Rust `enum`, Swift `enum with associated values`, C tagged union.
- The monomorphizer knows all payload sizes at compile time.
- Stack allocation (escape analysis) is a clean future optimisation (Phase 3).

Full detail: `native/plan/01-design-decisions.md` §D-N-002.

---

## D-N-003 — Panic / exception model: `abort()`, no stack unwinding

**Status:** ACCEPTED — native backend Phase 1.

**Decision:** All runtime panics (contract violations, bounds failures, OOM) call
`lyric_panic_msg()` which writes a diagnostic to stderr then calls `abort()`. No
LLVM landingpads, no DWARF unwind tables, no `defer` in Phase 1.

**Alternatives:**
- LLVM `landingpad` / C++ exception ABI (enables `defer` / structured cleanup).
- `longjmp`-based panic recovery.

**Rationale:**
- Landingpads require DWARF unwind tables in every function (~20% binary size),
  a personality function, and `libunwind`.
- `abort()` is one instruction after the diagnostic write.
- If `defer` is added in Phase 2, cleanup-only landingpads can be added without
  changing the abort architecture — the designs are compatible.

Full detail: `native/plan/01-design-decisions.md` §D-N-003.

---

## D-N-004 — Async / await strategy: LLVM coro.* stackless coroutines (Phase 2)

**Status:** ACCEPTED — mechanism designed in Phase 1; implementation is Phase 2.

**Decision:** `async func` / `await` on the native target use LLVM's built-in
coroutine intrinsics (`llvm.coro.*`). The `CoroSplit` pass synthesises the
ramp / resume / destroy functions. Phase 1 emits a hard error (N0099) for any
`async func` targeting native.

**Alternatives:**
- Green threads / fibers (requires a full runtime stack switcher).
- Hand-synthesised state machine (the MSIL approach) without coro intrinsics.
- POSIX `ucontext` / `setjmp`-based coroutines.

**Rationale:**
- LLVM coro is the most principled approach: the compiler emits a flat function;
  the optimiser does the frame extraction and split.
- No platform-specific stack-switching code.
- Compatible with LLVM's ARC analysis passes in Phase 2.
- The mechanism is fully designed in `native/plan/06-async-design.md`; Phase 2
  agents have no design work to do.

Full detail: `native/plan/01-design-decisions.md` §D-N-004 and
`native/plan/06-async-design.md`.

---

## D-N-005 — ARC cycle-collection policy: NativeWeak only, no background collector

**Status:** ACCEPTED — native backend Phase 1.

**Decision:** `NativeWeak[T]` is the only cycle-breaking primitive. There is no
background cycle detector in Phase 1. A strong reference increments RC;
`NativeWeak[T]` does not. `NativeWeak[T].upgrade()` returns `Option[T]`.

**Alternatives:**
- Tracing cycle detector running periodically (Swift's cycle collector approach).
- Trial deletion (CPython-style reference-counted cycle detection).

**Rationale:**
- A background cycle detector adds latency variability; `NativeWeak` gives
  deterministic performance.
- Static cycle prevention (mode checker detects self-referential strong field
  graphs and requires `NativeWeak`) is a purely additive Phase 2 analysis that
  does not change runtime behaviour.

Full detail: `native/plan/01-design-decisions.md` §D-N-005.

---

## D-N-006 — String representation: RC-managed heap object with inline UTF-8 data

**Status:** ACCEPTED — native backend Phase 1.

**Decision:** `String` values are `%LyricString*` — a heap object carrying an ARC
header, a byte-length, a capacity, and inline UTF-8 data. String literals are
emitted as static constants with `rc = INT32_MAX` (saturated, never freed).

**Alternatives:**
- Small-string optimisation (SSO) — inline strings up to 15 bytes in the pointer
  slot.
- Immutable interned strings (intern pool with de-duplication).
- C-style NUL-terminated strings (no length).

**Rationale:**
- Uniform `%LyricString*` type at every call site; static and heap strings have
  the same layout so `Std.Console.println` works transparently with both.
- SSO adds a branch in every string operation; complexity cost exceeds benefit
  for Phase 1.
- Interning requires a global hash table; not appropriate for general-purpose strings.

Full detail: `native/plan/01-design-decisions.md` §D-N-006 and
`native/plan/03-type-mapping.md` §String.

---

## D-N-007 — FFI syntax: new `extern func name(args): Ret = "symbol"` declaration form

**Status:** ACCEPTED — native backend Phase 1.

**Decision:** A new `extern func name(params): Ret = "symbol"` item form is added
to the parser (`IExternFunc` in the AST), emitted as an LLVM `declare`. This form
is only permitted in `_kernel_native/` files and `@unsafe_ffi`-annotated functions.
The existing `@externTarget` annotation machinery is NOT reused.

**Alternatives:**
- Reuse `@externTarget` (the .NET BCL binding mechanism) with a new attribute value.
- C `#include`-style header import.

**Rationale:**
- `@externTarget` encodes BCL member-qualified names (`System.IO.File.ReadAllText`);
  `extern func` carries a bare C symbol name (`"write"`). The two are orthogonal
  and coexist in the same codebase.
- A dedicated syntax makes it obvious which declarations cross the native ABI
  boundary.

Full detail: `native/plan/01-design-decisions.md` §D-N-007 and
`native/plan/05-ffi-design.md`.

---

## D-N-008 — Platform Phase 1 scope: Linux x86-64 + AArch64, macOS AArch64

**Status:** ACCEPTED — native backend Phase 1.

**Decision:** Phase 1 targets three LLVM triples:
`x86_64-unknown-linux-gnu`, `aarch64-unknown-linux-gnu`, `aarch64-apple-darwin`.
Windows (PE/COFF, Win32 API, MSVC/MinGW toolchain) is deferred to Phase 2.

**Alternatives:**
- Add Windows Phase 1 (requires Win32 API `_kernel_native/` layer and PE/COFF testing).
- Target only x86-64 Linux for Phase 1.

**Rationale:**
- All three Phase 1 targets share the POSIX syscall interface and the clang
  toolchain, minimising the `_kernel_native/` surface.
- CI matrix maps directly to available GitHub Actions runners
  (`ubuntu-latest`, `ubuntu-24.04-arm`, `macos-14`).
- Windows requires a separate `_kernel_native/win32/` layer and different linker
  conventions; the added scope is not justified for Phase 1.

Full detail: `native/plan/01-design-decisions.md` §D-N-008.

---

## D-N-009 — Linking strategy: clang as universal driver

**Status:** ACCEPTED — native backend Phase 1.

**Decision:** The compiler invokes `clang` for linking, passing the emitted `.ll`
file, `lyric_rt.a`, and standard libraries. The `lyric_rt.a` path is resolved
from `<compiler_bin>/../lib/` (installed) or `<repo_root>/lyric-rt/build/` (dev).

**Rationale:** See D-N-001 — this is the same clang-as-driver decision applied to
the link step. No separate `lld` or `ld` invocation is needed.

Full detail: `native/plan/01-design-decisions.md` §D-N-009.

---

## D-N-010 — Generics strategy: full monomorphization via existing `Lyric.Mono`

**Status:** ACCEPTED — native backend Phase 1.

**Decision:** The native backend consumes the already-monomorphized AST produced
by `Lyric.Mono.monoFile`. No new generics work is needed in the codegen layer.
Monomorphized type names follow the existing convention (e.g., `Lyric.Option__Int`).

**Alternatives:**
- Dict-passing (pass type-class dictionaries at runtime, as in Haskell).
- LLVM-level generic instantiation (generate generic IR and let LLVM specialise).

**Rationale:**
- `Lyric.Mono` already runs before MSIL and JVM backends; reusing it for native
  means zero new infrastructure.
- Full monomorphization produces better-optimised code than dict-passing.
- The LLVM backend gets concrete types with no erasure.

Full detail: `native/plan/01-design-decisions.md` §D-N-010.

---

## D-N-011 — ARC runtime intrinsics: external C symbols in `lyric-rt` static library

**Status:** ACCEPTED — native backend Phase 1.

**Decision:** Four runtime functions are `declare`d in LLVM IR and defined in
`lyric-rt.a` (C): `lyric_retain`, `lyric_release`, `lyric_alloc`,
`lyric_panic_msg`. All other operations (strings, collections) are in
Lyric-compiled code.

**Alternatives:**
- Use LLVM's ObjC ARC intrinsics (`@llvm.objc.retain`, etc.).
- Inline the retain/release increment/decrement in the emitter.

**Rationale:**
- ObjC ARC intrinsics are tied to Objective-C runtime metadata and require
  `libobjc` on non-Apple platforms.
- Four well-named external symbols are easy to reason about and audit.
- LLVM function attributes (`nounwind`, `willreturn`, `memory(argmem: readwrite)`)
  allow LLVM to reason about them in a future optimisation pass.

Full detail: `native/plan/01-design-decisions.md` §D-N-011 and
`native/plan/04-arc-design.md`.

---

## D-N-012 — Collection and slice representation

**Status:** ACCEPTED — native backend Phase 1.

**Decision:**
- `slice[T]`: borrowed fat pointer `{ T*, i64 }` — no ARC header, no ownership.
  Lifetime enforced by convention in Phase 1; lifetime annotations in Phase 2.
- `List[T]`: RC heap object `{ header, T* data, i64 len, i64 cap }`.
- `Map[K,V]`: RC heap object with open-addressing hash table (SipHash-2-4, seeded
  from `getrandom` to prevent hash-flooding attacks).

**Alternatives:**
- `slice[T]` as a heap-allocated view object (would require ARC and defeat the
  purpose of a cheap borrowed view).
- `List[T]` as a linked list (poor cache performance for random access).

**Rationale:**
- Fat pointer slices match the Rust `&[T]` / Go slice model and allow zero-copy
  passing to C functions that accept `(ptr, len)` pairs.
- RC heap `List[T]` gives deterministic lifetimes with mutable semantics.
- SipHash-2-4 with a random seed is the standard defence against hash-flooding
  DoS on map keys.

Full detail: `native/plan/01-design-decisions.md` §D-N-012 and
`native/plan/03-type-mapping.md` §slice and §List.

---

## D-N-013 — `@cfg(target = "X")` implemented via pseudo-feature injection

**Status:** ACCEPTED — native backend Phase 1 (N4.6).

**Context:** Stdlib modules such as `Std.Console`, `Std.File`, and `Std.Math`
must import different kernel packages depending on the compilation target:
`_kernel/` for dotnet and jvm, `_kernel_native/` for native. The existing
`@cfg(feature = "X")` erasure pass (D045, `Lyric.Cfg`) already drops
`@cfg`-annotated items whose feature is not in the active set. The question is
how to extend it so `@cfg(target = "native")` works alongside
`@cfg(feature = "myFeature")`.

**Decision:** Extend `CfgErasureInput.activeFeatures` to include the current
target as a pseudo-feature named `"target.<name>"`:

- `--target dotnet` injects `"target.dotnet"` into the active set.
- `--target jvm`    injects `"target.jvm"` into the active set.
- `--target native` injects `"target.native"` into the active set.

The predicate `@cfg(target = "native")` is parsed as a key/value predicate
where `key = "target"` and `value = "native"`, resolving to the pseudo-feature
`"target.native"`. This reuses the existing predicate grammar and erasure loop
without any new AST node or erasure logic.

**Rejected alternative — first-class `target` field in `CfgErasureInput`:**
Adding a separate `target: String` field to `CfgErasureInput` and a separate
`@cfg(target = "X")` predicate branch would require new AST nodes, a new
`Cfg.fs`-equivalent path in `Lyric.Cfg`, and callers that populate the new
field. The pseudo-feature approach is strictly simpler: one injection line in
`CfgErasureInput` construction, zero new predicate grammar, zero changes to
the erasure loop. The downside (pseudo-features mixing with real features in
`activeFeatures`) is acceptable because pseudo-feature names are namespaced
under `"target."` and cannot collide with user-declared `[features]` entries
(which the `F0013` diagnostic already validates against the manifest table).

**Scope:** This change applies to all three targets, not only native. In stdlib
modules that already have a `@cfg(target = "dotnet")` import, the jvm and
native branches must also be annotated (`@cfg(target = "jvm")` /
`@cfg(target = "native")`). All three are required; omitting any branch means
that target sees no import for the aliased identifier, which is a type error.

**Implementation:** `lyric-compiler/lyric/cfg.l` (`Lyric.Cfg`) only.
The F# bootstrap `Cfg.fs` does **not** need updating — the native target is
only reachable through the self-hosted Lyric CLI.

Full detail: `native/plan/07-stdlib-port.md` §target-conditional imports and
`native/plan/08-work-items.md` §N4.6.

---

## D-N-014 — Native backend ships under the `Lyric.Llvm*` package head; kernel selection is loader-based

**Status:** ACCEPTED — native backend Phase 1 (N0–N1 + N4/N6 slices shipped).

**Context:** `native/plan/02-architecture.md` sketched the backend as `Llvm.*`
packages under a new `lyric-compiler/llvm/` directory, mirroring `msil/` and
`jvm/`.  Implementation surfaced two bootstrap constraints the plan predates:

1. **Every stage-0 seed must resolve the backend's packages**, because
   `Lyric.Emitter` imports the native bridge and is in the `Lyric.Cli`
   closure that stage 1 compiles.  The frozen F# mint seed resolves only the
   hardcoded heads `Std`/`Lyric`/`Msil`/`Jvm` (`Emitter.fs:isBuiltinHead`),
   and the released self-hosted seed's `isCompilerPackage` predates `Llvm.`
   too.  A new `Llvm` head is unbootstrappable until a release carrying it
   ships — a circular dependency.
2. The plan's `@cfg(target = ...)`-gated kernel **imports** assume imports
   are annotatable; `ImportDecl` carries no annotations, and the shipped
   mechanism for target-specific kernels is the loader-preference model
   (`_kernel_jvm/<basename>` over `_kernel/<basename>`, docs/44 J6 M-10).

**Decision:**

- The backend's packages are `Lyric.LlvmTypes` / `Lyric.LlvmIr` /
  `Lyric.LlvmCodegen` / `Lyric.LlvmLowering` / `Lyric.LlvmBridge`, at
  `lyric-compiler/lyric/llvm_*.l`.  The `Lyric` head resolves in every seed
  generation, so the backend bootstraps with zero build-system gating (the
  plan's `INCLUDE_LLVM_BRIDGE` flag is not needed and was not implemented).
- Native kernel selection follows the JVM precedent: `_kernel_native/<x>.l`
  declares the SAME package as `_kernel/<x>.l` (e.g. `Std.ConsoleHost`) and
  the native source loader (`Lyric.Emitter.findStdlibSourcesNative`) prefers
  it by basename.  `@cfg(target = "X")` (D-N-013) still ships for gating
  ITEMS; it is simply not the kernel-import selection mechanism.
- Public entry points carry a `Native` suffix (`codegenNativePackage`,
  `codegenNativeBundle`, `lowerNativePackage`): the restored-bundle symbol
  resolver matches bare names last-registered-wins, so reusing the MSIL/JVM
  entry-point names (`codegenPackage`, `lowerPackage`) mis-resolves when the
  compiler bundle is linked.

**Consequence:** `native/plan/*` file paths and package names are read with
this mapping in mind; the plan documents remain the design source for
everything else (IR shape, ARC model, FFI, phasing).

---

### D086 — `result` is contextual: an in-scope `result` binding shadows the contract return-value keyword (#1488, Band-1 of #1470)

**Context.** `result` is a hard keyword (§1.3): the lexer always tokenises it as
`KwResult` and the parser produces an `EResult` node in expression position.  Its
only language-level meaning is the *return-value reference* inside an `ensures:`
clause (grammar §9, `ResultExpr = 'result'` — "only inside ensures clauses").
However, the pattern/binding parser also accepts `KwResult` in binding position,
so `val result = …` / a parameter named `result` is a legal local.  The MSIL and
JVM codegen have always resolved such a read against the function's `result`
*slot* first (`codegen.l:2833` — "`result` is a contextual keyword… the only
remaining case is a user-declared local"), falling back to the contract
return-value temp only when no binding exists.  The self-hosted **type checker**
did not match this: `EResult` typed unconditionally as the enclosing function's
return type, so a local `result` whose value type differed from the return type
was mis-typed.  Bodies using the common `var result = …; … ; result` accumulator
idiom only type-checked because `result`'s type *coincidentally equalled* the
return type; a `Unit`-returning function binding `result : String` produced a
spurious `T0032`/`T0060`.  This blocked the #1488 single-file-fatal gate, since
several stdlib tests (`environment_tests`, `path_tests`, …) use `result` as an
ordinary local.

**Decision.** `result` resolves as a **contextual keyword**: a reference resolves
to an in-scope binding named `result` (most-recent-first) before falling back to
the contract return-value reference.  The type checker now mirrors codegen
(`case EResult -> scopeTryFind(sc, "result")` then `returnTy`).  Inside an
`ensures:` clause — where no user `result` binding is in scope — the fallback
still yields the return type, so contract semantics are unchanged.  This is a
clarification of existing behaviour (codegen already did this), not a new
language rule: `result` remains a hard keyword, but its binding-position use and
in-scope-shadow resolution are now specified.  `docs/01` §1.3 and the grammar
gain a note to this effect.

---
## D-N-015 — Native `slice[T]` shares the RC'd `LyricList` representation (revises the D-N-012 borrowed fat pointer)

**Date:** 2026-07-03
**Status:** ACCEPTED (revises the `slice[T]` half of D-N-012)

**Decision.** On `--target native`, `slice[T]` lowers to the same RC'd
`LyricList` kernel representation as `List[T]`, immutable by
construction.  The type checker owns the mutability and spelling
distinctions (`.length` vs `.count`, no `add`/`set` on slices); the
native codegen reuses the list paths wholesale for `for`, indexing,
`.length`, and the `toArray()` snapshot (`lyric_list_copy`, which is
also the `slice → List` conversion).

**Why the borrowed fat pointer was dropped.** D-N-012 specified
`slice[T]` as a borrowed `{ptr, len}` pair.  That representation is
only memory-safe when every slice's backing store provably outlives
it, which the language cannot check natively today — and the stdlib
immediately violates it: `Std.File.readBytesOrPanic` RETURNS a slice
up the stack, so the buffer must own itself.  An RC'd representation
is safe under the existing ARC rules (retain on bind, release at scope
exit, container-owned elements) with zero new runtime or codegen
machinery.  The borrowed pair remains available as a future
optimisation once the mode checker can bound slice lifetimes.

**Costs accepted.**
- `slice[Byte]` stores one byte per 64-bit slot (the single list
  layout), an 8x width penalty on byte buffers; a packed byte-array
  representation is a follow-up optimisation.
- `List[T]` and `slice[T]` are indistinguishable at the NType level,
  so the native backend accepts `.count` on slices and `.length` on
  lists (a harmless superset — the checker rejects them in checked
  contexts).

**Kernel protocol note.** Ref-container results cross the C boundary
by RETURN VALUE plus an `Int` ok-flag out-param
(`lyric_file_read_bytes`, `lyric_dir_list2`), never by container
out-param: overwriting a `var xs = newList()` slot from C would leak
the initialiser (unlike the immortal `""` used by the string seams).

**Related:** D-N-012, D-N-014, `native/plan/03-type-mapping.md`,
issue #4752.


## D-N-016 — Native interface values are a heap-boxed fat pointer (revises the by-value fat pointer of 03-type-mapping.md / 04-arc-design.md Rule 8)

**Date:** 2026-07-03
**Status:** ACCEPTED (N3.2; revises the interface-dispatch representation)

**Decision.** On `--target native`, an interface value lowers to a
**heap-boxed** fat pointer — an ordinary RC'd object
`__iface.<m> = { i32 rc, i8* dtor, i8* obj, %__ifacevt.<m>* vtbl }` —
rather than the by-value `{ i8* obj, vtable* }` aggregate specified in
`native/plan/03-type-mapping.md` §"Interface dispatch" and
`04-arc-design.md` Rule 8.  The `obj` slot holds the (type-erased)
implementing object; a per-interface destructor releases it.  Each
interface has a vtable struct of one `i8*` slot per method; each
`impl I for R` emits an `internal constant` vtable of `bitcast`ed
concrete-method pointers.  Upcast (record → interface) boxes the object
and retains it into `obj`; dispatch loads `obj` + the vtable pointer,
indexes the method slot, `bitcast`s the raw pointer to the method's
function type, and calls with `obj` as arg 0.

**Why boxed instead of by-value.** The native IR layer (`llvm_ir.l`)
has **no** `insertvalue`/`extractvalue` and no by-value-aggregate call/
return ABI — the entire value model is pointer-centric (records and
closures are heap `NPtr(NStruct)` with an ARC header).  A by-value fat
pointer would require a large new aggregate surface across `coerceTo`,
call-argument lowering, returns, and locals.  Heap-boxing makes ARC
"just work": the box is a normal ref (standard retain on copy, release
on drop via the existing owned-temp/scope machinery), and its
destructor releases the erased `obj` — Rule 8's retain/release semantics
fall out of Rule 7 (destructor composition) with zero special-casing.

**Costs accepted.**
- One extra heap allocation per upcast.  Phase-1 ARC is "correct, not
  optimal" (no retain/release elision), so this is consistent with the
  rest of the backend; a by-value representation remains a future
  optimisation once an aggregate ABI exists.
- The `obj` slot is `i8*` (type-erased), so the box carries a bespoke
  destructor (releases `obj`) rather than reusing `synthRecordDtor`
  (which only releases `NPtr(NStruct)` ref fields, not an `i8*`).

**Scope shipped (N3.2 first slice).** Non-generic interfaces with
non-generic, non-async body-less methods (`IMSig`); `impl I for R` for a
plain record `R`; implicit upcast at argument / return / binding / field
/ match-arm positions (through the single `coerceTo` chokepoint);
interface-typed method dispatch; ARC verified leak-/double-free-clean
under AddressSanitizer (`llvm_self_test_n3.l`).

**Deferred (tracked).** Generic interfaces and generic impl methods
(need `Lyric.Mono` interaction), interface default methods (`IMFunc`),
associated types (`IMAssoc`), `Self`-returning methods, multiple
interface inheritance, async interface methods (Phase 2), `impl` for
non-record targets, and direct impl-method calls on a concrete
(non-interface-typed) receiver.

**Related:** D-N-014, `native/plan/03-type-mapping.md`,
`native/plan/04-arc-design.md` Rule 8, `native/plan/08-work-items.md`
N3.2.


## D-N-017 — Native protected types: heap-buffer mutex field + lock/unlock wrapper/inner split (revises the "inline slot" phrasing of `native/plan`)

**Date:** 2026-07-03
**Status:** ACCEPTED (N3.4; two representation divergences from the plan's literal phrasing)

**Decision.** On `--target native`, a `protected type` lowers to the same
record-shaped heap object as a plain record
(`{ i32 rc, i8* dtor, ...user fields }`), plus one trailing
`__mutex: i8*` field, with two divergences from a literal reading of
`native/plan`:

1. **The mutex is a heap-allocated buffer pointed to by the field, not an
   inline slot.** `lyric_mutex_size()` is a runtime C call (the
   `pthread_mutex_t` layout is platform-dependent); the self-hosted
   compiler runs hosted on .NET/JVM and cannot invoke the *target*
   runtime's `lyric_mutex_size()` at codegen time, and LLVM struct types
   are fixed-size — there is no way to reserve "however many bytes
   `lyric_mutex_size()` returns" as an inline struct field. Construction
   allocates the buffer at runtime (`lyric_mutex_size` → `lyric_alloc` →
   `lyric_mutex_init`) and stores the pointer in `__mutex`; the
   destructor calls `lyric_mutex_destroy` then `lyric_free` (not
   `lyric_release` — the buffer is a raw `lyric_alloc`, not an ARC
   object with a header). This still honours the plan's underlying
   intent ("do not hardcode a struct-layout table for `pthread_mutex_t`
   sizes across platforms") even though it diverges from the plan's
   literal "inline slot" phrasing.
2. **Every `entry` and `func` member lowers to two functions**, not one.
   The language reference (§7.5) makes both forms mutually exclusive (an
   Ada-style monitor); MSIL gets this for `entry` almost for free
   (`Monitor.Enter(this)` / try/finally) and JVM's production path has no
   locking at all (tracked gap, #855/#1833) — native has no monitor
   primitive and, more specifically, its statement lowering emits
   scattered `NRet`/`NRetVoid` at every return site with no unified
   epilogue (no try/finally region), so a single lock/unlock pair cannot
   simply bracket the original body. Each member becomes:
   - an **inner** function (`<Type>.<method>.__inner`): the member body
     with an implicit `self: in <ProtectedType>` receiver injected and
     bare field references rewritten to `self.field` (mirroring the MSIL
     emitter's `desugarProtectedFuncBody`), lowered through the ordinary
     `FunctionDecl` → `NFunc` pipeline exactly like a record/impl method.
   - a hand-built **wrapper** `NFunc` (`<Type>.<method>`): GEP+load the
     mutex field, `lyric_mutex_lock`, call the inner function, call
     `lyric_mutex_unlock` and forward its return value. UFCS call sites
     (`x.increment()`) resolve to the wrapper — its `NFuncSig` is
     registered directly into the module's call registry (`ctx.sigs`),
     bypassing the normal `buildSigs` scan, since the wrapper is
     hand-built and never exists as parsed Lyric source.
   Unlike MSIL (which only locks `entry`, a pre-existing spec gap), both
   `entry` and `func` get the wrapper — matching the language reference.

**Why the type resolves like a record with zero extra machinery.**
`ctx.recordDefs` is the single lookup `typeToN` / field access /
construction consult regardless of whether the entry came from a record
or a protected type, so registering the protected type's layout there
(with `ctx.protectedRecNames` marking which entries need mutex-aware
construction/destruction) makes `self: in ProtectedType` resolve, GEP,
and construct exactly like a record receiver with no new type-resolution
surface.

**Scope shipped (N3.4 first slice).** Non-generic protected types;
`var`/`let`/immutable fields (`PMField`); `entry` and `func` members
(non-generic, non-async funcs); field-args and no-arg (all-defaults)
construction; ARC-correct destruction (ref-typed user fields released,
mutex buffer destroyed and freed) verified leak-/double-free-clean under
AddressSanitizer (`llvm_self_test_n34.l`).

**Deferred (tracked).** `when:` barrier re-evaluation (needs
`pthread_cond_t` — not implemented on MSIL either), invariant re-check
after each operation (contract machinery), generic protected types,
read/write concurrency distinction (language reference explicitly leaves
this an open question), and the same same-package same-name-same-arity
UFCS collision risk that already exists for record/impl methods (a
protected type's wrapper is registered the same way). **Panic-while-locked:**
a panicking inner function leaves the mutex in a locked state (the
wrapper's `lyric_mutex_unlock` never runs) — harmless today because a
native panic aborts the whole process (D-N-003), but must be resolved
before `when:` barrier / `pthread_cond_wait` support is added (a panicking
entry would otherwise leave condition waiters blocked forever ahead of the
abort).

**Related:** `native/plan/08-work-items.md` N3.4,
`docs/01-language-reference.md` §7.5, D-N-016 (the same "no by-value
aggregate ABI" constraint that forced interfaces to heap-box also shapes
the mutex-as-pointer choice here).


## D-N-018 — `lyric test --target native` runs each test straight through, with no per-test try/catch isolation

**Date:** 2026-07-04
**Status:** ACCEPTED (N7.2; single-file test execution on the native backend)

**Decision.** `lyric test <source.l> --target native` compiles the
synthesised test program through `Emitter.emitNative` (the same entry
point `lyric build --target native` uses) and runs the produced binary
directly. The synthesised `main()` normally isolates each test in
`try { … } catch Bug as e { … }` (`Lyric.TestSynth.synthesizeMain`) so one
failing assertion reports `not ok` and the suite continues; native has no
try/catch at all (D-N-003: no unwinding, `panic` aborts the process), so
`TestSynth.synthesizeNative` (a new, non-`@stable` entry point alongside
the existing `synthesize`) emits a straight-through call sequence instead:
each test calls its function directly, and a passing test's `ok N - title`
line prints before moving to the next. If an assertion fails, the whole
process `panic`s and aborts immediately — no `not ok` line, no summary,
just a nonzero/abort exit code. This is not a workaround; it is the same
"panics abort" model every other native program already has (D-N-003),
applied honestly to test execution rather than papered over.

**Two supporting fixes needed along the way, both real native-codegen
gaps rather than test-runner-specific hacks:**

1. The type checker's prelude admits a bare `println(s)` / `toString(x)`
   spelling (`typechecker_checker.l`'s builtin-name list) that the dotnet/
   jvm emitters special-case but native's `llvm_codegen.l` never did.
   `Std.Testing.assertEqualInt`/`assertEqualLong` use the bare
   `toString(x)` form internally, so it was a **stdlib-blocking gap**, not
   just a test-synthesis one: any native program calling those assertion
   helpers would fail to compile with "cannot resolve call target
   'toString/1'" before this. `lowerConstructCall` (`lowerCall`'s fallback
   once the direct-name and UFCS resolution paths miss) now special-cases
   bare `toString(x)`/1-arg, delegating to the same `lowerScalarMethodCall`
   the `.toString()` method form already uses.
2. Bare `println(s)` has no native equivalent at all (unlike `toString`,
   for which a real backing implementation already existed) — native's
   synthesised test program instead imports and calls the already
   native-compilable `Std.Console.println` (N4.4/N5.1's console kernel),
   injecting `import Std.Console as Console` into the synthesised source
   header when `nativeMode` is set.

**Scope shipped.** Single-file `@test_module` compilation and execution
via `--target native`; `--filter` and normal TAP output on an all-passing
suite; a nonzero/abort exit on any failing assertion. Manifest
(multi-package) test suites are rejected with a diagnostic, mirroring
`lyric build --target native`'s existing single-file-only restriction — no
new work was done to lift that restriction for testing specifically.

**Deferred (tracked).** Per-test isolation for native (would need either
real unwinding support — a Phase 2 concern, contradicting D-N-003's
"panics abort" design — or a per-test-subprocess re-architecture of the
test runner); `--triple`/`--opt` CLI flags on `lyric test` (native build
defaults are used unconditionally, matching the no-manifest case of
`lyric build --target native`).

**Related:** D-N-003 (no unwinding), `native/plan/08-work-items.md` §N7.2,
`docs/01-language-reference.md` §"lyric test", `docs/24-test-runner-plan.md`.

## D-N-019 — Native `async func`/`await` Phase 2 first slice: synchronous `Task[T]` wrapper, not LLVM coroutines; generators, cancellation, and `spawn`/`scope` separately tracked (revises `06-async-design.md`'s coroutine mechanism for the no-`spawn` subset)

**Date:** 2026-07-04
**Status:** ACCEPTED (scope AND mechanism decision for the first native async slice)

**Context — scope.** `native/plan/06-async-design.md` (D-N-004) specifies
`Task[T]`, `await` lowering via LLVM `llvm.coro.*` intrinsics, and a
single-threaded cooperative scheduler, stating it "fully specifies the
mechanism so Phase 2 agents have no design work to do." Re-reading
`docs/01-language-reference.md` §7 while starting this slice surfaced
that the *full* async surface for dotnet/jvm is materially larger than
that design doc covers:

- §7.2 **async generators** (`yield` inside `async func`) — two lowering
  strategies (eager-producer, async-iterator) on MSIL/JVM; the
  async-iterator strategy (body has both `yield` and `await`) is **not
  implemented even on the mature MSIL backend** (tracked upstream as
  issue #1490 — the language reference documents it as a compile error
  today). Native therefore cannot be expected to exceed dotnet/jvm parity
  here.
- §7.3 **implicit cancellation tokens** — every `async func` gets a
  compiler-threaded `cancellation` parameter, cooperatively checked.
  Confirmed via `grep` that the self-hosted type checker
  (`type_checker/*.l`) has no `cancellation`/`CancellationToken` handling
  at all — this is purely an MSIL-emitter-level synthesis, not a
  front-end/semantic requirement, so its absence on native does not block
  basic `async`/`await` correctness.
- §7.4 **`spawn` expr / `scope { }` structured concurrency** — concurrent
  awaits with structured cancellation/error propagation. Not mentioned in
  `native/plan/06-async-design.md` at all.

**Context — mechanism.** Before writing any codegen, the coroutine
lowering pipeline itself was hand-verified end-to-end with `clang` 18
(a minimal hand-written `.ll` coroutine — `llvm.coro.id`/`coro.begin`/
`coro.suspend`/`coro.end` with a `presplitcoroutine` function attribute
and correct final-suspend handling — compiled and ran correctly via
plain `clang file.ll -o binary` at both `-O0` and `-O2`; the `coro-early`
→ `cgscc(coro-split)` → `coro-cleanup` lowering runs automatically, no
separate `opt` invocation needed in the `Llvm.Bridge` pipeline). That
confirmed the mechanism *works*, but designing the codegen shape on top
of it surfaced a more important fact: **`spawn`/`scope` is the only
construct in Lyric's async model that creates genuine concurrent
progress** (two tasks making progress independently of each other).
Every other async/await interaction — a chain of `await`s, `await`
inside a loop or branch, nested awaits — is, by construction, sequential
composition: when execution reaches `await task`, nothing else in the
program is running concurrently with `task`, so `task` can only ever be
"not yet complete" if it has not been driven at all yet, not because
something else is mid-flight on another logical thread of control.
With `spawn`/`scope` excluded from this slice (per the scope decision
above), **a genuinely-suspending coroutine is never observably different
from a synchronous call that runs the async body to completion and
returns an already-completed `Task[T]`** — no Lyric program expressible
in this slice's surface can tell the difference. Building the full LLVM
coroutine codegen path (frame spilling across arbitrary control flow,
ARC-across-suspend retention, a ready-queue/wait-queue scheduler) for a
property no reachable program can observe is exactly the kind of
speculative complexity CLAUDE.md's production-readiness standard warns
against ("don't design for hypothetical future requirements").

**Decision — further simplified after checking whether `Task[T]` is a
real type anywhere in the self-hosted front end.** It is not: `grep`
across `type_checker/*.l` and `lyric-stdlib/std/*.l` finds no
resolvable `Task` type at all. `ResolvedSignature.returnTy` for an
`async func` is the plain declared type `T` (never wrapped), and
`EAwait(inner)`'s inferred type is simply `inner`'s type — the front end
never materialises a boxed/wrapped value for "an async call not yet
awaited." The parser also does not restrict `await` to async-function
bodies (`parser_exprs.l`'s `KwAwait` arm parses `await <postfix-expr>` in
any expression position). This matches how MSIL codegen already treats
*every* call site of an async-signatured function as needing an
immediate unwrap — `await` or not — via a "blocking shim
(GetAwaiter+GetResult)" when the call is not itself inside another
async state machine (confirmed via `msil/codegen.l`'s comments at the
`EAwait` handler). Given `spawn`/`scope` (the only construct able to
produce an *unawaited*, held-for-later async value) is out of scope,
there is categorically no Lyric program in this slice's surface that can
observe an async call's result as anything other than a plain `T` value
available immediately at the call site.

**Therefore:** this slice compiles a non-generator `async func` through
the **exact same codegen path as a plain `func`** — no `Task[T]` wrapper
type, no boxing/unboxing, no runtime changes at all. `EAwait(inner)`
lowers as a pure pass-through: `lowerExpr(ctx, insns, inner)`. This
supersedes the "synchronous `Task[T]` heap-box wrapper" design
originally drafted in this entry — that box would have been constructed
and immediately destructed within the same call expression, observable
by nothing, i.e. dead complexity fully eliminated rather than shipped.

`lyric-rt` needs zero new code for this slice (no scheduler, no task
struct — none of `06-async-design.md`'s A-1 API). The only compiler
change is: stop rejecting `fn.isAsync and not isGenerator` in
`Llvm.Codegen.codegenFunc` (route it to the same path as a plain
function) and give `EAwait` a lowering case.

**Explicitly deferred, each with its own tracked follow-up and a clear
compile-time diagnostic (not a silent gap) rather than bundled into this
slice:**
- Async generators (`yield` inside `async func`) — a dedicated
  diagnostic distinct from plain unsupported-async, so a user sees
  "generators aren't supported yet" rather than "async isn't supported
  at all" once plain async ships.
- The implicit `cancellation` parameter / `checkOrThrow()` cooperative
  cancellation.
- `spawn` / `scope { }` structured concurrency — **and, when that lands,
  a real `Task[T]` representation plus real LLVM-coroutine suspension
  become necessary** (this is the point at which an async call's result
  can be held unawaited and two tasks can genuinely progress
  independently). The de-risking work already done in an earlier draft
  of this entry (a hand-verified `llvm.coro.id`/`coro.begin`/
  `coro.suspend`/`coro.end` `.ll` round-trip via plain `clang file.ll -o
  binary` at every `-O` level, no separate `opt` invocation needed once a
  function carries the `presplitcoroutine` attribute) is not wasted — it
  is exactly the mechanism that follow-up will need, and is preserved
  here for that future work: `coro-early` → `cgscc(coro-split)` →
  `coro-cleanup`, with a `final`-marked `llvm.coro.suspend(none, true)`
  at the natural-completion point so the frame's resume-fn-ptr slot is
  correctly nulled before the caller's `llvm.coro.done` check, and the
  frame only freed via an explicit `llvm.coro.destroy` (freeing eagerly
  inside `resume()` itself — without a final suspend first — leaves the
  caller holding a dangling handle, the bug the verification round hit
  and fixed before concluding the mechanism itself was sound).

**Related:** D-N-004, `native/plan/06-async-design.md`,
`docs/01-language-reference.md` §7, upstream #1490 (async-iterator
generators, MSIL).

## D-N-020 — Native `defer`: per-scope deferred-block stack, mirroring the existing ARC scope-exit mechanism (no try/finally to lean on)

**Date:** 2026-07-04
**Status:** ACCEPTED (P2.D1)

**Context.** `defer { D }` runs `D` at scope exit on every path — normal
fall-off, `return`, `break`/`continue` — with multiple defers in the same
scope running in reverse declaration order (grammar: "runs on scope
exit, success or failure"; D-N-003 narrows "failure" to mean a caught
exception on dotnet/jvm, since native panics abort rather than unwind —
see below). MSIL and JVM both lower this by rewriting the statements
following a `defer` as `try { rest } finally { D }`
(`lowerStmtsFromMsil`/JVM equivalent): the CLR/JVM's own exception
machinery guarantees `finally` runs on every exit from `rest`, including
nested `return`/`break`/`continue`, via `leave`/`goto`-based unwind.
Native has no try/finally at all (`STry` already panics: "not supported
for --target native, D-N-003: no unwinding"), so this mechanism cannot
be reused.

**Decision.** Model `defer` on native by extending the ARC codegen's
*existing* scope-exit mechanism rather than inventing a new one. The ARC
pass already tracks, per lexical scope, the ref-typed locals owned by
that scope (`Ctx.scopeRefs`, a stack — one list per nested block), and
already re-runs the release logic at every exit from a scope:
`releaseAllForReturn` (walks every open scope) and `releaseForLoopExit`
(walks scopes down to the loop floor), both called from `SReturn`/
`SBreak`/`SContinue`, plus the normal `popVarScope` call at fall-off.
`defer` adds a parallel stack, `Ctx.deferStack` — one list of pending
`Block`s per lexical scope, pushed/popped in lockstep with `scopeRefs`
(same two call sites: `pushVarScope`/`popVarScope`) — and a `SDefer(body)`
statement just appends `body` to the innermost scope's list instead of
lowering it inline. A new `runDeferredScopeAt(ctx, insns, idx)` lowers a
scope's pending blocks in reverse order (via the ordinary
`lowerBlockStmts`, so a deferred block gets full recursive support —
its own locals, its own nested defers, ARC-managed captures) and is
called at every one of the three existing scope-exit sites, *before*
that scope's ARC releases run (so a deferred block can still read the
scope's own locals). No new IR shape, no new runtime support — this
reuses the exact stack discipline already proven correct for ARC, just
carrying a second per-scope payload.

Because every existing call site funnels through the two central
functions (`pushVarScope`/`popVarScope`) and the two release helpers,
covering `defer` required touching only those four functions plus the
`SDefer` case itself — not each of the ~13 individual scope-opening call
sites.

**D-N-003 interaction (a real gap, not an oversight).** A `defer`
registered before a `panic` does **not** run on native: `panic` calls
`abort()` immediately, with no scope-exit event of any kind to trigger
the deferred-block walk (dotnet/jvm's `finally`-based lowering runs
during exception unwinding, which native categorically does not have).
This is the same "panics abort, no unwinding" model every other native
construct already carries (D-N-018 applied the identical reasoning to
`lyric test --target native`'s lack of per-test isolation); it is
verified directly in the self-test (a program whose deferred block would
print a marker if it ran, asserting the marker never appears in stdout
and the process exits nonzero) rather than left as an unverified claim.

**No front-end restriction added for `return`/`break`/`continue` inside
a `defer` body.** The CLR hard-rejects a `ret`/branch escaping a
`finally` handler at the verifier level, but neither the self-hosted
type checker nor the MSIL/JVM backends carry an equivalent check
(confirmed via `grep`) — so native intentionally matches that same
unchecked status quo rather than introducing a stricter, native-only
restriction the other targets don't have. Untested/unspecified on all
three targets alike.

**Verification.** New `llvm_self_test_defer.l` (8 cases: reverse
declaration order on fall-off, early return, fall-through, break,
continue, a value-producing if-branch, an ASan-clean String-capture
case, and the panic-bypasses-defer negative case) — 8/8 passing, using
the same `Lyric.LlvmBridge.compileToNativeWithFlags` full-bridge harness
`llvm_stdlib_self_test.l` uses (needed so `Std.Console.println` resolves
for the stdout-observation tests — process exit codes truncate to 8
bits on POSIX, so packing multi-fact observations into an exit code is
a trap for values over 255; several of this slice's early test
iterations hit exactly that trap before switching to stdout assertions).
Verified end-to-end via `lyric build --target native` directly, and via
`make ilverify` (0 IL-validity errors across 110 DLLs, no self-hosted
regression) and the full existing native self-test suite (no
regressions).

**Related:** D-N-003, D-N-018, D-N-019 (the parallel "extend the
existing scope-exit mechanism rather than invent a new one" reasoning),
`native/plan/08-work-items.md`, `docs/01-language-reference.md` (defer
semantics), `lyric-compiler/lyric/defer_self_test.l` (the dotnet/jvm
reference test this ports the non-panic cases of).

## D-N-021 — Native `spawn`/`scope`: passthrough parity with MSIL's own lowering; real coroutine suspension gated on an async *leaf primitive*, refining D-N-019's "spawn/scope is the trigger" claim

**Date:** 2026-07-04
**Status:** ACCEPTED (the `spawn`/`scope` slice D-N-019 deferred)

**Context — what the reference backend actually does.** D-N-019 deferred
`spawn`/`scope` as "the point at which real LLVM-coroutine suspension
becomes necessary", on the model that `spawn` is the one construct that
lets two tasks progress independently. Starting this slice, the first
step was reading MSIL's implementation (code as source of truth, the
docs/44 discipline), and it reframes the problem:

- MSIL's `ESpawn(inner)` lowering **is a pure passthrough** —
  `lowerExprMsil(cctx, fctx, insns, inner)`, nothing else
  (`msil/codegen.l`). Inside an async state machine, `val x = spawn
  f()` binds the un-awaited `Task<T>` (the `spawnNms`/`spawnTys`
  tracking) so a later `await x` does the GetAwaiter/GetResult dance —
  but the *concurrency* comes entirely from the .NET runtime's hot-task
  model underneath, not from anything the Lyric emitter does.
- MSIL's `SScope(_, body)` lowers as a **plain block** — none of §7.4's
  cancellation, failure-aggregation, or join machinery exists in the
  emitter today.
- A .NET `Task<T>` only ever *remains incomplete* (the precondition for
  observable concurrent progress) if its body awaits a genuinely
  asynchronous leaf operation — `Task.Delay`, socket/file I/O
  completions, a cross-thread signal. An async method that never
  suspends on an incomplete awaitable runs synchronously to completion
  at the call site and hands back an already-completed task.

**The refined insight.** Native's stdlib surface has **no async leaf
primitive at all**: every `_kernel_native/` operation (file I/O, time,
sleep, process) is synchronous, and there is no timer/io-completion
kernel. Therefore .NET's own semantics, *restricted to the programs
expressible on the native surface*, also degenerate to strictly
sequential execution — every spawned call completes at the spawn site
because nothing it transitively awaits can ever be incomplete. A
passthrough `spawn` on native is consequently **observationally
equivalent to the reference behavior for every compilable program**,
not a weaker approximation of it. The real gate for LLVM-coroutine
suspension is not `spawn`/`scope` syntax (this entry ships that) but
the first **async leaf primitive** (an async sleep/timer kernel is the
canonical minimal one, then async I/O) — that is the follow-up at which
D-N-019's preserved coroutine mechanism, the A-1 scheduler API, and
ARC-across-suspend all become load-bearing. This refines (does not
reverse) D-N-019's deferral note.

**Decision.** Ship `spawn`/`scope` as the same passthrough model:

- `ESpawn(inner)` lowers as `lowerExpr(ctx, insns, inner)` — identical
  in shape to MSIL's lowering and to native's own `EAwait` (D-N-019).
  The spawned call runs to completion at the spawn site; the binding
  holds its result; a later `await x` (a passthrough on a plain local)
  reads it.
- `SScope(_, body)` lowers via `lowerBlockStmts` — a real lexical scope
  on native (scope-local ARC releases and `defer` blocks run at scope
  exit per D-N-020), which is MSIL's plain-block treatment plus
  native's existing scope discipline, not less.
- §7.4's guarantees hold degenerately and honestly: every spawned task
  completes before scope exit (it completed at the spawn site); a
  failing task "cancels" siblings by aborting the process (D-N-003 —
  the same panics-abort model as everything else on native); no task
  can leak past the scope. No cancellation/aggregation machinery is
  pretended at.

**Verification.** Five new cases in `llvm_self_test_async.l` (13
total): a spawn binding held across other work and awaited later; the
language reference's own §7.4 dashboard shape (three spawns in a
`scope`, awaited, aggregate returned from inside the scope block);
`scope` interacting with `defer` as an ordinary lexical scope; an early
`return` from inside a `scope` that also registered a `defer` (the
scope's defer drains on the return path with the value captured first —
the D-N-020 + scope-boundary composition, added per review #5025); and
an ASan-clean String-typed spawn-binding loop. Plus the standard sweep:
full native self-test suite, `make ilverify`, and an end-to-end `lyric
build --target native` check.

**Related:** D-N-019 (refined by this entry), D-N-020 (`scope` reuses
its scope-exit discipline), D-N-003, `native/plan/06-async-design.md`
(the preserved coroutine mechanism this entry's follow-up will need),
`docs/01-language-reference.md` §7.4, `msil/codegen.l` `ESpawn`/`SScope`
(the reference lowering matched here).

## D-N-022 — Native async is real: LLVM coroutines + a cooperative lyric-rt scheduler, with `Std.Time.sleepMillis` as the async leaf (supersedes the passthrough lowering of D-N-019/D-N-021)

**Date:** 2026-07-04
**Status:** Accepted

**Context.** D-N-021 established that genuine concurrency on native is
gated on an async *leaf primitive*: with no operation that can leave a
task incomplete, `spawn`/`await` passthrough was observationally exact.
This entry ships that leaf and the machinery around it, so spawned
tasks now genuinely interleave.

**Decision — the scheduler (`lyric-rt/src/lyric_async.c`).**
Single-threaded, cooperative, run-to-completion. Tasks are HOT: calling
an `async func` runs its body until the first genuine suspension — an
`await` on an incomplete task, or an async sleep — matching .NET's
hot-task model. After an async call returns, its task is COMPLETE,
SLEEPING, or WAITING (never READY/RUNNING), so `spawn` needs no
scheduler call: it is the call itself with the returned task held
un-awaited, and a never-suspending task reproduces the D-N-021
passthrough behavior as the degenerate case. State machine:
RUNNING/SLEEPING (deadline-ascending timer list)/WAITING (parked on the
dependency's waiter list)/READY (FIFO)/COMPLETE. `lyric_task_block_on`
drives the loop from synchronous contexts (`main`, or an `await` in a
plain function): run ready tasks, wake expired sleepers, `nanosleep` to
the earliest deadline, and panic on a genuine deadlock (nothing ready,
no timers). Ref discipline: the caller owns the ramp-returned ref
(rc=1); the scheduler holds exactly one additional ref from
registration (SLEEPING/WAITING retain) to completion; the task dtor
destroys the coroutine frame and releases a ref-typed result.

**Decision — the emission (`Lyric.LlvmCodegen`).** Every non-generator
`async func` emits as `define i8* @f(...) presplitcoroutine` returning
its LyricTask*. Prologue: `llvm.coro.id`/`coro.alloc`(dynamic
`lyric_alloc`)/`coro.begin`, then `lyric_task_new(hdl)`. `return`
lowers to defers + ARC releases, `lyric_task_complete(task, slot,
is_ref)`, and a branch to the shared final-suspend block; the ramp's
only `ret` is after `llvm.coro.end`. Mid-body suspends register first
(`lyric_async_await` / `lyric_async_sleep`) then `llvm.coro.suspend`.
The C scheduler resumes frames through `lyric_coro_resume`/
`lyric_coro_destroy` — thin LLVM-compiled wrapper defines emitted into
async-using modules, because CoroSplit emits the frame's resume/destroy
pointers as `internal fastcc`, which C must not call directly.

**Decision — call sites.** A direct call to an async callee awaits in
place (is-complete check, else park-and-suspend in a coroutine /
`lyric_task_block_on` in a sync context, then read the result slot as a
borrow); `spawn f(...)` is the only context that keeps the un-awaited
task (`__task<T>` struct-name types, ARC-managed via `isRefNType`).
This mirrors the front end exactly: `spawn`/`await` are
type-transparent and no program can hold an unawaited result except
through `spawn`. A task flowing un-awaited into a value position is a
named codegen diagnostic. Async generic instances thread the same
path via `NFnInst.isAsync`; `async func main` is driven by the C-main
wrapper through `lyric_task_block_on`.

**Decision — the async leaf.** `Std.Time.sleepMillis` calls lowered
*inside a coroutine* are intercepted and emitted as
`lyric_async_sleep` + suspend: the sleep parks only the calling task,
an improvement over the thread-blocking sleep .NET/JVM perform (no new
`Std.Async` surface, no cross-target API divergence — the same source
means the same thing everywhere, and suspending is strictly better
scheduling of the same contract). Synchronous contexts (including
sync helpers called from a coroutine) fall through to the blocking
kernel twin, exactly as on the other targets.

**ARC across suspends.** No restriction needed: Lyric locals and temps
hold OWNED refs (bind retains, call results transfer), and frame-spilled
owned refs are sound across suspends — their releases execute after
resume in the split clones. The one exception is ref-typed *parameters*
(borrows, Rule 5): the caller regains control at the first suspend and
may release its refs while the frame is parked, so coroutine entry
retains each ref param and registers it in the function scope for
release on every exit path. Frame destruction only happens at rc=0,
which the scheduler's parked ref prevents before completion.

**Semantics note.** An un-awaited spawned task that never completes is
abandoned at process exit (its frame and task object are not reclaimed)
— the same abandonment .NET permits, minus a GC to sweep it; tests and
programs that care run everything to completion via `await`.

**Verification.** Six C scheduler tests in `lyric_rt_test.c` drive the
exact protocol codegen emits through fake coroutine handles (hot
completion, block-on-sleep, two-sleeper interleaving with >= 20ms
event separation, await chains, multi-waiter wake, deadlock abort);
seven new Lyric cases in `llvm_self_test_async.l` (20 total) prove
effect-order interleaving of two spawned sleepers (impossible under
sequential execution), the same under ASan, an await chain through a
sleeping leaf, String args/results crossing suspends under ASan, and
the un-awaited-task diagnostic — while the 13 pre-coroutine cases now
run THROUGH the coroutine path as the regression net.

**Related:** D-N-019, D-N-021 (both superseded on the lowering
mechanism; their semantic analyses remain the ground for the hot-task
model), D-N-003 (panics abort; no cancellation machinery),
`native/plan/06-async-design.md` (the coroutine mechanism realized
here), `lyric-rt/src/lyric_async.c`, `lyric-compiler/lyric/llvm_codegen.l`.

## D-N-023 — The first async I/O leaf: `Std.Process.runCapture` inside a coroutine drives a nonblocking capture op through the sleep leaf (no new stdlib surface, timeout honored)

**Date:** 2026-07-05
**Status:** Accepted

**Context.** D-N-022 shipped real native async with one leaf
(`Std.Time.sleepMillis`) and deferred async I/O. The highest-value I/O
operation already in the cross-target surface is
`Std.Process.runCapture`: on native its kernel seam made one blocking C
call (`lyric_process_run`), so a coroutine capturing a subprocess
stalled the entire scheduler for the child's whole lifetime — and the
sync seam ignores `timeoutMs` outright (#4752).

**Decision — a pump loop over the existing sleep leaf, not scheduler
fd-readiness.** The JVM kernel twin already drains its process pipes on
a documented 1 ms polling cadence; the native async seam adopts the
same idiom. `lyric-rt` gains a nonblocking capture op
(`lyric_process_start` / `_pump` / `_kill` / accessors / `_free` over
the same fork/execvp spawn path as the sync runner, with `O_NONBLOCK`
pipe read ends and a `WNOHANG` reap), and the native kernel twin gains
`Std.ProcessCaptureHost.hostRunCaptureListAsync`: an `async func` that
starts the op and pumps it in a loop, suspending through
`sleepMillis(1)` between pumps. Every suspension is the D-N-022
machinery — no new scheduler capability, no `poll()`-based fd wait list
(deferred to the socket leaf, where readiness becomes load-bearing:
a per-task 1 ms cadence is the wrong shape for many idle connections).

**Decision — call-site interception with in-IR projection.** Only code
lowered inside an `async func` body can suspend, so the redirect
happens at in-coroutine `Std.Process.runCapture` call sites (the same
mechanism as the sleep leaf). The seam returns
`Result[ProcessCaptureResult, String]` while the intercepted call is
typed `Result[ProcessResult, String]`; the backend awaits the seam,
then projects — the Ok payload through the stdlib's own
`Std.Process.projectResult`, the branch/rewrap emitted with the
existing union construct/payload-read helpers under the `lowerIf`
value-slot ARC protocol. Alternatives rejected: a `@cfg(target =
"native")` async wrapper in `std/process.l` (depends on every stdlib
build pipeline applying target-cfg erasure — a silent-build-break
blast radius the kernel-twin placement avoids by construction), and
new public async API surface (cross-target divergence).

**Reachability.** No Lyric source names the seam, so the bridge's
function-granularity reachability walk would prune it; the walk keeps
it (and, transitively, everything its body needs) whenever
`Std.Process.runCapture` is reachable. The seam calls `sleepMillis`
bare because the walk resolves bare and fully-qualified call keys
only — an alias-qualified spelling is invisible to it (pre-existing
walk limitation, now documented here).

**Semantics.**
- The async path honors `timeoutMs`, which the sync native seam still
  ignores (#4752): on expiry the child is SIGKILLed (the child process
  only, not its tree — narrower than the managed twin's `Kill(true)`),
  already-captured output is preserved, and the result reports
  `timedOut = true` with exit code -2, the managed-twin contract.
- Negative `timeoutMs` means no timeout; 0 kills at the first pump.
- An execvp failure in the child remains exit 127 with `Ok` (shell
  convention, matching the sync seam); only pipe/fork failure is `Err`.
- `runCaptureWithInput` is not intercepted (native has no stdin pipe,
  #4752 — the sync seam's explicit `Err` stands). A direct `spawn
  runCapture(...)` keeps the blocking sync path (spawn an async
  wrapper function to overlap captures — the natural pattern, and the
  one the front end's type-transparent `spawn` makes meaningful).
- Sync-context `runCapture` calls are untouched on every target.

**Verification.** Four C unit tests drive the op lifecycle (echo
pump; kill-mid-sleep preserving partial output with the 128+SIGKILL
status; kill-after-exit returning 0 with the real status preserved,
#5107; exec-failure 127) under clang and gcc. Six new
`llvm_self_test_async.l` cases (26 total): output/exit/timedOut
round-trip through the seam; two spawned captures whose 0.1 s child
completes before the 0.35 s child spawned first (impossible if either
capture blocked the scheduler); the same overlap ASan-clean; the
timeout contract (`timedOut`/-2/pre-kill output); a zero deadline
killing a sleeping child at the first pump; missing-binary exit
127. `lyric_process_kill` reports whether the SIGKILL actually
terminated the child, so one exiting inside the pump-to-deadline
window is never falsely reported as timed out (#5107). The interleave cases also double as the regression net that
caught the reachability gap during development (the intercept silently
fell through to the sync path until the walk kept the seam).

**Related:** D-N-022 (the scheduler and sleep leaf this builds on),
#4752 (sync-seam timeout/stdin gaps — the async path closes the
timeout half for coroutine callers), `lyric-rt/src/lyric_process.c`,
`lyric-stdlib/std/_kernel_native/process_capture_host.l`,
`lyric-compiler/lyric/llvm_codegen.l` (`emitAsyncRunCapture`),
`lyric-compiler/lyric/llvm_bridge.l` (reachability walk).

## D-N-024 — Native process capture reaches managed parity: always-piped stdin and a sync deadline kill close the `runCapture` half of #4752

**Date:** 2026-07-05
**Status:** Accepted

**Context.** After D-N-023, the native process runner still carried two
gaps the managed twin does not have (#4752): no stdin pipe anywhere (a
non-empty `stdinContent` was an explicit `Err` on both seams), and no
timeout on the synchronous path (`timeoutMs` silently ignored,
`timedOut` always false). Both were tracked deferrals, and both sat on
the same C function.

**Decision — always-piped stdin, interleaved with output reads.** The
child's stdin is a pipe on every capture, matching the managed twin's
`RedirectStandardInput = true`: a child that reads stdin sees the
content then EOF, never the parent's terminal. In the child, all three
pipe ends are `F_DUPFD`-lifted to fd ≥ 3 before the `dup2` fan-in onto
0/1/2, replacing case analysis over pathological low-fd aliasing. The
sync runner's poll loop gains the write end as a third entry —
**nonblocking** (POSIX blocking pipe writes of more than `PIPE_BUF`
bytes block until the full count is written, so a single large write
would deadlock against the child's full stdout pipe; the C test suite
pins this with a 256 KiB round-trip through `cat`). A child that exits
without draining stdin surfaces as `EPIPE`/`POLLERR`, and the remaining
content is silently dropped — the managed twin's absorbed writer throw.
SIGPIPE cannot kill the process: the write end carries
`F_SETNOSIGPIPE` on macOS; on Linux the write helper blocks the signal
for the write's duration and consumes a self-generated pending SIGPIPE
before restoring the mask (skipped when the caller already had it
blocked, so an intentionally-pending SIGPIPE is preserved).

**Decision — sync deadline kill with the #5107 contract.** `timeoutMs
>= 0` arms a monotonic deadline on the sync path; on expiry the child
is SIGKILLed, stdin feeding stops, and the loop keeps draining output
in 100 ms waits under a 2 s total drain budget (a grandchild holding
an inherited write end past the dead child cannot stall the EOF wait:
an idle one ends the drain at the first empty window, an actively
writing one hits the budget, #5176). After the
blocking reap, `timedOut` reports 1 only when the reaped status shows
the kill landed (`WIFSIGNALED`) — a child that exited normally in the
poll-to-kill window reports its real exit, never a false timeout
(the same contract D-N-023 established for the async op's kill,
#5107). The kernel seam normalizes a timed-out capture to exit code
-2, the managed-twin contract.

**Consequences.**
- Both native seams accept `stdinContent`; the async op copies it at
  start and pumps it out through its nonblocking write end alongside
  the output pumps. The explicit `Err` guards are gone.
- `Std.Process.runCaptureWithInput` now works on native, and its
  in-coroutine calls take the same async-seam redirect as `runCapture`
  (the /4 intercept; the /3 form inserts the empty stdin the seam
  expects). The bridge's reachability walk keeps the seam alive for
  either spelling.
- `lyric_process_run`'s signature grew (`stdin_content`, `timeout_ms`,
  `out_timed_out`); pre-1.0 native runtime, no compatibility shim.
- The runCapture half of #4752 is closed; the issue stays open for its
  remaining non-process items.

**Verification.** Seven new C unit tests under clang and gcc: a stdin
round-trip through `cat`; the 256 KiB no-deadlock interleave; a child
that ignores 256 KiB of stdin (the `EPIPE` drop path, real exit code
preserved); the sync deadline kill (`timedOut`, 128+SIGKILL raw
status, pre-kill output preserved); a deadline kill with 256 KiB of
stdin still in flight (the kill closes the feed and the drain
terminates promptly); a killed child whose grandchild keeps writing
(the 2 s drain budget returns control, #5176); and the async op's
256 KiB stdin pump. Four new `llvm_self_test_async.l` cases (30 total): sync
`runCaptureWithInput` round-trip in a plain main; the sync timeout
contract (`timedOut`/-2/pre-kill output); the 256 KiB sync round-trip
ASan-clean; and an in-coroutine `runCaptureWithInput` through the /4
intercept.

**Related:** D-N-023 (the async op this extends), #4752 (the
runCapture half closed here), #5107 (kill-vs-exit race contract),
`lyric-rt/src/lyric_process.c`,
`lyric-stdlib/std/_kernel_native/process_capture_host.l`,
`lyric-compiler/lyric/llvm_codegen.l`,
`lyric-compiler/lyric/llvm_bridge.l`, `lyric-stdlib/std/process.l`.

## D-N-025 — Native deadline kills take the child's whole process group: setpgid at spawn + kill(-pid), closing the D-N-024 process-tree deferral

**Date:** 2026-07-05
**Status:** Accepted

**Context.** Both native runners killed only the direct child on
deadline expiry (D-N-023 noted this as "narrower than the managed
twin's `Kill(entireProcessTree: true)`"; D-N-024 carried it as an
explicit deferral). A timed-out `sh -c` pipeline therefore left
grandchildren running — orphaned workers holding CPU, and (on the
sync path) holding the capture pipes open until the #5176 drain
budget expired.

**Decision — process-group isolation, not a descendant walk.**
`spawn_capture` puts every capture child in its own process group:
`setpgid(0, 0)` in the child before exec (a fresh fork child cannot
be a session leader, so failure is `_exit(126)`), mirrored by
`setpgid(pid, pid)` in the parent (the standard double-setpgid idiom
— a kill issued before the child runs cannot miss the group; the
parent's EACCES-after-exec result is ignored). Both deadline kill
sites (`lyric_process_run` and `lyric_process_kill`) send
`kill(-pid, SIGKILL)`, with a direct-pid fallback for the
cannot-happen case of both setpgid calls failing.

The alternative — walking `/proc` (Linux) / `proc_listchildpids`
(macOS) to enumerate descendants, as the .NET BCL's `Kill(true)`
does — was rejected: it is platform-divergent code with an inherent
race (a process spawned between the walk and the kills escapes),
whereas the group kill is atomic over present *and* future group
members.

**Trade-off (documented, accepted).** A group-isolated child no
longer shares the terminal's foreground process group, so it does
not receive terminal-generated signals (Ctrl+C) alongside the
parent. For a capture API — piped stdio, deadline-supervised,
non-interactive by construction — this is acceptable: parent death
closes the pipe ends, so an orphaned child sees EOF on stdin and
EPIPE on writes instead. The .NET twin on Unix leaves the child in
the parent's group and inherits the opposite trade-off (Ctrl+C
propagation, but tree-kill via racy walks).

**What the #5176 drain budget is still for.** The group kill removes
the common grandchild-stall case, but a descendant that calls
`setsid` leaves the group and survives; the 2 s post-kill drain
budget remains the backstop that returns control to the caller. The
C suite pins both sides: the grandchild-writer test now asserts an
EOF-based drain exit *under* 2 s — still discriminating, because a
kill regressed to child-only cannot finish before ~2.3 s by
construction (deadline + the full drain budget), while leaving
CI-load headroom over the ~0.5 s good path (#5187) — and a new
setsid-escapee test asserts the budget path still engages (>= 1.5 s,
< 10 s; self-skips where `setsid`(1) does not exist, e.g. macOS).

**Contract unchanged.** #5107 semantics are untouched: `timedOut`
reports true only when the *direct child's* reaped status shows the
kill landed; exit codes, -2 normalization, and output preservation
are as in D-N-024.

**Verification.** Two C tests as above (clang + gcc). One new
`llvm_self_test_async.l` case (31 total): a plain-main `runCapture`
timeout over `sh -c "(while :; do echo g; sleep 0.05; done) & sleep
30"` asserting `timedOut`/-2 and an elapsed bound that a surviving
grandchild (30 s sleep) or a budget stall would blow.

**Related:** D-N-024 (the deferral this closes), D-N-023, #4752,
#5107, #5176, `lyric-rt/src/lyric_process.c`,
`lyric-rt/test/lyric_rt_test.c`.

## D-N-026 — `Std.Uuid` on native: string-backed representation, shared canonicalizer, and a tri-target four-format parse contract

**Date:** 2026-07-05
**Status:** Accepted

**Context.** `Std.Uuid` was one of the two remaining #4752 native
gaps: no `_kernel_native/uuid_host.l` twin existed, so any native
program importing it failed to build. The managed kernel's parse seam
was `hostTryParseGuid(s, value: out Uuid): Bool` — a Bool+out shape
the native backend cannot express (out/inout parameters are an
explicit native-codegen panic), so a straight twin port was
impossible; and the three targets silently disagreed about accepted
input (`Guid.TryParse` took D/N/B/P/X, `java.util.UUID.fromString`
took only the hyphenated form).

**Decision — string-backed native representation.** On native, `Uuid`
is a record holding its canonical lowercase hyphenated 36-char string.
Formatting is the identity, the nil sentinel is a literal, and only v4
generation crosses the C boundary: `lyric_uuid_v4` draws 16 bytes from
the existing `lyric_secure_random` (getrandom(2) / getentropy), stamps
the RFC 4122 version-4 and variant-10 bits, and formats once, in C.
Alternatives rejected: a two-`Long` (hi/lo) record would need 64-bit
shift/mask formatting and parsing in Lyric for zero benefit — nothing
in the public surface reads the bits, and the string form is what
every operation ultimately produces or consumes.

**Decision — canonicalize in shared code; kernels parse only the
canonical form.** `Std.Uuid.parseUuidOpt` now validates and rewrites
the four cross-target formats ("D" hyphenated, "N" bare, "B" braced,
"P" parenthesized; either hex case; surrounding ASCII whitespace
trimmed) to the canonical lowercase "D" form in pure, target-neutral
Lyric (restricted to `length`/`substring`/`==`/`+`, the String surface
every backend implements), and each kernel exposes one exception-free
Option seam, `hostParseCanonicalGuid(d)`, that only ever sees that
form. Consequences:
- The native twin's parse is a wrap (input already validated).
- The JVM twin's historical divergence is retired: fromString never
  accepted "N"/"B"/"P", so those forms failed on JVM while succeeding
  on .NET; now all four parse identically everywhere.
- The .NET-only exotic "X" form (`{0x..,0x..,..,{0x..}}`) is
  **intentionally dropped** on .NET too: it was reachable only as an
  accident of TryParse, was never named in `Std.Uuid`'s documented
  format list, and tri-target parity of the documented contract wins
  over preserving an undocumented single-target extra. The stdlib
  test suite now pins its rejection on every target.
- The managed kernel keeps its Bool+out `hostTryParseGuid` extern as
  a private bridge to TryParse; the JVM twin's copy of that shape is
  deleted.

**Out-param note.** This slice deliberately does NOT add native
out-param support — the Option-seam idiom (D-progress-557) already
fits every kernel boundary shipped so far, and general out/inout
lowering remains tracked separately.

**Verification.** One new C unit test (format shape, version/variant
positions, distinctness). One new `llvm_stdlib_self_test.l` case
(ASan): v4 generation/format/distinctness, nil, round-trip, all four
parse forms including case-folding, and malformed rejection on native.
`uuid_tests.l` gains alternate-form and X-rejection cases that run on
the managed targets.

**Related:** #4752 (Std.Uuid half closed; Std.Time calendar surface
remains), D-progress-557 (the Option-seam kernel idiom),
`lyric-rt/src/lyric_posix.c` (`lyric_uuid_v4`),
`lyric-stdlib/std/uuid.l`, all three `uuid_host.l` twins.

## D-N-027 — `Std.Time`'s calendar surface on native: nanosecond-count records, pure-Lyric civil-calendar math, and a strict ISO-8601 kernel

**Date:** 2026-07-05
**Status:** Accepted

**Context.** The calendar half of `Std.Time` (`Instant` / `Duration` /
`DateTimeOffset`, arithmetic, `addMonths`/`addYears`, ISO formatting
and parsing) wrapped .NET types with no native representation — the
last substantial #4752 gap.  The parse seam was also the Bool+out
`hostTryParseInstant` shape the native backend cannot express, and the
shared surface carried a dead private `findTimeZone` wrapper (never
called from anywhere) anchoring a `TimeZone` type native has no story
for.

**Decision — nanosecond counts, like the JVM twin.** On native,
`Instant` is a record holding nanoseconds since the Unix epoch (UTC),
`Duration` a nanosecond count, and `DateTimeOffset` an instant already
reckoned at UTC offset zero (the only offset the shared surface ever
constructs).  The int64-nanos range covers years ~1678..2262 — the
same window `java.time.Duration.toNanos()` lives in, and the window
the JVM twin's `hostTotalMillis` already implies.  `hostNow` reads a
new `lyric_epoch_nanos` (CLOCK_REALTIME at full resolution).
Fractional `Duration` constructors round to whole nanoseconds via
`llround(3)`, mirroring the JVM twin's `Math.round` idiom.

**Decision — civil-calendar math in pure Lyric.** Calendar
decomposition uses Howard Hinnant's proleptic-Gregorian
`days_from_civil` / `civil_from_days` (correct under Lyric's
truncating integer division across the whole representable window,
with an explicit floor-division helper for the nanos→days split so
pre-1970 instants decompose correctly).  `hostAddMonths` shifts the
month index and clamps day-of-month to the target month's length —
`DateTime.AddMonths` / `java.time.plusMonths` semantics (Jan 31 + 1
month → Feb 28/29); `hostAddYears` delegates to `hostAddMonths(12n)`,
matching both managed twins' Feb-29 clamping.  No tzdata dependency:
everything is UTC, like the shared surface.

**Decision — ISO-8601 text.** `hostInstantToString` emits
java.time-style ISO-8601 UTC ("YYYY-MM-DDTHH:MM:SSZ"; sub-second
fraction only when non-zero, trimmed to 3/6/9 digits).  Textual
parity with .NET was never the contract — .NET's "o" format always
carries seven fractional digits while `java.time.Instant.toString()`
trims — so native matches the JVM form and the cross-target guarantee
stays what it always was: same-target `toIsoString` →
`parseOptInstant` round-trip.  The native parser accepts exactly that
shape (optional 1..9-digit fraction, trailing "Z") with full field
validation (month/day-in-month including leap years, hour/min/sec
ranges) and rejects dates outside the i64-nanos window (edge dates
1677-09-21 and 2262-04-11) via an exact reconstruction check — a
wrapped total lands on a different day index — so every constructible
Instant, including the boundary ones, round-trips (#5219), while
unrepresentable dates in the edge years are still rejected.
`addMonths` applies the same exact check, so a no-op `addMonths` on a
boundary Instant succeeds instead of tripping a coarse year filter.  .NET's `DateTime.TryParse` stays
lenient on its own target (documented host leniency, unlike the
Uuid case where the format list was the documented contract).
Every arithmetic seam that could leave the window panics rather than
wrapping (#5213, #5216, #5217), since a silent i64 wrap would produce
a valid-looking Instant from the wrong century.  The panic is the
native analog of enforcing the target's own representable range —
.NET throws `ArgumentOutOfRangeException` at its year-1..9999 bounds,
while `java.time`'s far larger `Year` range means the same extreme
delta that panics on native simply succeeds on the JVM (#5232): each
target fails, or doesn't, at ITS OWN range; what no target may do is
wrap silently.  The seams: `plus`/`addDays` and
duration add/sub via shared checked add/sub helpers, `since` via
checked subtraction, the epoch-millis/seconds conversions via input
bounds ahead of the scale-up multiply, and `addMonths`/`addYears` via
Long month-index math plus a recomposed-year window check (an extreme
`Int` delta could otherwise wrap the month index back INTO the valid
window).

**Decision — Option seam + dead-code removal.** `parseOptInstant`
routes through a new `hostParseInstantOpt(s): Option[Instant]` seam
all three twins implement (the D-N-026 idiom; the managed twin keeps
its Bool+out extern privately as the TryParse bridge, the JVM twin's
copy is deleted).  The dead private `findTimeZone` wrapper is removed
from `std/time.l` — it had no callers anywhere in the tree, and
keeping it would have forced the native twin to fake a `TimeZone`
type for an unreachable function.  The kernel-level
`hostFindTimeZone` / `TimeZone` extern surface is removed from the
managed and JVM twins for the same reason (#5237): the kernels are
internal-only ("only `Std.Time` should import this"), so with the
wrapper gone the exports were dead code one layer down.  A real
timezone surface would be designed fresh, kernel included.

**Verification.** `time_tests.l` gains target-neutral calendar
coverage (no ISO-string goldens — the textual forms differ per host
by design): epoch conversions, duration constructors/arithmetic/
comparisons, month/year/day arithmetic with leap and common-year
clamping asserted via exact elapsed-milliseconds, and the parse
round-trip (Option[Instant] unwrapped by inline match — `Instant` is
an extern value type on .NET, the #5196 pattern).  A new
`llvm_stdlib_self_test.l` case (ASan) pins native string goldens:
epoch and 1e9-seconds ISO forms (the latter matching the JVM
self-test's golden), pre-1970 floor-division, fraction trimming,
leap/common/negative-month clamping, strict-parse acceptance and
rejections (non-leap Feb 29, missing "Z", out-of-range year), and
`now()` sanity.  One new C test pins `lyric_epoch_nanos` against
`lyric_epoch_millis`.

**Related:** #4752 (calendar half closed; file `stat` remains),
D-N-026 (the Option-seam precedent), D-progress-557,
`lyric-stdlib/std/_kernel_native/time_host.l`,
`lyric-stdlib/std/time.l`, `lyric-rt/src/lyric_posix.c`.

## D086 — Band 3 Phase B.0: `IAsyncStateMachine` synthesis for user-defined `async func` (no-await path, #2070)

**Context:** D085 (Phase A) fixed the `@externTarget async` silent miscompile. The
next step in epic #2070 is synthesising real `IAsyncStateMachine` state machines
for user-defined `async func` declarations so that the self-hosted MSIL backend
produces standards-conformant async code.  Phase B.0 covers the simplest case:
async function bodies that contain **no `EAwait` nodes** — the entire body runs
synchronously inside `MoveNext`, so no suspension machinery is needed.

**Decision (Phase B.0 — no-await IAsyncStateMachine synthesis):**

1. **SM TypeDef** — a sealed class `<funcName>__SM_N` (namespace = pkg) implementing
   `System.Runtime.CompilerServices.IAsyncStateMachine` is synthesised for each
   user-defined `async func` whose body contains no `EAwait` nodes.
   - Field `__state: Int` — state machine state (-1 = initial, -2 = done).
   - Field `__builder: AsyncTaskMethodBuilder` (void path) or
     `AsyncTaskMethodBuilder<T>` (non-void path) — task builder.
   - Fields `__p0..N` — one copy of each user-function parameter.

2. **MoveNext** — runs the user body synchronously and then calls `SetResult`:
   - Preamble: `ldarg.0; ldfld __pN; stloc N` for each user param (restores them
     from SM fields into local slots so the body lowering sees them by name).
   - User body lowered exactly as a normal function body.
   - Epilogue: `ldarg.0; ldc.i4 -2; stfld __state; ldarg.0; ldflda __builder;
     [result]; call SetResult; ret`.
   - **Phase B.0 scope:** bodies with no `try`/`catch`/`finally`-with-`return`
     are supported.  Bodies containing `try`/`return` inside a protected region
     require Phase B.1 protected-region routing; a diagnostic is emitted for
     out-of-scope bodies.

3. **SetStateMachine** — no-op stub (the CLR calls this when boxing a struct SM;
   we use a class SM so boxing doesn't apply).

4. **Kickoff function** — replaces the original user func declaration:
   - `newobj SM; stloc 0` — allocate (no Create() needed; zero-init by newobj).
   - `ldloc 0; ldc.i4 -1; stfld __state` — initialise state.
   - Copy user params into SM fields.
   - `ldloc 0; ldflda __builder; ldloca 0; call ATMB[<T>].Start<SM>(ref SM)`.
   - **Void path** — falls through to `ret` (no unwrap needed; MoveNext already
     called SetResult before Start returned).
   - **Non-void path** — `ldloc 0; ldflda __builder; call ATMB<T>.get_Task();
     callvirt Task<T>.get_Result(); ret` — synchronous unwrap (task completes
     immediately since MoveNext ran to completion before Start returned).

5. **TypeSpec-parented MemberRef signatures** — `SetResult(T)` and `get_Task()`
   MemberRefs on `ATMB<T>` TypeSpecs use `VAR 0` (ECMA-335 II.23.2.1: the
   TypeSpec parent captures the concrete type argument; method signatures use the
   class type parameter placeholder).

6. **`lowerMRecord` TypeDef-first ordering** — the TypeDef row is now registered
   in the PE tables **before** field rows and method bodies are emitted.  This is
   required so that `findTypeDefRowByName` + `findFieldDefRowOfType` succeed inside
   `lowerMFunc` for MoveNext (which uses `MLdfldByName`/`MStfldByName`).  The row
   values are identical; only the insertion point moves earlier.

**Type-checker gap (tracked):** The self-hosted type checker does not yet
propagate the return type of `async func f(): T` through call sites — it infers
`Unit` instead of `T` for `val x = f()`.  This causes false T0043 diagnostics
when the result is used with typed assertions (`assertEqualInt`), but does not
affect runtime correctness or code generation (the codegen emits the correct type
from the function declaration).  Fixing the type-checker async return-type
inference is tracked as a follow-up in #2070.

**Regression gate:** 847/847 emitter tests + 84/84 CLI tests green.  All 7 Phase
B.0 tests in `lyric-compiler/lyric/async_sm_self_test.l` pass (tests 1–5 cover
non-void, void, and sequential paths; tests 6–7 cover explicit-return epilogue
paths added for #2256).  Phase A tests (`async_extern_self_test.l`) unaffected.

---
## D087 — Band 3 Phase B.1: `IAsyncStateMachine` synthesis for user-defined `async func` (await path, #2070)

**Context:** D086 shipped Phase B.0 (no-await SM synthesis).  Phase B.1 handles the
real suspension case: an `async func` body contains one or more `EAwait` nodes, each
of which may suspend execution.  Two correctness bugs blocked Phase B.1 from working.

**Decisions:**

1. **AwaitUnsafeOnCompleted MemberRef parent must be a TypeSpec (closed generic).**
   ECMA-335 §II.22.25 requires that when a method is called on a generic type instance,
   the MemberRef's parent column is a TypeSpec (closed instantiation), NOT an open
   TypeRef.  The Phase B.1 codegen was using `cctx.tokAtmb1AwaitUnsafeMr` whose parent
   was the open TypeRef `AsyncTaskMethodBuilder`1`.  The CLR rejected this at runtime
   with `TypeLoadException: Could not load type 'AsyncTaskMethodBuilder`1'` — a
   misleading error whose root cause is the malformed MemberRef parent.  Fix: compute a
   per-function `ctxAddMemberRefForTypeSpec(tsRow, "AwaitUnsafeOnCompleted", ...)` where
   `tsRow` is a TypeSpec for `GENERICINST VALUETYPE AsyncTaskMethodBuilder`1 <retTy>`.

2. **`MValueTypeGenericInst` locals must NOT degrade to Object in `buildLocalVarSigWithCtx`.**
   The CLR JIT cannot store an unboxed struct value (e.g. `TaskAwaiter<Int>`) into a
   local slot declared as `Object`.  Doing so via `stloc` causes "Common Language
   Runtime detected an invalid program".  The fix: emit the full
   `GENERICINST VALUETYPE typeRef<args>` encoding for `MValueTypeGenericInst` locals in
   `buildLocalVarSigWithCtx`, using `bufMsilTypeWithCtx` (which already handles this
   case).  `MGenericInst` (CLASS) types may still degrade to Object because reference
   types are assignment-compatible with Object.  The intern key function `buildLvSigKey`
   was updated to include typeRefCode and arg types for VTGI entries.

**Result:** All 15 tests in `async_sm_self_test.l` pass (tests 1–7 are Phase B.0;
tests 8–15 are Phase B.1 covering 2-await, 3-await, void-await, and
two-parameter variants).

---
## D088 — Band 3 Phase B.2: promoted locals for `async func` with awaits (#2070)

**Context:** D087 shipped Phase B.1 (await-path SM synthesis).  A latent correctness
bug remained: `val x = expr` bindings computed before an `await` point and used after it
were allocated as MoveNext-local slots.  The CLR zeroes all local slots at the start of
each MoveNext invocation, so on resume the slot held 0/null instead of the original value.

**Decision: hoist all `val` bindings in a Phase B.1 `async func` body to SM fields.**

The promotion protocol:

1. **Field registration (on-the-fly):** When `lowerStmtMsil` processes `LBLet(name, ...)` 
   inside a Phase B.1 MoveNext context (`fctx.phaseBCtx.count > 0`), it adds a
   `MField(FDA_PUBLIC, "__local_<name>", ty)` to `pbc.smFields` (the SM class's field
   list, which is still being built at this point — `smRec` is not constructed until after
   all body lowering completes).  It also registers the name, local slot index, and type in
   three parallel lists on `PhaseBCtx`.

2. **Field store (on assignment):** After `emitStoreSlot` stores the value to the local
   slot, a `ldarg.0; ldloc <slot>; stfld __local_<name>` sequence also writes the value
   to the SM field.  This is always emitted (not conditional on whether an await follows),
   so correctness does not require knowing the future control-flow shape.

3. **Field reload (at each resume label):** `emitPhaseBAwait` emits, after the awaiter
   restore / field-zero / state-reset sequence and BEFORE the `afterAwaitL` label, a
   reload loop: `ldarg.0; ldfld __local_<name>; stloc <slot>` for each entry currently
   in `pbc.promotedLocalNames`.  Because the list is populated sequentially during body
   lowering, resume label N's reload covers exactly the locals defined in segments 0..N-1
   — precisely those that need restoring at that point.

**Conservative promotion strategy:** All `LBLet` bindings are promoted, regardless of
whether they are actually live across an await.  This is correct (promoting an
unnecessary local is benign — the field just holds a value that is never reloaded) and
simple to implement.  The cost is one extra field per promoted local on the SM class.

**Result:** 4 new tests in `async_sm_self_test.l` (tests 16–19) cover: val-survives-one-
await, two-vals-survive-two-awaits, val-defined-between-awaits-survives-second, and
val-survives-three-awaits.  All 19 tests pass.

---

## D089 — Band 3 Phase B.2+: `var` promotion and while-loop await scanning fix (#2070)

**Context:** D088 extended Phase B.2 promoted locals to `LBLet` (`val`) bindings.  Two
further correctness gaps remained:

1. **`LBVar` bindings not promoted:** `var i = 0` in an async function body allocated a
   plain MoveNext local slot.  After suspension+resume the CLR zeroed the slot, corrupting
   the loop counter.  Fix: `LBVar` non-hoisted branches (both `Some(init)` and `None`)
   now call `phaseBRegisterAndSyncLocal` to register the var as a promoted field.
   Reassignment handlers (`lowerAssignExprMsil` EPath `AssEq` and compound-op paths) now
   call `phaseBSyncLocalIfPromoted` to keep the SM field current after every write.

2. **`collectAwaitTypesStmtPB` missing `SWhile` (and other control-flow forms):** The
   pre-scan that counts `EAwait` nodes (to pre-allocate `resumeLabels` and
   `awaiterFieldNames`) had `case _ -> {}` for all statement kinds not explicitly listed,
   silently skipping `SWhile`, `SFor`, `SLoop`, `SScope`, `STry`, `SAssign`, and `SThrow`.
   An `EAwait` inside a while-loop body was therefore never counted; `emitPhaseBAwait`
   accessed `resumeLabels[0]` on an empty list and crashed with `ArgumentOutOfRangeException`.
   Fix: added explicit cases for every statement kind that contains sub-blocks or
   sub-expressions, matching the completeness already in `collectAwaitTypesExprPB`.

**Bonus fix — stale `deps.json` with new stage1 DLLs:** After the stubbable port
(`Lyric.Lyric.Stubbable.dll` added to stage1), the `Makefile` `aot` target ran
`dotnet build` incrementally, skipping `deps.json` regeneration.  The new DLL was absent
from the TPA list, causing `FileNotFoundException` on any `lyric test` run.  Fix:
`dotnet build --no-incremental` in the `aot` target so `deps.json` is always regenerated
to match the current stage1 glob.

**Result:** 2 new tests in `async_sm_self_test.l` (tests 20–21) cover var-bindings-in-while-
loop with n=3 (result=6) and n=0 (result=0).  All 21 tests pass.

---
## D090 — Band 3 Phase B.3: stack-spill for `EAwait` in expression-position operands (#2070)

**Context:** D088–D089 covered promoted locals for named bindings.  A complementary gap
existed for *anonymous* intermediate values: when `await expr` appears as a sub-expression
of a binary operator (e.g. `(await f()) + (await g())`), the left-operand result sits on
the eval stack while the right operand is being computed.  If the right operand contains an
`await` that actually suspends, the CLR's `leave` instruction clears the evaluation stack
at the suspension point — the left-operand value is irrecoverably lost.

**Decision:** Extend `lowerBinopMsil` with stack-spill logic for all binary operators:

- Before lowering the RHS, call `exprContainsAwaitMsil(rhs)` to check whether RHS contains
  any `EAwait` node.
- If true, call `phaseBSpillToLocal(pbc, fctx, insns, lhsTy)`:
  - Allocates a new local slot.
  - Emits `stloc` to pop the LHS value from the stack into that slot.
  - Calls `phaseBRegisterAndSyncLocal` to register the slot as a promoted SM field and
    emit `ldarg.0; ldloc; stfld __local___spill_N` — saving it to the SM immediately so
    it survives any suspension inside the RHS.
  - Returns the local index for the caller to use.
- Lower RHS normally (including any awaits within it).
- After RHS is complete, reload the spilled LHS if needed:
  - **Commutative operators** (`+`, `*`, `xor`, `==`, `!=`): emit `ldloc spillIdx` after
    RHS; stack becomes [rhs_result, lhs_result]; the op produces the correct result.
  - **Non-commutative operators** (`-`, `/`, `%`, `<`, `>`, `<=`, `>=`): allocate a
    temporary RHS slot, emit `stloc rhsTemp; ldloc spillIdx; ldloc rhsTemp`  to restore
    [lhs, rhs] order before the op.  The RHS temp does not need to be promoted (it is
    only used within the same MoveNext invocation, after the await completes).
- **String concatenation** (`BAdd` on `MString`): the LHS is already stored to a named
  local (`__sadd_N`) before lowering the RHS.  When RHS contains an await, that local is
  additionally registered/synced as a promoted SM field via `phaseBRegisterAndSyncLocal`.
- Guard: all spill-path branches are gated on `fctx.phaseBCtx.count > 0` so non-async
  functions are unaffected.

**New helper:** `phaseBSpillToLocal(pbc, fctx, insns, ty): Int` — one-stop spill that
allocates, stores, and promotes; returns the local index.

**Tests:** `async_sm_self_test.l` Phase B.3 section (5 new test functions + 5 test cases):
`asyncAddBothAwaited` (commutative add), `asyncSubBothAwaited` (non-commutative sub),
`asyncLtBothAwaited` (comparison), `asyncAddRhsAwaited` (literal lhs, awaited rhs), and
`asyncStrConcatBothAwaited` (string concat with both sides awaited).

**JVM target:** Both D088–D090 fixes (promoted locals and binop stack-spill) are
**structurally inapplicable** to the JVM backend.  The JVM `EAwait` lowering
(`lyric-compiler/jvm/codegen.l:780`) is bootstrap-synchronous — `await expr` lowers
as a pass-through `lowerExpr(ctx, insns, inner)` with no state machine, no suspend/
resume protocol, and no `leave` instruction.  JVM locals are never zeroed between
"invocations" of a single method activation, so the promoted-field pattern is
unnecessary.  True JVM async will be a separate effort (virtual-thread continuations
or bytecode transformation) when Phase B equivalent work is scoped for that target;
at that point a dedicated D-progress entry will track it.  Closed as not-applicable
in issue #2356.

**Result:** All 26 tests in `async_sm_self_test.l` pass.  Existing `stack_spill_two_await_args`
and `stack_spill_await_in_binop` F# inline tests continue to pass.  All 24 async F# tests pass.
843/843 emitter tests green.  Tracked as D-progress-439.

---

## D091 — Band 3 Phase 4: `spawn` semantics and `await externFn()` pass-through (#2070)

**Context:** D090 completed the synchronous-context stack-spill work for complex `await`
sub-expressions.  Two remaining Phase 4 items were identified in the epic:

1. **`spawn asyncFn(args)`** — kick off an async function and return its `Task<T>` handle to
   the caller without blocking.  The caller can store the handle in a `val` and later
   `await handle` to block for the result.

2. **`await externFn()` pass-through** — `@externTarget` async functions (e.g.
   `stringReaderReadToEnd`, `taskDelay`) already block synchronously via an appended
   `.get_Result()` or `.Wait()` call; their Lyric return type is `T`, not `Task<T>`.  An
   explicit `await` on such a call should be a no-op pass-through — the value is already
   resolved and `isTaskTypeMsil(T)` returns false.

**Decisions:**

**`ESpawn(inner)` lowering (MSIL):** `lowerExprMsil(ESpawn(inner))` lowers the inner
expression (which may be an `ECall` or another `ESpawn`) and returns the resulting
`MsilType` unchanged.  The call-site kick-off already produces a `Task<T>` on the stack (the
async kick-off returns a running `Task<T>` immediately), so no additional wrapping is needed.
`spawn asyncFn(args)` in a non-SM context stores the `Task<T>` on the stack; `await handle`
then calls `emitBlockingAwait` to block for the result.

**`EAwait(inner)` gating via `isTaskTypeMsil`:** A new helper `isTaskTypeMsil(cctx, ty)`
checks whether an `MsilType` is `Task` (non-generic) or `Task<T>` (generic).  The `EAwait`
lowering path now gates on this check:
- If `isTaskTypeMsil(ty)` is false: the inner expression already produced `T` — emit
  nothing extra (pass-through).
- If true and `phaseBCtx.count > 0`: emit full Phase B suspension via `emitPhaseBAwait`.
- If true and `phaseBCtx.count == 0`: emit blocking unwrap via `emitBlockingAwait`.

This correctly handles `await externFn()` (inner type is `T`, not `Task<T>`) as a
pass-through, and handles `await spawnedHandle` (inner type is `Task<T>`) via blocking.

**Pre-scan for spawn bindings (`collectAwaitTypesPhaseBMsil`):** A two-phase pre-scan was
introduced to track `val h = spawn asyncFn(x)` bindings so that a later `await h` inside
an async SM knows to allocate a `TaskAwaiter<T>` awaiter field:

- **Phase 1 (flat top-level scan):** Walks only the outermost block's statements, looking for
  `SLocal(LBVal(PBinding(name), None, ESpawn(inner)))`.  For each such binding, calls
  `inferCallReturnTypePB(inner)` to obtain the `Task<T>` type and adds `(name, Task<T>)` to
  parallel `spawnNms: List[String]` / `spawnTys: List[MsilType]` locals.  Mutation happens
  only on LOCAL variables (never on `in` parameters) to work around an F# bootstrap emitter
  limitation where `.add()` on `in List[T]` parameters fails for non-BCL type arguments.

- **Phase 2 (recursive scan):** The full body is scanned read-only, passing the pre-built
  `spawnNms`/`spawnTys` lists as `in` parameters (no mutation).  `collectAwaitTypesExprPB`
  checks `EAwait(EPath(name))` against the spawn list to allocate the correct awaiter type.

Nested `spawn` bindings (inside `if`/`match`/loops) are deferred; the flat pre-scan covers
all Phase 4 test patterns.

**`inferCallReturnTypePB` extension:** Added `ESpawn(inner)` → delegate to inner, and
`EPath(name)` linear scan of `spawnNms`/`spawnTys` (replacing the earlier `Map[String, MsilType]`
spawn-env which failed due to the same F# bootstrap emitter `.add()` limitation on `in Map`
parameters).

**Alternatives considered:**
- Registering `Task<T>` as the Lyric type-level return type of `spawn`: rejected — Lyric's
  type system treats `spawn f(x)` as having the same type as `f(x)` (the `ESpawn` type checker
  path delegates to the inner expression).  The `Task<T>` wrapping is an MSIL implementation
  detail only.
- Using a `Map[String, MsilType]` spawn environment: attempted first but blocked by the F#
  bootstrap emitter's BCL dispatch failure for two-arg `.add(k,v)` on `in Map[K,V]`
  parameters when `V` is a non-BCL Lyric type.  Replaced with the parallel-list approach.

**Tests:**
- `async_sm_self_test.l`: 3 new `async func` helpers (`asyncSpawnImmediate`,
  `asyncSpawnAndStore`, `asyncSpawnTwoAndAdd`) + 3 test cases (Phase 4 section, tests 27–29).
  All 29 tests pass.
- `async_extern_self_test.l`: 2 new test cases covering `await externFn()` pass-through
  (tests 3–4).  All 4 tests pass.  843/843 emitter tests green.  Tracked as D-progress-441.

---

## D092 — Band 3 Phase 5: `IAsyncEnumerable<object>` generator synthesis (#2070)

> **PARTIALLY SUPERSEDED by D119 (2026-07-05).** The generator *feature*
> and the `<FuncName>__Gen_N : IAsyncEnumerable<object>` class shape below
> still ship, but the **eager-producer** lowering this entry describes
> (`RunBody()` collecting all yields into `_values` before the first
> `MoveNextAsync`) is **no longer what runs**. The shipped self-hosted
> MSIL backend synthesises a *lazy* `TaskCompletionSource`-driven state
> machine (`synthesizeGeneratorMsil`) that produces one value per pull —
> verified empirically in D119 (interleaved-side-effect probe; infinite
> yield-only sequences stream without buffering). Read the mechanism
> below as historical; see D119 and `docs/09` §14.6 for the lazy model.

**Context:** D091 completed the async/await self-hosted story through spawn semantics.
Phase 5 targets `yield`-bearing `async func` bodies: previously these used a
bootstrap-grade "collect-all" model that allocated a `List<object>`, appended each
`yield`-ed value, and returned the raw list — incompatible with the language
reference's `for x in gen()` consumption model and with the .NET async streaming APIs.

**Problem:** The collect-all model returned `MObject` (erased `List<object>`) from the
kickoff function, forcing call sites to use `.count`/`[i]` instead of `for x in` iteration.
This made generators unusable from the standard iteration idiom and prevented composing
them with other `IAsyncEnumerable`-typed values.

**Decision: eager-producer `IAsyncEnumerable<object>` class synthesis.**

Each `async func` whose body contains at least one `yield` is compiled into a synthesised
generator class `<FuncName>__Gen_N` that implements three interfaces:

- `IAsyncEnumerable<object>` — via `GetAsyncEnumerator(CancellationToken)`
- `IAsyncEnumerator<object>` — via `MoveNextAsync()` and `get_Current()`
- `IAsyncDisposable` — via `DisposeAsync()` (no-op, returns `default(ValueTask)`)

**Eager-producer pattern** (matching `AsyncGenerator.fs` in the F# bootstrap emitter):

1. The kickoff function allocates the generator class instance, stores user parameters
   as fields (`__p0..pN-1`), initialises `_values = new List<object>()`, calls
   `RunBody()` synchronously to eagerly execute the user body (collecting all yields),
   and returns `this` typed as `IAsyncEnumerable<object>`.

2. `RunBody()` is an instance method that loads `_values` and user params from fields
   into locals, then executes the user-written generator body with `EYield` lowered to
   `_values.Add(boxed_value)`.

3. `GetAsyncEnumerator(ct)` resets `_pos = 0` and returns `this`.

4. `MoveNextAsync()` checks `_pos < _values.Count`; if true, increments `_pos` and
   returns `new ValueTask<bool>(true)`, else returns `new ValueTask<bool>(false)`.

5. `get_Current()` returns `_values[_pos - 1]`.

6. `DisposeAsync()` returns `default(ValueTask)` via `initobj`.

**Rationale for eager producer vs lazy coroutine:**

- The F# bootstrap emitter uses the same eager pattern; consistency simplifies parity
  verification and avoids a two-implementation gap.
- True coroutine/lazy generators require either `IAsyncStateMachine` suspension inside
  the generator (conflicting with the existing Phase B SM synthesis) or separate
  thread/channel infrastructure.  The eager pattern is simple, correct for all Phase 5
  test cases, and defers coroutine complexity to a future decision.
- Eagerness is semantically correct for finite, deterministic generators (all current
  Lyric generator patterns).

**Key MSIL encoding choices:**

- `InterfaceImpl.Interface` for generic interfaces (`IAsyncEnumerable<object>`,
  `IAsyncEnumerator<object>`) uses a `TypeDefOrRef` coded index:
  `tdrTypeSpec(tsRow) = tsRow * 4 + 2` — **not** the raw `0x1B000000 + row` table token.
- `ValueTask<bool>` struct locals use `MValueTypeRef`; `MVoid` is invalid as a local type.
- TypeSpecs are created idempotently via `ctxAddTypeSpec` (key deduplication), so calling
  both `synthesizeGeneratorMsil` and `emitCollectionForMsil` for the same package uses the
  same TypeSpec rows.
- `DisposeAsync` returns non-generic `ValueTask` (not `ValueTask<bool>`); its local is
  typed with `tdrTypeRef(cctx.trValueTask)` (the non-generic TypeRef row).
- `addPackageTokens` reserves 6 MethodDef rows per generator class (`.ctor` from
  `useDefaultCtor`, `RunBody`, `GetAsyncEnumerator`, `MoveNextAsync`, `get_Current`,
  `DisposeAsync`) before processing `MPFunc` items so token assignments are stable.

**Consumer protocol (`emitCollectionForMsil`):**

When the iterable type is `MIAsyncEnumerable(_)` (set by `funcRetTypes` for generators),
`emitCollectionForMsil` uses the async-enumerator protocol instead of the index loop:

1. Zero-init a `CancellationToken` local via `MLdloca + MInitobj`.
2. Call `GetAsyncEnumerator(ct)`, store enumerator.
3. Loop: call `MoveNextAsync()`, store the `ValueTask<bool>` struct, call
   `get_Result()` via `MLdloca + MCall` to extract `bool`, `BrFalse` to exit.
4. Call `get_Current()`, bind element to loop variable, execute body.

**Tests:**

- `lyric-compiler/lyric/async_generator_self_test.l`: 8 new test cases covering
  zero-param generators, parametric generators (1 and 2 params), string generators,
  empty-sequence edge case, and sum accumulation via `for x in` loops.
- `bootstrap/tests/Lyric.Cli.Tests/SelfHostedMsilBridgeTests.fs`: updated
  `shm_yield_collect` to use `for x in gen() { count = count + 1 }` instead of
  the old `items.count` API (old API worked on `List<object>`; new return type is
  `IAsyncEnumerable<object>`).

Tracked as D-progress-444 (initial synthesis) and D-progress-445 (element-type unboxing).

**JVM parity:** Generator synthesis is MSIL-only in this entry; the JVM equivalent is tracked in issue #2469 (filed 2026-06-06).

---

### D-progress-442: `lyric fmt` round-trip — extern-adjacent "formatter output does not parse" cluster (#2452)
<!-- Note: this entry was assigned D-progress-442 from the tracking issue number
     but was appended after D-progress-444/445 (the async-generator synthesis
     batch) had already been committed.  The number reflects the work-item
     origin; the append order is the merge sequence. -->

Fixes the ~14-file cluster (epic #2280) where `lyric fmt --write` aborted with
`formatter output does not parse` — the loss-checked guard caught the formatter
emitting source the self-hosted parser then rejected.  Five distinct
self-hosted-formatter / parser defects, all in `lyric-compiler/lyric/`:

1. **Braceless `\u` escapes (`fmt_core.l`).**  `escapeStr`/`charLitStr` emitted
   control characters as the legacy `\uXXXX` form; the lexer only accepts
   `\u{XXXX}` (L0021 otherwise).  `uHex4` now returns bare hex digits and every
   caller wraps them in `\u{…}`.
2. **String-escape canonicalisation flagged as a token change (`fmt.l`).**  The
   loss check `codeTokens` compared string / char literals by raw source
   spelling, so re-spelling `\u{FFFD}` as its literal scalar (or vice-versa)
   tripped the guard.  String (`TString`/`TStringPart`) and char (`TChar`)
   tokens now compare by **decoded value**; every other token still compares by
   exact source slice.
3. **Literal `${` and interpolation (`fmt_core.l`).**  `escapeStr` now escapes a
   literal `${` to `\${` (an unescaped `${` re-lexes as an interpolation hole).
   This also fixed a self-hosting bug: the formatter's own `interpolatedStr` line
   `"${" + … + "}"` was being mis-lexed as one interpolated string, so every
   formatted hole collapsed to a constant — the literal is now written `"\${"`.
4. **Loop invariants (`fmt_core.l`).**  Header `invariant:` clauses are stored by
   the parser as leading `SInvariant` statements in the loop body; the formatter
   emitted them back *inside* the braces, where a bare `invariant:` statement is a
   P0050 parse error.  `forLines`/`whileLines` (and the inline forms) now lift the
   leading invariant run back into the loop header.
5. **Aspect `config { }` drop + `around … -> ret` binder drop (`fmt_items.l`,
   `parser_items.l`).**  `aspectDoc` never emitted the anonymous `config { }`
   block (now emitted after `matches:`, per docs/26).  Separately, the parser's
   `parseAspectAround` built `retName` via an `if … { Some(x) } else { None }`
   value-expression that the stage-0 emitter mis-lowered to `None`, dropping the
   `-> ret` binder; rewritten as a `var`-accumulator.  The formatter's around
   emitter was also extracted to a parameter-matching helper to sidestep a
   stage-0 type-erasure miscompile of nested `match` on an erased value's field.

Three further idempotency fixes were needed once the cluster files became
formattable (each a pre-existing trivia leak that the does-not-parse failures
had masked):

6. **Trailing comment on the last `match` arm (`fmt_core.l`).**  `matchLines`
   never drained trivia before its closing `}`, so a comment on the last arm
   bubbled out to the enclosing construct — flipping a nested match between
   multi-line and inline across passes.  It now drains up to the match's end
   offset, re-attaching a same-line comment to the last arm.
7. **Aspect inter-member blanks (`fmt_items.l`).**  Blank lines between aspect
   members leaked into the `around` body via `blockLines`' leading trivia pop;
   `aspectAroundLines` now consumes the pre-around trivia (comments kept,
   blanks dropped).
8. **Protected-type inter-member blanks (`fmt_items.l`).**  The same leak in
   `protectedTypeDoc`'s member loop (e.g. a blank between a type `invariant:`
   and an `entry` body); now consumed per member.

All 14 target files round-trip and are idempotent, and the repo-wide
"does not parse" count is 0 with 0 non-idempotent files across all 620
formattable `.l` sources.  Twelve new `fmt_self_test.l` cases lock the
constructs, and `testFormatSourceCheckedStructureChange` (which deliberately
exercised the now-closed string-escape gap) is repurposed to
`testStringEscapeCanonicalizationAccepted`.  Parser 325/325, Emitter 843/843,
Cli 84/84, Lexer 128/128, TypeChecker 189/189 green; `make lyric` self-host
green.  The pre-existing config-field-annotation reorder (affecting both
aspect and module-level `config` blocks via `parseTrailingAnnotations`
over-consuming across brace-internal newlines) is a separate defect left to a
follow-up, as are the unrelated `token changed` failures in the #2280 backlog.

---

### D-progress-446: parameter annotations + the four aspect example files (#2454)

Completes #2454 by making the 4 aspect-using `examples/` files
(`jobqueue/api`, `ledger/api`, `product-catalog/aspects`, `rbac/api`) parse,
round-trip, and stay idempotent through the self-hosted formatter, now that
#2450 (`matches: name in {…}`) has landed.

Most fixes mirror the non-aspect slice (D-progress earlier / #2502): non-spec
example syntax made spec-compliant — `enum`→`union` for payload-bearing cases,
`[T]`→`List[T]`, `&&`/`||`→`and`/`or`, brace-less multi-statement match arms
wrapped, function-type params parenthesised (`in (T) -> R`). Two
aspect-specific fixes: qualified names in `name in { … }` matchers reduced to
the short names the matcher actually compares (docs/26 §179), and aspect
members reordered to the formatter's canonical `wraps:`/`inside:` → `matches:`
→ `config { }` order (docs/26 §6.2).

**New language feature: parameter annotations.** The examples' lyric-web
handlers use `@body req: in CreateRequest` — a documented feature
(lyric-web README, `docs/03` web-routing entry) that neither parser actually
implemented (`Param` had no annotations field). Implemented end-to-end on the
self-hosted side: `Param.annotations: List[Annotation]` (parser_ast.l),
`parseParam` consumes leading annotations, the formatter renders them inline
before the name, and every `Param(…)` construction site
(parser, mono, alias_rewriter, derives, msil/codegen) threads the field.
Grammar `Param` production gains `{ Annotation }`; language reference §5.1
documents it. New fmt self-test `testParamAnnotationRoundTrips`. The language
attaches no semantics to param annotations — they are metadata for libraries
and generators; lyric-web reads `@body` to pick the body parameter.

All 4 files: 0 parse errors, round-trip + idempotent, canonically formatted.
Repo-wide: 639 files format clean, 0 does-not-parse, 0 non-idempotent. Parser
325, Emitter 843, Cli 84 green; `make lyric` self-host green. (A couple of
redundant comments inside aspect `config { }` blocks were dropped — free
comments in that position are not yet preserved by the formatter; a separate
gap.)

---

## D093 — Position-introducer hard keywords accepted as contextual identifiers (#2538 follow-up)

**Status:** Accepted — implemented in the self-hosted parser.

**Context.** Using a reserved keyword as an identifier (`val entry = …`,
`var type = …`, a parameter named `record`) failed with a confusing,
cascading low-level parse error (`P0050 "expected an expression"` /
`P0103 "expected an identifier"`) that never named the actual cause. This
surfaced in #2538, where the lyric-resilience .NET kernel had to rename an
`entry` local to `circuit` purely to satisfy the self-hosted parser.

**Decision.** Two complementary changes:

1. **A specific diagnostic.** When a genuinely-reserved keyword appears in
   identifier, value, or binding-name position, the parser now emits
   `P0051 "'X' is a reserved keyword and cannot be used as …"` naming the
   keyword, instead of the generic `P0050`/`P0103` cascade.

2. **Contextual acceptance for pure position-introducers.** The grammar
   already distinguishes §1.5 hard keywords from §1.6 soft keywords, and
   already accepts `result` as an identifier in identifier position
   (`tryEatIdentOrContextual`). This is extended to the hard keywords that
   are *pure position-introducers* — they carry keyword meaning only at
   item position, or, for `entry`, inside a `protected type` body, and
   never in expression / statement / binding-name position:

   ```
   type  alias  record  union  enum  interface  wire  fixture  property  test  entry
   ```

   These remain hard-lexed keyword tokens (so `type Age = Int` and
   `record P { … }` still declare a distinct type / record at item
   position), but the parser additionally accepts them as identifiers in
   binding-name (`tryEatIdentOrContextual`, `parsePrimaryPattern`) and
   value (`parsePrimaryExpr`) position. Documented in grammar §1.6.2.

**Excluded (remain fully reserved).** Operators (`and`/`or`/`not`/`xor`/
`is`/`as`/`in`), expression or statement starters (`if`/`else`/`match`/
`for`/`while`/`do`/`return`/`throw`/`try`/`await`/`spawn`/`val`/`var`/
`let`/`func`/`case`/`then`/`when`/`with`), parameter/visibility modifiers
(`out`/`inout`/`mut`/`pub`/`internal`/`async`/`exposed`/`scoped`/
`singleton`/`protected`/`generic`/`extern`/`scope`/`bind`/`use`), literals
(`true`/`false`/`self`/`old`), and the structural keywords
(`package`/`import`/`end`). Admitting any of these as an identifier would be
genuinely ambiguous (they begin a construct in the same position) or would
materially harm readability. `aspect`, `config`, and `from` were already
soft keywords (lexed as identifiers) and need no change.

**Consequences.** Idiomatic code like `val entry = …` and `someLong`-named
domain variables work without contortion; the lyric-resilience `entry`
local reverts from the `circuit` workaround. Library and user code compiled
by the self-hosted compiler benefit immediately. The stage-0 F# bootstrap
lexer is unchanged (and need not change): the self-hosted compiler's own
sources, which F# compiles, do not use these keywords as identifiers.

---

## D094 — `slice.length` and `String` relational operators in self-hosted MSIL codegen (#2539)

**Context.** `lyric build --manifest <m>.toml` crashed with an
`AccessViolationException` when a `[project.packages]` entry pointed at a
**directory** (`"Pkg" = "src"`) rather than an explicit file. The directory
branch in `cli.l` sorts the discovered file list for deterministic ordering,
and that path surfaced three independent self-hosted MSIL codegen bugs.

**Bug 1 — `slice.length` assumed a real array or a `String`.** Slice values
are `List`-backed at runtime (a slice literal `[…]` builds a `List<object>`,
and `List.toArray()` is a no-op that returns the receiver `List`), but the
`slice[T]` *type* lowers to the MSIL type `MArray`. The `.length`
member-access codegen dispatched on the receiver's MSIL type:

- an `MArray` receiver emitted `ldlen` — correct only for a genuine CLI
  array; on a `List`-backed value it reads a field as a length (garbage) or
  faults;
- an `MObject` receiver fell through to the `String.get_Length` path,
  reinterpreting the `List` as a `String`;
- an `MConcreteList` receiver threw "unimplemented List member access".

Meanwhile `.count`, indexing, and `for` were already `List`-aware. Both
`System.Array` and `List<T>` implement the non-generic
`System.Collections.IList` / `ICollection`, so the fix routes `.length`
(and slice indexing) through `ICollection.get_Count` / `IList.get_Item` for
every `List`-backed receiver, with an explicit `MString` arm preserving
`String.length` → `String.get_Length`. This also fixes the pre-existing
`for x in str.split(…)` fault (a genuine `String[]` iterable hit the
`List<object>`-specific cast).

Reading a `slice[Byte]` element through `IList.get_Item` returns a boxed
`object` that must `unbox.any [System.Byte]`, which exposed a latent gap:
`MByte` was absent from both `isValueType` and `boxTypeRef`, so the unbox
fell back to `System.Object` (a no-op) and leaked the boxed reference —
returning garbage bytes. This broke `lyric-auth`'s HMAC signature
verification (the `fixedTimeEqualBytes` constant-time compare indexes a
decoded `byte[]`), caught by the ecosystem CI suite. Registering a
`System.Byte` TypeRef and adding `MByte` to `isValueType` / `boxTypeRef`
completes value-type boxing for `Byte` (and fixes the same latent unbox at
the other `boxTypeRef(MByte)` call site).

**Bug 2 — `String` relational operators emitted integer compares.** `<` /
`>` / `<=` / `>=` emitted a raw `clt` / `cgt`, which compares the two string
*references* as integers rather than lexicographically — so `"a" < "b"` was
`false`. The fix registers a `String.CompareOrdinal(string, string): int32`
MemberRef and routes the four relational operators through it when the lhs is
`MString` (`==` / `!=` already used `Object.Equals`, which is correct for
strings). This is what actually unblocked the directory build: the file-list
sort compares paths with `<`.

**Bug 3 (out of scope, tracked separately as #2557) — generic-method slice ABI.**
`Std.Sort.{sort,sliceCopy,mergeSorted}` are emitted as true CLR generic
methods whose `slice[T]` parameters become `!0[]` arrays, but the arguments
are `List`-backed; once instantiated the JIT reinterprets the `List`
reference as an array and `StelemRef` corrupts memory. The `.length` /
indexing fixes make these calls memory-safe (no AV) but `Std.Sort`'s generic
path still returns an unsorted result for a `List`-backed argument.
Correcting the cross-package / generic slice ABI is a larger representation
change and is **not** part of this fix. To unblock the headline directory
build without that change, the two `cli.l` directory-sort call sites use a
local monomorphic `sortFileList(List[String])` (mirroring the existing
`emitter.l` local sort) instead of the generic `Std.Sort.sortStrings`.

**Verification.** `slice.length` (literal / `toArray()` / `slice[T]`
parameter / `String.split` array), slice indexing, `for`, and the four
`String` relational operators are covered by
`lyric-compiler/lyric/slice_string_self_test.l`, run in CI via native
`lyric test`. The single-file directory-package build succeeds with no
`AccessViolationException`. The full F# emitter regression suite stays green
(843 passed, 0 failed).

---

## D095 — Self-hosted generic `slice[T]` uses the List-backed slice representation (#2557)

**Context.** D094 made *non-generic* slice access (`.length`, indexing, `for`)
route through the non-generic `System.Collections.IList` / `ICollection`, so a
`List`-backed slice value (slice literal, `List.toArray()` result, sub-slice
copy) and a genuine CLI array (`String.split`, base64 `slice[Byte]`) both work
behind the single `slice[T]` static type. The *generic* case was explicitly
left out (D094 Bug 3): a user-defined generic function whose parameter, return,
or typed local mentioned `slice[T]` (or a bare type variable `T`) miscompiled.

**Root cause.** Two independent gaps, both in the self-hosted compiler:

1. **The monomorphiser never specialised these calls.** `Lyric.Mono.inferExprTE`
   had no arm for a list/slice literal `[…]`, so `glen([1,2,3])` inferred no
   argument type, `unifyTE` (which also lacked a `TSlice` arm) could not bind
   `T`, and the call survived to codegen as a generic invocation. The surviving
   generic `slice[T]` parameter then lowered to `MArray(MClass(pkg + ".T"))` —
   a slice over a CLR type that does not exist — and element reads emitted a
   `castclass pkg.T`, which the JIT rejected as "Common Language Runtime
   detected an invalid program."
2. **Specialised bodies were copied verbatim.** Even once a call *did*
   monomorphise, `Lyric.Mono.specializeFunc` substituted type variables only in
   the signature (params / return) and shared `decl.body` unchanged. A typed
   body local — `val acc: List[T] = newList()` — kept its `T`, and codegen built
   a `List<pkg.T>` instance over the non-existent type, the same "invalid
   program" failure by a different route.

**Decision.** Keep the post-#2558 **List-backed** slice representation (do not
fork to a genuine-array ABI for the self-hosted path) and make generic
`slice[T]` reuse it consistently:

- `inferExprTE` infers `slice[ElemType]` from a non-empty list/slice literal's
  first element; an empty literal stays `None` (no element type to infer).
- `unifyTE` gains a `TSlice` arm so `slice[T]` unifies against `slice[Int]`
  (and `TArray`), binding `T`. Most generic-slice calls therefore monomorphise
  into concrete `__Int` / `__String` copies that reuse the working non-generic
  List-backed slice path end to end.
- `specializeFunc` substitutes type-variable annotations throughout the
  specialised body (`substTypesFunctionBody` walks local bindings, lambda
  parameter annotations, and explicit type applications), so `List[T]` becomes
  `List[Int]` in the copy.
- For the residual cases that genuinely cannot monomorphise, `Msil.Codegen`
  lowers a generic function's `slice[T]` / bare-`T` parameter and return to the
  erased List-backed forms: the *signature* uses plain `object` (so a
  List-backed argument matches the slot), the *body tracking* and the
  caller-visible `funcRetTypes` use `MArray(MObject)` / `MObject` (so `.length`
  / indexing / `for` dispatch through the IList path and element reads yield
  `object`), never `MClass(pkg + ".T")`.

**Scope boundary — F#-compiled stdlib (`Std.Sort`).** `Std.Sort.{sort,
sliceCopy,mergeSorted}` ship inside the **F#-emitted** `Lyric.Stdlib.dll`
(stage-0 builds the stdlib bundle), where the F# emitter lowers a generic
`slice[T]` to a genuine `!0[]` array and `List.toArray()` to a genuine `T[]`.
A self-hosted caller passing a `List`-backed value to that F#-array ABI still
corrupts memory; this is a **cross-emitter ABI fork**, not a self-hosted codegen
bug, and is out of scope for #2557. The `cli.l` directory-sort therefore keeps
its local monomorphic `sortFileList(List[String])` from D094 rather than
reverting to `Std.Sort.sortStrings`. Closing the fork (recompiling the stdlib
through the self-hosted emitter, or monomorphising qualified imported-generic
calls and pulling their non-generic wrappers into the bundle) is tracked as a
follow-up.

**Verification.** A new `lyric-compiler/lyric/generic_slice_self_test.l`
(`glen[T]` / `gidx[T]` / `gcopy[T]` / `gid[T]` over value and reference
elements, covering `slice[T]` parameters, bare-`T` and `slice[T]` returns, and a
`List[T]` body local) runs in CI via native `lyric test`. The D094
`slice_string_self_test.l` (non-generic slice + string regression guard), the
ecosystem `lyric-auth` / `lyric-session` suites, the four
`examples/{rbac,ledger,jobqueue,product-catalog}` builds, and the full F#
emitter regression suite (843 passed, 0 failed) all stay green; `make lyric`
self-hosts cleanly.

---

## D096 — Self-hosted MSIL backend reifies generic TypeDefs; erasure is rejected (#2359, docs/43)

**Context.** The self-hosted MSIL backend must emit generic record and union types
(`Box[T]`, `Option[T]`, `Result[T, E]`).  Two strategies exist: (a) *reify* —
emit true CLR generic TypeDefs with a GenericParam table row (0x2A), VAR-typed
fields, and closed-instantiation TypeSpec construction/field-read; (b) *erase* —
monomorphise every instantiation to a separate non-generic TypeDef per concrete
type argument set.

**Decision.** Reify.  The self-hosted MSIL backend emits truly generic TypeDefs:

- **GenericParam table (0x2A) rows** with the arity-suffixed CLR name
  (`` Box`1 ``, `` Maybe`1 ``).
- **VAR-typed fields** — a field `value: T` in a generic record lowers to
  `FIELD VAR(0)` in the FieldDef signature blob.
- **TypeSpec-parented construction and field access** — constructing `Box[Int]`
  emits a closed-instantiation TypeSpec `Box`1<ELEMENT_TYPE_I4>` as the
  `.ctor` MemberRef parent; field reads use the same closed TypeSpec.
- Nullary union cases use `newobj`-each-time (no singleton) — Q-GEN-001 resolved.

**Rationale:**

1. The F# stage-0 bootstrap emitter uses reified generics (confirmed by
   inspecting `Lyric.Stdlib.dll` from a stage-0 build).  Erasure would break
   load correctness: a non-generic calling code compiled by F# loading an
   erased (non-generic) type emitted by the self-hosted backend produces a
   `TypeLoadException` at runtime.
2. Erasure forecloses Stage 3 of epic #2359 (byte-match comparison between F#
   and self-hosted-emitted DLLs); reification is a prerequisite for any
   structural byte-match.
3. The arity-suffix correctness fix (`` `1 `` suffix on multi-field value types)
   is required for correct CLR multi-field value-type layout; the F# emitter
   omits it for some cases, which is an F# emitter bug that the self-hosted
   emitter does not reproduce.

**Scope boundary.** In-bundle generic records and unions are reified (D-progress-453,
D-progress-455).  The exact stage-3 stdlib byte-match against the F# emitter was
**not pursued**: the arity-suffix correctness fix means the self-hosted output is
not byte-identical to F# output (it is structurally correct and more correct),
and self-compiling the full stdlib is blocked on front-end completeness (docs/41
§R7).  JVM-target generic TypeDef emission is out of scope for this entry (tracked
under Band 4 of docs/41 and epic #2359).

**Related:** epic #2359 (stages 1/2/4 merged; stage 5 #2364 shipped via
D-progress-454/456), docs/43, Band 4 of docs/41.

---

### D-progress-473: Band 5 — remove `Lyric.Emitter.dll` + `FSharp.Core.dll` from stage-1 runtime bundle

**Problem.** `scripts/bootstrap.sh` was copying `Lyric.Emitter.dll` (the F#
bootstrap emitter) and `FSharp.Core.dll` into the stage-1 and stage-2 runtime
bundles, and `Lyric.Cli.Aot.csproj` carried an explicit `<Reference>` to
`FSharp.Core.dll`.  The stated justification was that stdlib kernel modules
`@externTarget`-ed into `Lyric.Emitter.*` helper types at runtime.

**Audit result.** All four kernel modules that previously went through
`Lyric.Emitter.*` host shims had already migrated:
- `console_host.l` / `verifier_env_host.l` — migrated in #1493
- `process_capture_host.l` — migrated in #1489
- `http_host.l` — migrated in G12 / #1576

A strings scan of every Lyric DLL in stage-1 found zero `AssemblyRef` entries to
`Lyric.Emitter` or `FSharp.Core`.  The one string hit (`Lyric.Emitter` in
`Lyric.Lyric.Emitter.dll`) was the package name in embedded JSON contract
metadata — not a binary reference.

**Changes.**
- `scripts/bootstrap.sh` (stage-1 and stage-2 CLI bundle sections): removed
  `FSharp.Core.dll` and `Lyric.Emitter.dll` copy blocks; replaced with a comment
  explaining the audit result.
- `bootstrap/src/Lyric.Cli.Aot/Lyric.Cli.Aot.csproj`: removed explicit
  `<Reference Include=".../FSharp.Core.dll">`.
- `bootstrap/tests/Lyric.Emitter.Tests/EmitTestKit.fs`: removed the defensive
  `FSharp.Core.dll` and `Lyric.Emitter.dll` copies from `prepareOutputDir`;
  updated docstring.
- `docs/23-fsharp-shim-elimination.md`: opening policy section updated.

**Verified.** `make stage1` produces a bundle with 103 DLLs, none of which are
`FSharp.Core.dll` or `Lyric.Emitter.dll`.  `make aot` succeeds with 0 warnings.
All 827 emitter tests pass.

## D097 — Cross-package restored generic TypeRefs carry the arity suffix and full metadata maps (#1496, D-progress-494)

**Context.** D096 resolved in-bundle generic records and unions (types defined and consumed in the same compilation unit). A separate gap existed for *cross-package* generic types: when a consumer imports a restored dependency DLL that exports `record Box[T]` or `union Maybe[T]`, the self-hosted MSIL backend must re-register those types from the synthesised `PackageDecl` extracted from the DLL's contract metadata. The registration path (`registerRestoredTypeDecl`, `registerRestoredRecordCtor`, `registerRestoredRecordFields`, `registerRestoredUnion`, `ensureCaseClassTypeRefRow`) was not populating the four metadata maps that `MNewobjGenericByName` / `MLdfldGeneric` / `MIsinstGeneric` lowering requires.

**Decision.** Cross-package restored generic TypeRefs carry the CLR arity suffix and the full metadata maps required for generic lowering.

Concretely:
- `registerRestoredRecordCtor` adds a second `ctxAddTypeRef` call with the arity-suffixed name (`` Box`1 ``) when `recGenerics.count > 0`, and populates `genericTypeArity` (FQN → arity) and `genericCtorParams` (FQN → VAR-form field types via `typeExprToMsilG`).
- `registerRestoredRecordFields` populates `fieldSigBytes` (raw `FIELD VAR(n)` blob), `fieldVarIndices` (VAR parameter index), and positional `byPosKey` mirrors for each field; stores `MObject` (not `MTypeVar(n)`) in `fieldMsilTypes` to avoid the `pushCollExpect` collection-element mis-path.
- `ensureCaseClassTypeRefRow` gains an `arity` parameter and appends the `` `n `` suffix when non-zero; call sites in `registerRestoredUnionCase` pass the case-class arity.
- `registerRestoredUnion` populates `genericTypeArity` for the union base type and passes `uGenerics` to each case registration.

**Rationale.** The arity suffix on a TypeRef's `Name` field is what `findTypeRefRowByName` matches against when resolving `MNewobjGenericByName`. Without it the lowering falls back to a wrong TypeRef (or finds none), and the resulting `.ctor` MemberRef carries a non-generic sig that mismatches the VAR-form ctor in the DLL — producing "Method not found" at runtime. The `fieldSigBytes` gap caused `MLdfldGeneric` to fall through to a plain `ldfld` on an `MObject`-typed field, silently returning 0. The `MTypeVar` → `MObject` substitution in `fieldMsilTypes` prevents `pushCollExpect` from routing a scalar constructor argument through the collection-element path, which was causing an `InvalidCastException` (String → IList) at runtime.

**JVM parity.** The JVM `compileToJarBundledWithFeatures` entry point has no restored-dep pipeline (no `restoredDllPaths` parameter), so the cross-package generic registration fix does not apply to the JVM target. JVM parity is tracked in issue #3094.

**Related:** D096, D-progress-495, epic #1470 Band 4, issues #1496 and #3094.

---

### D-progress-474: Fixture support in `lyric test`

**Date:** 2026-06-10

**What changed:**

`lyric test` now supports `fixture name[: T] = expr` items in `@test_module`
files.  `TestSynth.synthesize` rewrites each fixture to a module-level `val`
declaration in the synthesised source, making its value available to all test
functions.  The `FixtureUnsupported` outcome variant and the `fixtureSpan`
scanner that triggered it are removed.

**Files changed:**
- `lyric-compiler/lyric/test_synth/test_synth.l`: removed `FixtureUnsupported`
  variant, removed `fixtureSpan` function and early-return guard, added
  `IFixture` case in the item loop (replaces `fixture ` with `val `).
- `lyric-compiler/lyric/cli.l`: removed `FixtureUnsupported` match arms from
  `cmdTest` and `cmdTestManifest`.
- `lyric-compiler/lyric/test_synth_self_test.l`: replaced `testRejectsFixture`
  (expected `FixtureUnsupported`) with `testSynthesisesFixture` (verifies the
  fixture is rewritten to `val`).

**M2a–M2d migration attempted but blocked:** Migration of `MsilSelfTestM2a.fs`
through `MsilSelfTestM2d.fs` to native `lyric test` was attempted in the same
PR but had to be reverted due to two pre-existing self-hosted compiler bugs:

1. **`ByteWriter` name collision** (`#2737`): `Msil.Kernel.ByteWriter` (record)
   and `Std.Stream.ByteWriter` (interface imported transitively from the stdlib
   bundle) share the same short name.  When M2a/M2b compile against restored
   `Msil.Kernel.dll`, the self-hosted type checker resolves `ByteWriter` to
   `Std.Stream.ByteWriter`, causing a CLR runtime error:
   `Method not found: 'Std.Stream.ByteWriter Msil.Kernel.Program.bufNew()'`.

2. **Module-level `pub val` constants absent from contract metadata** (`#2738`):
   Constants such as `MIA_IL`, `MDA_PUBLIC`, `HASH_ALG_SHA1`, `TDF_PUBLIC`,
   `FIRST_METHOD_RVA`, and `ASF_NONE` defined in `Msil.Tables` and
   `Msil.Assembler` are not emitted into those DLLs' embedded contract metadata.
   When M2c/M2d load them as restored deps, the names are invisible to the
   self-hosted type checker (T0020 "unknown name").

The F# wrappers (`MsilSelfTestM2{a,b,c,d}.fs`) and the `func main(): Unit`
`.l` sources remain unchanged.  Migration will proceed once #2737 and #2738
are resolved.

**Not migrated (separate issue):** `msil_self_test_m1.l` imports `Msil.Pe`
which is not in the stage-1 DLL closure (`Lyric.Msil.Pe.dll` is not reachable
from `Lyric.Cli`).  Migration requires either adding `Msil.Pe` to stage-1 or
inlining the test helper.  Tracked separately.

---

## D098 — Contract metadata format version 3 with SHA-256 integrity hashing (docs/45)

**Context.** docs/45 proposed migrating from the per-consumer synthesis → parse → re-typecheck path to metadata-direct symbol table construction for restored Lyric packages.  The proposal was accepted in full.  Phase 1 — the `Lyric.ContractMetaEmit` package (`lyric-compiler/lyric/contract_meta_emit.l`) — shipped in D-progress-471.  This entry codifies the design decisions from docs/45 so the sketch carries a backing decision-log reference.

**Decisions adopted from docs/45:**

- **D1 — Metadata-direct symbol table construction**: chosen over the synthesis/parse/recheck cycle for performance, simplicity, and consistency with the auto-FFI approach.  Direct JSON → symbol table, no per-consumer recheck.
- **D2 — Contract hash required**: every emitted contract carries a SHA-256 hash of its own JSON (two-pass protocol: serialize with blank hash, compute SHA-256, re-serialize with hash embedded).  Required, not optional.
- **D3 — v2 support dropped immediately**: breaking change.  The CLI rejects contracts with `formatVersion` less than 3 with the message `"Contract metadata format v2 is no longer supported. Rebuild the library with the latest compiler and re-publish."` No dual-path support.
- **D4 — Explicit `visibility` field**: `ContractDecl` carries a `visibility: String` field (`"pub"` | `"internal"` | `""`) extracted from the parsed AST, not derived from `repr` string parsing.
- **D5 — New fields are `@stable(since = "X.Y")`**: `visibility`, `dependencies`, and `contractHash` did not exist before format version 3 and carry the release version that ships format version 3.
- **D6 — v2 rejection error message**: verbatim as stated in D3.
- **D7 — Bundled DLL dependency manifest structure**: per-package manifests within the bundled DLL; merged at load time.

**Current implementation state (Phase 1.2b shipped; phases 2–5 pending):**

- `lyric-compiler/lyric/contract_meta_emit.l` (`Lyric.ContractMetaEmit`) — the v3 emitter entry point `emitContractMetadata(contract): String`.  Ships the two-pass SHA-256 protocol.
- The bootstrap F# emitter (`ContractMeta.fs`) continues to emit v2 metadata for backward compatibility until issue #2580 (in-process MSIL bridge) lands.  Phase 2 (bridge wiring), Phase 3 (direct symbol table builder), Phase 4 (bridge migration), and Phase 5 (synthesis-path removal) are deferred.

**JVM parity.** Not in scope for Phase 1.  The JVM `compileToJarBundledWithFeatures` path does not have a restored-dep pipeline; JVM parity for contract metadata direct resolution is deferred.

**Related:** docs/45, D-progress-471, issue #2580 (in-process MSIL bridge prerequisite for phases 2–5).

---

### D-progress-502: Reproducible-emit gate on the self-hosted MSIL backend (Q-dist-001 prerequisite)

**Date:** 2026-06-11

**Context.** `scripts/bootstrap.sh` stage 2 was marked BLOCKED and ran with
`SKIP_VERIFY=1`: its comparison normalized intrinsic identity fields with a
fragile "16-byte differing run" heuristic that false-failed whenever two random
Module MVIDs coincidentally shared a byte (the differing run then split into
sub-16-byte pieces, which the heuristic rejected as a "non-GUID diff").  It also
conflated two different questions — *is the F# stage-0 emitter reproducible?*
and *is the self-hosted emitter reproducible?* — by compiling both stages
through the F# `--internal-build` path.

**Findings (verified empirically, 2026-06-11).**

1. The **self-hosted MSIL backend is deterministic by construction**: the Module
   MVID is a fixed all-zero GUID (`lyric-compiler/msil/lowering.l`), the PE
   `TimeDateStamp` is zero (`lyric-compiler/msil/assembler.l`), and no wall-clock
   value is baked into any heap or resource.  Building the full 56-package stdlib
   bundle (`lyric-stdlib/lyric.full.toml`) twice yields **byte-for-byte identical**
   images (exact `cmp`, no normalization).  Moreover, self-host-compiling the
   *entire* `Lyric.Cli` closure — all 103 DLLs, every `Lyric.*` / `Msil.*` /
   `Jvm.*` compiler package plus its stdlib import closure, via
   `--internal-perpackage-build` — is **also byte-for-byte reproducible
   run-to-run** (103/103 DLLs match).  So the determinism property holds for the
   whole self-hosted compiler, not just the stdlib.
2. The **F# stage-0 emitter is non-reproducible by design**: it emits a random
   MVID, a real PE timestamp, and a `DateTime.UtcNow` `build_date` embedded in the
   `Lyric.SdkVersion` resource (`bootstrap/src/Lyric.Emitter/Emitter.fs`).  It is
   frozen on a deletion schedule (no new F#; the `build_date` fix is not a
   bootstrap-blocking bugfix), so it cannot be made byte-stable and is **not the
   trust anchor**.

**Decision.** The reproducibility gate measures the trust anchor — the
self-hosted emitter that produces the shipped binary — not the disposable F#
stage 0.

- **MVID strategy.** Keep the self-hosted Module MVID fixed (all-zero) for now.
  A fixed MVID is a legitimate deterministic choice (the MVID is module-identity
  metadata, *not* assembly-binding identity, and the self-hosted backend emits no
  PDB), and it makes the image byte-stable so a signature over the bytes is
  stable.  Upgrading to a *content-derived* deterministic MVID (Roslyn
  `/deterministic` style — real, meaningful, and reproducible) is the preferred
  end state but touches `lowering.l` plumbing and ~84 byte-exact MSIL self-tests,
  so it is tracked as a follow-up rather than bundled into this gate.
- **Stage 2 (a) — STRICT gate.** `scripts/verify-reproducible-emit.sh` has two
  modes: `manifest` (build a `lyric.toml`/`lyric.full.toml` bundle twice, compare
  the single output) and `closure` (self-host-compile the whole `Lyric.Cli`
  closure twice via `--internal-perpackage-build`, compare every DLL).  Both run
  via the AOT `lyric` binary (self-hosted `Msil.Bridge`) and assert an exact
  `cmp`.  Wired into `bootstrap.sh` stage 2 (a) and a dedicated CI step covering
  the full stdlib bundle AND the whole compiler closure.  A regression fails the
  build.
- **Stage 2 (b) — informational diagnostic.** The stage-1-vs-stage-2 F#-bundle
  comparison is retained but reframed as non-fatal stage-0 drift tracking.  Its
  normalizer was rewritten to locate the COFF `TimeDateStamp`, optional-header
  `CheckSum`, and the Module MVID (first 16 bytes of the `#GUID` heap, reached via
  the CLI header → metadata root → stream table) by **parsing** the PE rather than
  guessing.  It masks only those intrinsic fields, so the F# `build_date` wall-clock
  surfaces as the one honest remaining DIFF (on `Lyric.Stdlib.dll`); 104/105
  per-package DLLs match exactly.

**Remaining gap (the long pole), restated.** The self-hosted front-end already
*compiles* the whole compiler closure (the `--internal-perpackage-build` path
CI's "Whole compiler self-host-compiles" gate validates), and — per finding 1 —
that closure now also *emits reproducibly* run-to-run.  What is NOT yet a fixed
point is the **cross-emitter byte-match**: the self-hosted compiler emitted by
the F# stage 0 vs. the self-hosted compiler emitted by a prior self-hosted stage
are not byte-identical, because (a) the F# stage-0 emitter is non-reproducible
(finding 2) and (b) the two emitters' codegen still diverges in places
(docs/43 — e.g. the generic arity-suffix correctness fix the self-hosted emitter
carries and F# omits).  Closing that is the residual §R7 work; this gate proves
and locks in the determinism *foundation* it depends on.

**Related:** docs/34 (distribution), docs/36 §R7 / G5 / Q-dist-001, docs/41 §R7,
`scripts/verify-reproducible-emit.sh`, `scripts/bootstrap.sh`.

---

## D099 — `lyric-health` checks are function references; the DLL-reflection dispatcher is abandoned (#679)

**Date:** 2026-06-12
**Partially supersedes:** D057 (registration model and route wiring only).

### Context

D057 shipped `lyric-health` with name-based registration: `HealthCheck`
stored a fully-qualified function name (`handlerName: String`) that a
future "kernel dispatcher" would resolve via DLL reflection at request
time, mirroring `Web.Route.handlerName`.  That dispatcher never landed,
so `runChecks` deliberately panicked rather than silently reporting
"ok" — issue #679 asked for the dispatcher so registered checks would
actually be called.

The reflection design proposed in #679 is rejected by later codebase
direction: contract metadata reads bytes directly instead of loading
types (docs/45, D098), source generators bridge via subprocess rather
than reflection (D075), and the Native AOT distribution path (docs/34)
forbids runtime reflection because the AOT linker trims unreferenced
methods.  `Lambda.Direct` (D064, docs/35 §10) already established the
sanctioned alternative: register a function reference so the compiler
roots the handler at the registration site.

### Decision

`lyric-health` registration takes function references, and `runChecks`
invokes them directly:

- `HealthCheck.handlerName: String` → `handler: () -> CheckStatus`.
- `pub record CheckStatus { healthy: Bool, detail: String }` with
  `pass()` / `fail(detail)` factory functions replaces
  `Result[Unit, String]` as the check return type.  Empirically, a
  `Result` constructed in the consumer assembly and matched inside
  `Health.dll` misdispatches (`Err` matched as `Ok`, and closure-built
  `Ok(())` hits a non-exhaustive-match codegen panic) because generic
  stdlib union instantiations are not yet identity-stable across the
  restored-package boundary.  A library-defined record whose values are
  built by library factories — even when the factory call sits inside a
  consumer closure — crosses the boundary exactly, so the silent
  health-misreport failure mode is structurally excluded.
- `CheckGroup` becomes a payload-free `union` (was `enum`): restored
  enums miscompile at consumer call sites (InvalidProgramException),
  while payload-free unions dispatch correctly.  `isLiveness` /
  `isReadiness` helpers are provided because consumer-side `match` over
  a restored union falls back to an always-true `isinst` (W0003); the
  helpers match inside the defining assembly where dispatch is exact.
- `runChecks(registry, group): HealthReport { healthy, body }` runs
  every matching handler exactly once, in registration order, and
  builds the D057 JSON response shape (unchanged).
  `runLiveness` / `runReadiness` map the report onto the lyric-web
  handler convention: `Ok(body)` when healthy, `Err(503 ApiError)`
  naming the failing checks when degraded.
- `registerRoutes`, `attachRegistry`, `__handleLiveness` /
  `__handleReadiness`, and `config Endpoints` are deleted.  The web
  router is name-based, so a registry value cannot reach a
  name-resolved handler; instead services expose one-line handlers in
  their own package (`pub func healthReady(): Result[String, ApiError]
  { return Health.runReadiness(buildHealth()) }`) and register them
  with `Web.addGet`.  This composes with the router as it exists today
  instead of waiting on route-annotation support, and it removes the
  `attachRegistry` stub that silently dropped its argument.

### Consequences

- `lyric-health` is functional end-to-end: registered checks run, the
  JSON report aggregates them, and the panic gate is gone.
- The library's test suite (`lyric-health/tests/health_tests.l`,
  17 tests) covers registration, execution (passing / failing / mixed),
  group filtering, JSON escaping, and the handler-result mapping; it
  runs in CI via `lyric test --manifest lyric-health/lyric.toml` in the
  ecosystem test step.
- `examples/ledger`, `examples/rbac`, and `examples/jobqueue` migrate
  to the new API.
- Breaking change to a pre-1.0 `@experimental`-cohort library; no
  SemVer major bump required (docs/05 Tier-5 framing).

### Alternatives considered

- **DLL-reflection dispatcher (the #679 proposal).**  Rejected: AOT-
  hostile, reflection-based, and the function-reference model is both
  simpler and already precedented by `Lambda.Direct`.
- **Keeping `() -> Result[Unit, String]` as the handler type.**
  Rejected on empirical grounds (see Decision): cross-assembly `Result`
  misdispatch would let a failing check report healthy — the exact
  failure mode a health library exists to prevent.
- **Keeping `registerRoutes` as a no-op shim over the new model.**
  Rejected: a function that silently drops its registry argument is a
  production-quality violation; the explicit two-line `addGet` wiring
  is honest about how the name-based router composes.

**Related:** D057, D064 / docs/35 §10 (`Lambda.Direct` precedent),
D075 (subprocess generators), D098 / docs/45 (byte-reading contract
metadata), docs/34 (AOT distribution), issues #679, #367, #1024.
## D100 — `call.elapsed` runtime instrumentation auto-injects `import Std.Time` at weave time (#1298)

**Context.** docs/26 §4.3 specifies `call.elapsed: Option[Int]` — `Some(ms)`
after `proceed` returns, `None` before `proceed` / when the body never calls
it (the zero-sentinel was rejected in Q-aspects-003).  PR #1172 shipped the
compile-time `call` fields and deferred `call.elapsed` / `call.caller` to
#1298 because both need runtime instrumentation, and `call.elapsed`
additionally needs a design decision: the woven wrapper must call
`Std.Time.monotonicNanos()`, but the consumer's file is not required to
`import Std.Time`.  Issue #1298 offered two options — auto-inject the import
at weave time, or synthesise fully-qualified `Std.Time.*` calls and rely on
the resolver accepting them without an import.

**Decision.** Auto-inject `import Std.Time` (deduplicated) into the woven
file whenever any aspect's `around` body references `call.elapsed`.

- **Precedent**: `Lyric.Stubbable` (D-progress-433) auto-injects
  `import Std.Testing.Mocking` when it synthesises stub records — the
  synthesised dependency is made explicit on the file, exactly as the
  contract elaborator makes its `assert(...)` calls visible in the AST.
  `Lyric.Weaver.injectWeaveImports` mirrors that pattern.
- **Why not fully-qualified calls**: the self-hosted backends resolve
  cross-package calls through the file's import list (`pkgImports` on MSIL,
  the bundler's import-closure walk on JVM).  A fully-qualified call without
  the import would resolve on neither target without new resolver surface;
  the explicit import keeps both resolution paths on their existing,
  well-tested rails.
- **Placement**: `weaveFile` / `weaveFileWithDiags` apply the injection
  internally (before the items pass, while the `IAspect` items that carry
  the `call.elapsed` references still exist).  The JVM bridge additionally
  calls `injectWeaveImports` immediately after parse in `compileToJar` and
  `compileToJarBundledWithFeatures`, because the JAR bundler computes the
  stdlib import closure from `file.imports` *before* the middle-end weave
  runs — injection inside the weave alone would leave `Std.Time` out of the
  bundle.  The items-only overloads (`weaveItems` / `weaveItemsWithDiags`)
  cannot inject (no import list); their doc comments state the caller
  obligation.
- **Instrumentation shape**: the prelude materialises
  `var __lyric_call_elapsed: Option[Int] = None`, and each `proceed(args)`
  rewrites to a block expression that captures
  `val __lyric_call_start = monotonicNanos()`, calls the target, assigns
  `Some(((monotonicNanos() - __lyric_call_start) / 1000000).toInt())`, and
  yields the result.  The block form keeps the capture exact in any
  expression position and guarantees `Some` is assigned iff `proceed`
  dynamically executed.  `monotonicNanos` (not wall-clock `now()`) so a
  clock adjustment mid-call cannot produce a negative duration.
- **`call.caller` stays unwired**: docs/26 §4.3 specifies it as "when
  available"; no caller-site capture exists, so references keep surfacing
  as A0043, whose message now names `call.caller` as unavailable instead
  of "not yet wired".

**Consequences.** Aspects that reference `call.elapsed` no longer fail with
A0043; the recognised-fields list in the A0043 message gains `elapsed`.  A
woven file may carry one import the author did not write — visible in
`weaveFile` output and documented in the language reference §14.7 and
docs/26 §4.3.

**MSIL is complete; JVM is plumbed but blocked on a pre-existing gap.** The
implementation lands fully on the MSIL target (the weaver self-test runtime
arms, the verifier driver, and an end-to-end `lyric build`/`run` program all
pass).  On the JVM target, `Std.Time.monotonicNanos` does not yet resolve
(a plain `import Std.Time` / `Std.Time.monotonicNanos()` program fails JVM
codegen with an auto-FFI miss, and `Std.TimeHost`'s `java.time.Duration.ZERO`
extern trips F0015-J), so a `call.elapsed` aspect on `--target jvm` now fails
loudly at build time (the JVM bundler marks `Std.Time` reachable, surfacing a
clear J002 error) rather than silently un-weaving.  The JVM `Std.Time`
support gap is pre-existing and broader than this issue; it is tracked under
the JVM production-readiness plan (docs/44) and issue #1298's JVM follow-up.

**Related:** #1298, #1172, #682, D-progress-433 (Stubbable precedent),
D-progress-507 (implementation), docs/26 §4.3 / §15, docs/44 (JVM gap).

---

## D101 — Const patterns retain `PConstRef` through to codegen rather than lowering to `PLiteral` at type-check (Q-MP-001, #3479)

**Date:** 2026-06-14
**Resolves:** Q-MP-001 (docs/06), review finding #3479.

**Context.** docs/46-const-patterns.md sketched the const-pattern feature
(`case @NAME ->`, D-progress-523) with the type checker *lowering* a
`PConstRef(name)` pattern to a `PLiteral` carrying the constant's value, so
that both backends would need no new pattern arm ("Codegen … no changes are
needed"). The shipped implementation deviated: the type checker
(`typechecker_exprs.l::checkConstRefPattern`) **validates** a `PConstRef`
(existence T0072, compile-time-constant T0069, monomorphic T0071, scrutinee
type match T0068) but leaves the `PConstRef` node in the AST, and each
backend grew an explicit `PConstRef` arm in its pattern-test lowering
(`msil/codegen.l::lowerPatternTestMsil`, `jvm/codegen/03_match.l`). #3479
flagged this as an unbacked deviation from the doc and noted the backend
arms' `case None ->` fall-throughs.

**Decision.** Keep the codegen-level `PConstRef` lowering; the
`PLiteral`-rewrite-at-type-check approach is rejected.

- **Why not rewrite to `PLiteral`.** Rewriting requires the type checker to
  reconstruct a literal AST node from a resolved constant value. For
  non-integer consts (`String`, `Float`, `Long`, `Char`) the value lives in
  a static field at runtime, not as an inline literal — the MSIL backend
  emits `ldsfld` against the const's static-value token and the JVM backend
  emits `getstatic`, neither of which a synthetic `PLiteral` can express
  without re-introducing the constant reference. Lowering would therefore
  only ever cover the integer case and force a second representation for the
  rest, which is strictly more code than one honest `PConstRef` arm per
  backend.
- **Diagnostics and spans.** Retaining `PConstRef` keeps the source-level
  name and span available to the exhaustiveness checker and to error
  messages (e.g. the Bool-exhaustiveness fix in #3488 resolves a
  `PConstRef` Bool const to decide `sawTrue`/`sawFalse`), which a
  pre-lowered literal would have discarded.
- **The backend `case None ->` paths are defensive, not silent.** Both
  backends `panic` with `"… (type checker should have validated)"` when a
  `PConstRef` reaches codegen whose name is absent from `constValues` /
  `staticValTokens` (MSIL) or `moduleVals` (JVM). This is an internal
  invariant assertion guarded by `checkConstRefPattern`, not a
  default-value swallow; it fails loudly if a future change lets an
  unvalidated const pattern through.

**Consequences.** docs/46 is corrected to describe the codegen-level
arms (the "no changes needed" claims and the `lowerPatternBind` "returns
`PError`" note were inaccurate). Exhaustiveness checking must be
`PConstRef`-aware (#3488).

**Related:** Q-MP-001, D-progress-523, #3479, #3468, #3469, #3488,
docs/46-const-patterns.md.

---

## D102 — Aspect weaving wires bare config-field references and merges `from`-instance config onto template defaults (#3543)

**Context.** Every first-party aspect library ships C-mode
`@inline_template` templates that consumers instantiate with a separate
`from`-instance carrying a `matches:` clause (the pattern documented in
§§4, 8). An audit found that woven aspects were inert or crashed at
runtime: the templates reference config fields **bare** (`minLen`), but
the weaver's `buildConfigPrelude` only materialised and rewrote the
documented qualified form (`config.minLen`); a `from`-instance's
`config { }` *replaced* the template's config wholesale, dropping fields
the instance did not mention (e.g. `enabled`, `field`); the template's
`@inline_template` marker was lost during `collectAspectTemplates` (which
stores only the `AspectDecl`), so `args.<field>` was not rewritten in
`from`-resolved aspects; and an unqualified same-package `from X` failed
the template lookup (registered under `pkg.X`, looked up as `X`).

**Decision.** The weaver (`lyric-compiler/lyric/weaver/weaver.l`) now:

1. Materialises and rewrites **bare** config-field references in addition
   to `config.<field>`. A bare name is resolved to the config field only
   when it is not a parameter of the matched function (parameters shadow;
   use `config.<field>` to disambiguate). Documented in docs/26 §7.
2. Merges a `from`-instance's `config { }` onto the template's config
   defaults (`mergeAspectConfig`) — instance values win, unmentioned
   template fields keep their defaults — rather than replacing wholesale.
3. Propagates the template's `@inline_template` marker onto the resolved
   instance (detected from the template body's `args.<field>` use) so the
   `args.<field>` rewrite runs for `from`-resolved aspects.
4. Resolves an unqualified single-segment `from X` against the consuming
   package (`pkg.X`) as a fallback after the as-written lookup misses.

**Validation.** `lyric-validation/tests/aspect_weaving_tests.l` is the
ecosystem's first runtime weaving regression suite (6 cases across four
instantiation forms: cross-package `from`, same-package unqualified `from`,
a direct `@inline_template` aspect, and a C-mode `from`-template that reads
`args.<field>` without referencing the ambient `call` — the #3592 case;
each asserts the woven handler short-circuits out-of-bounds input and
proceeds on valid input). It runs in the `ecosystem-security-tests`
CI job via the already-wired `lyric-validation` manifest.

**Out of scope (follow-up).** Defect 4 of #3543 — aspect templates that
live in a *restored dependency DLL* (not an in-bundle source package) are
still not collected, because the around-body source is not serialised into
contract metadata. Cross-dependency aspect *libraries* therefore remain
unwoven until the metadata carries aspect bodies; tracked in #3543.

**Related:** #3543, docs/26-aspects.md §7, docs/27-aspect-libraries.md, D047, D051.

---

## D103 — `Char` is a UTF-16 code unit (BMP scalar); non-BMP string escapes emit a surrogate pair (#3299, #3621)

**Date:** 2026-06-14
**Resolves:** Issue #3299; spec/implementation conflict raised in review finding #3623.

**Context.** The language reference §2.1 originally described `Char` as a
"Unicode scalar" and §1.4 showed `'\u{1F600}'` as a valid character literal.
In practice, both the F# bootstrap and the self-hosted compiler represent
`Char` as a 16-bit value (mapped to `System.Char` on .NET and Java's
primitive `char` on JVM), which can only hold code points in the Basic
Multilingual Plane (U+0000–U+FFFF, excluding the surrogate range
U+D800–U+DFFF).  The self-hosted lexer always rejected non-BMP escapes in
char literals with L0022.  Issue #3299 surfaced a parity gap: the self-hosted
lexer also rejected non-BMP escapes in *string* literals, while the F#
bootstrap accepted them (via `Char.ConvertFromUtf32`).

**Decision.** `Char` is formally defined as a **UTF-16 code unit (BMP
scalar)** — a value in U+0000..U+FFFF excluding U+D800..U+DFFF.  The
consequences are:

- **Char literals** (`'…'`) may only contain BMP scalars.  A `\u{…}` escape
  with a code point > U+FFFF is a compile-time error (L0022: "non-BMP unicode
  escape cannot appear in a char literal").  The correct alternative is a
  string literal.
- **String literals** (`"…"`, `"…${…}…"`, `"""…"""`) accept any Unicode scalar
  in `\u{…}` escapes, including non-BMP.  The lexer emits the corresponding
  UTF-16 surrogate pair into the token's text buffer so the resulting `String`
  round-trips correctly on both .NET and JVM.  No diagnostic is emitted.
- **String indexing** (`s[i]: Char`) returns individual UTF-16 code units, not
  decoded scalars; a non-BMP character occupies two consecutive indices.

**Why not widen `Char` to a full Unicode scalar?** That would require a wider
`TChar` payload in the lexer (currently `codepoint: Int`, sufficient for
full scalar range) *and* changes to every backend and stdlib that allocates or
compares `Char` values, since both .NET and JVM represent `char` as a 16-bit
value at the hardware level.  This is tracked as a future enhancement; until
then the BMP restriction is explicit, documented, and consistently enforced.

**Consequences.** The language reference §1.4 example is corrected from
`'\u{1F600}'` to `'\u{20AC}'` (Euro sign, BMP), and the type table entry for
`Char` is updated from "Unicode scalar" to "UTF-16 code unit (BMP scalar)".
The book appendix B quick-reference is updated to match.
`docs/10-bootstrap-progress.md` removes "non-BMP `\u{…}`" from the deferred
list for string literals.

**Related:** #3299, #3621, issue #3623 (review finding), §1.4 and §2.1 of
`docs/01-language-reference.md`, `docs/10-bootstrap-progress.md`,
`book/chapters/appendix-b-quick-reference.md`,
`lyric-compiler/lyric/lexer.l`.

---

## D104 — A0045 diagnostic for unresolved `from`-instance aspect templates (#3497)

**Context.** `weaveFileWithDiagsAndTemplates` resolves `from`-instance aspects
(those with `from: Some(path)` and no `around` body) by looking up the template
in the supplied `Map[String, AspectDecl]`. When the lookup misses — because
the template package is absent from the build or the path contains a typo —
the instance is passed through unchanged and the standard weave silently
drops it (it has no `around` body). The woven function is therefore never
wrapped; security-relevant templates that are silently unresolved are worse
than a compile error.

**Decision.** `collectUnresolvedFromDiags` scans the item list after
`resolveFromInstances` runs and emits an `A0045` error diagnostic for every
`from`-instance aspect whose template was not found:

```
A0045: aspect 'LoggedFoo' declares `from Lib.Tracing` but the template was
not found in the build; ensure the package that defines 'Lib.Tracing' is
listed in [dependencies] in lyric.toml
```

The diagnostic fires once per unresolved aspect item (not once per function
that would have been matched), referencing the aspect's declaration span.
`weaveFileWithDiagsAndTemplates` accumulates both A0045 diagnostics and the
existing A0042/A0043/A0044 diagnostics from `weaveItemsCore` into the
returned `WeaveFileResult.diagnostics`.

**Diagnostic range.** A0040–A0044 were assigned for existing weave
diagnostics (D047/D051). A0045 is the next unused code in that range.

**Related:** #3497, #3414, D102, D047, D051.

---

### D-progress-529 — F# runtime decommission complete: zero F# in the `lyric` runtime closure (#1576, #1489)

**Context.** D-progress-473 removed `Lyric.Emitter.dll` and `FSharp.Core.dll`
from the stage-1 bundle mechanically, but two stdlib kernel modules still
`@externTarget`-pointed into `Lyric.Emitter.*` host methods, keeping those
assemblies load-bearing for any program that imported `Std.Http` or
`Std.Process`:

- `http_host.l` → `Lyric.Emitter.HttpClientHost.defaultClient` — a
  module-level `pub val` of reference type (`HttpClient`), which the F#
  emitter's `EPath` handler emitted as `ldsfld`.  The self-hosted MSIL
  backend lacked the `ldsfld` emission path for reference-typed package-level
  `val` fields (issue #1576).
- `process_capture_host.l` → `Lyric.Emitter.ProcessCapture.captureProcess` —
  used concurrent async reads for stdout/stderr, which required the
  async state-machine synthesis to handle two concurrent `Task<string>` awaits
  racing on the same process handle (issue #1489).

Both were fixed on `main`:

- **#1576** — `EPath` handler in `Msil.Codegen` extended to emit `ldsfld` for
  reference-typed (`not isValueType`) module-level `pub val` fields, matching
  the F# emitter's behaviour.  `http_host.l` retargeted from
  `Lyric.Emitter.HttpClientHost.defaultClient` to a direct `extern package`
  declaration against `System.Net.Http.HttpClient` in
  `lyric-stdlib/std/_kernel/http_host.l`.

- **#1489** — async state-machine synthesis extended to handle the two-`await`
  concurrent-read pattern (`Task.WhenAll` + indexed result extraction).
  `process_capture_host.l` retargeted to direct BCL externs
  (`System.Diagnostics.Process`, `System.IO.StreamReader`) with the async
  concurrent-read body expressed in Lyric.

**Outcome.** A strings scan of every stage-1 Lyric DLL confirms zero
`AssemblyRef` entries to `Lyric.Emitter` or `FSharp.Core` across the full
stdlib and CLI closure.  The `Lyric.Cli.Aot` csproj carries no explicit
`FSharp.Core.dll` reference.  `make aot` succeeds with 0 warnings on
linux-x64 and win-x64.

**Decommission definition.** "F# decommissioned from day-to-day operations"
means:

1. **No user-initiated command invokes F# code at runtime.**  `lyric build`,
   `lyric test`, `lyric run`, `lyric fmt`, etc. all trampoline through the
   AOT entry point into Lyric-emitted DLLs.  The F# stage-0 compiler is not
   on the path.
2. **No Lyric program's runtime closure contains F# assemblies.**  Neither
   `Lyric.Emitter.dll` nor `FSharp.Core.dll` appear in any compiled output.
3. **The stage-0 F# bootstrap compiler is build-tool-only.**  It compiles the
   self-hosted `.l` sources in the CI bootstrap chain; a prior self-hosted
   release can substitute for it via Q-dist-001 (`scripts/bootstrap.sh` stage 2).
   It is closed to new code and on a deletion schedule (see §0 inventory).

**Related:** D-progress-473 (initial bundle cleanup), docs/23 (shim elimination
plan), docs/34 (distribution strategy), #1576, #1489, issue #3661 (ecosystem
lib split, Phase 6).

---

## D105 — `impl ExternInterface for Record` emits InterfaceImpl rows against the external TypeRef (docs/51)

**Context.** Lyric programs already implement *native* Lyric interfaces with
`impl Iface for Record { … }`, and `import extern` / `extern type` already let
a program *name* an external .NET type. But the natural composition —
`impl IDisposable for MyResource` — was a panic in the MSIL backend:
`implIfaceNameMsil` (`lyric-compiler/msil/codegen.l`) qualified the
single-segment interface name with the current package prefix
(`pkgName + ".IDisposable"`), so `lowerMImpl`'s TypeRef lookup
(`findTypeRefRowByName` for `MyPkg.IDisposable`) failed and the emitter
panicked. The plumbing was otherwise in place — `lowerMImpl` already
emits an `InterfaceImpl` row pointing at a `TypeRef` token when the
target is external (`lyric-compiler/msil/lowering.l:4046`), `addInterfaceImpl`
+ `InterfaceImplRow` exist (`lyric-compiler/msil/tables.l`), and the
self-hosted metadata reader already records `TypeDefRow.flags`
(`lyric-compiler/msil/metadata_reader.l:511`).

**Decision.** We treat external .NET interfaces as first-class `impl`
targets without new syntax.

1. **No syntax change.** An external interface is brought into scope via
   the existing `import extern System.{ IDisposable }` form (D116's `import extern`)
   or `extern type IDisposable = "System.IDisposable"`. Both already register
   a `DKExternType` symbol with the CLR FQN.
   `impl IDisposable for Record { … }` parses identically to a native
   `impl`; the AST does not distinguish targets.

2. **Codegen resolves the FQN via the existing extern-type table.**
   `implIfaceNameMsil` consults `cctx.externTypeNames` first; when the
   single-segment iface name matches an imported extern, the table's CLR
   FQN is emitted into the queued `MImplData.ifaceTypeName`. The
   external TypeRef row is reserved during `collectImplEntriesMsil` so
   `lowerMImpl`'s TypeRef lookup never fails. The CLR resolves interface
   method dispatch by name + signature matching against the implementing
   record's methods — no `MethodImpl` rows are required for non-generic
   interfaces, matching the native-interface emission path.

3. **Signature validation lives in a post-type-check FFI conformance
   pass, not in the type checker.** The type checker is intentionally
   backend-agnostic and does not load .NET reference assemblies
   (`typechecker_checker.l` imports only `Std.*` and `Lyric.Parser`),
   so `checkImplConformance` continues to silently skip extern targets
   for the same reason it skips cross-package interfaces. The FFI
   conformance pass — `validateExternImplConformanceMsil` in
   `lyric-compiler/msil/codegen.l` — runs after `collectImplEntriesMsil`
   (the TypeRef row is already reserved) and before lowering. It calls
   `Mdr.inspectInterfaceTarget(asmPath, ifaceFqn)`, which loads the
   reference assembly, locates the TypeDef, reads `ClassSemanticsMask`
   (bit 0x20), and decodes every `MethodDef` row's signature through
   `decodeMethodSig` + `resolveSigTypeFqn` so types compare by
   normalised FQN. Four diagnostics emit via the same `panic`-style
   surface F0015 uses:

   - `F0020` — `extern type` resolves to a non-interface (the
     `ClassSemanticsMask` bit is clear). The user wrote `impl Math for
     R` against `System.Math` instead of a real interface.
   - `F0021` — an abstract interface method (Virtual + Abstract bits
     set) has no matching Lyric impl method. C# 8+ default interface
     methods (Virtual only) are optional and skipped.
   - `F0022` — an impl method's parameter arity or Nth parameter type
     does not match the interface's MethodDef signature.
   - `F0023` — an impl method's return type does not match the
     interface's MethodDef return type.

   When the reference pack is absent (`assemblyForType` returns None),
   validation is skipped silently — mirroring F0015's fallback at
   `codegen.l:11793`. Validation also bails (silently, per method) on
   any signature that mentions a Var / MVar / GenericInst / ByRef /
   Array shape — those land with the generic-external-interfaces
   follow-up work. The trade-off is conservative: a real mismatch on
   a non-generic shape fails the build; richer shapes still fall
   through to the CLR loader at first use, same hazard as today's
   hand-rolled `extern func`.

4. **Generic external interfaces (`IEnumerable[T]`, `IEquatable[T]`),
   property/event naming conventions (`get_X`/`set_X`), and bridge-thunk
   synthesis** are explicitly deferred to a follow-up decision. Generic
   support requires routing the queued `MImplData` through `MTypeSpec`
   instead of a bare `TypeRef`, and explicit `MethodImpl` rows since
   the CLR cannot name-match through a TypeSpec. The non-generic slice
   here covers `IDisposable`, custom single-method callback interfaces,
   and the bulk of practical BCL interop needs. Until the full support
   ships, `validateNoExternGenericIfacesMsil`
   (`lyric-compiler/msil/codegen.l`) detects `impl ExternIface[T] for R`
   shapes and surfaces them as `F0024` — failing the build at the codegen
   layer rather than silently emitting an InterfaceImpl row whose
   TypeRef names the open generic type (which would never wire dispatch
   at runtime). The diagnostic is emitted before `validateExternImplConformanceMsil`
   so the user sees the more specific "not yet supported" message
   instead of the F0022/F0023 "parameter mentions a generic param"
   structural-mismatch noise.

**Consequences.**

- `IDisposable`, `IComparable`, `IEquatable` (non-generic), custom
  C#-defined callback interfaces, and any BCL interface whose methods
  are non-generic now work as `impl` targets.
- The verification path is "metadata-direct" — same code path the
  auto-FFI resolver uses for method calls. No extra dependencies, no
  reflection, AOT-safe.
- The decision stays compatible with future generic and
  property-convention work: `MImplData` already carries an `ifaceTypeToken`
  alongside `ifaceTypeName`, so the generic path will populate the
  token with a TypeSpec without disturbing the non-generic path.

**Related.** docs/51, docs/47 (`import extern`), epic #1622 (metadata-based
auto-FFI), `lyric-compiler/lyric/auto_ffi_self_test.l` (precedent for
metadata-direct tests).

---

## D-progress-530 — Constructor shorthand for extern types (.new syntax)

**Feature:** Enable direct constructor calls on external types via `.new(args)`
syntax (docs/48), eliminating boilerplate `@externTarget` wrapper functions and
aligning MSIL behavior with the JVM backend.

**Status:** Shipped in self-hosted MSIL backend (M5.4).

**Implementation.**

The MSIL codegen in `lyric-compiler/msil/codegen.l` detects when the method
name is `"new"` on an `extern type` and routes to constructor resolution instead
of regular method lookup. The implementation reuses the Phase 3c auto-FFI
metadata resolution and overload-scoring infrastructure:

1. **Metadata lookup** — `tryAutoFfiFromMetadata` translates `"new"` to `".ctor"`
   when querying the metadata index, unifying constructor lookups with the
   existing method-resolution path.

2. **Overload resolution** — The metadata resolver finds the best-matching
   constructor via the same overload-scoring logic as regular methods (exact
   parameter match, widening conversions, etc.).

3. **IL emission** — For constructors:
   - Emit `newobj` instead of `call`
   - Use `buildInstanceMethodSig(paramMsil, MVoid)` (HASTHIS calling convention,
     void return) to match the ECMA-335 `.ctor` signature
   - Override the result type to `clrFqn` (the constructed type) instead of
     the method's void return signature

4. **Value-type rejection** — Constructors for value types (System.DateTime,
   System.Guid, etc.) have different construction semantics (initobj vs newobj)
   and are detected from metadata and rejected, falling back to the legacy path
   for a clear error message. Proper support is tracked as Q48-004.

**Tests.** A new `@test_module` (`lyric-compiler/msil/msil_self_test_m88.l`)
covers the three important overload paths: zero-arg constructor
(`SBld.new()`), single-argument (`SBld.new(capacity)` with capacity widening),
and multi-argument overload resolution (`SBld.new("hello")`).  Tests assert
real runtime behavior via auto-FFI instance property access (sb.Length,
sb.Capacity).  The test is wired into CI.

**Known limitations.**

- **Q48-004** — Value-type constructors are hardcoded as reference types (valueType = false).
  The proper fix requires querying the metadata index to detect whether a type is
  a value type and using `initobj` instead of `newobj` for those cases.  Until
  that infrastructure is in place, users of value-type constructors must use
  `@externTarget` wrapper functions.

**Related:** docs/48 (design), docs/01 §11.4 (language reference), docs/42
(Phase 3c metadata resolution), epic #1622 (auto-FFI), #3732 (PR).

---

## D-progress-531 — Self-hosting fixpoint HOLDS: stage-2 toolchain runs, stage-3 byte-reproducible (supersedes the D111 "remains gated" note)

**Status:** Verified. The stage-2 *self-hosted-built* toolchain
(`.bootstrap/stage2/bin/lyric`) builds and runs every command (including
`opaque type` programs), and `scripts/bootstrap.sh --stage 3` reports the
reproducibility fixpoint holding: the whole self-hosted compiler closure
(**101/101 DLLs**) and `Lyric.Stdlib.dll` re-emit **byte-for-byte identical**.
(The 101 is the same `--internal-perpackage-build` `Lyric.Cli`-closure
measurement — compiler packages plus their *transitive* stdlib imports — that
D-progress-502 recorded as 103/103 on 2026-06-11; the two counts differ only
because that import closure drifted by two packages over the intervening weeks,
not because of a different build path. It is distinct from the 122 DLLs
`build_stage2` emits, which additionally include every *public* `Std.*` package
from `lyric.full.toml`, not just `Lyric.Cli`'s import closure.)
This records a milestone that landed but was left undocumented; it supersedes the
D111 keystone note's "full stage-2 self-hosting remains gated by the separate
parser bug" and the docs/41 §R7 "stdlib self-compile blocked on front-end
completeness" caveat (for the emission/runnability axis).

**The "separate parser bug" was the per-package nullary-singleton mis-detection,
fixed in #4020.** The D111 keystone note flagged a self-hosted parser miscompile
that hung the stage-2 binary. Root cause (confirmed by re-deriving it from a
hang-state managed-stack sample → `Lyric.Parser.skipStmtEnds` ← `parseItemOpt`
looping on `opaque type`): `opaque type` is the only item whose leading keyword
is consumed via `tryEatKw` (a value compare through `isKw` → `object.Equals`)
rather than an unconditional `advance`. The self-hosted emitter gives nullary
union cases no structural `Equals`, relying on a shared static `Instance`
singleton for reference-equality. The restored-union registration decided whether
to load that singleton (vs `newobj` a fresh instance) using an **arity-suffix
proxy** that returned false for `Lyric.Lexer` — self-hosted-emitted, ~130
`Instance` singletons, but no generic TypeDef — so `Lyric.Parser` built
`new Keyword_KwOpaque()` that never `Object.Equals`'d the lexer's token keyword,
and `parseItems` re-dispatched the same `opaque` token forever. #4020 replaced
the proxy with a direct `Instance`-field scan (`dllNullaryInstanceInfo` /
`imageNullaryInstanceInfo`, which additionally records the CLASS-vs-OBJECT
field-sig convention so restored MemberRefs match the producer DLL). The single
`Lyric.Compiler.dll` bundle (D112) never hit this — in-bundle the singleton is
loaded directly — which is why the compiler self-tests stayed green throughout.

**Verification.** `bootstrap.sh --stage 3` (LYRIC_BOOTSTRAP_MINT): "Stage 2
toolchain RUNS — lyric 0.1.0"; "whole self-hosted compiler closure is
byte-for-byte reproducible (101/101 DLLs)"; "Lyric.Stdlib.dll … byte-for-byte
reproducible"; "Stage 3 … fixpoint holds". Stage-2 `lyric run` on an
`opaque type` program prints and exits 0. The remaining docs/41 bands (soundness
floor, async, etc.) are feature/soundness completeness, not self-host
runnability.

**Related:** #4020 (the Instance-detection fix), D111/D112 (stdlib + compiler
bundle collapse), #3920 (the original cross-package nullary-case blocker),
docs/41 §R7, `scripts/bootstrap.sh` stage-2/3 comments.

---

## D107 — `@externTarget` functions returning `Option[T]` coerce a nullable BCL reference to `None`/`Some` at the call boundary

**Status:** Accepted (Phase 1: MSIL emitter convention shipped; Phase 2:
stdlib migration + `case null` removal deferred).

**Context.** Many BCL methods return a nullable reference (e.g.
`System.Environment.GetEnvironmentVariable: string?`,
`System.Console.ReadLine: string?`, `System.IO.Path.GetDirectoryName:
string?`). The self-hosted compiler has no `null` literal or nullable-match
support, and the audited `_kernel/` boundary historically modelled these with a
`String?` extern return matched by `case null` — a construct the self-hosted
front-end silently miscompiles (the `case null` arm parses as a catch-all
binding, so the null test is dropped and e.g. `getVar` always returns the
no-value branch). The goal is to consume nullable BCL APIs **without** adding a
`null` literal or nullable type to the language.

**Decision.** When an `@externTarget` function (non-ctor, non-async) declares its
return type as `Option[T]` with `T` a reference type, the MSIL emitter binds the
MemberRef to the BCL's real nullable reference return `T` and emits a coercion
immediately after the call: a null reference becomes `None`, a non-null
reference becomes `Some(value)`. `Option`/`Some`/`None` are constructed with the
existing generic-case constructor machinery (`buildGenericCaseCtorTok`), the same
path `mapGet` uses. This keeps the entire surface above the audited boundary on
`Option[T]` — matched with ordinary `case None`/`case Some(v)`, which the
self-hosted compiler fully supports — and needs no `null` in the language.

**Why an emitter convention and not a new builtin.** A typecheck-visible builtin
(e.g. `isNull`) used by the stdlib breaks the bootstrap: the frozen seed
compiler (which compiles the stdlib transitively imported by the compiler) does
not know the new name and rejects it. The `Option[T]` return convention adds no
new name — the seed typechecks the stdlib signatures unchanged — so the new
behaviour lives entirely in the self-hosted emitter and is bootstrap-safe.

**Phasing.** Phase 1 (this entry) ships the emitter convention plus a wired
self-test (`lyric-compiler/lyric/extern_option_self_test.l`); the stdlib is
unchanged so the current seed keeps building it. Phase 2 — after a release
carrying this convention becomes the seed — migrates the `_kernel/` nullable
externs (`environment_host`, `console_host`, `path_host`) to `Option[T]` returns
and removes the `case null` usages, completing the null-free FFI boundary. JVM
emitter parity is tracked in #3932 (Phase 1 is MSIL-only).

The convention is matched in the emitter via the codegen's own `MsilType` union
(an `MVoid` "no coercion" sentinel), **not** a locally-constructed
`Std.Core.Option`: returning/matching an in-package `Option` from the FFI hot
path fell through both arms (an in-package Option-identity hazard), corrupting
the bound return type of every `@externTarget` in the function.

**Related:** docs/14 (native stdlib / extern boundary), docs/42 (metadata
resolution), docs/01 §11.3 (`@externTarget` reference), D105 (extern
interfaces), D117 (constructor shorthand).

---

## D108 — `[nuget]` entries are allowed in all manifests; no application-manifest restriction

**Status:** ACCEPTED

**Context.** `docs/38-workspace.md` §8 speculated about prohibiting `[nuget]`
/ `[platform.dotnet]` entries in application manifests (executables), on the
theory that all NuGet boundary code should live behind Lyric wrapper libraries.
Q-W-001 asked how a developer would consume an arbitrary NuGet package that has
no Lyric wrapper yet, noting that requiring a wrapper adds ceremony.

**Decision.** `[nuget]` (and its future rename `[platform.dotnet]`) is allowed
in any Lyric manifest — library or application — without restriction.
Application code that needs an unencapsulated NuGet package declares it in its
own `[nuget]` table directly. The "prohibit in executables" enforcement,
`@unsafe_native` escape-hatch design, and the forced `lyric migrate --workspace`
codemod path (Q-W-004) are all dropped.

**Rationale.**
- The Lyric ecosystem is early: most NuGet packages do not yet have Lyric
  wrappers, and blocking application developers from using the underlying
  packages would make the language impractical.
- The transitive propagation benefit (docs/38 §4) still applies once wrapper
  libraries exist — applications that depend on `Lyric.Grpc` do not need to
  re-declare `Grpc.Net.Client`. The restriction only provided value at the margin
  of a fully-wrapped ecosystem.
- The escape-hatch design (`@unsafe_native`) reliably becomes the norm before
  any enforcement value is realised — the language spec should not encode
  ecosystem-maturity-dependent enforcement rules.

**Implications.** Q-W-003 (rename `[nuget]` → `[platform.dotnet]`) and Q-W-004
(migration codemod) are moot given this decision. Q-W-002 (published manifest
format for transitive NuGet graph reconstruction) remains open and unaffected.

**Related:** docs/38-workspace.md §8, docs/39-package-registry.md §9, D073.

---

## D109 — SDK version check at CLI startup (Q-dist-007)

**Status:** ACCEPTED

**Context.** `docs/22-distribution-and-tooling.md` §5 specifies a
`Lyric.SdkVersion` embedded resource inside `Lyric.Stdlib.dll` carrying
`language_version`, `stdlib_version`, `compiler_version`, and `build_date`.
Q-dist-007 tracked the unimplemented check: at CLI startup, read the version
resource and warn (or error) when the stdlib DLL was built by a different
compiler version.

**Decision.** The version check is implemented as `checkSdkVersion()` in
`lyric-compiler/lyric/cli/cli_shared.l`, called from `cli_main.l` after the
early-exit flags (`--version`, `--help`, internal flags) and before command
dispatch.

**Implementation details.**
- Rather than reading an embedded PE resource (which requires PE parsing), the
  check reads a companion JSON file `sdk-version.json` placed beside
  `Lyric.Stdlib.dll` by the build pipeline.  This avoids a dependency on the
  metadata reader just for the startup check.
- Format: `{"language_version":"0.1","stdlib_version":"0.1.0","compiler_version":"0.1.0","build_date":"..."}`.
  Written by `make lyric` (Makefile) immediately after the stage-1 stdlib build.
- A missing `sdk-version.json` (dev builds, CI environments before the file
  was introduced) is silently ignored — the check is best-effort and must not
  break existing workflows.
- A mismatch prints a warning to stderr: `warning: SDK version mismatch: ...`.
- `LYRIC_STRICT_SDK_VERSION=1` converts the warning to a hard error (exit 1),
  for CI environments that want to enforce alignment.

**Relation to `Lyric.SdkVersion` resource.** The embedded-resource form
described in docs/22 is not yet implemented (requires PE writer involvement in
the stdlib build).  The `sdk-version.json` side-file is the interim mechanism;
the embedded resource form can be layered on top later without changing the
CLI's observable behaviour.

**Related:** docs/22-distribution-and-tooling.md §5, docs/34-distribution-strategy.md §5, D059.

---

## D110 — Isolated per-stage toolchains; stage 2 (true-builds-true) is the ship/test toolchain; reproducibility is a non-blocking diagnostic

**Decision.** The self-hosting build is organised into four stages, each a
**complete, self-consistent toolchain for ONE compiler generation**, written to
its own isolated root and never co-mingled with another generation's artefacts:

- **Stage 0** — acquire a *seed* binary (downloaded self-hosted release, or the
  minted F# bootstrap from git history). Output `.bootstrap/stage0-publish/`.
- **Stage 1** — the seed compiles the current true-compiler sources into a
  *runnable* true compiler + the smoke stdlib needed to run it. Output
  `.bootstrap/stage1/` (flat). Intrinsically **ABI-mixed** (its own runtime
  stdlib is seed-emitted/non-arity-suffixed while the code it *emits* is
  arity-suffixed), so it is a **build-only** toolchain, not a ship/test one.
- **Stage 2** — the stage-1 true compiler rebuilds **itself + the full stdlib**
  into an isolated, self-consistent root `.bootstrap/stage2/{lib,bin}` via a
  single `--internal-perpackage-build` over a driver importing `Lyric.Cli` plus
  every public `Std.*` package. Every compiler and stdlib package is emitted
  per-package, arity-suffixed, and mutually consistent. **This is the toolchain
  everything is tested against and that ships.**
- **Stage 3** — reproducibility fixpoint: stage 2 emits the stdlib bundle and
  its own closure twice; the images must be byte-identical (`cmp`).

**Runnability-first inversion.** The gating property is "**the true compiler
builds AND runs everything**", not "two stages are byte-identical". Building the
stage-2 toolchain is the runnability gate: when the self-hosted emitter has a
bug, the per-package emit may still succeed but the AOT-linked binary faults at
startup — that surfaces as a **clean, specific failure** (a real emitter bug to
fix) instead of being masked by build-system noise. The byte-for-byte
reproducibility check (Q-dist-001) moves to stage 3 as a **non-blocking
diagnostic** (`SKIP_VERIFY`-gated), reported but never fatal, and skipped with a
"pending" note while the stage-2 toolchain is not yet runnable.

**Resolution contract.** A toolchain pins its **own** stdlib: tests/CI set
`LYRIC_STDLIB_BIN=.bootstrap/stage2/lib` to select the stage-2 generation, with
no cross-generation fallback. The stage-2 binary's `bin/` co-locates its stdlib
so it also resolves with zero configuration. This is the target that replaces
the previous silent-fallback chain and the `userlib/` ABI-sniff / `selfhosted/`
staging hacks (which existed only because stage 1 mixed a seed-emitted
non-suffixed stdlib with self-hosted patches — a second ABI that stage 2
eliminates by construction). Removing those fallbacks from the CLI source
(`cli_shared.l` / `emitter.l`) is a tracked follow-up.

**Stdlib packaging — single DLL is the target (aligned with distribution).**
The current self-hosted emitter writes cross-assembly references to stdlib types
under **per-package assembly names** (`[Lyric.Stdlib.Core]Std.Core.Option`), so
each `Std.X` must deploy as its own `Lyric.Stdlib.X.dll` for those references to
resolve at runtime (.NET resolves a TypeRef by `(assembly identity, type
name)`). That per-package form is a **bootstrap-era artefact**, and it conflicts
with the distribution strategy (docs/22 §2, docs/34), which mandates a **single
`Lyric.Stdlib.dll`** in `lib/` carrying every package's `Lyric.Contract.<X>`
resource — explicitly *replacing* the ~25 per-package DLLs. The decision is to
**collapse stdlib to that single DLL**: change the emitter's stdlib reference
convention so stdlib types resolve to the single assembly identity
`Lyric.Stdlib` (drop the `stdlibAssemblyName → Lyric.Stdlib.<X>` mapping in
`codegen.l`), after which one `Lyric.Stdlib.dll` satisfies both compile-time
(the contract resources) and runtime (the type definitions). This does *not*
make stdlib an inconsistent special case: the compiler's own `Lyric.Lyric.*` /
`Lyric.Msil.*` packages stay per-package because they are **build intermediates
AOT-linked into the `lyric` binary**, never distributed, whereas the stdlib is a
**distributed artefact** user programs link. The emitter reference-convention
change is a tracked follow-up (it is a `.l` change, verifiable only against a
runnable self-hosted toolchain or CI's emitter — currently gated by the
arity-suffix blocker below). Until it lands, `build_stage2` emits the stdlib
per-package because that is the only form the current emitter references; it
switches to the single bundle (`lyric.full.toml` `output = "single"`) once the
convention changes, with no bootstrap-stage changes required.

**Status (2026-06-23).** Implemented in `scripts/bootstrap.sh` (`build_stage2`,
`stage3`, isolated `.bootstrap/stage2/{lib,bin}`) and `Makefile`
(`stage2`/`stage3`/`run-stage2`). Verified end-to-end via the minted seed:
stage 2 emits 123 self-hosted DLLs and the runnability smoke surfaces the real
blocker non-fatally — `System.TypeLoadException: Could not load type
'Std.Core.Option' from assembly 'Lyric.Stdlib.Core'` (the docs/43 arity-suffix
mismatch: consumer references `Option`, producer defines `Option`1` — right
assembly, wrong type name). The CLI strict-resolution cleanup and the CI
restructure onto the stage-2 artifact are tracked follow-ups; they require a
runnable self-hosted toolchain (or CI's emitter) to verify, which the surfaced
blocker currently gates.

**Related:** docs/41 / docs/43 (arity-suffix self-host gaps), D059, Q-dist-001.

---

## D111 — Single-DLL stdlib emitter collapse implemented; `usesAritySuffix` detection removed

**Decision (implements the D110 follow-up).** The self-hosted MSIL emitter now
references every `Std.*` type under the **single `Lyric.Stdlib` assembly
identity** instead of per-package `Lyric.Stdlib.<X>`. `stdlibAssemblyName`
(`codegen.l`) returns `"Lyric.Stdlib"` for all `Std.*` packages; one deployed
`Lyric.Stdlib.dll` (the `output = "single"` bundle from `lyric.full.toml`,
carrying every package) satisfies every stdlib reference at runtime. This is the
distribution-mandated shape (docs/22 §2, docs/34). Compiler packages
(`Lyric.<X>`) keep per-package names — they are build intermediates AOT-linked
into the binary, not distributed.

**`usesAritySuffix` removed.** With stdlib always the single self-hosted-emitted
bundle, the two-ABI detection that probed the installed `Lyric.Stdlib.Core.dll`
is vestigial: the emitter unconditionally emits the self-hosted (arity-suffixed)
convention. Removed `detectStdlibCoreDllUsesAritySuffix`, `findCoreDllPath`,
`findCoreDllInDir`, `walkUpForCoreDll` (and the `usesAritySuffix` parameter
threaded through `registerStdlibArtifactTokens` / `registerStdlibTypeItem` /
`registerStdlibFunc`, including the F#-only `xrefUnitArgsToValueTuple` return
branch). `coreDllHasAritySuffixTypeDef` / `dllHasNullaryInstanceField` are
**kept** — they still detect the convention of restored *non-stdlib* artifacts
(the F#-emitted compiler closure linked by the self-tests in the mint path); they
become vestigial only when the F# mint seed is retired.

**Bundle completeness.** `lyric.full.toml` was missing three kernel packages the
compiler uses (`Std.UnicodeHost`, `Std.CollectionsHost`, `Std.VerifierEnvHost`);
added so the single bundle covers the whole compiler closure. `build_stage2`
(`bootstrap.sh`) now builds the single bundle into `.bootstrap/stage2/lib`.

**HTTP/async hybrid carve-out (#4030).** The HTTP/async surface — `Std.Http`,
`Std.HttpServer`, `Std.Rest`, `Std.Task`, `Std.HttpHost` — is **not** in the
single bundle: the self-hosted emitter cannot yet emit these async-`Task` /
`Result`-heavy packages into the `output = "single"` assembly (Phase A
undercounts a cross-package `match await`, and a bundled `HttpServer` emits
invalid IL). They ship **per-package** (`Lyric.Stdlib.<X>.dll`, deployed by
`stage-selfhosted-stdlib.sh`), and `stdlibAssemblyName` keeps their references on
the `Lyric.Stdlib.<X>` identity via a small denylist. They build and run
correctly per-package (as they did pre-collapse); the cross-package
`EMatch`-await Phase-A gap was fixed in passing (`collectAwaitTypesExprPB` now
walks `match`). Re-bundling them is tracked in #4030.

**Keystone effect.** The collapse *also fixes the stage-2 self-hosting startup
blocker* from D110: the `Std.Core.Option` TypeLoadException was the per-package +
suffix-detection mismatch. With the collapse, the stage-2 self-hosted binary
**starts and runs the compile pipeline** (it no longer faults at load). The next
surfaced blocker is a separate self-hosted **parser** miscompile (`P0040` on
function bodies) — exactly the deeper bug the runnability-first model is meant to
expose; tracked separately.

**Verification.** Clean-room verified via the minted seed: a user program now
references only `[Lyric.Stdlib]`, links the single bundle, and runs correctly;
the whole compiler still type-checks and the compiler binary starts. The stage-2
binary builds and starts (the Option blocker is gone); full stage-2 self-hosting
remains gated by the separate parser bug.

**UPDATE (superseded in part by D-progress-531):** "full stage-2 self-hosting
remains gated by the separate parser bug" is no longer true. That parser bug was
the per-package nullary-union-case `Instance`-singleton mis-detection (fixed in
#4020); the stage-2 toolchain now runs and the stage-3 reproducibility fixpoint
holds (101/101 closure DLLs + stdlib byte-identical). See D-progress-531.

**UPDATE (#4030 resolved — D-progress-533):** The HTTP/async hybrid carve-out is
now retired. Two root causes were fixed: (1) `Std.Http` was listed before
`Std.HttpHost` in `lyric.full.toml`'s Tier 4.5 block, causing Phase A
`collectAwaitTypesPhaseBMsil` to undercount cross-package `EAwait` points and
produce `ArgumentOutOfRangeException` at `pbc.resumeLabels[N]` — fixed by
reordering (commit 89a34be); (2) `isLiteralI4ExprMsilWithEnv` returned `true` for
the `ELiteral(LUnit)` init of `@asyncLocal val __ambientSlot`, so no `.cctor` row
was counted and the field was emitted as `null` — fixed by detecting `@asyncLocal`
annotations in both the pre-scan and `codegenMPackage`, synthesising
`newobj AsyncLocal<object>..ctor()` and extending `boxTypeRef` / `emitGenericExternMember`
to emit `unbox.any` when `get_Value()` returns an erased value type (commit
45a88ab, issue #2972). `Lyric.Stdlib.dll` now carries the full HTTP/async surface
and the per-package hybrid is retired. See D-progress-533 for details.

**Related:** D110, docs/22 §2, docs/34, docs/43.

---

## D112 — Self-hosted compiler self-tests link a single `Lyric.Compiler.dll` bundle

**Context.** D111 collapsed the stdlib to one assembly and unblocked stage-2
startup, surfacing the next blocker it named: the self-hosted-emitted **compiler**
mis-parses its own input. Root-caused (docs/41 §R7) to the **per-package
cross-package emission** path: when the self-hosted emitter compiles each compiler
package into its own `Lyric.<Pkg>.dll` and threads the others as restored deps,
cross-package type references corrupt across the assembly boundary — a
self-hosted-emitted `Lyric.Parser` produces per-token `IError` garbage even on
`package P`. The same closure built as **one assembly** parses correctly
(in-bundle references are internal, never crossing the boundary).

**Decision.** Compiler self-tests link the self-hosted compiler as a **single
`Lyric.Compiler.dll` bundle** — the compiler analogue of D111's stdlib bundle.

- **Producer.** `Emitter.emitCompilerBundle(entrySource, outPath, Dotnet)`
  (`emitter.l`) reuses `loadCompilerPayloads` (multi-file discovery, import-closure
  filtering, topo-sort) and emits the whole `Lyric.Cli` closure into ONE
  `output = "single"` assembly named `Lyric.Compiler`. `Std.*` imports resolve
  from source and are referenced externally as `Lyric.Stdlib`. Driven by the
  internal CLI flag `--internal-compiler-bundle-build <entry.l> <outPath>`.
- **Consumer.** `compilerClosureDllPaths` prefers
  `<libDir>/selfhosted/Lyric.Compiler.dll` when staged, threading it as a
  **single** restored-dep entry. `loadRestoredPackage` yields one artifact per
  `Lyric.Contract.<Pkg>` resource in the bundle; `assemblySimpleNameFromDll`
  derives every `AssemblyRef` from the bundle's file stem (`Lyric.Compiler`), so a
  self-test resolves a self-consistent compiler from the one file with **no
  `stdlibAssemblyName` change** for compiler heads.
- **Staging.** `stage-selfhosted-compiler.sh` builds the bundle via the new flag
  and deploys `Lyric.Compiler.dll` into each `selfhosted/` dir (replacing the
  per-package `--internal-perpackage-build` staging).

**Why not fix per-package emission directly.** The single bundle gets the
self-tests green now (path A); fixing the per-package cross-package corruption
(path B) is still required for **external dependencies** (genuinely separate
assemblies) and is tracked separately. `--internal-perpackage-build` is retained
as the R7 front-end-completeness gate ("Whole compiler self-host-compiles").

**Verification.** Clean-room via the minted seed: the whole compiler builds into
one 3.6 MB `Lyric.Compiler.dll`; the `parser` self-test (corrupt under
per-package) passes 67/67 against the bundle, alongside `typechecker` (235),
`modechecker` (30), `contract_elaborator` (30), and others.

**Related:** D110, D111, docs/41 §R7, docs/43.

---

## D113 — Closure class synthesis for zero-overhead lambda captures (Epic #1877 Phase 2)

**Status:** ACCEPTED

**Decision:** Lambda closures are synthesized as strongly-typed closure records
(Lyric structs) with typed fields matching the captured variables, eliminating
the pre-Phase-2 uniform `object[]` array fallback and enabling zero-allocation
captures for value types (Int, Bool, Char, etc.) without boxing.

**Key mechanisms:**
- **Capture analysis:** `computeHoistedVarNamesJvm` / `collectMutableVarsBlock` (JVM)
  and equivalent MSIL pre-passes identify which closure captures are mutable (need
  by-reference cells).
- **Closure class generation:** `synthesizeClosureClassMsil` emits a record type
  with typed fields for each capture. Mutable captures become typed array cells.
- **Hoisted cell slots:** Mutable captures are stored in strongly-typed array cells
  (`MArray[T]`) so by-reference semantics work without boxing the array itself.
- **Dual-target:** Both MSIL and JVM backends generate identical closure class
  layouts, verified by the `closure_zero_overhead_self_test.l` corpus.

**Alternatives considered:**
- Keep the uniform `object[]` fallback. Rejected: defeats the zero-overhead goal.
- Generate closure classes at AST lowering time. Rejected: capture analysis requires
  full type information (only available post-type-check).
- Per-call-site specialized Func/Action types. Rejected: explosion of synthetic types.

**Rationale:**
- Typed closures enable JIT and AOT compilers to avoid boxing value-type captures,
  reducing memory pressure and GC churn for high-frequency lambda-heavy code.
- By-reference cell array design allows mutation semantics without forcing boxing
  of the entire closure; the cell is the array element, not the closure itself.
- Dual-target test corpus ensures behavioral parity across MSIL and JVM without
  platform-specific surprises.

**Verification:** The closure test corpus (`closure_zero_overhead_self_test.l`)
covers 16 cases: primitive captures, escaping closures (returned to caller),
by-ref mutation, multi-level nesting, and closure-returning-closure patterns.
All cases run identically on both MSIL and JVM targets.

**Related:** Epic #1877, docs/09-msil-emission.md, docs/18-jvm-emission.md.

---

## D114 — B′-mode: weaver-native shape-cache specialisation for cross-package aspect library templates (docs/55, Q-aspectlib-001 revision)

**Status:** ACCEPTED

**Context.** Q-aspectlib-001 (2026-05-08 revision, `docs/27-aspect-libraries.md`
§6) resolved the library aspect ABI as "hybrid B + C": a `pub aspect` without
`@inline_template` ships as B-mode, described there as *"a generic method in
the library DLL"* — a reified CLR open generic method (`MVAR`-typed,
`MethodDef`-owned `GenericParam` rows) instantiated per consumer. That
framing overclaimed: the self-hosted MSIL backend reifies generic *types*
only (`docs/43` GenericParam table 0x2A), never generic *methods* — there is
no `MVAR`/`MethodDef`-`GenericParam` emission path for any generic function,
aspect or otherwise (`docs/43` Q-GEN-002). Building that epic only to unblock
aspects would be backwards (docs/55 §2). Consequently, only C-mode
(`@inline_template`, source-template re-inlining) ever shipped; B-mode
templates that avoided `args.<field>` happened to compile (the weaver
inlined their body per matched function just like C-mode, minus the
`args.<field>` rewrite pass) but got **no dedup** — every match recompiled a
full copy of the body, the exact per-use-site cost B-mode was supposed to
avoid.

**Decision.** Ship **B′-mode** (docs/55): a monomorphisation-based variant
that gets B-mode's zero-boxing/type-safety/dedup properties using
infrastructure that already exists, explicitly **not** attempting reified
generic methods.

- **Contract metadata (Phase 0).** `ContractDecl` gains an additive `bmode:
  Bool` field (format v3, no version bump; absent in JSON defaults to
  `false`). `Lyric.ContractMeta.buildContractFromFile` now embeds **every**
  `pub aspect` with an `around` body — not only `@inline_template` ones —
  tagging B′-mode (`not hasInlineTemplateAnnotation`) vs C-mode.
- **Weaver ground truth (Phase 1).** `collectAspectTemplates`'s value type
  changes from bare `AspectDecl` to `CollectedTemplate { decl,
  isInlineTemplate }`, capturing the declaring `Item`'s actual
  `@inline_template` annotation at collection time. This replaces a
  pre-existing **heuristic**: `resolveFromInstanceItem` used to guess
  "was this template `@inline_template`?" from body content alone
  (`aspectTemplateIsCMode` — does the body read `args.<field>`?), silently
  auto-promoting any `args.<field>`-using template to C-mode regardless of
  whether the annotation was actually present. That heuristic is now
  reserved for a new diagnostic, **A0046**: a `from`-instance resolving to a
  template that is *not actually* `@inline_template` but *does* read
  `args.<field>` fails closed with a clear error instead of being silently
  reclassified — B′-mode's `args` is opaque (docs/27 §6.1.1) by contract,
  not by accident.
- **Shape-keyed specialisation (Phase 2).** A resolved `from`-instance whose
  template is not C-mode routes through a new weaver-native cache
  (`weaver.l` §8b) instead of `buildWrapper`'s per-match inlining: one
  ordinary (non-generic) specialised function per distinct `(TArgs, TRet)`
  shape, shared across every matched function and every `from`-instance of
  that template in the file. Ambient `call.<field>` values and `config
  .<field>` values — baked as literal-valued preludes for C-mode/local
  aspects — become real parameters instead: a single canonical
  `__LyricBModeCallContext` record (covering every `call.<field>` field) and
  a per-template `__LyricBModeCfg_<template>` record (fields = exactly the
  `config.<field>` names the template body references, so per-instance
  config overrides can never change the record's shape). `proceed` becomes a
  real `(T1,...,Tn) -> TRet` closure parameter — the strongly-typed lambda
  ABI (D113) — rather than a static call substitution; `rewriteBlock`'s
  existing `proceed(args) -> callTargetName(p1,...,pn)` substitution needed
  **no changes**, since it already just emits a call to whatever identifier
  `callTargetName` names, and a lambda-bound parameter name works
  identically to a real function name there.
- **Not routed through `Lyric.Mono`.** Despite docs/55's own framing citing
  `Lyric.Mono` as the reuse target, the shape cache is implemented natively
  in `weaver.l`, not via `monoFileWithImports`. `Lyric.Mono` specialises a
  genuinely generic (`TVar`-typed) function AST at a call site; an aspect
  `around` body is never itself generic-typed AST — the "genericity" is a
  weave-time fiction over the matched target's shape, with no type
  parameters ever appearing in the parsed body. Reusing Mono would mean
  synthesising a fake generic `FunctionDecl` purely to hand it to a
  specialiser built for real generics, for no behavioural gain over a direct
  shape-keyed cache. The weaver-native cache gets the identical "one
  specialised copy per distinct shape" guarantee with less machinery.
- **Codegen (Phase 3/4).** No new MSIL or JVM emitter primitives: Phase 2's
  specialised functions are ordinary `FunctionDecl` items: the existing
  backends already compile lambdas (D113), record construction, and plain
  function calls. Confirmed by the same self-hosting build (stage 1 mint +
  stage 2 self-host) that validates every other self-hosted-compiler change.
- **Ecosystem (Phase 5).** No ecosystem code changes needed: `lyric-logging`'s
  `CallLogging` / `SlowCallAlert` (`lyric-logging/src/logging_aspects.l`)
  were already written B′-mode-shaped (no `@inline_template`, no
  `args.<field>` access, already doc-commented "(B-mode)") — they were
  simply unreachable via a real dedup path until this change; they now
  route through it with no source edits.
- **Q-aspectlib-001 revision.** The "Resolved: hybrid B + C" note
  (2026-05-08) is corrected: B/C were resolved at the *spec* level then;
  B-mode's *implementation* is B′-mode, landed here. `docs/27` §6.1's "ships
  as a generic method" framing already carries a forward-referencing
  correction note to this entry.

**Alternatives considered:**
- True reified generic methods (the original B-mode framing). Rejected:
  needs its own epic (`MethodDef`-owned `GenericParam` rows, `MVAR` operand
  encoding, call-site `MethodSpec` emission, a JVM erasure-vs-boxing design
  decision) that benefits every generic function, not just aspects — out of
  scope here (docs/55 §2, tracked as a standing question, Q-bmode-003).
- Routing through `Lyric.Mono`'s TVar-substitution engine. Rejected: no
  genuine generic-typed AST to substitute against; would require
  synthesising fake generic scaffolding for no behavioural gain (see above).
- Per-instance (not per-shape) specialisation. Rejected: degenerates to
  C-mode's per-use-site recompilation, the exact cost B′-mode exists to cut.

**Rationale.** Restores the "`args` is opaque, verified once generically"
discipline B-mode always intended for the majority of shipped/ecosystem
aspects (observers like `Logging`/`Tracing`/`Timing`, not field-inspectors
like `ValidateKey`), and removes their per-call-site recompilation cost,
independent of whether cross-language (non-Lyric) consumption of library
aspects is ever pursued (Q-bmode-003).

**Verification.** `weaver_self_test.l` (38/38, including 6 new B′-mode
cases: shape-key dedup, distinct-shape non-dedup, A0046, C-mode-unaffected,
and the from-instance-resolution update), `contract_meta_self_test.l`
(39/39, including the new `bmode` field tests), `aspect_weave_self_test.l`
(7/7, no regression) and `restored_packages_self_test.l` (15/15) all pass.
Full self-hosting verified twice: stage 1 (F#-minted seed compiling the
whole `lyric-compiler/lyric/` + stdlib tree) and stage 2 ("true builds
true" — the self-hosted compiler, built with this change, rebuilding
itself and the full stdlib) both complete cleanly.

**Related:** docs/27 §6.1, docs/43 Q-GEN-002, docs/55 (full plan),
docs/56 (row-typed `args`, a follow-on extension of this monomorphisation
path per docs/55 §4), Q-aspectlib-001, Q-bmode-001–004.

---

## D115 — Row-typed `args` for B′-mode aspects: Option 1 (`where TArgs has { ... }`) shipped over Option 2 (marker interfaces)

**Status:** ACCEPTED

**Context.** `docs/56-row-typed-aspect-args-sketch.md` (Q-aspectlib-009 in
`docs/27` §12) pressure-tested two designs for typed, named field access on
B′-mode `args` — today opaque by contract (docs/27 §6.1.1): any `pub aspect`
template lacking `@inline_template` that reads `args.<field>` fails closed
with A0046 (D114), forcing field-accessing library aspects (the canonical
example, `Auth.Aspects.ValidateKey`) into C-mode, which re-parses/re-compiles
the template body at every consumer use site instead of sharing B′-mode's
one-specialised-function-per-shape dedup.

- **Option 1 (row constraint):** new `where TArgs has { field: Type, ... }`
  syntax on `around` advice, scoped so `TArgs` is never a user-declared
  generic parameter — always the compiler-synthesised args type for the
  matched function (docs/56 §3). Row satisfaction is a linear scan at each
  specialisation site, not general row-polymorphic type theory.
- **Option 2 (marker interfaces):** auto-synthesise a nominal marker
  interface per `(aspect, field-shape)` pair, reusing `impl <Interface> for
  Record` → `InterfaceImpl` emission (D105/docs/51). No new syntax.

**Decision.** Ship **Option 1**, against the sketch's own cost comparison
(docs/56 §4), which favoured Option 2 on every axis except "generalises
beyond aspects someday." Two things changed the calculus once implementation
started:

- Lyric already has a native `interface` / `impl I for Record` construct
  with `where T: Interface` bounds (`docs/01-language-reference.md`
  §"interface") distinct from the FFI-external-interface form D105/docs/51
  actually emits `InterfaceImpl` rows for — so Option 2 as sketched
  ("auto-synthesise a marker interface … reusing docs/51's emission
  pattern") would need its own new plumbing (synthesising an *internal*,
  non-FFI interface + impl per shape) at implementation time, not literally
  zero new mechanism the sketch's comparison table implied.
- Once the row clause is scoped to exactly one grammar position (right after
  an `around` advice's return binder, with `TArgs`/`has` both contextual —
  recognised only there, reserving neither word globally, mirroring how
  `from`/`matches`/`around` are already contextual in `parseAspectBody`) and
  to exactly one semantic gate (does a resolved `from`-instance's `args.<field>`
  usage set ⊆ the declared row-field set?), the "new user-facing concept"
  cost docs/56 §4 flagged shrinks to one line in `docs/26-aspects.md`'s
  worked-example table, not a standing new type-theory surface.

**Design (docs/56 §3, as shipped):**

- Grammar: `AroundAdvice = 'around' '(' IDENT ')' '->' IDENT [ ArgsRowClause ]
  Block ; ArgsRowClause = 'where' 'TArgs' 'has' '{' ArgsRowField { ',' ArgsRowField } [','] '}' ;
  ArgsRowField = IDENT ':' Type ;` (`docs/grammar.ebnf`). Parsed into a new
  `AspectAround.argsRow: Option[List[ArgsRowField]]` field
  (`lyric-compiler/lyric/parser/parser_ast.l`,
  `lyric-compiler/lyric/parser/parser_items.l`).
- Weaver (`lyric-compiler/lyric/weaver/weaver.l`): a template's row clause is
  read once per `templateKey` in `bmodeGetOrBuildTemplateInfo`, synthesising
  a `__LyricBModeArgs_<template>` record (one per template, fields = the row
  clause verbatim — analogous to the existing `__LyricBModeCfg_<template>`
  record for `config.<field>`) and adding it as an extra `__lyric_args`
  parameter on the shared specialised function
  (`buildBModeSpecializedFunction`). `args.<field>` for a declared row field
  rewrites to `__lyric_args.<field>` (`tryMemberRewrite`, gated by a new
  `RewriteCtx.argsRowFields` set — empty for local aspects and C-mode, so no
  existing rewrite path changes). `collectBModeArgsFieldDiags`'s A0046 check
  is refined: it now fires only when the template's `args.<field>` usage is
  *not* fully covered by a row clause (`aspectArgsFullyRowCovered`) — a
  template with no row clause at all keeps the pre-D115 A0046 behaviour
  unchanged.
- Row satisfaction is checked per matched function, not per shape
  (`buildBModeCallSite`): for each declared row field, the matched
  function's own parameter list must contain a same-name, same-type
  parameter (compared via the existing `bmodeTypeExprKey` shape-key
  canonicaliser). A new diagnostic, **A0047**, fires per unsatisfied field;
  weaving still proceeds with that field omitted from the args-record
  constructor call, so the downstream type-checker also flags the
  incomplete record literal — matching the established A0042/A0043/A0044/A0046
  "diagnostic is additive, not a hard stop" convention.
- Formatter (`lyric-compiler/lyric/fmt/fmt_items.l`): the row clause renders
  inline after the return binder (` where TArgs has { f1: T1, f2: T2 }`),
  loss-checked round-trip verified in `fmt_self_test.l`.
- No new verifier or JVM-specific work: by the time `vcgen.l` / `jvm/bridge.l`
  see the woven body, `__lyric_args` is an ordinary concrete record parameter
  — exactly docs/56 §5/§7's predicted consequence of scoping row satisfaction
  to compiler-synthesised `TArgs` only.

**Q-row-001–005 resolution:**
- **Q-row-001 (keyword/spelling):** `has { ... }` as sketched, kept as a
  contextual (not reserved) word.
- **Q-row-002 (trigger vs `@inline_template`):** the row clause's presence
  is the trigger; `@inline_template` stays reserved for genuine C-mode.
- **Q-row-003 (multiple aspects, different row needs, same target):**
  resolved for free — each template gets its own synthesised args record
  and its own per-match satisfaction check; no composition/union logic
  needed since the checks are independent per `(template, matched-function)`
  pair.
- **Q-row-004 (optional fields / row-exclusion operators):** not needed —
  "has at least these fields" is the only form implemented; extra fields on
  the matched function are simply ignored, matching every shipped/sketched
  aspect's actual needs.
- **Q-row-005 (ship at all, vs Option 2):** resolved above — ship Option 1.

**Alternatives considered:** Option 2 (marker interfaces, see Context);
declining both and keeping `args` opaque forever for B′-mode (rejected —
`Auth.Aspects.ValidateKey`, the concrete motivating case, would stay pinned
to C-mode's per-use-site recompile indefinitely).

**Verification.** `parser_self_test.l` (+4 cases: row clause parses, defaults
to `None`, P0326/P0327 diagnostics), `fmt_self_test.l` (+1 round-trip case,
105/105), `weaver_self_test.l` (+4 cases: rewrite to `__lyric_args.<field>`,
partial-coverage still emits A0046, A0047 on missing/mismatched field,
42/42), and an ecosystem proof-of-value: `Auth.Aspects.ValidateKey`
(`lyric-auth/src/auth_aspects.l`) converted from `@inline_template` C-mode to
this row-constrained B′-mode form; `lyric-auth`'s existing
`tests/auth_aspect_weaving_tests.l` (a real cross-package `from`-instance
consuming it) passes unchanged (3/3): correct-key proceeds, wrong-key denies
with `Err("API key is invalid")` before the handler runs, and the `enabled =
false` bypass still works — full parse → weave → specialise → codegen →
runtime coverage with no test-file changes needed on the consumer side.

**Related:** docs/27 §12 (Q-aspectlib-009), docs/51 (D105, InterfaceImpl
emission — the Option 2 path not taken), docs/55 (D114, B′-mode this extends),
docs/56 (the sketch this entry backs).

---

## D116 — `import extern` syntax unifies package and external-type imports (docs/47, Q47-001–Q47-004)

**Context.** Lyric package imports (`import Std.Core.{Option, Result}`) and
external-type declarations (`extern type HostClient = "Docker.DotNet.DockerClient"`)
used unrelated syntax, forcing one line per external type and burying
aliasing in a separate form. PR #3728 added parser support (`import extern
Docker.DotNet.{DockerClient as HostClient}`) per the docs/47 design sketch.
This entry backfills the decision-log record that docs/47 cites as "D105"
— that number was independently claimed by the external-interface-`impl`
decision above before this entry was written, and "D115" was independently
claimed by the row-typed-`args` decision above before this entry was
rebased past it; D116 is the correct citation going forward for
Q47-001–Q47-004.

**Decision.** Adopt Option A from docs/47 §6 (import-like syntax) and resolve
Q47-001 through Q47-004 as follows:

- **Q47-001 (namespace syntax)** — require the full FQN (assembly + namespace).
  No by-namespace search; ambiguity across reference assemblies is a foot-gun.
- **Q47-002 (collision handling)** — local types shadow external imports,
  matching standard Lyric import scoping (a local `Option` shadows
  `import Std.Core.{Option}` the same way).
- **Q47-003 (tooling)** — external types imported via `import extern` are not
  part of the public API surface; `lyric doc` and `lyric public-api-diff`
  treat them as implementation details, not surfaced members.
- **Q47-004 (visibility)** — `import extern` is allowed in `pub use`
  re-exports, with the caveat that downstream consumers of that public API
  transitively depend on the external assembly's availability.

**Status.** Parser support (Phase 1) shipped in PR #3728. Type-checker
integration (Phase 2 — resolving `import extern`-bound names through the
same symbol table path as `extern type`) remains deferred; `extern type`
continues to be the only form the type checker fully resolves today.

**Related:** docs/47 (full design), docs/42 (metadata-based extern
resolution), docs/14 (kernel boundary), D105 above (external-interface
`impl`, a related but independently-numbered decision).

---

## D117 — Constructor shorthand `.new(args)` for extern types; static factory methods need no new syntax (docs/48, Q48-003)

**Context.** MSIL required an `@externTarget` wrapper function to construct
an external type; JVM already supported `.new(args)` shorthand directly.
D-progress-530 (above) shipped the MSIL implementation. This entry backfills
the decision-log record that docs/48 cites as "D106" (see D116 above for why
the originally-anticipated number was unavailable) and resolves the one
open design question docs/48 marks as decided, Q48-003.

**Decision.** `TimeSpan.fromMinutes(5.0)`-style static factory methods need
no special `.new`-adjacent syntax: they are already reachable through
ordinary auto-FFI method-call resolution (`ExternType.methodName(args)`),
since a static factory is just a static method returning the type, not a
constructor. `Q48-003` is resolved as "no action needed."

**Deferred (not part of this decision).** Q48-001 (generic constructors,
e.g. `List[T].new(capacity)` — requires call-site template instantiation,
tracked with Q022-4/docs/36) and Q48-002 (async constructors — not planned)
remain open per docs/48 §5.

**Related:** docs/48 (full design), D-progress-530 (MSIL implementation),
docs/42 (Phase 3c metadata resolution this reuses).

---

## D-progress-542 — Clarifying the 101/122-DLL counts in D-progress-531 against D-progress-502's 103

_Numbering note: this entry originally claimed "D-progress-540", but that
number was independently claimed by the LLVM native backend Phase 1 slice
entry in `docs/10-bootstrap-progress.md`; "D-progress-541" was independently
claimed by the lyric-docker Phase 1 entry in the same file. D-progress-542 is
the correct citation going forward._

**Context.** D-progress-531 reports the whole self-hosted compiler closure as
**101/101 DLLs** byte-for-byte reproducible. D-progress-502 recorded the same
kind of measurement as **103/103** on 2026-06-11. Read side-by-side without
context, the two counts look like a regression or a measurement-methodology
change; this entry records why they differ.

**Clarification.** Both counts are the same `--internal-perpackage-build`
`Lyric.Cli`-closure measurement — compiler packages plus their *transitive*
stdlib imports. The two counts differ only because that import closure
drifted by two packages over the intervening weeks between the two
measurements, not because of a different build path or methodology. This
count is also distinct from the 122 DLLs `build_stage2` emits, which
additionally include every *public* `Std.*` package from `lyric.full.toml`,
not just `Lyric.Cli`'s import closure.

**Related:** D-progress-531 (101/101 fixpoint measurement this clarifies),
D-progress-502 (103/103 measurement on 2026-06-11).

---

## D-progress-543 — Published NuGet `lyric` 0.4.9's `lyric fmt` diverges from `main`'s canonical match-arm style; hand-formatting is an accepted interim substitute in a source-build-less sandbox

**Context.** `CLAUDE.md`'s "Formatting" section mandates running the
**self-hosted** formatter (`lyric-compiler/lyric/fmt/`, invoked via
`./bin/lyric fmt --write`, built from this repo's own source) over every
changed `.l` file before committing — explicitly *not* any other formatter.
Some sandboxes used for this repo's automated sessions cannot build
`./bin/lyric` from source: the release-download bootstrap step is blocked by
network policy, and the historical F# mint-fallback path no longer exists
(F# was fully purged from the repo, `scripts/mint-stage0-fsharp.sh` requires
`git rev-parse 44a0d1e7~1`, which doesn't resolve after history rewrites).
The only formatter available in that environment is the **published NuGet
`lyric` 0.4.9 global tool** (`dotnet tool install -g lyric`).

**The problem.** While fixing SUGGESTION-severity review findings in
`lyric-docker/src/docker.l` (PR #4650), running `lyric fmt --write` from the
0.4.9 tool collapsed the file's established multi-line `match` block style
(one `case` arm per line) into single-line semicolon-separated form (e.g.
`match sent { case Err(e) -> return Err(...); case Ok(r) -> r }`) —
including for functions the PR never touched (`fromHttpError`, confirmed by
isolating a reformat run to only that function). Since this collapsed style
appears nowhere else in the file's history before this run, and the tool's
`fmt` is idempotent on its own output, this is conclusive evidence the 0.4.9
tool's formatter has diverged from whatever formatter last produced this
file's committed state on `main` — not a case of the file having been
hand-edited without formatting.

**Decision.** In a sandbox that cannot build `./bin/lyric` from source, when
the published NuGet tool's `lyric fmt --write` output measurably diverges
from the pre-existing style of a file being edited (verified by isolating
the reformat to untouched code, as above — not merely "it looks different"),
hand-formatting new/changed code to match the file's existing established
style is an accepted **interim substitute** for running the formatter,
provided:

1. The divergence is verified, not assumed (isolate a reformat run to
   code outside the actual diff; if untouched code also gets rewritten,
   that's the signal, not a stylistic hunch).
2. The PR description documents which files were hand-formatted and why,
   so reviewers know to check style-consistency manually rather than
   trusting a `lyric fmt` run happened.
3. This is not used as a general excuse to skip formatting — it applies
   only when the tool is demonstrated to actively fight the file's
   established convention, not merely "unavailable" or "inconvenient."

This does **not** change the standing rule for sessions that *can* build
`./bin/lyric` from source (the overwhelming majority): those must still run
the self-hosted formatter per `CLAUDE.md`, unchanged. This decision is
scoped to source-build-less sandboxes only, and is superseded the moment a
working self-hosted build is available in that environment.

**Related:** PR #4650 (the fix batch that surfaced this), issue #4658 (the
review finding that prompted this entry), `CLAUDE.md` "Formatting — run
`lyric fmt` before every commit", `scripts/mint-stage0-fsharp.sh` (the
retired F# mint-fallback this sandbox limitation stems from).

**Addendum (2026-07-04, published NuGet `lyric` 0.4.14, `dotnet tool
install -g lyric`):** the same class of published-tool divergence extends
to runtime correctness, not just `fmt`'s formatting style. Reading back
an opaque type's own private field from within its own defining
package — the exact pattern every accessor function in the stdlib uses
(`Std.Regex.isMatch`'s `r.handle`, `Std.Http.Url.toString`'s `url.value`,
`Std.Http.request`'s `url.value`, and by extension presumably every
other opaque type in the stdlib) — throws
`System.FieldAccessException: Attempt by method '...' to access field
'...' failed` when compiled by the published 0.4.14 tool against this
repo's current stdlib source (via `LYRIC_STD_PATH`), reproduced against
two independent opaque types (`Std.Http.Url`, `Std.Regex.CompiledRegex`)
with minimal isolated repros.

**Correction (2026-07-05):** the conclusion above — "almost certainly a
published-release-packaging artifact, not a real bug on `main`" — was
**wrong**, and was reached without actually running the from-source CI
build before writing it off. Real CI on PR #5084 hit the *identical*
`FieldAccessException`, byte-for-byte, on `lyric-stdlib/tests/http_tests.l`
— proving this is a genuine `main` bug, not a tool artifact. Root-caused
and fixed in D-progress-596: non-projectable opaque types' backing
fields were emitted with CLR-`Private` visibility
(`lyric-compiler/msil/lowering.l`'s `lowerMOpaque`), which the CLR
restricts to the *declaring type itself* — not the declaring package —
so any same-package function other than a method of that exact class
(e.g. `Std.Http`'s own free-standing `request()` reading `url.value`)
faults exactly like this. See D-progress-596 for the fix and two more
bugs (a cross-package generic-erasure match failure, and a qualified
user function silently shadowed by a same-named compiler intrinsic)
the same investigation surfaced. The methodological lesson generalizes
beyond this one entry: a published-tool repro that looks like it would
"break virtually everything" if real is a hypothesis to verify against
CI, not a conclusion to reach from that plausibility argument alone —
see D-progress-596's "why this went undetected" for why a bug this
broad-sounding survived undetected (it required a *specific*,
previously-untested combination: an opaque type's field read from a
free function outside its own methods).

---

## D118 — Fixed aspect `requires:`/`ensures:` runtime enforcement gap; retired C-mode across every field-accessing ecosystem library aspect

**Context.** While scoping whether D115's row-typed `args` let the
ecosystem retire C-mode (`@inline_template`) entirely, empirical testing
(not just re-reading the spec) surfaced that docs/26 §5's "Contract
augmentation" — specified since D-progress-208 and assumed shipped — had
never actually worked for any `requires:`/`ensures:` clause referencing
`args.<field>`, in *either* C-mode or B′-mode. `Auth.Aspects.ValidateKey`'s
`requires: args.apiKey != ""` silently never panicked on an empty key.
Two independent bugs compounded:

1. The weaver spliced `aspect.contracts` onto the wrapper's `contracts`
   field verbatim, leaving `args.<field>` an unresolved name.
2. Even a correctly-rewritten wrapper contract was never lowered into a
   runtime `assert(...)`: `Lyric.ContractElaborator` runs *before* weaving
   in the compile pipeline (parse → typecheck → modecheck → elaborate →
   mono → weave), but a wrapper's contracts don't exist until weaving
   builds the wrapper — by which point elaboration has already run.

**Decision.** Fix both gaps in `weaver.l`, then use the fix to retire
`@inline_template` from every ecosystem library aspect that only needed it
for `args.<field>` access (not to introduce any new language surface).

**Design — the fix:**
- `rewriteContractClauseArgs` / `rewriteContractClauseListArgs` rewrite
  `args.<field>` to the matched function's bare parameter name inside
  `CCRequires`/`CCEnsures`/`CCWhen`/`CCDecreases` (reusing the existing
  `rewriteExpr` traversal with an otherwise-empty `RewriteCtx`).
  Unconditional for every aspect mode — contracts always land on the
  per-match wrapper, never a shared B′-mode specialised function, so
  there's no shape-dedup opacity concern.
- `elaborateWrapperBodyForAspectContracts` re-runs
  `Lyric.ContractElaborator.elaborateFunction` directly against the built
  wrapper body, scoped to *only* the aspect's own (rewritten) contracts —
  not the full composed list — so the target's own already-elaborated
  contracts aren't double-checked.
- Wired into both `buildWrapper` (local aspects + C-mode `from`-instances)
  and `buildBModeCallSite` (B′-mode per-match wrapper) — two independent
  composition sites needed the identical fix.
- Two new `weaver_self_test.l` cases prove a `requires: args.<field>`
  clause is both rewritten and elaborated into a runtime `assert()`, for
  both the local-aspect and B′-mode `from`-instance code paths (44/44
  weaver self-tests pass); empirically verified end-to-end (both
  row-constrained B′-mode and C-mode forms of a `requires: args.apiKey !=
  ""` aspect now correctly panic on an empty key at the call site).

**Design — the retirement, once the fix made it safe:** converted every
field-accessing ecosystem library aspect off `@inline_template` to
row-constrained B′-mode (`where TArgs has { field: Type, ... }`):
`Web.Aspects.{RequiresAuth,RequiresRole,ApiKey}` (single scalar fields),
`Validation.Aspects.{ValidateInput,ValidateEmail}` (single scalar fields),
`Mq.Aspects.{Idempotent,DeadLetter}` (nested access — `args.message.id`
rewrites cleanly to `message.id` since only the leading `args.` segment is
rewritten; `DeadLetter` needs two row fields, `message: Message` and
`consumer: QueueConsumer`), `Ws.Aspects.{WsAuth,WsRateLimit}`,
`Grpc.Aspects.{RequiresGrpcAuth,RequiresGrpcRole}`,
`Storage.Aspects.ValidateKey`, and `Lambda.Aspects.DeadlineGuard` (row
field typed with the cross-package qualified name
`Lambda.LambdaContext`, confirming the row clause's type position accepts
qualified paths, not just bare same-package names). `Auth.Aspects.ValidateKey`
was already converted in D115. Each library's own test suite was run
after conversion; all pre-existing passes stayed green (a handful of
unrelated pre-existing sandbox failures — `HMACSHA256`/`MD5` type-loading
and `*.Kernel.Net` type-initializer exceptions — were confirmed identical
before and after conversion via git-stash A/B testing, so they are not
regressions from this change).

**Not converted:** `Web.Aspects.RateLimit`/`HttpCircuitBreaker`,
`Grpc.Aspects.GrpcRateLimit`/`GrpcCircuitBreaker`,
`Storage.Aspects.AuditAccess`, `Lambda.Aspects.EventLogging` — these are
already B-mode (no `args.<field>` access at all; they use only
`call.qualifiedName`), so there was nothing to convert.

**Related:** docs/26 §5, D-progress-208 (original, silently-broken
contract-augmentation spec), D114, D115, docs/55, docs/56.

---

## D-progress-553 — Breaking `@stable` API changes across five ecosystem libraries to unblock cross-DLL contract-metadata synthesis (#4514)

**Context.** `lyric publish` was failing contract-metadata synthesis for
five ecosystem libraries because their `pub` signatures referenced types
from *other* libraries' DLLs (`Lyric.Web`, `Lyric.Cache`, `Lyric.Mq`) that
a consumer might not have declared as a direct dependency — a `T0010`-class
failure. Fixing this required removing those cross-DLL types from the
affected `@stable(since = "0.1")` public signatures, which is a breaking
change to each. PR #4514 shipped the fix without a decision-log entry
recording the rationale or the migration path; this entry closes that gap
retroactively.

**Decision.** Prefer breaking the `@stable` signatures over leaving
publish broken. The alternative — keeping the cross-DLL types and forcing
every consumer to always declare every transitive library as a direct
dependency — does not scale and defeats the purpose of per-library
contract-metadata synthesis.

**What actually shipped (verified against the current tree):**

- **`lyric-health`** (`lyric-health/src/health.l`): `runLiveness` /
  `runReadiness` return `Result[String, String]` instead of
  `Result[String, ApiError]` (`Lyric.Web`'s `ApiError`). The error string
  carries the same failing-check information; `import Web` and the
  `Lyric.Web` dependency are removed from the library entirely.
  **Migration:** callers that returned the health result directly from an
  HTTP handler now map `Err(msg)` to `Err(Web.serviceUnavailable(msg))` (or
  an equivalent `ApiError`) at the call site — done for the `jobqueue`,
  `ledger`, and `rbac` examples in the same PR.
- **`lyric-mq`** (`lyric-mq/src/mq_aspects.l`): `pub func configure(idempStore:
  in CacheStore, dlStore: in DeadLetterStore)` is removed. It was a documented
  no-op (the `Idempotent`/`DeadLetter` aspects already resolve their store
  via aspect `config { }`, not this function), so removal has no runtime
  migration — callers simply delete the call. `Lyric.Cache`'s `CacheStore`
  remains used *inside* the aspect bodies (not in any `pub` signature), so
  `import Cache` is unaffected.
- **`lyric-lambda`** (`lyric-lambda/src/lambda.l`): `LambdaApp` stays a
  `pub record` (an intermediate `pub opaque type LambdaApp` attempt was
  reverted in the same PR after it broke intra-package field access and
  13 tests — see the PR's commit history for the false start). What
  actually changed: the `httpRouter` field's type changes from
  `Option[Router]` (`Lyric.Web`) to `Option[LambdaRouter]`, a new
  zero-field `pub opaque type` token defined in `lambda.l` with no
  `Lyric.Web` reference, so `Router` never appears in `LambdaApp`'s
  contract metadata. `pub func withRouter` is now gated behind
  `@cfg(feature = "web")`. **Migration:** consumers that called
  `withRouter` must add `web = []` to the features they enable (already
  the case for the `[nuget]`/library-dependency shape) — `Lyric.Web` is
  in scope for `withRouter`'s parameter/return types only when the `web`
  feature is active, so `T0010` cannot fire for consumers that don't use
  it.
- **`lyric-testing`** (`lyric-testing/src/testing.l`): `PublishedMessage
  .headers` changes from `slice[Mq.MessageHeader]` to a new
  `slice[TestMessageHeader]` (a `pub record` local to `lyric-testing` with
  the same `{key, value}` shape); a `toTestHeaders` helper converts at the
  `MockMessageQueue` publish boundary. `TestContext.cache` changes from
  `Cache.InProcessCacheStore` to a new local `pub record MockCacheStore`
  (implements `Cache.CacheStore`). **Migration:** test code that read
  `.headers` or `.cache` off these types field-by-field continues to work
  (same field shapes), but code that passed the value on to an API typed
  against the original `Mq`/`Cache` types needs the new local record type
  instead.

**Not a migration concern:** `lyric-docker`'s `extractJsonField` fix in
the same PR was a compile-error fix (`String.indexOf` returns `Int`, not
`Option[Int]`), not an API-shape change.

**Related:** #4514, docs/45 (contract-metadata direct resolution), D098.

---
## D-progress-554 — JVM: unbox an erased generic payload at the `match`/`?` bind site so arithmetic on it stops string-concatenating / VerifyError-ing (#4877)

**Context.** On `--target jvm`, an unannotated `val` bound to an erased
generic payload — the value arm of a `match` on a `Result`/`Option`, or the
result of `?` — was tracked as `java/lang/Object` (a boxed `Integer`),
because a generic union case's type-parameter field (`Ok(value: T)`) erases
to `Object` on the JVM (unlike MSIL, which reifies the field). Combining two
such bindings with an arithmetic operator miscompiled: `x + y` picked the
reference-typed `+` and **string-concatenated** (`2 + 2` → `"22"`), while
`x - y` (no string fallback) failed class verification with a
`java.lang.VerifyError`. This hits the single most common Lyric
error-handling idiom (`let x = foo()?; let y = bar()?; x + y`), so the issue
was BLOCKER-class. MSIL was correct throughout.

**Decision.** Implement the issue's preferred fix direction (Option 2): give
the JVM match-lowering the scrutinee's generic instantiation and unbox the
payload to its concrete primitive at the bind site. Rejected the runtime
`instanceof`-dispatched arithmetic alternative (boxes results, regresses the
hottest idiom) and the join-unification alternative (fixes the direct `match`
but not the `?` form, whose only value arm is `Object`).

**What actually shipped (verified on both targets):**

- `JvmCaseField` gains `paramIdx: Int` (index into the enclosing generic
  type's type-parameter list when the field is a bare type parameter, `-1`
  for a concrete field), populated in `collectFileCasesExtern` via
  `typeParamIndexOf`. `JvmFuncSig` gains `retGenericArgs: List[TypeExpr]`
  (the declared return type's generic arguments, e.g. `Result[Int, String]`
  → `[Int, String]`), populated via `returnTypeGenericArgs`.
- `lowerMatchExpr` recovers the scrutinee's generic args
  (`scrutineeGenericArgs`: a direct `match callee(...)` reads the callee's
  `retGenericArgs`; `EParen` is unwrapped) and threads them through
  `lowerPatternBind`. In the `PConstructor` arm, a field with `paramIdx >= 0`
  whose scrutinee supplies a concrete argument at that index resolves the
  payload's concrete JVM type; `bindCaseField` then `checkcast`+unboxes the
  boxed `Object` (`Integer.intValue`/`Long.longValue`/`Double.doubleValue`/
  `Float.floatValue`/`Boolean.booleanValue`) so the bound local is a real
  primitive. Reference / unresolved payloads stay boxed (pre-fix behaviour).
- The `?` form is fixed by construction: `propagate.l` desugars `getInt(a)?`
  to a `match` whose scrutinee is the original `getInt(a)` `ECall`, so
  `scrutineeGenericArgs` recovers the same instantiation.

**Gotcha codified (cost two failed stage-1 builds).** `retGenericArgs` was
first declared with a `= newList()` default. Like `isIface` (whose comment
already warned of this), a **defaulted field on a record constructed
cross-package miscompiles under the current self-hosted MSIL emitter** —
stage-1 produced invalid IL for `collectDeriveFreeSigs`, surfacing as a
runtime `System.InvalidProgramException` when the JVM compile path ran. Fix:
the field carries **no default**; all ten `JvmFuncSig` construction sites
pass it explicitly. (A separate first failure was a plain reserved-word slip
— `val out` in `returnTypeGenericArgs`; `out` is a parameter-mode keyword.)

**Third gotcha codified (cost one CI stage-0 build).** The CI bootstrap
mints stage 0 from a **pinned F# emitter** (commit `35c0d2e5`), which then
compiles the current self-hosted compiler source. Its inference is weaker
than the self-hosted checker: reading `sig.retGenericArgs` where `sig` came
from a bare `Option[JvmFuncSig]` match-arm destructure (no typed
intermediate) mis-resolved the receiver to the file's prevalent imported
`TypeExpr` record and failed with `E5/E7 codegen: imported record 'TypeExpr'
has no field 'retGenericArgs'`. Sandbox builds passed (newer stage 0), so it
surfaced only in CI. Fix: the read goes through a helper
`funcSigRetGenericArgs(sigOpt: in Option[JvmFuncSig])` whose explicit
parameter type anchors both the `sig` binding and the `mapGet` value type.
General lesson: bind a `mapGet` result to an explicitly-typed `Option[T]`
(or pass it to a typed parameter) before any field access the pinned F#
stage-0 emitter must compile.

**Fourth gotcha codified (cost one more CI stage-0 build).** With the third
fixed, the same pinned F# emitter then rejected the new `JvmCaseField.paramIdx`
field with `E5 codegen: record 'JvmCaseField' missing field 'paramIdx'` — it
**drops a defaulted record field from its field registry**, so `.paramIdx`
access resolved against a `JvmCaseField` that (to that emitter) had no such
field. This is the F#-stage-0 manifestation of the second gotcha's
defaults-are-hostile rule: it broke the self-hosted MSIL emitter as an
`InvalidProgramException` and the F# stage-0 emitter as a missing-field error.
Fix: `paramIdx` carries **no default**; all eight `JvmCaseField` construction
sites pass it explicitly (`-1` for concrete fields). Verified by running the
pinned mint locally (`LYRIC_BOOTSTRAP_MINT=1 scripts/mint-stage0-fsharp.sh`)
rather than pushing blind — the general lesson being **no JVM-codegen record
field may carry a default value**, since neither emitter in the build chain
handles it.

**Coverage.** `lyric-compiler/jvm/erased_generic_arith_jvm_self_test.l`
(`@test_module`, 8 tests) asserts runtime values for Int/Long/Double
payloads, a user-defined generic union, a guard over an unboxed payload, and
both the `match` and `?` forms (including the `-` VerifyError case). Runs in
CI on both targets — `--target jvm` in `compiler-self-tests-jvm` (Java 21),
`--target dotnet` in `compiler-self-tests-dotnet-a`.

**Related:** #4877, #2667 (band J4), docs/44 §5 J4, D-progress-473
(use-site unboxing this extends).

---

## D-progress-555 — `lyric build`/`lyric test` crashed with `InvalidCastException` on every non-workspace project; root cause was a bare `None` inside a tuple return, not `[nuget]` (#4925)

**Context.** Issue #4925 reported `lyric build` (`cmdBuild` → `buildProject`)
and `lyric test` (`cmdTestManifest`) crashing with an unhandled
`System.InvalidCastException: Specified cast is not valid.` on any project
manifest with a non-empty `[nuget]` table, confirmed against the published
`0.4.10` release. The issue's own root-cause theory pointed at
`cli_shared.l`'s `nugetUnresolvedReason`/`warnIfNugetUnresolved` matching
`manifest.nuget: Option[Mf.NugetSection]` directly — the same
`Option[RecordSection]`-match shape already worked around for
`Manifest.features` (see the `readFeatureDefaultsFromToml` comment in
`cli_build.l`) — and suggested applying the same raw-TOML-scan bypass to
`.nuget`.

**What actually reproduced.** Installing the published `lyric` `0.4.10`
NuGet global tool (`dotnet tool install -g lyric`; reachable in a
source-build-less sandbox because `api.nuget.org` isn't blocked even though
the GitHub release-download bootstrap path is, per D-progress-543's sandbox
profile) and running `lyric build` against a minimal non-workspace manifest
reproduced the exact exception — **with `[nuget]` entirely absent from the
manifest**:

```
Unhandled exception. System.InvalidCastException: Unable to cast object of
type 'Std.Core.Option_None`1[System.Object]' to type
'Std.Core.Option`1[Lyric.Workspace.WorkspaceContext]'.
   at Lyric.Cli.Program.buildProject(...)
```

Stripping `[nuget]` did **not** fix the crash; the exact same manifest
without `[nuget]` still crashed identically. Wrapping the same package as a
workspace member (a `[workspace]` root `lyric.toml` with `members = [...]`)
made the crash disappear — the actual trigger is **"this project has no
`[workspace]` ancestor,"** not `[nuget]`. The issue's own repro (a
standalone downstream repo, `cloud-agents`) happened to be a non-workspace
project; the `lyric-lang` monorepo's own ecosystem libraries never hit this
because the repo root `lyric.toml` declares `[workspace]` with every library
as an (excluded-or-member) directory, so `Ws.findWorkspaceRoot` always
succeeds for in-repo builds and the buggy code path is never exercised in
this repo's own CI.

**Root cause.** `cli/workspace_builder.l`'s `buildWorkspaceDeps` has
signature `(List[String], Bool, Option[Ws.WorkspaceContext])`. Its
not-in-a-workspace early-return path was `return (result, false, None)` —
a bare `None` literal constructed **inside a tuple literal**. Unlike a
plain `Option[T]`-returning function returning `None` directly (which
works fine; `Ws.findWorkspaceRoot` itself does this at its own `None` tail
position with no issue), a `None` embedded as one element of a multi-value
tuple loses its type argument under the bootstrap emitter, so the runtime
value is an untyped `Option_None<Object>`. Both call sites —
`buildProject` (`cli_build.l:1164`) and `cmdTestManifest`
(`cli_test.l:707`) — immediately destructure the tuple
(`val (a, b, c) = buildWorkspaceDeps(...)`), and casting that untyped
`Option_None<Object>` back to the declared `Option[Ws.WorkspaceContext]`
throws. A codebase-wide grep confirmed `buildWorkspaceDeps` is the only
function with an `Option[...]`-typed tuple return element, so this is a
narrow, fully-fixed instance rather than a broader class needing an audit.

**Decision.** Fix `buildWorkspaceDeps`'s early-return arm to return the
already-typed `wsCtxOpt` local (bound from the `Ws.findWorkspaceRoot` call
a few lines above, statically `Option[Ws.WorkspaceContext]`, and `None` by
construction in that `match` arm) instead of a fresh bare `None` literal —
`return (result, false, wsCtxOpt)`. No change was made to
`nugetUnresolvedReason`/`warnIfNugetUnresolved`: the issue's suggested
`.nuget` raw-TOML-scan bypass would not have fixed this crash (confirmed by
the nuget-absent repro above), so it was not applied — the `.features`
raw-TOML-scan bypass in `cli_build.l`/`cli_test.l` remains scoped to its
original purpose (D045 feature-flag resolution) and this entry does not
claim it generalizes.

**Coverage.** `cli_workspace_builder_self_test.l` gained a regression test
that calls `Cli.buildWorkspaceDeps` directly against a fresh manifest and
destructures the returned tuple exactly as the two production call sites
do. The first version asserted the tuple's `Option` element is `None`
(matching the local sandbox repro, where the fixture directory genuinely
has no `[workspace]` ancestor) — this **failed in CI** (`compiler-self-tests-
dotnet-a`) with `wsCtxOpt: Some(...)`, not a crash: the CI runner's
`TMPDIR`-rooted fixture directory apparently does resolve a workspace
ancestor (exact mechanism unconfirmed — plausibly a `runner.temp` layout
difference from this session's sandbox), so the buggy early-return arm is
never exercised there either way. Rewritten to compare the tuple's element
against a direct `Ws.findWorkspaceRoot` call on the same directory instead
of hardcoding an expected variant — environment-agnostic, still fails
loudly if the tuple ever mangles the `Option`'s type again. Could not be
verified end-to-end against a rebuilt `./bin/lyric` in this session: the
sandbox's release-download bootstrap is network-policy-blocked and the
historical F# stage-0 mint path no longer resolves
(`scripts/mint-stage0-fsharp.sh` requires `git rev-parse 44a0d1e7~1`,
unavailable in a shallow clone) — the same source-build-less profile
D-progress-543 documents. The crash reproduction and the post-fix manual
reasoning both used the published `0.4.10` global tool binary; CI
(`compiler-self-tests-dotnet-a`) is what actually confirmed the rewritten
self-test passes against the fix.

**Related:** #4925, D045 (`cli_build.l`'s `readFeatureDefaultsFromToml`
bypass, the prior art this issue's own theory drew from), D-progress-543
(the sandbox profile that made the published-tool repro possible), docs/38
(`[workspace]` design).

---

## D-progress-576 — `Std.Core`'s `Option`/`Result`/`Some`/`None`/`Ok`/`Err` never resolved at use-site outside the monorepo checkout; installed releases never shipped the raw stdlib source the typechecker needed (#4980)

**Context.** Issue #4980 reported that after #4925/#4955 fixed the
`InvalidCastException` crash, `lyric build` got further but immediately hit
a second bug: a plain `import Std.Core` never errored, but any actual use
of `Option[T]`, `Result[T, E]`, or their constructors `Some`/`None`/`Ok`/`Err`
failed with `T0010 unknown type name` / `T0020 unknown name`, in both a
minimal standalone repro and a real downstream project
(`nichobbs/cloud-agents`). Fully-qualified access
(`Std.Core.Result[Int, String]`) failed identically. True compiler builtins
(`println`, `slice[T]`, `String` methods, arithmetic) always resolved fine —
only types actually *declared* in `lyric-stdlib/std/core.l` were affected.

**Root cause.** `Lyric.Emitter.findStdlibSourcesForTarget` (the function
behind both `emitProjectInProcess` and the single-file `emitMsilInProcess`
compile paths) locates `lyric-stdlib/std/` by walking up from the running
binary's directory or the CWD looking for that literal directory name, then
reads its raw `.l` source text so the typechecker can register `Std.*`'s
declared types. When neither walk finds a hit, it silently returns an empty
source list — the typechecker never sees `Option`/`Result` at all, but
`import Std.Core` itself has nothing to validate against, so it never
errors either. Every real installed release (`bootstrap/publish/<rid>/`
tarballs, the NuGet global tool, and the downstream project's own repo)
ships *only* the compiled `lib/Lyric.Stdlib.dll` bundle — never the raw
`lyric-stdlib/std/` tree the walk needs. `docs/34-distribution-strategy.md`
§4 had always documented a "source fallback… included in all distribution
archives" as the safety net for exactly this case, but neither the
`tar.gz`/`zip` archive step nor the NuGet `dotnet pack` step in
`publish.yml`/`Lyric.Cli.Aot.csproj` ever actually copied that source tree
in — the promised fallback was undocumented-vaporware, not a regression.
The bug was invisible in every previous release because #4925's crash fired
first on any non-workspace project; it was also invisible in this repo's
own CI and dev loop, because a locally-built `lyric` binary's directory (or
the dev shell's CWD) always sits inside the monorepo checkout, so the walk
always finds the real `lyric-stdlib/std/` regardless of the packaging gap.
The existing publish smoke test (`printf 'import Std.Core...'` in
`publish.yml`) never caught this either: it imports `Std.Core` but never
actually references `Option`/`Result`, so it hit the exact same
never-errors-on-plain-import blind spot the issue itself flagged.

**Decision.** Rather than start shipping the raw stdlib source tree in
every release archive (docs/34's originally-promised fix), reuse the
compiled-bundle-driven contract-metadata machinery `Lyric.RestoredPackages`
already built for restored NuGet/workspace dependencies: every compiled
Lyric assembly — including `Lyric.Stdlib.dll` itself — embeds a
`Lyric.Contract.<Pkg>` resource per bundled package (docs/45), and stdlib
items are always resolved at codegen as cross-assembly references into the
compiled DLL rather than re-emitted (`registerStdlibArtifactTokens`), so a
declaration-only reconstruction is sufficient — no function bodies, no
re-typecheck round-trip needed. Added
`Lyric.Emitter.stdlibSourcesFromCompiledBundle()`: when
`findStdlibSourcesForTarget`'s raw-source walk comes up empty (the
`.NET`/MSIL target only — see the JVM caveat below), it locates the
already-copied-beside-the-binary `lib/Lyric.Stdlib.dll` via the existing
`findCompiledStdlibDir()`, loads its per-package contracts through
`Lyric.RestoredPackages.loadRestoredPackage`, and calls
`RP.synthesiseSource(contract, <empty preamble>)` per package to produce
the same `List[String]` shape `collectStdlibPackages` already expects.

The first implementation passed each artifact's *sibling*-type preamble
(`siblingTypeDecls`, the helper `emitProjectInProcess` already uses for
restored NuGet deps) into `synthesiseSource`, mirroring
`Lyric.RestoredPackages.synthesiseArtifact`'s validation step. That was
wrong here: `synthesiseArtifact`'s preamble is a *standalone re-typecheck
aid* that gets stripped back out before the artifact is stored
(`ownSrc = synthesiseSource(art.contract, emptyPreamble())`), whereas every
stdlib package is fed to the typechecker *together* in one
`importedPkgs` pass, so cross-package references already resolve against
the real sibling artifact. Keeping the preamble caused a manual repro
regression: `Std.Collections` (which references `Option[T]` in its own
signatures) got a second, case-less stub `pub union Option[T] {}` registered
under its own package alongside `Std.Core`'s real one, and
`symTableTryFindOne`'s last-registered-wins scan silently picked whichever
copy loaded later — surfacing as `T0065 returned value of type Option[Int]
does not match declared return type Option[Int]` (same printed name, two
distinct declarations). Fixed by passing an empty preamble.

**JVM caveat.** `Lyric.ContractMeta.readAllContractsFromFile` reads
`Lyric.Contract.<Pkg>` resources via the metadata-direct PE reader
(`Msil.MetadataReader`), which only understands the `.NET` CLI/PE format.
There is no JAR-side equivalent, so a `--target jvm` build with no reachable
raw source tree still degrades to the pre-existing empty-list behaviour.
Filed as #4994 rather than solved here, to keep this fix scoped to the
reported `.NET`-target bug.

**Coverage.** Manually reproduced the exact issue repro (`Option[Int]` /
`Result[Int, String]` returning `find`/`divide` functions) against a
"fake install" — the freshly built `./bin/lyric` binary plus its
`Lyric.Stdlib*.dll` copied into an isolated temp directory outside the
repo, run against a project also outside the repo, with `LYRIC_STD_PATH`
unset — confirming the exact `T0010`/`T0020` failures before the fix and a
clean build + correct runtime output (`found 5` / `not found` / `ok 5` /
`err div by zero`) after. Verified the normal in-repo (raw-source) path is
unaffected by re-running the same repro directly against the monorepo
checkout. Added a regression test,
`"stdlib types reconstruct from compiled bundle contract metadata"` in
`msil_project_bridge_self_test.l` (run in CI via native `lyric test`),
that calls `Emitter.stdlibSourcesFromCompiledBundle()` directly and asserts
`Std.Core`'s `Option`/`Result` unions are present in the reconstructed
source — exercised directly rather than by hiding the raw source tree,
since this test's own process CWD and app-base directory both sit inside
the checkout, making the fallback unreachable end-to-end from within it.

**Related:** #4925/#4955 (the crash this bug was hidden behind), #4994
(tracked JVM-target follow-up), docs/34-distribution-strategy.md §4
(stdlib distribution forms), docs/45-contract-metadata-direct-resolution.md
(the contract-metadata mechanism this fix reuses).

---

## D-progress-578 — A `[nuget]`/`[dependencies]`-registry-form dependency on another Lyric package never had its contract loaded; zero-argument (and any other) function calls into it resolved through the raw-metadata auto-FFI guess instead (#5004)

**Context.** Issue #5004 reported that after #4980 fixed `Std.Core`
resolution, a further bug surfaced: calling a genuinely zero-argument
function from a NuGet-restored Lyric package (`Web.create(): Router` from
`Lyric.Web`) failed type-checking with `T0042 expected 1 argument(s), got
0`, even though both the package's embedded contract and its compiled IL
agreed the function takes no parameters. Multi-argument calls into the
same package (`Web.addGet`/`addPost`/`addDelete`) type-checked fine; only
the zero-arg case failed.

**Investigation.** Reproducing this took most of the effort. Tracing the
full contract-metadata → `Lyric.RestoredPackages` synthesis →
typechecker signature-registration → call-site arity-lookup pipeline
against the real published `Lyric.Web`/`Lyric.Auth`/`Lyric.Resilience`
0.4.11 packages — via `Lyric.RestoredPackages.synthesiseArtifact`,
`Msil.Bridge.compileProjectToMsilWithRestoredAndVersion`, and finally
`Lyric.Emitter.emitProject` directly, replicating the real `restoredDllPaths`
list byte-for-byte — never reproduced the bug: every stage correctly
computed zero params for `Web.create`. The break only appeared going
through the *real* `lyric build` CLI path
(`cli_build.l::buildProject`), which showed the actual root cause:
**`resolveNugetAssets`'s output (every DLL `dotnet restore` resolved from
`[nuget]` **and** from a `[dependencies]` registry-form entry — both
produce the same `<PackageReference>` in the generated restore csproj,
per `cli_restore.l`'s `buildRestoreCsproj`) was threaded *only* into
`EmitProjectRequest.nugetAssemblyPaths`, which feeds the raw
PE-metadata auto-FFI index (`Msil.MetadataReader`, Phase 5 of
`ensureMetadataIndex` in `msil/codegen.l`) — never into
`restoredDllPaths`, the field that actually becomes a
`Lyric.RestoredPackages.RestoredArtifact` with the package's real
declared signatures.** `restoredDllPaths` (`cli_build.l`'s `restoredDlls`
local) was populated only from `[workspace]` and `path`-source
`[dependencies]` entries; the manifest-walking loop had a bare
`case _ -> ()` fallback for every other `DepSource` variant, silently
dropping `Registry` (the documented form for a published-package
dependency; see docs/39-package-registry.md §5) entirely. So a Lyric
package consumed via NuGet — regardless of which manifest table named
it — was never routed through the contract-aware restored-dependency
path at all; it only ever reached the auto-FFI metadata guess, whose
raw-signature heuristics misread `create()`'s arity.

Confirming this required a working *end-to-end* toolchain: the sandbox's
`make lyric` fell back to minting the historical F# bootstrap compiler
(release download blocked by network policy) whose `Lyric.Cli.dll`
closure gets reused wholesale rather than recompiled — reproducing an
unrelated `MissingFieldException: Std.Yaml.YamlValue_YMapping.pairs`
crash inside `resolveNugetAssets`'s own JSON parsing before ever reaching
typecheck (also independently reproduced against the officially published
`lyric` 0.4.12 NuGet global tool). That crash is a distinct ABI-staleness
bug, filed separately as #5010 (out of scope here). `make stage2` (the
fully self-consistent, self-hosted-rebuilding-itself toolchain) sidesteps
it entirely, and reproduced #5004's exact `T0042` error via `lyric
restore && lyric build` on the real repro project.

**Decision.** Added `Lyric.Cli.partitionNugetLyricDeps` (`cli_shared.l`):
for each DLL path `resolveNugetAssets` resolves, check whether it carries
an embedded `Lyric.Contract`/`Lyric.Contract.<Pkg>` resource
(`Lyric.ContractMeta.readAllContractsFromFile`, the same PE-metadata
reader `Lyric.RestoredPackages.loadRestoredPackage` uses). A contract-
bearing DLL is a Lyric package — append it to `restoredDlls` (the same
`"name\tpath"` shape a workspace/path dependency already uses); a DLL
with no contract is a genuine third-party .NET library and keeps going
through `nugetAssemblyPaths`/auto-FFI unchanged. Wired into both
`cli_build.l::buildProject` and `cli_test.l::cmdTestManifest` (hoisting
the latter's `resolveNugetAssets`/`warnIfNugetUnresolved` calls out of
the per-test-file loop they were previously and pointlessly re-run
inside, to append to `restoredDlls` exactly once). This fixes both the
issue's own `[nuget]`-table repro and the documented-but-equally-broken
`[dependencies]` registry-form, uniformly and without needing to special-
case `DepSource.Registry` in the manifest-walking loop at all — the
partition operates downstream of manifest parsing, directly on resolved
NuGet assets, so it doesn't care which table originally named the
dependency.

**Coverage.** Verified end-to-end against a freshly built, fully
self-consistent `make stage2` toolchain: the exact issue repro
(`[nuget] "Lyric.Web" = "0.4.11"`, `var router = Web.create()`) now
builds and runs (`hi`), as does an equivalent manifest using
`[dependencies] "Lyric.Web" = "0.4.11"` (the documented registry form).
Added a regression test,
`"partitionNugetLyricDeps: Lyric-contract DLL routes to restored deps,
third-party DLL does not"` in `cli_shared_self_test.l`, using the running
test's own compiled DLL (every Lyric-emitted assembly carries a real
embedded contract) as the Lyric-package fixture. `cli_build_self_test.l`
(15/15), `emitter_project_self_test.l` (20/20), and
`restored_packages_self_test.l` (15/15) all pass with no regressions.
`cli_shared_self_test.l`'s three pre-existing `resolveNugetAssets`
happy-path failures (`Field not found: Std.Yaml.YamlValue_YMapping.pairs`)
are unaffected by this change — confirmed by inspection (they crash
inside `resolveNugetAssets`'s own unmodified YAML-parsing code, before
`partitionNugetLyricDeps` is ever called) — and are the same #5010 ABI-
staleness bug, reachable here via `lyric test`'s compiler-bundle-linking
mechanism for self-tests that reference `Lyric.Cli` internals.

**Related:** #4980 (the resolution this bug was hidden behind), #5010
(the separately-tracked, out-of-scope `Std.Yaml`/auto-FFI ABI-mismatch
crash found during investigation), docs/39-package-registry.md §5 and §9
(the `[dependencies]` vs `[nuget]` manifest design this fix's scope was
clarified against).

---

## D-progress-584 — A stdlib union case or record field forward/mutually-referencing another `Std.*` type degraded to `System.Object` in cross-package MemberRef signatures, faulting with `MissingFieldException` under framework-dependent (JIT) execution (#5010)

**Status:** ACCEPTED

**Symptom.** `dotnet tool install -g lyric` (the framework-dependent NuGet
global tool) crashed with `System.MissingFieldException: Field not found:
'Std.Yaml.YamlValue_YMapping.pairs'` inside
`Lyric.Cli.Program.extractPackagesPathFromYaml`, on *any* project with a
`[nuget]` table — i.e. before ever reaching the code path #5004 was
about. The self-hosted-AOT release tarball (`lyric-*.tar.gz`) did **not**
exhibit this crash for the same repro, which made it look like a
packaging/build-pipeline inconsistency between the two distribution
channels rather than a genuine compiler bug.

**Investigation.** Direct .NET reflection over the compiled DLLs
(`System.Reflection.Metadata`/`PortableExecutable`) confirmed an ABI
mismatch: `Lyric.Stdlib.dll` declares `YamlValue_YMapping.pairs` as
`FIELD GENERICINST CLASS <List\`1> 1 CLASS <YamlPair>` (properly typed),
but `Lyric.Lyric.Cli.dll`'s MemberRef *referencing* that field encodes
`FIELD OBJECT` — the whole field type collapsed to `System.Object`. This
reproduced from a from-scratch local `make stage2` build (no network
dependency on the published release), and — critically — reproduced
identically even when the closure was re-emitted by the **stage-2
binary itself** (a true self-hosted compile, not the frozen historical
F# bootstrap seed reused for stage 1), proving the bug lives in the
*current* self-hosted MSIL emitter (`lyric-compiler/msil/`), not in a
stale bootstrap artifact.

Two independent bugs in `lyric-compiler/msil/codegen.l` combined to
produce this:

1. **Wrong field-signature encoder.** Cross-package union-case field
   registration for `Std.*` stdlib packages
   (`registerStdlibTypeItem`'s `IUnion` arm) built each case field's
   signature with the **context-free** `buildFieldSig` — which cannot
   resolve a cross-assembly TypeRef by name and therefore *always*
   degrades any reference type (`MClass`, `MConcreteList`,
   `MConcreteMap`, `MGenericInstByName`) to `ELEMENT_TYPE_OBJECT`
   (`lowering.l`'s own comments document this as the intended behavior
   for that function — it exists for BCL-extern signatures where no
   TypeRef lookup is needed or possible). Every other cross-package
   field-registration path in the file (`registerRestoredRecordFields`,
   `registerRestoredUnionCase`) already used the **context-aware**
   `buildFieldSigWithCtx`, which resolves the real TypeRef/TypeDef row
   via `bufMsilTypeWithCtx` and encodes the correct concrete signature.
   Fixed by switching all four call sites in the `IUnion` arm to
   `buildFieldSigWithCtx(typeExprToMsilCtx(cctx, ty, packageName),
   cctx.lctx)`.

2. **Forward/mutual-reference ordering.** Even with (1) fixed, a
   *different* field still degraded: `Std.Yaml.YamlPair.value:
   YamlValue`. `YamlPair` (a plain record) is declared *before*
   `YamlValue` (the union) in `yaml.l`, and the two are mutually
   recursive (`YamlValue`'s `YMapping` case embeds `List[YamlPair]`;
   `YamlPair.value` names `YamlValue`). `registerStdlibArtifactTokens`'s
   "Pass 1" was a *single* combined walk (via `registerStdlibTypeItem`)
   that registered a type's own TypeRef **and immediately baked its
   field/ctor signatures** in the same pass, per item, in declaration
   order — so `YamlPair`'s field signature for `value` was baked before
   `YamlValue`'s TypeRef existed, degrading it the same way. The
   already-correct `registerRestoredArtifactTokens` path (for non-stdlib
   packages) avoids exactly this by splitting into two full sub-passes
   across every package: register **all** TypeRefs first, then **all**
   member signatures. Applied the same two-sub-pass split to the stdlib
   path: `registerStdlibTypeItem` was split into
   `registerStdlibTypeItemRefs` (type + union-case TypeRefs only) and
   `registerStdlibTypeItemMembers` (fields/ctors, assuming every
   TypeRef — including forward/mutually-referenced ones — already
   exists), and `registerStdlibArtifactTokens`'s Pass 1 now runs sub-pass
   1a (refs, all packages) fully before sub-pass 1b (members, all
   packages).

**Why the tarball didn't crash.** A degraded field signature does not
fail to *compile* — it's still valid PE metadata, just wrong. NativeAOT
(`ilc`, used for the self-contained release tarball) statically links
the whole closed program graph at compile time and resolves a field
access by (owning type, name) against the real TypeDef, generating
correct native code regardless of the caller's stale cached signature —
masking the bug entirely. A framework-dependent, JIT-loaded assembly
(the published `lyric` NuGet global tool, and any `lyric test`-run
self-test) loads producer and consumer as independent assemblies at run
time, and the CLR's field-binding validates the caller's MemberRef
signature against the real FieldDef — a mismatch is exactly
`MissingFieldException: Field not found`.

**Verification.** Confirmed via a multi-generation bootstrap chain
(fix applied to source → compiled by an *unfixed* tool → AOT-linked →
that binary used to recompile the closure again), directly inspecting
MemberRef signature bytes at each generation with .NET reflection: the
first fix alone corrected `YamlValue_YMapping.pairs`
(`06151239...`, no longer `061C`) but left `YamlPair.value` degraded;
both fixes together correct both fields. `lyric-compiler/lyric/
cli_shared_self_test.l`'s three previously-failing
`resolveNugetAssets` happy-path tests (blocked on this exact crash,
noted as out-of-scope in D-progress-578/#5004) now pass 10/10 with no
regressions. Added a new regression test,
`lyric-compiler/lyric/yaml_stdlib_field_abi_self_test.l`
(`@test_module`, imports only `Std.*`), that parses JSON through
`Std.Yaml.parseJson`, reads `YamlPair.key`/`.value` off the resulting
`YMapping`'s pairs, and asserts real values — confirmed to reproduce the
original `MissingFieldException` crash against a build carrying only
fix (1) and to pass cleanly with both fixes applied.

Scoped to the MSIL backend only: `lyric-compiler/jvm/` has no
`registerStdlibTypeItem`/`buildFieldSig` analog (grepped for both name
patterns, no hits), so this specific bug does not have a JVM
counterpart to fix in parallel.

**A pre-existing, related observation.** During the full-rebuild
verification, Stage 1 (compiling `lyric-compiler` packages with the
mint/stage-0 tool) logged 284 `W0005: ... MGenericInstByName
'Std.Core.Result\`2' — signature degraded to System.Object (#2494)`
warnings — the same silent-degradation mechanism, for a different
stdlib generic type. #2494 (closed) already documents this class of
bug: an earlier attempt to turn the fallback into a hard panic broke
real builds because "the fallback path is genuinely exercised during
normal stdlib compilation," so it was reverted to a warning with the
underlying seeding bug left unfixed. Stage 2 of the same rebuild (using
a tool built from this PR's fixed source) shows **zero** `W0005`
warnings for the identical compile — consistent with this fix having
already resolved the `Result\`2` case incidentally, since it goes
through the same `registerStdlibArtifactTokens` two-pass path. Not
investigated further here (Stage 1 uses a frozen historical tool that
real CI never exercises — CI's stage 0 downloads a current release
instead of minting); left for a follow-up if the warnings turn out to
still occur in a real release build.

**Related:** #5004 (the bug this one was found while investigating, and
was hidden behind — this crash happens earlier, during NuGet asset
resolution, before #5004's arg-count check ever runs), D-progress-578
(the #5004 entry that first identified and scoped out this crash),
#2494 (the related, already-closed silent-degradation-warning issue
this fix incidentally seems to also resolve for `Std.Core.Result\`2`).

## D119 — Concurrency gap resolution: real structured concurrency (§7.4) + implicit cancellation (§7.3) across MSIL/JVM, generator-laziness spec correction (§7.2); native async is real (D-N-022) but its §7.4 structured layer is a separate follow-up

**Date:** 2026-07-04
**Status:** ACCEPTED (design codification; implementation lands in slices — see §"Implementation plan")

**Context — the audit.** Bringing the native (LLVM) backend's `async`/
`spawn`/`defer` slices online (D-N-019, D-N-020, D-N-021) surfaced that
the *reference* backends (MSIL, JVM) do not implement several §7
guarantees the language reference presents as shipped. A four-way audit
(native, MSIL, JVM, and the language reference) established the actual
per-backend state:

- **`defer` (§4.3)** — real and complete on MSIL (`try/finally` rewrite in
  `lowerStmtsFromMsil`, all exit paths incl. exception unwind) and JVM
  (`replayDefers` + catch-all region). Native runs it on all *normal*
  paths but not on `panic` (D-N-020, no unwinding — intentional).
  **One real MSIL limitation:** because `defer` lowers to `try/finally`
  and V0012 forbids `await` inside any protected region, a `defer` cannot
  span an `await` suspension point (async cleanup across a suspend is
  impossible today). Tracked as a follow-up, not resolved here.
- **`spawn`/`scope` structured concurrency (§7.4)** — **the headline
  gap.** No backend implements the §7.4 guarantees (bounded task
  lifetime, sibling-cancel-on-failure, first-failure propagation with
  aggregation, no fire-and-forget):
  - MSIL: `ESpawn` is a pure passthrough exposing the raw hot `Task<T>`;
    `SScope` is a plain block. Real concurrency happens only via .NET's
    hot-task model, but with *no* structure — a spawned handle can be
    dropped un-awaited (fire-and-forget leak), directly contradicting
    §7.4's "raw fire-and-forget is not available." `spawn` outside a
    `scope` is not rejected.
  - JVM: `ESpawn` runs its expression *synchronously inline*; `SScope`
    is a plain inline block — no concurrency at all. A complete,
    production-quality `StructuredTaskScope.ShutdownOnFailure` lowering
    (`lowerScopeBlock`, `lowering.l`) exists in the emission library
    ("Path A") but is **not wired into the user compile path**.
  - Native: as of **D-N-022** (landed 2026-07-04, superseding the
    D-N-019/D-N-021 passthrough), `async`/`spawn`/`await` are **real** —
    LLVM coroutines + a cooperative `lyric-rt` scheduler with
    `Std.Time.sleepMillis` as the async leaf, so spawned tasks make
    genuine concurrent progress. But §7.4's *structured* guarantees
    (sibling-cancel-on-fault, failure aggregation) are still absent on
    native (D-N-003: panics abort, no cancellation machinery) — the same
    §7.4 gap MSIL and JVM have, now on a real-concurrency substrate.
  - `docs/09-msil-emission.md` §15 documents a `Lyric.Runtime.Scope`
    runtime type (`ConcurrentBag<Task>` + `JoinAll`) that **does not
    exist** in the self-hosted backend — aspirational F#-emitter-era
    design, never ported.
  - **A parallel *library* substrate already exists** (found while
    auditing): `lyric-stdlib/std/_kernel/task.l` (`Std.Task`) ships a
    real `Scope` **`protected type`** backed by a
    `CancellationTokenSource` + `List[Task]`, with `makeScope` /
    `scopeSpawn` / `awaitAll` (via `Task.WhenAll`) / `cancelScope` /
    `disposeScope`, cancellable `delay`/`delayWithCancel`
    (`Task.Delay(ms[, token])` — a *genuine* async leaf), and an
    `@asyncLocal` ambient-token slot (D-progress-071). Its own header
    documents the identical sibling-cancel gap: the F#-era
    `LyricTaskScope.Add` attached a `Task.ContinueWith((Task) -> Unit)`
    continuation to cancel siblings on first fault; that was **dropped**
    pending a `(Task) -> Unit` FFI delegate ("G12 audit"). So the
    language `spawn`/`scope` keywords (`ESpawn`/`SScope`) and this
    library are two faces of one feature — the kernel comment even says
    `scopeSpawn` is named to leave `spawn` free "for the future `spawn
    expr` syntactic form." The intended architecture is that the
    keywords lower onto (or share the substrate of) `Std.Task`, not that
    each backend re-emits bespoke join/cancel IL.
- **Cancellation (§7.3)** — the reference says every `async func` gets an
  implicit `CancellationToken` (`cancellation`, `checkOrThrow()`,
  auto-propagation). **Unimplemented on all three backends** and absent
  from the shared type checker. Pure spec-vs-impl gap, and the mechanism
  §7.4's sibling-cancellation needs.
- **Generators (§7.2)** — the reference claims yield-only generators use
  an *eager* "collect-all into a `List`" strategy and that laziness needs
  `yield`+`await`. **Both false as of the shipped self-hosted backends:**
  MSIL emits a genuinely *lazy* `IAsyncEnumerable` state machine (TCS +
  per-yield resume labels, `synthesizeGeneratorMsil`), and JVM emits a
  lazy virtual-thread + `SynchronousQueue` producer. Yield-only infinite
  sequences already work on both. The eager path is dead/legacy. Several
  self-test headers repeat the stale "collect-all" wording.
- **`?` propagation** — *not* a gap: `docs/44` B-2 ("`?` is a synchronous
  passthrough miscompile on JVM") is **stale**. A shared middle-end pass
  (`Lyric.Propagate.lowerPropagateFile`) desugars every `?` into
  `match`/`return` in all three bridges before codegen; the codegen
  `EPropagate` passthrough is unreachable fallback.

**Decision.**

1. **§7.2 (generators) — correct the spec to *empirically verified*
   shipped reality.** Rewrite §7.2 to state that yield-only generators
   are *lazy* on both MSIL (`IAsyncEnumerable` TCS state machine) and JVM
   (virtual thread + `SynchronousQueue`); infinite yield-only sequences
   are supported. Retire the "eager collect-all / unbounded generators
   hang" caveat. **Verification note (why the earlier "reject
   `yield`+`await`" plan in a draft of this entry was dropped):** a
   direct end-to-end test (`./bin/lyric run`) showed the `yield`+`await`
   async-iterator form **already works on MSIL, including a genuinely
   suspending `await delay(ms)` between yields** — the MSIL generator is
   itself an `IAsyncStateMachine`, so it suspends/resumes correctly. The
   long-standing "#1490 compile error" claim was stale; MSIL must *not*
   reject this form (that would remove working functionality). JVM is the
   real gap: its generator producer is a synchronous virtual thread with
   no suspension, and `Std.Task`'s async leaf primitives are `.NET`-only,
   so a suspending `await` in a JVM generator fails at runtime — #1490 is
   reframed as "JVM async-iterator parity," not "unimplemented
   everywhere." Fix the stale self-test / codegen headers.

2. **§7.4 (structured concurrency) — implement for real on MSIL and JVM
   (native's real-async substrate landed separately in D-N-022; its §7.4
   structured layer is a native follow-up).** The guarantees are
   implemented, not documented-away. Two target-specific mechanisms, one
   shared front-end contract:

   - **Shared front-end (consumption rule, not strict lexical scoping):**
     every spawned task must be *consumed* — `await`ed, or joined by an
     enclosing `scope { }`. A spawned task that is dropped (flows into a
     value position, or falls out of scope, without being awaited or
     scope-joined) is rejected by the shared checker (new diagnostic
     **V0014** — `V0013` was already taken by the verifier's
     NaN/±Infinity float-literal warning, `verifier/driver.l:239`),
     enforcing "no fire-and-forget" on every target.
     **Design correction (2026-07-05):** an earlier draft of this entry
     said `spawn` must be *lexically inside* a `scope`, but that
     contradicts shipped reality — `llvm_self_test_async.l:271`
     (native, D-N-022) and `async_sm_self_test.l` (MSIL) both run and
     assert `val t = spawn f(); … ; await t` with **no** enclosing
     `scope`, and D-N-022's native backend already emits exactly the
     value-position diagnostic V0014 generalises. The consumption rule
     is the correct formulation: it closes the fire-and-forget hole
     without breaking the idiomatic bare-`spawn`-then-`await` pattern or
     the just-landed native async. No existing well-formed test needs
     rewriting (only genuinely-dropped spawns, if any, become errors).

   - **JVM (the tractable target — real forked concurrency):** wire the
     existing `lowerScopeBlock` into the user path. Each `spawn e` inside
     a `scope` synthesises a `Callable` class whose `call()` runs `e`
     (reusing the closure-class synthesis machinery); the `scope` block
     collects those callable names and emits the
     `StructuredTaskScope.ShutdownOnFailure` fork/join/propagate sequence
     (JDK 21–23; JDK 24+ raises the existing #2263 error). This gives
     genuine §7.4 semantics — each spawn forks onto a virtual thread,
     `join()` waits for all, a failed subtask shuts the scope down
     (cancelling siblings) and rethrows the cause. `await handle` reads
     the settled subtask result.

   - **MSIL (build on `Std.Task`, not bespoke codegen IL):** since the
     `Std.Task.Scope` substrate already exists (join via `Task.WhenAll`,
     linked `CancellationTokenSource`, ambient token), the MSIL
     `scope { }` / `spawn e` keywords lower **onto that library**, not
     into hand-rolled per-scope IL. `scope { }` brackets the body with
     `makeScope()` / `defer { cancelScope; disposeScope }` and joins with
     `awaitAll`; `spawn e` registers the hot `Task<T>` with the ambient
     scope (`scopeAdd`) and binds it for a later `await`. This reuses
     tested runtime code and keeps codegen thin.
     - **V0012 constraint (still load-bearing):** the docs/09 §15
       `try { await JoinAll } catch { Cancel; throw }` shape is illegal
       (V0012 forbids `await` in a protected region), so the join is
       lowered as a **non-throwing** await —
       `await awaitAll(scope).ContinueWith(_ -> unit)` — followed by an
       `IsFaulted` check + `throw agg.Exception` *outside* any `try`
       (`AggregateException` carries first + subsequent failures, §7.4's
       aggregation for free).
     - **Sibling-cancel-on-first-fault is the one genuinely blocked
       piece.** It needs a per-task `Task.ContinueWith((Task) -> Unit)`
       continuation that cancels `__cts` on the first fault — the exact
       thing `Std.Task` dropped. **Verification (2026-07-05):** Epic
       #1877 makes the `(Task) -> Unit` lambda lower to a real
       `System.Action<Task>` (confirmed), but a direct FFI test showed
       **auto-FFI overload resolution mis-resolves the instance method
       `Task.ContinueWith(Action<Task>)`** — it picks
       `ContinueWith(Task, Object)` and throws `MissingMethodException`
       at runtime. So the residual blocker is auto-FFI
       delegate-parameter overload resolution (epic #1622 family), *not*
       lambda typing. Until that resolves, sibling-cancel is landed via a
       small audited `_kernel/task.l` helper that binds the specific
       `ContinueWith(Action<Task>)` MemberRef explicitly (an audited
       kernel extern, permitted by the `_kernel/` boundary) rather than
       through the auto-FFI guess.

3. **§7.3 (cancellation) — implement as the mechanism §7.4 needs (bundled,
   per the chosen resolution).** Every `async func` gains a compiler-
   synthesised trailing `cancellation: CancellationToken` parameter;
   `cancellation` resolves to it in the body and `cancellation.checkOrThrow()`
   lowers to `CancellationToken.ThrowIfCancellationRequested()`. Ambient
   propagation: a child `async` call inherits the caller's `cancellation`
   automatically; inside a `scope`, the ambient token is `__cts.Token`
   (so a scope failure cancels its whole subtree). This is an async-ABI
   change (every async signature, kickoff stub, SM field set, and async
   call site threads the token) and is therefore landed as its own slice
   with full parity, not folded into an unrelated change. On JVM the
   token maps onto the `StructuredTaskScope`'s own shutdown signal;
   `checkOrThrow()` checks `Thread.interrupted()`.

4. **Native — real async already, structured guarantees still open.**
   D-N-022 (landed alongside this audit) shipped the async leaf D-N-021
   anticipated (`Std.Time.sleepMillis` + LLVM coroutines + `lyric-rt`
   scheduler), so native `spawn`/`await` are genuinely concurrent — this
   entry does not alter that. What native still lacks is the §7.4
   *structured* layer (sibling-cancel-on-fault, aggregation), gated on
   native cancellation machinery (D-N-003). The V0014 structural
   enforcement (2) applies to native too; the runtime structured layer
   is a native follow-up outside this entry's MSIL/JVM scope.

**Why not "align spec to reality" (option 2c) for §7.4.** The
fire-and-forget leak is a real, reachable safety hole on MSIL (a dropped
hot `Task` runs unobserved, and its failure is swallowed) — exactly the
class of bug the language's structured-concurrency guarantee exists to
prevent. Documenting the hole as intended would institutionalise it.
V0014 (the spawned-task-must-be-consumed check) closes the hole even
before the runtime join lands, and the runtime slices deliver the rest.

**Implementation plan (slices, each its own PR / D-progress entry).**
- **S1 (this PR):** spec/doc correction, all *empirically verified* on a
  source-built `./bin/lyric` — §7.2 lazy generators (verified via an
  interleaved-side-effect probe on both targets), §7.2 `yield`+`await`
  works on MSIL / fails on JVM (verified, including a suspending
  `await delay`), §7.3/§7.4 status, docs/09 §15 rewritten to the
  library-based V0012-safe lowering, docs/09 §16 cancellation status,
  and the stale "eager collect-all" self-test/codegen headers fixed. No
  runtime codegen; no `yield`+`await` rejection (it works on MSIL).
- **S2:** V0014 — shared front-end "spawned task must be awaited or
  scope-joined" enforcement (the consumption rule, generalising native's
  value-position diagnostic). Closes the fire-and-forget hole on all
  targets without breaking the bare-`spawn`-then-`await` idiom.
  Self-contained. **SHIPPED (D-progress-598):** the mode checker rejects a
  `spawn` used as a discarded statement outside a `scope`; the broader
  unused-binding case is left as a follow-up.
- **S3:** restore **sibling-cancel-on-first-fault in `Std.Task.Scope`**
  via an audited `_kernel/task.l` `ContinueWith(Action<Task>)` helper
  (the residual FFI-overload blocker worked around at the kernel
  boundary); library-level test. This is the highest-value real §7.4
  slice and is backend-agnostic (both targets consume `Std.Task`).
  **INVESTIGATED, NOT SHIPPED (D-progress-621):** the JVM side of
  `Std.Task` was a phantom kernel entirely (fixed in D-progress-621,
  unblocking `Std.Task` on JVM generally, with a genuine sibling-cancel
  implementation). The .NET `ContinueWith(Action<Task>)` helper this
  slice proposed is confirmed unbindable (generic delegate erasure, as
  predicted above); two further alternatives and a pre-existing
  `Task.Run` delegate-invocation bug were found blocking any fix on
  .NET — see D-progress-621 for the full investigation and the
  library-level test (`lyric-stdlib/tests/task_tests.l`) that pins the
  current (partial) status on both targets.
- **S4:** JVM real structured concurrency for the *keywords* — **shipped
  (D-progress-602)** per the D120 approach (not the original
  `StructuredTaskScope.ShutdownOnFailure` wiring, which was rejected as a
  preview-only API; see D120). `scope { }` opens a non-preview virtual-thread
  `ExecutorService` closed on every exit path via a synthesized `defer`; `spawn e`
  synthesizes a capturing `Callable` (mirroring `lowerLambda`) submitted to the
  scope's executor, yielding a `Future`; `await` joins via a per-package
  `__lyric_await` helper (`Future.get()` + `ExecutionException`-cause unwrap) and
  unboxes to the spawned call's result type. Runtime self-test
  `async_spawn_self_test.l` runs on both targets.
- **S5:** MSIL cancellation-token ABI (§7.3) — implicit param threading,
  `cancellation` / `checkOrThrow()`, ambient propagation (the
  `@asyncLocal` slot already exists); self-test. Prereq for S6's ambient
  linkage (ordered before S6 so the dependency runs forward).
- **S6:** MSIL keyword lowering — `scope { }` / `spawn e` lower onto
  `Std.Task` (makeScope / scopeAdd / non-throwing `awaitAll` join per
  (2)); building on the §7.3 ambient token from S5; runtime self-test on
  `--target dotnet`.
- **S7:** JVM cancellation parity (`checkOrThrow()` → interrupt check),
  and the `defer`-across-`await` (V0012) limitation write-up / tracked
  issue.

**Related:** D-N-019, D-N-020, D-N-021 (native slices that surfaced this),
D086/D091 (MSIL async SM + `spawn` passthrough origin), D035 (async SM),
D070 (async generators), `docs/01-language-reference.md` §7,
`docs/09-msil-emission.md` §14–16, `docs/18-jvm-emission.md` §14–15,
`docs/44-jvm-production-readiness-plan.md` (B-2 correction),
`lyric-compiler/jvm/lowering.l` `lowerScopeBlock`, #1490 (async-iterator),
#2263 (JDK 24+ `StructuredTaskScope`), V0012 (await-in-try).

---
## D-progress-592 — `lyric build`/`lyric run`/`lyric test` never copied resolved NuGet dependency DLLs (or, for the manifest test path, the stdlib bundle) into the output directory, crashing at runtime with `FileNotFoundException` (#5066)

**Status:** ACCEPTED

**Symptom.** After #4925/#4955, #4980, and #5004/#5010 fixed the
compile-time NuGet resolution path, a project with a `[nuget]`
dependency built successfully but crashed at runtime:
`System.IO.FileNotFoundException: Could not load file or assembly
'Web, Version=0.4.0.0, ...'`. `lyric test --manifest` hit the same
class of bug for a different assembly:
`Could not load file or assembly 'Lyric.Stdlib, ...'`.

**Root cause, two independent bugs sharing one symptom.**

1. `buildProject` (`cli_build.l`) only called `copyRestoredDepDlls`
   (co-locate each resolved dependency DLL beside the output
   assembly) inside the `if buildKind == "exe"` branch, alongside
   native-apphost emission. A project with no `[build]` section
   defaults to `kind = "lib"` — but `lyric run` executes a `kind =
   "lib"` build directly via `dotnet exec` just the same as a `kind
   = "exe"` build's fallback path, so it needs the identical set of
   co-located dependencies. Separately, genuine third-party NuGet
   assemblies (`partitionNugetLyricDeps`'s `thirdPartyPaths` — any
   NuGet package that isn't itself a Lyric package) were only ever
   threaded into `EmitProjectRequest.nugetAssemblyPaths`, a
   compile-time-only auto-FFI reference list; no code path copied
   them to the output directory at all, regardless of `buildKind`.
2. `cmdTestManifest`'s per-test dotnet run step (`cli_test.l`) called
   `copyRuntimeDepsBeside(outPath, Environment.appBaseDirectory())`
   directly instead of the layout-agnostic `findCompiledLibDir()`
   helper every other call site uses (`cli_build.l`, `cli_run.l`, and
   even this same file's single-file `cmdTest` path). `appBaseDirectory()`
   only holds the compiled stdlib bundle when it happens to sit
   directly beside the running binary; an installed-SDK layout
   (`lib/` subdir) or a dev bootstrap tree (`.bootstrap/stage1`,
   `lyric-stdlib/bin`) needs the walk-up discovery `findCompiledLibDir()`
   performs, so the direct call silently copied nothing on any layout
   where the two differ.

**Fix.** `cli_shared.l`: factored the per-file copy body out of
`copyRestoredDepDlls` into a new `copyDllBeside` helper, and added
`copyNugetAssembliesBeside` (same best-effort semantics) for the
bare-path `thirdPartyPaths` list `partitionNugetLyricDeps` already
computed. `cli_build.l`: moved `copyRuntimeDepsBeside`/
`copyRestoredDepDlls` out of the `if buildKind == "exe"` guard so
they run unconditionally for any Dotnet-target manifest build
(apphost emission itself stays exe-only — that part genuinely is
exe-specific), and added a `copyNugetAssembliesBeside` call for
`nugetThirdPartyPaths`. `cli_test.l`: swapped the manifest test
path's `Environment.appBaseDirectory()` for `findCompiledLibDir()`,
and added the same `copyNugetAssembliesBeside` call the manifest
build path gained (the test path already called `copyRestoredDepDlls`
unconditionally — only the stdlib-discovery call and the third-party
NuGet copy were missing there).

Single-file builds (`buildOneNative`/`buildOne`) are unaffected —
that path never resolves manifest dependencies to DLL paths in the
first place (pre-existing, tracked separately as #4126).

**Verification.** Built a local repro outside the source tree: a
plain third-party `Acme.ThirdParty` .NET class library packed to a
local NuGet feed folder, and a `lyric.toml` with a `[nuget]` entry
pointing at it (via a `NuGet.Config` `<packageSources>` override —
no network access to nuget.org required) and no `[build]` section
(so `kind` defaults to `lib`, matching the issue's exact repro
shape). Before the fix, `lyric build` produced only `WebTest.dll` +
`.runtimeconfig.json` in `bin/`; after the fix, `bin/` also contains
`Acme.ThirdParty.dll` and `Lyric.Stdlib.dll`, and `lyric run` prints
the program's output successfully end-to-end (previously a
`FileNotFoundException`). Confirmed via `git stash` that an
unrelated `System.InvalidProgramException` surfaced by the
`lyric test --manifest` repro (once the missing-assembly error is
fixed) reproduces identically against unmodified `main` with zero
`[nuget]` dependencies present — a pre-existing, unrelated self-hosted
test-synthesis/codegen bug, not a regression from this fix and out of
scope for #5066.

Also corrected `docs/21-nuget-linking.md` §6, which described a
`.deps.json`-generation mechanism that was never implemented; the
actual (now-fixed) mechanism is DLL colocation beside the output
assembly, consistent with how workspace/path dependencies and the
stdlib bundle are already handled.

**Related:** #4925, #4955, #4980, #5004, #5010 (the preceding fixes
that made `[nuget]` projects build successfully, surfacing this
runtime-copy gap), #4126 (tracked follow-up for the single-file build
path).

---

## D-progress-594 — Attempted bootstrap seed cutover (#3936): sandbox verification passed, real CI caught a genuine v0.4.14-seed-only regression; reverted, filed #5094

**Status:** Attempted and reverted. #3936 remains open and blocked.

**Context.** `scripts/bootstrap.sh`'s stage-0 seed can be acquired two ways:
download the latest published self-hosted release, or mint the historical F#
bootstrap compiler from git history. `ci.yml`/`bench.yml` hard-coded
`LYRIC_BOOTSTRAP_MINT=1` and `publish.yml`'s `mint_stage0` input defaulted to
`true`, because the previously published release binary mis-emitted `>64 KB`
string-heap indices and generic-union-case TypeRef arity suffixes (fixed in
#3988). Every release since v0.4.5 is built from post-fix source, so #3936
tracks re-verifying and flipping the default.

**What was attempted.** In an isolated sandbox (GitHub API access was
proxy-restricted there, so `LYRIC_BOOTSTRAP_VERSION=0.4.14` pinned the
version, skipping the API lookup but exercising the same asset-download code
path CI uses): `LYRIC_BOOTSTRAP_MINT=0 ./scripts/bootstrap.sh --stage 1`
against v0.4.14 built cleanly (`Lyric.Cli.Program` resolved — the exact
previously-broken symptom — and `examples/fizzbuzz.l` / `examples/ffi_bcl.l`
ran correctly), and `--stage 3` held the full reproducibility fixpoint
(109/109 DLLs byte-for-byte reproducible). On that evidence,
`LYRIC_BOOTSTRAP_MINT` was dropped from `ci.yml`/`bench.yml` and
`publish.yml`'s `mint_stage0` default flipped to `false` in PR #5090.

**What real CI caught.** Neither the stage-1 smoke test nor the stage-3
fixpoint exercises the JVM target. CI's `compiler-self-tests-jvm` job failed:
multiple JVM self-tests (`pattern_lowering_self_test.l`,
`silent_miscompile_guard_jvm_self_test.l`, J3-lowering, NaN-comparison,
`lyric-resilience`'s JVM suite) crashed with
`MissingMethodException: Method not found: 'System.Single
System.Convert.ToSingle(Double)'` in `Jvm.Kernel.Program.dblToSingle`
(`@externTarget("System.Convert.ToSingle")` in
`lyric-compiler/jvm/_kernel/kernel.l`), `Aborted (core dumped)`, exit 134.

Reproduced locally and narrowed the cause: `lyric test --target jvm
lyric-compiler/lyric/pattern_lowering_self_test.l` against **stage 1**
(compiled directly by the v0.4.14 seed) crashes with the exact exception
above; the same test against **stage 2** (the self-hosted compiler
recompiling itself + the full stdlib from current source, using v0.4.14 only
as the initial seed) passes 17/17. So current source's self-hosted MSIL
emitter correctly compiles this `@externTarget` binding when it self-hosts —
the defect is in what v0.4.14's *own compiled emitter logic* does when used
directly as the compiling tool for stage 1, a third, previously-undiscovered
seed-binary bug distinct from the two #3988 already fixed.
`rewrite-corelib-refs.fsx`'s log showed no facade-mapping warnings for this
run, pointing away from the CoreLib-facade-retargeting step and toward the
MemberRef signature v0.4.14 itself emits for this overload — the exact
defect in v0.4.14's emitter was not located.

**Why the sandbox verification wasn't enough.** CI's self-test jobs run
against **stage 1** (built directly by the stage-0 seed), not stage 2. Any
residual self-hosted-emitter bug in a published release — even one already
fixed in current source, if no newer release has been cut carrying the fix —
corrupts stage 1 the moment that release is used as a download seed.
Verifying "the download path works" therefore requires running the full
self-test suite CI runs, both `--target dotnet` and `--target jvm`, against
a download-seeded stage 1 — not a stage-1 smoke test plus a
`--target dotnet`-only stage-3 reproducibility check.

**What shipped:** nothing behavioral. PR #5090's `ci.yml`/`bench.yml`/
`publish.yml`/`Makefile`/`scripts/bootstrap.sh` changes were reverted; this
entry and #5094 are the net result. `LYRIC_BOOTSTRAP_MINT=1` /
`mint_stage0: true` remain the CI/publish defaults.

**Related:** #3936 (the cutover this blocks, left open), #3988 (the two
previously-known bugs this is distinct from), #4004 (flags #3988's fix as
manually-verified-only with no automated regression test — same
full-suite-coverage gap this entry's finding closes the case for), #5094
(the new issue with full repro + proposed resolution paths), PR #5090.

---

## D-progress-596 — Three previously-undiscovered self-hosted MSIL codegen bugs found and fixed while adding `Std.Http` test coverage; one stdlib content-type bug fixed alongside

**Context.** Writing `lyric-stdlib/tests/http_tests.l` (PR #5084, part of
working through docs/57 §7's rollout list) surfaced real `main` failures in
CI, not just published-tool noise (see D-progress-543's corrected addendum
above — the initial published-`lyric`-0.4.14 repro was wrongly written off
as a release-packaging artifact before checking real CI). This session
built `./bin/lyric` from source in a sandbox that cannot reach GitHub
releases or mint the retired F# bootstrap, by feeding the published NuGet
`lyric` 0.4.14 tool's own installed DLLs into `.bootstrap/stage0-publish/`
so `scripts/bootstrap.sh`'s cached-seed check accepts them as stage 0 —
letting stage 1 recompile the *current* `lyric-compiler/**/*.l` source
(including this entry's fixes) rather than only being able to test against
whatever the published tool's own frozen behavior does. This is stage-1-only
(no stage 2/3 self-recompilation), so per D-progress-594's finding it can
carry residual v0.4.14-seed-specific defects for constructs the seed itself
mis-emits — none of the three bugs below are in that category: each was
root-caused by reading the actual `.l` source (not just observed
empirically), each reproduces identically against real CI's from-scratch
build (confirmed pre-fix on PR #5084), and all three fixes are ordinary
`if`/`match`/field-flag changes with no JVM or seed-specific surface.

**Bug A — non-projectable opaque type fields emit CLR-`Private`, not
`Internal`, breaking same-package non-method access.**
`lowerMOpaque` (`lyric-compiler/msil/lowering.l`) has two branches: a
`@projectable` opaque type's backing fields already use `FDA_ASSEMBLY`
(internal — CLR-accessible from anywhere in the same assembly/package),
with a comment explaining exactly why: the Lyric type checker enforces the
real package-level boundary, so the MSIL flag only needs to satisfy the
*assembly* boundary. The non-projectable branch — the far more common case,
used by `Std.Http.Url`, `Std.Regex.CompiledRegex`, and most opaque types in
the stdlib — never got the same treatment and still used `FDA_PRIVATE`
(CLR-`Private`, accessible only from the *declaring type itself*, not the
declaring package). A method of the opaque type's own class can still read
its private field; a free function elsewhere in the same package cannot.
`Std.Http.request(method, url)` is exactly such a free function reading
`url.value` — `System.FieldAccessException` at runtime. Fixed by changing
the non-projectable branch's `FieldRow` flags from `FDA_PRIVATE` to
`FDA_ASSEMBLY`, mirroring the projectable branch's existing, already-audited
reasoning. This only *widens* CLR access (assembly-internal ⊇ type-private),
so it cannot break any currently-working same-class access; it only fixes
the previously-broken same-package, different-class case.

**Bug B — a qualified call to a user function whose name collides with a
compiler intrinsic silently ran the intrinsic instead.**
`Std.Http.Url.toString(url)` printed `Std.Http.Url` (`Object.ToString()`'s
default) instead of executing the real, user-written
`pub func Url.toString(url: in Url): String { url.value }`.
`lowerBuiltinOrStaticCallMsil` dispatches purely on the call's *bare last
path segment* — `println`/`panic`/`assert`/`toString`/`intToLong`/
`newList`/`format1`/… and 20 total names — before ever checking whether
the qualifier names a real user-declared function of that exact name.
Since `Url.toString`'s last segment is `"toString"`, and `Std.Core`'s
global `toString(x)` intrinsic is also named `"toString"`, the intrinsic
branch always won — the user's function was never reached, cross-package
*or* same-package, for any call site. Fixed with a single guard,
`hasQualifiedFuncOverrideMsil`, computed once per call: true only when the
call path has 2+ segments (an explicit qualifier — `toString(x)` alone
never matches) *and* `cctx.funcTokens` already has a registered function
under that exact qualified FQN (or its arity-qualified key). Every one of
the 20 intrinsic-name branches is now gated on `not hasQualifiedOverride`,
falling through unchanged to the existing record-ctor / qualified-function
resolution logic that already correctly handles every *other* function
name. A grep across the entire stdlib and all 26 ecosystem libraries found
exactly one existing collision (`Url.toString`) — this was a live,
shipped-since-1.0 bug, not a hypothetical.

**Bug C — a record field typed `Option[T]`/`Result[T,E]`, constructed with
a bare `None`/`Ok`/`Err` in one already-compiled package and pattern-matched
in another, erased to `Option_None<object>` and matched neither arm.**
`HttpClientBuilder.new()` builds `HttpClientBuilder(socketPath = None, …)`;
any consumer's `match b.socketPath { case None -> …; case Some(_) -> … }`
panicked `Msil.Codegen: match not exhaustive … arms=2` — a fully exhaustive
match failing both arms at runtime. The per-constructor-argument generic
hint lookup (the loop in the "record constructor call" branch of
`lowerBuiltinOrStaticCallMsil`) resolves each field's declared type via
`cctx.fieldMsilTypes`, then pattern-matched the result with
`case MGenericInst(_, _, innerArgs) -> { …push innerArgs as the hint… }`
— but a field's declared type read back from an *already-compiled sibling
package* resolves to the structurally-equivalent but differently-tagged
`MGenericInstByName`, which fell through to `case _` (the
List/Map-collection-hint branch) instead, silently dropping the hint. A
bare `None` lowered with no hint erases its type argument
(`Option_None<object>`); the consuming package's `match` then tests for
`Option_Some<String>`/`Option_None<String>` via `isinst` against the
*correct* concrete type and neither ever matches the erased instance. Only
affects a bare nullary case (`None`, or a niladic union case) as a
*record-field initializer specifically* — `Some(value = x)` carries its own
concrete argument type regardless of representation, which is why
`withRedirects`/`withUnixSocket` (both `Some(...)`) already worked and only
the `None`-defaulted fields broke. Fixed by replacing the direct
`MGenericInst` pattern match with `genericArgsOfMsil(innerHint)` (already
used elsewhere in this same file, e.g. the match-expression scrutinee-hint
seeding at line ~8153) — it handles `MGenericInst`, `MGenericInstByName`,
and `MValueTypeGenericInst` uniformly, so the hint survives regardless of
which representation a field's type happens to resolve to.

**Why this combination went undetected for so long, despite sounding
severe.** Bug A and Bug C both require a *specific* shape no prior test
exercised: Bug A needs a free function (not a method) in the *same* package
as the opaque type reading its field — most opaque-type-consuming code lives
in a *different* package, where the (also broken, but differently) `T0100`-
style boundary rules already forced a public accessor function, and the
stdlib's own opaque accessors (`Url.toString`, `CompiledRegex`'s accessors)
happen to be dotted D037-style functions — themselves hit by Bug B, so their
`url.value`/`r.handle` reads never even reached codegen far enough to
surface Bug A's `FieldAccessException` in isolation until this session
untangled the two. Bug C needs an `Option`/`Result`-typed field defaulted to
a bare nullary case *and* consumed from a separately-compiled package — the
`HttpClientBuilder` fluent-builder pattern (build via `.new()` in one
package, inspect fields via `match` in another) is exactly this shape, but
nothing in the existing stdlib test suite matched on a builder's own
fields before `http_tests.l`. All three are now covered end-to-end by
`lyric-stdlib/tests/http_tests.l`'s 10 tests (previously 5/10 failing,
now 10/10).

**A fourth, unrelated stdlib bug fixed alongside:** `Std.Http`'s `post`/
`put`/`patch`/`withTextBody`/`postAsync`/`postWithCancelAsync` all passed
the full string `"text/plain; charset=utf-8"` as the `mediaType` argument
to `.NET`'s `StringContent(body, encoding, mediaType)` 3-arg constructor —
which builds the actual `Content-Type` header as
`{mediaType}; charset={encoding.WebName}` itself, so passing an already-
composed `mediaType` produces a doubled, invalid header value and throws
`System.FormatException: The format of value 'text/plain; charset=utf-8'
is invalid.` at every call site, unconditionally. Fixed by passing the bare
`"text/plain"` at all 6 sites — `Encoding.UTF8` supplies the `charset=utf-8`
suffix, so the actual resulting header is unchanged (matches the existing
doc comments verbatim). Confirmed against a minimal C# repro of the same
constructor overload before and after.

**Verification.** All three MSIL fixes plus the content-type fix verified
against a from-source `./bin/lyric` build (the stage-0-seed-substitution
method above): `http_tests.l` went from 5/10 to 10/10; `file_tests.l`
(11/11) and `directory_tests.l` (13/13) unaffected; the full stdlib bundle
(`lyric build --manifest lyric-stdlib/lyric.toml`, 16 packages) builds
clean; `regex_tests.l` (exercises the same opaque-type-field pattern via
`Std.Regex.CompiledRegex`) passes; and a broad sweep of the compiler's own
self-tests — `typechecker` (240), `modechecker` (47), `contract_elaborator`
(33), `cfg` (12), `derives` (45), `mono` (21, including its own
qualified-vs-unqualified-call-hijacking regression tests, #3627/#3677),
`fmt` (110), `generic_extern` (6), `enum_msil` (8), `restored_packages`
(15), `weaver` (46), `bitwise` (10), `aspect_weave` (7), `verifier` (52),
`closure_correctness` (8), and `auto_ffi` (14) — all pass with no
regressions. Real CI (which uses the proper F#-minted stage-0 seed, not
this session's substitution) is the authoritative confirmation for the
final PR.

**Related:** PR #5084 (where this was found and fixed), D-progress-543
(the corrected addendum above), D-progress-594 (documents the class of
seed-specific defect this entry's stage-1-only local build could in
principle have carried, and why none of these three bugs are in that
class), issue #5077 (the separate, larger stdlib-test-CI-wiring gap found
in the same session), docs/57 §5.1/§7.

## D-progress-598 — D119 slice S2: `V0014`, the shared front-end "spawned task must be consumed" diagnostic

**Date:** 2026-07-05
**Status:** SHIPPED

First runtime slice of D119. The mode checker (`Lyric.ModeChecker`, shared
by the MSIL, JVM, and native pipelines) now rejects the canonical
fire-and-forget mistake: a `spawn` used as a **statement outside a
`scope { }`**, where the task handle is discarded. Diagnostic **`V0014`**
("spawned task is discarded … bind and `await` it, or run it inside a
`scope { }`").

**Design — a value-position-aware positional rule.** V0014 flags a `spawn`
whose result is *discarded*: a `spawn` in statement position (through
parens) that is not lexically inside a `scope` and whose value is not used.
Consuming positions are allowed by construction: the operand of `await`
(`await spawn f()`), a binding initialiser (`val t = spawn f()`), and a
bare `spawn` statement *inside* a `scope` (the scope joins it at exit).

The check tracks **value position** — whether a statement's value is used —
so it flags the real fire-and-forget shapes without false-positiving on a
returned task (refined across review rounds #5141, #5143, #5145):
- The walk threads a `valuePos` flag; a block's value flows only to its
  **trailing** statement. A trailing `spawn` in a **value-position** block
  (a function/lambda body, an expression-block, a value-context `if`/`match`
  branch) is *returned*, not discarded, so it is **not** flagged — a
  function that returns the spawned task (`async func f(): T { … ; spawn
  g() }`) is legal (#5141).
- A trailing `spawn` in a **statement-position** block (a `while`/`for`/
  `loop` body, a `try`/`catch`/`finally` or `defer` body) *is* discarded and
  **is** flagged (#5145); likewise a `spawn` ending a branch of an `if`/
  `match` used as a non-trailing statement (its value is thrown away).
- The walk covers `IFunc`, record/exposed-record members, interface
  (`IMFunc`) and impl (`IMplFunc`) method bodies, protected-type
  `entry`/`func` bodies (`PMEntry`/`PMFunc`) (#5143), **aspect `around`
  advice** (spliced into real functions during weaving, which runs *after*
  mode checking and is never re-checked, so a fire-and-forget there would
  otherwise escape — #5158), and `test`/`property`/`fixture` bodies
  (#5159) — a superset of `checkAwaitInTry`'s coverage.

`scope` and lambda boundaries are tracked — a lambda body starts a fresh
out-of-scope, value-position context because a lambda may outlive the
enclosing scope. **Zero false positives** on the existing tree (every
extant `spawn` is a binding or `await` operand). The one remaining
follow-up is a `val` bound to a spawn but never awaited (needs
use-analysis, not positional information).

**Placement.** New pass `checkSpawnConsumption` in
`lyric-compiler/lyric/mode_checker/modechecker_check.l`, called from
`checkFileWithImports` alongside the existing `checkAwaitInTry` (V0012)
pass and mirroring its exhaustive expr/stmt walk. Skipped for `@axiom` and
`@proof_required` files (the latter already reject `spawn` via V0002, so
V0014 would double-report).

**Verification.** Fifteen `spawn` cases in `modechecker_self_test.l`
(62/62 pass): non-trailing spawn outside scope → V0014; trailing spawn in
value position → none (#5141); spawn bound + awaited → none; `await spawn`
→ none; non-trailing spawn inside a `scope` → none; non-trailing dropped
spawn in a lambda → V0014; discarded spawn in an impl method → V0014
(#5143); trailing spawn in a loop body → V0014 (#5145); spawn in a
non-trailing `if` branch → V0014 (#5145); spawn in a value-position `if`
branch → none; discarded spawn in a protected `entry` → V0014 (#5143);
spawn in a value-position `try`/`catch` → none and a trailing spawn in a
non-value `try` body → V0014 (#5148); discarded spawn in an aspect
`around` body → V0014 (#5158); discarded spawn in a `test` body → V0014
(#5159). End-to-end via `./bin/lyric build` on both `--target dotnet` and
`--target jvm` (V0014 fires identically — it is a shared front-end check).
Regression: `async_sm_self_test.l` (57/57, including the Phase-4 spawn
tests) passes unchanged; no existing spawn usage is newly rejected.

**Related:** D119 (slice plan; this is S2), D-N-022 (native value-position
diagnostic V0014 generalises), V0012 (the sibling await-in-try pass this
mirrors), V0002 (proof-required spawn rejection, deduplicated against).

## D120 — JVM structured concurrency (D119 slice S4): non-preview virtual-thread `ExecutorService`, not preview `StructuredTaskScope`; sibling-cancel + aggregation deferred to a JDK-25 follow-up

**Date:** 2026-07-05
**Status:** ACCEPTED (design/approach decision for D119 slice S4; codegen
implementation is the tracked follow-up)

**Context.** D119 slice S4 is "JVM real structured concurrency." The JVM
emission design (`docs/18-jvm-emission.md` §15) specced
`java.util.concurrent.StructuredTaskScope` (`ShutdownOnFailure`), and an
unwired `lowerScopeBlock` in `lowering.l` already emits that shape. Before
building on it, three facts (verified against the code and JDK 21):

1. **`StructuredTaskScope` is a *preview* API on JDK 21** (JEP 453 — the
   project's baseline JDK, `java -version` → 21.0.10). Using it requires
   `--enable-preview` at *both* compile and run time and a preview
   class-file marker (minor version `0xFFFF`). The JVM pipeline has
   neither: `classfile.l` supports minor `65535` but every constructor
   defaults to `0`, and no `--enable-preview` is wired into the run path.
   So adopting `StructuredTaskScope` would first require building
   preview-mode plumbing through class emission, `java` invocation, and
   bundling — a substantial prerequisite that gates *every* scope-using
   program on preview mode.
2. **`lowerScopeBlock` is unwired and never executed.** It operates on a
   `MethodAssembler` (immediate bytecode) while codegen emits the `LInsn`
   IR — a level mismatch — and it assumes **no-arg `Callable`s**, which is
   incompatible with a capturing `spawn e` closure. Its only test
   (`self_test_b120.l`) *builds* a class using it but does not run it, so
   the `StructuredTaskScope` emission has never actually executed.
3. **A non-preview substrate exists that is *final* in JDK 21:** a
   virtual-thread-per-task `ExecutorService`
   (`Executors.newVirtualThreadPerTaskExecutor()`), which is
   `AutoCloseable` (JDK 19+).

**Decision — ship the ExecutorService substrate; defer STS-only features.**
Lower `scope`/`spawn`/`await` onto the non-preview executor:
- `scope { }` → try-with-resources over
  `Executors.newVirtualThreadPerTaskExecutor()`; `close()` blocks until
  every submitted task terminates (no leaks), emitted with a `try`/
  `finally` so it closes on all exit paths (mirroring `defer`).
- `spawn e` → `__exec.submit(callable)` → `Future<T>`, where `callable` is
  a synthesized `Callable` **closure** capturing `e`'s free variables —
  the same synthesis as `ELambda`/`lowerLambda` but implementing
  `java/util/concurrent/Callable`/`call()Object` instead of
  `Lyric$Lambda`/`invoke`. Emitted as ordinary `LInsn`s (`LNew` /
  `LInvokestatic` / `LInvokeinterface`), *not* via the
  `MethodAssembler`-level `lowerScopeBlock`.
- `await handle` (handle a `spawn` `Future`) → `handle.get()`, unwrapping
  `ExecutionException` to the cause. The codegen tracks `Future`-typed
  spawn bindings (analogous to MSIL's `spawnNms`/`spawnTys`).

This delivers §7.4's **core** guarantees on JDK 21 today: **no task leaks**
(try-with-resources join), **genuine concurrency** (per-spawn virtual
threads), and **first-failure propagation** (`Future.get()` rethrow).
**Verified end-to-end** with a standalone JDK-21 program (two 200 ms tasks
complete in ~220 ms, not 400 ms; a throwing task surfaces its cause via
`ExecutionException`).

**Explicitly deferred (the two `StructuredTaskScope`-only properties),
tracked, not silently dropped:** automatic **sibling-cancel-on-first-fault**
and **failure aggregation** (every child's failure collected). These are
the `LyricAggregatingScope` features from docs/18 §15.3. The follow-up is
to swap the scope type to `StructuredTaskScope`/`LyricAggregatingScope`
once it is **final** (JDK 25, JEP 505) — at which point no preview plumbing
is needed and the existing `lowerScopeBlock` (or an `LInsn`-level port of
it) becomes usable. This is the same "ship the honest baseline now, adopt
the richer runtime when it is load-bearing and unblocked" staging D-N-021
used for native `spawn`/`scope`.

**Why not build the preview plumbing now (adopt STS on JDK 21).** It gates
every scope program on `--enable-preview`, ties the shipped feature to a
preview API that changed shape across JDK 21→24 (JEP 453→462→505; the
`ShutdownOnFailure` class this repo's `lowerScopeBlock` targets was already
removed by JDK 24), and delivers no guarantee the ExecutorService baseline
lacks except sibling-cancel/aggregation — which the follow-up adds cleanly
once the API is final. Building throwaway preview plumbing for an
already-changing API is exactly the speculative complexity CLAUDE.md's
production-readiness standard warns against.

**docs/18 §15 updated** to describe the shipped ExecutorService lowering,
retaining the `StructuredTaskScope` shape as the documented target
end-state.

**Related:** D119 (slice plan; this is S4), D-N-021 (the "ship the honest
degenerate/baseline form, gate the richer runtime on the unblocking
primitive" precedent), `docs/18-jvm-emission.md` §15, `lowering.l`
`lowerScopeBlock` (the unwired STS emission, reusable at JDK 25),
`lowerLambda`/`LClosure` (the closure synthesis the `Callable` synthesis
mirrors), V0014/D-progress-598 (the front-end `spawn`-consumption rule).

---

## D-progress-603 — General nested-block shadowing fixed on both backends: block-scoped slot allocation + name-map restore (#5191)

**Date:** 2026-07-05
**Status:** SHIPPED

Fixes a pre-existing correctness bug in **both** the JVM and MSIL self-hosted
backends: a nested-block local binding that **shadows** an enclosing, still-live
local of the same verifier type reused the enclosing binding's slot and never
restored the outer name→slot mapping on block exit, so the outer binding read the
inner (shadow) value after the block. Surfaced as the root cause of review finding
#5191 on PR #5184 (a `spawn`-bound name shadowed inside a nested block), but proven
spawn-independent and general to all locals:

```
func f(): Int { val t = 7; if c { val t = 99 }; return t }   // returned 99, should be 7
```

Both backends independently miscompiled this identically (the JVM via `allocSlot`'s
same-frame-type slot reuse, the MSIL via `allocSlotMsil`'s identical-type reuse),
because neither treated a `{ … }` block as a lexical scope for slot allocation or
name resolution.

**Fix (mirrored on both backends).**
- **Block-scoped slot reuse.** `FuncCtx` gains a `scopeBase` (`scopeBaseMsil` on
  MSIL): the slot high-water mark captured when the current nested block was
  entered. `allocSlot`/`allocSlotMsil` now reuse an existing slot for a re-bound
  name **only** when that slot was allocated at or after the base
  (`existing >= scopeBase`) — a binding in the *current* block, safe to overwrite.
  A name whose slot predates the base is an *enclosing*-scope binding; shadowing it
  falls through to a **fresh** slot, so the enclosing binding's still-live value is
  never clobbered. Same-scope sequential rebinds still reuse (leanness preserved).
- **`scope { }` body (#5204).** The JVM `lowerScopeStmt` (D-progress-602 S4)
  lowered its `scope` body via `lowerBlockStmtsFrom` directly, bypassing the
  `enterBlockScope`/`exitBlockScope` bracket, so a `val`/`var` declared directly
  in a `scope` body (not further nested in an `if`/`match`/loop, which are
  bracketed) shadowing a still-live enclosing binding reused its slot — the exact
  bug this entry fixes, for the one construct S4 ships real semantics for. Fixed
  by bracketing the body lowering the same way `lowerBlock` does, with the
  executor's own slot allocated *outside* the bracket so it stays live for the
  synthesized close-defer. The MSIL `SScope` handler already routed through the
  bracketed `lowerBlockMsil`, so it needed no change. Covered by a
  `scopeBodyShadow` case in `block_shadow_self_test.l`.
- **Name-map restore via a change log.** `enterBlockScope`/`exitBlockScope`
  (`…Msil` on MSIL), wrapping `lowerBlock`/`lowerBlockExpr`
  (`lowerBlockMsil`/`lowerBlockExprMsil`) — and the JVM `lowerScopeStmt` body
  (#5204) — bracket each block. `allocSlot`
  (`allocSlotMsil`) calls `recordScopeUndo` (`…Msil`) before every (re)binding to
  push the name's prior `Option[slot]` / `Option[type]` onto a per-function
  `scopeUndo` log; `exitBlockScope` replays the entries pushed during the block
  (innermost first) back to the entry mark, restoring each enclosing name→slot /
  name→type mapping the block overwrote and dropping names the block introduced.
  `enterBlockScope` returns just two ints (`prevBase`, `undoMark`) — no generic
  collections cross a function boundary.
  - A **change log**, not a whole-map `mapEntries` snapshot: the snapshot form
    both mis-monomorphised under the pinned F# stage-0 mint (its nested-generic
    `List[MapEntry[String, …]]` entry types produced corrupt IL) and, once
    compiled, corrupted the codegen dictionaries at runtime during the whole-map
    enumeration inside `mapEntries`. The change log touches `slots`/`types`
    exactly the single-key way (`mapGet`/`add`/`remove`/`containsKey`) that
    `allocSlot` already does — no whole-map iteration anywhere.
  - The binding-metadata maps (`varGenericArgs` on JVM, `funcValRetTypes`/
    `funcValParamTypes` on MSIL, and the hoisted-cell maps) are NOT scoped: they
    were never restored before this fix either (the JVM's `recordVarGenericArgs`
    already overwrites shadow-safely at the binding site), so leaving them is not
    a regression — the value-clobbering bug is fixed by the `slots`/`types` +
    `scopeBase` machinery alone.
- **Ticker not rolled back.** Inner slots stay allocated (dead after the block).
  On JVM this keeps every slot a single verifier type across the method's uniform
  StackMapTable frame (the reason `allocSlot` already gated reuse on
  `sameFrameSlotType`); on MSIL it keeps the LocalVarSig valid and composes with the
  discard-relower (`rollbackFuncCtxSlotsSinceMsil`) and async-SM promoted-local
  tracking. `var` reassignment through a nested block is unaffected — assignment
  resolves the still-in-scope slot rather than rebinding.

**Verification.** A 10-case shadow suite (plain `if`-then, `if`/`else`, nested
doubles, `while`-body shadow, `var` mutation through a nested block, `match`-arm
shadow, value-producing block shadow, reference-typed shadow, sibling scopes)
returns the correct value on **both** `--target jvm` and `--target dotnet`. No
regression across the native `lyric test` CI suite (compiler self-tests, `async_sm`
57/57, `closure_correctness`, `bitwise`, `aspect_weave`, `async_spawn`,
`closure_zero_overhead`, `auto_ffi` on both targets). Re-verified against the pinned
F# stage-0 mint (`FS_COMMIT=35c0d2e5`). No new MSIL/JVM codegen surface; the fix is
purely in slot allocation and lexical-scope bookkeeping.

**Files:** `lyric-compiler/jvm/codegen/{01_types,02_exprs,05_stmts,06_items}.l`,
`lyric-compiler/msil/codegen.l`, `docs/18-jvm-emission.md` §15.3.

**Related:** D-progress-602 / #5184 (the PR whose review surfaced #5191),
D-progress-569 (`varGenericArgs` remove-then-add shadow-safety, the narrower
precedent this generalises), `docs/18-jvm-emission.md` §15.3.

---

## D-progress-602 — D119 slice S4: JVM structured-concurrency keyword codegen (`scope`/`spawn`/`await`) shipped per D120; MSIL async spawn-in-scope pre-scan fix

**Date:** 2026-07-05
**Status:** SHIPPED

Implements the D120 design for D119 slice S4 in the self-hosted JVM backend
(`lyric-compiler/jvm/codegen/`), plus a companion MSIL async-SM fix surfaced by
the shared self-test.

**JVM keyword lowering.**
- `scope { body }` (`05_stmts.l` `lowerScopeStmt`) opens
  `Executors.newVirtualThreadPerTaskExecutor()` into a fresh local, makes it
  visible to `spawn` via a new `FuncCtx.scopeExecSlots` stack, and closes it on
  **every** exit path. The close is routed through a synthesized
  `defer { __lyric_jvm_close_executor(<exec>) }` prepended to the body, so the
  existing defer machinery (fall-off, early return/break/continue replay, and the
  exception catch-all) drives it — D120's "closes on all exit paths (mirroring
  defer)". The close intrinsic is intercepted in `lowerCall` and emits
  `ExecutorService.close()` (blocks until every task terminates).
- `spawn e` inside a scope (`02_exprs.l` `lowerSpawnSubmit`/`lowerSpawnCallable`)
  synthesizes a capturing `Callable` closure — the same `LClosure`/`closureAcc`
  synthesis as `lowerLambda`, but implementing `java/util/concurrent/Callable`
  (`call()Object`, no arg-array prologue) — and `submit`s it to the innermost
  scope executor, yielding a `Future`. A `spawn` outside any scope stays
  degenerate (runs `e` synchronously).
- `await` on a spawn `Future` (`lowerFutureGet`) calls a per-package
  `__lyric_await` static helper (`06_items.l` `makeAwaitHelperFunc`, emitted when
  the package synthesized any closure) that does `Future.get()` and unwraps
  `ExecutionException` to its cause. A helper — not an inline try/catch — because
  `await a + await b` leaves the first result on the operand stack while the
  second await lowers, and an inline exception region would begin with a
  non-empty stack (StackMapTable "bad offset" / frame mismatch); `invokestatic`
  is atomic. The joined `Object` is then unboxed to the spawned call's result
  type (tracked in `FuncCtx.spawnResultTypes`, populated at the binding via the
  callee's `JvmFuncSig.ret`), so `await a + await b` sees two primitives rather
  than the both-`Object` arithmetic gap (#2862).
- Two supporting JVM-codegen fixes the shared self-test surfaced:
  `stmtTerminates` now treats a `scope { … return … }` as terminating (so the
  function epilogue does not append a stray void `return` in a value-returning
  method), and `lowerDeferRegion` no longer emits the join label when the
  protected suffix already transferred control (a dead label at a method's tail
  otherwise produced a code-end StackMapTable frame — "bad offset" at load).

**MSIL async pre-scan fix.** The shared self-test also runs on `--target dotnet`
(where `async func`s are real `Task<T>` state machines and `spawn`/`scope` are
degenerate pending S5/S6). The Phase B await pre-scan
(`collectAwaitTypesPhaseBMsil`) collected `val x = spawn f()` bindings only from
the outermost block, so a spawn bound inside a `scope { }` was missed and a later
`await x` crashed codegen ("await index exceeds pre-allocated resume labels").
The pre-scan now recurses into block-bearing statements (`scope`, loops, `try`)
via `collectSpawnBindingsBlockMsil`; `if`/`match` branch bindings remain a
documented deferred case.

A follow-up (#5205) extended the same pre-scan to `var handle = spawn f()`
(`LBVar`) bindings and `handle = spawn g()` (`SAssign`) reassignments —
`collectSpawnBindingLocalMsil` previously handled only `LBVal`, so a reassignable
spawn handle (the retry idiom) awaited later hit the identical "await index
exceeds pre-allocated resume labels" divergence. On the JVM side the same #5205
finding wired `recordSpawnResultType` into `lowerAssignExpr`'s `SAssign` case
(previously only `SLocal`), so a reassigned handle's `spawnResultTypes` slot entry
refreshes and a later `await` unboxes to the new spawn's return type. (The
reviewer's stated `ClassCastException` does not actually reproduce — a `var`'s
fixed type keeps both spawns' return types identical, so the stale entry was
already value-correct — but the symmetric wiring is the correct robust behaviour
and closes the real `SLocal`/`SAssign` asymmetry.)

**Test.** `lyric-compiler/lyric/async_spawn_self_test.l` (`@test_module`, both
targets) covers two spawns joined by early `return` inside a scope, the same by
fall-off, a bare no-scope spawn, three concurrent spawns, and a `Unit`-returning
spawn. Test blocks `await` the async helpers so the value resolves on both the
degenerate-synchronous JVM path and the blocking-`GetAwaiter().GetResult()` MSIL
path (as `async_sm_self_test` does). Verified: MSIL 5/5 via `lyric test`, and the
JVM real-concurrency codegen for every shape via standalone `--target jvm`
programs.

**Deferred (unchanged from D120):** JVM sibling-cancel-on-first-fault and failure
aggregation (the `StructuredTaskScope` properties), pending JDK 25.

**Related:** D120 (the design), D119 (slice plan), D-progress-598 (V0014),
`docs/18-jvm-emission.md` §15, #2862 (both-`Object` arithmetic gap).

---

## D-progress-595 — Two CI safety-net jobs: stage-2 self-testing (#5099) and per-release seed candidacy (#5094 resolution path 3)

**Status:** Shipped. Neither #5094's underlying v0.4.14 emitter defect nor
#3936's blocked cutover is resolved by this entry — both new jobs are
detection, not a fix.

**Context.** D-progress-594 / #5094 found that CI's self-test jobs verify
only stage 1 (built directly by whatever the stage-0 seed is), and that a
download-seeded stage 1 can carry a seed-binary-specific defect invisible to
every existing job, since `ci.yml`/`bench.yml` force
`LYRIC_BOOTSTRAP_MINT=1`. #5099, filed from the same investigation,
generalised the finding: stage 1 testing can never verify "the self-hosted
compiler correctly compiles itself" (stage 2's defining property, and the
property the shipped artifact — standalone binaries, the NuGet global tool —
actually depends on), because stage 1 is materialized by the seed, not by
self-hosting.

**What shipped.**

1. `.github/workflows/stage2-self-test.yml` (#5099) — a nightly-scheduled
   (`workflow_dispatch`-triggerable) job that runs `./scripts/bootstrap.sh
   --stage 2` (mint stage-0, matching every other CI job — this job isolates
   self-hosting correctness, not seed-download trust), asserts stage 2 is
   runnable as a hard gate (`bootstrap.sh`'s own stage-2 smoke check is
   deliberately non-fatal under its runnability-first model; this job
   re-asserts it as a gate so a non-runnable stage 2 cannot silently read as
   green), then runs a representative self-test subset — front-end,
   middle-end, and both backend targets — against the stage-2 binary with
   `LYRIC_STDLIB_BIN` pinned to `.bootstrap/stage2/lib` (`make run-stage2`'s
   existing pattern). Deliberately includes `pattern_lowering_self_test.l`,
   `silent_miscompile_guard_jvm_self_test.l`, and `j3_lowering_self_test.l` —
   the three tests D-progress-594 found actually distinguished a broken
   stage 1 from a correct stage 2.
2. `.github/workflows/seed-candidacy.yml` (#5094 proposed resolution path 3)
   — triggered on every `release: published` event (plus `workflow_dispatch`
   for testing an arbitrary past version, e.g. re-confirming v0.4.14):
   downloads that release as a `LYRIC_BOOTSTRAP_VERSION` seed with
   `LYRIC_BOOTSTRAP_MINT` deliberately left unset (every other CI job sets it
   to `1`, which is precisely why the v0.4.14 regression went undetected
   until a manual #3936 attempt), builds stage 1 from it, and runs the same
   representative self-test subset against that download-seeded stage 1 for
   both `--target dotnet` and `--target jvm`. On failure it files (or
   re-confirms) a `seed-regression`-labeled tracking issue naming the
   offending version, so a bad seed candidate is discoverable without
   babysitting workflow run history.

Both jobs run a curated subset, not the full `ci.yml` self-test matrix — a
full self-host build already costs roughly double a stage-1-only build, and
duplicating literally every stage-1 self-test step in either job would
double CI cost again on top of that (stage2-self-test.yml on top of its own
nightly cadence, seed-candidacy.yml on top of every release). The subset and
the reasoning for it are logged in both workflow files' comments rather than
silently applied, per the coverage explicitly called out in each job.

**What this does NOT do:** it does not root-cause the v0.4.14
`dblToSingle`/`Convert.ToSingle(Double)` defect (still unlocated — D-progress-594
narrowed it to "the MemberRef signature v0.4.14's own emitter produces for
this overload" and no further), and it does not unblock #3936 — that cutover
still requires either locating and fixing the defect, or cutting a new
release whose own stage-0 seed is confirmed clean by `seed-candidacy.yml`
before it is adopted as the new download-seed default.

**Related:** #5094, #5099, D-progress-594 (the investigation both jobs
respond to), #3936 (the cutover `seed-candidacy.yml` is meant to eventually
de-risk), #3988 (the two prior release-corruption bugs), `docs/10-bootstrap-progress.md`
§"Bootstrap vs self-hosted — which compiler am I running?" (the compiler-identity
table #5099's framing is built on).

---

## D-progress-599 — Self-hosted MSIL bundler: a cross-package closure silently corrupted every later FieldDef/MethodDef token, including the entry point (#5177)

**Status:** ACCEPTED

**Symptom.** #5177 reported `System.MissingFieldException` on a real
multi-package `output = "single"` project, naming a field
(`CloudAgents.Db.RecycleAction.StopAndIdle`) that the crashing function
never references and that raw PE-metadata inspection confirmed is present,
public, and correctly shaped. Every attempt to reproduce with a synthetic
multi-package project — enums, unions, protected types, config blocks,
distinct types, records, interfaces/impls, async functions with
`for`/`while`/`match` + `await`, non-literal module-level `pub val`s, up to
13 packages and ~250 declared items — ran correctly. The eventual
reproduction needed a completely different ingredient the original report's
own failed-repro list never tried: a capturing lambda (`{ x: Int -> ... }`
closed over an outer `var`) declared in one in-bundle package and called
from another. A minimal 2-package repro reproduces reliably; metadata
inspection (`System.Reflection.Metadata.PEReader`) on the miscompiled
output showed the exact mechanism: two things, compounding.

**Root cause, two independent bugs sharing one symptom.**

1. `Msil.Codegen.codegenMPackage`'s closure-record emission (`## Epic #1877
   Phase 2`) walked `cctx.lambdaClosureRecordList` — a list of synthesized
   `__Closure_<i>` records shared across the *entire bundle* (one `cctx`
   lowers every package) — from index 0 on every call. `codegenMPackage`
   runs once per package, so any package processed after the one that
   synthesized a closure re-walked from 0 and re-emitted that same closure
   record into its own `MPackage` too. Confirmed via `PEReader`: a 2-package
   bundle with one closure in package A produced *two* separate `TypeDef`
   rows both named `A.__Closure_0` (with their own duplicate `.ctor`
   `MethodDef` and captured-var `FieldDef`), the second interleaved into
   package B's own item list.
2. Even with (1) fixed (a per-`cctx` cursor,
   `lambdaClosureEmittedCount`, so each record drains exactly once),
   the closure record still landed physically *in between* the two
   packages' own items in the final `TypeDef`/`MethodDef`/`FieldDef`
   tables. `addPackageTokens`'s two-pass FieldDef/MethodDef row prediction
   (the running `fieldDefRow`/`methodDefRow` counters threaded across
   packages, first documented for this bug class at #3196) has no way to
   account for that closure row: a closure class is synthesized during
   *expression lowering* (`synthesizeClosureClassMsil`, invoked from inside
   `lowerExprMsil`'s `ELambda` arm once real codegen reaches the capturing
   lambda's construction site), never from a source-level `Item` the
   pre-scan pass can see or count ahead of time. So every predicted token
   for anything in a *later* package — including `cctx.mainEntryToken`,
   recorded from the very same predicted `funcTok` — silently pointed one
   row (per bundle-wide closure) too early. Confirmed via `PEReader`: the
   PE's COR header entry-point token resolved to the closure's own `.ctor`
   `MethodDef`, not `main` — the "field not found" symptom's sibling for
   method tokens.

**Fix.** `lyric-compiler/msil/codegen.l`: removed the per-package drain
from `codegenMPackage` entirely and extracted it into a standalone
`drainLambdaClosureRecordsMsil(cctx)`, gated by the new
`lambdaClosureEmittedCount` cursor (mirrors the existing
`nextFieldDefRow`/`nextMethodDefRow` length-as-value counter convention).
`lyric-compiler/msil/bridge.l`: call the drain exactly once — immediately
after the lone `codegenMPackage` call for a single-file compile
(`compileToMsilWithVersion`), and once after *every* package's
`codegenMPackage` call for a bundle (`compileProjectToMsilWithRestoredAndVersion`),
appending the result onto the *last* package's `MPackage.items`. This is an
architectural fix rather than a matching prediction: closures for the whole
bundle now always sort after every package's own items, so no package's
`addPackageTokens` prediction ever needs to account for a closure row
landing before it — sidestepping the "two independently-maintained
bookkeeping passes must agree" hazard entirely for this construct, rather
than adding a third piece of duplicated (and equally driftable) capture-count
prediction logic to `addPackageTokens`.

**Verification.** All of `closure_correctness_self_test.l` (8/8),
`closure_zero_overhead_self_test.l` (18/18), `async_sm_self_test.l`
(57/57), `cross_package_generics_self_test.l` (6/6),
`aspect_weave_self_test.l` (7/7), and `bitwise_self_test.l` (10/10) pass
unchanged. Added `msil_project_bridge_self_test.l`'s "cross-package closure
does not corrupt later tokens or the entry point" — a 2-package repro
pinning both a same-package function declared after the closure and a
second package's entry point. Also re-ran the synthetic 13-package,
~250-item stress project built while investigating #5177 (enums, unions,
protected types, config blocks, distinct types, async control flow) plus
the minimal reproductions built along the way — all produce correct output
and correct `PEReader`-inspected metadata (single `TypeDef` per closure,
correct entry-point token) after the fix, where they previously either
threw `System.MissingFieldException`/`InvalidProgramException` or produced
a corrupted entry point.

**What this does NOT do:** it does not confirm this was cloud-agents'
*exact* trigger for #5177 (the original report's project was not directly
reproduced against — only a synthetic minimization exercising the same
mechanism); the issue should stay open until re-verified against the
original repro or a NuGet release incorporating this fix. Two unrelated
bugs surfaced incidentally while building repro projects for this
investigation — an aspect-weaving `InvalidProgramException` when advice
runs a statement after `proceed(args)` (#5182), and a contract-elaborator
`InvalidProgramException` for `ensures: result.isOk implies result.value ...`
over a `Result[T, E]` where `E` carries payload fields (#5183) — are filed
separately and are out of scope here.

**Related:** #5177 (the reported symptom), #3196 (the first documented
instance of this general "prediction pass has a blind spot for a
codegen-synthesized item kind" bug class, for enum `value__` fields),
#5030 and #4958/#4947 (two further instances of the same class, for
cross-package field signatures and an unaccounted `RMFunc` row
respectively), #5182, #5183 (unrelated bugs found during the investigation).

---

## D-progress-600 — Self-hosted MSIL bundler: an `async func` awaiting a call into a LATER package silently corrupted every intervening package's tokens (#5177, second root cause)

**Status:** ACCEPTED

**Context.** D-progress-599 fixed one confirmed cause of #5177's symptom
(cross-package closures) but the reporter re-verified against a v0.4.16
build carrying that fix and #5177 still reproduced identically against the
real `cloud-agents` project — which uses no closures or module-level
`pub val`s at all. With direct access to both `lyric-lang` and
`cloud-agents` this session, the reporter (in a prior session, per the
issue comments) narrowed it to a clean 4-package repro and identified the
actual differentiator: an `async func` that `await`s an (unqualified,
imported) call to a function declared in a **later** package, per
`[project.packages]` declaration order.

**Symptom.** Same class as D-progress-599: a function with zero source-level
relationship to the async machinery (`dbErrorMessage`, matching an unrelated
union) throws `InvalidProgramException`/`MissingFieldException` depending on
exactly which real row its miscounted token lands on. `PEReader` inspection
(reused from the closure investigation) pinned it precisely: `dbErrorMessage`'s
`ldfld` for a union case's payload field encoded token `0x04000004`, which
really names a completely different type's field
(`Manager.<createRunner>__SM_0.__aw0`, an async state-machine's awaiter
field) — the correct field, `DbError_OpenFailed.message`, sits one row later
at `0x04000005`.

**Root cause.** `Msil.Codegen.addPackageTokens`'s FieldDef/MethodDef
row-prediction pass runs once per package, strictly in
`[project.packages]` declaration order. For an `async func`,
`countSmFieldsMsil` needs to know how many *awaiter* fields the
synthesized state-machine class will need — one per distinct `await`ed
Task type — which it determines via `collectAwaitTypesPhaseBMsil` /
`inferCallReturnTypePB`, resolving the awaited call's return type through
`cctx.funcRetTypes` (and, for the "does this import even have this
function" existence check, `cctx.funcTokens` via `findImportedFqn`). Both
maps are populated by `addPackageTokens` itself, in the SAME per-package,
declaration-order pass. So when package K's `async func` awaits a call
into package K+n (n > 0, not yet visited), the callee's return type is
unresolved (`MObject`), `isTaskTypeMsil` rejects it, and the awaiter field
this await genuinely needs goes uncounted — the prediction comes up one
field short. The REAL codegen (`codegenMPackage`, which for the whole
bundle runs only after every package has already been through
`addPackageTokens`) resolves the same call with a fully-populated
`funcRetTypes` and correctly emits the awaiter field — so the real SM class
ends up with one more field than was predicted, and every FieldDef/
MethodDef token predicted for any package *after* the awaiting one is off
by one from that point forward. Exactly the same "two independently
maintained bookkeeping passes must agree, and one has a blind spot"
architecture hazard as D-progress-599 and #3196/#5030/#4958/#4947, this
time triggered by call-graph order diverging from package-declaration
order rather than by a codegen-only-synthesized item.

An existing, narrower version of this same mechanism was already present
and correctly handled: `addPackageTokens`'s own "Pre-pass 0" seeds a
Task/Task<T> return-type placeholder for every async function *in the
same file*, specifically so a same-package forward reference (one async
function awaiting another declared later in the same package) resolves
correctly. It just never extended across package boundaries.

**Fix.** `lyric-compiler/msil/codegen.l`: extracted Pre-pass 0's per-function
body into `seedAsyncFuncRetTypePlaceholderMsil`, and added
`preSeedBundleAsyncRetTypesMsil`, which walks every package's (already
parsed + mono'd) items and, for every function bundle-wide: (1) registers
its bare `pkgName.funcName` into a new `cctx.bundleFuncFqns` existence-only
marker set, and (2) if async, seeds the same Task/Task<T> placeholder
Pre-pass 0 already seeds per-file. `findImportedFqn` and
`findImportedFqnWithHint` now also check `bundleFuncFqns` alongside
`funcTokens` — `bundleFuncFqns` is never used for a token's numeric value
(only existence), so pre-seeding it can't shadow or block a package's own
later, real `funcTokens` registration the way seeding `funcTokens` itself
with a placeholder would have. `lyric-compiler/msil/bridge.l`: call
`preSeedBundleAsyncRetTypesMsil(cctx, perPkgFiles, perPkgNames)` once,
right after `prescanProjectableFqns` and before the per-package weave/
lift/`addPackageTokens` loop starts — mirroring that existing bundle-wide
pre-seed's exact placement and calling convention. A no-op for a
single-file compile (nothing to seed ahead of; the per-file Pre-pass 0
already covers it).

**What this does NOT do.** While narrowing this fix, a fully-qualified
cross-package `await` (`await Pkg.Sub.createContainer(id)` instead of the
unqualified, imported-name form `await createContainer(id)`) was found to
hit a *different*, pre-existing crash (`emitPhaseBAwait: await index 0
exceeds pre-allocated resume labels`) — confirmed present identically both
with and without this fix (verified by temporarily reverting via `git
stash` and re-testing), so it is a separate bug in the qualified-path
branch of `inferCallReturnTypePB`'s candidate resolution, not a regression
from or a target of this change. Filed and tracked as #5222.

**Verification.** Reproduced the reporter's exact 4-package minimal repro
(`Manager` awaits `Primitives.createContainer` unqualified, with an
unrelated `Consumer` package declared in between) via `PEReader` inspection
before and after: `dbErrorMessage`'s `ldfld` moves from the wrong token
(`0x04000004`, `Manager.<createRunner>__SM_0.__aw0`) to the correct one
(`0x04000005`, `DbError_OpenFailed.message`), and the program now runs
correctly end-to-end. Re-ran the full existing suite plus D-progress-599's
new test — `async_sm_self_test.l` (57/57), `closure_correctness_self_test.l`
(8/8), `closure_zero_overhead_self_test.l` (18/18),
`cross_package_generics_self_test.l` (6/6), `aspect_weave_self_test.l`
(7/7), `bitwise_self_test.l` (10/10), `msil_await_expr_forms_self_test.l`
(5/5), `inbundle_generics_self_test.l` (20/20), `async_extern_self_test.l`
(4/4), `generic_specialization_self_test.l` (8/8),
`async_generator_self_test.l` (8/8) — all pass. Added a new
`msil_project_bridge_self_test.l` case ("async func awaiting a call into a
LATER package does not corrupt an unrelated package's field access")
reproducing the minimal 4-package shape end-to-end via `dotnet exec` and
asserting stdout — 28/28 in that file including it.

**Related:** #5177 (the reported symptom; this is the SECOND of at least
two independent root causes found for it — see D-progress-599 for the
first), #3196/#5030/#4958/#4947 (the same "prediction pass has a blind
spot" bug family), D-progress-599 (this issue's first fix, and the
`PEReader`-based investigation technique reused here), #5222 (the
fully-qualified cross-package `await` crash found — and confirmed
pre-existing — while narrowing this fix).

---

## D-progress-606 — MSIL: cross-package qualified module-val access silently resolved to null (#5258)

**Status:** ACCEPTED

**Symptom.** In a single-bundle multi-package project (`[project.packages]`,
`output = "single"`), a cross-package qualified reference to another
package's module-level `pub val` (e.g. `App.Util.httpsPrefix` referenced
from `App.Main`) silently resolved to `null` at runtime instead of the
actual static field — `println(App.Util.httpsPrefix)` threw
`NullReferenceException`; depending on how the mistracked value was used
downstream, a `.length` call on it could instead throw `InvalidCastException:
Unable to cast String to IList` (the exact symptom of a downstream bug
report this fix traces back to, alongside #5177/#5222's cross-package
token-corruption family — a separate root cause hiding behind
superficially similar-looking "cross-package access breaks" reports).

**Root cause.** `App.Util.httpsPrefix` parses as nested `EMember`s
(`EMember(EMember(EPath(["App"]), "Util"), "httpsPrefix")`), not a flat
multi-segment `EPath` (`parser_exprs.l`'s `parsePostfixExpr` wraps the
receiver in one more `EMember` layer per `.ident`; only a single bare
identifier ever produces `EPath`). Cross-package **qualified free-function
calls** already handled this shape correctly: `lowerMethodCallMsil`
flattens the receiver via `flattenPathExprSegs` and checks the flattened
dotted name against `funcTokens` before falling back to method dispatch
(the #3332/#3349 fix family). **Module-level `pub val`/`pub const` access
in value position had no equivalent** — `lowerExprMsil`'s `EPath` arm's
"Module-level val" fallback (`staticValTokens`/`staticValMsilTypes`) was
keyed by the bare name only and was only reached for a genuinely
single-segment `EPath`, so a qualified reference never reached it at all;
it fell through `EMember`'s generic record-field-access fallback (no case
for "this is actually another package's static field") and defaulted to
pushing a null literal.

**Fix.** `lyric-compiler/msil/codegen.l`: `staticValTokens`/
`staticValMsilTypes` now also register a package-qualified key
(`pkgName + "." + name`) alongside the existing bare-name key, mirroring
`funcTokens`'s FQN convention. A new `tryQualifiedStaticValNameMsil`,
short-circuited at the top of `lowerExprMsil` (same pattern and same
"don't restructure the `EMember` arm" safety rationale as the existing
`tryQualifiedEnumOrdinalMsil` check), flattens an `EMember` chain via the
existing `flattenPathExprSegs`, guards against a local-variable-rooted
chain, and emits `ldsfld` directly when the flattened dotted name matches
a registered qualified static val.

**Scope boundary.** Two related gaps are documented, not fixed, here:

1. The restored-dependency case (`[dependencies] = { path = ... }`, two
   separately-compiled DLLs) has the identical symptom via a completely
   different mechanism — contract-metadata cross-DLL resolution
   (`Lyric.ContractMeta`/`Lyric.RestoredPackages`) doesn't emit non-literal
   `pub val` declarations at all today (only literal-foldable `pub const`s
   round-trip, via the pre-existing, unrelated compile-time-inlining path).
   Fixing it needs a contract-metadata schema change; ties into the
   docs/45 phased work, whose phases 2–5 are already deferred pending
   #2580.
2. JVM: multi-package manifest builds don't support `--target jvm` at all
   yet (a separate, already-tracked gap per docs/44), so the JVM analog
   isn't independently testable via the documented multi-package flow
   today. By code inspection, `Jvm.Codegen`'s `EPath` handling
   (`ctx.moduleVals`, bare-name-keyed) and `lowerMethodCall` (single-segment
   qualified calls only, no `flattenPathExprSegs` equivalent) have the same
   shape of gap and will need the analogous fix once JVM multi-package
   builds work.

**Verification.** Added `msil_project_bridge_self_test.l`'s "multi-segment
qualified static val resolves correctly" (mirroring that file's existing
"multi-segment qualified call resolves correctly" test for the function
case) — reads a qualified `pub val`, its `.length`, and a qualified `pub
func` call, all from a different package in the same bundle — 29/29 in
that file including it. `enum_msil_self_test.l` (8/8, touches the same
`lowerExprMsil` short-circuit area) and `slice_ops_self_test.l` (13/13)
pass unchanged.

**Related:** #5248 (the PR this fix was found while investigating a
downstream report against), #5177/#5222/D-progress-599/D-progress-600
(a different cross-package MSIL bundler bug family with superficially
similar symptoms), docs/45 (contract-metadata direct resolution, relevant
to the restored-dependency scope boundary above).

---

## D-progress-608 — MSIL: untyped top-level `val`'s inferred type defaulted to `MObject`, crashing `.length` with `InvalidCastException: String -> IList` (#5298)

**Status:** ACCEPTED

**Symptom.** A package-scope (top-level) `val` declared without an explicit
type annotation, whose initializer is a `String` literal (e.g. `val prefix
= "https://"`), crashed at runtime with `System.InvalidCastException:
Unable to cast object of type 'System.String' to type
'System.Collections.IList'` when its `.length` property was read —
anywhere in the program, including from the same package, with no
cross-package reference involved. Explicitly annotating the `val` (`val
prefix: String = "https://"`) was one, but not the only, workaround.

**Root cause.** `lyric-compiler/msil/codegen.l`'s item pre-scan (the pass
that registers package-scope `IVal` declarations' MSIL type for later
`EPath`/qualified-access reads via `cctx.staticValMsilTypes`) only recorded
the correct type when the `val` had an explicit annotation
(`typeExprToMsilCtx(cctx, te, pkgName)`); an untyped `val` — `decl.ty ==
None` — fell back to `MObject` unconditionally, discarding the fact that
the initializer was a string literal. A read site later looked up this
recorded `MObject` type and fed it into `.length`'s generic-receiver
fallback arm, which assumes any `MObject`-typed receiver is a
`List`-backed slice and unconditionally emits `castclass IList` +
`ICollection.get_Count` — correct for actual slices (whose static type
also erases to `MObject`), wrong for a boxed `System.String`, which does
not implement `IList`. The field's *actual* runtime type was already
inferred correctly at the separate emission-site pass (`lowerExprMsil` on
the initializer, used to build the real FieldDef signature) — only the
pre-scan's separately-tracked bookkeeping copy was wrong, so the produced
program was internally inconsistent: a real `String` field whose readers
believed it was an opaque `MObject`/List.

Not a regression — present since early static-val support, independent of
D-progress-606's cross-package qualified-access fix (#5258), which added
qualified lookup keys to the same maps but did not touch the
`decl.ty`-only inference this bug lives in.

`ConstDecl.ty` is a non-optional `TypeExpr` in the AST (`parser_ast.l`), so
the equivalent `IConst` arm cannot hit this gap — the bug is `IVal`-only.

**Fix.** Added `inferUntypedStaticValMsilType(e: in Expr): MsilType`,
matching on `decl.init`'s literal shape (String/triple-string/raw-string →
`MString`, float → `MDouble`, int → `MInt`/`MLong` per range and suffix,
bool/char/unit → `MBool`/`MChar`/`MVoid`, interpolated string → `MString`,
parenthesized → recurse), used at the `IVal` pre-scan arm in place of the
`MObject` default whenever `decl.ty` is `None`. Anything outside this
literal set (calls, records, collections, …) still falls back to
`MObject` — unchanged prior behavior for those shapes; an explicit type
annotation is still required to type those precisely.

**Verification.** Reproduced the reporter's exact single-file repro (an
untyped top-level `val` whose `.length` is read from `main`) end-to-end:
built the self-hosted compiler from source with this fix (stage 1, using
the published NuGet `lyric` 0.4.18 tool as the stage-0 seed, since this
sandbox's GitHub API release-listing call is blocked but direct release-
asset downloads work — see D-progress-543's sandbox-limitation precedent),
confirmed the unpatched 0.4.18 tool reproduces the crash on the repro
verbatim, then confirmed the locally-built fix runs it cleanly. Extended
`lyric-compiler/lyric/module_val_self_test.l` with an untyped `String` val
(`untypedGreeting`) and two new tests: reading `.length` directly, and
reading it through a separate top-level helper function (matching the
downstream report's "read via a helper function" shape) — both assert the
correct length rather than faulting. `lyric test
lyric-compiler/lyric/module_val_self_test.l` against the local build: all
tests pass.

**Review hardening (same PR, #5300).** `claude-review` on PR #5299 found
`inferUntypedStaticValMsilType` didn't unwrap `EPrefix(PreNeg, ...)` — the
AST shape for a leading unary minus (`val minTemp = -40` parses as
`EPrefix(PreNeg, ELiteral(LInt(40)))`) — so a negative-literal untyped val
still fell through to the `MObject` default even though its real FieldDef
type is a primitive `Int`/`Long`/`Double`, reproducing the identical
"recorded type ≠ real field type" bug class for negative literals instead
of strings. Fixed by adding an `EPrefix` arm: `PreNeg` recurses into the
operand (mirroring `lowerExprMsil`'s `EPrefix`/`PreNeg` arm, which derives
its type from the un-negated operand and passes it through unchanged after
emitting `neg` — negation never changes the runtime type), `PreNot` always
yields `MBool`, and `PreRef` is a bare passthrough — all three mirroring
`lowerExprMsil`'s actual `EPrefix` semantics exactly. Added
`untypedNegInt = -40` plus a helper-function arithmetic test
(`untypedNegIntPlusTen`) to `module_val_self_test.l`; local build/test
(13/13) passes.

**Related:** D-progress-606 (#5258 — the other `staticValTokens`/
`staticValMsilTypes`-rooted `.length`/IList-cast bug, cross-package
qualified access rather than untyped-declaration inference), #2539
(comments at the `.length` generic-fallback dispatch site explaining the
List/IList assumption this bug's read site fell into), #5300 (the review
finding addressed above).

---

## D121 — Library-contributed DI extensions ship per docs/58: config templates, `contributes[T]`, wire templates — implemented as a front-end expansion (`Lyric.WireExpand`), with the MSIL wire bootstrap/accessor ABI (#5021) fixed to make wires callable on both targets

**Date:** 2026-07-06
**Status:** ACCEPTED (implemented; docs/58 is the backing sketch and is now
specced by this entry)

**Context.** `docs/58-wire-templates-sketch.md` proposed three additive
DI-extension mechanisms — config templates (`pub config` + `from`),
`contributes[T]` ordered multi-value wire bindings, and wire templates
(`pub wire` + `include`) — and left four open tensions (Q-wire-001 …
Q-wire-004) plus an implementation-shape question open. This entry
codifies the decisions and records what shipped.

**Decision 1 — implementation shape: a pre-typecheck AST expansion, not
backend codegen.** All three mechanisms are rewritten into ordinary items
and plain wire members by a new compiler package,
`lyric-compiler/lyric/wire_expand/wire_expand.l` (`Lyric.WireExpand`),
run by both bridges (`Msil.Bridge`, `Jvm.Bridge`) immediately after the
alias/stubbable rewrites and BEFORE type checking — the same
collect-templates-across-packages shape as the aspect weaver
(`collectAspectTemplates` / `weaveFileWithDiagsAndTemplates`):

- `pub config Name { fields }` (template declaration) is replaced by a
  synthesised `pub record Name` carrying the template's field shape —
  the template is a schema plus a nominal type, never an env-backed
  block in the declaring package.
- `config Local from Pkg.Template { overrides }` (module level, or
  inside a wire body — the wire form is hoisted to module scope)
  materialises an ordinary `config Local` block: template fields in
  template order, override defaults applied, env vars derived from the
  LOCAL name exactly as docs/25 §5 already specifies for ordinary
  blocks. Inside wire member initialisers, a value-position reference
  to the instantiation rewrites to a record construction of the
  template's record twin reading the instantiation's config statics
  (`Server(files = Files)` → `Server(files = StaticFiles(root =
  Files.root, …))`); `Local.field` access anywhere stays ordinary
  config access. **v1 scope:** the value-position rewrite applies
  inside wire member initialisers only — the DI-consumption site the
  mechanism exists for; general expression positions can construct the
  record twin explicitly.
- `contributes[T] name = expr` entries lower to plain typed wire
  members plus one synthesised `val <T>: List[T] = [entries…]` member
  per collection, so the bare identifier `T` resolves as the ordered
  list with zero new codegen on either backend. Order = declaration
  order adjusted by `wraps:`/`inside:` constraints (Kahn's algorithm,
  smallest-declaration-index tiebreak), **outermost-first** in the
  list.
- `include Pkg.Module [as Alias] { adjustments }` splices the collected
  `pub wire` template: `@provided` inputs are name-substituted (explicit
  `@provided x: expr` mapping, or bare same-name passthrough); exposed /
  contributes-entry / config-instance names enter the includer's scope
  bare; non-surface members get collision-proof `__incl<N>_` internal
  names; `replace` / `remove` are gated by the template's `overridable`
  allow-list; nested includes expand recursively with cycle detection.
- `pub wire` template items are dropped from the declaring file's
  output (never bootstrapped as that package's own graph), matching
  docs/58 §5's "one keyword, different modifiers" reading of D051.

Because expansion happens before the type checker, the synthesised
records and config blocks flow through the existing checking and
lowering paths unchanged, and neither backend gained docs/58-specific
codegen. Codegen backstops (`panic` on an unexpanded docs/58 member)
guard against a bridge that skips the expander.

Expansion runs **before the import-alias rewrite** (and the stubbable
rewrite) in every bridge path. This ordering is load-bearing: the alias
rewriter collapses `X.member` to bare `member` whenever `X` matches an
import alias or an imported package's last segment, so an include alias
that happens to collide with one (`include … as Core` in a file with
`import Std.Core`) would have its `Core.router` access destroyed before
the expander could resolve it. With expansion first, the include alias
wins inside wire member initialisers; outside wire graphs the
import-alias collapse behaves exactly as before. (Like `AspectDecl.from`,
`include` / `config … from` paths are matched as written — an
import-ALIAS-qualified template path is not resolved through the alias
table on either mechanism.)

**Decision 2 — Q-wire-001 (open vs sealed collections): open by
default,** `sealed contributes[T]` as the per-collection opt-in, exactly
as docs/58 §4.2 leaned. A sealed collection rejects add / remove /
reorder from outside the declaring scope (W0023); `replace` of a sealed
entry remains possible when (and only when) the entry is `overridable`,
since replacement preserves both membership and position.

**Decision 3 — Q-wire-002 (expose propagation): exposed names propagate
into the includer's SCOPE, not its public surface.** An included
template's `expose`d names become bare bindings referenceable inside the
including wire (and re-exposable by it), but the consumer wire's own
`expose` list alone determines what is reachable from outside — no
auto-re-expose. This keeps the includer's `expose` list a complete
enumeration of its surface (the legibility half of the tension) while
still eliminating the re-declaration boilerplate (the motivation half).
One documented v1 looseness: because inclusion flattens into a single
scope, a nested include's exposed names are reachable in the outermost
consumer even when the middle template does not re-expose them.

**Decision 4 — Q-wire-004 (blanket closed-module marker): deferred,** as
the sketch suggested — a template with zero `overridable` names is
already fully closed by construction.

**Q-wire-003 (verifier interaction):** confirmed nothing to design —
`wire` has no proof-obligation surface; the expander runs before the
verifier driver's weave step and produces only ordinary members.

**Decision 5 — aliasing isolates.** `include … as Alias` mangles the
template's exposed names to `__incl_<Alias>_<name>` (reached via
`Alias.<name>`, rewritten during expansion), prefixes its hoisted config
instantiations `<Alias>_<Name>` (env vars follow, per the local-name
rule), and keeps its contributes entries and collections internal — two
aliased instances of one module never share a collection, and a
consumer-level `contributes[T]` entry joins only the bare (unaliased)
collection. Unaliased inclusion shares the consumer's bare namespace;
collisions are a hard error (W0024) directing the user to alias.

**Decision 6 — template resolution is source-availability-scoped, like
aspect templates.** `include` / `config … from` resolve against
templates collected from the compilation's own packages and
path-dependency source packages (the same set
`collectAspectTemplates` sees). Templates inside restored (binary)
packages await the contract-metadata channel — the same standing gap as
cross-package aspect templates from restored deps (#3498 family), not a
new one.

**Decision 7 — #5021 fixed as part of this work: MSIL wires get the
JVM-parity ABI.** Wire templates are pointless on a target where no wire
is callable, so the MSIL backend's dead `<name>_create` factory was
replaced with the JVM-shaped ABI: one host-class static field per
EXPOSED binding, `<Wire>_bootstrap(provided…)` evaluating the graph in
topological order and storing exposed bindings, and one
`<Wire>_<name>()` accessor per exposed binding, with call sites
(`TestWire.bootstrap(cfg)`, `TestWire.logger()`) resolving through the
static-call path via tokens registered in `addPackageTokens`.
`wire_di_self_test.l` now runs on `--target dotnet` as well as
`--target jvm`.

**Diagnostics (wire expander, W0010–W0027).**

| Code | Meaning |
|---|---|
| W0010 | `config … from` references an unknown config template |
| W0011 | config override names a field the template lacks |
| W0012 | config override's declared type differs from the template's |
| W0013 | `pub` on a config-template instantiation |
| W0014 | config template field has a type outside the config set |
| W0015 | `include` references an unknown wire template |
| W0016 | include cycle |
| W0017 | unmapped `@provided` input with no same-named binding in the includer |
| W0018 | replace/remove target not in the template's `overridable` list |
| W0019 | adjustment target does not exist in the template |
| W0020 | a name has both `contributes[T]` entries and a plain binding |
| W0021 | `wraps:`/`inside:` constraint cycle |
| W0022 | ordering clause references an unknown entry |
| W0023 | sealed-collection violation (external add/remove/reorder) |
| W0024 | bare-name collision when splicing an include |
| W0025 | `@provided` mapping names a non-input of the template |
| W0026 | (warning) `overridable` in a non-template wire |
| W0027 | `expose` names no binding of the finished wire |

Parser diagnostics P0332–P0343 cover the new syntax forms
(`contributes[…]`, ordering clauses, include bodies, `remove`/`reorder`,
and the wire-body `config` form's mandatory `from`).

**Known target gap (pre-existing, unchanged by this entry):** module-level
config blocks emit runtime state on `--target dotnet` only — the JVM
backend emits nothing for `IConfig`, so config-template *runtime*
behaviour is .NET-only until JVM config emission ships (#3228; see
`config_templates_self_test.l`'s header). The docs/58
front-end expansion itself is target-independent, and wire templates +
`contributes[T]` run end-to-end on both targets.

**Tests.** `wire_expand_self_test.l` (expander unit coverage: all
W-codes, splice shapes, ordering, aliasing, nesting — CI via native
`lyric test` linking the stage-1 DLLs), `wire_templates_self_test.l`
(runtime, BOTH targets), `config_templates_self_test.l` (runtime,
`--target dotnet`), plus parser and formatter round-trip cases in
`parser_self_test.l` / `fmt_self_test.l`.

**Related:** docs/58 (backing sketch — now specced by this entry), D046
(config blocks), D047/D050/D051 (aspect-template idiom and the
one-keyword precedent), D045 (feature-set freeze that makes wire
templates precompiled-only), #5021 (MSIL wire ABI — fixed here), #2972
(`scoped[X]` members remain deferred and are passed through inclusion
unchanged).

---

## D122 — Typed FFI delegate bridging for `@externTarget` functions (Epic #1877/#3923's FFI-boundary slice), bounded to that boundary rather than the general lambda ABI

**Date:** 2026-07-06
**Status:** ACCEPTED (implemented)

**Context.** `docs/50-ffi-delegates-proposal.md` proposed letting Lyric
lambdas bind directly to nominally-typed .NET delegates once the lambda ABI
became strongly typed (Epic #1877). Investigating whether
`bootstrap/src/Lyric.Cli.Aot/UnixSocketHttpClient.cs` could migrate to pure
Lyric (its header names this exact prerequisite) found that issue #4077's
closure — believed to be the blocker — was actually closed by *removing* a
buggy shape-based Predicate/Comparison special case, not by shipping typed
delegate construction. The lambda ABI still unconditionally built
`Func<object,...,object>`/`Action<object,...>` for every lambda, and
`typeExprToMsilCtx`'s `TFunction` branch (`lyric-compiler/msil/codegen.l`)
hardcoded `MObject` for every type argument regardless of the real declared
types — the shared default used by every function-typed value's signature
resolution across the stdlib and all 26 ecosystem libraries, not just
lambdas. Fixing that shared default generally would touch every native
HOF/lambda call site in the codebase — too much blast radius for this task.

**Decision.** Add typed delegate construction, but bounded strictly to
`@externTarget` functions' own function-typed parameters — a small, distinct
subset of all functions, already handled by a separate code path
(`emitExternTargetBody`) from the general default:

- New `CodegenCtx` fields (`funcParamIsExternTargetDelegate`,
  `funcParamFnRetType`, `lambdaExternDelegateParamTypes`,
  `lambdaExternDelegateRetType`) mark exactly the case "a lambda passed
  directly to an `@externTarget` function's `TFunction`-typed parameter,"
  populated purely from each function's own declared AST (no type-checker
  dependency).
- `buildTypedFuncOrActionMsilType`/`buildFuncNTypedCtorTok`/
  `buildActionNTypedCtorTok` construct the real closed
  `System.Func<T1,...,Tn,TReturn>`/`System.Action<T1,...,Tn>` — including
  value-type arguments (e.g. `CancellationToken`), which delegate variance
  cannot bridge — instead of the uniform boxed ABI, for exactly that case.
- `resolveValueTaskGenericMsilType` narrowly resolves a
  `System.Threading.Tasks.ValueTask`1[InnerFqn]`-shaped extern type to its
  real closed value-type instantiation, bypassing the general (and separate,
  correct) `object`-erasure decision #4025 makes for any extern type whose
  CLR name contains `[` — needed because that erasure, applied generally,
  would defeat this slice's whole point for a `ValueTask<T>`-returning
  delegate.
- `typeExprToMsilCtx`'s shared default is never modified. Every existing
  native HOF/lambda call site is unaffected — verified no existing
  `@externTarget` function in the stdlib declares a non-trivial
  `TFunction`-typed parameter today (the sole existing example,
  `Std.Task`'s `taskRunWithCancel(action: in () -> Unit, ...)`, is a
  zero-arg non-generic `System.Action` with no type argument to erase in
  the first place, so it never exercised the erasure bug either way).

**Verification.** `lyric-compiler/lyric/typed_ffi_delegate_self_test.l`
targets a real BCL API — `System.Net.Http.SocketsHttpHandler.ConnectCallback`
(`Func<SocketsHttpConnectionContext, CancellationToken, ValueTask<Stream>>`)
— specifically because `CancellationToken` is a value type and
`SocketsHttpConnectionContext` is a plain (non-generic-declaring-type)
reference type, pinning the exact shape the erasure bug corrupted and that
Predicate/Comparison special-casing never covered. Wired into CI via native
`lyric test` (dotnet-only — the feature is MSIL-specific).

**Scope not covered.** Migrating `UnixSocketHttpClient.cs` itself did not
land in the same change: adding the Unix-socket `ConnectCallback`'s
capturing lambda to `Std.HttpHost` (not the stdlib bundle's last package)
surfaced a separate, pre-existing `Msil.Lowering` bug — #5304 — where a
non-last package's closure `.ctor` fails to resolve once a large-enough
subsequent package follows it. `UnixSocketHttpClient.cs` remains in place
pending that fix. General Predicate/Comparison/custom-named-delegate FFI
support also remains unimplemented — not needed for the `Func`/`Action`
shapes this slice targets.

**Related:** docs/50-ffi-delegates-proposal.md (backing proposal), #1877 /
#3923 (epic; #3923 updated to reflect this bounded slice vs. its original
general-ABI scope), #4077/#4084/#4089/#4091 (the PR #3885 review-finding
cleanup that removed shape-based Predicate/Comparison dispatch without
replacing it), #4025 (the `object`-erasure decision this slice narrowly
bypasses for one specific shape), #4601/#5206 (investigated and confirmed
not triggered by this slice), #5304 (the closure-lowering bug blocking the
Unix-socket migration itself).

---

## D123 — Single-file `lyric build <source.l>` gains manifest-driven dependency resolution via a synthetic one-package `EmitProjectRequest`

**Date:** 2026-07-06
**Status:** ACCEPTED

**Problem.** `lyric build` has always had two structurally independent
code paths in `cli/cli_build.l`: project mode (`buildProject`, driven by
`lyric.toml`'s `[project.packages]`) resolves workspace/path/NuGet
dependencies into `Emitter.EmitProjectRequest.restoredDllPaths` and routes
through `Emitter.emitProject`; single-file mode (`buildOneNative`) builds a
bare `Emitter.EmitRequest` with no dependency fields at all and routes
through `Emitter.emit`. A loose `.l` file compiled directly — even one
sitting right next to a `lyric.toml` that declares real dependencies —
structurally could not see anything outside `Std.*`: there was no code
path that resolved NuGet/Maven/workspace/path deps for a single-file
compile, regardless of what manifest happened to be nearby.

**Decision.** Rather than hand-rolling a second, parallel dependency
resolver for the single-file path, `buildOneNative` now synthesizes a
one-package `EmitProjectRequest` and routes it through the exact same
`Emitter.emitProject` pipeline `buildProject` uses, when (and only when) a
manifest actually contributes something. Concretely (`cli/cli_build.l`'s
`emitSingleFileOrProject`, `discoverManifestForSourceFile`,
`loadManifestForSingleFileBuild`; `cli/workspace_builder.l`'s
`resolveManifestDependencies` / `resolveManifestFeatures` /
`injectMavenClasspathForJvm`, extracted out of `buildProject` so both
callers share one implementation instead of two copies):

1. **Manifest discovery walks from the SOURCE FILE's own directory, not
   the shell's cwd.** An explicit `--manifest` always wins; otherwise
   `Lyric.Discovery.findNearestManifest` is called on
   `Path.dirname(absolutize(sourcePath))` — deliberately different from
   every other project-aware command (`discoverManifest` in
   `cli_shared.l`), which walks from `Environment.currentDirectory()`.
   `lyric build sub/dir/foo.l` must find a `lyric.toml` relative to
   `foo.l`'s own location (matching what a project rooted at `sub/dir/`
   would see) regardless of where the invoking shell happens to be
   sitting. `sourcePath` is absolutized first because a bare relative
   filename's `Path.dirname` is `"."`, and walking up from `"."` alone can
   never leave the cwd.
2. **No new dependency-declaration syntax.** Dependencies only ever come
   from an actual discovered/explicit `lyric.toml` — there is no new
   annotation or header-block form for declaring a dependency inside a
   bare `.l` file. "Synthetic" describes the project-SHAPED request
   (`EmitProjectRequest` with one `ProjectPackage`), not a new syntax.
3. **The synthetic path only fires when it would actually change
   anything.** Routing every single-file compile through `emitProject`
   unconditionally was measured (empirically, by diffing PE bytes) to
   change the output even with zero dependencies: `emitProject`'s MSIL
   bridge embeds its `Lyric.Contract` resource as `Lyric.Contract.<pkg>`
   (the multi-package convention), while the single-file bridge
   (`Msil.Bridge.compileToMsilWithVersion`) embeds the bare
   `Lyric.Contract` — an inherent, bridge-level naming difference,
   not something fixable from the CLI layer without touching shared
   codegen. So `emitSingleFileOrProject` computes whatever a nearby
   manifest would contribute (`restoredDlls`, `nugetThirdPartyPaths`,
   `activeFeatures`, `declaredFeatures`, `depTemplateSrcs`, and — JVM only
   — whether `[maven]` entries exist) and falls back to the historical
   `Emitter.emit(req)` path, byte-for-byte unchanged, whenever all of
   those are empty. This covers both "no manifest found anywhere" (the
   overwhelmingly common case: a standalone script, a stdlib self-test)
   and "a manifest was found but declares nothing dependency/feature
   relevant" — both verified empirically byte-identical to this change's
   pre-existing compiled output, and covered by
   `cli_build_self_test.l`'s "byte-identical to no manifest" case.
   When a manifest DOES contribute something, the resulting
   `Lyric.Contract.<pkg>` resource-naming difference is an accepted,
   documented trade-off of reusing the project pipeline rather than
   forking it — there is nothing to be "identical" to for a capability
   that didn't exist before.
4. **Conservative default: fail loud, never implicitly restore.**
   `lyric build foo.l` has never touched the network, and that is
   preserved. If a discovered/explicit manifest names a workspace/path
   dependency that has not been built yet (no DLL at its expected `bin/`
   path, or no `lyric.toml` at all at the declared path), the build fails
   with the same message wording `buildProject` already uses
   (`Release.localDepNotBuiltMessage` / "no lyric.toml found at") rather
   than silently compiling without the dependency or silently kicking off
   a restore. This is a deliberate, conservative choice — `buildProject`
   itself has historically only *warned* on this exact condition (prints
   the message, keeps going, and lets the eventual typecheck surface a
   real error) rather than treating it as fatal; single-file mode is
   strictly more conservative here on the theory that a build with no
   manifest-driven precedent to fall back on should not compile a broken
   half-result. `resolveManifestDependencies`'s `hadUnbuiltLocalDep` flag
   carries this distinction: `buildProject` ignores it (preserving its
   exact historical behavior byte-for-byte); the new single-file path
   checks it and fails immediately.
5. **`[features]` manifest defaults thread through; no new CLI flags.**
   Single-file mode has no `--features`/`--no-default-features`/
   `--all-features` flags of its own (none were added). Its call into the
   shared `resolveManifestFeatures` always passes an empty CLI feature
   list and `false`/`false`, which resolves to exactly the manifest's
   `[features].default` set — a low-risk, natural extension of the same
   plumbing, not new CLI surface.
6. **JVM Maven classpath injection is wired in whenever the synthetic
   path fires on the JVM target**, mirroring `buildProject`'s
   `LYRIC_FFI_JARS` injection around its own `emitProject` call — a
   manifest that declares `[maven]` entries (even with no `[dependencies]`
   at all) is itself enough to trigger the synthetic path, so a JVM
   single-file build near a Maven-dependent manifest does not silently
   produce a build that cannot resolve the referenced Java types.
7. **Colocation extended to match.** `buildOneNative`'s existing
   `Release.declaresEntryMain`-gated stdlib colocation step now also
   copies the newly-resolved restored-dependency and third-party-NuGet
   DLLs beside a runnable program's output (`copyRestoredDepDlls` /
   `copyNugetAssembliesBeside`), exactly like `buildProject` already does
   — otherwise a program that now compiles against a workspace/path
   dependency would fail at `dotnet exec` time with a missing-assembly
   error. Verified end-to-end: a `func main` single file compiled next to
   an unlisted manifest with an already-built path dependency runs
   correctly under `dotnet exec` and prints the dependency's output.

**Explicitly out of scope for this change:**
- `lyric run`'s single-file path (`cli_run.l`'s `runOnce`) gets this
  capability for free — it already calls `buildOneNative` directly with
  `manifestPath = None`, so auto-discovery now applies there too with no
  code changes. Verified end-to-end.
- `lyric test`'s single-file path (`cli_test.l`) does **not** get this
  capability: it calls `Emitter.emit` directly rather than going through
  `buildOneNative`/`buildOne`, so extending it would require a second,
  separate wiring pass through `cli_test.l`'s own build logic — left as a
  precisely-scoped follow-up rather than attempted partially, tracked in
  #5341.
- A pre-existing, orthogonal gap was found (not caused by this change):
  `Emitter.emitProject`'s JVM path (`emitProjectJvmInProcess`) never reads
  `EmitProjectRequest.restoredDllPaths` at all — cross-package calls into
  a restored dependency's `pub func`s compile but fail at runtime with a
  bytecode `VerifyError` (`Bad type on operand stack`), because the JVM
  bridge has no restored-artifact-loading equivalent to the MSIL bridge's
  `RestoredPackages`/`SynthesisedArtifact` machinery — only the aspect
  weaver's `depTemplateSrcs` source-text mechanism is wired for JVM.
  Reproduced identically via plain, pre-existing `buildProject` (manifest
  project mode) against the same fixture, confirming it predates and is
  independent of this change. Tracked as a follow-up; the MSIL target is
  unaffected and fully functional.
- `--target native` is untouched, as `Emitter.emitProject` already
  hard-rejects native multi-package builds (`emitter.l`'s `case Native ->
  failResult(...)` in `emitProject`), so there is no manifest-shaped native
  path to reuse.

**Verification.** Empirically diffed compiled PE bytes (`cmp`) between the
pre-change single-file path and an equivalent one-package manifest-driven
project build to find the `Lyric.Contract` resource-naming difference
above; confirmed byte-identical output before and after this change for a
bare file with no manifest anywhere, and for a bare file next to a
manifest declaring nothing dependency-relevant. End-to-end manual
verification: (a) no-manifest single-file build unchanged; (b) a loose
`.l` file next to a `lyric.toml` with an already-built path dependency —
compiled directly, not listed in any `[project.packages]` — resolves the
dependency, colocates its DLL, and runs correctly under `dotnet exec`;
(c) the same with the dependency not yet built fails loudly with the
expected message; (d) `lyric build sub/dir/foo.l` invoked from an
unrelated cwd resolves `sub/dir/lyric.toml`, not any manifest at the cwd.
Extended `cli_build_self_test.l` with four new cases (dependency resolves,
dependency unbuilt fails loud, bare-manifest byte-identical, plus the
existing colocation cases continuing to pass); full existing self-test
suite (`cli_build_self_test.l`, `cli_workspace_builder_self_test.l`,
`cli_restore_self_test.l`, `cli_version_self_test.l`) passes unchanged.

**Review hardening (same PR).** `emitSingleFileOrProject` checked
`resolvedDeps.hadUnbuiltLocalDep` but never `resolvedDeps.hadWorkspaceError`,
so a manifest declaring a broken `{ workspace = true }` dependency (a
member name absent from the workspace, unlike a `path` dependency this is
detected purely from the workspace member index, with no DLL-existence
check involved) silently fell through to a dependency-less compile instead
of failing loud — directly contradicting this entry's own "fail loud,
never implicitly restore" guarantee (point 4 above). Fixed by checking
`hadWorkspaceError` first, mirroring `buildProject`'s existing immediate
`return 1` for the same condition. Added a fifth `cli_build_self_test.l`
case: a workspace root with a member manifest declaring a dependency on a
nonexistent member, compiled directly via `buildOneNative`, now fails
instead of silently succeeding.

**Review hardening, round 2 (same PR).** The same silent-swallow shape
existed in two more branches of `resolveManifestDependencies`: a `path`
dependency whose `lyric.toml` is unreadable or fails to parse printed an
error but never set `hadUnbuiltLocalDep`, unlike the sibling "no
lyric.toml found" / "DLL not built" branches a few lines away. Fixed by
setting the flag in both branches too. Added a sixth
`cli_build_self_test.l` case (a malformed dependency `lyric.toml`).
Also added direct unit tests for the shared helpers this PR extracted
(`resolveProjectSources` in `cli_shared_self_test.l`;
`resolveManifestFeatures`/`injectMavenClasspathForJvm` in
`cli_workspace_builder_self_test.l`), which previously had none of their
own.

**Review hardening, round 3 (same PR).** `emitSingleFileOrProject` set
`EmitProjectRequest.assemblyName` to the Lyric package's declared name
instead of `req.assemblyName` (the output file's stem) — the convention
both the pre-existing single-file path and `buildProject`'s multi-package
path use, and the value that becomes the emitted PE's actual `AssemblyDef`
Name row on `--target dotnet`. Fixed. Also: renamed `cli_build_self_test.l`'s
fixture identifiers (previously embedding the decision number itself, e.g.
`DepD122`) to decision-number-independent names, since embedding a D-number
that can itself be renumbered by a future rebase collision (as happened
twice already while landing this PR) is a self-defeating naming choice;
added a JVM-target case exercising the `jvmNeedsMaven`/
`injectMavenClasspathForJvm` branch (a manifest with `[maven]` entries but
no `[dependencies]` is itself enough to trigger the synthetic path on
`--target jvm`); and filed #5341 to track the `lyric test` single-file
follow-up, which previously had no linked issue.

**Related:** `docs/20-project-as-dll.md` (project bundling this
reuses), `docs/24-test-runner-plan.md` (the `lyric test` follow-up this
does not attempt), #5341 (that follow-up's tracking issue).

---

## D-progress-620 — G1 resolved: JVM is an independently-versioned Phase-6 target, not a v1.0 SemVer channel; `docs/44` band-order note

**Date:** 2026-07-06
**Branch:** docs/CI audit sweep (this session)

### Context

`docs/44-jvm-production-readiness-plan.md`'s header has, since it was
written, asked for a decision-log entry: *"File a decision-log entry to
codify the band ordering and the G1 channel decision before band J1
lands."* Band J1 (and J2, J3) shipped historically (see `docs/44` §6 for
the band breakdown), so this entry was overdue — it does not gate any
already-shipped work, it records a decision that was made in practice and
makes it discoverable.

`docs/36-v1-roadmap.md` §1 independently poses the same question as gate
**G1**: *"Is `--target jvm` a v1.0 supported channel, or is it Phase-6
ecosystem work with its own versioning?"* with the stakes spelled out:
if yes, Q-J012/Q-J013 (JVM checked-exception call-site wrapping) are
release-blocking; if no, the language reference documents JVM as
"supported but not v1.0 SemVer-guaranteed."

### Decision

**G1 resolved: JVM is an independently-versioned Phase-6 target, not a
v1.0 SemVer-guaranteed channel.** `--target jvm` continues to ship fixes,
PRs, and new capability on its own cadence (tracked via the JVM umbrella
epic #2663 and `docs/44`'s J0–J7 bands) without blocking the v1.0 release
train for the primary `--target dotnet` channel. This mirrors the
existing G4 precedent (D066): the `lyric-*` ecosystem service libraries
already ship under independent versioning rather than v1.0 SemVer, and
JVM — as a whole secondary compilation target, not a single library —
gets the same treatment.

Consequence for `docs/36` G1: resolves to the "no" branch. Per that gate's
own stakes table, `docs/01-language-reference.md` §0.1 (or the platform
support matrix) should carry a note that `--target jvm` is supported and
tested but carries no v1.0 SemVer guarantee; breaking changes may land in
minor releases until JVM support is separately declared stable. (Filing
this note in the language reference itself is left to whichever session
next touches `docs/36` R3/G1 bookkeeping — this entry's scope is codifying
the decision, not the full downstream doc sweep.)

### Band-order note (docs/44)

For the record, the band sequencing this decision unblocks: J0–J3 shipped
in earlier sessions (JVM audit, F#-host kernel debt elimination
`Lyric.Jvm.Hosts` deletion, `defer`/opaque/protected/wire lowering).  This
session's docs/CI audit pass (alongside sibling sessions working the same
effort in parallel — Maven resolver distribution, a `Std.Task.Scope` JVM
correctness fix, JVM auto-FFI robustness, and `lyric-search` API wiring,
none detailed here since they are each other sessions' scope) targets the
J5/J6-adjacent documentation-accuracy gaps: the M-17/B-11 stale-finding
corrections and the m-11 doc-drift sweep recorded elsewhere in `docs/44`
and in this entry's sibling commits.

### Consequences

- `docs/44-jvm-production-readiness-plan.md`'s header no longer describes
  an "Unbacked plan" for the G1 half of its ask — the channel decision is
  now recorded here. Band ordering itself remains documented in `docs/44`
  §6 (J0–J7); this entry does not re-litigate that sequencing, only
  confirms bands J1–J3 are historical fact by the time this was written.
- `docs/36-v1-roadmap.md` G1 should be marked resolved (cross-reference
  this entry) the next time that document is touched.

---

## D-progress-621 — JVM: `Std.Task.Scope` was a phantom kernel (`NoClassDefFoundError` on every call); rewritten over real JDK primitives. MSIL: `await` never actually blocked on an extern-declared `Task` value; fixed. D119 slice S3 (sibling-cancel) investigated, blocked on two newly-found pre-existing bugs, not shipped

**Status:** ACCEPTED (JVM rewrite + MSIL `await`-recognition fix); D119 slice S3 NOT shipped (see below)

**Context.** `lyric-stdlib/std/_kernel_jvm/task.l` declared `extern type
Scope = "lyric.runtime.LyricTaskScope"` and `extern package
lyric.stdlib.jvm.TaskScopeHost { ... }` against classes that exist nowhere
in the runtime — every `Std.Task` call on `--target jvm` (`makeScope`,
`scopeSpawn`, `delay`, cancellation tokens, all of it) threw
`NoClassDefFoundError`/`ClassNotFoundException`. This is the same phantom-
kernel-shim pattern fixed repeatedly elsewhere in the stdlib (D-progress-543
and its neighbours). Separately, D119 (`docs/03-decision-log.md`, slice S3)
asked to restore .NET's dropped sibling-cancel-on-first-fault in
`Std.Task.Scope`.

**JVM fix.** `_kernel_jvm/task.l` is rewritten as pure Lyric directly over
real JDK classes via the auto-FFI, discovering two hard constraints in the
process (both verified with standalone repros, documented in the file's
header): (1) the JVM auto-FFI class reader intentionally skips
`ACC_INTERFACE` class files, so instance methods on JDK *interfaces*
(`ExecutorService`, `Future`, `Executor`) have no metadata-backed
resolution path and silently mis-resolve to a legacy guess that throws
`IncompatibleClassChangeError`; only concrete classes
(`AtomicBoolean`/`AtomicReference`, `Thread`, `System`) are usable. (2)
Lyric closures have no bridge to arbitrary JDK functional interfaces
(`Runnable`/`Callable`) outside the compiler's own `spawn`/`scope { }`
keyword codegen. Consequently: `Scope.scopeSpawn` defers each action into a
`List[() -> Unit]`; `awaitAll` is where they actually run — one `scope { }`
`spawn`s every pending action (real JDK 21 virtual threads), wrapping each
so a fault sets a shared `AtomicBoolean` cancellation flag and records the
first failure's message via `AtomicReference.compareAndSet` (first-fault-
wins), then re-panics with it once every action has joined — genuine
sibling-cancel-on-first-fault, achieved with real concurrency primitives,
not a stub. `delay`/`delayWithCancel` block the calling virtual thread
directly (`Thread.sleep`, chunked so cancellation is observed promptly);
`makeCancelSourceTimeout`'s auto-cancel is a lazy deadline check folded
into `isCancelled` rather than an eagerly-scheduled background canceller
(the Runnable-bridging gap rules that out). The ambient token slot uses
`java.lang.ThreadLocal` (not `ScopedValue`, still JDK 21 preview — same
reason D120 rejected `StructuredTaskScope`).

**MSIL fix (`Msil.Codegen.isTaskTypeMsil`, `lyric-compiler/msil/codegen.l`).**
While verifying the .NET side, `await` on any extern-declared `Task`-typed
value (`Std.Task.delay`/`delayWithCancel`/`awaitAll`) turned out to never
actually suspend/block at all — `await delay(3000)` completed in ~0.9s
total process runtime, not ~3s. Root cause: `isTaskTypeMsil` recognises an
awaited `Task` by comparing its TypeRef row against the compiler's own
eagerly-registered `cctx.trTask`/`cctx.trTask1` (set up directly via
`ctxAddTypeRef` at compile-context construction, before `cctx.ffiTypeRefs`
even exists). `ctxAddTypeRef` never deduplicates, and `extern type Task =
"System.Threading.Tasks.Task"` interns its *own*, separate TypeRef row the
first time `internFfiTypeRef` sees it — the two rows never match, so
`await` silently fell through to the "already-resolved, pass through"
branch for every kernel/user-declared `Task`. Fixed by cross-checking the
`ffiTypeRefs` cache (keyed exactly as `internFfiTypeRef` would key a fresh
intern of the same FQN) in addition to the row-index comparison. Verified:
`await delay(3000)` now takes ~3.9s. This is a real, load-bearing fix
independent of D119 S3 — every `Std.Task` consumer that `await`s a `Task`
now actually waits, which was silently false before.

**D119 slice S3 — investigated, not shipped.** Three independent,
pre-existing bugs were found while attempting it, each confirmed with a
standalone repro outside `Std.Task`:

1. `Task.ContinueWith(Action<Task>)` can never bind: Lyric closures erase
   every generic delegate type argument to `System.Object` (Epic #1877's
   closure ABI), so a `(Task) -> Unit` handler always presents as
   `Action<Object>`, never `Action<Task>`, and no BCL `ContinueWith`
   overload matches — both the metadata auto-FFI resolver and the
   table-driven `@externTarget` resolver fall back to a guessed signature
   that throws `MissingMethodException` at runtime.
2. An alternative using `Task.GetAwaiter().OnCompleted(Action)` (a
   non-generic, arity-0 delegate — the shape already proven to bind, per
   (3)) compiles the call correctly, but as soon as any closure appears in
   a function that also calls `GetAwaiter`/`OnCompleted`, the whole
   compilation unit's MSIL lowering panics: `Msil.Lowering: MNewobjByName
   could not resolve .ctor for type '<pkg>.__Closure_N'`. Reproduced with a
   `() -> Unit` local closing only over a `Task` and a `protected type`
   value (never over another closure), so this is independent of (1) — a
   second gap in closure-class registration ordering specifically when
   `TaskAwaiter`/`GetAwaiter` participate.
3. Most significant: even the *existing*, already-shipped
   `Task.Run(Action[, CancellationToken])` binding `scopeSpawn` uses never
   actually invokes the passed closure on this backend — confirmed with a
   minimal repro carrying no dependency on `Std.Task` at all
   (`taskRunPlain({ -> println(...) }); t.Wait()` prints nothing and
   returns immediately, even after an extra `Thread.Sleep`). This means
   `Scope.scopeSpawn`'s concurrent-execution primitive does not run user
   code on `--target dotnet` today, independent of sibling-cancel — a
   materially bigger, pre-existing gap than the missing cancel-on-fault
   feature this slice set out to restore.

Given (3), `_kernel/task.l`'s `scopeSpawn` is left functionally unchanged
(matching its pre-existing behaviour); only the header documentation and
the genuinely-shipped `isTaskTypeMsil` fix are new on the .NET side. D119
slice S3 remains open, now blocked on items (1)–(3) above rather than only
the `ContinueWith` overload issue D119 already knew about.

**A fourth bug, found verifying the JVM side end-to-end.** A closure
passed as a `() -> Unit` argument into a function in ANOTHER package,
stored, and later invoked via `spawn` from inside that package's own body
throws `ClassCastException`: every lambda-related check in
`lyric-compiler/jvm/codegen/*.l` keys off `ctx.pkgName` (the package
currently being lowered) with no cross-package interface adaptation, so
the closure (implementing the *caller's* synthesized `Lyric$Lambda`) never
matches the callee's own. A same-package `Scope` consumer, and a direct
(non-deferred) cross-package `spawn action()` call, both work fine
(verified) — the mismatch is specific to the store-then-spawn-via-a-
different-function shape `scopeSpawn`/`awaitAll` is split into. This means
`Scope` does not work reliably for genuine cross-package consumers on JVM
either, today — a separate, pre-existing, general JVM-backend gap, not
specific to `Std.Task`.

**Verification.** `lyric-stdlib/tests/task_tests.l` (new): cancellation
token/source semantics, `delay`/`delayWithCancel` timing and cancellation,
`makeCancelSourceTimeout`'s lazy deadline — all pass on both
`./bin/lyric test lyric-stdlib/tests/task_tests.l` and `./bin/lyric test
--target jvm lyric-stdlib/tests/task_tests.l`. The two `Scope`-based tests
(normal completion, sibling-cancel-on-fault) currently fail on **both**
targets — not because either kernel's `Scope` logic is wrong (each was
independently verified correct in isolation: the JVM design against a
same-package repro exercising real concurrent virtual threads and fault
aggregation; the MSIL `isTaskTypeMsil` fix against a direct timing
measurement) — but because of the pre-existing bugs above, both of which
predate this change and block ANY cross-package `scopeSpawn` consumer, not
just the sibling-cancel feature. The test file is left wired in (not
skipped/deleted) with this status documented in its own header, so a
future fix to either bug flips the assertions green without rediscovery.

**Scope boundary / follow-ups (not fixed here, each needs its own
investigation and issue):**

1. .NET: `Task.Run(Action[, CancellationToken])` never invokes its
   delegate argument on the self-hosted MSIL backend (item 3 above) — the
   biggest of the four findings, blocking `Scope.scopeSpawn` entirely on
   `--target dotnet`.
2. .NET: closures that call `TaskAwaiter.GetAwaiter()/OnCompleted()`
   alongside any other closure in the same compilation unit corrupt
   `MNewobjByName` closure-class resolution (item 2 above).
3. JVM: cross-package closure arguments stored and later invoked via
   `spawn` from a different function throw `ClassCastException` (the
   fourth bug above) — blocks reliable cross-package `Scope` usage on
   JVM.
4. `Task.ContinueWith(Action<Task>)` (and, by the same generic-erasure
   argument, any `Action<T>`/`Func<T,R>` BCL delegate parameter for
   non-zero, non-`object` `T`) can never bind from Lyric (item 1 above) —
   a standing constraint on what BCL APIs are callable from `_kernel/`
   externs until the closure ABI carries real generic delegate types.

**Related:** D119 (the entry this slice belongs to), D120 (JDK-preview-API
rejection precedent this JVM rewrite's `ThreadLocal`-over-`ScopedValue`
choice follows), D-progress-543/555/519 (the phantom-kernel-shim fix
pattern this JVM rewrite follows), Epic #1877 (closure ABI, `Action<T>`
erasure), docs/44 (JVM production-readiness plan).

**Review hardening (same PR, #5320/#5321/#5323).** Three findings from
re-review, all fixed in the same change:

1. **#5320 — JVM ambient slot silently dropped `deadlineMs`.**
   `_kernel_jvm/task.l`'s `__ambientSlot` (a raw `java.lang.ThreadLocal`,
   not a compiler-synthesised `AsyncLocal[T]` like the .NET side) only
   threaded `token.flag` through `installToken`/`currentToken`/
   `restoreToken`; a token created via `makeCancelSourceTimeout` and
   installed as ambient lost its deadline the moment it was read back via
   `currentToken()` (`deadlineMs` hardcoded to `0i64`), silently disabling
   its auto-cancel. Fixed with a second, lockstep `__ambientDeadlineSlot`
   ThreadLocal. Verified with a standalone repro: `currentToken().deadlineMs`
   now round-trips a real epoch-ms value instead of `0`.
2. **#5323 — `task_tests.l`'s sequential `main()` masked two of the three
   Scope tests' real status.** A bare sequential call list aborts the whole
   program at the first `Bug` panic, so once
   `testScopeNormalCompletionRunsEveryChild` started failing, the two Scope
   tests after it never ran at all — their pass/fail status was simply
   unknown, not "known to fail" as the header implied. Fixed with a
   `runScopeTest` helper that `try`/`catch Bug`-wraps each Scope test
   individually and reports it, so the suite always completes and every
   test's real status is observed. This surfaced a **new finding**:
   `testScopeWithNoChildrenCompletesImmediately` — which spawns zero
   children — also fails on both targets, with a null-dereference inside
   `awaitAll` itself, not the cross-package closure-invocation bug the
   non-empty-scope tests hit. All three Scope tests are confirmed failing
   on both targets now (not two), each independently reported.
3. **#5322 — no tracked issue for the `lyric-search` extern-package FFI
   gap.** Filed as **issue #5324** ("`extern package` FFI binding
   mechanism doesn't resolve to a real call on either backend") so the
   WS3 finding (`extern package` FFI resolution crashing at runtime on
   both targets, affecting at least 14 other ecosystem-library kernels)
   isn't only discoverable via git history; `lyric-search/README.md` and
   `search.l`'s kernel-boundary comment now link it directly instead of
   only recommending that someone file it.

None of the three change the headline conclusion (`Scope`'s *public* API
logic is sound; the bugs are in the shared `awaitAll`/closure-invocation
plumbing beneath it) — they make the existing, already-honest disclosure
more precise and closer to what the code actually does.

**Second review-hardening round (same PR, #5325/#5326/#5327/#5328).**

1. **#5325 — `task_tests.l` wasn't wired into any CI job, unlike every
   other `lyric-stdlib/tests/*.l` file.** Fixed by splitting the file:
   `task_tests.l` now carries only the eight token/cancellation/delay tests
   that reliably pass (plus a new regression test for #5320's ambient-slot
   fix), asserts normally, and is wired into `ci.yml` (`stdlib-builds` via
   `lyric run`; `compiler-self-tests-jvm` via `lyric build --target jvm` +
   `java -jar` + a `"task tests: ok"` sentinel grep, matching
   `uuid_tests.l`/`time_tests.l`'s exact pattern). The three Scope tests
   move to a new, deliberately-unwired
   `lyric-stdlib/tests/task_scope_known_failures_tests.l` — see its header
   for why (mirrors the `contract_meta_emit_self_test.l`/#2580 precedent
   for a test that cannot cleanly pass yet).
2. **#5326 — the three newly-discovered Scope-blocking bugs were only in
   decision-log prose, no tracked issue.** Filed as **issue #5329**
   ("`Std.Task.Scope`'s `scopeSpawn`/`awaitAll` never actually runs
   spawned closures"), covering all three (plus the empty-scope
   null-dereference #5323 surfaced). `task_scope_known_failures_tests.l`'s
   header links it.
3. **#5327 — `runGuardedJvm`'s empty-string `firstFault` sentinel could
   silently mistake an empty-message panic for success.** Confirmed real:
   `firstFault: JAtomicReference = JAtomicReference.new("")` used
   `compareAndSet("", b.message)` (first-fault-wins) and `awaitAll` decided
   whether to re-panic via `msg == ""` — so a sibling panicking with an
   empty message (`panic("")`) would CAS `""` to `""`, `awaitAll` would see
   `msg == ""`, and the fault would be silently swallowed as if every
   action had succeeded. Fixed by adding a dedicated `hasFault:
   JAtomicBoolean` (initially `false`) that gates the first-fault-wins
   write via `hasFault.compareAndSet(false, true)`; `awaitAll` now branches
   on `hasFault.get()` instead of the string comparison, so the sentinel
   value and a legitimate empty fault message can no longer collide.
   Verifying this surfaced a second, self-contained bug: the first version
   of this fix put the panic-and-terminate arm FIRST in `awaitAll`'s
   `if`/`else` (`if hasFault.get() { panic(msg) } else { Task(done=true) }`)
   and that ordering alone produced `VerifyError: Method expects a return
   value` at class-load time for the whole `Std.Task` class — matching the
   general "terminating-arm-position-sensitive if/else codegen" fragility
   class already catalogued in `docs/44-jvm-production-readiness-plan.md`
   (e.g. m-55). Reordering to match the pre-fix code's shape (success arm
   first, panic arm second: `if not hasFault.get() { Task(done=true) }
   else { panic(msg) }`) avoids it. **Verified end-to-end**: a standalone
   `scopeSpawn(sc, { -> panic("") })` repro now correctly propagates the
   empty-message fault (`catch Bug` observes it) instead of silently
   reporting success, on `--target jvm`.
4. **#5328 — `runScopeTest` let `main()` always return 0 despite known
   failures, in tension with "fix or delete, don't paper over."** Resolved
   as a consequence of the #5325 file split: the known-failing tests now
   live in their own file whose `main()` returns non-zero when a failure
   fires (verified: real exit code 1, not just non-zero-looking console
   output) and which is explicitly not asserted by CI either way — neither
   a fake green nor a red build for a bug this PR doesn't fix.

**A fifth bug, found while verifying #5320 end-to-end on .NET.** Adding a
regression test that called `installToken` on `--target dotnet` (to prove
`deadlineMs` survives the JVM ambient-slot fix — the .NET side didn't need
the fix itself, since it already stores the whole `CancellationToken` in
its `AsyncLocal`) reliably crashed: a `NullReferenceException` in
`ambientValue`/`currentToken` on `installToken`'s very first call in a
minimal repro, or a native `libclrjit.so` segfault in a slightly larger
one. Root cause: `ambientValue`/`setAmbientValue` are `@asyncLocal`
compiler intrinsics (real bodies synthesised by the self-hosted MSIL
emitter, not the `= ()` stub shown in source); on the very first access in
a process, `AsyncLocal<CancellationToken>.Value` is `null`, and the
synthesised getter appears to dereference it without a null check. Nothing
in the shipped stdlib calls `installToken` today (only documents the
pattern in comments), so this is a previously-latent, never-before-
exercised gap in the self-hosted MSIL compiler's `@asyncLocal` intrinsic
lowering, not something introduced by this PR. Filed as **issue #5330**;
the regression test was removed from the CI-wired `task_tests.l` (it
would crash the CI step) with a comment pointing at #5330 and explaining
why #5320 is instead verified directly against `_kernel_jvm/task.l` (see
above).

---


## D124 — `lyric-web` gets real HTTP dispatch, static file serving, and a middleware pipeline (CORS included); `Handler`/`Middleware` are interfaces, not closures, after discovering closures are unreliable across 2+ packages

**Date:** 2026-07-07

### Context

`Web.serve()` (`lyric-web/src/web.l`) accepted a fully-populated `Router` —
routes registered by method, URL pattern, and a `handlerName: String`
meant to be resolved "via DLL reflection at server startup" per D054 —
but that dispatcher was never implemented. Every request, regardless of
method or path, got the same hardcoded JSON payload describing the
registered routes. `lyric-web`'s own module doc already flagged this
("the end-to-end pipeline... has not been exercised against a live HTTP
client in CI"); `docs/57`'s ecosystem audit independently found the same
gap. There was also no static file serving and no middleware pipeline
(CORS config was parsed from the environment and silently never applied).

D099 already fixed the identical bug shape for `lyric-health`
(`HealthCheck.handlerName: String` → `handler: () -> CheckStatus`,
rejecting the DLL-reflection design outright as AOT-hostile and contrary
to this project's direction away from runtime reflection — D006) but
explicitly left `lyric-web`'s own router unfixed: "the web router is
name-based, so a registry value cannot reach a name-resolved handler."
This entry is that fix, plus the static-file and middleware pipeline the
user asked to see built on top of it, plus the docs/58 wire-template
integration for composing them.

### Decision 1 — real dispatch: `Request`/`Response`/`Handler`, pure `Web.dispatch`, `Std.HttpServer`-backed `Web.serve`

`Web.Router`/`Web.Route` gain `Request` (method, path, `pathParams`,
`queryParams`, `headers: Map[String,String]`, `body: String`),
`Response` (status, contentType, `bodyBytes: slice[Byte]`,
`headers: Map[String,String]`), and route handlers move from
`handlerName: String` to a `Handler` value (see Decision 4 for why this
ended up as an interface, not the originally-planned closure).
`Web.dispatch(router, req): Response` is a **pure** function — method +
`{name}`/`{*name}` path-pattern matching (segment-by-segment, with a
trailing `{*name}` capturing the remainder including further `/`),
path/query percent-decoding, case-insensitive header lookup, then
middleware composition (Decision 3) around the matched route's handler,
falling back to a 404 `ApiError` JSON body when nothing matches. `Web.serve`
is a thin I/O shell around `dispatch`, built on `Std.HttpServer`
(`lyric-stdlib/std/_kernel/http_server.l`, already proven end-to-end in CI
via `examples/rest_service.l`'s live-socket smoke test) rather than
reinventing `HttpListener` bindings inside `lyric-web` itself. `Std.HttpServer`
gained `requestQuery`, `requestHeaders`, `urlDecode`, `respondBytes`,
`respondBytesWithHeaders` (dotnet-only additions; the JVM twin routes
through an out-of-repo prebuilt JAR and doesn't yet expose these — a
pre-existing Phase-6 gap, not one this entry introduces).

There is no automatic request-body deserialization or
path/query-parameter-to-handler-argument binding (the "flat typed
parameters" D054 envisioned) — implementing that would require either
runtime reflection (rejected outright by D006/D099) or a source-generator
pass this project doesn't have. Handlers read `req.body`/`pathParam`/
`queryParam`/`header` explicitly instead; aspect-guarded business logic
keeps its original parameter shape (the aspect's row-constraint reads a
named parameter like `authToken: in String`) and a thin `Handler` wraps
it — see `examples/ledger|rbac|jobqueue`'s `Api.l` files for the pattern
this entry established.

### Decision 2 — static file serving: `Web.StaticFiles` config template, canonical-path traversal guard, multi-mount support

`pub config StaticFiles { root, mountPrefix, cacheControlSeconds,
fallbackToIndex }` — a docs/58 config template (D121), instantiable
directly (`Web.withStaticFiles(router, Web.StaticFiles(...))`) or via
`config Assets from Web.StaticFiles { ... }` in a `wire` graph. Multiple
mounts are just multiple `withStaticFiles` calls with different
`mountPrefix`/`root` pairs — no new mechanism needed. Path traversal is
rejected by resolving the candidate path to its canonical absolute form
via `Path.GetFullPath` and requiring it fall within the canonically
resolved root (plus a null-byte reject) — not a substring check on the
raw request path, which an encoding trick could evade; a request that
resolves to no file falls through to the rest of the pipeline (routes,
then 404) rather than answering directly, so static files can be mounted
before or after API routes freely.

### Decision 3 — middleware pipeline: `Web.Middleware`, CORS finally wired up, `Web.requestLogger`

`Web.Middleware { func wrap(req, next: Handler): Response }`, registered
with `Web.withMiddleware` in **outermost-first** order (first-registered
sees the request first, response last) — the same ordering
`contributes[Middleware]` uses in a wire graph (D121 §4.1), so a
library's own internal middleware and a consumer's `contributes[Middleware]`
entries compose with one mental model. CORS (previously parsed from
`LYRIC_CONFIG_WEB_CORS_*` and never applied — a `attachRegistry`-shaped
silently-dropped-argument violation per D099's own standard) is now a
real `Middleware` (`Web.corsMiddleware`) that `Web.start` attaches
automatically when enabled; `Web.requestLogger()` is a second built-in
middleware (`METHOD path -> status`), not attached by default.

### Decision 4 — `Handler`/`Middleware` are interfaces, not closures: closures are unreliable across 2+ packages in the current self-hosted MSIL backend

The first implementation modeled `Handler` as `alias Handler = (Request)
-> Response` (docs/58's own illustrative `Middleware`/`Handler` sketch
used a closure shape), with route handlers registered as either bare
named-function references or inline closure literals. This surfaced,
in order of discovery, **four previously-unknown self-hosted MSIL
backend bugs**, filed as:

- **#5361** — a payload-free `enum` with 2+ cases anywhere in the same
  compiled unit as a closure crashes closure lowering
  (`MNewobjByName could not resolve .ctor`/`MStfldByName could not
  resolve field`). Worked around in this entry by converting
  `Web.OpenApi.SchemaType`/`ParameterLocation` from `enum` to payload-free
  `union` (identical case lists; neither is pattern-matched or has
  ordinal/`.toString()` usage anywhere in the repo) — the same class of
  fix D099 already applied to `lyric-health`'s `CheckGroup` for a related
  enum cross-package dispatch bug.
- **#5362** — passing a **bare named function** (not a closure literal)
  as a function-typed value crashes at runtime
  (`NullReferenceException`) the first time it's invoked, whether stored
  in a record field or passed straight through — reproduced with a
  10-line repro completely unrelated to `lyric-web`. The project's own
  precedent (D099, D064 `Lambda.Direct`) recommends exactly this "register
  a function reference" pattern; every actual usage found in the repo
  (`lyric-health`'s `{ -> checkFn() }` call sites) already wraps the
  reference in a closure literal rather than passing it bare — quite
  possibly an unstated workaround for this exact bug, not a style choice.
- **#5363** — the severe one: invoking closures from **two or more
  different packages compiled into the same program** is unreliable —
  symptoms ranged from `InvalidProgramException` and
  `InvalidCastException` (casting completely unrelated types, e.g.
  `Web.Response` to `Web.ApiError`, inside a method that never
  references `ApiError`) to **silent wrong-value corruption with no
  exception at all**, reproduced with two trivial hand-written packages,
  no aspects/weaver involved. `lyric-web` (closures in its own package)
  plus any real consumer package (which will define its own closures to
  adapt handler functions — exactly what `examples/ledger|rbac|jobqueue`
  originally did) is precisely this shape. The confirmed-safe
  alternative, verified with the identical two-package repro: a
  single-method **interface** (`impl Handler for SomeRecord { func
  handle(...) }`, invoked via `h.handle(x)`) instead of a stored
  closure/`Func<...>` value — consistent with every other
  pluggable-behavior abstraction already in this codebase (`WsHandler`,
  `MailSender`, `StorageBucket`, …) being an interface rather than a
  stored closure, which may be exactly why this bug had gone unnoticed
  until now.
- **#5364** — unrelated to closures entirely (single package, single
  file, zero closures): passing a `match`-arm-**bound** variable
  (`case Some(eq) -> ...`) directly as a call argument from inside that
  same arm crashes with `InvalidProgramException`
  (`pair.substring(0, eq)` where `eq` came from `Some(eq)`); copying it
  into a fresh local first (`val n: Int = eq; pair.substring(0, n)`) is a
  confirmed-reliable workaround, applied throughout `web.l` wherever this
  shape occurred (`parseQueryPair`'s query-string split index, among
  others).

**Given #5363, `Handler` and `Middleware` are both interfaces
(`Handler.handle(req): Response`, `Middleware.wrap(req, next: Handler):
Response`)**, and `Web.dispatch`'s middleware-composition + route-dispatch
tail are built from small `Handler`-implementing records
(`MiddlewareChain`, `RouteDispatchHandler`) rather than a composed closure
chain — zero closures appear anywhere in `lyric-web`'s own implementation.
Every route-handler registration across the library, its tests, and the
three example services (`ledger`, `rbac`, `jobqueue`) uses a small
zero-field record + `impl Web.Handler for X { func handle(req) {...} }`,
never a closure literal or bare function reference.

### Consequences

- `lyric-web` is functional end-to-end on `--target dotnet`: real
  method/path dispatch with path parameters, static file serving
  (multi-mount, traversal-safe), a middleware pipeline with working CORS,
  verified by `lyric-web/tests/dispatch_tests.l` (23 tests exercising
  `Web.dispatch` directly — routing, path/query/header extraction,
  wildcard routes, middleware ordering and short-circuiting, CORS
  preflight/allow/deny, static file serving including path-traversal
  rejection) and by a live `HttpListener` + `curl` smoke test against a
  router consumed as a genuine path dependency from a separate project
  (the exact configuration #5363 made unreliable) covering path params,
  query strings, headers, static files, and 404s across multiple
  sequential requests with no crash and correct bodies.
- `examples/ledger`, `examples/rbac`, and `examples/jobqueue` migrate
  their route tables and health endpoints to the `Handler` interface,
  and gain hand-rolled `Std.Json`-based request-body parsers (the
  previously-assumed "the Web kernel deserializes the JSON request body"
  comment was aspirational and never true).
- `Web.addWorker`/`WorkerRegistration` are explicitly **not** touched by
  this entry — still registered, still never invoked. The obvious fix
  (structured-concurrency `spawn`) is a synchronous no-op on
  `--target dotnet` today (D119/D120), so a correct implementation needs
  either MSIL structured concurrency (D119 S5/S6, not yet shipped) or a
  hand-rolled thread/timer extern boundary; tracked as **issue #5359**
  rather than shipped as a bootstrap-grade workaround.
- Live OpenAPI JSON / Swagger UI serving (`LYRIC_CONFIG_WEB_SERVER_SWAGGERENABLED`,
  previously parsed and silently ignored — the same class of violation
  CORS was in before this entry) is removed from `Web.start`/`serve()`
  rather than left as a dead env var; tracked as **issue #5360**. Use the
  build-time `lyric web spec` workflow until it ships.
- `lyric-web` remains `dotnet`-only; `Std.HttpServer`'s JVM kernel routes
  through an out-of-repo prebuilt JAR that doesn't yet expose the
  query-string/header/byte-body primitives this library needs (a
  pre-existing gap, not newly introduced).

### Alternatives considered

- **Keep the closure-based `Handler` design and work around #5363 by
  telling consumers to avoid defining their own closures.** Rejected:
  unenforceable (nothing stops a consumer package from writing a closure
  literal for an unrelated reason and silently corrupting `lyric-web`
  dispatch), and the interface alternative has no real ergonomic cost
  beyond one extra `record`/`impl` block per handler.
- **DLL-reflection dispatcher (the original D054 design).** Rejected on
  the same grounds D099 already rejected it for `lyric-health`: AOT-hostile,
  contrary to D006, and reflection was never actually implementable for
  this without the metadata-based auto-FFI infrastructure (docs/42),
  which solves compile-time FFI signature resolution, not runtime
  dynamic dispatch by name.
- **Ship the live-Swagger/worker-dispatch env vars as documented but
  silently inert**, matching the pre-existing state. Rejected per
  D099's own precedent: a config value that's read and then ignored is a
  production-quality violation, not a neutral no-op.

**Related:** D054 (original router design), D099 (function-reference
dispatch precedent, enum → union cross-package workaround precedent),
D006 (no runtime reflection), D119/D120 (structured concurrency,
dotnet-target synchronous-degenerate gap), D121 (config templates /
`contributes[T]` / wire templates this entry's static-file and
middleware config build on), docs/57 (ecosystem review that independently
flagged the dispatch gap), issues #5359 (worker dispatch), #5360 (live
spec serving), #5361–#5364 (the four closure/codegen bugs found and
worked around in this entry).

---
## D-progress-623 — JVM: primitive-array `slice[T]` marshaling at the auto-FFI/`@externTarget` boundary generalized from a `byte[]`-only, tail-position-only special case to all 8 primitive element types, in both directions, and fixed for explicit `return` statements

**Status:** ACCEPTED

**Context.** The JVM backend's `slice[T]` is uniformly erased to
`java.lang.Object[]` regardless of `T` (`jvm/codegen/01_types.l`). Reference
element types are covariant with `Object[]`, so no conversion is needed, but
a real JDK primitive array (`int[]`, `char[]`, etc.) is a distinct bytecode
array type from `Object[]` and cannot be treated as one without an explicit
per-element box/unbox loop. Before this entry, exactly one such loop existed
— `byte[]` only — and it only fired for an *implicit tail-expression*
return; an explicit `return someIntArray` (or any non-byte primitive array
return, or a `slice[T]` argument passed into a JDK API expecting a primitive
array) skipped the coercion entirely and either silently mismatched the
descriptor or crashed at runtime (`VerifyError` / `ClassCastException`
depending on the call shape). This blocked ecosystem-kernel migrations that
need to hand a real JDK primitive array (not just `byte[]`) across the
`slice[T]` boundary — found while scoping a broader `extern package` →
`extern type`/`import extern` migration, which needs this fixed first for
any kernel that touches a non-byte primitive array.

**Decision.** Generalized the byte-only loops to all 8 JVM primitive array
element types (`boolean`/`char`/`float`/`double`/`byte`/`short`/`int`/
`long`), in both directions:

- **Return-side (primitive array → `Object[]`):** `emitBoxByteArray` →
  `emitBoxPrimitiveArray(ctx, insns, elemTy)` (`jvm/codegen/06_items.l`),
  parameterized over element type via `primitiveNewarrayCode`/
  `primitiveArrayLoadInsn`/`wrapperClassNameFor` (`jvm/codegen/04_calls.l`).
  Split `emitReturnArrayCoerced` into a `coerceReturnValue` half (the
  coercion itself) and the trailing `emitReturn` call, so the explicit
  `return` statement (`05_stmts.l`'s `SReturn`) can call `coerceReturnValue`
  directly instead of the bare `coerceArgTo` it used before — this is the
  fix for the explicit-return gap, independent of the element-type
  generalization.
- **Argument-side (`Object[]` → primitive array):** `emitFfiCoerce`'s
  hardcoded `[Ljava/lang/Object; -> [B` arm generalized to
  `emitUnboxObjectArray(ctx, insns, elemTy)` for any primitive array
  descriptor (`jvm/codegen/04_calls.l`). Byte and Short unboxing keeps the
  pre-existing `Number.intValue()` + narrowing-conversion tolerance (an int
  literal in a `List[Byte]`/`List[Short]` boxes as `Integer`, not
  `Byte`/`Short`); the other 6 types checkcast to their exact wrapper and
  call the matching `LUnboxX`.
- **Overload scoring:** `jvm/auto_ffi.l`'s `scoreParamMatch` had a
  byte-only `argDesc == "[Ljava/lang/Object;" and paramDesc == "[B"` arm
  gating which overloads even get *considered* a match — generalized via a
  new `isPrimitiveArrayDesc` helper, or the codegen fix above would be dead
  code for any constructor/method overload whose primitive-array parameter
  isn't `byte[]` (verified: `String(char[])`'s constructor was not even
  found as a candidate before this fix).

**Verification.** `auto_ffi_jvm_self_test.l` gained 3 new cases using a real
static JDK method (`Character.toChars(int): char[]`) — a non-byte element
type never previously exercised on either return path: a tail-expression
return, an explicit `return`, and a `slice[Char]` literal argument unboxed
into `String(char[])`'s constructor (round-tripping both directions
end-to-end). All pass on `--target jvm`. A regression sweep of 8 other JVM
self-tests touching arrays/slices/calls (`hash_jvm_self_test.l`,
`file_jvm_self_test.l`, `process_capture_jvm_self_test.l`,
`slice_ops_self_test.l`, `extern_param_jvm_self_test.l`,
`extern_loop_jvm_self_test.l`, `string_methods_jvm_self_test.l`,
`closure_jvm_self_test.l`, `generic_jvm_self_test.l`) shows no regressions.

**Known adjacent gap, not fixed here:** `verifyExternTargetJvm` (the
`@externTarget` signature verifier, F0015-J) only checks argument
descriptors against real JDK metadata, never the return descriptor — a
hand-written `@externTarget` declaration with a mismatched *return* type
still compiles clean. Pre-existing, orthogonal to this entry (which fixes
codegen's ability to *produce* a correct slice-typed return once the
declared signature is trusted, not the verifier's ability to *check* that
signature); left as a follow-up.

**Review hardening.** The `scoreParamMatch` generalization above scores
*any* of the 8 primitive array descriptors equally against an erased
`slice[T]` argument — code review correctly flagged that this makes JDK
overload families differing only by primitive element type (`String(char[])`
vs `String(byte[])`; dozens of `java.util.Arrays.hashCode`/`sort`/`equals`/…
families, each with one overload per primitive type) tie at the same score,
with `findBestMethod`/`findBestConstructor`'s strict first-wins tie-break
silently resolving to whichever overload the parsed class metadata happens
to list first — not necessarily the caller's intent. Confirmed real Lyric
element-type information is not recoverable at that point: `slice[T]`
erases structurally to `Object[]` in `typeExprToJvm` (`01_types.l`) well
before call lowering, and the type checker's unerased `TySlice(element)`
data is never threaded into codegen (only its diagnostics are read).
Added `checkPrimitiveArraySliceAmbiguity` (`jvm/auto_ffi.l`) to
`findBestMethod`/`findBestConstructor`/`findBestInstanceMethod`: when 2+
candidates tie at the winning score and the tie is caused by a `slice[T]`
argument matching 2+ *different* primitive array parameter types, refuse
with a compile-time diagnostic rather than guess. Verified manually (this
is a compile-time panic inside the compiler process itself, not a runtime
`Bug`, so it cannot be expressed as a `@test_module` `assertPanics`
assertion) and via a new CI negative-test step
(`Ambiguous primitive-array overload fails loud on JVM`) that builds a
`String(char[])`-vs-`String(byte[])` repro and asserts the build fails with
the diagnostic. The PR's own `String.new(slice[Char])` test was changed to
`String.copyValueOf(slice[Char])` (a static method with only one arity-1
overload, so genuinely unambiguous) once the ambiguity check correctly
started rejecting the constructor form. Also applied the review's
SUGGESTION finding: `emitFfiCoerce`'s new array-descriptor branch now
reuses `descStrToJvmType` + a `JArray` match instead of manually stripping
the leading `[` via substring.

**Related:** `docs/44` M-10 (the original byte-only interop this
generalizes), `docs/42` (metadata-based auto-FFI resolution this scoring
fix extends).

---
## D-progress-624 — Self-hosted MSIL backend: fixed #5361 (enum + closure lowering crash), #5363 (cross-package closure map collision), and #5364 (match-bound `.indexOf` payload mistyped), each with new regression self-test coverage; #5362 (bare function reference as a delegate value) investigated but not fixed — an attempted compile-time diagnostic false-positived on legitimate monomorphized code and was reverted before merge; #5359/#5360 confirmed correctly scoped as follow-ups; new bug #5366 found and filed while verifying #5363

Root-caused and fixed three of the four self-hosted MSIL compiler bugs
D124 found and worked around (#5361–#5364), converted the fourth into a
clear compile-time diagnostic instead of shipping a runtime landmine,
and confirmed the two scope-boundary follow-ups (#5359, #5360) remain
correctly documented as blocked rather than silently inert.

- **#5361 (payload-free `enum` + closure in the same compile unit
  crashes closure lowering) — fixed.** `lowerMEnum`
  (`lyric-compiler/msil/lowering.l`) was the *only* type-lowering
  function that never called `recordUserTypeDefRow` after `addTypeDef`
  — every other lowering path (record, union, distinct type, interface,
  opaque) does. `recordUserTypeDefRow` populates the positional
  `ctx.typeDefRowFqns` list that `findMethodDefRowOfType` /
  `findFieldDefRowOfType`'s `row - 2` reverse-lookup fallback depends on
  to resolve a forward-referenced TypeDef (e.g. a closure class drained
  after the enum's package) before its real row exists in the table.
  Omitting the call desynced that list for every type lowered after an
  enum, so the fallback either read the wrong FQN or fell out of bounds
  — surfacing as `MNewobjByName`/`MStfldByName` "could not resolve"
  panics. Fixed by adding the missing call; verified with the issue's
  own repro (payload-free `enum` + closure literal, single package).
- **#5363 (closures across 2+ packages corrupt/crash) — the described
  root cause is fixed.** `cctx.lambdaTicker` (`codegen.l`) resets to 0
  at the start of every package's `codegenMPackage` call, so two
  different packages' first capturing lambda both produce
  `lname = "__lambda_0"`. Five per-lambda maps
  (`lambdaCaptureNames`/`Types`/`Cells`, `lambdaClosureClasses`,
  `lambdaParamTypes`) were keyed by this bare, non-package-qualified
  name — mirroring a collision `lambdaExternDelegateParamTypes` had
  already been fixed for in #5309, but the fix wasn't applied to these
  five. A later package's own (possibly non-capturing) `__lambda_0`
  read stale capture metadata left behind by an earlier package's
  `__lambda_0`, corrupting its MethodDef signature with a bogus leading
  closure-class parameter. Fixed by qualifying every read/write site
  with `pkgName + "."` (mirroring the #5309 fix exactly); verified via
  compiler-internal instrumentation that both packages' lambda
  metadata now resolves independently, and via a 2-package repro that
  the previously-wrong `hasCaps`/signature is now correct.
  **Not fully fixed end-to-end**: verifying against the issue's own
  `r1 + r2` repro surfaced a second, pre-existing, unrelated bug (see
  #5366 below) that also breaks the repro's final arithmetic step —
  confirmed via a from-scratch `main`-commit rebuild that this second
  bug predates this session and is not a regression from the fix above.
- **#5362 (bare named function reference used as a delegate value
  crashes with `NullReferenceException`) — investigated, not fixed;
  an attempted compile-time diagnostic was reverted before merge.**
  A full fix (desugaring a bare function reference into an equivalent
  forwarding closure at every call site, or teaching the uniform boxed
  `Func` ABI to bridge a real typed BCL method signature) is
  substantially larger than this slice — deferred. A first attempt
  added a `codegen.l` check (`lowerExprMsil`'s `EPath` fallback — the
  final arm reached only when a name resolves to no local/capture/
  const/enum-case/union-case-ctor/static-val) that raised a new F0027
  diagnostic whenever the unresolved name matched a known top-level
  function, on the theory that this fallback is only ever reached by
  exactly the buggy pattern. **That theory was wrong and the check was
  reverted**: CI's `build`/`build-and-test` jobs caught it
  false-positiving on `examples/product-catalog`'s
  `map(rows, rowToProduct)` — a bare function reference passed to a
  generic higher-order function that `Lyric.Mono` monomorphizes/inlines
  against the concrete function at that specific call site, never
  constructing a real `Func` delegate at all, so no bug is present
  there. The `EPath` fallback reached by *every* unresolved bare
  function-name reference doesn't distinguish "a delegate must
  actually be materialised here" (buggy) from "this call site is
  monomorphized away" (safe) — a correct fix needs that distinction,
  not a blanket check. Left as `ldnull`/`MObject` (the pre-existing
  behavior) pending a properly-scoped fix; #5362 remains open.
- **#5364 (match-arm-bound variable used directly as a call argument
  crashes with `InvalidProgramException`) — fixed.** Root cause
  (found by a delegated investigation that built and IL-disassembled
  four variants): `.indexOf`/`.lastIndexOf` **method-call syntax**
  is special-cased in `lowerMethodCallMsil` to call the raw BCL
  `String.IndexOf`/`LastIndexOf` (`-1`-sentinel `Int`), while the mode
  checker resolves the same call against `Std.String.indexOf`'s
  `Option[Int]` signature — letting `match str.indexOf(x) { case
  Some/None }` type-check against a scrutinee that is physically a raw,
  never-boxed `Int`. `lowerPatternBindMsil`'s `PConstructor` arm
  (`codegen.l`) computes the case class from `scrutTy`; when `scrutTy`
  is a bare value type (not a class), it falls to a legacy "erased
  `MObject` scrutinee (e.g. from `mapGet`)" path that **hardcoded** the
  bound variable's slot type to `MObject` regardless of `scrutTy`,
  even though the physical value was an unboxed `int32`. `stloc`/`ldloc`
  tolerate the mismatch, but a later `callvirt` argument slot (e.g.
  passing the bound variable into `.substring(...)`) does not — the
  JIT rejects it outright. Fixed by using `scrutTy` (not a hardcoded
  `MObject`) for the fallback binding's slot type — a no-op for the
  genuine `MObject`-scrutinee case (`scrutTy` is already `MObject`
  there), correct for the raw-value-sentinel case. Also hardened
  `"substring"`'s three call-arg-count branches to `coerceCallArgMsil`
  their `Int` arguments as defense in depth, matching the general
  call-argument-lowering paths elsewhere in this file that already do
  this. Verified with the issue's own repro; `closure_correctness`,
  `closure_zero_overhead`, `bitwise`, `aspect_weave`, `async_spawn`,
  `block_shadow`, `msil_project_bridge`, `auto_ffi`, `typechecker`,
  `parser`, `modechecker`, `mono`, `result_generic_specialization`,
  and `stubbable` self-tests all still pass (no regressions from any of
  the three fixes landed in this entry).
- **New regression coverage added** (closing the review gap this PR's
  own `claude-review` pass flagged, #5368): a new
  `lyric-compiler/lyric/enum_closure_pattern_bind_self_test.l`
  (`@test_module`, native `lyric test`) pins #5361 (payload-free enum
  co-compiled with a closure) and #5364 (`.indexOf`/`.lastIndexOf`
  match-bound variable used directly as a `substring` call argument,
  both single- and multi-char-offset shapes); a new case in
  `lyric-compiler/lyric/msil_project_bridge_self_test.l` ("two packages
  each defining their own lambda index 0 do not corrupt each other's
  capture metadata") pins #5363 using the multi-package
  `compileProjectToMsil` bridge harness already used by that file's
  other cross-package regression tests.
- **#5359 (`Web.addWorker` registered but never invoked) and #5360
  (live OpenAPI/Swagger serving not implemented) — confirmed correctly
  scoped, no code change needed beyond one stale doc line.** Both are
  genuinely blocked on larger prerequisite work D124 already identified
  (real MSIL structured concurrency, or a design for live spec
  serving) and are already documented in `lyric-web`'s source/README as
  "registered, not yet invoked" / "not implemented, tracked in #5360" —
  matching the project's no-silently-dead-config standard. Fixed one
  remaining stale claim: `lyric-web/src/openapi.l`'s module doc still
  said code-first specs could be "served live via `Web.start(router)`
  with swagger enabled," which is not true; corrected to point at
  #5360.
- **New issue filed: #5366** — verifying #5363 end-to-end surfaced a
  second, unrelated, pre-existing bug: a function/closure value bound
  without a *literal* `(T) -> U` type annotation (i.e. inferred, or
  annotated via a type alias like `Handler`) never gets its return type
  registered in `fctx.funcValRetTypes`, so invoking it leaves a boxed
  `object` on the stack that arithmetic on the result silently
  corrupts (no exception). Confirmed pre-existing via a from-scratch
  rebuild of `main` before this session's changes. Root-caused to a
  specific `codegen.l` gap (`LBLet`/`LBVar`'s `funcValRetTypes`
  registration only matches a literal `TFunction` `TypeExpr`, never an
  alias reference or an inferred binding) with a proposed fix sketch;
  not fixed in this entry — a properly-scoped follow-up, not a
  bootstrap-grade patch, per this repo's production-readiness standard.

**Related:** D124 (the `lyric-web` PR that found and worked around all
six issues this entry addresses), #5309 (the earlier, narrower fix to
`lambdaExternDelegateParamTypes` that #5363's fix generalizes to the
remaining four per-lambda maps), #1877 (uniform boxed `Func` ABI both
#5362 and #5366 live in), #3196 (the earlier enum-FieldDef-row-shift bug
in the same family as #5361, though a different specific gap).

## D-progress-625 — JVM: 4 stdlib `_kernel_jvm/*.l` files migrated off `extern package` onto `extern type` + auto-FFI, restoring `Std.Environment`/`Std.Process`/`Std.Log`/the self-hosted lexer's Unicode classification on `--target jvm`; 7 pre-existing JVM codegen/bridge bugs found and tracked

**Status:** ACCEPTED (migration); 7 newly-discovered bugs filed and deliberately NOT fixed here (see below)

**Context.** A reconnaissance pass across all 33 `extern package` declarations
in the repo (prompted by a design discussion on retiring `extern package` in
favor of `extern type`/`import extern`) found that `environment_host.l`,
`process_host.l`, `log_host.l`, and `unicode_host.l` in
`lyric-stdlib/std/_kernel_jvm/` were the highest-priority migration targets:
unlike the ~29 ecosystem-library `extern package` usages (mostly dead code or
requiring real hand-written adapter glue, per the reconnaissance report), these
four are core stdlib, on live call paths, and each maps onto a genuinely real,
simple JDK API (`System.getenv`/`System.exit`, `ProcessBuilder`/`Process`,
plain stderr write, `Character.getType`) — `extern package`'s permanent no-op
status meant `Std.Environment`, `Std.Process`, and `Std.Log` were **entirely
non-functional on `--target jvm`**, and the self-hosted lexer's Unicode
identifier classification (`Lyric.Lexer` via `Std.UnicodeHost`) was degraded.

**What shipped.** All four kernels rewritten as pure Lyric over `extern
type` + JVM auto-FFI, mirroring the pattern already proven in
`console_host.l`/`time_host.l`/`collections_host.l`/`file_host.l`:

- `environment_host.l`: `hostGetVarOpt` → `System.getenv`; `hostExit` →
  `System.exit` (works because `Never` erases to `JVoid`, matching
  `System.exit`'s real `void` return exactly — no "throw after call" trick
  needed). Also fixed two exports (`hostGetCommandLineArgs`, `hostExit`)
  that were **missing from the file entirely** — `std/environment.l` called
  both unconditionally, so `Std.Environment` failed to even *load* as a
  class on JVM (a `VerifyError` cascading from the malformed/absent method,
  which poisons the whole class file, not just the missing function) before
  this fix, independent of the `extern package` no-op. `hostGetCommandLineArgs`
  has no real implementation (the JDK exposes no process-wide argv retrieval
  the way .NET does) — panics with a diagnostic instead of the previous
  crash; real implementation needs new entry-point codegen, filed as #5377.
- `process_host.l`: `ProcessHandle` is now `extern type ... = "java.lang.Process"`
  directly (was an indirect `exposed type` re-export through the dead shim).
  `hostSpawn` reuses `Std.ProcessCaptureHost.parseArgString` (made `pub`)
  rather than re-implementing the shared `buildArgString` quoting format.
  Also added `hostDisposeProc` (**also entirely missing** — `std/process.l`
  called it unconditionally; a genuine no-op on JVM, not a stub, since
  `java.lang.Process` holds no handle requiring explicit release the way
  .NET's `Process.Dispose()` does).
- `log_host.l`: rewritten to match the `.NET` kernel exactly (a plain
  stderr write via `Std.ConsoleHost`) rather than the originally-envisioned
  `java.util.logging.Logger` shim, which would have given `Std.Log`
  independent per-target level-filtering/handler behavior instead of
  identical cross-platform output.
- `unicode_host.l`: `Character.getType(int)` returns Java's own category
  ordinals, numbered differently from .NET's `System.Globalization.
  UnicodeCategory` (the convention `_kernel/unicode_host.l` and the
  self-hosted lexer both expect). Added `jvmCategoryToNetConvention`, a
  30-entry translation table cross-referencing both platforms' constants
  via the shared underlying Unicode General_Category property. Verified
  against 10 code points spanning distinct categories (letters, digits,
  punctuation, symbols, separator) with **identical output on `--target
  dotnet` and `--target jvm`** for the same source. Also fixed a pre-existing,
  independently-broken call to a nonexistent `charToInt` function (not
  `extern package`-related — this line was never going to compile regardless
  of the extern mechanism) — replaced with the real `Std.Char.toInt` UFCS
  method (`c.toInt()`).

**Verification.** `lyric-compiler/lyric/stdlib_jvm_kernels_self_test.l` (10
cases) exercises all four kernels directly (not through `Std.Environment`/
`Std.Process`/`Std.Log`, for reasons below) on `--target jvm`, wired into CI.
Manually verified end-to-end: `Std.Environment.getVar`/`runtimeDirectory`/
`runtimeIdentifier`/`setVar`/`exitCode` (real subprocess exit code
round-trip, confirmed via a real `java -jar` exit-code check, not just
"doesn't crash"); real child-process spawn/wait/exit-code via
`Std.ProcessHost` directly.

**Five pre-existing JVM codegen bugs found while verifying end-to-end,
deliberately NOT fixed in this entry** — each independent of the `extern
package` migration itself (confirmed by reproducing each with this
migration's changes stashed out), each requiring its own investigation:

- **#5377** — `Std.Environment.args()` has no implementation path (the JDK
  exposes no process-wide argv retrieval; needs new entry-point codegen).
- **#5378** — a `Never`-returning function's call used as the bare TAIL
  expression of a differently-typed function (e.g. `func main(): Int {
  ...; exitCode(42) }`, no trailing value) produces a class-load
  `VerifyError`. Does not affect the non-tail form (`exitCode(42); 0`),
  which works correctly — confirmed via a real subprocess exit code.
- **#5379** — discarding the result of an instance auto-FFI call whose
  receiver is a function PARAMETER (of an extern type) in non-tail
  statement position emits no invoke instruction at all (`VerifyError:
  Operand stack underflow`). Reproduced independently with both
  `java.lang.StringBuilder` and `java.lang.Process`. Worked around in
  `process_host.l`'s `hostWait` by making the call the function's sole tail
  expression instead of a discarded mid-block statement.
- **#5380** — a nullary enum case value is corrupted when passed as a
  function argument: `match`ing on it in the callee always resolves to the
  FIRST-declared case regardless of which case was actually passed.
  Confirmed independent of `Std.Log` with a minimal `enum`/`match` repro;
  confirmed JVM-specific (`--target dotnet` produces correct output for the
  identical source). This is why `Std.Log.info`/`warn`/`error` currently
  print `[DEBUG]` for every level on JVM — `Std.LogHost.write` itself (this
  entry's fix) is unaffected and correct when called with an explicit level
  string, verified directly in the self-test.
- **#5381** — `Std.Process.buildArgString`'s `args[i].contains(" ")`
  (`args: List[String]`) fails to bundle on JVM: `List[String]` indexing
  loses the element's `String` static type for auto-FFI method resolution,
  resolving the receiver as bare `java.lang.Object`. Blocks
  `Std.Process.run()`/`runChecked()` end-to-end on JVM even after this
  entry's kernel fix — `Std.ProcessHost`'s kernel functions work correctly
  when called directly with an already-formatted argument string (as the
  self-test does), confirming the kernel itself, not this entry's fix, is
  unaffected.

Each of these blocks a *public-facing* wrapper (`Std.Environment.args`/
`exitCode`'s tail form, `Std.Log.info`/`warn`/`error`'s level display,
`Std.Process.run`) from working end-to-end even though the underlying
kernel this entry fixed is independently correct — filed separately rather
than expanding this migration's scope, per the "smaller correct slice"
principle: each is a distinct, general JVM codegen defect unrelated to
`extern package`, discovered only because this fix let execution reach far
enough to expose them (previously every one of these call paths crashed
immediately on the `extern package` no-op, before ever reaching these bugs).

**Related:** the ongoing `extern package` retirement discussion (deprecate
in favor of `extern type`/`import extern`); the reconnaissance report
classifying the other ~29 `extern package` usages (mostly ASPIRATIONAL-ADAPTER
or dead code, not simple syntax migrations).

**Review hardening.** Two rounds of review found four real gaps in the
initial version of this migration:

- **REQUIRED (#5383):** `environment_host.l` was still missing
  `hostAppBaseDirectory`/`hostCurrentDirectory` — `std/environment.l` calls
  both unconditionally, so `Std.Environment` still failed to load as a JVM
  class, the exact failure mode this entry's `hostGetCommandLineArgs`/
  `hostExit` fix was supposed to close. Fixed: `hostCurrentDirectory` is a
  genuine, accurate `System.getProperty("user.dir")` call (a real JVM
  equivalent to "current working directory," unlike `hostAppBaseDirectory`);
  `hostAppBaseDirectory` has no accurate JVM equivalent to .NET's
  `AppContext.BaseDirectory` without reflecting on a loaded class's
  `ProtectionDomain`/`CodeSource` (and is NOT interchangeable with
  `user.dir` — `java -jar /opt/app/app.jar` run from an unrelated `cwd`
  would silently return the wrong directory) — returns `""` per the
  already-established "empty = unavailable" convention rather than a
  plausible-looking but wrong answer.
- **REQUIRED (#5384):** `hostSpawn`'s `ProcessBuilder` never called
  `.inheritIO()`, so it defaulted to `Redirect.PIPE` — silently breaking
  the documented "child inherits the parent's stdio" contract and risking
  a real deadlock in `hostWait`'s `waitFor()` once a child filled the
  unread pipe buffer. Fixed and manually verified (a spawned child's
  stdout is now visible in the parent's own output).
- **SUGGESTION (#5385):** `docs/44` M-19 cited `D-progress-624` instead of
  `D-progress-625` (the rebase-conflict renumbering after this entry
  collided with a concurrently-landing MSIL entry) — fixed.
- **SUGGESTION (#5386):** `hostGetVarOpt` dropped the `.NET` kernel's
  `try`/`catch Bug -> None` wrapper (issue #4752's exception-free-surface
  contract) — a `System.getenv` failure would panic on JVM instead of
  degrading gracefully like the .NET target. Fixed to match exactly.
- **SUGGESTION (#5387):** `hostGetCommandLineArgs`'s deliberate panic path
  had no test coverage. Added one — which surfaced a SIXTH pre-existing
  bug: **#5388**, a panic's `.message` is lost/replaced with a JVM
  class-name-shaped string when the panic propagates through a closure
  invoked via a higher-order function parameter (confirmed with
  `Std.Testing.assertPanicsWith`, which wraps the target call in a `{ ->
  ... }` closure before invoking it). `assertPanics` (occurrence-only, no
  message check) is unaffected and was used instead; the real panic text
  was verified manually with no closure indirection.
- **SUGGESTION (#5389):** `stdlib_jvm_kernels_self_test.l` grew from 8 to
  10 cases (adding the appBaseDirectory/currentDirectory test and the
  hostGetCommandLineArgs panic test above) but the PR description and 3
  docs still said "8 cases" — fixed.
- **SUGGESTION (#5390):** `docs/17-axiom-audit.md`'s prose still said "21
  files" carry `@axiom(...)` after `Std.LogHost`'s axiom was dropped
  (§18's summary table already said 20) — fixed.
- **SUGGESTION (#5391, #5392):** `docs/44`'s M-19 entry listed only the
  original 5 pre-existing bugs (missing #5388), and this entry called
  #5388 the "SEVENTH" bug when it's the sixth — both fixed.
- **REQUIRED (#5393):** `assertPanics("...", { -> hostGetCommandLineArgs() })`
  in the new self-test does not actually type-check: `hostGetCommandLineArgs`'s
  *declared* return type is `slice[String]` (its body unconditionally
  panics, but that's a runtime fact the type checker cannot see from the
  signature alone), so the closure infers as `() -> slice[String]`, which
  `argSatisfiesParam` does not accept where `assertPanics` expects
  `() -> Unit` (only a literal `Never`-returning closure body, e.g. a bare
  `{ -> panic(...) }`, is special-cased). Confirmed with a standalone
  repro reproducing the exact `T0043` diagnostic. Fixed by appending
  `; ()` to the closure body (`{ -> hostGetCommandLineArgs(); () }`),
  making its own inferred return type genuinely `Unit`; reverified the
  fixed file passes all 10 cases with `lyric test --target jvm`.
  Investigating this surfaced a SEVENTH pre-existing bug, filed
  separately as **#5395**: `Jvm.Bridge`'s single-file path treats
  type-checker diagnostics as advisory rather than fatal, so the
  original (broken) form of this test's `T0043` did not actually fail
  `lyric build --target jvm` (exit 0, JAR produced) even though the
  identical source correctly fails `--target dotnet` (exit 1). This is
  the still-open half of `docs/41-self-hosted-compiler-gap-analysis.md`
  §C1's single-file type-check flip (the MSIL side flipped in
  D-progress-438; the JVM side did not) — #5395 gives it a concrete
  tracked number and a live repro.
- **SUGGESTION (#5394):** this entry's own `**Status:**` line still said
  "5 newly-discovered bugs" after #5388 brought the count to 6 (now 7,
  after #5395) — fixed.

**Related:** #5383, #5384, #5385, #5386, #5387, #5388, #5389, #5390,
#5391, #5392, #5393, #5394, #5395.

---

## D-progress-627 — `lyric-feature-flags`: deleted the dead `extern package` HTTP-polling scaffold and rewrote `Flags.Registry` as pure Lyric, closing the FlagGated aspect's silent no-op

**Status:** ACCEPTED

**Context.** `lyric-feature-flags/src/_kernel/{net,jvm}/flags_kernel.l`
each declared two `extern package` blocks — the mechanism confirmed
broken in D-progress-625/#5324: it parses but never resolves to a real
binding in either the type checker or MSIL/JVM codegen. An internal
triage pass found two unrelated things bundled behind that one
boundary:

1. `Lyric.Flags.Http` / `lyric.flags.HttpClient` — an Int-handle-table
   remote HTTP-polling client (`connect`/`isEnabled`/`getValue`/
   `listFlags`/`refresh`). **100% dead code.** Zero callers anywhere in
   the repo. The public entry point the README documented,
   `Flags.connectRemote(): Result[FlagStore, FlagError]`, did not exist
   in `flags.l`, nor did the `NativeFlagStore` type the README also
   described. `feedback/04-security.md` FINDING-05 and
   `docs/10-bootstrap-progress.md`'s "security hardening" note both
   describe a TLS-enforcement fix (`INSECURE_URL`) for this function —
   that fix was never actually applied to the code; the function was
   aspirational the whole time.
2. `Lyric.Flags.Registry` / `lyric.flags.Registry` — a stateless global
   name→value map (`checkFlag`/`getStringFlag`/`registerBoolFlag`/
   `registerStringFlag`). This one IS wired to a real call site:
   `Flags.Aspects.FlagGated`'s `around(call)` advice calls
   `FlagsKernel.checkFlag` on every invocation of a matched function.
   But `FlagGated` itself was never applied anywhere in the repo, so
   nobody had ever exercised it at runtime — the registry's `extern
   package` no-op silently always returned `defaultValue`, and no test
   caught it because no test wove the aspect end-to-end.

**What shipped.**

- Deleted `lyric-feature-flags/src/_kernel/` entirely (both `net/` and
  `jvm/flags_kernel.l`) — the HTTP client scaffold, its
  `@cfg(feature = "remote")`-gated re-export wrappers, and the broken
  `Registry` extern block.
- Added `lyric-feature-flags/src/flags_registry.l` (`Flags.Registry`):
  a pure-Lyric registry backed by `Std.Collections.Map[String, Bool]`
  / `Map[String, String]` fields on a `val`-bound record (the same
  "mutate through a `val`-bound record's `var` fields" idiom
  `Cache.inProcess()` / `Cache.Aspects.functionCacheStore` already use
  — Lyric has no module-level `var`). No extern boundary, no
  `_kernel/` directory, no target split: modelling "map of flag name
  to value" needs no BCL/JDK object reference, so the same file now
  serves `dotnet` and `jvm` identically. Ships the same honest
  not-thread-safe caveat as `Flags.InProcessFlagStore` and
  `Cache.InProcessCacheStore` (lyric-lang #411).
- `Flags.Aspects.FlagGated` now calls `Flags.Registry.checkFlag`
  directly instead of the dead `Flags.Kernel.Net` alias.
- `lyric.toml` drops the `Flags.Kernel.Net` package entry and the now-
  meaningless `remote` feature; adds `Flags.Registry` and a new test
  target.
- Removed the remote-store doc scaffolding from `flags.l`'s module
  header (the `LYRIC_CONFIG_REMOTE_*` env var table, the
  `connectRemote()` mention, the "NativeFlagStore" placeholder
  section) and from `lyric-feature-flags/README.md` (the "Remote flag
  service" section, the `connectRemote()`/`INSECURE_URL` claims in the
  platform-parity table). The README's platform-parity table now
  states plainly that no remote store exists rather than claiming one
  is "Available" or "Planned." `book/chapters/appendix-b-quick-
  reference.md`'s `lyric-feature-flags` rows are corrected to match
  (dropped the phantom `connectRemote()`/`INSECURE_URL` note and the
  never-implemented `enable`/`disable` functions).
- Added `lyric-feature-flags/tests/flags_aspect_weaving_tests.l`: end-
  to-end coverage that actually applies `FlagGated` to a handler and
  invokes it through the weaver — an unregistered flag with
  `defaultOnMissing = false` short-circuits; `Flags.Registry.
  registerBoolFlag` flipping the flag to `true`/`false` changes the
  woven handler's behavior live; `defaultOnMissing = true` proceeds
  for an absent flag; the aspect's own `enabled = false` master switch
  bypasses the registry entirely; and a direct
  `registerStringFlag`/`getStringFlag` round-trip. This is the
  regression guard that would have caught the original bug — no test
  in the repo wove `FlagGated` before this change.

**What was NOT done, deliberately.** `extern package` itself was not
fixed — that is the subject of the ongoing retirement discussion
referenced in D-progress-625. A real remote-polling `FlagStore` was
not built; it would need `Std.Http`'s client, a background poll loop,
and a JSON decoder for the remote payload, none of which existed
before this entry and none of which this entry adds. Implementing one
is left to a future, explicitly-scoped task; the README says so
directly instead of leaving broken scaffolding in its place.

**Verification.** `./bin/lyric test --manifest lyric-feature-flags/lyric.toml`
on `--target dotnet` (both `Flags.FlagsTests` and the new
`Flags.FlagsAspectWeavingTests`, all green) confirms the rewritten
registry and the `FlagGated` weave both work end-to-end; `lyric-feature-
flags` has no `[project.packages]` entry for a `jvm` kernel today (it
never did — `Flags.Kernel.Jvm` was itself orphaned, referenced by no
import anywhere in the repo, prior to this entry), so `--target jvm` is
not part of this library's build.

**Review hardening.** Two SUGGESTION findings pointed at other docs
that drifted stale once this entry's fix landed:

- **SUGGESTION (#5429):** `docs/57-stdlib-ecosystem-library-review.md`
  still claimed `FlagGated`/`FlagVariant` aspect weaving had no
  regression test — fixed to note `FlagGated` is now covered by
  `flags_aspect_weaving_tests.l`, narrowing the remaining gap to
  `FlagVariant` (still an unwoven stub).
- **SUGGESTION (#5430):** `feedback/04-security.md`'s FINDING-05
  quoted the deleted, never-real `connectRemote()` as if it were live
  code needing a TLS fix — annotated as superseded/moot, mirroring the
  `docs/10-bootstrap-progress.md` treatment.

A second review round found a REQUIRED regression: a later editing pass
on this same PR (fixing stale `D-progress-626` citations) rewrote the
README's platform-parity table to claim "In-process store: Available
(both targets)" / "`FlagGated` aspect: Available (both targets)" —
directly contradicting this entry's own Verification section above,
which explicitly says `--target jvm` was never part of this library's
build. That claim was never checked against a real JVM run.

- **REQUIRED (#5436):** Actually running
  `lyric test --manifest lyric-feature-flags/lyric.toml --target jvm`
  for the first time found the JVM claim is false, and moreover
  surfaced two previously-unknown JVM backend compiler bugs, neither
  caused by this library:
  - **#5441** — any JVM program that constructs or `match`-extracts a
    `Float`-typed value crashes the *compiler itself*
    (`System.Convert.ToSingle` `MissingMethodException` inside the
    self-hosted JVM class-file emitter's constant-pool interning).
    Blocks `getFloat`/`FlagValue.FlagFloat` entirely.
  - **#5442** — `FlagValue`'s union case field accessor (`value`) gets
    miscompiled to reference an entirely unrelated stdlib type
    (`Std.Http.Url`, which is never imported by this library, directly
    or transitively) instead of its own accessor, producing a bytecode
    reference to a class that's never bundled into the jar —
    `NoClassDefFoundError: Std/Http/Url` at runtime. Breaks every
    `FlagStore` read path (`isEnabled`, `getValue`, `getBool`,
    `getString`, `getInt`, `listFlags`, `fromEntries`) on JVM: 19 of 33
    tests in `flags_tests.l` fail once #5441 is worked around enough to
    let the package compile at all.
  - The `FlagGated` aspect additionally hits the already-known,
    pre-existing B′-mode aspect-weaver JVM bug
    (`__LyricBModeCallContext` `NoSuchMethodError`, first documented in
    the `lyric-auth` JVM kernel work) — 5 of 6
    `flags_aspect_weaving_tests.l` cases fail on JVM; only the one
    test that calls `Flags.Registry` directly (bypassing the aspect
    and the `FlagValue` union) passes.
  - Corrected `README.md`'s platform-parity table to state precisely
    what works on JVM today (only `Flags.Registry`'s raw map API) and
    what doesn't (everything else, with issue links), and updated
    `book/chapters/29-application-libraries.md`'s library-availability
    matrix from "planned" to "broken (#5441, #5442)" to reflect that
    JVM has actually been attempted and found non-functional, not
    merely unattempted.

**Related:** D-progress-625, issue #5324 (`extern package` FFI
resolution mechanism), lyric-lang #411 (`protected type` weaver,
referenced by the thread-safety caveat), #5429, #5430, #5436, #5441,
#5442.

---

## D-progress-628 — `lyric-i18n`: rewrote `I18n.Kernel.{Net,Jvm}` as pure Lyric (no extern boundary), registered into the build, both targets real and tested

**Status:** ACCEPTED

**Context.** `lyric-i18n/src/_kernel/{net,jvm}/i18n_kernel.l` each declared
an `extern package Lyric.I18n.FileLoader` / `lyric.i18n.FileLoader` block
(loadFromPath/parseTranslationsJson/loadStore/translate/
availableLocalesJson/hasKey) — the mechanism confirmed broken in
D-progress-625/#5324. Neither file was even registered in
`lyric-i18n/lyric.toml`'s `[project.packages]`, and `I18n`'s own public
package (`src/i18n.l`) never imported either kernel — it reimplements
the same translation-loading logic directly against `Std.File`/
`Std.Json`, which already work identically on both targets (`Std.Json`'s
JVM backend was rewritten to pure Lyric in D-progress-555). Per explicit
direction to roll forward and fix rather than delete dormant code, both
kernel files are rewritten as pure Lyric (no extern boundary — reading a
file and looking up a parsed JSON object needs no BCL/JDK object
reference) and registered into the build as a real, standalone,
handle-based alternative entry point.

**What shipped.**

- Both `i18n_kernel.l` files rewritten identically (the same pure-Lyric
  logic, since neither needs any platform-specific behavior): a
  module-level `I18nKernelState` record holds two parallel
  `Map[Int, ...]` tables (translations, fallback locale) keyed by an
  incrementing handle, following the same "eliminate the extern boundary
  entirely" idiom as `Flags.Registry` (D-progress-627).
- Registered `I18n.Kernel.Net` and `I18n.Kernel.Jvm` in
  `lyric-i18n/lyric.toml`'s `[project.packages]` (neither was compiled
  as part of the build before this).
- Added `tests/i18n_kernel_tests.l` (10 cases) exercising `loadStore`/
  `translate`/`hasKey`/`availableLocalesJson`/`parseTranslationsJson`/
  `loadFromPath` against a real JSON fixture file on disk — all 10 pass
  on both `--target dotnet` and `--target jvm`.
- `i18n.l` itself is unchanged: it already works correctly on both
  targets without any kernel, so this is a genuinely separate, optional
  entry point, not a redesign of the primary public API.

**Two new JVM/MSIL compiler bugs found and worked around (not fixed
here, filed separately):**

- **#5422** — `Std.Collections.mapKeys()` called directly on a
  `match`-pattern-bound `Map` value throws a runtime cast exception on
  BOTH `--target dotnet` and `--target jvm` (`Dictionary`/`HashMap`
  cannot be cast to `IList`/`List`). Reproduces with a two-line minimal
  repro; does NOT reproduce for a plain `val`-bound (non-`match`) Map,
  regardless of nesting depth. Worked around by re-binding the
  match-bound value to an explicitly-typed local before calling
  `mapKeys` — used three times in the new kernel files, each commented.
- **#5423** — calling a native `String` method (e.g. `.contains`) on a
  `String` value bound inside a `match { case Ok(x) -> ... }` arm can
  crash `--target jvm` compilation entirely: the JVM backend's type
  tracking loses the value's `String` type inside the arm and falls
  through to the auto-FFI instance-call resolver, which then fails to
  find `.contains` on the erased `java.lang.Object`. `--target dotnet`
  compiles the identical code with no issue. Worked around the same way
  as #5422 — re-bind to an explicitly-typed local first — used twice in
  `tests/i18n_kernel_tests.l`, each commented. Possibly the same root
  cause as #5422 (match-bound pattern types losing precision before a
  subsequent call).

**Verification.** `./bin/lyric test --manifest lyric-i18n/lyric.toml`
on both `--target dotnet` and `--target jvm --features jvm`: the
pre-existing `I18n.I18nTests` (25 cases, `i18n.l`'s own logic,
unaffected by this change) and the new `I18n.I18nKernelTests` (10
cases) both pass on `--target dotnet`; on `--target jvm`,
`I18n.I18nKernelTests` also passes fully (10/10) once the two
compiler-bug workarounds above were applied. `I18n.I18nTests` has one
pre-existing, unrelated JVM failure (`I18n.Locale cannot be cast to
java.lang.String`) in a test this change does not touch — a distinct,
separate bug in `i18n.l`'s own `availableLocales()` JVM-target codegen
(a `slice[Record]`-from-`List.toArray()` erasure gap), not caused by
the kernel work but filed as #5439 in the review-hardening round below
since it was surfaced by this entry's JVM verification pass and had
never been filed. A second, cosmetic finding from the same JVM run —
benign false-positive "unknown name" `T0020` diagnostics for
cross-package `Std.*` calls that resolve and run correctly — is filed
as #5440.

**Review hardening.** A review round found three real gaps in the
initial version of this entry's work:

- **REQUIRED (#5426):** `loadFromPath`/`loadStore` discarded the bound
  `IOError` behind a hardcoded generic message, so callers couldn't
  distinguish "file not found" from "permission denied" from any other
  host I/O failure. Fixed to embed `IOError.message(e)` in both
  functions.
- **REQUIRED (#5427):** this entry's own Context paragraph cited a
  nonexistent `D-progress-626` (the entry that never landed after the
  "delete 7 kernels" commit was reverted) — fixed to not cite a
  decision-log entry number at all.
- **SUGGESTION (#5428):** `I18n.Kernel.Net`/`I18n.Kernel.Jvm` were
  byte-identical ~230-line files with no actual platform difference —
  a maintenance hazard (the #5422/#5423 workarounds above had to be
  hand-applied twice) that also meant `I18n.Kernel.Jvm` itself was
  never exercised by any test (`tests/i18n_kernel_tests.l` only
  imported `.Net`, which has no `@cfg` gate and is what JVM builds
  compiled too). Consolidated into a single ungated `I18n.Kernel`
  package (`lyric-i18n/src/i18n_kernel.l`, not under `_kernel/`),
  matching `Flags.Registry`'s precedent — re-verified all 10 kernel
  tests pass on both `--target dotnet` and `--target jvm` against the
  single consolidated package.

A second review round found and fixed:

- **SUGGESTION (#5438):** `tests/i18n_kernel_tests.l`'s `withFixtureFile`
  wrote every test's fixture to one shared hardcoded filename
  (`lyric_i18n_kernel_test_fixture.json`) — a latent race once parallel
  test runs ship (docs/24 Stage 4). Fixed by threading a per-call-site
  suffix through `withFixtureFile` so each of the 10 tests gets its own
  scratch path.
- **SUGGESTION (#5437):** `book/chapters/29-application-libraries.md`'s
  library-availability matrix still listed `lyric-i18n` JVM as
  "planned". While fixing this, running `i18n_tests.l` on `--target jvm`
  for the first time (CI only ever builds ecosystem libraries on the
  default `dotnet` target, never runs `lyric test --target jvm` for
  them) surfaced the real, previously-unfiled #5439 (JVM
  `ClassCastException` in `availableLocales()`) and #5440 (cosmetic
  false-positive JVM diagnostics) noted above. Updated the book row to
  "stable (1 known JVM-only gap, #5439)" rather than a blanket "stable",
  corrected the README's platform-parity table and prose to the same
  precision, and replaced the stale `lyric.toml` comment (which still
  cited the long-closed #3719) with the real current test status.

**Related:** D-progress-625, D-progress-627, issue #5324, #5422, #5423,
#5426, #5427, #5428, #5437, #5438, #5439, #5440.

---

## D-progress-629 — JVM: fixed `impl <ExternInterface> for Record` resolving against the local package instead of the real JDK FQN; `lyric-web` gets a real Undertow-backed `Web.Kernel.Runtime`, blocked end-to-end on two newly-found JVM backend bugs (not #1707 — that ticket is closed and about a different defect)

**Status:** ACCEPTED (compiler fix + kernel implementation); the full
`lyric-web --target jvm` test suite remains blocked on #5443 and #5444
below, filed separately, not fixed here.

**Context.** `lyric-web/src/_kernel/jvm/web_kernel.l` (`Web.Kernel.Jvm`)
was a forward-declaration stub built on `extern package` — a confirmed
no-op FFI mechanism (D-progress-625, #5324) — and was commented out of
`lyric-web/lyric.toml`'s `[project.packages]` entirely. Making it real
required binding `io.undertow` directly via `extern type` + JVM
auto-FFI, which in turn required a Lyric record to implement a real JDK
interface (`io.undertow.server.HttpHandler`) so Undertow could dispatch
back into Lyric-handled requests.

**Compiler bug found and fixed: `impl <ExternInterface> for Record` was
unreachable from the real JDK caller on `--target jvm` — three separate
resolution sites, not one.** Verified with a from-scratch repro
(`extern type JRunnable = "java.lang.Runnable"`; `impl JRunnable for
MyRunner { func run(): Unit {...} }`) compiled and inspected with
`javap`: the emitted class declared `implements <pkg>/JRunnable` (a
same-package class that does not exist) instead of `implements
java/lang/Runnable`. Root cause: `Jvm.Codegen.constraintRefToJvmClass`
(`lyric-compiler/jvm/codegen/06_items.l`), which resolves an `impl Y for
X` block's interface name to a JVM binary class name, never consulted
the file's `extern type` table for a single-segment name — it always
guessed `<currentPackage>/<name>`, the same resolution
`typeExprToJvmExtern` already applies correctly to ordinary type
positions (#3334). Fixed by threading the file's `externTypes` map into
`constraintRefToJvmClass` and checking it before the local-package
fallback. Extending the fix to an `impl` method with an extern-typed
**parameter or return value** (needed once a self-test exercised
`java.io.FilenameFilter.accept(File, String): boolean` — not exercised
by `lyric-web`'s `HttpHandler`, whose single method takes only its own
declaring interface's argument) surfaced two more instances of the same
bug class in the same file: `holderAwareParamTypes`'s `erase` branch
called the plain `typeExprToJvmErased` instead of the extern-aware
`typeExprToJvmErasedExtern` it already had in scope (an earlier,
narrower fix had covered the *return*-type side of this exact gap but
left params on the `erase` arm unfixed), and `lowerImplMethod`'s
return-type resolution called plain `typeExprToJvm` instead of
`typeExprToJvmExtern`. Both fixed the same way — route through the
file's `externTypes` map instead of guessing the local package. Pinned
by a new regression test, `lyric-compiler/jvm/ffi_iface_impl_jvm_self_test.l`
(2 cases): `impl JFilenameFilter for AcceptNonEmptyFilter` implementing
`java.io.FilenameFilter.accept(File, String): boolean` (a real,
always-available two-parameter JDK interface needing no Maven
dependency) exercises all three fixes at once — interface-name
resolution, `File`-typed param resolution, and `Bool`-typed return
resolution — plus a second `impl` of the same interface in the same
file to pin that per-impl resolution doesn't collide. Re-verified: the
emitted class now correctly declares `implements java/lang/Runnable`
(the standalone `Runnable` repro) and runs under `java`
(`new Thread(runnable).start(); .join()` completes with exit 0); the
new self-test passes 2/2 on `--target jvm`. Verified against the full
self-hosted regression sweep (no dotnet-target self-test regresses):
`ffi_iface_impl` (5/5), `parser` (94/94), `typechecker` (240/240),
`modechecker` (62/62), `fmt` (116/116), `weaver` (46/46), plus the
JVM-specific `iface_dispatch_jvm`, `extern_param_jvm`,
`self_method_call_jvm`, and `auto_ffi_jvm_self_test` (22/22).

**What shipped for `lyric-web`.**

- `lyric-web/src/_kernel/jvm/web_kernel.l` rewritten from the `extern
  package` stub to a real `Web.Kernel.Runtime` (JVM) package: `extern
  type` bindings for `io.undertow.Undertow`/`Undertow$Builder`/
  `server.HttpHandler`/`server.HttpServerExchange`/`util.HeaderMap`/
  `util.HttpString`; a `LyricUndertowHandler` record implementing
  `HttpHandler` via `impl` (the fix above) that reads a full
  `Web.Request` off the exchange, routes it through the same
  `Web.dispatch(router, req)` pure core the `dotnet` accept loop uses,
  and writes the `Web.Response` back; a `serve(host, port, router)`
  entry point that builds and starts the server then blocks the calling
  thread on a `CountDownLatch`. The rate limiter is a port of the
  `dotnet` kernel's tumbling-window algorithm onto
  `java.util.concurrent.ConcurrentHashMap` + `ReentrantLock`.
- `Web.Kernel.Net` renamed to `Web.Kernel.Runtime` on both targets
  (`lyric-web/lyric.toml`'s `[project.packages]` lists both
  `_kernel/net/web_kernel.l` and `_kernel/jvm/web_kernel.l` under one
  package name, selected by feature — the `Lambda.Kernel.Runtime`
  pattern). `Web.serve` split into `@cfg(feature = "dotnet")` /
  `@cfg(feature = "jvm")` variants; `Web.parseQueryString` made `pub`
  for the JVM kernel to reuse without duplicating URL-decoding.
- New `lyric-web/tests/jvm_server_smoke.l`: a real Undertow round-trip
  test (server + `curl`). Not yet registered in `[project.tests]`
  pending the two blockers below.

**Two new JVM backend bugs found verifying the JVM test suite end to
end (neither fixed here, both filed with full repros):**

- **#5443** — the `[project.packages]` array form for a single package
  built from two alternative files (`_kernel/net/web_kernel.l` /
  `_kernel/jvm/web_kernel.l`, selected by feature) leaks the
  non-selected file's `extern type` binding when both files declare the
  same local alias name for genuinely different host types. Both files
  declare `extern type ConcurrentDict[K, V]` — the `dotnet` file binds
  it to `System.Collections.Concurrent.ConcurrentDictionary`2`, the
  `jvm` file to `java.util.concurrent.ConcurrentHashMap` — and
  compiling `--target jvm` emits a class file with a dangling reference
  to the **.NET** type name, crashing with `Illegal class name
  "System/Collections/Concurrent/ConcurrentDictionary`2/"`. All 5
  `Web.RateLimitTests` cases fail with this on JVM.
- **#5444** — calling an interface method (`mw.wrap(req, next)`, `mw:
  Middleware` pulled from the router's middleware list/slice) crashes
  JVM compilation: the erased `Object` list element isn't checkcast
  back to the `Middleware` interface before the call, so codegen falls
  through to auto-FFI resolution against `java.lang.Object`
  (`no matching instance or inherited method for
  'java.lang.Object.wrap(...)'`). Blocks `Web.DispatchTests`,
  `Web.CorsGuardTests`, and `Web.SecurityAspectWeavingTests` from
  compiling on `--target jvm` at all. Likely the same root cause as the
  `slice[Record]` field-access crash filed as #5439 in D-progress-628
  (erased collection elements never get checked back to their concrete
  type before use) — #5439 is the field-read variant, this is the
  method-dispatch variant.

An earlier draft of this integration (from the agent that did the
initial implementation work) attributed the JVM blocker directly to
#1707. That specific citation doesn't hold up: #1707's own body
describes a narrow nested-generic union-case-construction defect
(`Result[Option[T], E]`), already closed, and the project's own
precedent (D-progress-575, following up on the same M-5 area) is to
file a *new* issue for a newly-surfaced symptom rather than reopen
#1707 wholesale — exactly what #4982 did there. Re-verifying end to end
here found the real, distinct symptoms are #5443 and #5444 above,
filed fresh per that precedent rather than citing #1707 as if it
covered them directly. Note separately: unqualified cross-package
`Std.*` calls (e.g. `newMap()` called from `Web` without a
`Std.Collections.` prefix) do print spurious `error[T0020] unknown
name` diagnostics during `--target jvm` compiles, but — per #5440
(D-progress-628) — these are cosmetic false positives that do not
actually block compilation; they were not the cause of the real
failures documented above.

**Verification.** `./bin/lyric test --manifest lyric-web/lyric.toml`:
`--target dotnet` passes clean across all 4 test files (`Web.CorsGuardTests`
16/16, `Web.RateLimitTests` 5/5, `Web.SecurityAspectWeavingTests` 13/13,
`Web.DispatchTests` 23/23 — a rename-related regression in
`rate_limit_tests.l`'s import, introduced mid-implementation, was caught
by this run and fixed before landing). `--target jvm`: `Web.RateLimitTests`
0/5 (blocked by #5443); `Web.CorsGuardTests`, `Web.SecurityAspectWeavingTests`,
`Web.DispatchTests` all fail to compile (blocked by #5444).
`jvm_server_smoke.l` cannot compile until both land, so it stays
unregistered in `[project.tests]`.

**Formatter note.** `lyric-web/src/_kernel/jvm/web_kernel.l` refuses to
format: `lyric fmt --write` reports a loss-check failure on an `extern
type` string literal (`"java.util.Collection"` round-tripping through
the formatter would append a spurious `` `1 `` arity suffix, changing
the token content). Left unformatted per the "never hand-format around
a refusal" policy — a genuine formatter bug, not addressed here.

**Related:** #3334, #5324, #5439, #5440, #5443, #5444,
D-progress-625, D-progress-628.

---
## D-progress-630 — lyric-auth: real JVM JWT/API-key kernel (`javax.crypto.Mac`), replacing dead `extern package` (#5324)

**Context.** `lyric-auth/src/_kernel/jvm/auth_kernel.l` declared two
`extern package` blocks (`io.jsonwebtoken` for `verifyJwt`/`extractClaim`,
`java.security` for `verifyApiKey`). `extern package` is a confirmed no-op
in both the type checker and the MSIL/JVM codegens — it parses but
generates no real binding — so the JVM kernel was dead code: it could
never have verified a real JWT or compared a real API key at runtime, and
was already opt-in and CI-invisible (`lyric-auth/lyric.toml`
`[features] default = ["dotnet"]`). No Maven dependency for JJWT had ever
actually been wired either — the `io.jsonwebtoken` extern was purely
aspirational.

**Decision.** Do not bind the full JJWT fluent builder chain (a new Maven
dependency for no real benefit, and a multi-call object-lifecycle pattern
that doesn't fit `Auth.Kernel.Net`'s proven approach). Instead: port
`Auth.Kernel.Net`'s ~450 lines of pure-Lyric, platform-independent JWT
logic (base64url decode, JSON claim scanning with `aud` duplicate-key
detection, `parseLong` with overflow guards, the RFC 8725 §3.1 algorithm
allow-list, `exp`/`nbf` validation with clock-skew tolerance,
`fixedTimeEqualBytes`) verbatim into the JVM kernel, and bind exactly ONE
real native primitive via `extern type` + JVM auto-FFI: HMAC-SHA256 using
`javax.crypto.Mac`/`javax.crypto.spec.SecretKeySpec` (both in `java.base`,
no Maven dependency) — `SecretKeySpec.new(key, "HmacSHA256")` builds the
key material, `Mac.getInstance("HmacSHA256")` selects the algorithm,
`.init(keySpec)` binds it, `.doFinal(message)` computes the MAC. This is
the same `_kernel_jvm` idiom already proven by `Std.HashHost`
(`MessageDigest.getInstance(...).digest(...)`) and `Storage.Kernel.Jvm`.
`verifyApiKey` needed no extern binding at all — `fixedTimeEqualBytes` is
pure Lyric and ported unchanged. This collapses the JVM kernel from "two
broken `extern package` blocks with zero real dependency" to "one small
`extern type` HMAC-SHA256 primitive + a straight port of already-tested
pure-Lyric logic."

**Two additional pre-existing bugs blocked verification and were fixed
alongside (both narrowly scoped, both required to actually exercise the
new kernel on `--target jvm` rather than ship it untested):**

1. **`lyric-stdlib/std/encoding.l`'s `tryDecodeUtf8`** indexed a
   `slice[Byte]` into an unannotated `val b0 = bytes[i]` before calling
   `.toInt()`. On `--target jvm`, an un-annotated slice-index expression
   used as a numeric-intrinsic receiver loses its `Byte` element type
   before the `.toInt()`/`.toLong()`/etc. intrinsic check runs, so it fell
   through to JVM auto-FFI against `java.lang.Object` (which has no
   `toInt()` method), crashing `Jvm.Codegen` with an unhandled
   `System.Exception` for ANY program that imports `Std.Encoding` and
   compiles for JVM — a pre-existing, general stdlib/JVM-backend gap,
   reproduced independently of lyric-auth with a 9-line repro. Fixed by
   annotating the four `b0`/`b1`/`b2`/`b3` locals in `tryDecodeUtf8` as
   `Byte` explicitly (`val b0: Byte = bytes[i]`) — a type-annotation-only
   change, no behavior change, confirmed by both `lyric-auth` test suites
   passing unchanged on `--target dotnet` before and after.
2. **Generic `Option`/`Result` payload erasure for `slice[T]` on JVM.**
   D-progress-554 taught the JVM match-lowering to unbox PRIMITIVE scalar
   payloads (Int/Long/Double/Float/Boolean) bound from a generic
   `Option`/`Result` case, but explicitly left reference/array payloads
   boxed as `java.lang.Object` (documented in that entry as "stays
   boxed — pre-fix behaviour"). A `slice[Byte]` value extracted from
   `Std.Encoding.tryDecodeBase64`'s `Option[slice[Byte]]` result and then
   forwarded to ANY function expecting a concrete `slice[Byte]`
   parameter — including `Std.Encoding.tryDecodeUtf8` itself — fails JVM
   bytecode verification (`VerifyError: ... not assignable to
   '[Ljava/lang/Object;'`), reproduced with a 9-line repro fully
   independent of lyric-auth and of `tryDecodeBase64` specifically (a
   bare `Option[slice[Byte]]`-returning function has the same failure).
   This is a genuine, general self-hosted JVM backend limitation, not
   fixed here (out of scope — it needs the same `checkcast`-insertion
   treatment D-progress-554 gave primitives, generalized to array types,
   in `Jvm.Codegen`'s match-arm binding). Worked around locally: the JVM
   kernel implements its own base64url decoder
   (`tryFromBase64Url(seg, result: out slice[Byte]): Bool`,
   validation ported from `Std.Encoding.tryDecodeBase64`, byte
   accumulation from `Std.EncodingHost.hostFromBase64`) that returns via
   `Bool` + `out slice[Byte]` instead of `Option[slice[Byte]]` — writing
   through an `out` parameter assigns the concretely-typed local directly
   from a `List[Byte].toArray()` result, never through an
   `Option[slice[Byte]]` intermediate, which keeps the JVM backend's type
   inference intact (the same `List` + `newList` + `.toArray()`
   construction already proven by `Std.HashHost`/`Std.EncodingHost`).
   `Auth.jwtAlg` in `auth.l` (pre-existing, non-`@cfg`-gated
   belt-and-suspenders algorithm extraction, unrelated to the kernel
   rewrite) had the identical shape and was hitting the identical
   `VerifyError`; it is now `@cfg`-split into a `dotnet` branch (unchanged
   original body) and a `jvm` branch that calls the kernel's
   (now-`pub`) `tryFromBase64Url`.

**Alias-rewriter collision avoided defensively.** The JVM kernel's public
functions are named `verifyJwtImpl`/`extractClaimImpl`/`verifyApiKeyImpl`
(not `verifyJwt`/`extractClaim`/`verifyApiKey`), matching
`Auth.Kernel.Net`'s existing naming and its documented rationale
(`Lyric.AliasRewriter` is scope-blind: `AuthKernelJvm.extractClaim(...)`
rewrites to bare `extractClaim(...)`, which would otherwise resolve to
`Auth.extractClaim`'s own recursive call rather than the kernel — #1127,
#1094). The former (dead, `extern package`-only) kernel used
non-`Impl`-suffixed names that were never actually exercised at runtime;
`auth.l`'s two `@cfg(feature = "jvm")` call sites were updated to match.

**Verification.** HMAC-SHA256 is deterministic and byte-identical across
platforms, so `lyric-auth/tests/auth_security_tests.l`'s existing 32 test
cases (algorithm pinning, duplicate-alg/duplicate-aud attacks, exp/nbf
overflow, clock-skew, JSON escape decoding) — written once, shared
unconditionally across both `@cfg`-gated `Auth.verifyJwt` overloads — now
pass identically on both targets:

```
./bin/lyric test --manifest lyric-auth/lyric.toml
  # dotnet (default features): 2 passed, 0 failed (32 + 4 tests)
./bin/lyric test --manifest lyric-auth/lyric.toml --target jvm --no-default-features --features jvm
  # Auth.AuthSecurityTests: 32/32 pass (was: build crash / dead extern)
```

`Auth.AuthAspectWeavingTests` (4 tests, `Auth.Aspects.ValidateKey`) passes
on `dotnet` but fails on `jvm` with a `NoSuchMethodError`-shaped
`__LyricBModeCallContext` runtime crash. Confirmed via the FIRST (pre-fix)
JVM test run's raw output that this exact failure signature was already
present before any change in this entry — it is the self-hosted JVM
backend's B′-mode aspect-weaver codegen (D114/D115), a subsystem entirely
independent of `Auth.Kernel.Jvm`/`Auth.jwtAlg`, and out of scope here.
`lyric-auth/README.md`'s platform-parity table is corrected accordingly:
`Auth` is genuinely available and verified on both targets;
`Auth.Aspects.ValidateKey` is `.NET`-only pending that separate fix.

**Related:** #5324, D-progress-554 (the primitive-only unboxing this
entry's workaround routes around for `slice[Byte]`), D114/D115 (the
B′-mode aspect weaver whose JVM codegen gap this entry surfaces but does
not fix).

---

## D-progress-631 — `lyric-session`: real Lettuce-backed `Session.Kernel.Jvm` (`extern type` + auto-FFI, replacing the no-op `extern package` forward declaration), plus three newly-discovered self-hosted JVM auto-FFI bugs found and fixed/worked-around while wiring it up

**Status:** ACCEPTED

**Context.** `lyric-session/src/_kernel/jvm/session_kernel.l` declared two
`extern package` blocks (`lyric.session.RedisStore`, `lyric.session.InMemoryStore`)
— the confirmed no-op FFI mechanism (D-progress-625/#5324) — and the package was
never registered in `lyric.toml`'s `[project.packages]`, so it was never even
compiled. `Session.Kernel.Net` (the `.NET` StackExchange.Redis kernel) *was*
registered but gated on a bare `redis` feature with no `default` in
`[features]`, so it was ALSO never compiled by any CI run (`lyric test
--manifest lyric-session/lyric.toml` runs with no `--features` flag).

**What shipped.**

1. **`[maven]` table** added to `lyric-session/lyric.toml`:
   `io.lettuce:lettuce-core = "6.8.2.RELEASE"` (latest 6.x; verified via
   `lyric restore` against the real Maven Central metadata and a `javap`
   inspection of the downloaded JAR — every Lettuce API used below was
   checked against real bytecode, not documentation).
2. **`session_kernel.l` (jvm) rewritten** from the dead `extern package`
   forward declaration to real `extern type` + JVM auto-FFI bindings against
   `io.lettuce.core.RedisClient` (static factory `.create(url)`),
   `io.lettuce.core.api.StatefulRedisConnection` (`.connect()`/`.sync()`),
   `io.lettuce.core.api.sync.RedisCommands` (`.get`/`.set`/`.setex`/`.del`/
   `.expire`), and `io.lettuce.core.SetArgs` (`.new()`/`.keepttl()` for the
   `save()` keep-TTL semantics matching the .NET kernel's
   `StringSet(..., keepTtl: true)`). The dead `lyric.session.InMemoryStore`
   block (never called — `session.l`'s `InProcessSessionStore` is already
   pure Lyric and serves both targets with no kernel boundary) was deleted
   rather than ported, matching the `lyric-feature-flags` `Flags.Registry`
   precedent (D-progress-627 on `main`, not yet present on this branch's base).
3. **`[features]`** changed from the vestigial `redis`/`inmemory` pair (the
   `inmemory` feature gated nothing real) to `dotnet = []`, `jvm = []`,
   **no default feature**. An initial version of this change set
   `default = ["dotnet"]`, matching `lyric-auth`/`lyric-resilience`/
   `lyric-storage`'s platform-feature convention on the surface — but
   unlike those libraries' `dotnet` default (needs no external package:
   pure Lyric + BCL), this library's `dotnet` kernel has a genuine
   mandatory NuGet dependency (`StackExchange.Redis`). Defaulting it on
   broke CI: `ecosystem-security-tests` (building `lyric-testing` ->
   `lyric-mq` -> `lyric-session` as a workspace dependency, which does
   not restore NuGet for transitive deps) and `stdlib-builds` (the
   tier-1 ecosystem-library build loop, plain `lyric build --manifest
   lyric-session/lyric.toml`, no restore) both crashed with `FFI extern
   'StackExchange.Redis.ConnectionMultiplexer.Connect' ... cannot be
   resolved to any indexed reference assembly`, since neither path had
   run `lyric restore` first. Caught by CI on this same PR before merge;
   fixed by removing the default so a bare `lyric build`/`lyric test`
   (no explicit `--features`) only ever compiles the kernel-free
   `Session` package — safe for any workspace-dependent consumer with no
   prior restore — and updating `.github/workflows/ci.yml`'s dedicated
   `lyric-session` test step to `lyric restore` then
   `lyric test --features dotnet` explicitly, matching how the `jvm`
   feature was already invoked (`--target jvm --no-default-features
   --features jvm`). `Session.Kernel.Net`'s package-level gate moved
   from `feature = "redis"` to `feature = "dotnet"`; `Session.Kernel.Jvm`
   registered in `[project.packages]` for the first time, gated
   `feature = "jvm"`.
   `session.l`'s `NativeSessionStore` record, its `SessionStore` impl, and
   `connectRedis()` are each duplicated into `@cfg(feature = "dotnet")` /
   `@cfg(feature = "jvm")` pairs (the `auth.l` dispatch idiom), since the
   `storeHandle` field's concrete type differs per kernel. The shared JSON
   wire-format helpers (`jsonEscapeStr`/`serializeSessionJson`/
   `parseSessionJson`) are left ungated — pure Lyric over `Std.Json`, which
   already has a JVM kernel twin (`_kernel_jvm/json_host.l`), so they compile
   identically on both targets.
4. **Pre-existing `.NET`-kernel bug fixed as a side effect of #3**: making
   `dotnet` the default feature meant `Session.Kernel.Net` now compiles on
   every default `lyric test` run for the first time ever, which
   immediately surfaced `error[T0070]`: every one of its six kernel
   functions used the `func f(...): T = { try { ... } catch Bug as b { ...
   } }` expression-body form, and the self-hosted type checker infers
   `<error>` for a `try`/`catch` block's type specifically in that form
   (confirmed with an 8-line minimal repro — a block-bodied `func f(...):
   T { try { ... } catch ... }` with an otherwise-identical body
   type-checks fine). Converted to block-body form (semantically
   identical, and the form already used everywhere else in this file and
   `session.l`) rather than chasing the type-checker bug itself — out of
   scope for this change, but worth a follow-up issue since it silently
   made `Session.Kernel.Net` a compile-time no-op since #1777 shipped it.
5. **Three previously-undiscovered self-hosted JVM compiler bugs**, found
   because Lettuce's core client types (`StatefulRedisConnection`,
   `RedisCommands`) are the first case in the ecosystem of an `extern type`
   bound directly to a JDK/Maven **interface** rather than a concrete class
   (every existing `_kernel_jvm`/ecosystem kernel binds only concrete BCL
   classes — `HashMap`, `File`, `MessageDigest`, etc.):
   - **JVM auto-FFI never supported interface-typed extern types at all.**
     `jvm/class_reader.l`'s `parseClass` unconditionally `return None`d for
     any `ACC_INTERFACE` class file, so `loadClass()` on an interface
     always failed, silently falling through to the legacy
     `(args...)Object` `invokevirtual` guess — which the JVM verifier
     rejects for an interface owner ("Found interface X, but class was
     expected", JVMS §6.5 `invokevirtual`'s "must not be an interface"
     rule). Fixed at the root: `ClassInfo` gained an `isInterface: Bool`
     field (from `ACC_INTERFACE`, alongside the pre-existing `isAbstract`
     from `ACC_ABSTRACT`; enums/annotations are still skipped), and
     `jvm/codegen/04_calls.l`'s `lowerAutoFfiInstanceCall` emits
     `LInvokeinterface` instead of `LInvokevirtual` when the resolved
     owner is an interface — the auto-FFI/extern-type counterpart of the
     existing `sig.isIface` dispatch fix for in-package `impl` methods
     (#3687/"m-17b", `docs/44`). Separately, `RedisCommands` itself
     declares almost none of its own methods (`get`/`set`/`setex`/`del`/
     `expire` live on sibling interfaces it extends, e.g.
     `RedisStringCommands`/`RedisKeyCommands`), so `auto_ffi.l`'s
     `findBestInstanceMethod` — which only walked the single-parent
     `superName` chain — gained a new recursive `scoreInterfacesRec` walk
     over `ClassInfo.interfaces` (with a visited-set guard against diamond
     re-scoring), invoked both for the receiver's own interface list and
     for each class in the existing superclass walk. The emitted
     `invokeinterface`'s owner still names the original receiver type
     (not the interface that actually declared the method) — intentional
     and correct per JVMS 5.4.3.4's own superinterface-search resolution
     algorithm, so only the compile-time *lookup* needed the extra walk.
     Verified with a from-scratch minimal repro (a JDK-free two-interface
     hierarchy) before touching Lettuce, and the existing
     `auto_ffi_jvm_self_test.l` (22 cases) / `iface_dispatch_jvm_self_test.l`
     (3 cases) / `auto_ffi_self_test.l` (14 cases) / `bitwise_self_test.l` /
     `generic_jvm_self_test.l` / `aspect_weave_self_test.l` self-tests all
     still pass unchanged after the fix.
   - **Java varargs methods** (`RedisKeyCommands.del(K...)`, bytecode
     descriptor `([Ljava/lang/Object;)Ljava/lang/Long;`) have no
     auto-wrapping at the bytecode level — javac's single-argument-to-array
     sugar is source-level only. `scoreMethod` correctly rejects a bare
     scalar argument against the array-typed parameter (no silent
     mis-resolution), so this needed an application-level fix rather than
     a compiler one: `session_kernel.l` (jvm) builds an explicit
     `List[String]` + `.toArray()` for `del`'s single-key call. Documented
     inline; not a compiler bug.
   - **Cross-package qualified call inside an `impl` block, whose callee
     name collides with the enclosing interface's own method name, gets
     misrouted to intra-impl self-dispatch.** `NativeSessionStore.load()`
     calling `SessionKernelJvm.load(self.storeHandle, sessionId)` (a
     package-qualified call to an unrelated 2-arg static function) produced
     a `VerifyError` ("Bad type on operand stack" — the `self.storeHandle`
     field, checkcast to `String`, ends up on the stack where the `self`
     receiver for a recursive `load(sessionId)`-shaped invokevirtual was
     expected). Reproduced with a minimal two-package, JDK-free repro
     independent of any Lettuce/Redis code, confirming it as a distinct,
     general codegen defect — the compiler's own bare-intra-impl-call bug
     (`m-4`/#1722 in `docs/44`, previously known only for *unqualified*
     bare calls) apparently also mis-fires for a *qualified* cross-package
     call when the name happens to match a sibling interface method. Not
     fixed at the root (would need locating exactly where `Package.func(...)`
     calls are lowered inside `impl` bodies and untangling the name-priority
     logic — a different area of the codegen than the interface-dispatch fix
     above, and higher-risk to patch blind without deeper familiarity).
     Worked around by renaming the kernel's public functions so they no
     longer collide with the `SessionStore` interface's method names
     (`create`/`load`/`save`/`destroy`/`touch` → `kernelCreate`/`kernelLoad`/
     `kernelSave`/`kernelDestroy`/`kernelTouch` in both `Session.Kernel.Net`
     and `Session.Kernel.Jvm`, for symmetry, plus `session.l`'s call sites)
     — a legitimate internal rename (both kernels are internal, documented
     "only `Session` should import this"), and arguably better practice
     regardless of the bug. Filed as a follow-up; #1722 is the closest
     existing tracker but this qualified-call variant is a new symptom.
   - Also fixed in `session.l` while getting the Redis path to actually run
     end-to-end against a live server for the first time: `for k in
     data.entries` (iterating a `Map[String, String]` directly) assumes the
     Map's erased runtime representation is itself `Iterable`, which holds
     for the `.NET` kernel's `Dictionary` but not the JVM kernel's raw
     `java.util.HashMap` (`Class java.util.HashMap does not implement the
     requested interface java.lang.Iterable` at runtime) — switched to
     `mapKeys(data.entries)`, matching `_kernel_jvm/collections_host.l`'s
     documented idiom. And `jsonEscapeStr` returned `Std.Json.encodeString`'s
     result directly, which is a *complete* quoted JSON string literal on
     both kernels (`_kernel/json_host.l` and `_kernel_jvm/json_host.l`'s
     `hostEncodeString` both wrap in `"..."`) — but every call site also
     added its own surrounding quotes, double-quoting every string field
     (`"id":""abc""`) and making `parseSessionJson` fail to parse its own
     output. Both bugs are pre-existing and platform-symmetric (not
     JVM-only), just never exercised because the Redis-backed store had
     never been run against a live server on either target before this.
6. **`tests/session_redis_jvm_tests.l`** — new CRUD integration suite
   (connectRedis/create/load/get/set/delete/clear/touch/destroy, 13 cases)
   registered in `[project.tests]`. Not `@cfg`-gated (file-level `@cfg` is
   not applied to `[project.tests]` sources — `cli_test.l` feeds each test
   file straight to `TestSynth.synthesize` + `emitProject`, bypassing
   `Cfg`/`CfgGate` entirely; confirmed with a throwaway always-false
   `@cfg(feature = "impossible")` test file that still ran), so it
   transparently exercises whichever backend (`Session.Kernel.Net` or
   `Session.Kernel.Jvm`) is active for the current build. Every case
   no-ops when `LYRIC_CONFIG_SESSION_REDISSESSION_URL` is unset, so the
   default `lyric test` run (no live Redis) stays green — the existing
   31-test baseline (`SessionFixationTests`/`SessionStoreTests`/
   `SensitiveUrlTests`) is unaffected either way.
7. **Verified against a real local Redis 7.0.15 server** (`redis-server`,
   available in this sandbox): all 13 cases pass on `--target jvm
   --no-default-features --features jvm` via real Lettuce calls (`lyric
   restore` resolving the real Maven artifact, then `lyric test` directly
   — see item 8 for the classpath-injection fix that made this possible
   without a manual `java -cp` step). All 13 also pass on `--target
   dotnet --features dotnet` when no Redis URL is configured (skip path);
   with a live Redis and the StackExchange.Redis-format URL, 4/13 pass
   and 9/13 hit an unrelated, independently-reproduced pre-existing MSIL
   bug (item 9).
8. **Originally found as a pre-existing gap (`lyric test --target jvm`
   never wired the `[maven]`-restored classpath at *run* time) and fixed
   in the same PR by `lyric-aws-xray`'s integration.** `lyric build
   --target jvm` correctly read `target/restore/jvm-classpath.txt` and
   injected `LYRIC_FFI_JARS` for auto-FFI resolution at *compile* time
   (`cli_build.l`), but `cli_test.l` exec'd the produced JAR as a bare
   `java -jar` with no `-cp`/`--module-path` for the same restored
   dependencies, so a Maven-dependent JVM test JAR, correctly compiled,
   still threw `ClassNotFoundException` at *run* time. Originally worked
   around here (in this entry's initial version) by manually exporting
   `LYRIC_FFI_JARS` and running the compiled test JAR directly via `java
   -cp` — now fixed at the root by `cli_test.l`'s
   `injectMavenClasspathForJvm`/`java -cp <maven-jars>:<jar> <MainClass>`
   change (see the `lyric-aws-xray` decision-log entry, integrated into
   this same PR), re-verified here:
   `lyric-session/tests/session_redis_jvm_tests.l`'s 13 cases now pass via
   a direct `lyric test --manifest lyric-session/lyric.toml --target jvm
   --no-default-features --features jvm` with no manual classpath
   assembly. Not specific to `lyric-session`; the fix benefits every
   `[maven]`-declared ecosystem library's `lyric test --target jvm`.
9. **Confirmed pre-existing, independently-reproduced bug (not fixed,
   out of scope): MSIL cross-package `System.Nullable\`1[T]` value type
   fails to load when 3+ packages are bundled via `lyric test`.**
   `Could not load type 'System.Nullable\`1' ... due to value type
   mismatch` when `Session.Kernel.Net`'s `create()`/`touch()` (which use
   `extern type NullableTimeSpan = "System.Nullable\`1[System.TimeSpan]"`)
   are exercised via the new test file's 3-package bundle
   (test + `Session` + `Session.Kernel.Net`). Reproduced with a minimal,
   completely unrelated 3-package/1-test repro (package A declares the
   `Nullable\`1[TimeSpan]` extern type and two functions using it; package
   B calls both; a `@test_module` in a third package calls B) — same
   crash, confirming it is a general `lyric test` multi-package MSIL
   bundling defect with no dependency on Redis or session code. This is
   why the .NET-target `SessionRedisJvmTests` (item 5/7) can only get 4/13
   passing with a live server today, despite `Session.Kernel.Net`'s Redis
   logic itself being correct (`connectRedis`/`load`/`set`
   (`SESSION_NOT_FOUND` path)/`destroy` all pass — every failure is
   specifically a case that reaches `create()` or `touch()`).

10. **Newly-found while running the full `lyric test --manifest
    lyric-session/lyric.toml --target jvm` suite (not just the new Redis
    test file) as part of integrating this work: `InProcessSessionStore`
    — `Session.inMemory()`, entirely unrelated to the Redis kernel work
    above — is broken on JVM.** `SessionFixationTests` (1/5 fail) and
    `SessionStoreTests` (8/15 fail) both crash with `class
    Session.SessionData cannot be cast to class java.lang.Long` the
    moment a session actually stores data (`create()` alone passes;
    `set()`/`get()`/`load()` after a real write crash). `--target
    dotnet` passes both files unchanged. This looks like the same
    erased-generic-confusion family as #5439/#5442/#5444 (found
    integrating `lyric-i18n` and `lyric-web` in the same PR) — here a
    `Map[String, SessionData]` read appears to resolve against an
    unrelated `Map[String, Long]` instantiation elsewhere in the same
    JVM bundle. Filed as #5451 (not fixed here — a deep JVM erasure
    defect, out of scope for a library-level change). `README.md`'s
    platform-parity table is corrected: the Redis-backed
    `NativeSessionStore` is genuinely available and verified on JVM;
    `InProcessSessionStore` is NOT currently usable on JVM.

**Files changed:** `lyric-session/lyric.toml`,
`lyric-session/src/_kernel/net/session_kernel.l`,
`lyric-session/src/_kernel/jvm/session_kernel.l`, `lyric-session/src/session.l`,
`lyric-session/tests/session_redis_jvm_tests.l` (new),
`lyric-session/README.md`; `lyric-compiler/jvm/class_reader.l`,
`lyric-compiler/jvm/auto_ffi.l`, `lyric-compiler/jvm/codegen/04_calls.l`.

**Related:** #1722 (m-4, bare intra-impl calls — this entry's item 5's
qualified-call variant is a new symptom of the same family), #3687/"m-17b"
(the in-package `impl`-dispatch analog of this entry's interface-auto-FFI
fix), D-progress-625 (`extern package` no-op precedent), D-progress-627 on
`main` (`Flags.Registry` in-memory-store deletion precedent, not yet
present on this branch's base commit), #5439, #5442, #5444, #5451 (the
erased-generic-confusion family this entry's item 10 adds a fifth
instance to).


---
## D-progress-632 — `lyric-aws-xray`: `aws`/`jvm` migrated off `extern package` onto `extern type` + auto-FFI against the real AWS X-Ray SDKs; JVM auto-FFI interface dispatch (adopted from D-progress-631), `lyric test --target jvm` Maven classpath, and a wrong NuGet package ID fixed as prerequisites; 2 new pre-existing MSIL auto-FFI gaps found and documented (1 filed as #5452, its `lyric-session` risk checked and ruled out), JVM `Tracing` aspect blocked on a pre-existing weaver bug (not fixed here)

**Status:** ACCEPTED (bindings shipped and verified on all 3 features); 2 newly-discovered MSIL gaps and 1 pre-existing JVM weaver gap deliberately NOT fixed here (see below)

**Context.** `lyric-aws-xray/src/xray.l`'s `aws` (.NET) and `jvm` feature
blocks were each a hand-written `extern package` — a confirmed permanent
no-op in both the type checker and both codegens (`docs/03` recent
`extern package` entries; issue #5324) — so both features compiled but
`currentSubsegment`/`annotate`/`metadata`/the `Tracing` aspect silently did
nothing at runtime on either target. Only `local` (an intentional no-op) was
real. A separate `src/_kernel/xray_kernel_{local,jvm,aws}.l` trio was
orphaned dead code (never registered in `lyric.toml`, never imported) and is
left in place per the "don't delete, roll forward" policy — it was not
touched.

**What shipped in `xray.l`.**

- **`SubsegmentHandle`** is now three separate `@cfg`-gated declarations
  (only one survives erasure per build) instead of one shared zero-field
  opaque record: `local` keeps the opaque no-op record; `aws` aliases
  directly to `Amazon.XRay.Recorder.Core.Internal.Entities.Entity` (the
  `.Internal` namespace segment is real, confirmed via `System.Reflection`
  against the actual NuGet package — the type itself is public); `jvm`
  aliases directly to `com.amazonaws.xray.entities.Entity` (the interface,
  not the narrower `Subsegment`, because `putAnnotation`/`putMetadata` are
  declared on `Entity` itself and every real producer — `beginSubsegment`,
  `getCurrentSubsegment`, `DummySubsegment` — is a `Subsegment`, which
  extends `Entity`, a safe upcast). This mirrors the `Std.ProcessHost
  .ProcessHandle = "java.lang.Process"` no-wrapper-record precedent
  (D-progress-625's `process_host.l`).
- **`aws`:** `AWSXRayRecorder.Instance` (static property) plus
  `BeginSubsegment`/`EndSubsegment`/`AddAnnotation`/`AddMetadata`/
  `GetEntity`/`IsEntityPresent` (all instance) as `@externTarget` wrappers.
  The .NET SDK is ambient/thread-local (unlike Java): these calls act on the
  recorder's *current* entity, not an explicit handle — the `handle`
  parameters `annotate`/`metadata`/`endSubsegment` accept are unused on this
  backend, which is correct because `beginSubsegment`/`endSubsegment` pairs
  always run on the same call stack. `AWSXRayRecorder.GetEntity()` is the
  one call that throws (not log-and-continue) when no segment/subsegment is
  active — verified directly by invoking the real SDK via
  `System.Reflection` outside this compiler entirely — so `awsSafeEntity`
  guards it with `IsEntityPresent()` first and falls back to `default()` (a
  null `Entity`), which is safe specifically because nothing on this
  backend ever dereferences the handle value.
- **`jvm`:** `AWSXRay.getGlobalRecorder()` (static) plus
  `AWSXRayRecorder.beginSubsegment`/`endSubsegment` and
  `Entity.putAnnotation`/`putMetadata` as bare auto-FFI dot-calls (the
  Java SDK returns the real subsegment object from `beginSubsegment`, so
  `annotate`/`metadata` call directly on the handle rather than through the
  recorder). `getCurrentSubsegment()`'s nullable return falls back to a real
  SDK `DummySubsegment` (constructed via `.new(recorder)`) on `null`,
  mirroring the Java SDK's own designed-for-this-purpose no-op entity type.
- **New public API:** `AwsXRay.beginSubsegment(name): SubsegmentHandle` /
  `AwsXRay.endSubsegment(handle): Unit`, exposing the same manual lifecycle
  the `Tracing` aspect's `around` advice already ran internally. Added
  because `tests/xray_tests.l` needed a way to exercise the real begin →
  annotate/metadata → end sequence without depending on the aspect weaver
  (see the JVM weaver gap below), and because it is a genuinely useful
  capability this library previously had no public entry point for.

**Three prerequisite fixes, all required to get `xray.l` compiling and
running for real (none aws-xray-specific — each is a general compiler/CLI
gap that happened to block this task first):**

1. **JVM auto-FFI never resolved interface types at all** (not
   `jvm`-instance-dispatch-specific — a class-file-parsing gap).
   `Jvm.ClassReader.parseClass` unconditionally returned `None` for any
   `ACC_INTERFACE` class file (`lyric-compiler/jvm/class_reader.l`), so an
   `extern type` naming a Java interface (`com.amazonaws.xray.entities
   .Entity`) failed to load at all — independently discovered here at
   essentially the same time as `lyric-session`'s Lettuce Redis kernel
   work hit the identical gap (`io.lettuce.core.api.sync.RedisCommands`,
   also interface-typed). The version that landed is `lyric-session`'s
   (D-progress-631): it adds the same `ClassInfo.isInterface` field and
   `invokeinterface`-vs-`invokevirtual` selection this entry's own draft
   fix did, plus a superset this entry's narrower fix didn't need —
   `Jvm.AutoFfi.findBestInstanceMethod`'s recursive superinterface walk
   (`scoreInterfacesRec`), required because Lettuce's `RedisCommands`
   declares almost none of its own methods (they live on sibling
   interfaces it extends), unlike X-Ray's `Entity`/`Subsegment` which
   declare `putAnnotation`/`putMetadata` directly. Verified with no
   regressions against the adopted fix: the full `auto_ffi_jvm_self_test.l`
   (22 cases), `iface_dispatch_jvm_self_test.l` (3 cases),
   `bitwise_self_test.l`, and `aspect_weave_self_test.l` on `--target jvm`
   all still pass, and `xray_tests.l`'s 4 cases pass on `--features jvm`
   against the real X-Ray Java SDK.
2. **`lyric test --target jvm` never resolved `[maven]` dependencies at
   all** for manifest (multi-package) test suites — `cli_build.l`'s
   `injectMavenClasspathForJvm` (compile-time `LYRIC_FFI_JARS` injection)
   was never called from `cli_test.l`'s `cmdTestManifest`, and even with
   `LYRIC_FFI_JARS` set manually the compiled JAR was run as `java -jar
   <jar>` unconditionally — Maven-resolved third-party classes are never
   copied into the bundled JAR (`module-path.txt`, written by `cli_build.l`
   for exactly this reason, documents the same constraint for `lyric
   build`), so `-jar` alone can never find them regardless of compile-time
   resolution. Fixed: `cmdTestManifest` now calls
   `injectMavenClasspathForJvm` before compiling (restored via `defer`),
   and runs with `java -cp "<mavenClasspath>:<jar>" <MainClass>` instead of
   `-jar` when a non-empty Maven classpath was resolved (`<MainClass>` is
   the manifest's `[project.tests]` key, matching `Jvm.Bridge`'s Main-Class
   derivation from the dotted package declaration). Verified: 34/34 on
   `lyric-storage` (`--target jvm`, no `[maven]` — confirms the `-jar`
   fallback path is unaffected) and 11/11 on `lyric-session` (`--target
   dotnet` — confirms the dotnet path is untouched).
3. **`lyric-aws-xray/lyric.toml`'s `[nuget]` entry named the wrong package
   ID.** `"Amazon.XRay.Recorder.Core"` is the .NET *namespace*, not the
   NuGet package ID (`AWSXRayRecorder.Core`) — confirmed via the live
   NuGet.org search API (`amazon.xray.recorder.core` 404s;
   `awsxrayrecorder.core` is the real package, version 2.14.0 exists).
   `lyric restore` silently reported `NU1101` for the wrong name; nothing
   in the existing test suite exercised a real restore, so this had never
   been caught. Fixed the manifest entry.

**Two newly-discovered MSIL auto-FFI gaps, deliberately NOT fixed here**
(both are general `Msil.Codegen`/`Msil.Ffi` limitations well outside this
task's scope; worked around in `xray.l` itself, documented inline there):

- **A Lyric `extern type` alias for a closed-generic value type (e.g.
  `"System.Nullable\`1[System.DateTime]"`) has no flat TypeRef identity and
  silently erases to `object`** in `typeExprToMsilCtx`, producing a
  MemberRef that doesn't bind to the real `Nullable<T>`-typed BCL parameter
  (`MissingMethodException` at runtime, not a build-time diagnostic).
  Metadata-resolved `Nullable<T>` params/returns built from a real BCL
  signature during `@externTarget`'s trailing-optional-parameter auto-fill
  do *not* have this problem (they route through `resolvedSigToMsil`,
  which correctly builds `MValueTypeGenericInst`) — `xray.l` avoids the bug
  entirely by never declaring a `Nullable<T>` extern type itself, leaving
  every `DateTime?` parameter unsupplied for the compiler to auto-fill.
- **Neither the `@externTarget` metadata resolver
  (`Mdr.resolveExternMethodScored`/`resolveExternMethodScoredIn`) nor the
  bare-dot-call auto-FFI resolver (`Mdr.resolveExtern`/`resolveOverloadIn`)
  walks a BCL type's superclass chain.** A member inherited from a base
  class (not literally declared on the exact TypeDef the `@externTarget`
  names) with a non-trivial parameter list — anything beyond zero
  parameters, where there is nothing for a wrong fallback encoding to get
  wrong — silently falls back to the Lyric-declared (possibly wrong: e.g.
  `string` where the BCL takes `object`) signature instead of failing
  loudly, producing a `MissingMethodException` at runtime rather than a
  build-time diagnostic. Confirmed with `AWSXRayRecorder.AddAnnotation`/
  `AddMetadata` (declared on the base class `AWSXRayRecorderImpl`, not on
  `AWSXRayRecorder`): resolution only succeeded once the `@externTarget`
  target string named `AWSXRayRecorderImpl` directly.  `GetEntity`/
  `IsEntityPresent` (same base-class situation, zero parameters) worked
  regardless, which is what makes this gap easy to miss. Filed as #5452.
  This raised a suspected risk for `lyric-session/src/_kernel/net
  /session_kernel.l`, integrated into this same PR (D-progress-631):
  `getDatabase`/`strSetCreate`/`strSetKeepTtl`/`strGet`/`keyDel`/
  `keyExpire`/`redisValueIsNull`/`redisValueToString` are ALL declared
  without `@externStatic`/`@externInstance` against `StackExchange.Redis`
  interface members (`IDatabase`/`RedisValue`) with multi-parameter
  signatures — the same shape that silently mis-emitted here. **Checked
  directly against a real local Redis server** (`redis-server`,
  `LYRIC_CONFIG_SESSION_REDISSESSION_URL="redis://127.0.0.1:6379,
  abortConnect=false"`, `--features dotnet`): `connectRedis()`,
  `load()` for an unknown id, `set()` on an unknown id, and `destroy()`
  on an absent id all completed real `IDatabase`/`RedisValue` round
  trips with no `MissingMethodException` — the risk did not materialize
  for this specific interface (`getDatabase`/`strGet`/`keyDel` etc. must
  each be declared directly on `IDatabase` itself, not inherited from a
  base type, unlike `AWSXRayRecorderImpl`). The remaining 9/13 cases
  failed on the already-known, unrelated `System.Nullable\`1` bug
  (D-progress-631 item 9), exactly as that entry documents. No follow-up
  needed for `lyric-session` specifically; #5452 remains open as the
  general `Msil.Ffi` gap for any future `@externTarget` binding an
  inherited BCL member with a non-trivial signature.

**One pre-existing JVM weaver gap, deliberately NOT fixed here:**
`AwsXRay.Tracing` is a `pub aspect` without `@inline_template`, so any
cross-package `aspect X from AwsXRay.Tracing { ... }` instantiation is
B'-mode (docs/55). B'-mode's JVM call-context codegen throws
`NoSuchMethodError` on the synthesised `__LyricBModeCallContext` at runtime
— reproduced with a minimal single-matched-function case, confirmed absent
on `--target dotnet` (MSIL handles the identical cross-package B'-mode
shape correctly) and confirmed pre-existing:
`aspect_weave_self_test.l` — the only existing runtime coverage for
B'-mode aspect weaving on JVM — exercises only same-package, non-`from`
aspects, and its own header note already flags "the multi-file scenario
where a consumer package imports a library template" as untested (tracked
separately as #3498 per docs/26's changelog). `tests/xray_tests.l` works
around this by testing the real `beginSubsegment`/`annotate`/`metadata`/
`endSubsegment` SDK calls directly instead of through the aspect — the
`Tracing` aspect itself is unaffected on `local`/`aws` and works correctly
there; only cross-package instantiation on `--target jvm` is blocked.
README's platform-parity table documents this precisely.

**Verified:** `lyric-aws-xray`'s full `tests/xray_tests.l` suite (4 cases)
passes on all three features: `--features local` (default target),
`--features aws --target dotnet`, and `--features jvm --target jvm` (via
`lyric restore` + `make maven-resolver` + `LYRIC_MAVEN_RESOLVER`). All four
cases exercise the real SDK: package import, `currentSubsegment`/
`annotate`/`metadata` with no active context (the `awsSafeEntity`/
`DummySubsegment` fallback paths), and the full `beginSubsegment` →
`currentSubsegment`/`annotate`/`metadata` → `endSubsegment` lifecycle on
both the happy path and the error-annotation path. `lyric fmt --write` run
on every changed `.l` file.

**Related:** #5452 (the `@externInstance`-required MSIL gap this entry
found), #3498 (pre-existing JVM B'-mode cross-package weaver gap,
already tracked), #5324 (`extern package` no-op), D-progress-631
(`lyric-session`'s Lettuce kernel — the JVM interface auto-FFI fix that
landed, and the `Session.Kernel.Net` risk this entry raised and
verified against).

---

## D-progress-633 — `lyric-jobs`: real Quartz JVM kernel; `Class-Path:` manifest embedding for `lyric run`/`lyric test --target jvm`; `List[T].removeAt` JVM support; two new record-constructor/erased-generics JVM bugs found

**Status:** ACCEPTED (`Jobs.Kernel.Jvm` + 3 compiler fixes); 2 newly-found
JVM backend bugs deliberately NOT fixed here (see below).

**Context.** `Jobs.Kernel.Jvm`'s Quartz binding predated this PR as dead
scaffolding: an `extern package`-based forward declaration (confirmed
permanent no-op, D-progress-625/#5324), never registered as a real
working backend. `InProcessJobScheduler` (pure Lyric, no kernel) was the
only genuinely functional scheduler.

**What shipped.**

- `lyric-jobs/src/_kernel/jvm/jobs_kernel.l`: real `org.quartz-scheduler
  :quartz`/`quartz-jobs` bindings via `extern type` + JVM auto-FFI —
  `SchedulerFactory`/`Scheduler`/`JobDetail`/`Trigger`/`CronTrigger`
  wired to schedule, run, poll, cancel, and report errors for real jobs
  executed on Quartz's own thread pool. Bound to Quartz's public
  `org.quartz.impl.StdScheduler` facade class rather than the
  `Scheduler` interface it implements (a deliberate workaround for the
  interface-auto-FFI gap — see below — that predates and is independent
  of that gap's actual fix; both now work, and the facade binding was
  left as-is rather than switched).
- **Two new JVM backend bugs found, one fixed, one filed:**
  - **Fixed directly** (`lyric-compiler/jvm/codegen/04_calls.l`):
    `List[T].removeAt(index: Int): Unit` had no JDK translation at all
    — Lyric's `List` maps to `java.util.ArrayList`, whose index-based
    removal is `remove(int)`, but `ArrayList` also overloads
    `remove(Object)` for value-based removal, so the emitted call must
    force the argument through as a raw (unboxed) `int` to select the
    correct overload rather than autoboxing into the wrong one. First
    hit by `InProcessJobScheduler.cancel`'s `self.queue.removeAt(i)` —
    blocked compiling `Jobs` for JVM at all before this fix.
  - **Filed as #5457, not fixed** (general record-constructor codegen
    gap): a `var …: Bool` field declared immediately adjacent to a
    `Long` field, or a defaulted field (`= default()`) ahead of a
    `Long`/trailing-reference field, miscompiles the record constructor
    (`VerifyError: Bad type on operand stack` — a local-slot width bug,
    reproduced independently of `lyric-jobs` in a minimal record with
    the same field shape). Worked around in `JobRecord` by field
    reordering (both `Long` fields declared before the `Bool` field)
    and supplying every field explicitly at every construction site (no
    `= default()` anywhere).
  - The interface-auto-FFI gap this kernel's `StdScheduler`-facade
    workaround predates (`ClassInfo`/`ACC_INTERFACE` skipped entirely,
    causing `invokevirtual`-against-interface `VerifyError`s) was
    independently found and fixed by `lyric-session`'s Lettuce Redis
    kernel work in this same PR (D-progress-631) — not re-fixed here.
- **`Class-Path:` JAR manifest embedding**
  (`lyric-compiler/jvm/{bridge,driver,manifest}.l`): `PackageMeta`
  gained a `classpathJars: List[String]` field (populated from
  `autoFfi.jarPaths`, itself `LYRIC_FFI_JARS` — a restored project's
  `target/restore/jvm-classpath.txt`), embedded as a JAR manifest
  `Class-Path:` attribute (wrapped to the JAR spec's 72-byte
  continuation-line limit) whenever a package has Maven dependencies.
  Fixes `lyric run --target jvm` (which execs a bare `java -jar` and,
  before this, could never see `[maven]`-restored classes at runtime —
  a gap `lyric-session`'s D-progress-631 entry documented as still open
  for `lyric run` specifically after its own `lyric test`-only fix) and
  complements `cli_test.l`'s independently-landed `java -cp` injection
  for `lyric test --target jvm` (D-progress-632). **A bug in this
  change's own line-wrapping logic** (`wrapManifestLine`'s continuation
  branch called `remaining.substring(limit, remaining.length)` — passing
  the *original* remaining length as the substring's `count` parameter
  instead of `remaining.length - limit`, always requesting more
  characters than actually remained) crashed `System.String.Substring`
  with `ArgumentOutOfRangeException` for any classpath long enough to
  need wrapping (7+ Maven JARs, first hit integrating `lyric-ws`'s
  Undertow + transitive dependency set into this same PR). Fixed as part
  of this integration; the `removeAt` fix's own shorter classpath (2
  Quartz JARs) never exercised the wrapping branch, so this was a
  latent bug in the originally-landed code, not a new regression.

**Verification.** `./bin/lyric test --manifest lyric-jobs/lyric.toml`:
`--target dotnet` (default features) 17/17 pass, no regression.
`--target jvm --no-default-features --features jvm,inprocess`: 10/17
pass — the real Quartz end-to-end case (schedule/run/poll/cancel/error)
passes cleanly; the 7 failures are `InProcessJobScheduler`/`JobResult`
cases hitting a newly-found, separate erased-generics bug (`List[JobSpec]`
confused with an unrelated `Integer`-typed value elsewhere in the JVM
bundle — filed as #5456, same family as #5439/#5442/#5444/#5451, not
caused by or specific to the Quartz kernel work above).
`lyric-jobs/README.md`'s platform-parity table corrected: `dotnet`
`InProcessJobScheduler` remains Available; `jvm` `InProcessJobScheduler`
is now honestly marked Broken (#5456) rather than the prior blanket
Available claim.

**Related:** #5324, #5456, #5457, D-progress-631 (the interface-auto-FFI
fix this kernel's workaround predates), D-progress-632 (`lyric test
--target jvm` Maven classpath — the `cli_test.l` half of the same
run-time classpath problem this entry's `Class-Path:` manifest work
complements).

---

## D-progress-634 — `lyric-ws`: real Undertow JVM WebSocket kernel; workspace dependencies now inherit the consumer's `--features`/`--target` selection (general compiler fix); three more JVM backend gaps found and precisely diagnosed, not fixed

**Status:** ACCEPTED (`Ws.Kernel.Jvm` + compiler fixes); 3 newly-discovered
JVM backend bugs filed via this entry and deliberately NOT fixed here —
each precisely diagnosed and worked around in the file/comment nearest
its symptom.

**Context.** `lyric-ws/src/_kernel/jvm/ws_kernel.l` declared `extern
package` FFI blocks (a confirmed no-op mechanism) for a fake Int-handle
Undertow WebSocket server; `Ws.Kernel.Jvm` was registered in
`lyric-ws/lyric.toml`'s `[project.packages]` (so it compiled) but
`ws.l` never imported it, so the JVM feature was unreachable. No
`[maven]` table existed for `io.undertow:undertow-core`.

**What shipped.**

- `lyric-ws/lyric.toml`: added a `[maven]` table for
  `io.undertow:undertow-core` (same version as `lyric-web`'s Undertow
  HTTP kernel, `2.3.13.Final`).
- `lyric-ws/src/_kernel/jvm/ws_kernel.l`: full rewrite off `extern
  package` onto `extern type` + auto-FFI against real
  `io.undertow.*`/`org.xnio.*`/JDK classes. `WebSocketConnectionCallback`
  and the receive/close listeners (`org.xnio.ChannelListener`) are real
  Lyric records implementing the real JDK interfaces via `impl
  <ExternInterface> for Record`. `startServer`/`stopServer` start and
  stop a genuine `io.undertow.Undertow` server upgrading a configurable
  path to WebSocket; `send`/`broadcast`/`close` dispatch real frames via
  `io.undertow.websockets.core.WebSockets`'s blocking send methods;
  `connectionCount`/`isConnected` query a real per-registry
  `ConcurrentHashMap<String, WebSocketChannel>`. Documented, non-silent
  gaps: fragmented (multi-frame) messages are drained but not
  reassembled; ping-interval keepalives are not scheduled; text decoding
  is lenient UTF-8 (see #5453 below).
- `lyric-ws/src/ws.l`: added a `kernelXxx` `@cfg(feature =
  "dotnet"/"jvm")`-paired dispatch layer (mirrors `Auth`'s
  `Auth.Kernel.Net`/`Auth.Kernel.Jvm` split) so every existing kernel
  call site now selects the right backend; added new public API
  `startServer`/`startServerWithConfig`/`stopServer` (the library
  previously had no way to actually bind a `WsHandler` to a running
  server on either target). `Ws.Kernel.Net` grew matching
  `startServer`/`stopServer` stubs returning `Err(code =
  "NOT_IMPLEMENTED")` — the real ASP.NET Core WebSocket upgrade path
  stays deferred to #778, now with the same public surface on both
  targets.
- **`impl <ExternInterface> for Record` JVM support** (three
  compiler bugs in `constraintRefToJvmClass`/`holderAwareParamTypes`/
  `lowerImplMethod`) — independently discovered here at essentially the
  same time as `lyric-session`'s Lettuce Redis kernel work
  (D-progress-631) hit the identical class of gap. The version that
  landed is `lyric-session`'s: the same `ClassInfo.isInterface`
  field and `invokeinterface`-vs-`invokevirtual` selection this entry's
  own draft fix also had, plus a superset this entry's narrower fix
  didn't need (recursive superinterface walk, required for Lettuce's
  deeper interface hierarchy but not for Undertow's flatter one).
  Verified against the adopted fix: `ffi_iface_impl_jvm_self_test.l`
  (2/2), `auto_ffi_jvm_self_test.l` (22/22), and `lyric-ws`'s own
  `impl JHttpHandler`-shaped Undertow bindings all compile and dispatch
  correctly on `--target jvm`.
- **Workspace dependencies now inherit the consumer's resolved feature
  set** (`lyric-compiler/lyric/cli/{workspace_builder,cli_build}.l`,
  `cli_workspace_builder_self_test.l`): `{ workspace = true }`
  dependencies always built with their *own* manifest's default
  features, never the consumer's `--features`/`--no-default-features`
  selection — `buildWorkspaceDep`'s recursive `buildProject` call
  hardcoded `newList()` (no CLI features) and `false` (use defaults). A
  `--target jvm --features jvm --no-default-features` consumer build of
  `lyric-ws` therefore built its `Lyric.Auth` workspace dependency with
  `default = ["dotnet"]` active — compiling `Auth`'s `@cfg(feature =
  "dotnet")` branches into JVM bytecode and erasing the `@cfg(feature =
  "jvm")` ones, so `lyric-auth` (a `lyric-ws` dependency) could never
  actually build for JVM. Fixed by threading the consumer's
  already-resolved `activeFeatures` through `resolveManifestDependencies`
  -> `buildWorkspaceDeps` -> `buildWorkspaceDep`, forcing it verbatim
  (`noDefaultFeatures = true`) onto every workspace dependency's build.
  Confirmed both via `lyric-ws --target jvm --features jvm` and a
  minimal two-package isolated repro before landing. General compiler
  fix, not specific to `lyric-ws`/`lyric-auth` — benefits any workspace
  dependency whose behavior varies by feature.
- `cli_test.l`'s Maven-classpath-for-`lyric test` injection (needed to
  actually run the new `Ws.Kernel.Jvm`-exercising test suite on
  `--target jvm`) was independently discovered here too, at essentially
  the same time as `lyric-aws-xray`'s integration (D-progress-632). The
  version that landed is `lyric-aws-xray`'s (already integrated into
  this PR); this entry's own near-identical draft (differing only in
  classpath-vs-jar ordering) was not re-applied.

**Three newly-found, precisely-diagnosed JVM backend gaps, deliberately
NOT fixed here (each general, not `lyric-ws`-specific — filed with full
repros):**

- **#5453** — `Std.Encoding`'s pure-Lyric byte-indexing helpers
  (`tryDecodeUtf8`, `encodeBase64`, `tryDecodeBase64`, `encodeHex`,
  `tryDecodeHex`) fail to compile on `--target jvm` at all: indexing a
  `slice[Byte]` yields the JVM-erased `Object` element type, so a
  subsequent `.toInt()` on the element fails to resolve. Systemic —
  breaks `Std.Encoding` entirely on JVM. Both `lyric-ws` and
  `lyric-auth` (see D-progress-631's `decodeBase64Utf8`-style
  workaround, independently arrived at here too for `Ws.Kernel.Jvm`)
  route around it with direct `java.util.Base64`/`java.lang.String
  (byte[], String)` calls, accepting a lenient-UTF-8 trade-off.
- **#5454** — a `val x: slice[Byte] = <externCall returning byte[]>`
  local declared directly inside a loop body (or, less reliably, in
  some larger straight-line functions) triggers a JVM `VerifyError`
  ("[B is not assignable to [Ljava/lang/Object;") — a stack-map-merge
  conflict between the concrete `[B` an extern call actually returns
  and the generic `Object[]` slice ABI a different code path expects
  for the same declared type. `Ws.Kernel.Jvm`'s own frame-reading
  functions were written defensively (the `slice[Byte]` local lives in
  its own non-looping function) and never hit this;
  `ws_jvm_e2e_test.l`'s `pollForTextFrame` needed the same treatment
  plus inlining the local away entirely to avoid it.
- **#5455** — cross-package `impl` of a *native* (non-extern) Lyric
  interface, where an interface method's reference-typed parameter or
  return is a record/union declared in a *third* package, emits a wrong
  class reference (`NoClassDefFoundError` at runtime). Confirmed
  specific to `impl`-method signatures (`Ws.WsTests`'s ordinary
  cross-package union *matching* works fine on JVM). Needs a
  cross-package type-declaration lookup threaded through the JVM
  codegen's type resolution, comparable in shape to `externTypes` but
  covering every bundled package's own declarations — a real feature,
  not a small fix. `tests/ws_jvm_e2e_test.l` is written, real, and
  documents this fully in its header; deliberately not registered in
  `[project.tests]` until the gap is fixed.

**Verification.** `lyric-ws`'s registered `[project.tests]` suite
(`Ws.WsTests`, `Ws.WsSecurityAspectWeavingTests`) is 12/12 green on
`--target dotnet` (no regression). On `--target jvm --features jvm`
(never previously reachable, since `Ws.Kernel.Jvm` was unregistered from
`ws.l`'s imports): `Ws.WsTests` is 4/6 (the 2 failures are a
pre-existing, separately-tracked nullary-union-case JVM matching gap,
`WsCloseCode.GoingAway`/`ProtocolError`, unrelated to this work and not
investigated further here); `Ws.WsSecurityAspectWeavingTests` is 0/6
(the pre-existing B′-mode aspect-weaver JVM codegen gap already seen in
`lyric-auth`/`lyric-web`/`lyric-feature-flags` this same PR —
`__LyricBModeCallContext` not found at runtime — exercising
`Ws.Aspects`, not `Ws.Kernel.Jvm`; also not investigated further here).
Both are newly-*exposed* by making the JVM feature reachable for the
first time, not regressions introduced by this change.
`ffi_iface_impl_jvm_self_test.l` (the adopted compiler fix's own
regression test) is 2/2 green on `--target jvm`.

**Formatting note:** `lyric-ws/src/ws.l` could not be run through
`lyric fmt --write` — it refuses with "formatting would change the
code-token sequence" for this file's `{ (a: T, b: T) -> ... }`
multi-parameter, block-bodied lambda literals (the language reference's
`LambdaExpr` grammar form; no other `.l` file in the repo uses this
exact shape). Left unformatted per the "never hand-format around a
refusal" policy; the formatter bug itself was not investigated.

**Related:** #5453, #5454, #5455, #5324, D-progress-631 (the JVM
interface-auto-FFI fix adopted here, and `lyric-auth`'s parallel
`Std.Encoding` workaround), D-progress-632 (the `lyric test --target
jvm` Maven-classpath fix adopted here).

---

## D-progress-635 — Fixed a CI-breaking regression in D-progress-634's workspace-feature-inheritance fix; worked around #5443 in `lyric-web` with an alias rename, which exposed a new generic auto-FFI gap (#5458)

**Status:** ACCEPTED (compiler regression fix); #5443 worked around in
`lyric-web` specifically (the general `[project.packages]` compiler bug
is still open); #5458 newly found and filed, not fixed.

**Context.** Integrating D-progress-634's workspace-dependency
feature-inheritance fix into this branch's `lyric-testing` ecosystem
suite broke CI (`ecosystem-security-tests`): `lyric-testing/lyric.toml`
declares no `[features]` table at all (it has none of its own — every
dependency it needs is pulled in as a `{ workspace = true }` dep). D-134's
fix computes the *consumer's* `activeFeatures` and forces it (via
`noDefaultFeatures = true`) onto every workspace dependency's own build,
unconditionally. For a consumer with no `[features]` table and no CLI
`--features` flags, that resolved `activeFeatures` is legitimately empty
— and forcing an empty set onto `Lyric.Storage` (a workspace dep with
`default = ["dotnet"]`, whose `dotnet` kernel is mandatory, not optional)
erased its `@cfg(feature = "dotnet")` kernel branch entirely, leaving
`hostPathGetFullPath`/`hostMd5`/`hostGetFiles`/etc. as `T0020 unknown
name` errors during the CI run building `lyric-testing`.

**Fix.** `lyric-compiler/lyric/cli/workspace_builder.l`'s
`buildWorkspaceDep`: only force `noDefaultFeatures = true` (override the
dependency's own defaults with the consumer's exact resolved set) when
the consumer's `activeFeatures` is non-empty — i.e. the consumer actually
resolved something (its own `[features].default`, or an explicit CLI
`--features`/`--all-features`/`--no-default-features` selection). When
`activeFeatures` is empty, `noDefaultFeatures = false` is passed instead,
so the dependency falls back to its own `[features].default` exactly as
it did before D-progress-634's fix existed. This preserves the original
fix's benefit (a `--target jvm --features jvm --no-default-features`
consumer still forces that selection through to every workspace
dependency) while restoring the pre-fix behavior for consumers that
never expressed a features opinion at all.

**Verification.** `./bin/lyric test --manifest lyric-testing/lyric.toml`
(no CLI feature flags, reproducing the CI invocation exactly): all 5
workspace deps (`Lyric.Cache`, `Lyric.Mail`, `Lyric.Storage`, `Lyric.Mq`,
`Lyric.Session`, `Lyric.Flags`) build clean, `Testing.TestingTests` 37/37
pass (previously: `Lyric.Storage` failed to build with 6 `T0020` errors).
`./bin/lyric test --manifest lyric-session/lyric.toml --features dotnet`
(the D-progress-631 scenario the original fix was needed for) still
passes 4/4 test files, confirming the carve-out doesn't regress the
explicit-selection case. `cli_workspace_builder_self_test.l` 11/11 green
(unchanged — the existing `resolveManifestFeatures` cases already covered
the empty-features-table case at the resolution layer; the gap was
specifically in how `buildWorkspaceDep` propagated that resolved value
downward).

**Separately: #5443 investigated per PR review suggestion, worked around
in `lyric-web`.** #5443 (D-progress-629) is a general
`[project.packages]` multi-file-same-package alias-collision bug — still
open, not fixed here. `lyric-web/src/_kernel/jvm/web_kernel.l`'s
colliding `extern type ConcurrentDict[K, V]` alias (the JVM file's
`java.util.concurrent.ConcurrentHashMap` binding, which the compiler bug
let the sibling `.NET` file's identically-named `ConcurrentDictionary`2`
binding leak over) was renamed to `JvmConcurrentDict[K, V]` — a one-line
rename that sidesteps the collision entirely, since the bug only bites
when both files use the *same* local alias name. Verified: compiling
`lyric-web --target jvm --features jvm --no-default-features` (with
Undertow's JAR supplied via `LYRIC_FFI_JARS`) no longer produces #5443's
"Illegal class name" `VerifyError` — `Web.Kernel.Runtime` now correctly
resolves `JvmConcurrentDict` to the real `ConcurrentHashMap`.

**New bug found while verifying the workaround: #5458.** With the
correct extern type now reachable, JVM auto-FFI resolution advanced
further and hit a different, previously-masked failure: `dict.get(key)`
inside the generic helper `cdTryGetValue[K, V](dict: in
JvmConcurrentDict[K, V], ...)` fails with `no matching instance or
inherited method for 'java.lang.Object.get(Ljava/lang/String;)'` — the
receiver erases to `java.lang.Object` instead of the real extern type
when the call site is inside a still-generic function body operating on
a generic extern type. This is a new instance of the erased-generic
bug family (#5439, #5442, #5444, #5451, #5456), specifically the first
one inside a generic function over a generic *extern* type rather than a
stdlib collection or a union/interface value. Filed as #5458 with a
minimal repro; not fixed here. `lyric-web`'s `Web.RateLimitTests` still
does not compile on `--target jvm` because of it — `docs/44` m-90 and
`lyric-web/README.md`'s Known gaps section updated to describe the
current, more precise state (#5443 worked around, #5444 and #5458 still
open).

**Related:** #5443, #5444, #5458, D-progress-629, D-progress-631,
D-progress-634 (the fix being corrected here).

---

## D125 — Decommission Legacy F# Bootstrap & Fix JVM dblToSingle Crash

**Date:** 2026-07-08
**Status:** ACCEPTED

**Context & Problem.** The legacy F# bootstrapping mechanism (`mint-stage0-fsharp.sh`), the F# reference rewriter (`rewrite-corelib-refs.fsx`), and related Makefile targets (`make mint`) add significant maintenance burden and run-time complexity to the toolchain. However, previous attempts to completely decommission the F# bootstrap (e.g. in PR #5090) were reverted because the `compiler-self-tests-jvm` suite crashed during build with a runtime `MissingMethodException`/`ClassNotFoundException` when utilizing the precompiled v0.4.14 self-hosted seed. The crash specifically arose when calling single-precision float conversion helpers (like `dblToSingle`), which are compiled to use the CLR's `System.Single` type.

**Decision.**
1. **Complete Decommissioning**: We delete the F# bootstrapping scripts (`mint-stage0-fsharp.sh`, `rewrite-corelib-refs.fsx`) and retired build commands (`make mint`), shifting the stage-0 bootstrap permanently to use downloaded self-hosted seed release binaries.
2. **Metadata Signature Mapping Fix**: Inside `argTyToSig` (`lyric-compiler/msil/codegen.l`), we map the FQN `"System.Single"` to primitive code `0x0C` (ELEMENT_TYPE_R4, corresponding to standard single-precision float) instead of a named value type reference. Under the previous behavior, passing a `System.Single` value compiled with a class-based reference signature (`valuetype [System.Runtime]System.Single`) rather than the primitive `float32` signature type expected by the BCL's `System.Convert.ToSingle` or `System.BitConverter.SingleToInt32Bits`, triggering loader validation failures and JVM self-test crashes at runtime.
3. **Unified Kernel Wrappers**: We restore explicit `@externTarget` FFI wrappers for `dblToSingle` and `singleToInt32Bits` inside `_kernel/kernel.l` for both JVM and MSIL targets to keep their signatures identical and clean, avoiding any seed compiler FFI auto-resolution crashes. (The JVM kernel's related `doubleToInt64Bits` wrapper additionally carries `@externStatic`.)
4. **Tooling and Docs Alignment**: We update `scripts/selfhost-check.sh` and `Makefile` comments to retire references to `make mint`, replacing them with `make lyric` / `make stage1`. We fully update the bootstrap progress log (`docs/10-bootstrap-progress.md`) to reflect the unified, self-hosted 2-compiler bootstrap model.

**Verification.** Running `make stage1`, `make stage2`, and `make stage3` successfully passes all JVM self-tests (`compiler-self-tests-jvm`), IL verification (`make ilverify`), and standard library HTTP test suites, while successfully achieving byte-for-byte reproducibility at Stage 3.

---

## D126 — D125's `System.Single` fix was incomplete (`@externTarget` signature encoding); `compiler-self-tests-jvm` now tests stage-2

**Date:** 2026-07-08
**Status:** ACCEPTED

**Context & Problem.** D125's `argTyToSig` fix (`lyric-compiler/msil/codegen.l`) maps `System.Single` to the primitive `ELEMENT_TYPE_R4` signature byte, but `argTyToSig` is used only by the auto-FFI metadata-resolution path. Explicit `@externTarget` bindings — the form `Jvm.Kernel.Program.dblToSingle` itself uses (`@externTarget("System.Convert.ToSingle")`) — build their MemberRef signature through a separate function, `bufFfiType`/`bufMsilType` (`lyric-compiler/msil/lowering.l`), whose `MValueTypeRef` case unconditionally emitted `ELEMENT_TYPE_VALUETYPE` + a TypeRef token with no `System.Single` special case. Both `Jvm.Kernel.Program.dblToSingle`'s own declared return type (`Single`) and `Msil.Kernel.Program.dblToSingle`'s (the MSIL-target twin) went through this unpatched path, so the exact `MissingMethodException: System.Single System.Convert.ToSingle(Double)` crash D125 was meant to fix still occurred — surfacing as 5 failing `compiler-self-tests-jvm` steps (Pattern-lowering, Silent-miscompile-guard, J3-lowering, NaN-comparison self-tests, and the lyric-resilience suite) the first time that CI job actually ran to completion on this PR (prior pushes never got that far because an earlier, unrelated `build` job failure short-circuited it).

**Compounding bootstrap-sequencing issue.** `dblToSingle` lives inside the self-hosted compiler's own source (`lyric-compiler/jvm/_kernel/kernel.l` and the MSIL twin), so a fix to the *encoding logic* (`bufMsilType`) only changes `dblToSingle`'s own compiled behavior once a compiler that already has the fix recompiles it. `compiler-self-tests-jvm` (and every other `compiler-self-tests-*` job) builds and tests against **stage-1**, which is compiled by the *externally published* stage-0 seed release (predates this fix by definition) — so the source fix alone cannot turn that stage-1-based CI job green; it only takes effect starting at **stage-2** (the self-hosted rebuild, where the now-fixed stage-1 compiles `dblToSingle` itself). Verified empirically: rebuilding stage-1 fresh (stage-0 = published v0.4.19) with the `bufMsilType` fix applied still crashes identically; rebuilding stage-2 from that stage-1 passes all 5 previously-failing suites cleanly (52 individual test cases total).

**Decision.**
1. **Fix `bufMsilType`'s `MValueTypeRef` case** (`lyric-compiler/msil/lowering.l`) to special-case `clrFqn == "System.Single"` the same way D125's `argTyToSig` does — emit primitive `ELEMENT_TYPE_R4` (`0x0C`) instead of a named valuetype reference. This is the actual root-cause fix; `argTyToSig`'s special case remains necessary too (it covers the auto-FFI path) but was insufficient alone.
2. **Add a `build-stage2` CI job** (`.github/workflows/ci.yml`) that runs `bootstrap.sh --stage 2` independently in parallel with the other test jobs and uploads `.bootstrap/stage2` as an artifact. Repoint the 5 affected `compiler-self-tests-jvm` steps (and only those — the ~40 other steps in that job keep using stage-1, unaffected and unnecessary to change) at the stage-2 binary (`.bootstrap/stage2/bin/lyric`, `LYRIC_STDLIB_BIN=.bootstrap/stage2/lib`) instead of stage-1. `build-and-test`'s aggregate gate now also depends on `build-stage2`.
3. **Scope note**: this does not change what any *other* `compiler-self-tests-*` job tests, and does not attempt to make stage-1 itself pass (that would require cutting a new stage-0 seed release with this fix baked in — a maintainer release action, out of scope here). A future stage-0 seed release built from a commit at or after this one will make stage-1 pass these tests too, at which point the `build-stage2`/stage-2-rerouting machinery could be simplified away if desired, but is not required to be.

**Verification.** `msil_project_bridge_self_test.l` (`--target dotnet`, 31 cases) confirmed no MSIL-target regression from the `bufMsilType` change. All 5 previously-failing JVM suites pass against a freshly-built stage-2 (52 cases total). `examples/rest_service.l` (the earlier `http_server.l` CI-failure fix) re-verified working end-to-end after the rebuild.

---

## D-progress-636 — MSIL auto-FFI: `resolvedSigToMsil` had no case for array-shaped (`STSzArray`) signatures, so any BCL instance method returning/taking an array (e.g. `Encoding.GetBytes(string): byte[]`) could not be metadata-resolved, silently reopening the exact static-vs-instance mis-emission #3887 claimed to close

**Status:** ACCEPTED

**Symptom.** Reported downstream as a runtime crash attributed to (already-closed)
issue #3887: `System.MissingMethodException: Method not found: 'Byte[]
System.Text.Encoding.GetBytes(System.Text.Encoding, System.String)'` — an
`@externTarget("System.Text.Encoding.GetBytes")` wrapper with no explicit
`@externInstance`/`@externStatic` hint was emitted as a **static** call with
the receiver smuggled in as an extra leading parameter, instead of the real
instance call `Encoding.GetBytes(String)`. Re-investigating #3887 itself
found both of its tracked items genuinely fixed (verified via a from-source
mint + self-hosted stage-1/stage-2 bootstrap, including a targeted
`parseModel`-shaped repro through the real `ilc` Native AOT path — no
reproduction), so this was new information, not a regression of #3887's fix.

**Root cause.** `resolvedSigToMsil` (`lyric-compiler/msil/codegen.l`) converts
a metadata-decoded `Mdr.SigType` to the `MsilType` the emitter needs to encode
a real MemberRef signature. It has explicit cases for by-ref, closed generic
instantiations, primitives, and named class/value types — but none for
`STSzArray` (a single-dimension array, e.g. `byte[]`), so it silently
returned `None` for any array-shaped parameter or return type. Its sibling
`genericMemberSigToMsil` (used for generic-type members) already had the
equivalent `STSzArray -> MArray` case; `resolvedSigToMsil` was simply missing
it. Two independent call sites depend on this conversion succeeding:
- `emitResolvedInstanceAutoFfi` (pure auto-FFI instance-method-call syntax,
  `expr.Method(args)` with no `@externTarget` wrapper) returns `None` when the
  return type can't convert, which its caller treats identically to "no
  matching overload" — falling back to the "unresolved extern instance
  method" runtime-throw stub (a safe failure, but still fatal, and NOT the
  user's crash).
- `emitExternTargetBody`'s metadata-scored resolution (docs/42, the #3887
  fix): when `resolvedSigToMsil(cctx, msig.returnType)` returns `None`, the
  `case None -> ()` arm does nothing at all — critically, it never reaches
  `emitIsStatic = not msig.hasThis`, the exact correction #3887 added. For a
  wrapper with no explicit `@externInstance` hint, `emitIsStatic` therefore
  stays at `resolveExternTarget`'s default (`RHEither -> true`, static) —
  producing the wrong static-with-receiver-as-param0 MemberRef and a genuine
  `MissingMethodException` at runtime. This is why the bug surfaces
  differently depending on whether a hint is present: an explicit
  `@externInstance` hint (matching every current in-repo caller, e.g.
  `lyric-stdlib/std/_kernel/encoding_host.l`, `lyric-web/src/web.l`) masks it
  — `emitIsStatic` is already correct before metadata resolution even runs,
  so the silent `None` fallback to the Lyric-declared param/return types
  (which the wrapper always has) produces a working, if metadata-resolution-
  bypassing, build. Only a hint-less wrapper, or the pure-auto-FFI call-site
  path (which has no Lyric-declared fallback at all), actually crashes.

**Fix.** Added an `STSzArray` case to `resolvedSigToMsil`, using the existing
cross-package accessor `Mdr.sigSzArrayElem` (already present, unused by this
function — added for D105's interface-conformance work) and recursing on the
element type, mirroring `genericMemberSigToMsil`'s identical case:
`Mdr.sigSzArrayElem(sig) -> Some(elem) -> MArray(elemTy = resolvedSigToMsil(elem))`.
`MArray` is already the confirmed lowered static type of `slice[T]`
(`TSlice(elem) -> MArray(elemTy = ...)`), so this is consistent with every
other array-consuming code path in the emitter.

**Verification.** Built the self-hosted compiler from source (mint
stage-0 from F# history, per `scripts/mint-stage0-fsharp.sh`, then stage 1)
with the fix. Negative control: reverted the fix (`git stash`), rebuilt, and
reproduced the reported crash **verbatim** — byte-for-byte the same
`MissingMethodException` message — with an `@externTarget("...GetBytes")`
wrapper carrying no `@externInstance` hint. Re-applied the fix, rebuilt,
confirmed: (a) the exact same no-hint wrapper now resolves and runs
correctly, (b) raw auto-FFI instance-call syntax (`enc.GetBytes(s)`, no
wrapper at all) now resolves instead of throwing the runtime stub, (c) the
existing hint-bearing wrapper pattern (matching `encoding_host.l`/`web.l`)
still works standalone and cross-package (a restored path dependency),
with no change in behavior. Ran the existing `auto_ffi_self_test.l` suite
(14/14 pass, no regressions) and extended it with a new test, "auto-FFI
resolves an instance method with an array-typed return", covering both the
raw-auto-FFI and hint-less-wrapper shapes (15/15 pass with the fix).

**Related:** #3887 (the metadata-direct resolution this gap was hiding
inside), docs/42 (extern metadata resolution design), #3943 (the by-ref
and value-type-receiver fixes to this same function), #4025 (the closed
generic-instantiation fix to this same function).

---
## Decisions deferred to v2 or later


- Package generics (Ada-style module-level parameterization)
- JVM backend
- Self-hosting
- Annex-style certifiable conformance
- Effect system (currently only `async` is effectful)
- Hot reload
- REPL

These are noted in `04-out-of-scope.md` with full rationale.
