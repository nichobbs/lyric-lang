# 00 — Overview

## What Lyric is

Lyric is a statically-typed, ahead-of-time-compiled application language targeting the .NET runtime. It synthesizes ideas from Ada (range subtypes, package contracts, representational privacy, protected types, design-by-contract), Rust (sum types, exhaustive matching, monomorphized generics, `Result`-based error handling), Kotlin/Swift (modern surface syntax, async/await, expression-oriented blocks), and SPARK (optional SMT-solver-backed verification per module).

The thesis: many of the safety properties modern languages keep rediscovering — distinct types for distinct domains, opaque types whose representation is inaccessible to clients, contracts as part of a function's interface, structured concurrency, sum types — were present in mature, standardized form in Ada by 1983. Modern languages have been independently converging on these features for forty years. A language that takes them seriously *as a synthesis*, with familiar syntax and a real ecosystem path, is missing from the landscape.

Lyric is not Ada with new syntax. It deliberately drops or alters several Ada features (parameter-mode-only contracts, the package generic mechanism, certified annexes, file-split source organization, raw `raises` declarations) where they pay for themselves in ceremony rather than guarantees. It deliberately keeps the features where guarantees outweigh ceremony.

## Design philosophy

**Make expectations explicit.** Range bounds, parameter modes, raised errors, side effects, dependencies — if it matters for correctness, it should be in the type or the contract, not in a comment.

**Distinct types for distinct meanings.** `UserId` and `OrderId` are not interchangeable, even when both are `Long`. The compiler enforces this. A type system that conflates everything to its underlying machine representation is doing less work than it could.

**Structurally enforced encapsulation.** Visibility is not advisory. An opaque type's representation is unreachable — not by reflection, not by serialization, not by debugger hooks. The boundary is the type, not the developer's discipline.

**Compile-time over runtime where feasible.** Dependency injection, generics, contracts, and (optionally) full functional correctness are resolved at compile time. The runtime carries less weight; bugs are found earlier; AOT compilation works without configuration.

**Ergonomic for the common case, restrictive for the dangerous case.** A REST handler is short. A mutable shared-state operation requires a `protected type`. A nullable value requires explicit handling. A reflective operation is impossible. The friction is calibrated to the danger.

**Lean on existing standards.** Operator precedence, identifier rules, numeric literal syntax, IEEE 754 behavior, ISO 8601 dates — the language adopts established conventions where decisions are conventional rather than load-bearing. The decision log makes clear which choices are ours and which are inherited.

## Target audience

**Primary:** Engineers building services, APIs, and applications on .NET who are dissatisfied with C#'s tendency toward reflection, runtime DI, and weak type discipline at the domain layer. The same engineers who reach for F# for correctness reasons but find F#'s ML-family syntax unfamiliar and its OO interop awkward.

**Secondary:** Teams in regulated or safety-adjacent domains (financial services, healthcare, infrastructure) where contract-based design and optional formal verification justify additional engineering investment.

**Not the audience:** Systems programmers who need fine-grained memory control (Rust does this better, Lyric doesn't try). Scripting and rapid-prototyping users (Lyric's compile times and ceremony are wrong for this). Game developers needing hot-path optimization (different priorities). JVM-first shops in v1 (JVM backend is post-v1).

## What Lyric is not

**Not a systems language.** Lyric uses tracing GC (the .NET runtime's). No ownership/borrowing, no manual memory management, no `unsafe` pointers. Memory safety comes from the host runtime, not from a borrow checker.

**Not a language without a runtime.** Lyric programs depend on the .NET BCL and the Lyric standard library. There is no freestanding mode, no OS-kernel target, no microcontroller target.

**Not a verification-first language.** Most code in a typical Lyric program is `@runtime_checked`, with contracts evaluated as runtime asserts. Static proof is opt-in per module and only feasible for code that doesn't reach into the world. Lyric is verification-*friendly*, not verification-required.

**Not a successor to anything.** Not "C# done right," not "modern Ada," not "Rust without the borrow checker." It's a synthesis with its own opinions, and some of those opinions are unfashionable on purpose (mandatory parameter modes, no exceptions for recoverable errors, no reflection).

## Five things a developer should expect to like

1. The type system catches a category of bugs (unit confusion, range violations, exhaustiveness gaps) that escape Java/C#/TypeScript.
2. Dependency injection is a language feature, not a framework. Wiring is checked at compile time and is plain readable code.
3. Tests don't need a mocking framework — interfaces and the `@stubbable` derive cover the typical cases without runtime bytecode generation.
4. The contract on a function tells you what it requires and guarantees, in the language itself, runnable as runtime checks during development.
5. Concurrent code with shared state is structurally safer — the `protected type` keyword wraps state with declared invariants and barrier conditions; raw locks aren't a tool you reach for.

## Five things a developer should expect to dislike

1. No reflection. Most ORMs, model binders, and Jackson-equivalents won't work. Source generators are the substitute.
2. Mandatory `in`/`out`/`inout` parameter modes — explicit on every parameter, even where C# would let you elide them.
3. Two visibility tiers (`opaque` and `exposed`) means domain types and DTOs are different, with compiler-generated bridges. This is the discipline good DDD codebases already follow informally; Lyric makes it mandatory.
4. Compile times are higher than C# because of monomorphization, contract checking, and (optionally) SMT-solver verification.
5. Smaller ecosystem than C# or Kotlin. The standard library and a curated set of bindings are the starting point; the long tail of NuGet/Maven packages is not directly available.

## Where Lyric sits relative to neighbors

| Property | Lyric | C# | F# | Rust | Kotlin | SPARK Ada |
|---|---|---|---|---|---|---|
| Primary domain | Services | General | General | Systems | General | Safety-critical |
| Memory model | Host GC (.NET) | Host GC | Host GC | Ownership | Host GC | Stack/region |
| Range subtypes | Yes (built-in) | No | No | Newtype | No | Yes |
| Distinct nominal types | Yes (built-in) | No (workaround) | Units of measure | Newtype | Inline classes | Yes |
| Reflection | None | Pervasive | Limited | None | Limited | None |
| DI | Compile-time, language | Runtime, framework | Manual | Manual | Frameworks | Manual |
| Sum types | Yes | Records + pattern | DUs | Enums | Sealed classes | Discriminated records |
| Static verification | Optional per module | None | Limited | External tools | None | Default |
| Async | `async`/`await` | `async`/`await` | Async workflows | `async`/`await` | Coroutines | Tasks |
| Shared state primitive | `protected type` | `lock`/locks | mutable refs | `Arc<Mutex>` | `Mutex` | Protected objects |

Lyric's distinctive position: the safety properties from the right-most column, expressed in the syntax-and-tooling vocabulary of the middle columns, on the .NET runtime.
