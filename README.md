# Lyric

A safety-oriented application language targeting .NET, drawing on Ada's design principles while maintaining familiar syntax and ecosystem interoperability.

**Status:** Bootstrap compiler shipping (Phase 1 complete, Phase 2 substantially complete). The `lyric` CLI compiles `.l` source files to runnable .NET assemblies today. The language specification and design rationale live alongside the compiler.

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

## Quick start

### Prerequisites

- [.NET 9 SDK](https://dotnet.microsoft.com/download/dotnet/9.0)

### Build the compiler

```sh
cd compiler
dotnet build Lyric.sln
```

### Compile and run a Lyric program

```sh
# Build: writes hello.dll + hello.runtimeconfig.json alongside hello.l
dotnet run --project compiler/src/Lyric.Cli -- build hello.l

# Build + run in one step
dotnet run --project compiler/src/Lyric.Cli -- run hello.l

# Pass args to the program
dotnet run --project compiler/src/Lyric.Cli -- run hello.l -- arg1 arg2
```

`build` is incremental — re-running with the same source and stdlib files is
a no-op.  Pass `--force` to always rebuild.

### Hello world

```lyric
package Hello
import Std.Core

func main(): Unit {
  println("Hello, world!")
}
```

### Using the standard library

The stdlib lives in `compiler/lyric/std/`.  Import individual modules with
`import Std.X`:

```lyric
package MyApp
import Std.Core
import Std.String
import Std.Parse
import Std.Errors

func main(): Unit {
  val parts = split("a,b,c", ",")
  println(join(" | ", parts))        // → a | b | c

  match tryParseInt("42") {
    case Ok(value) -> println(value) // → 42
    case Err(_)    -> println(-1)
  }
}
```

Available stdlib modules: `Std.Core` (Result, Option, built-in ops),
`Std.String` (trim, split, join, case conversion, substring, …),
`Std.Parse` (tryParseInt, tryParseLong, tryParseDouble, tryParseBool),
`Std.Errors` (ParseError, IOError, HttpError),
`Std.File` (readText / writeText / fileExists / createDir),
`Std.Collections` (`List[T]` and `Map[K, V]` — generic growable
lists and hash maps backed by the BCL; access via method-style
`xs.add(item)` / `m[key]` / `m.containsKey(key)` / `xs.count`).

Codegen builtins (no import needed): `println`, `panic`, `expect`,
`assert`, `toString(x)` (any value → String), `format1`/`format2`/
`format3`/`format4` (`String.Format`-style with `{0}` placeholders).

The compiler resolves `import Std.X` by locating the matching `.l` source in
the `lyric/std/` directory, compiling it on demand, and linking the produced
DLL into the user's output directory.  The search order is:

1. `LYRIC_STD_PATH` environment variable (point this at the `lyric/std/`
   directory for out-of-tree / installed use)
2. Walk up the directory tree from the compiler binary's location looking for
   a `lyric/std/` subdirectory (works when running inside the repo with
   `dotnet run`)

### Running the test suite

```sh
cd compiler
dotnet run --project tests/Lyric.Lexer.Tests
dotnet run --project tests/Lyric.Parser.Tests
dotnet run --project tests/Lyric.TypeChecker.Tests
dotnet run --project tests/Lyric.Emitter.Tests
```

---

## Documentation map

- [00-overview.md](docs/00-overview.md) — design philosophy, target audience, what Lyric is and is not
- [01-language-reference.md](docs/01-language-reference.md) — syntax, type system, semantics
- [02-worked-examples.md](docs/02-worked-examples.md) — non-trivial programs in proposed-Lyric
- [03-decision-log.md](docs/03-decision-log.md) — every significant design decision with rationale
- [04-out-of-scope.md](docs/04-out-of-scope.md) — what we deliberately don't do, and why
- [05-implementation-plan.md](docs/05-implementation-plan.md) — phased plan from v0.1 to self-hosting
- [06-open-questions.md](docs/06-open-questions.md) — unresolved design questions
- [07-references.md](docs/07-references.md) — external standards and prior art
- [08-contract-semantics.md](docs/08-contract-semantics.md) — operational semantics for `requires` / `ensures` / `invariant`
- [09-msil-emission.md](docs/09-msil-emission.md) — how Lyric lowers to MSIL on .NET
- [grammar.ebnf](docs/grammar.ebnf) — formal grammar (Phase 0 deliverable #4)

## Reading order

Newcomers: 00 → 02 → 01 → 03.
Implementers: 01 → 05 → 06.
Reviewers: 03 → 04 → 06.

## Implementation progress

See [docs/10-bootstrap-progress.md](docs/10-bootstrap-progress.md) for the running log of what has shipped vs. what's deferred.  See [docs/05-implementation-plan.md](docs/05-implementation-plan.md) for the full phased plan.

## Contributing to the design

The decision log (03) is the canonical record of *why* the language is the way it is. Any proposal to change a fundamental design decision should reference the relevant decision-log entry and explain why the original reasoning no longer holds. New decisions get appended; reversed decisions are not deleted but marked superseded with a forward reference.
