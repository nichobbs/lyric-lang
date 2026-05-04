# Core Types

Lyric's type system is where most of its safety properties live. Before you write any interesting program, you need to understand what the language's types actually mean — not just their names, but what the compiler enforces and what it does not. This chapter covers the building blocks: primitives, range-constrained subtypes, distinct nominal types, literals and conversions, and the `Never` type. These are the bricks. Everything else is built from them.

The theme running through all of this is that types carry *meaning*, not just shape. A `UserId` and an `Age` are both numbers, but they are not interchangeable, and the compiler enforces that. A `DiceRoll` is an integer between 1 and 6, and that constraint lives in the type — you do not validate it at runtime; you *construct* a value of the right type, and from that point on, the constraint is just true.

## §2.1 Primitive types

Lyric has a conventional set of primitive types, with two entries worth a closer look.

| Type | Description | Range / Notes |
|------|-------------|---------------|
| `Bool` | Boolean | `true`, `false` |
| `Byte` | 8-bit unsigned integer | `0 ..= 255` |
| `Int` | 32-bit signed integer | `-2_147_483_648 ..= 2_147_483_647` |
| `Long` | 64-bit signed integer | Full Int64 range |
| `UInt` | 32-bit unsigned integer | `0 ..= 4_294_967_295` |
| `ULong` | 64-bit unsigned integer | `0 ..= 2^64 - 1` |
| `Nat` | Non-negative 64-bit integer | `0 ..= 2^63 - 1` |
| `Float` | 32-bit IEEE 754 floating-point | Per IEEE 754-2019 |
| `Double` | 64-bit IEEE 754 floating-point | Per IEEE 754-2019 |
| `Char` | Unicode scalar value | Per Unicode 15+ |
| `String` | Immutable UTF-8 string | Unbounded |
| `Unit` | The unit type | Single value: `()` |
| `Never` | The bottom type | Uninhabited — no values exist |

`Nat` is the most useful of these for day-to-day work. In most languages you reach for `int` or `long` and mentally add "must be non-negative" as a comment. In Lyric, `Nat` encodes that constraint structurally. Array lengths, collection sizes, loop counters — any quantity that can't be negative should be `Nat` rather than `Int` or `Long`. You will see it constantly in the standard library.

`Never` is covered in detail in §2.5.

**Overflow behaviour** differs by build mode. In debug builds (the default when you run `lyric run` or `lyric build` without flags), integer arithmetic panics on overflow. In release builds (`lyric build --release`), overflow on *unconstrained* integer types wraps silently. Range-constrained subtypes — covered next — always panic on overflow regardless of build mode.

Floating-point follows IEEE 754-2019 with round-to-nearest-even and traps disabled. `NaN != NaN` is `true`, as the standard requires.

## §2.2 Range subtypes

Range subtypes are one of Lyric's most distinctive features. They let you narrow a numeric type to a contiguous range of values, and that range becomes part of the type — enforced at construction, trusted everywhere else.

```lyric
type Age = Int range 0 ..= 150
type Cents = Long range 0 ..= 1_000_000_000_00
type DiceRoll = Int range 1 ..= 6
```

These are not aliases or annotations on top of `Int`. They are *distinct types* in the nominal sense — you cannot pass an `Age` where an `Int` is expected, and you cannot mix them in arithmetic without explicit conversion:

```lyric
val age: Age = Age.tryFrom(25)?     // Result[Age, ContractViolation]
val next: Int = age.toInt() + 1     // explicit conversion back to Int
val bad: Int  = age + 1             // compile error: Age + Int is not defined
```

Two construction paths exist: `tryFrom` returns `Result[Age, ContractViolation]` and lets you handle the out-of-range case; `from` panics immediately if the value falls outside the range. In `@proof_required` modules the compiler discharges the range obligation statically and the runtime check is elided entirely. Chapter 8 covers that in detail. For now, `tryFrom` and the `?` propagation operator are the idiomatic construction pattern.

The range syntax has four forms:

| Syntax | Meaning |
|--------|---------|
| `a ..= b` | Closed range — both endpoints included |
| `a .. b` | Half-open — `b` excluded |
| `..= b` | From the type's minimum up to `b` |
| `a ..` | From `a` up to the type's maximum |

One practical payoff comes up in §3.5: array indexing. When you index an `array[N, T]` with a value whose range is statically proven to be within `0 ..= N - 1`, the compiler elides the bounds check entirely. No unsafe annotations, no manual proof — the type system handles it.

::: sidebar
**Why range subtypes rather than a `validate()` method?**

The standard pattern in Java or C# is a constructor or factory method that checks `if (value < 0 || value > 150) throw ...`. That works, but it requires every caller to decide whether to re-validate. It invites defensive duplication. And when the code is read six months later, the reader has to track down the constructor to understand what values are possible.

With a range subtype, the constraint is in the type name. An `Age` is, by definition, between 0 and 150. A function that takes an `Age` does not need to re-validate. A caller that constructs an `Age` has to handle the `tryFrom` `Result` at the boundary — one explicit validation at the entry point, then structural correctness everywhere else. The value is *valid by type*. That is a different, stronger claim than "this value was validated by code I can't see from here."

The proof system (Chapter 11) makes this even stronger: in a `@proof_required` module, the SMT solver verifies that the range obligation is discharged, and the runtime check disappears entirely. Dynamic validation can't give you that.
:::

The `derives` clause (covered in §2.3) applies to range subtypes too. `type Cents = Long range 0 ..= 1_000_000_000_00 derives Add, Sub, Compare` enables addition, subtraction, and comparison directly on `Cents` values — you can add two `Cents` values together and get a `Cents` back. You cannot multiply them; that's not in `derives`, and `Cents * Cents` would be dimensionally meaningless anyway.

## §2.3 Distinct types and aliases

Lyric distinguishes between two kinds of type declarations:

```lyric
alias Distance = Long          // structural synonym — interchangeable with Long
type UserId   = Long           // distinct nominal type — not interchangeable with Long
type OrderId  = Long           // also distinct — not interchangeable with UserId either
```

With `alias`, the compiler treats `Distance` as another name for `Long`. You can pass a `Long` anywhere a `Distance` is expected, and vice versa. Aliases are mostly for shortening long generic types in signatures.

With `type`, the new name is a different type from the underlying one, and different from every other `type` wrapping the same underlying. `UserId + OrderId` is a compile error. `UserId + Long` is also a compile error. Passing an `OrderId` to a function that expects a `UserId` is a compile error. This is the mechanical version of "don't mix up IDs," and it costs you nothing at runtime — the values are just `Long` under the covers, but the compiler tracks the distinction.

The `derives` clause controls which operations are available on the new type:

```lyric
type Cents  = Long range 0 ..= 1_000_000_000_00 derives Add, Sub, Compare
type UserId = Long derives Compare, Hash    // no arithmetic on identifiers
type Tag    = String derives Equals, Hash   // tag values can be compared and hashed
```

The full set of derivable markers is:

| Marker | What it enables |
|--------|----------------|
| `Add` | `T + T -> T` |
| `Sub` | `T - T -> T` |
| `Mul` | `T * T -> T` |
| `Div` | `T / T -> T` |
| `Mod` | `T % T -> T` |
| `Compare` | `<`, `<=`, `>`, `>=` and `IComparable<T>` |
| `Hash` | Consistent hash code (implies `Equals`) |
| `Equals` | `==`, `!=` and `IEquatable<T>` |
| `Default` | `T.default()` — the canonical zero-like value |

`Default` is rejected as a derive if the underlying primitive's default value falls outside a declared range. `type Age = Int range 0 ..= 150 derives Default` is fine — `0` is a valid age. `type DiceRoll = Int range 1 ..= 6 derives Default` is a compile error — `0` is not a valid die face.

Notice that `UserId derives Compare, Hash` enables sorting and using `UserId` as a map key, but you cannot add two user IDs together. The `derives` clause is how you specify exactly what algebra makes sense for your domain type. Without it, you get nothing — no `==`, no `<`, nothing. You have to be explicit.

::: sidebar
**Why are distinct types the default?**

In most languages, `type UserId = Long` would be an alias — identical to `Long`. Lyric reverses the default. If you want an alias, you write `alias`. If you write `type`, you get a genuinely distinct type.

The reasoning is in the name-frequency argument: in Lyric idioms, the common case is wanting a distinct type (`UserId`, `OrderId`, `Cents`) because the whole point is to stop them from being mixed. Aliases are the unusual case — mostly used to give a shorter name to a long generic type. Making the rare thing the keyword you have to write (`alias`) and the common thing the default (`type`) is the correct assignment.

Per decision log D011, TypeScript's "branded type" pattern (`type UserId = Long & { readonly _brand: 'UserId' }`) achieves something similar but requires boilerplate and is a workaround rather than a feature. Lyric makes it the primary mechanism.
:::

## §2.4 Literals and conversions

**Integer literals** follow Rust's syntax. Underscores are permitted anywhere for readability, and type suffixes are optional:

```lyric
42              // Int by default
0xFF            // hex
0o755           // octal — note: C-style 0755 is a lexer error
0b1010_1100     // binary with underscore
1_000_000       // underscores for readability
100u32          // explicit u32 (UInt)
-42i64          // explicit i64 (Long)
```

The suffix names map to Lyric types: `u8` → `Byte`, `u32` → `UInt`, `u64` → `ULong`, `i32` → `Int`, `i64` → `Long`.

**Float literals** similarly accept a suffix:

```lyric
3.14            // Double by default
2.5e10          // scientific notation
3.14f32         // Float
1_000.5f64      // Double (explicit)
```

**String interpolation** uses `${expr}` inside double-quoted strings. Any expression is valid inside the braces:

```lyric
val name = "Alice"
val age = 30
val msg = "Hello, ${name}! You are ${toString(age)} years old."

val escaped = "literal: \${not interpolated}"
```

**Raw strings** disable escape processing and interpolation:

```lyric
val path = r"C:\Users\alice\documents"
val quoted = r#"this contains "double quotes" and is still one string"#
```

The `r#"..."#` form uses matching hash delimiters to allow embedded double quotes without escaping.

**Triple-quoted strings** span multiple lines. Leading whitespace up to the indentation of the closing `"""` is stripped:

```lyric
val sql = """
  SELECT id, email
  FROM users
  WHERE active = true
  """
```

**Explicit conversions.** Lyric has no implicit widening. Passing an `Int` where a `Long` is expected is a compile error. Conversions are written explicitly:

```lyric
val i: Int  = 42
val l: Long = i.toLong()
val d: Double = i.toDouble()
val n: Nat = i.toNat()     // panics if i < 0; use tryToNat() for a Result
```

This is occasionally verbose but eliminates an entire class of bugs — no silent precision loss, no silent sign extension, no "I didn't realise Int would be widened to Long here."

## §2.5 The type `Never`

`Never` is the bottom type. It has no values — it is uninhabited. A function that returns `Never` cannot return normally; it must diverge (enter an infinite loop), panic, or throw an exception.

The canonical use is as the return type of `panic`:

```lyric
func panic(message: in String): Never
```

`panic` never returns, so its return type is `Never`. The compiler uses this in type inference. Consider:

```lyric
val x = if condition then 42 else panic("impossible")
```

The `if` expression needs both branches to have compatible types. The `then` branch has type `Int`. The `else` branch has type `Never`. Since `Never` is a subtype of every type — it produces no values, so it can't cause a type mismatch — the expression has type `Int`, and `x` is inferred as `Int`. The panic branch is unreachable in practice and contributes no type requirements.

This matters when you write code where you know a branch is impossible but the compiler doesn't. Pattern matching with a wildcard is one example:

```lyric
val result = match status {
  case Ok(value)    -> value
  case Err(e)       -> panic("unexpected error: ${e.message()}")
}
```

The `panic` branch has type `Never`, so `result` gets the type of the `Ok` branch. You do not need a different overload or a cast.

You will also see `Never` as a return type on functions that are logically exit points:

```lyric
func exitWith(code: in Int): Never {
  // terminates the process; never returns
  Std.Process.exit(code)
}
```

If you write a function that is supposed to return `Never` but can actually return, the compiler will tell you — the function's body must have a path that either panics, loops forever, or calls another `Never`-returning function.

## Exercises

1. Create `type Percentage = Int range 0 ..= 100 derives Add, Sub, Compare`. Call `Percentage.tryFrom(150)` — what does it return? Call `Percentage.from(150)` — what happens?

2. Define `type CustomerId = Long` and `type SupplierId = Long`. Write a function that takes both as parameters. Try calling it with the arguments reversed. What error does the compiler produce, and on which line?

3. The `derives` clause controls the available algebra. Declare `type Seconds = Long derives Add, Sub`. Then write `val s = Seconds.from(10) * Seconds.from(5)`. What error do you get?

4. Write a function `get` that takes an `array[10, Int]` and an `Int range 0 ..= 9` index, returning the element at that index. Now write a second version that takes a plain `Int` index. What is different about the two at the call site, and what does the compiler say when the index is out of range?

5. What is the type of `if false then 42 else panic("unreachable")`? Wrap it in a `val x = ...` and run `lyric build` with type inference output to confirm. Can you write a version where the `then` branch is `panic` and the `else` branch is a string? What is `x`'s type in that case?
