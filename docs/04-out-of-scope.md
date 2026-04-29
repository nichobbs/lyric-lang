# 04 — Out of Scope

This document lists features and capabilities deliberately excluded from Lyric, with rationale. Some are deferred to future versions; some are permanently rejected.

The "what we don't do" list is as load-bearing as the "what we do" list. New proposals to add anything in this document should explicitly address the rationale here.

---

## Permanently rejected

### Class inheritance

**Status:** REJECTED

Polymorphism is via interfaces and sum types only. There is no class hierarchy, no `extends`, no virtual methods on records.

**Why:** Class inheritance is widely recognized as overused. Composition + interfaces + sum types covers the use cases without the fragility of inheritance hierarchies. Sum types model "data that can be one of several things" correctly; class hierarchies model it incorrectly (open extension when closed semantics were wanted, semantic coupling between parent and child).

### Reflection

**Status:** REJECTED

Lyric programs cannot inspect types at runtime. There is no equivalent of `typeof(T).GetFields()`, `getClass()`, or `instanceof` outside of the pattern-matching context.

**Why:** Reflection is what makes opaque types' representational privacy meaningless. It's also what blocks AOT compilation and forces runtime DI containers. Source generators (`@derive`) cover the legitimate use cases that reflection used to handle.

### Implicit numeric conversion

**Status:** REJECTED

`Int` does not silently widen to `Long`. `Long` does not silently truncate to `Int`. `Double` does not silently absorb integers. Conversion is always explicit.

**Why:** The C family's implicit numeric conversion is the source of the Ariane 5 disaster, integer overflow CVEs, and a thousand subtle off-by-one bugs. Modern languages (Rust, Swift, Kotlin's strict mode) have moved away from it. We follow them.

### Null as a universal value

**Status:** REJECTED

Types are non-nullable by default. Nullable types use the explicit `T?` syntax. Opaque types are never nullable; their nullable-ness must be expressed at use sites.

**Why:** Null-as-billion-dollar-mistake. The cost of explicit nullability is small; the safety benefit is large. Modern consensus.

### Dynamic typing escape hatches

**Status:** REJECTED

There is no `Any`, no `dynamic`, no `object`-as-universal-base. Generic code uses parameterized types; ad-hoc polymorphism uses interfaces.

**Why:** Dynamic types are anti-features in a statically-typed language. Their existence encourages bypassing the type system. Languages that ship them (TypeScript's `any`, C#'s `dynamic`) regret it.

### Ternary operator

**Status:** REJECTED

`a ? b : c` does not exist. Use `if a then b else c`.

**Why:** `if` is an expression in Lyric. The ternary is redundant. Eliminating it removes an operator-precedence wrinkle and makes conditionals uniformly readable.

### C-style include / textual import

**Status:** REJECTED

There is no preprocessor, no `#include`, no textual code expansion. Imports are module-level, named, and explicit.

**Why:** Every modern language has rejected this. C++ modules' decade-long migration is the cautionary tale.

### Macros (textual or token-based)

**Status:** REJECTED for v1; possibly revisit for v2

There is no Rust-style `macro_rules!`, no Lisp-style macros, no C++-style templates beyond the language's built-in generics.

**Why:** Macros are powerful but they degrade tooling (LSP support is harder), make code less readable to outsiders, and create a parallel language that learners must also master. Lyric's `@derive` system handles the common case (generating boilerplate from type structure) without exposing a macro language.

### Operator overloading

**Status:** REJECTED for arbitrary operators; LIMITED for arithmetic on numeric distinct types

Users cannot define custom operators. Numeric distinct types may *derive* `Add`/`Sub`/`Mul`/`Div`/`Mod` via the `derives` clause; this is the only operator-overloading mechanism.

**Why:** Arbitrary operator overloading is a footgun. Users define `<<` for "stream insertion" or `+` for "string concatenation in custom DSL" and readability suffers. The constrained derive mechanism handles the genuine use case (treating `Cents + Cents` as `Cents`) without opening the floodgates.

### Implicit conversions / coercions

**Status:** REJECTED

There are no user-defined implicit conversions. The C# `implicit operator`, Scala implicits, Kotlin's `Number` hierarchy — none of these exist in Lyric.

**Why:** Implicit conversions hide control flow and confuse the type checker. Where conversion is needed, an explicit method (`.toFoo()`) makes it visible.

### Global mutable state

**Status:** REJECTED

There are no global variables. Module-level `val` declarations are immutable. Module-level `var` is a parser error. Mutable state lives in `protected type` declarations or behind DI.

**Why:** Global mutable state is the original sin of concurrency bugs. Removing it removes a whole category of problems.

### Goto

**Status:** REJECTED

There is no `goto`. Loops have labels for `break`/`continue` only.

**Why:** Standard rejection. Goto's last legitimate use case (state machines) is better served by sum types and pattern matching.

### Exceptions for control flow

**Status:** REJECTED (as a design pattern; the mechanism exists for `Bug` propagation)

Exceptions are not the primary error-handling mechanism. They exist only for `Bug` propagation (precondition violations, contract failures, unwrap on Err). Recoverable errors use `Result[T, E]`.

**Why:** Exception-based control flow obscures what can fail. `Result` makes failure visible in the type, which is what we want for recoverable errors.

---

## Deferred to v2 or later

### Package generics (Ada-style module-level parameterization)

**Status:** DEFERRED to v2

Trait/interface-based generics ship in v1. Package generics (parameterizing whole modules over types, values, and other modules) are deferred.

**Why:** Trait-style generics cover the 90% case familiar to TS/Java/Kotlin/Swift/Rust developers. Package generics are powerful but unfamiliar; they earn their keep in domains (large stateful subsystems, cross-cutting type families) that are rare in application code. Ship the common case first; revisit if real users hit the limits.

### JVM backend

**Status:** DEFERRED to post-v1

Lyric v1 targets .NET only.

**Why:** Building two backends in parallel risks shipping neither. JVM's erased generics and reflection-heavy ecosystem make it a worse fit; the AOT-compatible-library migration on JVM is less complete than on .NET. After v1 ships and stabilizes, evaluate JVM based on user demand.

### Self-hosted compiler

**Status:** DEFERRED to Phase 5 (post-v1)

The compiler is implemented in F# until the language is stable.

**Why:** Self-hosting too early forces every language change to be made twice. Wait until the language stabilizes; then port.

### Effect system

**Status:** DEFERRED indefinitely

Lyric tracks `async` as an effect (functions are or are not async). It does not track `raises`, `io`, `mut`, or other effects in the type system.

**Why:** Effect systems (OCaml 5, Koka) are powerful but cost a whole extra type-system axis. The cognitive load is high; the practical value is unproven outside research languages. Revisit when the field has matured.

### Annex-style certifiable conformance

**Status:** DEFERRED to v2 or later

There is no formal Lyric Conformity Assessment Test Suite, no certified compiler conformance program.

**Why:** This is meaningful only with industrial users in safety-critical domains. We're not there yet. Once we are, the model is well-established (Ada has it, C/C++ effectively have it via compiler validation suites).

### Hot reload

**Status:** DEFERRED indefinitely

Lyric programs are AOT-friendly and do not support hot code replacement during execution.

**Why:** Hot reload is incompatible with several of Lyric's design choices (compile-time DI, monomorphized generics, sealed metadata). Reload via process restart is the substitute.

### REPL

**Status:** DEFERRED to v2

There is no `lyric repl` command in v1.

**Why:** A REPL is real work to build well, and it's an awkward fit for a language with mandatory module structure, mandatory parameter modes, and compile-time DI. The cost-benefit isn't there for v1.

### Coroutines beyond async/await

**Status:** DEFERRED indefinitely

There are no Kotlin-style suspend functions beyond `async`/`await`, no Python-style generators, no full coroutine library.

**Why:** `async`/`await` covers the typical use case. Generators can be expressed via interfaces and pattern matching. Adding more concurrency primitives would expand the surface area for marginal benefit.

### Persistent / immutable data structures in the standard library

**Status:** PARTIAL in v1, EXPANSION DEFERRED

`std.collections` ships immutable variants of `Map`, `Set`, `List`. More sophisticated persistent structures (HAMTs, finger trees, persistent vectors) are deferred to v2.

**Why:** The basic immutable collections cover most application code. Persistent variants are a real engineering effort (correct, fast, well-tested implementations).

### Inline assembly / hardware intrinsics

**Status:** REJECTED (we are not a systems language)

There is no inline assembly, no SIMD intrinsics exposed at the language level, no hardware-specific code paths.

**Why:** Lyric is not a systems language. Performance-critical code that needs SIMD calls into native code via FFI; intrinsic-level access is out of scope.

### Compile-time evaluation beyond constants

**Status:** LIMITED in v1

The compiler evaluates `const` expressions and resolves wire blocks at compile time. There is no general compile-time function execution (`constexpr`/`comptime`).

**Why:** General compile-time evaluation is a significant complexity cost. Specific use cases (DI resolution) are handled by purpose-built mechanisms. Revisit if patterns emerge.

### User-defined attributes (annotations)

**Status:** DEFERRED to v2

The annotation set in v1 is the language's built-in annotations (`@projectable`, `@stubbable`, `@derive`, `@runtime_checked`, etc.). Users cannot define new attributes.

**Why:** Without reflection, user-defined attributes have nothing to act on at runtime. Defining them at compile time requires a macro/source-generator system. Defer until a clear use case emerges.

---

## Notably *included* despite seeming controversial

These are choices that some might argue should be in the "out of scope" list but explicitly aren't:

### Mandatory parameter modes (`in`/`out`/`inout`)

This is friction that some will hate. We include it because the contract value outweighs the syntax cost. See D004.

### Compile-time DI as a language feature

Some will argue DI should be a library, not a language feature. We disagree — see D008. The benefits (compile-time resolution, lifetime checking, zero runtime cost) require language integration.

### `protected type` keyword

This is unfamiliar to most developers; some would prefer leaving it as a library type. We include it because mutual exclusion needs to be structural, not advisory. See D009.

### Two visibility tiers (`opaque`/`exposed`)

Adds a concept that doesn't exist in most languages. We include it because the alternative (purely opaque or purely exposed) doesn't work. See D003.

### No exceptions for recoverable errors

Java/C#/Python developers will find `Result[T, E]` everywhere verbose. We include it because the alternative (declared `raises:` or unchecked exceptions) is worse. See D007.

---

## How to propose changes to this document

If you believe something here should move (rejected → deferred, deferred → included, included → out of scope), open a design proposal that:

1. References the relevant decision-log entry
2. Explains what changed since the original decision
3. Estimates implementation cost
4. Identifies who benefits and who pays the cost

Decisions can be revisited; they should not be revisited casually.
