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
| **F: Kernel cap** | 150 extern declarations as a v1.0 release gate. |
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
- **Audit cost is finite.** A hard cap of 150 extern declarations
  (Decision F) keeps the trusted boundary tractable.
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

**Revisions:** None.

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
- **Stable (`since="1.0"`):** `Std.Errors`, `Std.Parse`, `Std.Testing` (assertEqual/assertEqualInt/assertTrue), `Std.Collections`, `Std.String`, `Std.Console`, `Std.File`, `Std.Iter`, `Std.Math`, `Std.Stream`, `Std.Log`, `Std.Path`, `Std.Environment`, `Std.App`, `Std.Directory`, `Std.Json`, core HTTP types and methods, core time operations.

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

## D044: Self-hosted MSIL PE emitter — Stage M1 approach

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
  user-facing equivalent: book chapter 19 §19.7.1.

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
- **Per-target opt-out via `@no_aspect` / `@no_aspect(X)`.**
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

  - **Q-aspectlib-001** — Library ABI: hybrid B + C.
    Default is generic-monomorphised IL distribution; opt
    individual aspects into source-template via
    `@inline_template`.  Typed-erased delegate (option A)
    rejected.  Spec: `docs/27-aspect-libraries.md` §6.

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

## D050 — Aspect templates (`pub aspect_template`)

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

## Decisions deferred to v2 or later

- Package generics (Ada-style module-level parameterization)
- JVM backend
- Self-hosting
- Annex-style certifiable conformance
- Effect system (currently only `async` is effectful)
- Hot reload
- REPL

These are noted in `04-out-of-scope.md` with full rationale.
