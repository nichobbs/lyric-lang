# 06 — Open Questions

This document collects unresolved design questions. Each entry should be resolved during Phase 0 (or explicitly deferred with rationale).

Format:
- **Question**: what's unresolved
- **Context**: why this matters
- **Options**: candidate resolutions
- **Constraints**: things any answer must satisfy
- **Recommendation**: a tentative direction (may be revised by Phase 0 review)

---

## Q001: Record vs class lowering on .NET

**Status:** RESOLVED — see `docs/09-msil-emission.md` §5 (16-byte heuristic with `@valueType`/`@referenceType` overrides).

**Question:** When does Lyric lower a record to .NET `readonly struct` vs `record class`?

**Context:** Small records benefit from value-type semantics (no allocation, copy on assignment). Large records benefit from reference semantics (cheaper to pass around). Some records contain async-unsafe state and should always be reference types.

**Options:**
1. Always `record class`. Simple. Loses value-type performance for small records.
2. Always `readonly struct`. Wins on small records; bad on large ones (excessive copying).
3. Heuristic based on size (e.g., ≤ 16 bytes → struct, else class).
4. Annotation-based (`@valueType` / `@referenceType` on the record).

**Constraints:**
- Must be consistent within a program (the same record can't be struct in some places and class in others).
- AOT compilation must work without runtime configuration.
- Generic monomorphization needs to be consistent.

**Recommendation:** Heuristic with annotation override. Default to struct for records with ≤ 16 bytes of fields, class for larger; allow `@valueType` and `@referenceType` annotations to force either. Document the threshold in the language reference. Accept that some users will need to annotate to get the behavior they want.

---

## Q002: Sealing opaque types against .NET reflection

**Status:** RESOLVED — see `docs/09-msil-emission.md` §7.2 (mangled field names + `[Lyric.Opaque]` + AOT trim + analyzer).

**Question:** What concrete .NET mechanism prevents reflection from inspecting opaque types' fields?

**Context:** `Type.GetFields()`, `Type.GetMembers()`, `Type.GetMembersWithSpecificFlags()` all expose private fields by default. Even with `BindingFlags.NonPublic`, reflection can read private fields. We need to ensure opaque types' fields cannot be enumerated by reflection.

**Options:**
1. Compile fields as locals inside a closure-style closure object that has no public surface. Heavy on allocation.
2. Use `[CompilerGenerated]` attributes that AOT respects but JIT may not honor.
3. Mark opaque type members with custom attributes and use Native AOT trim warnings to flag reflection attempts. Doesn't fully prevent attacks but catches accidents.
4. Emit fields as `internal` to a separate AOT-trimmed assembly. The opaque type's "real" implementation lives in an assembly that user code can't reference.
5. Use `RuntimeHelpers.PrepareConstrainedRegions` or other mechanisms. Probably misuse of those APIs.
6. Accept that determined attackers can break opacity; the goal is to make accidental breakage impossible.

**Constraints:**
- Native AOT compatibility required.
- Performance penalty must be acceptable (no allocation per opaque type instance).
- Must work in JIT mode too (development builds).

**Recommendation:** Combination approach. (a) Lyric emits opaque type fields with names that are syntactically illegal in C# (e.g., `<lyric>$balance`). (b) The fields are marked with custom attributes that LSP/IDE tools respect to hide them. (c) Native AOT mode trims reflection metadata for these types, making reflection access impossible at runtime. (d) Document the JIT-mode caveat: malicious code with reflection can break opacity in JIT; AOT mode is required for full guarantee.

This isn't perfect but it's the best `.NET` lets us do without a runtime modification.

---

## Q003: Projection cycle handling

**Status:** RESOLVED — see decision log D026.

**Question:** What is the syntax for breaking projection cycles?

**Context:** If `User` is `@projectable` and contains a `Team` field, and `Team` is `@projectable` and contains a `members: slice[User]` field, the projection graph cycles. The auto-generated views would recurse infinitely.

**Options:**
1. Detect cycles and reject at compile time; force user to manually break them.
2. Default to a "shallow projection": cycles are broken by emitting opaque handles for the cyclic field.
3. Annotation `@projectionBoundary` on a field, breaks the cycle by emitting an ID reference instead of the full projection.
4. Generate two views: full (one level deep) and reference (just IDs).

**Constraints:**
- Must produce a serializable graph (JSON, SQL).
- Must not surprise users who add a cyclic relationship later.

**Recommendation:** Option 3 with mandatory annotation. When the compiler detects a cycle in `@projectable` types, it requires the user to mark one side with `@projectionBoundary(asId)` or similar. The compiler emits an error pointing at the cycle, identifying both sides, and asking the user to choose. Better to make this explicit than silently produce a different graph than the user expected.

---

## Q004: Generic constraint markers

**Status:** RESOLVED — see decision log D034.

**Question:** What is the exhaustive list of built-in constraint markers for generics?

**Context:** `where T: Comparable + Default` style constraints. We need to define what built-in markers exist and what they mean.

**Options:**
- Minimal set: `Equals`, `Compare`, `Hash`, `Default`, `Copyable`, `Send` (for thread safety)
- Larger set including `Numeric`, `Add`, `Sub`, `Mul`, `Div`, `Iterable`, etc.
- All constraints are user-defined interfaces; no built-ins beyond what fundamental.

**Constraints:**
- Must align with `derives` clauses on distinct types (so a `T derives Add` distinct type satisfies `where T: Add`).
- Must be implementable with monomorphized generics.
- Must not require runtime dispatch.

**Recommendation:** Two-tier approach. Built-in markers are: `Equals`, `Compare`, `Hash`, `Default`, `Copyable`, `Send`, `Add`, `Sub`, `Mul`, `Div`, `Mod`. These are markers that map to specific lowering patterns (operator overloading for arithmetic, structural equality for `Equals`, etc.). User-defined interfaces work as constraints too, but bringing the cost of indirect dispatch unless the implementation is monomorphizable. Document the performance distinction.

---

## Q005: Async with non-record `inout` parameters

**Status:** RESOLVED — see `docs/09-msil-emission.md` §11.4 (use-after-await analyser rejects; pre-await use is fine).

**Question:** What happens when an `async` function has an `out` or `inout` parameter whose type is a value type, and the function awaits?

**Context:** `async` functions on .NET become state machines. `out`/`inout` parameters are by-reference. Holding a reference across an await point is unsafe in general (the referent could be on a stack frame that's gone by the time the await resumes).

**Options:**
1. Disallow `out`/`inout` on async functions entirely. Forces `Result`-based output.
2. Disallow only across awaits (analyze whether the parameter is used after any await). Allows simple cases.
3. Promote `out`/`inout` parameters to heap-allocated boxes for async. Works always, has runtime cost.
4. Restrict to reference-type parameters only.

**Constraints:**
- Must be safe (no use-after-free or torn writes).
- Should not force programmers into awkward patterns.

**Recommendation:** Option 2 with diagnostic. The compiler analyzes async functions; if an `out` or `inout` parameter is used after any await point, emit a compile error suggesting the function return a `Result` instead. Pre-await use is fine. This is restrictive enough to be safe but allows the common patterns where output parameters are populated before any I/O.

---

## Q006: `?` operator in non-error-returning functions

**Status:** RESOLVED — see decision log D027.

**Question:** What does `?` do when used inside a function that doesn't return `Result` or nullable?

**Context:** `?` is the early-return operator. If the enclosing function doesn't return a compatible error type, where does the early return go?

**Options:**
1. Compile error — `?` requires a compatible return type.
2. Implicit panic — `?` on `Err` raises a `Bug`.
3. Implicit unwrap — `?` on `Err` panics; on `Ok`, extracts value.

**Constraints:**
- Must be unambiguous in source.
- Must not silently change error-handling behavior.

**Recommendation:** Option 1. If the enclosing function returns `T`, `?` on a `Result[T, E]` is a compile error. The user must use `match`, `?` with appropriate function signature, or `unwrap()` (which is explicitly panicking). Don't conflate `?` with `unwrap()`.

---

## Q007: `var` capture across async boundaries

**Status:** RESOLVED — see `docs/09-msil-emission.md` §11.5 (snapshot by value; cross-await write requires `protected type` or stdlib `Atomic[T]`).

**Question:** How are mutable local variables (`var`) handled when captured by an `async` closure or spawned task?

**Context:** Capturing `var` by reference across an await point is a race condition; capturing by value loses the mutability semantics the user expected.

**Options:**
1. Reject capturing `var` in async closures entirely.
2. Capture by value (snapshot at closure creation); subsequent mutations don't affect the closure.
3. Capture by reference but emit thread-safety warnings.
4. Require explicit `mut` annotation on captures, with synchronization mechanism.

**Constraints:**
- Must be safe by default (no race conditions in straightforward code).
- Should not require explicit synchronization for the common case (no concurrent access).

**Recommendation:** Option 2 with explicit option. Capturing `var` defaults to by-value snapshot at closure creation. If the user wants by-reference capture, they wrap the value in a `protected type` (or a stdlib `Atomic[T]`) and capture the protected reference, which has its own concurrency contract.

---

## Q008: Concurrent `func` calls on protected types

**Status:** RESOLVED — see `docs/09-msil-emission.md` §17.4 (`ReaderWriterLockSlim` if any `func`, else `SemaphoreSlim`).

**Question:** Can multiple callers invoke `func` (non-mutating) operations on a protected type concurrently?

**Context:** Ada's `protected` distinguishes between `entry`/`procedure` (exclusive) and `function` (concurrent reads). C# `lock` is exclusive only. Reader-writer locks allow concurrent readers but cost more on the implementation side.

**Options:**
1. All operations on a protected type are exclusive (simplest, matches C# `lock`).
2. `func` operations are concurrent (reader-writer lock semantics, matches Ada).
3. Annotation per operation: `concurrent func` opts in.

**Constraints:**
- Must be safe (no torn reads, no race with concurrent writers).
- Implementation cost for the compiler is real but bounded.

**Recommendation:** Option 2. The Ada precedent is solid and the performance benefit is real for read-heavy workloads. Implementation: emit a `ReaderWriterLockSlim` instead of a `SemaphoreSlim` for protected types that have any `func` declarations. Document the cost (slightly slower than exclusive locks) and the benefit (concurrent reads).

---

## Q009: Protected type lowering details

**Status:** RESOLVED — see `docs/09-msil-emission.md` §17.1–17.3 (`SemaphoreSlim` plus condition variables for `when:` barriers).

**Question:** How exactly does `protected type` lower to .NET primitives?

**Context:** Need to settle on the runtime mechanism for mutual exclusion, barrier evaluation, and condition signaling.

**Options:**
1. `SemaphoreSlim` for exclusion + condition variables for barriers. Standard, well-understood.
2. `Channel<T>` from System.Threading.Channels — match against barriers via message passing.
3. Custom runtime types optimized for the protected-type pattern.

**Constraints:**
- Performance must be acceptable for high-contention scenarios.
- Must integrate with .NET cancellation.
- Must support both sync and async callers.

**Recommendation:** Option 1 in v1. `SemaphoreSlim` is well-tested and supports async natively. Barrier evaluation: re-check after every entry/func completes, with waiting tasks queued by registration order. Custom optimizations come later if profiling shows they're needed.

---

## Q010: Task vs ValueTask selection

**Status:** RESOLVED — see `docs/09-msil-emission.md` §14.2 (default `Task<T>`; `@hot` opts into `ValueTask<T>`).

**Question:** When does an `async` function compile to `Task<T>` vs `ValueTask<T>`?

**Context:** `ValueTask<T>` avoids allocation in the common synchronous-completion case. `Task<T>` is more general and supports continuations naturally.

**Options:**
1. Always `Task<T>`. Simpler, slower in hot paths.
2. Always `ValueTask<T>`. Avoids allocation but has subtle correctness issues if awaited multiple times.
3. Heuristic: ValueTask for short, simple functions; Task for everything else.
4. Annotation-based opt-in to ValueTask.

**Constraints:**
- Must not introduce subtle bugs (awaiting a ValueTask twice is undefined behavior).
- Performance should be competitive with hand-tuned C# async.

**Recommendation:** Option 4 with default to `Task<T>`. The compiler defaults to `Task<T>` for safety. Functions annotated `@hot` (or whatever final naming) compile to `ValueTask<T>` and the compiler emits diagnostics if the awaited result is used in patterns that would re-await. This avoids the foot-gun while making the optimization available.

---

## Q011: Standard library API surface

**Status:** DEFERRED — Phase 3 work; not gating Phase 0.

**Question:** What is the v1.0 standard library API surface, and what stability guarantees apply?

**Context:** The standard library is the user's first impression of the language. Too small and users complain about reaching for FFI; too large and we commit to maintaining things forever.

**Constraints:**
- Must cover the common needs of REST API services.
- Must be implementable without language features beyond what v1 ships.
- Must be SemVer-stable from v1.0.

**Recommendation:** Phase 3 work. Define a "minimum viable stdlib" closer to ship: collections, IO, time, networking, JSON, HTTP, testing. Keep modules small and focused. Mark anything experimental clearly.

---

## Q012: Package registry

**Status:** RESOLVED — see decision log D-progress-030 (NuGet
piggyback) and D-progress-031 / D-progress-077 (embedded
`Lyric.Contract` resource + `lyric.toml` manifest + `lyric publish`
/ `lyric restore`).

**Question:** Where do Lyric packages live?

**Options:**
1. NuGet (reuse existing infrastructure, implies .NET-only forever)
2. Custom registry (more flexibility, more infrastructure to maintain)
3. Git-based (no central registry; dependencies are git URLs)
4. Multiple, with NuGet as the default

**Constraints:**
- Must support SemVer resolution.
- Must support private registries for enterprise users.
- Should be simple to mirror or proxy.

**Resolution:** Option 1 (NuGet piggyback) shipped during Tier 3.
The bootstrap takes the "TypeScript on npm" route: every Lyric
package emits a standard `.nupkg` carrying its DLL plus an
embedded `Lyric.Contract` managed resource describing its `pub`
surface.  `lyric.toml` is a thin manifest that the package
manager lowers to a generated `<PackageReference>` `.csproj`;
`lyric publish` runs `dotnet pack`, `lyric restore` runs `dotnet
restore`.  Private feeds, signing, and credential helpers come
free from NuGet's existing infrastructure.  Build-time
consumption of restored Lyric packages — wiring `lyric build`'s
import resolver to read the embedded contract resource from a
NuGet-restored DLL — is the remaining follow-up tracked under
Tier 6 in `docs/12-todo-plan.md`.

---

## Q013: Doctest semantics

**Status:** RESOLVED — see decision log D028.

**Question:** How are code examples in doc comments executed?

**Context:** Rustdoc compiles and runs all code blocks in doc comments by default. This is great for keeping examples accurate but slows compilation.

**Options:**
1. All ` ```lyric ` blocks are doctests, run on `lyric test`.
2. Opt-in via `// doctest` annotation.
3. Opt-out via `// no_test` annotation, default-on.

**Recommendation:** Default-on, opt-out via `// no_test`. Match Rust's pattern. The cost is real but the benefit (examples don't bit-rot) is high.

---

## Q014: Operator overloading via traits/interfaces

**Status:** RESOLVED — see decision log D029.

**Question:** Can users implement `Add`, `Sub`, etc. on their own types, or only `derive` them on numeric distinct types?

**Context:** Lyric explicitly rejects user-defined operators (D019, D-some-number for op overloading). But `derives Add` on a distinct numeric type permits `+` on values of that type. What about user types that aren't numeric distinct types but want `+` for some reason (matrices, vectors, etc.)?

**Options:**
1. Only `derives` on distinct types, no impl-based operator overloading.
2. Allow `impl Add for MyType` to define `+`.
3. Allow it but only for types in the standard library.

**Constraints:**
- Must not become a footgun (custom `+` for "stream insertion" etc.).
- Should support legitimate use cases (vector math, matrix math).

**Recommendation:** Option 2, but the trait-based operator implementations are restricted to numeric semantics. `Add[T] for MyType` requires `MyType + MyType -> MyType` and is documented as having numeric algebra semantics; weird overloading is socially discouraged via convention rather than mechanically prevented.

---

## Q015: Error trait

**Status:** RESOLVED — see decision log D030.

**Question:** Is there a built-in `Error` interface that error types implement?

**Context:** Rust has `std::error::Error`. Provides `.source()`, `.description()`, integrates with `?` and printing.

**Options:**
1. Built-in `Error` interface with a defined contract.
2. Errors are just any type used in `Result[_, E]`; no requirement.
3. Auto-derive `Display`, `Debug` for error types.

**Recommendation:** Option 1 + 3. Define a small `Error` interface in `std.core` (`message(): String`, optional `source(): Error?`). Auto-derive on `union` types used in `Result`. Required to implement on user-defined error types.

---

## Q016: Coercion of non-async to async

**Status:** RESOLVED — see decision log D031.

**Question:** Can a synchronous function be passed where an async function is expected?

**Context:** `interface Repository { async func findById(...): T? }`. Can a synchronous implementation satisfy this? Trivial wrapping (`return Task.fromValue(syncResult)`) works, but it's verbose.

**Options:**
1. Implementations must match exactly: async satisfies async, sync satisfies sync.
2. Sync auto-lifts to async (the compiler wraps the return).
3. Async auto-lowers to sync via `.result` (blocks; unsafe in async context).

**Recommendation:** Option 2. Sync implementations of async-declared interface methods are accepted; the compiler wraps the return value. This is ergonomic and harmless. The reverse (async auto-blocking) is rejected — explicit `.await()` (with potential deadlock) only.

---

## Q017: Newtype derives for non-numeric distinct types

**Status:** RESOLVED — confirmed by language reference §2.3 as written; no design change required.

**Question:** What does `derives Compare, Hash` give a non-numeric distinct type?

**Context:** `type UserId = Long derives Compare, Hash`. The `Compare` and `Hash` derive should give comparison and hashing, not numeric arithmetic.

**Constraints:**
- Must not implicitly enable arithmetic (`UserId + UserId` should fail even if `Long` supports it).
- Must integrate with collections (`Map[UserId, X]` should work).

**Recommendation:** Settled in language reference §2.3 — the derive set explicitly lists what's allowed. `Compare` and `Hash` work for any underlying type that supports them. `Add`, `Sub`, etc. are separate derives. The language reference wording is correct; this Q is about confirming the design holds at implementation time.

---

## Q018: Module docstrings vs item docstrings

**Status:** RESOLVED — see decision log D032.

**Question:** What's the syntax for module-level documentation?

**Context:** Item docs use `///`. Module docs need a different prefix because they precede the package declaration or come before any item.

**Options:**
1. Rust-style `//!` for module docs, `///` for items.
2. `////` for module docs.
3. `@doc("...")` annotation on the package declaration.

**Recommendation:** Option 1. Match Rust's pattern; it's well-established and documentation tooling handles it cleanly.

---

## Q019: Pattern matching on protected types

**Status:** RESOLVED — see `docs/09-msil-emission.md` §17.5 (rejected at type-check; no IL emitted).

**Question:** Can pattern matching access fields inside a protected type?

**Context:** Pattern matching on the *outside* of a protected type (binding it as a name) is fine. But `match queue { case TokenBucket { tokens: t, ... } -> ... }` would access state without going through an entry, breaking mutual exclusion.

**Recommendation:** Reject pattern matching that destructures protected types. Force users to call entries that read state and pattern-match on the result. Document this clearly with examples.

---

## Q020: SMT solver licensing

**Status:** RESOLVED — see decision log D033.

**Question:** Z3 (MIT) or CVC5 (BSD-3)? Both are good; both are free.

**Context:** Phase 4 work, but worth deciding early so users know what they're depending on.

**Considerations:**
- Z3 is more battle-tested. Microsoft Research, well-maintained, used in widely-deployed verification systems (Dafny, F*).
- CVC5 has a more permissive license and slightly better performance on some quantifier-heavy queries.
- Both have .NET bindings of varying quality.
- Either choice can be revisited if problems emerge.

**Recommendation:** Z3 for v2.0 (when the proof system ships). The maturity and Dafny precedent are decisive. Bindings can be improved if needed.

---

## Q021: `where`-clause activation in the bootstrap compiler

**Status:** OPEN — gating the native stdlib (D038, `docs/14-native-stdlib-plan.md` §4.1 G3).

**Question:** What is the concrete plan to lift the Phase 1 deferral of `where` clauses with the D034 marker set, so that native `Std.HashMap[K, V] where K: Hash + Equals`, `Std.Sort[T] where T: Compare`, etc. become expressible in Lyric source?

**Context:**

`docs/05-implementation-plan.md` §"Language subset for Phase 1" explicitly defers generic constraints. D034 fixes the closed marker set (`Equals`, `Compare`, `Hash`, `Default`, `Copyable`, `Add`, `Sub`, `Mul`, `Div`, `Mod`). D038 commits to native stdlib data structures; G3 in `14-native-stdlib-plan.md` §4.1 names this lift as the single largest gating item before P2 of the migration can begin.

**Sub-questions:**

1. **Type checker.** Does the existing `where`-clause parser surface (already accepted in syntax) plumb through to the type checker, or is it a stub that throws on first use?
2. **Marker dispatch lowering.** Per `docs/09-msil-emission.md` §9.4, generic constraints lower to interface dispatch on the marker interfaces. Are those interface types defined yet for the D034 markers?
3. **Built-in primitive coverage.** `Int`, `Long`, `String`, `Double` need to auto-satisfy `Hash`, `Equals`, `Compare`, `Default`. Where in the type checker / stdlib registration should that auto-satisfaction live?
4. **Monomorphisation interaction.** D035 documents per-call-site monomorphisation as the bootstrap strategy. Does monomorphisation of `f[T] where T: Hash` reduce to "find the concrete `T`, look up its `Hash` impl, inline a direct call"? Confirm before implementing.
5. **User-defined interface constraints.** D034 admits user-defined interfaces as `where` constraints. Same path as marker dispatch, or separate?

**Constraints:**

- Must not destabilise existing M1.4 monomorphisation (D035).
- Must produce code that the AOT-first principle (`docs/09-msil-emission.md` §1) accepts.
- Should match the precedence chosen by D034: mark the type checker's slot for new markers as closed; reject `where T: Iterable` (etc.) at parse / resolve time per D034's "closed list" language.

**Recommendation:** Single-PR design proposal under `docs/proposals/q021-where-clauses.md` covering sub-questions 1-5, then implementation. Estimated 3-4 weeks of compiler work (per `14-native-stdlib-plan.md` §4.1). Begin toward end of P0 of the native stdlib migration so it lands before P1 needs it.

**Revisions:** None.

---

## How to resolve these questions

Phase 0 work assigns each question to an owner. Resolution happens in any of:
- A short design document under `docs/proposals/`
- An update to the relevant section of the language reference
- An update to the decision log

Resolved questions move from this document to the decision log. New questions surface during implementation; they go here.
