# Getting Started

Before you can write Lyric, you need a working compiler. This chapter gets you from zero to a compiled and running program. Along the way you will meet the basic anatomy of a Lyric source file, the handful of tools you will use constantly, and what Lyric errors look like when they occur.

## Installing the compiler

The `lyric` compiler ships as a standalone binary. There are two install paths depending on whether you have the .NET SDK available.

**Option A — .NET global tool (recommended if you already have the .NET 10 SDK):**

```sh
dotnet tool install -g lyric
```

This is one command. The tool is published to NuGet.org and includes the stdlib bundle; no separate download is needed.

**Option B — standalone binary (no .NET SDK required):**

```sh
curl -fsSL https://raw.githubusercontent.com/nichobbs/lyric-lang/main/scripts/install.sh | sh
```

The script detects your platform, downloads the appropriate release archive from GitHub, extracts it to `~/.lyric/bin`, and adds that directory to your shell profile.

Alternatively, download the archive directly from the project's GitHub releases page and place the `lyric` binary (or `lyric.exe` on Windows) somewhere on your `PATH`.

Verify the installation:

```sh
lyric --version
```

The examples in this book use `lyric` as the command name throughout.

## Hello, world

Save this as `hello.l`:

```lyric
package Hello
import Std.Core

func main(): Unit {
  println("Hello, world!")
}
```

Build and run it:

```sh
lyric run hello.l
```

Output:
```
Hello, world!
```

That is the smallest valid Lyric program. A few things are worth noticing right away.

**Every file starts with a package declaration.** `package Hello` says that this file belongs to the `Hello` package. A package corresponds to a directory — all `.l` files in the same directory share the same package name. The file name (`hello.l`) is not meaningful to the compiler; only the package name is.

**`import Std.Core` brings in the standard library core.** `println` is defined in `Std.Core`. The import is explicit — Lyric does not have implicit global namespaces. The exception is a handful of built-in operations (`println`, `panic`, `assert`, `toString`) that are always available without import.

**`func main(): Unit`** is the entry point. `Unit` is Lyric's equivalent of `void` — a type with exactly one value, `()`. A `main` function that returns `Unit` can omit the final `return`.

**String interpolation** uses `${expr}`:

```lyric
package Hello
import Std.Core

func main(): Unit {
  val name = "world"
  println("Hello, ${name}!")
}
```

## Build vs run

`lyric run` compiles and immediately executes. `lyric build` compiles and produces a `.dll` and a `.runtimeconfig.json` alongside the source:

```sh
lyric build hello.l
# Produces: hello.dll  hello.runtimeconfig.json

dotnet hello.dll           # run the produced assembly
```

`lyric build` is incremental: if neither the source nor the standard library has changed since the last build, it is a no-op. Pass `--force` to rebuild unconditionally.

> **Native AOT — not yet available.** A self-contained Native AOT binary (no
> .NET runtime needed at deployment) is a planned deliverable, not a shipped
> feature: there is no `--aot` flag today, and `<PublishAot>` is not yet wired
> into the compiler (`docs/41-self-hosted-compiler-gap-analysis.md` H13,
> sequenced as `docs/36-v1-roadmap.md` §R7.5). For now, deploy the produced
> `hello.dll` and run it with `dotnet hello.dll`, or install the compiler as a
> .NET global tool (`dotnet tool install lyric`).

## The anatomy of a Lyric file

A slightly more complex program:

```lyric
// greet.l
package Greet
import Std.Core

pub record User {
  name: String
  age: Int
}

pub func greet(u: in User): String {
  return "Hello, ${u.name}! You are ${toString(u.age)} years old."
}

func main(): Unit {
  val alice = User(name = "Alice", age = 30)
  println(greet(alice))
  
  val bob = alice.copy(name = "Bob", age = 25)
  println(greet(bob))
}
```

Output:
```
Hello, Alice! You are 30 years old.
Hello, Bob! You are 25 years old.
```

This introduces several things at once.

### `pub` marks public declarations

By default every declaration is visible only inside its own package. `pub` makes a declaration part of the package's public contract — other packages can import and use it. Here, `User` and `greet` are public; `main` is not (and doesn't need to be — the compiler finds entry points by name).

### Records are the primary data structure

`record User` declares a named collection of named fields. There are no classes, no constructors to write, no getters and setters. You get:

- Named construction: `User(name = "Alice", age = 30)`. This is the only construction form — positional construction is not allowed.
- Non-destructive update: `alice.copy(name = "Bob")` produces a new `User` with `name` changed and everything else unchanged.
- Structural equality: two `User` values are equal if all their fields are equal.

### `val` is immutable, `var` is mutable

`val alice = ...` binds `alice` immutably. You cannot reassign it. For a mutable binding, use `var`. The convention in Lyric is to use `val` everywhere you can and reach for `var` only when the algorithm genuinely needs mutation.

There is also `let`, for a lazily-evaluated binding:

```lyric
let expensive = computeSomethingCostly()  // evaluated on first use, then cached
```

`let` uses .NET's `Lazy<T>` semantics — thread-safe initialisation and single evaluation.

### Parameter modes

The `in` on `pub func greet(u: in User)` is a parameter mode. It means the parameter is read-only inside the function. `in` is the default — you can omit it on any parameter — but the language allows writing it explicitly as documentation.

The other modes are `out` (the function must assign the parameter exactly once before returning) and `inout` (read and write). You will see them in Chapter 4.

::: sidebar
**Why explicit parameter modes?** In C# and Java, pass-by-reference and pass-by-value are implicit. A `ref` parameter in C# is visible at the call site (`func(ref x)`) but nothing in the signature tells a reader whether the function reads the value, writes it, or both. Lyric's `in`/`out`/`inout` make this explicit in every signature, which is useful both for readability and for the proof system (a `requires:` clause on an `in` parameter is cleaner when you can trust the parameter won't be mutated). Omitting `in` is valid — the compiler defaults to it — but the formatter always inserts it, so in practice every parameter mode is visible in formatted code.
:::

## The toolchain at a glance

Core commands you will use constantly:

| Command | What it does |
|---------|-------------|
| `lyric build <file.l>` | Compile; produce a `.dll` |
| `lyric run <file.l>` | Compile and immediately execute |
| `lyric test <file.l>` | Run `test` declarations in a `@test_module` file (TAP-shaped output, exit 1 on failure) |
| `lyric test <file.l> --list` | Print test titles without compiling |
| `lyric test <file.l> --filter <substring>` | Run only tests whose title contains the substring |
| `lyric fmt` | Format source code to the standard style |
| `lyric fmt --check` | Exit 1 if the file is not formatted (CI gate) |
| `lyric fmt --write` | Overwrite file in place |
| `lyric lint` | Report style and quality diagnostics |
| `lyric lint --error-on-warning` | Treat warnings as errors (CI gate) |
| `lyric doc <file.l>` | Generate Markdown documentation from doc comments |
| `lyric prove <file.l>` | Run the SMT-backed verifier on `@proof_required` modules |
| `lyric bench <file.l>` | Measure runtime performance of `@bench_module` functions |
| `lyric bench <file.l> --runs <N> --warmup <N>` | Control timed and warmup iteration counts |
| `lyric bench <file.l> --filter <substring>` | Run only benchmarks whose name contains the substring |
| `lyric publish` | Pack and push the current package to the configured registry |
| `lyric publish --registry <url> --api-key <key>` | Publish to a specific feed with an API key |
| `lyric restore` | Restore all dependencies declared in `lyric.toml`; writes `lyric.lock` |
| `lyric restore --locked` | Restore strictly from `lyric.lock` (fail if lock is stale) |
| `lyric search <query>` | Search the registry for matching packages |
| `lyric repl` | Start an interactive read-eval-print loop |
| `lyric repl --verbose` | REPL with diagnostic output on each evaluation |
| `lyric --sdk-info` | Print SDK root, stdlib path, and version information |

`lyric fmt` is opinionated and has no configuration. The format is the format. Run it on save.

`lyric fmt` walks the parser's red/green concrete syntax tree, so **all comments are preserved**: `///` and `//!` doc comments, `//` line comments, and `/* … */` block comments — at item, member, statement, and nested-block boundaries.  Intentional blank lines are also preserved (collapsed to at most one blank per spot, Black-style).

If you need the older AST-based formatter (which drops `//` comments, retained for one release as a compatibility fallback), pass `--legacy` or set the environment variable `LYRIC_FMT_LEGACY=1`.

`lyric lint` catches five categories of issue without needing a full compile: PascalCase for types (L001), camelCase for functions (L002), missing doc comments on `pub` items (L003), TODO/FIXME in doc comments (L004), and `pub func` with a block body but no contracts (L005). L001/L002 are errors; L003–L005 are warnings that become errors under `--error-on-warning`.

## Your first error message

Understanding what the compiler says when things go wrong saves you a lot of time. Here is a simple error: calling a function with the wrong type.

```lyric
package BadGreet
import Std.Core

record User {
  name: String
  age: Int
}

func greet(u: in User): String {
  return "Hello, ${u.name}!"
}

func main(): Unit {
  println(greet("Alice"))    // wrong: "Alice" is a String, not a User
}
```

The compiler produces:

```
badGreet.l:15:11: error E0201: type mismatch
  expected: User
     found: String
  note: argument 1 to greet()
```

Lyric errors report the file, line, and column; name the expected and found types; and identify which argument caused the mismatch. You will not see "expected identifier, found ';'" when you pass the wrong type to a function.

Here is an exhaustiveness error — one of the errors you will come to appreciate:

```lyric
package ShapeDemo
import Std.Core

union Shape {
  case Circle(radius: Double)
  case Rectangle(width: Double, height: Double)
}

func area(s: in Shape): Double {
  return match s {
    case Circle(r) -> 3.14159 * r * r
    // forgot Rectangle!
  }
}
```

```
shapeDemo.l:11:10: error E0301: non-exhaustive match
  missing case: Rectangle
  note: if you intend to ignore this case, use: case _ ->
```

The compiler names the missing case. If you add a new variant to a union later, every `match` in the codebase that covers that union will fail to compile until you handle the new case. This is one of the practical payoffs of sum types — a change in the data model propagates as a compile error, not a runtime crash.

## Reading doc comments

Lyric supports three kinds of comments:

```lyric
// Regular line comment — not included in documentation

/// Doc comment for the following item (Markdown)
/// The compiler extracts these for `lyric doc`.

//! Doc comment for the enclosing module (placed at the top of a file)
```

Use `//!` — not `///` — for a file-header doc block at the top of a file. `///` attaches to the *item that follows it*, so a `///` before the `package` declaration has nothing to document and is rejected with `error[P0020]: a '///' doc comment before 'package' has no item to document; use '//!' for a module-level doc comment`. `//!` documents the enclosing module and belongs before `package`.

Write doc comments on every `pub` declaration. The `lyric doc` command generates Markdown documentation from them, including your `requires` and `ensures` clauses.

## The library ecosystem

The standard library (`Std.*`) covers the basics: collections, strings, JSON, time, UUIDs, HTTP primitives, and testing.  For production service work, Lyric ships a suite of standalone library packages that you add to your `lyric.toml`:

| What you need | Library | Key packages |
|---|---|---|
| Structured logging | `lyric-logging` | `Std.Logging`, `Std.Logging.Aspects` |
| HTTP server | `lyric-web` | `Web`, `Web.OpenApi`, `Web.Aspects` |
| Caching (in-memory / disk) | `lyric-cache` | `Cache`, `Cache.Aspects` |
| SQL database access | `lyric-db` | `Db`, `Db.Aspects` |
| Background jobs | `lyric-jobs` | `Jobs` |
| Email (SMTP / SES / SendGrid) | `lyric-mail` | `Mail` |
| Message queues (RabbitMQ / SQS / …) | `lyric-mq` | `Mq`, `Mq.Aspects` |
| Observability (OpenTelemetry) | `lyric-otel` | `OTel`, `OTel.Otlp` |
| Full-text search (Elasticsearch / Meilisearch) | `lyric-search` | `Search` |
| Distributed sessions | `lyric-session` | `Session` |
| Object storage (S3 / Azure Blob / local) | `lyric-storage` | `Storage`, `Storage.Aspects` |
| Input validation | `lyric-validation` | `Validation` |
| WebSockets | `lyric-ws` | `Ws`, `Ws.Aspects` |
| Feature flags | `lyric-feature-flags` | `Flags`, `Flags.Aspects` |
| Internationalisation (i18n) | `lyric-i18n` | `I18n` |
| Protocol Buffers (proto3) | `lyric-proto` | `Proto` |
| gRPC client | `lyric-grpc` | `Grpc` |
| Liveness / readiness probes | `lyric-health` | `Health` |
| Test mocks and assertion helpers | `lyric-testing` | `Testing` |

See Appendix B §B.9 for the full module reference, and each library's `README.md` for usage examples.

## Exercises

1. **Different entry points**

   Lyric's `main` function name is a convention, not a keyword. What happens if you rename it to `run`? Try it and see what error the compiler produces. Then look up how `lyric build --entrypoint` changes the convention.

2. **Named construction and `.copy()`**

   Create a `record Point { x: Double; y: Double }`. Construct a value with `Point(x = 1.0, y = 2.0)`, then use `.copy()` to produce a second `Point` with only `x` changed to `3.0`. Verify that the original is unchanged. Now try writing `Point(1.0, 2.0)` without field names — what error does the compiler produce?

3. **Mutating with `var`**

   Write a function that takes a mutable counter (`var count: Int`) and increments it three times in a loop, printing the value after each increment. Notice that the `for i in 0 ..< 3` syntax gives you a range of integers.

4. **Exhaustiveness**

   Add a `Triangle(base: Double, height: Double)` case to the `Shape` union from the error example above. Observe every place the compiler complains. Fix them. How does this compare to adding a new case to a C# enum?

5. **Format style**

   Write a function with poor formatting — inconsistent spacing, misaligned `=` signs, or a mix of tab and space indentation. Run `lyric fmt` on it. What changed? What didn't?
