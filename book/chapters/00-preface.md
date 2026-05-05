# Preface

There is a particular feeling that comes from working in a language that is on your side. You write the thing you mean, the compiler checks it, and the resulting program does what you said. The type system is not a layer of boilerplate to work around; it is the language of your domain. The errors you get are precise enough to be useful. The codebase, months later, still reads like documentation.

Most developers have experienced the opposite too: a language that is clever enough to let you express anything, but which offers no help distinguishing `UserId` from `OrderId`, no structural way to say "this function cannot fail," no mechanism for encoding the rule that an `Amount` must be positive. These things end up in comments that rot, in documentation nobody reads, in runtime assertions that fire in production at three in the morning. The discipline that was supposed to be there is cultural, not structural. Culture drifts.

Lyric is an attempt to make that discipline structural. It takes safety properties that exist in mature form in languages like Ada and SPARK, and expresses them in syntax that a developer familiar with Kotlin, C#, or TypeScript can read on day one. Range-constrained types. Distinct nominal types for distinct domains. First-class contracts: `requires`, `ensures`, `invariant`. Compile-time dependency injection. Structured concurrency. Optional SMT-backed proofs per module.

None of these ideas are new. What Lyric offers is a synthesis: familiar syntax, the .NET ecosystem, and safety properties that are normally found only in languages with a much higher barrier to entry.

## About the title

"Making Lyric Sing" works on two levels, and both are deliberate.

The obvious one: Lyric is a language, and the book is about learning to use it. Making it sing is making it work for you.

The less obvious one: a piece of music that doesn't sing is technically correct but inert. All the right notes, played in the right order, with no feeling. Programs can be the same way — they compile and run, but the structure doesn't reflect the domain, the types don't encode the invariants, and the contracts live in comments that nobody reads. *Making* Lyric sing means writing programs that express what they mean. The type system isn't the overhead; it's the instrument.

## Who this book is for

You know how to program. You are comfortable with at least one statically-typed language — Java, C#, Kotlin, TypeScript, Scala, Rust, Go, something in that neighbourhood. You have written code that runs in production. You are not here to learn what a function is.

What you have probably not done is write in a language where:

- A `UserId` and an `OrderId` cannot be accidentally swapped, at compile time, with no wrapper boilerplate
- A function's contract — what it requires and what it guarantees — is part of the source code, checked by the compiler or an SMT solver
- Dependency injection is resolved at compile time, in the language, with a cycle check
- A concurrent shared-state data structure has its invariants structurally enforced, not locked behind convention

If any of those sound appealing, this is the right book.

## What this book covers

The book is organised progressively. Each chapter builds on the previous ones. If you are impatient, you can skip ahead, but chapters in Part III onwards assume you are comfortable with the material in Parts I and II.

**Part I — Getting Started** covers the toolchain and first programs. By the end you will have compiled and run Lyric code.

**Part II — Core Language** works through types, data structures, functions, pattern matching, and the module system — the grammar of the language.

**Part III — Safety by Construction** is where Lyric's distinctive character emerges: error handling via `Result`, contracts, and opaque types whose invariants are structurally enforced.

**Part IV — Real Programs** covers the features you need to build something substantial: async/await, structured concurrency, compile-time dependency injection, the standard library, and FFI.

**Part V — Testing and Quality** shows how testing works in Lyric — unit tests, property-based tests, snapshot tests, and how `@stubbable` interfaces replace mocking frameworks.

**Part VI — Verification** introduces `@proof_required` modules and `lyric prove`. This is the deep end: getting an SMT solver to check your contracts at compile time. It is optional in practice, invaluable in safety-critical code.

**Part VII — The Package Ecosystem** covers `lyric.toml`, the package manager, and stability annotations.

The appendices cover the VS Code extension and a quick-reference card for syntax and standard library.

## What this book is not

This is not a language specification. The authoritative language specification is `docs/01-language-reference.md` in the repository. If this book and the spec disagree, the spec wins. This book is a learning guide, not a contract.

This is also not an API reference. The standard library's source lives in `compiler/lyric/std/`; `lyric doc` generates the rendered API docs. The appendix has a quick-reference card, but for detailed API coverage, use the generated docs.

## A note on the compiler

The bootstrap compiler exists and ships working code. `lyric build`, `lyric run`, `lyric test`, and `lyric prove` are real commands you can run today. The compiler targets .NET 10. Some features described in this book are ahead of what is shipped — notably, some advanced FFI, certain `@projectable` edge cases, and the full standard library surface — but the core language and the features that matter most for learning are implemented.

Where a feature is not yet shipped, the text says so. Descriptions that say "the compiler checks" or "the prover discharges" are not hypothetical — they describe what actually happens when you run the commands.

## How to read this book

Sequentially, ideally. The examples build on each other. The banking service that appears in Part III shows up again in Parts V and VI, and seeing it evolve is part of the point.

That said, if you are already familiar with the basics and want to get to contracts, jump to Chapter 8. If you want to understand the test infrastructure, jump to Chapter 14. Each chapter starts with a short summary of what it covers and what you should already know.

Code examples use Lyric for Lyric source, `sh` for shell commands, `json` for JSON, and `toml` for configuration. Comments in Lyric source use `//`. All examples are written to be runnable with the bootstrap compiler unless explicitly noted.

One last thing: the language has opinions, and the book explains them. Design decisions are not arbitrary — there is a decision log (`docs/03-decision-log.md`) that records the reasoning behind every significant choice. When the book presents a sidebar that starts with "Why does Lyric...", it is drawing on that log. If you find yourself disagreeing with a decision, the log is the place to read the other side.
