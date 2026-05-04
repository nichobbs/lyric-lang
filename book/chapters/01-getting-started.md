# Getting Started

Before you can write Lyric, you need a working compiler. This chapter gets you from zero to a compiled and running program. Along the way you will meet the basic anatomy of a Lyric source file, the handful of tools you will use constantly, and what Lyric errors look like when they occur.

## Building the compiler

Lyric is self-hosted in the sense that it targets .NET, and the bootstrap compiler is written in F#. You will need the .NET 10 SDK, then a single build command.

```sh
# Clone the repository (if you haven't already)
git clone https://github.com/nichobbs/lyric-lang
cd lyric-lang

# Build everything
cd compiler
dotnet build Lyric.sln
```

The first build downloads NuGet dependencies and compiles the compiler itself. Subsequent builds are incremental and take a few seconds.

Once built, the `lyric` command is available via `dotnet run`:

```sh
dotnet run --project src/Lyric.Cli -- --help
```

For convenience, you can install the CLI as a global .NET tool or add a shell alias:

```sh
# Option A: alias (put in your .bashrc / .zshrc)
alias lyric='dotnet run --project /path/to/compiler/src/Lyric.Cli --'

# Option B: publish as a self-contained binary (see compiler/src/Lyric.Cli)
dotnet publish src/Lyric.Cli -c Release -o ~/bin/lyric
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

For release binaries:

```sh
lyric build --release hello.l
lyric build --aot    hello.l    # Native AOT, no .NET runtime needed at deployment
```

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

- Named construction: `User(name = "Alice", age = 30)`. Positional construction works too, but named is idiomatic.
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
**Why mandatory parameter modes?** In C# and Java, pass-by-reference and pass-by-value are implicit. A `ref` parameter in C# is visible at the call site (`func(ref x)`) but nothing in the signature tells a reader whether the function reads the value, writes it, or both. Lyric's `in`/`out`/`inout` make this explicit in every signature, which is useful both for readability and for the proof system (a `requires:` clause on an `in` parameter is cleaner when you can trust the parameter won't be mutated). The decision to require explicit modes even for the common `in` case was made because the formatter enforces the convention anyway — you see it or the code doesn't format.
:::

## The toolchain at a glance

You will use four commands constantly:

| Command | What it does |
|---------|-------------|
| `lyric build <file.l>` | Compile; produce a `.dll` |
| `lyric run <file.l>` | Compile and immediately execute |
| `lyric test` | Run `test` and `property` declarations in `@test_module` packages |
| `lyric fmt` | Format source code to the standard style |
| `lyric doc <file.l>` | Generate HTML documentation from doc comments |
| `lyric prove <file.l>` | Run the SMT-backed verifier on `@proof_required` modules |

`lyric fmt` is opinionated and has no configuration. The format is the format. Run it on save.

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

Write doc comments on every `pub` declaration. The `lyric doc` command generates browsable HTML from them, including your `requires` and `ensures` clauses. Doc comments are also checked for code examples by `lyric test --doctests`.

## Exercises

1. **Different entry points**

   Lyric's `main` function name is a convention, not a keyword. What happens if you rename it to `run`? Try it and see what error the compiler produces. Then look up how `lyric build --entrypoint` changes the convention.

2. **Named vs positional construction**

   Create a `record Point { x: Double; y: Double }` and construct one using positional arguments (`Point(1.0, 2.0)`). Does it compile? Is the result the same as `Point(x = 1.0, y = 2.0)`? What do you think the tradeoff is between the two styles?

3. **Mutating with `var`**

   Write a function that takes a mutable counter (`var count: Int`) and increments it three times in a loop, printing the value after each increment. Notice that the `for i in 0 ..< 3` syntax gives you a range of integers.

4. **Exhaustiveness**

   Add a `Triangle(base: Double, height: Double)` case to the `Shape` union from the error example above. Observe every place the compiler complains. Fix them. How does this compare to adding a new case to a C# enum?

5. **Format style**

   Write a function with poor formatting — inconsistent spacing, misaligned `=` signs, or a mix of tab and space indentation. Run `lyric fmt` on it. What changed? What didn't?
