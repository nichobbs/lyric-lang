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

**Revisions:** None.

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
   the existing `import extern System.{ IDisposable }` form (D115's `import extern`)
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
interfaces), D106 (constructor shorthand).

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
## Decisions deferred to v2 or later

- Package generics (Ada-style module-level parameterization)
- JVM backend
- Self-hosting
- Annex-style certifiable conformance
- Effect system (currently only `async` is effectful)
- Hot reload
- REPL

These are noted in `04-out-of-scope.md` with full rationale.
