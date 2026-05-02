# 13 — Tutorial

A guided introduction to Lyric for newcomers.  Each section is a
small, runnable program that builds on the previous one; the goal
is to get you typing real code in 30 minutes, not to enumerate
every language feature (`docs/01-language-reference.md` is the
authoritative spec; `docs/02-worked-examples.md` is the gallery).

This tutorial assumes you have the bootstrap compiler built (see
`README.md`):

```
cd compiler
dotnet build Lyric.sln
```

You'll run programs with `dotnet run --project src/Lyric.Cli -- run
path/to/program.l` (or build a standalone binary with
`lyric build path/to/program.l`).

---

## 1. Hello, world

Save this as `hello.l`:

```
package Hello

func main(): Unit {
  println("hello, world")
}
```

Run it:

```
dotnet run --project src/Lyric.Cli -- run hello.l
```

You should see:

```
hello, world
```

A few things to notice:

- Every Lyric source file starts with a **package** declaration.
  The file's path on disk doesn't matter; the package name does.
- `func main(): Unit { ... }` declares the entry point.  `Unit`
  is Lyric's "no return value" — equivalent to `void` in C# or
  Java.
- `println` writes a string to standard output, followed by a
  newline.  No `import` is needed for this — `Std.Core` is
  always implicitly available.

---

## 2. Records and basic functions

Lyric's primary data structure is the **record** — a named
collection of named fields.

```
package Greet

pub record User {
  name: String
  age: Int
}

pub func greet(u: in User): String {
  "hello, " + u.name + " (age " + toString(u.age) + ")"
}

func main(): Unit {
  val alice = User(name = "Alice", age = 30)
  println(greet(alice))
}
```

Output:

```
hello, Alice (age 30)
```

Things to notice:

- **`pub`** marks a declaration as part of the package's public
  surface.  Other packages can `import Greet` and call `greet`
  directly; non-`pub` items are package-private.
- **`val`** binds an immutable name.  Lyric also has `var` for
  mutable bindings and `let` for runtime-evaluated constants.
- **`in`** on a parameter means "by-value, the callee can't
  modify it."  `out` and `inout` are also available; the mode
  is part of the signature.
- Record construction uses **named arguments**:
  `User(name = "Alice", age = 30)` — positional construction
  is also supported but named is preferred for clarity.

---

## 3. Sum types and pattern matching

Lyric has tagged unions (sum types) for "this value is one of
several alternatives":

```
package Shape

pub union Shape {
  case Circle(radius: Double)
  case Rect(width: Double, height: Double)
}

pub func area(s: in Shape): Double {
  match s {
    case Circle(r)        -> 3.14159265 * r * r
    case Rect(w, h)       -> w * h
  }
}

func main(): Unit {
  println(toString(area(Circle(radius = 5.0))))
  println(toString(area(Rect(width = 3.0, height = 4.0))))
}
```

Output:

```
78.539815
12
```

The compiler **enforces exhaustiveness**: if you forget a case
in the `match`, the program won't compile.  This is one of
Lyric's safety guarantees.

`Std.Core` provides two ubiquitous unions out of the box:

```
generic[T] union Option {
  case Some(value: T)
  case None
}

generic[T, E] union Result {
  case Ok(value: T)
  case Err(error: E)
}
```

Use `Option[T]` instead of nullable references; use `Result[T, E]`
for fallible operations.

---

## 4. Generics and `where` clauses

Lyric's generics work like Rust's or Kotlin's — fully reified at
runtime, with type parameters that can be constrained:

```
package GenDemo

generic[T] func first(xs: in slice[T]): Option[T] {
  if xs.length > 0 {
    Some(value = xs[0])
  } else {
    None
  }
}

func main(): Unit {
  match first[Int]([1, 2, 3]) {
    case Some(v) -> println(toString(v))
    case None    -> println("empty")
  }
  match first[String]([]) {
    case Some(v) -> println(v)
    case None    -> println("empty")
  }
}
```

Output:

```
1
empty
```

The bracket-list `[1, 2, 3]` constructs a **slice** (`slice[Int]`),
which is Lyric's go-to dynamic-length container.  Slices support
indexing (`xs[0]`), length (`xs.length`), and iteration (`for x in
xs { ... }`).

---

## 5. Async / await

Async functions run as state machines and integrate with .NET's
`Task` infrastructure.  Mark a function `async` and use `await`
to wait for another async value:

```
package AsyncDemo

extern type Task = "System.Threading.Tasks.Task"

async func sleeps(ms: in Int): Unit {
  await Task.Delay(ms)
}

async func count(): Unit {
  println("one")
  await sleeps(50)
  println("two")
  await sleeps(50)
  println("three")
}

func main(): Unit {
  await count()
}
```

Output (with 50 ms pauses between lines):

```
one
two
three
```

For a more substantial example — async with `try`/`catch`,
`defer`, and a `for` loop — see `docs/02-worked-examples.md`
example #5 ("Stream processing pipeline").  All three control
constructs lower to real Roslyn-equivalent state-machine IL
(D-progress-056 / 057 / 058).

---

## 6. File I/O and JSON

Lyric's standard library wraps the .NET BCL behind safety-
oriented APIs that surface failures as `Result` instead of
throwing exceptions:

```
package FileDemo

import Std.File
import Std.Core

func main(): Unit {
  match writeText("/tmp/lyric-tutorial.txt", "from Lyric") {
    case Ok(_)  -> println("wrote")
    case Err(_) -> println("write failed")
  }
  match readText("/tmp/lyric-tutorial.txt") {
    case Ok(text) -> println(text)
    case Err(_)   -> println("read failed")
  }
}
```

For JSON, annotate a record with `@derive(Json)` and the compiler
synthesises `toJson` and `fromJson`:

```
package JsonDemo

import Std.Core

@derive(Json)
pub record User {
  name: String
  age: Int
}

func main(): Unit {
  val alice = User(name = "Alice", age = 30)
  val s = User.toJson(alice)
  println(s)
  val parsed = User.fromJson(s)
  println(parsed.name)
}
```

Output:

```
{"name":"Alice","age":30}
Alice
```

Nested records, primitive slices, and round-tripping work out
of the box (D-progress-060).

---

## 7. Testing

Lyric ships built-in test helpers in `Std.Testing` and
`Std.Testing.Snapshot` and `Std.Testing.Property`.  These
land alongside the language; no test runner to install
separately.

### Equality assertions

```
package TestDemo

import Std.Testing

func main(): Unit {
  assertEqual(toString(1 + 1), "2", "addition works")
  assertEqualInt(2 + 2, 4, "still adding")
  assertTrue(5 > 3, "ordering works")
  println("all assertions held")
}
```

### Snapshot testing

`snapshot(label, actual)` compares the actual output against
`snapshots/<label>.txt`.  The first run captures the file; later
runs compare.

```
package SnapDemo

import Std.Testing.Snapshot

func main(): Unit {
  val output = "captured " + toString(42)
  snapshotMatch("demo", output)
  println("snapshot ok")
}
```

After the first run you'll find `snapshots/demo.txt` containing
`captured 42`; commit that file alongside your test source.

### Property-based testing

For invariants that should hold over many inputs, use a property:

```
package PropDemo

import Std.Random
import Std.Testing.Property

func main(): Unit {
  val rng = makeRandom(42)
  forAllIntRange(rng, -100, 100, 200,
    { x: Int -> (x + x) % 2 == 0 })
  println("doubling preserves parity")
}
```

The `rng` is seeded so test runs are deterministic; bump the
seed (or replace with `sharedRandom()`) if you want variation.

---

## Where next

- **Reference**: `docs/01-language-reference.md` describes every
  syntactic construct and its semantics.
- **Worked examples**: `docs/02-worked-examples.md` shows
  multi-file, realistic programs (banking, streaming, REST).
- **Decision log**: `docs/03-decision-log.md` explains *why* the
  language looks the way it does — useful when something
  surprises you.
- **Bootstrap progress**: `docs/10-bootstrap-progress.md`
  tracks what's actually shipping in the bootstrap compiler
  (Phase 1) vs. deferred to Phase 2/3/4.
- **Standard library**: source lives in `compiler/lyric/std/`.
  Each `.l` file is the authoritative API for its package; the
  doc comments are surfaced by `lyric doc <file>`.

Read in that order if you're going deep.  Keep this tutorial
open in a tab while you write your first 100 lines — the
`Std.Core` patterns (`Result`, `Option`, `match` exhaustiveness)
are the muscle memory you'll lean on most.
