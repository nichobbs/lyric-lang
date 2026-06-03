# Lyric

A safety-oriented application language targeting .NET, drawing on Ada's design principles while maintaining familiar syntax and ecosystem interoperability.

**Status:** Self-hosted compiler shipping. Lyric compiles itself: the self-hosted compiler under `lyric-compiler/lyric/` lexes, parses, type-checks, mode-checks, elaborates contracts, monomorphises, weaves aspects, and emits MSIL (in-process) and JVM bytecode. A 40-module standard library and ~20 ecosystem libraries (web, mq, auth, storage, sessions, jobs, etc.) ship alongside. The legacy F# bootstrap compiler under `bootstrap/src/Lyric.*/` exists solely so stage-0 can compile the self-hosted compiler from `.l` sources; it is closed to new code and on a deletion schedule (see `docs/23-fsharp-shim-elimination.md`). The self-hosted `--target dotnet` path is not yet at the v1.0 production bar — the front end is still advisory and a few constructs (`?`, `await`, `defer`, `==`) need correctness work; the live gating list is `docs/41-self-hosted-compiler-gap-analysis.md` §10, sequenced as `docs/36-v1-roadmap.md` §R7.

## What Lyric is

A general-purpose application language for building services and APIs, with:

- **Strong type system** with range-constrained subtypes and distinct nominal types
- **Representational privacy** via opaque types — no reflection can crack them open
- **Design-by-contract** as a first-class language feature (`requires`, `ensures`, invariants)
- **Compile-time dependency injection** baked into the language
- **Structured concurrency** with `async`/`await` and Ada-style `protected type` for shared state
- **Tiered visibility** — opaque domain types coexist with exposed wire-level types via compiler-generated projections
- **Optional formal verification** via SMT-solver-backed proof of contracts (per-module opt-in)

Lyric targets the .NET runtime (`--target dotnet`, leveraging reified generics, value types, and Native AOT) and the JVM (`--target jvm`, emitting JVM bytecode via the self-hosted JVM emitter under `lyric-compiler/jvm/`).

## Quick start

### Prerequisites

- [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0) (pinned by `bootstrap/global.json`)

### Build the compiler

```sh
# Stage 0: build the F# bootstrap compiler.
cd bootstrap
dotnet build Bootstrap.sln

# Stage 1: bootstrap the self-hosted Lyric compiler.  This compiles
# every `lyric-compiler/lyric/**/*.l` package into a `Lyric.Lyric.*.dll`
# bundle under `.bootstrap/stage1/` and builds the AOT entry-point
# binary `bootstrap/src/Lyric.Cli.Aot/bin/Debug/net10.0/lyric` that
# trampolines into the Lyric-emitted CLI.
cd ..
./scripts/bootstrap.sh --stage 1
```

### Compile and run a Lyric program

User-facing commands flow through the AOT entry-point binary built by
stage 1.  After `./scripts/bootstrap.sh --stage 1`:

```sh
lyric=bootstrap/src/Lyric.Cli.Aot/bin/Debug/net10.0/lyric

# Build: writes hello.dll + hello.runtimeconfig.json alongside hello.l
$lyric build hello.l

# Build + run in one step
$lyric run hello.l

# Pass args to the program
$lyric run hello.l -- arg1 arg2
```

`build` is incremental — re-running with the same source and stdlib files is
a no-op.  Pass `--force` to always rebuild.

The F# `bootstrap/src/Lyric.Cli/` project only handles internal flags
(`--internal-build`, `--internal-project-build`,
`--internal-contract-meta`, `--internal-manifest-build`) used by the
bootstrap pipeline; do not invoke it directly for user commands.

### Hello world

```lyric
package Hello
import Std.Core

func main(): Unit {
  println("Hello, world!")
}
```

### Using the standard library

The stdlib lives in `lyric-stdlib/std/`.  Import individual modules with
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

The 40+ stdlib modules under `lyric-stdlib/std/*.l` cover the
core surface (`Std.Core`, `Std.Collections`, `Std.String`,
`Std.Char`, `Std.Iter`, `Std.Set`, `Std.Sort`, `Std.Hash`,
`Std.Format`, `Std.Stream`), data interchange (`Std.Json`,
`Std.Xml`, `Std.Yaml`, `Std.Encoding`), I/O (`Std.File`,
`Std.Directory`, `Std.Path`, `Std.Console`, `Std.Process`,
`Std.Environment`), networking (`Std.Http`, `Std.Rest`),
math/random (`Std.Math`, `Std.Random`, `Std.SecureRandom`),
text matching (`Std.Regex`, `Std.RegexSafe`, `Std.Parse`),
time/identity (`Std.Time`, `Std.Uuid`), diagnostics
(`Std.Errors`, `Std.Log`), testing (`Std.Testing`,
`Std.Testing.Property`, `Std.Testing.Snapshot`,
`Std.Testing.Mocking`), and reflection-on-self
(`Std.AssemblyResources`).  See `docs/10-stdlib-plan.md` for the
stability cut table.

Codegen builtins (no import needed): `println`, `panic`, `expect`,
`assert`, `toString(x)` (any value → String), `format1`/`format2`/
`format3`/`format4` (`String.Format`-style with `{0}` placeholders),
`default()` (zero-init for the surrounding ascribed type).

`func name(p: out T)` and `func name(p: inout T)` lower to CLR byref
parameters; arguments must be named-variable l-values, and a
definite-assignment analysis ensures every `out` param is written
on every path before return.

The compiler resolves `import Std.X` by locating the matching `.l` source in
the `lyric-stdlib/std/` directory, compiling it on demand, and linking the produced
DLL into the user's output directory.  The search order is:

1. `LYRIC_STD_PATH` environment variable (point this at the `lyric-stdlib/std/`
   directory for out-of-tree / installed use)
2. Walk up the directory tree from the compiler binary's location looking for
   a `lyric-stdlib/std/` subdirectory (works when running inside the repo with
   `dotnet run`)

### Running the test suite

```sh
cd bootstrap
dotnet run --project tests/Lyric.Lexer.Tests
dotnet run --project tests/Lyric.Parser.Tests
dotnet run --project tests/Lyric.TypeChecker.Tests
dotnet run --project tests/Lyric.Emitter.Tests
dotnet run --project tests/Lyric.Cli.Tests
```

The `Lyric.Emitter.Tests` runner discovers and executes every
`lyric-stdlib/tests/*_tests.l` self-test against the in-process MSIL
bridge.  Self-tests for the self-hosted compiler packages live next to
their sources (`lyric-compiler/lyric/<pkg>_self_test.l`).

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
- [13-tutorial.md](docs/13-tutorial.md) — guided introduction for newcomers (Phase 3 / D-progress-065)
- [18-jvm-emission.md](docs/18-jvm-emission.md) — JVM bytecode emission strategy (self-hosted Lyric emitter shipped in `lyric-compiler/jvm/`)
- [grammar.ebnf](docs/grammar.ebnf) — formal grammar (Phase 0 deliverable #4)

## Reading order

Newcomers: 00 → 13 → 02 → 01 → 03.
Implementers: 01 → 05 → 06.
Reviewers: 03 → 04 → 06.

## Implementation progress

See [docs/10-bootstrap-progress.md](docs/10-bootstrap-progress.md) for the running log of what has shipped vs. what's deferred.  See [docs/05-implementation-plan.md](docs/05-implementation-plan.md) for the full phased plan.

## Contributing to the design

The decision log (03) is the canonical record of *why* the language is the way it is. Any proposal to change a fundamental design decision should reference the relevant decision-log entry and explain why the original reasoning no longer holds. New decisions get appended; reversed decisions are not deleted but marked superseded with a forward reference.
