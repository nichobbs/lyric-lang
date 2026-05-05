# Data Structures

With the core types established, you have the atoms. This chapter covers how Lyric lets you combine them. Records, unions, enums, tuples, arrays, slices — these are the vocabulary of every Lyric program. If you have used Kotlin data classes, C# records, Rust enums, or TypeScript discriminated unions, most of this will feel familiar in concept while differing in some specifics. Where Lyric diverges, it does so for reasons worth understanding.

The organizing principle is that structure should match meaning. A record models a thing with named parts. A union models a value that can be one of several distinct alternatives. An enum models a small fixed set of named constants. The division is not arbitrary. Choosing the right structure makes the code easier to read, and makes the compiler's exhaustiveness checking do more work for you.

## §3.1 Records

Records are the primary way to group named data in Lyric. You have already seen them in Chapter 1. Here they are in slightly more detail.

```lyric
record Point {
  x: Double
  y: Double
}

record Customer {
  id: CustomerId
  email: Email
  joinedAt: Instant
  isActive: Bool
}
```

Records are constructed with named fields. Positional construction is not allowed — named construction is the only form:

```lyric
val p = Point(x = 1.0, y = 2.0)
val c = Customer(
  id       = CustomerId.from(42),
  email    = Email.from("alice@example.com")?,
  joinedAt = clock.now(),
  isActive = true
)
```

**Non-destructive update** uses `.copy()`. It produces a new record with the specified fields changed and everything else unchanged:

```lyric
val p2 = p.copy(x = 3.0)        // p.y is preserved; p is unchanged
val inactive = c.copy(isActive = false)
```

**Structural equality.** Two records are equal if and only if all their fields are equal. You do not implement `equals` or override `hashCode`. For a `Point`, `Point(x = 1.0, y = 2.0) == Point(x = 1.0, y = 2.0)` is always `true`.

**Visibility.** By default, all fields are visible within the package. `pub` on the record itself makes the record type visible to other packages. `pub` on an individual field makes that field accessible outside the package:

```lyric
pub record Customer {
  pub id: CustomerId      // readable from outside the package
  pub email: Email        // readable from outside
  joinedAt: Instant       // package-internal
  isActive: Bool          // package-internal
}
```

If you want full encapsulation with invariants, use `opaque type` instead — Chapter 9 covers that in depth.

**Records are immutable.** Once constructed, a record's fields cannot be reassigned. There is no `customer.isActive = false`. Use `.copy()` or use an `opaque type` with controlled mutation through functions.

**The `@valueType` annotation** is a hint to the compiler that this record should be lowered to a .NET `readonly struct` rather than a `record class`. This is appropriate for small, frequently-allocated records — coordinates, sizes, colours — where avoiding heap allocation matters:

```lyric
pub record Vec2 @valueType {
  x: Double
  y: Double
}
```

The compiler will reject `@valueType` on records that contain reference-type fields or exceed a platform-dependent size threshold. For most domain records, leave the annotation off and let the compiler decide.

## §3.2 Unions

Unions are sum types — a value of a union type is exactly one of its declared cases. Each case can carry different data.

```lyric
union Shape {
  case Circle(radius: Double)
  case Rectangle(width: Double, height: Double)
  case Triangle(base: Double, height: Double)
}
```

You construct a union value by naming the case:

```lyric
val circle: Shape    = Circle(radius = 5.0)
val rect: Shape      = Rectangle(width = 3.0, height = 4.0)
val triangle: Shape  = Triangle(base = 6.0, height = 8.0)
```

The only way to access the payload is through a `match`. The compiler requires the match to be exhaustive — every case must be handled, or there must be a wildcard:

```lyric
func area(s: in Shape): Double {
  return match s {
    case Circle(r)         -> 3.14159 * r * r
    case Rectangle(w, h)   -> w * h
    case Triangle(b, h)    -> 0.5 * b * h
  }
}
```

If you forget a case, the compiler tells you which one:

```
shapes.l:8:10: error E0301: non-exhaustive match
  missing case: Triangle
  note: if you intend to ignore this case, use: case _ ->
```

You saw this error in Chapter 1. In this chapter, it is important to understand *why* this matters for unions specifically.

**The built-in `Result[T, E]` and `Option[T]` are unions.** You have already used them. Now that you know what a union is, you can read their declarations:

```lyric
union Result[T, E] {
  case Ok(value: T)
  case Err(error: E)
}

union Option[T] {
  case Some(value: T)
  case None
}
```

There is nothing special about them from the language's perspective. They are generic unions, exactly like `Shape`. Generics are covered in Chapter 6.

**Public unions and breaking changes.** When you mark a union `pub`, its case list becomes part of your package's public contract. Adding a new case to a `pub` union is a breaking change — every `match` in every caller must handle the new case, and the compiler will refuse to compile them until they do. This is intentional. A new case represents a genuinely new possibility that callers must handle. Silently ignoring it would be a bug.

::: sidebar
**Why is adding a new union variant a breaking change?**

At first this can feel restrictive. In an object-oriented style, adding a new subclass is usually backward-compatible — callers don't have to know about it if they dispatch through an interface method.

The difference is in what you are modelling. A union case is a *complete enumeration of possibilities*, and the compiler's exhaustiveness check is based on that being complete. If you add a case to a public union, callers have existing `match` expressions that cover all cases — except the one you just added. Those expressions are now silently wrong if there's a wildcard, or correctly broken if there isn't.

Correctly broken is what you want. Compare this to adding a new method to an interface: every implementor gets a compile error until they add the method. That is also correct behavior. Unions give you the same guarantee in the opposite direction: the data structure gains a new form, and every consumer gets a compile error until they handle it.

The tradeoff is real: if you have a public union that you expect to extend frequently, consider whether an interface with `impl` is a better fit. Chapter 6 covers that choice in detail.
:::

## §3.3 Enums

Enums are unions with no payload. They are the natural fit for a small, fixed set of named constants.

```lyric
enum Color {
  case Red
  case Green
  case Blue
}

enum Direction {
  case North
  case South
  case East
  case West
}
```

Construction and use are the same as unions:

```lyric
val c: Color = Color.Red
val d: Direction = Direction.North

func opposite(d: in Direction): Direction {
  return match d {
    case North -> South
    case South -> North
    case East  -> West
    case West  -> East
  }
}
```

Enums are distinct from integers. There is no implicit conversion between `Color` and any numeric type. To get the underlying integer (for interop or serialization), use `.toInt()`. To go the other direction, use `Color.fromInt(n)`, which returns `Option[Color]` — not every integer is a valid color, so the conversion can fail.

```lyric
val n: Int = Color.Green.toInt()        // 1 (by declaration order, zero-indexed)
val c: Option[Color] = Color.fromInt(5) // None — no Color with index 5
```

This is a deliberate difference from C# or Java enums, where the int-to-enum cast silently succeeds for any value. The explicit conversion with an `Option` result forces you to handle the invalid case. Chapter 7 covers error handling in more detail.

## §3.4 Tuples

Tuples are anonymous structural types. They let a function return multiple values without defining a record.

```lyric
val pair: (Int, String) = (42, "hello")
val triple: (Bool, Int, String) = (true, 0, "ok")
```

Tuple elements are accessed positionally, but the more common pattern is destructuring:

```lyric
val (n, s) = pair           // n: Int = 42, s: String = "hello"
val (ok, code, msg) = triple
```

Tuples work well as function return types when a function produces two or three closely related values and naming a whole record would be over-engineering:

```lyric
func minMax(xs: in slice[Int]): (Int, Int)
  requires: xs.length > 0
{
  var lo = xs[0]
  var hi = xs[0]
  for x in xs {
    if x < lo { lo = x }
    if x > hi { hi = x }
  }
  return (lo, hi)
}

val (smallest, largest) = minMax([3, 1, 4, 1, 5, 9])
```

Use tuples sparingly. If you find yourself writing `(UserId, Instant, String)` and the meaning of each element is not immediately obvious at the call site, that is a signal that a named record would be clearer. The rule of thumb: tuples for small, local, and obvious groupings; records for anything that crosses function or package boundaries.

::: note
**Note:** Lyric does not support tuple indexing with `.0`, `.1` etc. If you need to access elements without destructuring, define a record with named fields. The omission is intentional — named access is always clearer than positional access for anything beyond two elements.
:::

## §3.5 Arrays and slices

Lyric distinguishes between two collection types with different tradeoffs.

**Arrays** are fixed-size and length is part of the type. They are value types — they live on the stack (or inline in a containing struct) and have no heap allocation.

```lyric
val bytes: array[16, Byte]        // 16 bytes, length in type
val zeros: array[4, Int] = [0, 0, 0, 0]
```

The length is known at compile time. `array[16, Byte]` and `array[32, Byte]` are different types.

**Slices** are dynamically sized, heap-allocated sequences. They are reference types backed by .NET's `List<T>`.

```lyric
val xs: slice[Int]             // empty by default
val ys: slice[Int] = [1, 2, 3] // literal syntax; type inferred
val zs = [1, 2, 3]             // type inferred as slice[Int]
```

Slices support the operations you expect:

```lyric
val n  = xs.length               // Nat
val v  = xs[2]                   // Int; panics if out of bounds
val ys = xs.append(42)           // new slice with 42 appended
val zs = xs.concat(ys)           // concatenation
val sl = xs.slice(1, 3)          // sub-slice [1, 3)
for x in xs { println("${x}") } // iteration
```

There is no in-place mutation. `append` and `concat` produce new slices.

**Bounds checking and range subtypes.** Array and slice indexing is bounds-checked at runtime. But if the index type's range statically proves the access is in bounds, the compiler elides the check entirely:

```lyric
val xs: array[100, Int]
val i: Int range 0 ..= 99 = ...
val v = xs[i]                    // bounds check elided — proven safe by type
```

With a plain `Int` index, you get the runtime check and the compiler will not guarantee it's safe:

```lyric
val j: Int = computeIndex()
val w = xs[j]                    // bounds check happens at runtime; may panic
```

This is the payoff that §2.2 previewed. A range-typed index is not just documentation — it eliminates real overhead in hot paths. The type does the work.

## §3.6 Choosing the right structure

Every data modelling problem in Lyric involves a choice between these forms. Here is a quick guide.

| If you need to... | Use |
|---|---|
| Group named fields with invariants | `record` (or `opaque type` for stronger encapsulation — Chapter 9) |
| Express "a value is one of N alternatives" | `union` |
| Name a small fixed set of constants | `enum` |
| Return two or three values from a function | tuple |
| Store a fixed number of same-type values | `array[N, T]` |
| Store a variable number of same-type values | `slice[T]` |

The most common mistake when coming from an OO background is to model everything as records and add a discriminator field (`kind: String` or a tag enum). Unions are the right tool for "one of several things." The compiler's exhaustiveness checking makes them safer than the OO pattern, not just differently organized.

If you find yourself adding a `None` or `null` field to a record, that is usually a signal that you want `Option[T]` in the field type, or a union with two cases — one that has the field and one that doesn't.

## Exercises

1. Define a `union HttpStatus` with at least five cases: `case Ok(body: String)`, `case Created(location: String)`, `case NotFound`, `case BadRequest(message: String)`, and `case ServerError(message: String)`. Write a function `statusCode(s: in HttpStatus): Int` that returns the appropriate HTTP status integer for each case.

2. Add a `@valueType` annotation to `record Point { x: Double; y: Double }`. Run `lyric build --verbose`. What does the output say about the .NET representation? If you have `ildasm` or `dotnet-ildasm` available, inspect the emitted type and confirm it is a struct.

3. Write a function `divmod(a: in Int, b: in Int): (Int, Int)` that returns the quotient and remainder. Call it and destructure the result. Then refactor: define `record DivResult { quotient: Int; remainder: Int }` and return that instead. Which feels cleaner? Under what circumstances would you prefer one over the other?

4. Build a `slice[String]` from three string literals. Append one more element. Concatenate it with another slice of two strings. Iterate over the result with `for` and print each element. Verify the final length is 6.

5. The `Result` union is generic: `Result[T, E]`. Define a `union ParseError { case Empty; case InvalidChar(c: Char); case TooLong(maxLen: Nat) }`. Write a function `parseUsername(s: in String): Result[String, ParseError]` that returns `Err(Empty)` for an empty string, `Err(TooLong(...))` if the string exceeds 32 characters, and `Ok(s)` otherwise. Write a `match` on the return value that prints a human-readable message for each case.
