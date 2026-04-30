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

**Revisions:** None.

---

## D035: M1.4 scope cuts — bootstrap-grade lowering for generics, async, and FFI

**Status:** ACCEPTED

**Decision:** The bootstrap compiler's M1.4 milestone (per
`docs/05-implementation-plan.md`) ships *bootstrap-grade* lowerings for
three constructs that the language reference describes in their full
form. The reduced-fidelity lowerings unblock the banking example and
let the type checker / parser / emitter pipeline verify the broad
shape of v0.1 end-to-end; the full lowerings land in Phase 2 polish.

| Construct | M1.4 lowering | v0.1-target lowering | Where the gap lives |
|---|---|---|---|
| Generics | **Monomorphisation per call site** — the type checker rewrites each generic call into a synthesised concrete instantiation; the emitter sees only monomorphic methods. | Reified generics with `DefineGenericParameters`, JIT specialisation as the strategy doc §9.1 calls for. | `Lyric.Emitter.Codegen.emitCall` has no `ldtoken`/generic-arg handling. |
| `async` / `await` | **Blocking shim** — `async func` lowers to a `Task<T>`-returning method that calls the body synchronously; `await e` calls `e.GetAwaiter().GetResult()`. Sequential under the hood. | A C#-style state machine per the strategy doc §13. | `Lyric.Emitter.Codegen.emitAsyncBody` documents the simplification. |
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
  picks up reified generics and full async state machines.
- Phase 4 work plan picks up `@proof_required` proof-obligation
  generation and `old(_)` snapshotting.
- The Stdlib shim's contents become the seed of `std.core` /
  `std.io` once the package manager lands (Phase 3).

**Revisions:** None.

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

## Decisions deferred to v2 or later

- Package generics (Ada-style module-level parameterization)
- JVM backend
- Self-hosting
- Annex-style certifiable conformance
- Effect system (currently only `async` is effectful)
- Hot reload
- REPL

These are noted in `04-out-of-scope.md` with full rationale.
