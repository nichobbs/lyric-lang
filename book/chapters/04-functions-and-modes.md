# Functions and Parameter Modes

Functions in Lyric carry more information than in most languages. The parameter modes, optional contracts, and return types form a small but precise specification of what a function does — before you read a single line of the body. This chapter covers everything about declaring and using functions, from the basics to closures and lambdas.

By the end you should be comfortable writing and calling functions with `out` and `inout` parameters, returning multiple values via tuples, and using closures as first-class values. We cover `match` briefly here because it appears in control flow, but Chapter 5 goes into pattern matching in depth.

## Basic function declaration

The simplest function looks like this:

```lyric
func add(x: Int, y: Int): Int = x + y
```

When the body is a single expression, use the `= expr` form. For anything more complex, use a block:

```lyric
func greet(name: String): String {
  return "Hello, ${name}!"
}
```

A few things to notice:

**Return types are always required on `pub` functions.** The compiler can often infer the return type of a private function, but anything you export needs an explicit annotation so callers have a stable contract. The convention is to be explicit everywhere — it makes code easier to read at a glance — but for short private helpers inference is reasonable.

**`Unit` means no useful value.** If a function does its work via side effects and returns nothing meaningful, declare `: Unit` or omit the return type entirely (it defaults to `Unit`). A `Unit` function can omit the `return` statement:

```lyric
func logMessage(msg: String): Unit {
  println("[INFO] ${msg}")
  // no return needed
}

// or equivalently
func logMessage(msg: String) {
  println("[INFO] ${msg}")
}
```

`Unit` is not `void`. It is a real type with exactly one value, `()`. You can store it, pass it around, and return it explicitly with `return ()`. This matters for generic code where a type parameter might be instantiated as `Unit`.

## Parameter modes: `in`, `out`, `inout`

This is one of Lyric's most visible departures from C#, Java, and Kotlin. Every parameter has a *mode* that declares the relationship between the function and the argument.

### `in` — read-only (the default)

```lyric
func area(r: Double): Double = 3.14159 * r * r

// Explicit `in` is allowed and sometimes written for documentation
func area(r: in Double): Double = 3.14159 * r * r
```

`in` is the default when you write no mode keyword. The function receives the value and cannot mutate it. The compiler may pass small types by value and larger types by reference internally, but from the function's perspective the parameter is read-only.

### `out` — the function writes it

```lyric
func divmod(n: Int, d: Int, q: out Int, r: out Int) {
  q = n / d
  r = n % d
}
```

An `out` parameter must be assigned on every control-flow path before the function returns. The caller passes a mutable variable; its value before the call is undefined (the compiler will reject reading an `out` parameter before assigning it). This is equivalent to C#'s `out`.

Calling a function with `out` parameters:

```lyric
var quotient: Int
var remainder: Int
divmod(17, 5, quotient, remainder)
// quotient is now 3, remainder is now 2
```

The variables must be `var`, not `val`. You cannot pass an immutable binding to an `out` parameter.

### `inout` — read and write

```lyric
func increment(x: inout Int) {
  x = x + 1
}
```

An `inout` parameter enters the function with a value, and the function can read and modify it. The caller passes a mutable variable, and any assignments to the parameter are visible in the caller after the function returns.

```lyric
var counter = 0
increment(counter)   // counter is now 1
increment(counter)   // counter is now 2
```

A practical example — sorting a slice in place:

```lyric
func swap(xs: inout slice[Int], i: Int, j: Int) {
  val tmp = xs[i]
  xs[i] = xs[j]
  xs[j] = tmp
}
```

### A note on async functions

Async functions cannot have `out` or `inout` parameters that cross `await` points. If you need to return multiple values from an async function, use a tuple or a record. The reason is subtle but practical: `inout` uses reference semantics, and a reference to a caller's variable across an await point would alias across concurrent operations.

::: sidebar
**Why require explicit parameter modes?** In C# and Java, pass-by-reference is implicit. A `ref` parameter in C# is visible at the call site (`func(ref x)`) but nothing in a function *declaration* tells a reader whether a parameter is mutated, read-only, or both — you have to look at the body. Lyric's modes are in the signature, which means the mode is visible at every call site and in generated documentation. This is especially useful for the proof system: a `requires:` clause on an `in` parameter is a clean precondition because the prover knows the value cannot change during execution. See D004 in the decision log for the full reasoning.
:::

## Return values and multiple returns

For a single value, declare the return type after `:` as usual. For multiple values, use a tuple:

```lyric
func minMax(xs: slice[Int]): (Int, Int) {
  var lo = xs[0]
  var hi = xs[0]
  for x in xs {
    if x < lo { lo = x }
    if x > hi { hi = x }
  }
  return (lo, hi)
}
```

Destructure the result at the call site:

```lyric
val (lo, hi) = minMax(numbers)
println("range: ${toString(lo)} to ${toString(hi)}")
```

When a function returns more than two or three values, a named record is more readable than a tuple. Tuples are positional — `(Int, Int, Int)` does not tell you which is which. A record gives names to the parts:

```lyric
record Stats {
  min: Int
  max: Int
  sum: Int
  count: Int
}

func summarize(xs: slice[Int]): Stats {
  // ...
}

val s = summarize(numbers)
println("avg: ${toString(s.sum / s.count)}")
```

The choice between `out` parameters and tuple returns is mostly stylistic. The idiomatic Lyric style is to return tuples for simple multi-value functions and records when the values have distinct names or when the function is `pub`. `out` parameters are appropriate when the function has a primary return value and a secondary output — like a parser that returns a parsed value *and* an updated position.

## Closures and lambdas

Closures are written with `{ params -> body }`:

```lyric
val double = { x: Int -> x * 2 }
val result = double(21)    // 42
```

When the context makes the parameter types clear, you can omit them:

```lyric
val numbers = [1, 2, 3, 4, 5]
val doubled = numbers.map { x -> x * 2 }
val evens = numbers.filter { x -> x % 2 == 0 }
```

Multi-statement closures produce the value of their last expression (no `return` keyword):

```lyric
val process = { x: Int ->
  val y = x * 2
  y + 1      // this is the produced value
}
```

### Trailing lambda syntax

When the last parameter of a function is a closure, you can move it outside the parentheses. This is how collection methods read naturally:

```lyric
// These are identical
val doubled = numbers.map({ x -> x * 2 })
val doubled = numbers.map { x -> x * 2 }

// No parens needed when the closure is the only argument
val doubled = numbers.map { x -> x * 2 }
```

### Closures as first-class values

Closures are values. You can store them in variables, pass them to functions, and return them from functions:

```lyric
func makeAdder(n: Int): {Int -> Int} {
  return { x -> x + n }
}

val addFive = makeAdder(5)
val result = addFive(3)    // 8
```

The type `{Int -> Int}` is the type of a closure that takes an `Int` and returns an `Int`. For a closure taking two parameters: `{Int, Int -> Bool}`.

### Capture semantics

Closures capture from their enclosing scope. The rule is:

- `val` bindings are captured by value — a snapshot of the value at the time the closure is created.
- `var` bindings are captured by reference — the closure sees the current value whenever it runs.

```lyric
var count = 0
val increment = { count = count + 1 }
increment()   // count is 1
increment()   // count is 2
```

Capturing `var` bindings across an async boundary requires explicit synchronisation (covered in Chapter 10 on concurrency). The compiler will tell you if you attempt to do this without the right primitives.

## Operator precedence

Lyric's precedence table is based on Swift's, with several deliberate changes. The full table, from highest to lowest binding:

| Level | Operators | Associativity |
|---|---|---|
| postfix | `f(x)`, `a[i]`, `.field`, `?` | left |
| prefix | `-x`, `not x`, `&x` | right |
| range | `..`, `..=` | non-associative |
| multiplicative | `*`, `/`, `%` | left |
| additive | `+`, `-` | left |
| nil-coalescing | `??` | right |
| comparison | `==`, `!=`, `<`, `<=`, `>`, `>=` | non-associative |
| logical-and | `and` | left |
| logical-or | `or`, `xor` | left |
| assignment | `=`, `+=`, `-=`, `*=`, `/=`, `%=` | right |

Three things differ from what you might expect coming from C, Java, or Kotlin.

**No bitwise operators.** There are no `&`, `|`, `^`, `<<`, `>>` operators. Use method calls instead: `.and()`, `.or()`, `.xor()`, `.shl()`, `.shr()`. This sidesteps the C-family precedence confusion where `x & 0xFF == 0` parses as `x & (0xFF == 0)` rather than `(x & 0xFF) == 0`.

**Chained comparisons are a parse error.** `a < b < c` is not `(a < b) < c`; it is a compile error. Write `a < b and b < c`. Comparison operators do not associate with each other.

**`??` is right-associative.** `a ?? b ?? c` is `a ?? (b ?? c)` — the rightmost fallback applies first if all the left-hand values are absent. This is the natural reading: try `a`, fall back to `b`, fall back to `c`.

**`?` is postfix.** The error-propagation operator binds tighter than everything except field access and indexing. `f(x)?.field` parses as `(f(x)?)`.field`.

## Control flow

### `if` as an expression

`if`/`else` produces a value:

```lyric
val label = if score >= 60 then "pass" else "fail"
```

Both branches must produce the same type. If you only write `if` without `else`, the expression produces `Unit`, which is fine for a statement but will cause a type error if you try to use the value.

For the statement form you are more likely to write the block form:

```lyric
if score >= 60 {
  println("pass")
} else {
  println("fail")
}
```

There is no ternary `?:` operator. The `if expr then a else b` form is the equivalent.

### `while` and `for`

`while` is the standard loop:

```lyric
var i = 0
while i < 10 {
  println(toString(i))
  i = i + 1
}
```

There is no `do...while`. For a loop that always executes the body at least once, use:

```lyric
while true {
  val input = readLine()
  if input == "quit" { break }
  process(input)
}
```

`for` iterates over any value that implements the `Iterable` interface, including ranges:

```lyric
// Iterate over a half-open range [0, n)
for i in 0 ..< n {
  println(toString(i))
}

// Iterate over a closed range [0, n]
for i in 0 ..= n {
  println(toString(i))
}

// Iterate over a collection
for item in inventory {
  println(item.name)
}
```

### `break`, `continue`, and labelled loops

`break` exits the innermost loop; `continue` skips to the next iteration. Both accept a label to target an outer loop:

```lyric
outer: for row in matrix {
  for cell in row {
    if cell == target {
      break outer    // exits both loops
    }
  }
}
```

Labels are written as `name:` immediately before the loop keyword. They are only needed when breaking out of nested loops — the vast majority of loops do not need labels.

## Error propagation with `?`

Chapter 7 covers error handling fully. Here is the short version so you can read code that uses it.

The `?` operator on a `Result[T, E]` value either unwraps the `Ok` side or returns `Err` from the enclosing function:

```lyric
func processAge(raw: String): Result[Age, ParseError] {
  val n = tryParseInt(raw)?     // returns Err[ParseError] early if parse fails
  return Age.tryFrom(n)?        // returns Err[ParseError] if n is out of range
}
```

If `tryParseInt(raw)` returns `Err(e)`, the `?` immediately returns `Err(e)` from `processAge`. Execution does not continue to the next line. The enclosing function must declare a `Result` return type that is compatible with the error type; the compiler rejects `?` in a function that returns a plain value.

`?` also works on nullable types (`T?`): if the value is `None`, the enclosing function returns `None`.

## Exercises

1. Write `func clamp(value: inout Int, lo: Int, hi: Int)` that modifies `value` in place to be within `[lo, hi]`. Call it from `main` and print the value before and after to confirm the change.

2. Write a function with an `out` parameter that has two control-flow paths, and deliberately leave one path without assigning the `out` parameter. What error does the compiler produce?

3. The `map` function on `slice[T]` takes a closure. Write a function `applyAll(xs: slice[Int], fs: slice[{Int -> Int}]): slice[Int]` that applies each function in `fs` in sequence to each element of `xs`, collecting the results. (This verifies that closures work as first-class values stored in a slice.)

4. Rewrite `divmod` to return a tuple `(Int, Int)` instead of using `out` parameters. Which style do you find more readable for this particular case? When would you prefer one over the other?

5. `a < b and b < c` is the idiomatic Lyric range check. Write a function `inBounds(x: Int, lo: Int, hi: Int): Bool` that returns whether `x` is in `[lo, hi]`. Then try writing `lo <= x <= hi` in the body instead — what does the compiler say?
