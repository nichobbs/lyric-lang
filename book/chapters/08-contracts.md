# Contracts

A function's name and type signature tell you what it takes and what it returns. Its contract tells you what must be true before it runs, and what it promises will be true when it returns. Lyric builds contracts into the language as first-class constructs — not comments, not docstrings, but code that the compiler checks. You write them alongside the function they describe, the tooling includes them in generated documentation, and the proof system (when you want it) can verify them statically. Contracts are the language's answer to the question every reader of unfamiliar code eventually asks: "what is this function actually allowed to receive?"

The concept is not new — Eiffel called it design by contract in the 1980s, Ada/SPARK uses it for safety-critical software today — but Lyric is the first language in the .NET space to make it ergonomic at the granularity of a typical application service. You do not need to switch tools, write annotations in a separate file, or adopt a heavyweight formal methods workflow. You add `requires:` and `ensures:` to functions you already write. If the contracts are violated at runtime, you get a precise error with the values that caused the failure. If you want static guarantees, you switch a package to `@proof_required` and the compiler does the proof work.

This chapter introduces how contracts are written and what they mean. Chapters 16 and 17 cover the two verification modes in depth.

## §8.1 What a contract is

Think of a contract as a signed agreement between a function and its callers. The caller promises: "when I call you, I guarantee these conditions hold." The function promises: "if you hold up your end, I guarantee these conditions hold when I return." If either party breaks the agreement, the violation is a bug — not a recoverable error, not an exception to be caught in normal code, but a `Bug` that propagates up the call stack (see Chapter 7).

Here is a concrete example:

```lyric
func divide(n: in Int, d: in Int): Int
  requires: d != 0
  ensures: result * d + (n % d) == n
{
  return n / d
}
```

The `requires: d != 0` clause is the precondition: the caller is not allowed to call `divide` with a zero denominator. The `ensures: result * d + (n % d) == n` clause is the postcondition: the function promises that integer division satisfies the division algorithm. `result` in an `ensures:` clause refers to the return value.

Neither clause is decoration. In `@runtime_checked` mode — the default — the `requires:` clause is evaluated on entry, and a failing check raises a `PreconditionViolated` bug with a message that includes the function name and the violated condition. The `ensures:` clause runs on return. In `@proof_required` mode, the compiler hands both clauses to an SMT solver before the program ever runs, and rejects the compilation if any obligation cannot be proved.

## §8.2 `requires:` — preconditions

A precondition captures what the caller must guarantee before the function body runs. Multiple `requires:` clauses are conjoined — all of them must hold:

```lyric
func transfer(from: in Account, to: in Account, amount: in Amount): Result[TransferReceipt, TransferError]
  requires: from.id != to.id
  requires: amount > 0
{
  // ...
}
```

When this function is called, the runtime checks `from.id != to.id` first, then `amount > 0`. If either fails, execution stops with a `PreconditionViolated` bug. The clauses are ordered — the first that fails is the one reported — so if both would fail, you see the first.

**What belongs in a precondition.** A precondition documents what the *caller* must guarantee. Things the function should handle gracefully — invalid input from an external API, a user's typo, an empty file — belong in the return type as `Result[T, E]`, not in a `requires:` clause. Reserve `requires:` for conditions that represent caller mistakes: passing the same account as both source and destination, or passing a zero denominator to a division function. The rule of thumb: if a reasonable caller could trigger the condition without a programming error on their part, it should be a `Result`; if only a buggy caller could trigger it, it belongs in `requires:`.

Keep preconditions simple. A precondition that requires a caller to demonstrate some complex global property becomes a burden on every call site. The harder a precondition is to satisfy, the more likely callers will work around it rather than satisfy it.

## §8.3 `ensures:` — postconditions

A postcondition describes what the function promises will be true on every return path. `result` refers to the return value. Here is a function whose postcondition expresses the exact value it returns:

```lyric
pub func balanceOf(a: in Account): Cents
  ensures: result == a.balance
{
  return a.balance
}
```

That particular postcondition is trivial — the implementation makes it obviously true — but it is also documentation that survives refactoring. If someone later rewrites the body and accidentally returns `a.balance - 1`, the `ensures:` catches it.

More useful postconditions talk about error cases explicitly:

```lyric
pub func debit(a: in Account, amount: in Amount): Result[Account, AccountError]
  ensures: result.isOk implies result.value.balance == a.balance - amountValue(amount)
  ensures: result.isErr implies a.balance < amountValue(amount)
{
  // ...
}
```

The `implies` operator is `a implies b`, meaning "if `a` is true, then `b` must also be true" — equivalent to `not a or b`. Here the two postconditions say: if the debit succeeded, the new balance is exactly reduced by the amount; if it failed, the balance was already too low. Together they rule out the silent-failure case where the function returns `Err` even when there was enough balance.

### `old()` — referring to the pre-state

Postconditions on functions that modify `inout` parameters, or that capture a snapshot of a parameter's state for comparison, use `old(expr)`. The `old()` form evaluates `expr` against the state at the moment the function body began executing — before any modifications:

```lyric
func push(s: inout Stack[T], x: in T): Unit
  ensures: s.depth == old(s.depth) + 1
  ensures: s.top() == x
{
  // ...
}
```

`old(s.depth)` is the depth of the stack when `push` was called. The postcondition says the depth increases by exactly one and the new top is the pushed element. Without `old`, you cannot write this: `s.depth` in an `ensures:` clause would refer to the post-state, which is what you are trying to characterize.

The snapshot is taken after the `requires:` clauses have been evaluated and before the function body runs. The runtime captures only the fields the contract actually reads — `old(s.depth)` costs one integer snapshot, not a deep copy of the stack.

## §8.4 Type invariants

Functions are not the only place contracts live. Records and opaque types can declare invariants — conditions that must hold for every valid value of the type:

```lyric
opaque type Account {
  balance: Cents
  invariant: balance >= 0 and balance <= 1_000_000_000_00
}
```

The invariant fires at every public boundary: after every public function in the type's package returns, on every parameter of the type passed into a function, and on every return value of the type. Internal mutations can temporarily violate the invariant — partial updates inside a function body are permitted — but the check fires when control returns to a public boundary.

What this buys you: once you hold an `Account` value, you can assume `balance >= 0` without checking. The type carries its own proof of validity. A function that receives an `Account` does not need to re-validate it; the compiler and runtime ensure it was valid when it entered the package.

::: note
**Note:** Invariants on `opaque type` are particularly powerful because the constructor is package-private. Callers outside the package can never create an `Account` value except through constructor functions you control, which means the invariant is enforced at every construction site. Chapter 9 covers this in depth.
:::

## §8.5 The contract expression sublanguage

Contract expressions are restricted. They must be pure — no side effects, no I/O, no mutation. The compiler enforces this statically: a contract expression that calls a non-`@pure` function is a compile error.

What you can use:

- Standard arithmetic, comparison, and logical operators (`+`, `-`, `*`, `/`, `%`, `==`, `!=`, `<`, `<=`, `>`, `>=`, `and`, `or`, `not`)
- Calls to functions explicitly marked `@pure`
- Field access (`a.balance`, `s.depth`)
- `result` and `old(expr)` in `ensures:` clauses
- `implies` — `a implies b` is equivalent to `not a or b`
- `forall` and `exists` quantifiers over finite collections:

```lyric
ensures: forall (x: T) where xs.contains(x) implies result.contains(x)
```

In `@runtime_checked` mode, a `forall` over a slice iterates the slice at runtime. In `@proof_required` mode, it becomes a universally-quantified formula for the SMT solver.

What you cannot use:

- Calls to non-`@pure` functions
- Side effects, allocation, or mutation
- The early-return operator `?`
- Body-local variables — contracts can only reference the function's parameters, `result`, and `old(...)` forms

The restriction exists because contracts need to be evaluable at multiple points in the function's lifecycle (on entry, on return, and by an external proof system) without changing the program's behavior. A contract that writes to a database or allocates would be impossible to evaluate soundly in proof mode.

## §8.6 Verification levels (a preview)

Every Lyric package carries a verification level, declared with a package-level annotation:

```lyric
@runtime_checked
package Account

@proof_required
package Transfer
```

**`@runtime_checked`** is the default. Contracts are evaluated at runtime and produce bugs if violated. This is the mode you develop in: fast feedback, precise error messages, argument values captured at the violation point. It costs runtime overhead proportional to contract complexity, which is usually negligible.

**`@proof_required`** requires the compiler to statically discharge every contract obligation before the package can be compiled. The SMT solver verifies that no execution of the code could violate a contract. If it cannot prove an obligation, the compilation fails with a counterexample. A `@proof_required` package can only call other `@proof_required` packages or `@axiom` extern boundaries — calling `@runtime_checked` code would make the proof unsound, because the proof system cannot reason about code whose contracts are only checked at runtime.

Chapters 16 and 17 cover both modes in depth. For most of the code you write, `@runtime_checked` is the right choice. `@proof_required` is for the packages where the stakes are high enough to justify the additional constraint on what you can call.

::: sidebar
**Why put contracts in the source?** The alternative — comments, documentation, or README sections describing what a function expects — rots the moment someone changes the implementation without reading the doc. A `requires:` clause fails loud and immediately when violated at runtime. More importantly, it is part of the code the proof system reads: if the precondition is in the source, the prover can use it as a hypothesis when verifying callers; if it is in a comment, the prover cannot. Contracts in source are executable documentation with teeth.
:::

## §8.7 Reading contract violations

When a contract is violated at runtime in `@runtime_checked` mode, the error message identifies the function, the violated clause, and the values of the relevant arguments at the violation point:

```
account.l:34:3: bug PreconditionViolated: divide — d != 0
  at Transfer.execute (transfer.l:45)
  at TransferService.transfer (transferService.l:22)
  at TransferHttp.handleTransfer (transferHttp.l:88)
counterexample values at violation:
  n = 100
  d = 0
```

The stack trace shows the call chain. The counterexample block shows the argument values that caused the failure. If you see this, you know exactly which call site passed `d = 0`, and you can trace back through the stack to find where `0` came from.

In `@proof_required` mode, the counterexample comes from the SMT solver before the program ever runs. The compiler rejects the build and produces the same counterexample format — but at compile time, not at 3am in production. This is the practical value of static verification: the bug is found when you write the code, not when a specific set of inputs reaches production.

Postcondition violations (`PostconditionViolated`) and invariant violations (`InvariantViolated`) follow the same format. The tag in the bug name tells you which kind of contract failed.

## Exercises

1. Write a `func factorial(n: in Int): Long` with a `requires: n >= 0` precondition and an `ensures: result > 0` postcondition. Call it with `-1` and observe the runtime violation message. Then try calling it with `0` — does the postcondition hold? What does `factorial(0)` return, and does `result > 0` hold for that value?

2. Add an `ensures` clause to a simple string-processing function: `func trimAndLower(s: in String): String ensures: result.length <= s.length`. In `@runtime_checked` mode, this is a runtime check. Can you construct an implementation that violates it? What does the violation message look like?

3. Write a function with two `requires:` clauses. Violate each one separately — pass arguments that break only the first clause, then only the second. Which violation is reported in each case? Does the order of `requires:` clauses in the source affect which one is reported?

4. Use `old()` to write a postcondition on a function that modifies an `inout` counter: `func increment(counter: inout Int, n: in Int): Unit ensures: counter == old(counter) + n`. Implement it correctly, then break the implementation and verify the postcondition fires.

5. Mark a package `@runtime_checked` and write a function with a `forall` in an `ensures:` clause — for example, a function returning a `slice[Int]` where the postcondition asserts every element is positive. Implement a version that satisfies the contract, then implement a version that violates it. Observe that the runtime iterates the slice to evaluate the `forall`.
