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

Arguments to `.copy` must be named, each naming a real field at most once, with a value the field accepts. The receiver and the arguments are evaluated once, left to right, and the copy is shallow: a `List` field in the copy is the same list as in the original. `c.copy()` with no arguments is a plain shallow copy.

**Function-typed fields.** A record can hold functions, and calling one looks like a method call: given `record Handler { apply: (Int) -> Int }`, `h.apply(2)` runs the function stored in `apply`. This is a convenient way to describe a program as data (an `update` and a `view` function, say) and pass it around as one value.

**Structural equality.** A record with no `var` field is a value, so `==` and `!=` compare it field by field: `Point(x = 1.0, y = 2.0) == Point(x = 1.0, y = 2.0)` is `true`, with no annotation needed. A field that is itself such a record is compared by its fields, a distinct type by its underlying value, and every other field with its own type's `==` (a `String` by its text, a union structurally). A `Double` or `Float` field is equal when `==` holds or both are `NaN`, so `0.0` equals `-0.0` and a record holding a `NaN` equals itself, while `==` on a bare `Double` stays IEEE. A record with a function-typed field has no `==` (**T0153**).

The same equality is used wherever a record is compared, not just by `==`:

- as a `Map` or `Set` key and by `List.contains`/`indexOf`;
- inside a union payload (`Some(p) == Some(q)`);
- through a type parameter (`func same[T](a: in T, b: in T): Bool = a == b`).

On dotnet and the JVM every such record gets matching `Equals`/`hashCode` overrides, so a key built separately is found:

```lyric
val seen: Map[Point, String] = newMap()
seen.add(Point(x = 1.0, y = 2.0), "origin-ish")
seen.containsKey(Point(x = 1.0, y = 2.0))   // true
```

A record with a `var` field keeps identity, as a key too, unless it derives `Equals`. Native `Map` keys must still be a `String` or a scalar (#8167).

A record with a `var` field has identity (see "Values and mutable records" in the reference): `==` asks whether two bindings refer to the same instance. Deriving `Equals` gives it field-by-field `==` instead:

```lyric
@derive(Equals)
record Account {
  var balance: Long
  owner: String
}
```

Unions (§3.2) get structural equality unconditionally, with no annotation required.

**Component-wise arithmetic.** A record whose fields all have the same numeric type can derive `Add` and `Sub`. `+` and `-` then work field by field on two values of that record:

```lyric
@derive(Add, Sub)
record Vec2 {
  x: Float
  y: Float
}

val a = Vec2(x = 1.0, y = 2.0)
val b = Vec2(x = 0.5, y = 0.5)
val c = a + b              // Vec2(x = 1.5, y = 2.5)
var p = a
p -= b                     // p is now Vec2(x = 0.5, y = 1.5)
```

That is the whole of operator support on records: there is no `Mul`, `Div` or `Mod`, and a record with fields of different types, a generic record or a record with an `invariant:` cannot derive `Add` or `Sub` (error T0152). Scaling, dot products and other vector operations are ordinary methods (`v.scale(2.0)`, `a.dot(b)`).

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

**Structural equality.** Unlike records (§3.1), unions get structural equality unconditionally — no `@derive(Equals)` annotation is needed, and this holds regardless of backing representation or whether the union is generic. Two case values are equal if and only if they are the same case with equal payloads:

```lyric
val a: Option[Int] = None
val b: Option[Int] = None
a == b                              // true

Some(value = 1) == Some(value = 1)  // true, even for independently-constructed values
Some(value = 1) == None             // false
```

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

Enums are distinct from integers. There is no implicit conversion between `Color` and any numeric type. To get the ordinal (for interop or serialization), use `.toNat()` — enum ordinals are always non-negative, so `Nat` is the right return type. To go the other direction, use `Color.fromNat(n)`, which returns `Option[Color]` — not every natural number is a valid color, so the conversion can fail.

> **Not yet shipped:** `toNat()` and `fromNat()` are specified but not yet synthesised by the compiler. They are planned for the v1.0 release. Until then, use an explicit `match` or cast via `@externTarget` for ordinal access.

```lyric
// Planned API (compiler support coming in v1.0):
val n: Nat = Color.Green.toNat()        // 1 (by declaration order, zero-indexed)
val c: Option[Color] = Color.fromNat(5) // None — no Color with index 5
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

The same destructuring works at module level, outside any function. Each name becomes a module value of the package, with the declaration's visibility:

```lyric
pub val (width, height): (Int, Int) = (640, 480)
val (smallest, largest) = minMax([3, 1, 4, 1, 5, 9])   // minMax runs once
```

A module-level pattern must be irrefutable (names, `_`, and tuples of those), since there is nowhere for a failed match to go: `val Some(x) = lookup()` at module level is a compile error (`T0144`). Use a `match` inside a function for shapes that can fail.

Use tuples sparingly. If you find yourself writing `(UserId, Instant, String)` and the meaning of each element is not immediately obvious at the call site, that is a signal that a named record would be clearer. The rule of thumb: tuples for small, local, and obvious groupings; records for anything that crosses function or package boundaries.

::: note
**Note:** Lyric does not support tuple indexing with `.0`, `.1` etc. If you need to access elements without destructuring, define a record with named fields. The omission is intentional — named access is always clearer than positional access for anything beyond two elements.
:::

## §3.5 Arrays and slices

Lyric distinguishes between two collection types with different tradeoffs.

**Arrays** are fixed-size and the length is part of the type. They are values: assigning, passing or returning an array copies it, and a write through one binding is never seen through another.

```lyric
var bytes: array[16, Byte]        // 16 bytes, length in type, zero filled
val zeros: array[4, Int] = [0, 0, 0, 0]
```

The length is known at compile time. `array[16, Byte]` and `array[32, Byte]` are different types. A bracket literal where an array is expected builds one and must have exactly `N` elements (T0155). A declaration with no initializer, and a record field with no default, is filled with the element type's zero value: `0`, `0.0`, `false`, an enum's first case, a record of zeros, or a nested array of them. An element type with no zero (a `String`, a union, a range excluding zero) needs an initializer (T0156). A construction that leaves an array field out gets the zero too, also for a record from another package or a generic one: `record Box[T] { var data: array[2, T] }` built as a `Box[Int]` starts with `[0, 0]`, and `Box(data = [1, 2])` is a `Box[Int]` because the literal binds `T`.

```lyric
var m: array[3, Int] = [1, 2, 3]
val first = m[0]                  // reads an element
m[1] = 20                         // writes through a var local
m[2] += 5

var copy = m                      // a copy
copy[0] = 100                     // m[0] is still 1

for x in m { println("${x}") }    // over the array's value when the loop starts
val s = m.toSlice()               // a new slice[Int]; m.length is 3, a constant
```

An element write needs a writable place: a `var` local, an `out` or `inout` parameter, or a `var` field. Anything else, such as a `val` local or an `in` parameter, is T0157, because the array would otherwise change under a binding that cannot be assigned. `==` and `!=` compare two arrays element by element.

```lyric
func bump(a: inout array[4, Int], i: in Int) {
  a[i] = a[i] + 10                // the caller's array changes
}
```

On `--target native` an array of by-value elements (numbers, enums, records with no `var` field, other such arrays) is stored inline with no allocation, so a `Vec3` table or a 4 by 4 matrix inside a by-value record costs nothing to copy beyond its bytes. `--target dotnet` stores an array as a `List`, which holds numbers unboxed. `--target jvm` stores an array of numbers, `Bool` or `Char` as a Java array of that primitive (`int[]`, `float[]`), so its elements are not boxed either, and any other array as a `List`.

A function can take an array of any length by making the length a value generic parameter. Each call binds `N` to its argument's length, and `N` is an ordinary `Int` constant in the body:

```lyric
func total[N: Nat](a: in array[N, Int]): Int {
  var t = 0
  for i in 0 ..< N {
    t = t + a[i]
  }
  t
}

func doubled[N: Nat](a: in array[N, Int]): array[N, Int] {
  var r = a
  for i in 0 ..< N {
    r[i] = a[i] * 2
  }
  r
}

val small: array[3, Int] = [1, 2, 3]
val big: array[4, Int] = [5, 6, 7, 8]
total(small)          // N = 3
total(doubled(big))   // N = 4; doubled returns an array[4, Int]
```

Each length is compiled separately, exactly as if you had written it out, so bounds checks, copies and `==` behave as they do for a literal length. Two arguments that disagree about `N`, or an argument that disagrees with an explicit `total[3](a)`, are a compile-time error (T0043). When no argument has the length (`func make[N: Nat](): array[N, Int]`), give it explicitly: `make[4]()`; a bare `make()` is T0110. A record can take a length parameter too, which sizes its array fields:

```lyric
record Ints[N: Nat] {
  var data: array[N, Int]

  func sum(self: in Ints[N]): Int {
    var t = 0
    for x in self.data {
      t = t + x
    }
    t
  }
}

val a: array[3, Int] = [1, 2, 3]
val v = Ints(data = a)       // an Ints[3]: N comes from the field's length
val z: Ints[5] = Ints()      // N from the type you ask for; data is zero filled
```

`Ints[3]` and `Ints[5]` are different types, and `N` is an `Int` constant in the methods: each method is compiled once per length it is called with. A method is in fact a generic function named after the record, and can also be declared that way, outside it:

```lyric
func Ints.first[N: Nat](self: in Ints[N]): Int = self.data[0]

val f = v.first()            // or Ints.first(v); compiled for N = 3
```

Two fields that disagree about `N` are T0043. A union, opaque type or protected type cannot take a length parameter (T0160, #8149).

A record with a length parameter can be used from another package like any other. Its methods are compiled for each length a call uses, in the package that makes the call, so `.length`, bounds checks and copies stay constants there too:

```lyric
import Shapes            // declares `pub record Ints[N: Nat]` with `func sum`

val v: Ints[3] = Ints()  // one type in every package that names it
val s = v.sum()
```

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

**Bounds checking and range subtypes.** Array and slice indexing is bounds-checked at runtime; an index outside `0 ..< N` panics with `index <i> out of range for array[<N>]`. But if the index is a literal in range, or its type is a named range subtype whose range statically proves the access is in bounds, the compiler elides the check entirely, in every build and on every target (an inline `Int range 0 ..= 3` annotation is not a proof, since it is not enforced on every path):

```lyric
type Slot = Int range 0 ..= 99
var xs: array[100, Int]
val i: Slot = Slot.from(7)
val v = xs[i]                    // bounds check elided — proven safe by type
```

An array index is an integer (`Int`, `Long`, `Byte`, ...) or a range subtype of one (T0158 otherwise); a non-`Int` index is range checked as a `Long`. An array has no members but `.length` and `.toSlice()` (T0113). An element of a `List` is not a writable array place (T0157).

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
