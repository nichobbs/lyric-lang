# Contracts at Runtime

Most Lyric programs spend their lives in `@runtime_checked` mode. This is not a fallback — it is a genuinely useful setting that turns contracts into live assertions, catches violations immediately, and produces counterexample values that make debugging fast. For the vast majority of application code, runtime checking gives you most of the benefit of formal verification at a small fraction of the cost: you write a `requires:` clause once, and every caller that passes bad arguments gets an immediate, precise error instead of a corrupted database row three transactions later.

This chapter covers what `@runtime_checked` mode actually does, what a violation looks like when it fires, the rules around debug and release builds, and how to use contracts as a development tool — writing the contract first, stubbing the body, and letting violations guide you to a correct implementation. It also draws the line between `requires:` and `assert`, which serve different purposes even though they both check Boolean conditions.

## §16.1 `@runtime_checked` — the default

Every package is implicitly `@runtime_checked`. You never have to write the annotation; it is there if you do not write anything else. Writing it explicitly makes the choice legible:

```lyric
@runtime_checked
package Account
```

What this annotation enables:

- **`requires:` clauses** are evaluated on entry to the function, in source order. The first clause that evaluates to `false` raises a `PreconditionViolated` bug immediately, before the function body runs.
- **`ensures:` clauses** are evaluated just before the function returns, after the body has produced a value. The first clause that evaluates to `false` raises a `PostconditionViolated` bug.
- **`invariant:` clauses** on record and opaque types are checked at every public boundary: when a value of the type is passed as an argument to a `pub` function outside the type's own package, and when such a value is returned from a `pub` function.
- **`forall` and `exists`** quantifiers iterate at runtime over the collection they range over. A `forall (x: Int) where xs.contains(x) implies result.contains(x)` walks the slice.

The annotation has no effect on which code you can call. A `@runtime_checked` package can call `@proof_required` packages, `@axiom` boundaries, or any other package without restriction. The restriction runs the other way: `@proof_required` packages are constrained in what they may call (Chapter 17).

## §16.2 What a runtime violation looks like

Here is a small program with a function whose precondition will fire:

```lyric
@runtime_checked
package Division

pub func divide(n: in Int, d: in Int): Int
  requires: d != 0
  ensures: result * d + (n % d) == n
{
  return n / d
}

func main(): Unit {
  val q = divide(10, 0)    // caller bug: d == 0
  println(toString(q))
}
```

When you run this, the runtime evaluates `d != 0` on entry to `divide`. It is false. Execution stops and the runtime produces:

```
division.l:4:3: bug PreconditionViolated: divide — d != 0
  at Division.main (division.l:9)
counterexample values at violation:
  n = 10
  d = 0
```

The error message tells you:
- **The file and line** where the contract clause was written — not just where the call happened.
- **The bug tag** — `PreconditionViolated` tells you this is a caller mistake, not a bug inside `divide`.
- **The function name and the violated clause** verbatim.
- **The call chain** — even in this trivial case, you see `main` called `divide`. In a deeper stack you see every frame.
- **The counterexample values** — the exact arguments that caused the failure. You do not have to reproduce the call; the runtime captures the values for you.

If instead the body had a bug and the `ensures:` fired:

```
division.l:5:3: bug PostconditionViolated: divide — result * d + (n % d) == n
  at Division.main (division.l:9)
counterexample values at violation:
  n = 10
  d = 3
  result = 2
```

The counterexample now includes `result` — the value the function actually returned — alongside the arguments. You can see immediately that `2 * 3 + (10 % 3) == 7`, not `10`, so something in the body produced the wrong quotient.

## §16.3 Violation semantics

There are three kinds of contract violation, each with its own bug tag:

**`PreconditionViolated`** — the caller passed arguments that broke the function's `requires:` clause. The function body never ran. This is always a bug in the calling code, not in the function being called. The function did exactly what it was designed to do: refuse to proceed with invalid input.

**`PostconditionViolated`** — the function's body ran and returned a value, but that value did not satisfy the `ensures:` clause. This is always a bug in the function itself. The function promised something it did not deliver.

**`InvariantViolated`** — a value of a type crossed a public boundary in a state that did not satisfy the type's `invariant:` clause. This can indicate a bug inside the type's own package (a function left the value in a bad state before it returned through a public boundary), or in rare cases a violation of construction rules.

All three are `Bug` values (Chapter 7). They are not normal errors — do not put them in a `Result` return type. Do not catch them in normal application code. A violation is a programming mistake that needs to be fixed, not a condition that callers should handle gracefully. The right response to seeing one is to find the bug, not to add a `try`/`catch` around the call site.

::: sidebar
**Why are violations `Bug` and not exceptions?** Contract violations signal programming errors, not runtime conditions. An `InsufficientFunds` error is a condition a caller should handle; a `PreconditionViolated` means the caller should never have made that call. Routing violations through the same `Result`/exception channel as domain errors would let callers accidentally swallow them — returning `Err(PreconditionViolated(...))` from a function gives the caller the false impression that this is a handled case. Making violations `Bug` ensures they propagate noisily up the stack until someone with the appropriate context — a top-level handler, a test harness — sees them.
:::

## §16.4 Debug vs release contract checking

The runtime overhead of contract checking is real: evaluating Boolean expressions on every function entry and return costs time proportional to contract complexity. For tight loops processing millions of items, this overhead can matter. Lyric's build modes give you control.

**Debug builds** (`lyric build` without `--release`) check all contracts everywhere. This is what you want during development — full visibility, immediate feedback.

**Release builds** (`lyric build --release`) apply a more selective policy:

- `requires:` on `pub` functions are **always checked**, even in release. A caller outside your package can always pass bad arguments; eliminating those checks would silently corrupt data in production.
- `requires:` on non-`pub` (internal) functions are **elided**. By the time a value reaches an internal function, it has already passed through a public boundary that validated it.
- `ensures:` clauses are **elided by default** in release. They are expensive (they run on every return) and primarily useful during development. To keep them in a release build, pass `--release-contracts` to the compiler.
- Range subtype checks — the bounds on types like `Nat range 0 ..= 100` — are **always checked** in all builds. These are structural properties of values; eliding them would produce values the type system claims cannot exist.

To opt into full contract checking in a release build for a specific package, annotate the package:

```lyric
@runtime_checked(release_contracts = full)
package Account
```

This is useful for financial packages where the cost of a missed postcondition violation in production far exceeds the performance overhead.

::: note
**Note:** The `--release-contracts` flag and `release_contracts` annotation apply to the package they annotate. Downstream packages that import `Account` do not inherit the setting; each package controls its own release policy.
:::

## §16.5 Using contracts as development tools

The most practical use of `@runtime_checked` mode is as a development workflow tool. Write the contract before writing the implementation. The violation messages guide you to the correct implementation without needing a debugger.

Here is the workflow applied to a debit function:

**Step 1: Write the contract, stub the body.**

```lyric
@runtime_checked
package Account

pub func debit(a: in Account, amount: in Cents): Result[Account, AccountError]
  requires: amount > 0
  ensures: result.isOk implies result.value.balance == a.balance - amount
  ensures: result.isErr implies a.balance < amount
{
  panic("not implemented")
}
```

You now have an executable specification. Call it from a test:

```lyric
val alice = makeAccount(balance = 100)
val result = debit(alice, 30)
expect(result.isOk)
```

The test fails (because `panic` runs), but you have not violated any contract yet.

**Step 2: Implement incorrectly and observe the postcondition.**

```lyric
pub func debit(a: in Account, amount: in Cents): Result[Account, AccountError]
  requires: amount > 0
  ensures: result.isOk implies result.value.balance == a.balance - amount
  ensures: result.isErr implies a.balance < amount
{
  return Ok(a.copy(balance = a.balance))   // forgot to subtract amount
}
```

Running the test now gives:

```
account.l:4:3: bug PostconditionViolated: debit
  — result.isOk implies result.value.balance == a.balance - amount
  at AccountTest.testDebit (accountTest.l:12)
counterexample values at violation:
  a.balance = 100
  amount    = 30
  result.value.balance = 100
```

The counterexample tells you exactly what is wrong: `result.value.balance` is `100` when it should be `70`. The fix is obvious.

**Step 3: Implement correctly.**

```lyric
pub func debit(a: in Account, amount: in Cents): Result[Account, AccountError]
  requires: amount > 0
  ensures: result.isOk implies result.value.balance == a.balance - amount
  ensures: result.isErr implies a.balance < amount
{
  if a.balance < amount {
    return Err(InsufficientFunds)
  }
  return Ok(a.copy(balance = a.balance - amount))
}
```

Both postconditions now hold. Both tests pass.

This workflow compresses what would otherwise be a write-run-debug-print cycle into a write-run cycle. The contract doubles as your test oracle.

## §16.6 `assert` vs `requires:`

Both `assert(cond, msg)` and `requires: cond` check a Boolean condition. They serve different purposes and produce different diagnostic output.

`requires:` is a **caller obligation**. It is part of the function's public contract — visible in generated documentation, included in the compiled package's contract metadata, available to the proof system when callers are verified. Use `requires:` when the condition is something the caller must guarantee. If the condition fires, the blame falls on the caller.

`assert` is an **internal sanity check**. It is not part of the function's API surface. It does not appear in documentation or contract metadata. It is not reasoned about by the proof system in the same way (the prover treats it as an assumed hypothesis in `@proof_required` mode, not as a caller obligation). Use `assert` when a condition should never be false by construction — a path the compiler cannot statically rule out but you are confident cannot be reached given the invariants already in place. If it fires, the blame falls on the implementation.

```lyric
pub func processItems(items: in slice[Item]): slice[Result[Processed, ItemError]]
  requires: items.length > 0     // caller's obligation: do not call with empty list
{
  var results: slice[Result[Processed, ItemError]] = []
  for item in items {
    val processed = transform(item)
    assert(processed.id == item.id, "transform must preserve id")  // internal sanity check
    results = results.append(Ok(processed))
  }
  return results
}
```

The error output is also different. A `requires:` violation says `PreconditionViolated` and names the function and clause. An `assert` violation says `AssertionFailed` and shows the message you provided. When reading a bug report, `PreconditionViolated` immediately tells you to look at the call site; `AssertionFailed` tells you to look at the function's body.

A third option — returning an `Err` — is appropriate when the condition represents a recoverable situation a reasonable caller might encounter: bad user input, a missing file, a network timeout. Reserve `requires:` for conditions only a buggy caller would trigger, and `assert` for conditions that represent internal logic errors.

## Exercises

1. Write a function `func divide(n: in Int, d: in Int): Int requires: d != 0` and a function `func badDivide(n: in Int, d: in Int): Int ensures: result == n / d + 1`. Call `divide` with `d = 0` and observe the `PreconditionViolated` message. Then implement `badDivide` correctly but observe the `PostconditionViolated` message. Compare the bug tags, messages, and which values appear in the counterexample.

2. Write an `opaque type Counter` with `invariant: value >= 0`. Write an `increment` function that works correctly and a `decrement` function that allows the value to go negative internally before correcting it. Call `decrement` from a test and observe that the invariant does not fire for internal intermediate states, but does fire if you expose the broken value through a `pub` function that returns the `Counter`.

3. Write the same condition as both a `requires:` clause and an `assert(...)` call inside a function body. Trigger each. Compare the error messages: which names the violated clause verbatim, which shows your custom message, and which bug tag does each produce?

4. Write a function with a `forall` in its `ensures:` clause — for example, `func nonNegativeAll(xs: in slice[Int]): slice[Int] ensures: forall (x: Int) where result.contains(x) implies x >= 0`. Implement it correctly, then implement a version that includes a negative value. Observe that the runtime iterates the slice to find the violating element and includes it in the counterexample.

5. Write a tight loop that calls a function with a non-trivial `ensures:` clause one million times. Build in debug mode and release mode (`lyric build --release`). Use a timer to measure the difference. Then add `--release-contracts` and measure again. What is the overhead of postcondition checking in your case?
