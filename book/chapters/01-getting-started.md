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

### Upgrading the compiler

Once installed, the compiler can easily upgrade itself to the latest released version (or a specific version) using the `lyric upgrade` subcommand:

```sh
lyric upgrade
```

By default, the command auto-detects how `lyric` was installed (via `.NET Global Tool` or as a standalone binary) and updates it accordingly.

To force a specific upgrade channel or target a specific version, use:

```sh
# Upgrade via NuGet global tool
lyric upgrade --nuget

# Upgrade standalone installation via the GitHub Releases script
lyric upgrade --github --version 0.4.6
```

You can also use `--dry-run` to preview the exact upgrade commands that would be run.


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

A project can produce a directly-runnable launcher instead of a bare `.dll` by setting `kind = "exe"` in its `lyric.toml`:

```toml
[build]
kind = "exe"   # default: "lib"
```

This emits a native *apphost* launcher beside the managed DLL — `bin/<name>` (or `<name>.exe` on Windows) — so the program starts with `./<name>` rather than `dotnet <name>.dll`, and `lyric run` execs it directly. It is still framework-dependent (a .NET runtime must be installed). The `bundle` (self-contained) kind is reserved for future use. `kind = "aot"` produces a native binary with no runtime dependency and is equivalent to `lyric build --release` (see §"Native binaries" below); it requires a system linker (`clang` or `ld64`) on `PATH` and supports Linux (`x64`/`arm64`) and macOS (Windows is tracked in #1975).

Inside a project, you can drop the arguments entirely. Running `lyric` with no
command builds the current project, and `lyric build` / `lyric restore` find the
project's `lyric.toml` by walking up from your working directory — so they work
from any subdirectory. All eight dev-loop commands (`build`, `run`, `fmt`,
`lint`, `prove`, `doc`, `test`, `bench`) do the same discovery, so they work
from any subdirectory without arguments. Run `lyric --help` for the grouped
command list.

### Scaffolding a project — `lyric init`

Rather than hand-writing `lyric.toml` and the source layout, `lyric init`
scaffolds a new package:

```
lyric init demo
cd demo
lyric run src/main.l      # prints: Hello from Demo!
lyric build               # builds demo/bin/Demo.dll
```

`lyric init [<dir>] [--name <Name>] [--lib] [--force]` creates the target
directory (default the current one), a `lyric.toml` with `[package]`,
`[project]`, and an empty `[dependencies]` table, a `src/main.l` hello-world
(or `src/lib.l` with `--lib`), and a `.gitignore`. The package name is derived
from the directory name (capitalised to the `UpperCamelCase` convention) unless
`--name` overrides it; a name that isn't a valid identifier is rejected with a
hint to pass `--name`. An existing `lyric.toml` is never overwritten without
`--force`.

### Native binaries — `lyric build --release`

For deployment, `lyric build --release hello.l` produces a **self-contained
Native AOT binary** — a single executable with no .NET runtime required on the
target machine:

```sh
lyric build --release hello.l
# Produces: hello   (a native executable)
./hello
```

Under the hood the compiler invokes `ilc` (the .NET Native AOT compiler) and
`clang` directly — no generated C#, no `dotnet publish`. `clang` must be on
`PATH` (e.g. `apt install clang` on Debian/Ubuntu, `dnf install clang` on
Fedora). Any ILC trim/AOT warnings are shown. `--rid <rid>` selects a runtime
identifier (default: your host), and `-o` overrides the output path.

This is equivalent to setting `[build] kind = "aot"` in your `lyric.toml` and
running `lyric build`.

> **Scope today.** `--release` covers Linux (`x64`/`arm64`) and macOS (`x64`/`arm64`). Windows is tracked in [#1975] and fails loud rather than emitting a managed
> artifact. The JVM (GraalVM `native-image`) target is also tracked in #1975.

[#1975]: https://github.com/nichobbs/lyric-lang/issues/1975

### The LLVM native target — `lyric build --target native`

Distinct from `--release` (which AOT-compiles the *.NET* build with `ilc`),
`lyric build --target native hello.l` compiles Lyric source directly to LLVM
IR and drives `clang` to produce a self-contained POSIX executable with no
managed runtime at all — no .NET, no JVM:

```sh
lyric build --target native hello.l
# Produces: hello   (a native executable)
./hello
```

`clang` must be on `PATH`; the binary links against the `lyric_rt` runtime
library (ARC intrinsics, strings, POSIX helpers), `libm`, and `libpthread`.
`--triple <llvm-triple>` cross-compiles (default: the host triple) and
`--opt 0|1|2|3|s` sets the clang optimisation level (default `2`).
`lyric run --target native <file.l>` builds and runs in one step.

Memory on this target is managed by automatic reference counting (ARC) —
there is no garbage collector. Reference cycles are not collected; break
them explicitly with `NativeWeak[T]`, whose `upgrade()` returns
`Option[T]` (`None` once the target has been released).

> **Scope today.** Linux (`x64`/`arm64`) and macOS (`arm64`) are supported.
> The lowered surface covers scalars and strings; records (methods, field
> defaults, mutable fields), unions, enums, distinct types (range-checked),
> and tuples; full pattern matching; non-generic interfaces (`impl I for
> Record` dispatches through a per-interface vtable) and non-generic
> protected types (`entry`/`func` members lock a mutex around a
> desugared inner body); generic records, unions, and functions
> (via call-site monomorphization); closures (by-value captures); and
> `NativeWeak[T]`; and `List[T]`/`Map[K, V]` with `for` loops, indexing,
> and the `Std.Collections` accessors (map keys must be String or a
> scalar type); `slice[T]` (shares the list representation, immutable by
> construction), unlocking bytes-mode file I/O, directory listing, and
> `Std.Environment.args()`. A non-generator `async func` and `await`
> compile through the same codegen path as a plain `func` (`Task[T]`
> isn't materialised as a distinct value on this target); `spawn` and
> `scope { }` follow the same passthrough model the .NET emitter itself
> uses (a spawned call completes at the spawn site — native has no
> async leaf primitive for it to overlap with); `defer` runs
> on its normal-exit paths (fall-off, `return`, `break`, `continue`).
> Standard-library modules with native kernels work out of
> the box: `Std.Console`, `Std.File` (text I/O, existence probes,
> directory create/delete), `Std.Environment` (variables, working
> directory), `Std.Process.runCapture` (argv list, never a shell), and
> `Std.Time` (epoch millis, monotonic nanos, sleep). Raw C interop
> (`extern func`, `NativePtr[T]`,
> `nativeAddrOf`, `nativeNullPtr`, closures as C callbacks) is confined to
> `@unsafe_ffi` functions and the standard library's kernel files — the
> compiler rejects it elsewhere (`N0100`). Constructs not yet lowered fail
> the build with a diagnostic naming the construct rather than
> miscompiling: interface default/generic methods, generic protected
> types, list literals, module-level `val`, async generators (`yield`
> inside `async func`), a `defer` that must run during
> a `panic`, and manifest (multi-package) native builds.

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
| `lyric` | Build the current project (discovers the nearest `lyric.toml`) |
| `lyric build <file.l>` | Compile for .NET (default); produce a `.dll` + `.runtimeconfig.json`; prints elapsed time on success |
| `lyric build --target jvm <file.l>` | Compile for the JVM; produce a runnable `.jar` (no `runtimeconfig.json`) |
| `lyric build --target native <file.l>` | Compile to a self-contained POSIX executable via the LLVM backend + clang |
| `lyric build` | Build the discovered project (no source arg needed) |
| `lyric run <file.l>` | Compile and immediately execute a single file |
| `lyric run` | Build and run the discovered project (no source arg needed) |
| `lyric run --target jvm` | Build and run the project on the JVM target |
| `lyric run --target native <file.l>` | Build the native binary and run it directly |
| `lyric --help` | Print the grouped command list |
| `lyric test <file.l>` | Run `test` declarations in a `@test_module` file (TAP-shaped output, exit 1 on failure) |
| `lyric test` | Run tests for the discovered project; falls back to scanning packages for `@test_module` |
| `lyric test <file.l> --list` | Print test titles without compiling |
| `lyric test <file.l> --filter <substring>` | Run only tests whose title contains the substring |
| `lyric test <file.l> --fail-fast` | Stop after the first file with failing tests; print an early summary |
| `lyric check <file.l>` | Type-check without producing a usable output artifact |
| `lyric check` | Type-check the discovered project (output to `.lyric-check/`, not `bin/`) |
| `lyric clean` | Remove `bin/`, `.lyric-run/`, `.lyric-test/`, `.lyric-bench/`, `.lyric-check/`, `.lyric-release/` |
| `lyric fmt` | Dry-run: list files that would be reformatted (exit 1 if any) |
| `lyric fmt --write` | Reformat all project source files in place |
| `lyric fmt --check` | Exit 1 if any file is not formatted (CI gate) |
| `lyric fmt --diff` | Show a unified diff of what would change without writing |
| `lyric fmt <file.l> [<file2.l> …]` | Format one or more explicit files |
| `lyric fmt --stdin` | Read from stdin, write formatted output to stdout (editor integration) |
| `lyric lint` | Report style diagnostics; prints summary `N error(s), M warning(s) in K file(s)` |
| `lyric lint --error-on-warning` | Treat warnings as errors (CI gate) |
| `lyric doc <file.l>` | Generate Markdown documentation from doc comments |
| `lyric doc` | Generate docs for all packages in the discovered project |
| `lyric prove <file.l>` | Run the SMT-backed verifier on `@proof_required` modules |
| `lyric prove` | Verify all packages in the discovered project |
| `lyric bench <file.l>` | Measure runtime performance of `@bench_module` functions |
| `lyric bench <file.l> --target jvm` | Benchmark on the JVM target (`java -jar`) |
| `lyric bench` | Run benchmarks for all packages in the discovered project |
| `lyric bench --target jvm` | Project mode on JVM target |
| `lyric bench <file.l> --runs <N> --warmup <N>` | Control timed and warmup iteration counts |
| `lyric bench <file.l> --filter <substring>` | Run only benchmarks whose name contains the substring |
| `lyric publish` | Pack and push the current package to the configured registry |
| `lyric publish --registry <url> --api-key <key>` | Publish to a specific feed with an API key |
| `lyric restore` | Restore all dependencies declared in `lyric.toml`; writes `lyric.lock` |
| `lyric restore --locked` | Restore strictly from `lyric.lock` (fail if lock is stale) |
| `lyric update` | Re-resolve all deps to latest compatible versions; rewrites `lyric.lock` |
| `lyric deps` | Print the resolved dependency list from `lyric.lock` |
| `lyric remove <name>` | Remove a dependency from `[dependencies]` in `lyric.toml` and re-run restore |
| `lyric search <query>` | Search the registry for matching packages |
| `lyric repl` | Start an interactive read-eval-print loop |
| `lyric repl --verbose` | REPL with diagnostic output on each evaluation |
| `lyric --sdk-info` | Print SDK root, stdlib path, and version information |

`lyric fmt` is opinionated and has no configuration. The format is the format. Run it on save.

`lyric fmt` walks the parser's red/green concrete syntax tree, so **all comments are preserved**: `///` and `//!` doc comments, `//` line comments, and `/* … */` block comments — at item, member, statement, and nested-block boundaries.  Intentional blank lines are also preserved (collapsed to at most one blank per spot, Black-style).

`lyric lint` catches five categories of issue without needing a full compile: PascalCase for types (L001), camelCase for functions (L002), missing doc comments on `pub` items (L003), TODO/FIXME in doc comments (L004), and `pub func` with a block body but no contracts (L005). L001/L002 are errors; L003–L005 are warnings that become errors under `--error-on-warning`. In project mode, lint prints a summary at the end: `"K file(s) clean"` or `"N error(s), M warning(s) in K file(s)"`.

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
