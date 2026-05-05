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

## 8. Verifying the banking example

This section is a step-by-step walkthrough for marking the banking
transfer example `@proof_required` and discharging its VCs with
`lyric prove`.  It assumes you have read sections 1–7 and are
comfortable with `requires:`/`ensures:` syntax.

### 8.1 What we are proving

The transfer domain has one key conservation invariant:

```
newFrom.balance + newTo.balance == from.balance + to.balance
```

Informally: money is neither created nor destroyed.  This should
hold for every successful `Transfer.execute` call.  We will make the
compiler *check* that — not just assert it at runtime.

### 8.2 Annotating the package

Change the first line of each domain file:

```
@proof_required          // was: @runtime_checked (or absent)
package Money
```

```
@proof_required
package Account
```

```
@proof_required
package Transfer
```

The application-layer file (`TransferService`) stays
`@runtime_checked`; it's allowed to call into proof-required
packages (the partial order permits it).

### 8.3 Running the verifier

```
cd compiler
lyric prove path/to/transfer.l
```

On a fresh, unannotated `transfer.l` the prover will immediately
complain about `execute`:

```
transfer.l:12:3: error V0008: ensures (conservation) — proof failed
  counterexample:
    from.balance : Int = 100
    to.balance   : Int = 50
    amount       : Int = 0
  falsified conclusion: newFrom.balance + newTo.balance == 150
```

The solver found an input where the postcondition is violated — in
this case because `debit` can return `Err` (insufficient funds), the
function returns early, and `newFrom`/`newTo` are never bound.

### 8.4 Writing the contracts for `debit` and `credit`

The key is to make `debit`'s postcondition strong enough that the
VC generator can derive the conservation property from it.  Add:

```
pub func debit(a: in Account, amount: in Amount): Result[Account, AccountError]
  ensures: result.isOk implies result.value.balance == a.balance - amountValue(amount)
  ensures: result.isErr implies a.balance < amountValue(amount)
```

And for `credit`:

```
pub func credit(a: in Account, amount: in Amount): Result[Account, AccountError]
  ensures: result.isOk implies result.value.balance == a.balance + amountValue(amount)
  ensures: result.isErr implies a.balance + amountValue(amount) > 1_000_000_000_00
```

### 8.5 Writing the contract for `execute`

```
pub func execute(
  from: in Account,
  to:   in Account,
  amount: in Amount
): Result[(Account, Account), TransferError]
  requires: from.id != to.id
  ensures: result.isOk implies {
    val (newFrom, newTo) = result.value
    newFrom.balance + newTo.balance == from.balance + to.balance
  }
```

The VC generator applies the Hoare call rule (§10.4 of
`docs/08-contract-semantics.md`): at each call to `debit`/`credit`
it asserts the callee's `requires:` and then *assumes* the callee's
`ensures:`.  From those assumed facts it derives the conservation
property and discharges the goal.

### 8.6 Checking with `--explain`

When the proof goes through you'll see:

```
transfer.l: @proof_required  1 goal  discharged (trivial discharger)
```

To inspect the goal IR before discharge:

```
lyric prove --explain --goal 0 transfer.l
```

This prints the Lyric-VC IR for goal 0 — the hypotheses (the
callee postconditions, substituted at the call sites) and the
conclusion (the conservation postcondition).

### 8.7 Machine-readable output

```
lyric prove --json transfer.l
```

Emits:

```json
{
  "file": "transfer.l",
  "level": "@proof_required",
  "goals": [
    {
      "index": 0,
      "label": "execute/ensures/conservation",
      "kind": "ensures",
      "outcome": "discharged",
      "model": null,
      "smtPath": null
    }
  ],
  "diagnostics": [],
  "summary": { "total": 1, "discharged": 1, "unknown": 0, "counterexamples": 0 }
}
```

The JSON surface is frozen as of M4.3; downstream tooling
(`lyric public-api-diff`, CI gates) can parse it reliably.

### 8.8 Checked arithmetic

For financial code that must not overflow, annotate:

```
@proof_required(checked_arithmetic)
package Account
```

In this mode every arithmetic operation on `Int` generates an
additional side condition that the result lies within `[Int.min,
Int.max]`.  The overflow VCs for `a.balance + amountValue(amount)`
inside `credit` will then be checked by the solver.

### 8.9 Escaping to `unsafe { }`

Occasionally a callee is too complex to discharge (for example, it
calls into a BCL method not in the decidable fragment).  Annotate:

```
@proof_required(unsafe_blocks_allowed)
package Transfer
```

Then wrap the problematic call in `unsafe { }` and assert the
postcondition you are manually confident holds:

```
unsafe {
  val raw = bcl_complex_thing(from)
  assert(raw.balance >= 0)
}
```

Inside `unsafe { }` the prover does not generate obligations for
the body; the `assert` becomes an *assumed* hypothesis for the rest
of the function.  The full V0009 rule prevents `assume` from
appearing outside `unsafe { }` in plain `@proof_required` packages,
ensuring every assumption is explicitly bracketed.

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
- **Proof plan**: `docs/15-phase-4-proof-plan.md` gives the full
  technical specification for the VC generator, SMT encoding, and
  solver architecture.
- **Axiom audit**: `docs/17-axiom-audit.md` lists every `@axiom`
  shipped in `std.bcl.*` with rationale and the invariants callers
  must uphold.

Read in that order if you're going deep.  Keep this tutorial
open in a tab while you write your first 100 lines — the
`Std.Core` patterns (`Result`, `Option`, `match` exhaustiveness)
are the muscle memory you'll lean on most.
