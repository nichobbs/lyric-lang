# Pattern Matching

Pattern matching in Lyric is not syntactic sugar for a series of `if` checks. It is the primary way of working with sum types, and the compiler enforces that you handle every case. Where other languages let you forget a variant and discover the omission at runtime, Lyric turns that into a compile error. This chapter covers matching in depth, from simple literals to nested patterns with guards.

You have already seen `match` in Chapter 1's error message example. Now we cover it properly.

## The basics

The canonical use of `match` is destructuring a union:

```lyric
val description = match shape {
  case Circle(r)        -> "circle of radius ${toString(r)}"
  case Rectangle(w, h)  -> "rectangle ${toString(w)}x${toString(h)}"
}
```

A few properties to notice immediately.

`match` is an expression. It produces a value, which you can assign, return, or pass directly as an argument. You are not forced to write `var result; match ...; result` — just use the match expression inline.

Every arm has the form `case Pattern -> expression`. The `->` separates the pattern from what the arm produces. There is no `break` needed; arms do not fall through.

All arms must produce the same type. If one arm produces a `String` and another produces an `Int`, the compiler rejects the match.

The compiler enforces exhaustiveness. If you write the `Circle` arm but forget `Rectangle`, the build fails with an error naming the missing case. There is no way to leave a union variant silently unhandled.

## Pattern kinds

### Literal patterns

Match against a specific value:

```lyric
val label = match n {
  case 0 -> "zero"
  case 1 -> "one"
  case 2 -> "two"
  case _ -> "other"
}
```

The `_` wildcard matches anything and discards the value. It is the escape hatch for exhaustiveness: any case not explicitly listed falls through to `_`. Literals work for `Int`, `Long`, `Bool`, `String`, `Char`, and other primitives.

### Binding patterns

A bare name in a constructor pattern captures the field value into a local variable:

```lyric
match opt {
  case Some(value) -> doSomething(value)
  case None        -> fallback()
}
```

Here `value` is bound to whatever was inside the `Some`, and is in scope only within that arm.

### Wildcard `_`

When you want to match a constructor but do not need its contents:

```lyric
match result {
  case Ok(_)  -> "success"
  case Err(_) -> "failure"
}
```

You can also use `_` in specific positions within a pattern to say "something is here, but I do not care what it is":

```lyric
match pair {
  case (0, _) -> "first is zero"
  case (_, 0) -> "second is zero"
  case (x, y) -> "both non-zero: ${toString(x)}, ${toString(y)}"
}
```

### Record destructuring

Records can be matched field by field. You may match on specific field values and bind others:

```lyric
match point {
  case Point { x = 0.0, y }  -> "on the y-axis at ${toString(y)}"
  case Point { x, y }        -> "at (${toString(x)}, ${toString(y)})"
}
```

The `x = 0.0` checks that `x` equals `0.0`. The plain `y` binds the field value into `y`. You do not have to mention every field — fields not listed are implicitly wildcarded.

### Range patterns

```lyric
val group = match age {
  case 0 ..= 17  -> "minor"
  case 18 ..= 64 -> "adult"
  case _         -> "senior"
}
```

Range patterns use the same `..=` (closed) and `..<` (half-open) syntax as range literals. The compiler does not check that range patterns together cover the full integer domain — you still need a `_` arm or explicit coverage of every possible value.

### Tuple patterns

```lyric
val message = match (success, code) {
  case (true, 200)   -> "ok"
  case (true, _)     -> "ok with unexpected code"
  case (false, 404)  -> "not found"
  case (false, code) -> "error ${toString(code)}"
}
```

Tuple patterns nest directly inside `match`. The outer parentheses in `match (success, code)` are just constructing a tuple inline — there is nothing special about matching on a tuple versus any other value.

## Guard clauses

Guards add a boolean condition to a case. The pattern must match *and* the guard must be true for the arm to fire:

```lyric
val classification = match shape {
  case Circle(r) where r > 100.0        -> "large circle"
  case Circle(r)                        -> "small circle of radius ${toString(r)}"
  case Rectangle(w, h) where w == h     -> "square"
  case Rectangle(w, h)                  -> "${toString(w)}x${toString(h)} rectangle"
}
```

Both `where` and `if` are accepted as the guard keyword. They are identical. `where` reads more naturally when the guard is a domain condition; `if` reads more naturally for boolean checks. Use whichever reads better in context.

If the guard fails, the match continues to the next case. In the example above, a `Circle` with `r <= 100.0` does not match the first arm, so the second arm fires.

The important rule: **the compiler does not count guarded arms as covering a pattern.** If you write:

```lyric
match shape {
  case Circle(r) where r > 0.0 -> ...
  case Rectangle(w, h)         -> ...
}
```

This is a compile error. `Circle` with `r <= 0.0` is unhandled. A guarded arm covers a subset of the pattern space; it does not satisfy the exhaustiveness requirement for that variant. You need an unguarded `case Circle(r) ->` or a `case _ ->` to close it off.

## Nested patterns

Patterns compose. The binding names from inner patterns are available in the arm body:

```lyric
match result {
  case Ok(Some(user))         -> "found user ${user.name}"
  case Ok(None)               -> "not found"
  case Err(NotFound(id))      -> "account ${toString(id)} missing"
  case Err(PermissionDenied)  -> "access denied"
}
```

Here `result` is a `Result[User?, AccountError]`. The outer pattern distinguishes `Ok` from `Err`; the inner patterns go further into the contents. The binding `user` (from `Some(user)`) and `id` (from `NotFound(id)`) are both in scope in their respective arms.

Nesting can go as deep as the data structure requires. There is no practical limit, though deeply nested patterns are usually a sign that extracting a helper function would improve readability.

::: note
**Note:** Nested patterns are matched top-to-bottom. When `Ok(Some(user))` appears before `Ok(None)`, the compiler checks both are present. If you wrote only `Ok(Some(user))`, the compiler would flag `Ok(None)` as a missing case.
:::

## Exhaustiveness in practice

Adding a new variant to a union is one of the most common refactoring operations in Lyric. The exhaustiveness check makes it safe.

Suppose you start with:

```lyric
union Shape {
  case Circle(radius: Double)
  case Rectangle(width: Double, height: Double)
}

func area(s: Shape): Double {
  return match s {
    case Circle(r)    -> 3.14159 * r * r
    case Rectangle(w, h) -> w * h
  }
}
```

Later you add `Triangle`:

```lyric
union Shape {
  case Circle(radius: Double)
  case Rectangle(width: Double, height: Double)
  case Triangle(base: Double, height: Double)
}
```

The compiler now rejects the `area` function:

```
shape.l:8:10: error E0301: non-exhaustive match
  missing case: Triangle
  note: if you intend to ignore this case, use: case _ ->
```

Every `match` on `Shape` throughout the codebase produces this error until you handle `Triangle`. This includes `match` expressions in other files, in tests, in library code that imports `Shape`. The compiler finds all of them.

::: sidebar
**Why not just warn on non-exhaustive matches?** Because warnings are ignored. An incomplete match on a sum type is always a bug — if a new variant appears, code that silently missed it will behave incorrectly at runtime. Making it an error means the codebase cannot be in a state where some matches are silently incomplete. This is particularly valuable during refactoring: change a union, and the compiler finds every unhandled location before the build succeeds. See D012 in the decision log for the full reasoning.
:::

The correct instinct when you see E0301 during development is to handle the new case, not to add `case _ ->` to suppress the error. `case _ ->` is appropriate when you genuinely want to ignore future variants, but for domain-critical logic — `area`, `serialize`, `describe` — you want the compiler to force you to think about every variant.

## `match` vs `if`/`else`

`match` is for sum types, destructuring, and pattern-based dispatch. `if`/`else` is for boolean conditions that do not involve destructuring. Knowing which to reach for is mostly intuition after a little practice.

Use `match` when:
- You are working with a union type
- You need to extract values from a constructor
- You have several distinct structural cases to handle

Use `if`/`else` when:
- The condition is a boolean expression
- There is no destructuring
- You have one or two conditions and a `match` would be noisy

One pattern that Lyric deliberately does not have is `if let` (as in Rust or Swift). To check whether an `Option` is `Some` and bind its value, you write a full match:

```lyric
match maybeUser {
  case Some(user) -> println("logged in as ${user.name}")
  case None       -> println("not logged in")
}
```

This is slightly more verbose than `if let Some(user) = maybeUser`, but it makes the handling of both cases explicit. The compiler ensures you do not accidentally ignore the `None` branch.

Here is how `match` replaces a chain of `instanceof` checks in Java or `is` type tests in Kotlin:

```lyric
// Lyric — exhaustive, no casting, no silent omissions
func describe(event: Event): String {
  return match event {
    case UserCreated(id, email)    -> "new user ${toString(id)}: ${email}"
    case UserDeleted(id)           -> "deleted user ${toString(id)}"
    case PasswordChanged(id)       -> "password changed for ${toString(id)}"
    case LoginFailed(email, count) -> "${email} failed login (attempt ${toString(count)})"
  }
}
```

```java
// Java equivalent — open-ended, requires casting, silently ignores new variants
String describe(Event event) {
    if (event instanceof UserCreated e) {
        return "new user " + e.id() + ": " + e.email();
    } else if (event instanceof UserDeleted e) {
        return "deleted user " + e.id();
    }
    // PasswordChanged and LoginFailed silently return null
    return null;
}
```

The difference is not just ceremony — it is a structural guarantee. When you add `AccountLocked` to `Event` in Lyric, the compiler finds the `describe` function. In Java, it silently returns `null` until someone notices.

## Exercises

1. Write a `union Expr { case Num(n: Int); case Add(left: Expr, right: Expr); case Mul(left: Expr, right: Expr) }` and a recursive `func eval(e: Expr): Int` that evaluates the expression tree. Test it by constructing `Add(Num(2), Mul(Num(3), Num(4)))` and checking that it produces `14`.

2. Match on a `Result[Int, String]` and handle three cases: `Ok` where the value is positive, `Ok` where the value is negative or zero, and `Err`. Use a guard for the sign check. Then observe what the compiler says if you remove the unguarded `Ok` arm — does the guarded arm satisfy exhaustiveness?

3. Given `record Person { name: String; age: Int }`, write a match that produces different strings for people named `"Alice"`, for people under 18 (regardless of name), and for everyone else. Make sure the `"Alice"` arm fires even when Alice is under 18 — pay attention to arm ordering.

4. Add a `Sub(left: Expr, right: Expr)` case to the `Expr` union from exercise 1. How many places in your code does the compiler report as incomplete? Fix them all. Compare this experience to adding a new value to a C# `enum` — what does the compiler tell you in that case?

5. The wildcard `_` is sometimes necessary and sometimes a shortcut for not thinking. Write a match with a final `case _ -> panic("impossible")` arm. Identify a case where this is justified (a variant that can never occur at this point in the code due to a precondition) and a case where it is a smell (you are just avoiding the compiler's question about a variant you should handle). What is the difference between the two situations?
