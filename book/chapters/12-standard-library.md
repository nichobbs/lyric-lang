# The Standard Library

Lyric ships a curated standard library that covers the runtime needs of application development without exposing the full .NET BCL surface. The design goal is a library you can use without surprises: predictable error handling, no hidden exceptions, and a consistent interface story for anything that touches the outside world.

A thread you will notice running through the library is that anything involving I/O — files, HTTP, time — is expressed as an interface rather than a concrete type. `Std.File` exports functions, but `Std.Time` exports a `Clock` interface alongside the concrete `SystemClock`. This is not incidental. It is what makes tests easy: inject the real implementation in production, inject a stub in tests. Chapter 15 covers the testing infrastructure; this chapter covers the library itself.

The stdlib is separate from the compiler and versioned independently. Every `pub` item carries a `@stable` or `@experimental` annotation. If something is marked `@experimental`, expect its shape to change before v1.0.

## §12.1 How the stdlib is structured

The standard library lives in `compiler/lyric/std/`. Each module is a `.l` file; you import a module with `import Std.X`, where `X` is the module name. The compiler locates the source file, compiles it on demand, and links the produced assembly into your output.

Here is the full module inventory:

| Module | Contents |
|--------|----------|
| `Std.Core` | `Result`, `Option`, built-in ops — always implicitly available for `println` etc. |
| `Std.String` | `trim`, `split`, `join`, case conversion, `substring`, `startsWith`, `endsWith` |
| `Std.Parse` | `tryParseInt`, `tryParseLong`, `tryParseDouble`, `tryParseBool` |
| `Std.Errors` | `ParseError`, `IOError`, `HttpError` |
| `Std.File` | `readText`, `writeText`, `fileExists`, `createDir` |
| `Std.Collections` | `List[T]`, `Map[K, V]` |
| `Std.Math` | `abs`, `sqrt`, `pow`, `min`, `max`, trigonometric functions |
| `Std.Random` | seeded RNG: `makeRandom`, `nextInt`, `nextDouble` |
| `Std.Time` | `Instant`, `Duration`, `Clock` interface, ISO 8601 parsing |
| `Std.Json` | `toJson`, `fromJson` for `@derive(Json)` types |
| `Std.Http` | HTTP client and server primitives |
| `Std.Testing` | `assertEqual`, `assertTrue`, `assertEqualInt`, snapshot, property |
| `Std.Iter` | `map`, `filter`, `fold`, `zip`, `take`, `drop` over slices |

The `Std.Core` module is special: `println`, `panic`, `assert`, `toString`, and a few others are codegen builtins — the compiler emits calls to them directly, so they are available without an explicit import. Everything else in the table requires an explicit `import`.

## §12.2 `Std.Core` — Result, Option, and the builtins

`Result[T, E]` and `Option[T]` are the backbone of Lyric's error handling and optional-value story. Both are always in scope; you do not need to import them. The key operations on `Result`:

```lyric
val r: Result[Int, String] = Ok(42)
val doubled   = r.map     { v -> v * 2 }           // Result[Int, String]
val mapped    = r.mapErr  { e -> e.length }         // Result[Int, Int]
val flattened = r.flatMap { v -> Ok(v + 1) }        // Result[Int, String]
val orDefault = r.unwrapOr(0)                       // Int
```

`map` transforms the success value, `mapErr` transforms the error value, `flatMap` chains a fallible operation. `unwrapOr` extracts the value or returns a default if the result is `Err`. If you want to propagate an error rather than handle it, the `?` operator does that:

```lyric
func doWork(): Result[Int, String] {
  val x = riskyOperation()?      // returns Err early if riskyOperation fails
  return Ok(x + 1)
}
```

`Option` works analogously:

```lyric
val opt: Option[String] = Some("hello")
val upper    = opt.map     { s -> s.toUpper() }    // Option[String]
val fallback = opt.unwrapOr("default")             // String
val found    = opt.isSome                          // Bool
```

The codegen builtins available without any import:

- `println(s: String)` — write to stdout with a trailing newline
- `panic(msg: String)` — raise a `Bug` immediately; no recovery
- `assert(cond: Bool, msg: String)` — panic if `cond` is false
- `toString(x)` — produce a `String` representation of any value
- `format1(template, a)` through `format4(template, a, b, c, d)` — `String.Format`-style substitution using `{0}`, `{1}`, etc. as placeholders
- `default()` — zero-initialise a value for the contextual type; useful when a `var` needs an initial sentinel

For anything beyond these, you reach for the specific `Std` module.

## §12.3 `Std.String`

```lyric
import Std.String

val parts   = split("a,b,c", ",")           // slice[String]: ["a", "b", "c"]
val joined  = join(" | ", parts)            // "a | b | c"
val trimmed = trim("  hello  ")             // "hello"
val upper   = toUpper("hello")              // "HELLO"
val sub     = substring("hello", 1, 3)      // "el"
val starts  = startsWith("hello", "he")     // true
val ends    = endsWith("hello", "lo")       // true
```

`split` and `join` are counterparts: `split` takes a string and a separator, `join` takes a separator and a `slice[String]`. `substring(s, start, end)` follows the half-open convention (`start` inclusive, `end` exclusive) — the same convention slices use everywhere in Lyric. Indices out of range produce a `Bug`, not a silently truncated result, so validate before calling if the inputs are not known at compile time.

`Std.String` also exports `toLower`, `contains`, `replace`, and `padLeft`/`padRight`. The full API is in `compiler/lyric/std/string.l`.

## §12.4 `Std.Collections`

```lyric
import Std.Collections

var list: List[String] = List.empty()
list.add("alpha")
list.add("beta")
println(toString(list.count))               // 2

val m: Map[String, Int] = Map.empty()
m.set("age", 30)
val age    = m.get("age")                   // Option[Int]
val exists = m.containsKey("age")           // Bool
```

`List[T]` is a growable list backed by .NET's `List<T>`. `Map[K, V]` is a hash map backed by `Dictionary<K, V>`. Both support `for x in collection` iteration.

`m.get(key)` returns `Option[Int]`, not a nullable value and not a thrown exception. You pattern-match on it:

```lyric
match m.get("age") {
  case Some(v) -> println(format1("age is {0}", toString(v)))
  case None    -> println("key not found")
}
```

`List[T]` also has `remove(index)`, `get(index)` (returns `Option[T]`), and `toSlice()` for converting to an immutable slice. If you need to remove by value rather than by index, use `Std.Iter` to filter and rebuild.

::: sidebar
**Why not immutable collections by default?** The decision log entry D038 frames the stdlib as evolving toward native Lyric implementations with verifiable invariants. Immutable persistent data structures are on that roadmap. For now, `List[T]` and `Map[K, V]` are the mutable BCL-backed forms, which are the right default for most application code. Immutable variants — once shipped — will carry the same names under a different import (`Std.Immutable` is the current proposal). The module inventory note says "immutable/persistent variants" are in scope; they are not yet `@stable`.
:::

## §12.5 `Std.Time`

```lyric
import Std.Time

val now: Instant = SystemClock.now()
val later = now.plusSeconds(30)
val diff: Duration = Duration.between(now, later)
println(toString(diff.seconds()))           // 30

val parsed    = Instant.fromIso8601("2026-04-29T00:00:00Z")?
val formatted = parsed.toIso8601()
```

`Instant` represents a point in time as an opaque value; you do not construct one from raw numbers. `Duration` has `seconds()`, `millis()`, and `nanos()` accessors. `Duration.between(a, b)` is always non-negative — it returns the absolute difference; if `a` is after `b`, the result is still positive.

`Instant.fromIso8601` returns `Result[Instant, ParseError]`. The `?` propagates the error if parsing fails. If you are parsing user input, you will always want to handle the `Err` case explicitly.

The `Clock` interface is what testability depends on:

```lyric
pub interface Clock {
  func now(): Instant
}
```

Your service takes a `clock: in Clock` parameter. In production you pass `SystemClock`. In a test you pass a `ClockStub` that returns a fixed instant. Chapter 15 shows the full pattern; the point here is that the interface exists in `Std.Time` and `SystemClock` implements it — you do not need to write the interface yourself.

## §12.6 `Std.File`

```lyric
import Std.File

match writeText("/tmp/output.txt", "hello from Lyric") {
  case Ok(_)  -> println("written")
  case Err(e) -> println(format1("error: {0}", toString(e)))
}

match readText("/tmp/output.txt") {
  case Ok(text) -> println(text)
  case Err(e)   -> println(format1("read error: {0}", toString(e)))
}

val exists = fileExists("/tmp/output.txt")   // Bool, not Result
```

Every operation that can fail returns `Result`. `fileExists` is the exception: it returns `Bool` directly, because a check that says "the file was there when I asked" is already racy, and wrapping it in `Result` would invite code that treats `Err` as "the file doesn't exist" when `Err` actually means "the OS refused to answer."

Path strings are unchecked at compile time. The compiler does not know whether `/tmp/output.txt` is a valid path on the target system. If you are constructing paths from user input, validate them before passing them in.

::: note
**Note:** `Std.File` is a Lyric wrapper around `System.IO.File`. Its `@axiom` block is in `compiler/lyric/std/file.l`. If you are calling it in a `@proof_required` module, the prover will trust the axiom contracts and not check them. Chapter 13 explains what that means and when it matters.
:::

## §12.7 JSON with `@derive`

`@derive(Json)` generates `toJson` and `fromJson` at compile time. No reflection, no runtime type inspection — the serializer is source-generated and AOT-compatible.

```lyric
import Std.Core

@derive(Json)
pub exposed record Order {
  id:          String
  customerId:  String
  totalCents:  Long
  items:       slice[String]
}

func main(): Unit {
  val order = Order(
    id          = "ord-1",
    customerId  = "cust-42",
    totalCents  = 1500,
    items       = ["item-a", "item-b"]
  )

  val json = Order.toJson(order)
  println(json)

  match Order.fromJson(json) {
    case Ok(parsed) -> println(format1("id: {0}", parsed.id))
    case Err(_)     -> println("parse error")
  }
}
```

`toJson` is a static method on the type, not a method on an instance — `Order.toJson(order)`, not `order.toJson()`. This is because the compiler generates the function into the type's namespace, and calling it as a static makes the generated nature explicit.

Nested records work if each nested type is also `@derive(Json)`. `Option[T]` fields round-trip as `null` in JSON. Slices of primitives and slices of `@derive(Json)` records both work. What does not work: `Map[K, V]` with non-`String` keys (JSON object keys must be strings), `opaque` types (their representation is not visible), and types with `inout` or `out` fields (those are parameter modes, not field modifiers).

If you need to serialise an opaque type across a boundary, the idiomatic pattern is to project it to an `exposed record` first, then derive JSON on the exposed form. Example 5 in `docs/02-worked-examples.md` shows this pattern with `RawConfig` and `AppConfig`.

## §12.8 `Std.Http`

The HTTP module is interface-based. You inject it the same way you inject `Clock`:

```lyric
import Std.Http

pub interface HttpClient {
  async func get(url: in String): Result[HttpResponse, HttpError]
  async func post(url: in String, body: in String): Result[HttpResponse, HttpError]
}
```

`HttpResponse` has a `statusCode: Int` and a `body: String`. `HttpError` is defined in `Std.Errors`.

The real `HttpClient` implementation wraps `System.Net.Http.HttpClient`. In production you wire it through your `wire` block. In tests you inject a stub that returns canned responses. Chapter 13 covers the FFI aspect of this wrapping; Chapter 15 covers the test stub pattern.

There is also a server-side surface in `Std.Http` for handling inbound requests, but it is `@experimental` and its shape is still being settled. For production HTTP service code, the current recommendation is to use the `Std.Http.HttpClient` interface for outbound calls and handle routing at the framework level.

## Exercises

1. Write a program that reads a comma-separated list of names from a file, splits on `,`, trims each name, converts to uppercase, and writes the results back out, one per line.

2. Build a `Map[String, Int]` word-frequency counter: read a string, split on spaces, and count how many times each word appears. Print each word and its count.

3. Write a function that takes a `slice[Order]` (from §12.7) and serialises each to JSON, then assembles a JSON array string. Do not call a JSON array function — build the array by joining the individual `Order.toJson` results with `,` and wrapping in `[` and `]`.

4. The `Clock` interface allows dependency injection. Write a function `isExpired(createdAt: in Instant, ttl: in Duration, clock: in Clock): Bool` and call it once with `SystemClock` and once with a stub that returns a fixed `Instant` you control. Observe that the function's behaviour is fully determined by its inputs when the clock is injected.

5. `Std.Iter` provides `filter` and `map` over slices. Rewrite the word counter from exercise 2 using `filter` to exclude empty strings before counting, and `fold` to accumulate the map. Compare the result to the imperative version.
