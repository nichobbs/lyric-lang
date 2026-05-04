# Proofs

`@runtime_checked` catches violations for the specific inputs the program runs with. `@proof_required` catches them for every possible input, before the program ever runs. The prover does not sample — it reasons over the entire input space and either discharges a contract obligation as universally true or produces a concrete counterexample demonstrating a case where it fails. This chapter covers Lyric's SMT-backed verification: how to annotate a module, run the verifier, read the output, and when the investment pays off.

The proof system is not a replacement for runtime checking. It is a different tool for a different class of problem. Most packages should stay `@runtime_checked`. The ones that benefit from `@proof_required` are the ones where you can articulate the correctness properties precisely, where the domain is arithmetic-heavy, and where a bug slipping through testing would be expensive enough to justify the additional discipline. If that sounds like the core of a financial system, that is because it usually is.

## §17.1 When to use `@proof_required`

The proof system discharges contracts by handing them to an SMT solver. That solver is very good at certain things and not at others. Understanding the fit helps you decide where the annotation belongs.

**Well-suited to `@proof_required`:**

- Domain cores with arithmetic invariants: balance arithmetic, conservation properties, range constraints on financial values. These sit squarely in the decidable fragment of linear integer arithmetic, which Z3 handles deterministically and quickly.
- Data structures with universally quantified correctness properties: a sorted set where every element satisfies an ordering invariant, a BST where left keys are smaller than the root. Z3 handles inductive datatypes with quantifiers over finite structure.
- Bounded computations with explicit loop invariants: when you can state what holds before and after each iteration, the wp calculus can verify the loop.

**Less suited to `@proof_required`:**

- Code that calls I/O, databases, or network operations. These require `@axiom` boundaries, and every axiom you add is an assumption the prover takes on faith. A package that is mostly axioms provides limited proof value.
- Code with unbounded recursion and no termination argument. The VC generator needs a finite proof tree; diverging code produces obligations it cannot discharge.
- UI and orchestration layers. These tend to involve mutable state, async composition, and external dependencies — all of which push outside the fragment or require extensive axioms.

The pattern that works well in practice is the one from the banking example: `@proof_required` for the domain layer — `Money`, `Account`, `Transfer` — and `@runtime_checked` for everything else. The domain layer is arithmetic-heavy, has clear invariants, and is small enough that proof obligations are tractable. The application layer calls into the domain layer and gets the domain's guarantees for free, without itself needing to be verified.

::: sidebar
**Why per-module and not per-function?** D013 in the decision log captures this choice. Function-level verification opt-in sounds more flexible, but a verified function calling unverified helpers gives you nothing — the prover has to assume the helpers' postconditions rather than checking them. Per-module boundaries enforce the discipline that makes the proof meaningful. Every function in a `@proof_required` package is verified, and every callee it calls is either also verified or explicitly declared as an axiom.
:::

## §17.2 Annotating a module

Marking a package `@proof_required` is a single-line change:

```lyric
@proof_required
package Money

pub type Cents = Long range 0 ..= 1_000_000_000_00 derives Add, Sub, Compare

pub opaque type Amount @projectable {
  value: Cents
  invariant: value > 0
}

pub func make(c: in Cents): Result[Amount, ContractViolation]
  ensures: result.isOk implies result.value.value == c
{
  return if c > 0 then Ok(Amount(value = c))
                  else Err(ContractViolation("amount must be positive"))
}

pub func valueOf(a: in Amount): Cents
  ensures: result == a.value
{
  return a.value
}
```

The annotation changes what the compiler does with `requires:` and `ensures:` clauses: instead of generating runtime assertion code, the compiler feeds them to the VC generator, which produces SMT formulae that must be discharged before the package can be compiled.

There is one new constraint on your call graph: a `@proof_required` package may only call:

- Other `@proof_required` packages (whose contracts were already verified)
- Primitive operations built into the language (arithmetic, comparisons, constructors)
- `@axiom` extern boundaries (which are assumed rather than proved)

It may not call `@runtime_checked` code. If it did, the prover would have no basis for reasoning about what that code does — its contracts are checked at runtime, not in advance. The proof would be incomplete and therefore meaningless.

This restriction is detected at compile time. If you annotate a package `@proof_required` and it imports a `@runtime_checked` package, the compiler reports diagnostic `V0002` and tells you exactly which import violates the constraint. Your options are: mark the imported package `@proof_required` (if it can be verified), declare it behind an `@axiom` boundary, or move the calling code back to `@runtime_checked`.

::: note
**Note:** A `@runtime_checked` package can call a `@proof_required` package freely. The restriction is one-directional: proof-required code constrains its callees; runtime-checked code does not. Downstream packages benefit from a `@proof_required` domain layer without needing to adopt `@proof_required` themselves.
:::

## §17.3 Running `lyric prove`

Once you have annotated a module, run the verifier:

```sh
lyric prove money.l
```

When all obligations discharge:

```
money.l: @proof_required  3 goals  discharged (trivial discharger)
```

This output tells you the file, its verification level, how many goals the VC generator produced, and how they were discharged. "Trivial discharger" means the obligations fell within what the built-in syntactic solver could handle without invoking Z3.

When an obligation fails, the output names the goal and provides a counterexample:

```
transfer.l:12:3: error V0008: ensures (conservation) — proof failed
  counterexample:
    from.balance : Int = 100
    to.balance   : Int = 50
    amount       : Int = 0
  falsified conclusion: newFrom.balance + newTo.balance == 150
```

The counterexample is not arbitrary — it is a specific assignment of values to variables that makes the postcondition false. In this case, the solver found that if `amount = 0` and `debit` returns `Err`, the function returns early before binding `newFrom` and `newTo`, so the conservation property cannot hold. The counterexample tells you exactly what inputs expose the gap.

## §17.4 The Hoare call rule (accessible explanation)

The key mechanism that makes module-level proof tractable is the Hoare call rule. When the VC generator encounters a call to `debit(from, amount)` inside `execute`, it does not re-analyse `debit`'s body. It uses `debit`'s contract instead:

1. **Assert** `debit`'s `requires:` at the call site — confirm that the arguments satisfy `debit`'s precondition.
2. **Assume** `debit`'s `ensures:` after the call — treat the postcondition as an established fact for the rest of the analysis.

This is the deal: you prove each function independently, and at call sites you trust what you proved. The proof for `execute` does not need to know how `debit` works internally; it only needs to know what `debit` promises.

To see this in action, let us trace through the conservation property proof step by step. The goal is to verify that `execute`'s postcondition holds:

```lyric
ensures: result.isOk implies {
  val (newFrom, newTo) = result.value
  newFrom.balance + newTo.balance == from.balance + to.balance
}
```

The function's body calls `debit` and then `credit`. The VC generator works backwards through the body using the weakest-precondition calculus. At the `debit` call site:

- It checks `debit`'s precondition. (In the full example there is none beyond the implicit range constraints, which the type system already guarantees.)
- It then assumes `debit`'s postcondition:
  ```
  result.isOk implies result.value.balance == from.balance - amountValue(amount)
  ```

Similarly at the `credit` call site, it assumes:
  ```
  result.isOk implies result.value.balance == to.balance + amountValue(amount)
  ```

Now the VC generator has two assumed facts. The conservation property — `newFrom.balance + newTo.balance == from.balance + to.balance` — follows from these two facts by linear arithmetic substitution:

```
newFrom.balance + newTo.balance
  = (from.balance - amountValue(amount)) + (to.balance + amountValue(amount))
  = from.balance + to.balance
```

Z3 discharges this in milliseconds. The entire proof never opened `debit`'s body or `credit`'s body; it used their contracts as black-box specifications. This is why contracts on callees must be strong enough to let their callers reason about them — a `debit` with no postcondition, or a postcondition that does not mention the balance, would leave the VC generator with no facts to work from, and the conservation goal would remain unproven.

## §17.5 `lyric prove --explain` and `--json`

When a proof succeeds or fails, you can inspect the underlying goal in more detail.

**`--explain --goal N`** shows the Lyric-VC IR for goal N — the hypotheses available at the discharge point and the conclusion that must follow from them:

```sh
lyric prove --explain --goal 0 transfer.l
```

Output:

```
goal 0: execute/ensures/conservation

hypotheses:
  H0: from.id != to.id
  H1: 0 <= from.balance <= 1_000_000_000_00
  H2: 0 <= to.balance <= 1_000_000_000_00
  H3: debit(from, amount).isOk implies debit(from, amount).value.balance == from.balance - amountValue(amount)
  H4: credit(to, amount).isOk implies credit(to, amount).value.balance == to.balance + amountValue(amount)

conclusion:
  result.isOk implies newFrom.balance + newTo.balance == from.balance + to.balance
```

The hypotheses are the assembled proof context: the parameter invariants, the callee postconditions substituted at the call sites, and any other facts the VC generator collected along the way. The conclusion is what must follow from them. Reading this output tells you immediately whether the right facts are present — if the conservation property is not discharging, check that `H3` and `H4` are present. If they are absent, the callee contracts are missing.

**`--json`** emits machine-readable structured output, designed for CI integration:

```sh
lyric prove --json transfer.l
```

Output:

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

The `outcome` field is `"discharged"`, `"counterexample"`, or `"unknown"`. A CI gate that fails if `counterexamples > 0` or `unknown > 0` ensures that every proof obligation is affirmatively discharged before a merge. The `"model"` field, when present, contains the counterexample bindings in the same format the human-readable output shows.

## §17.6 `@axiom` boundaries in `@proof_required` packages

Not everything a domain package needs is itself provable. I/O, clocks, database operations, and .NET BCL calls live outside the decidable fragment. The `@axiom` boundary is the mechanism for bringing them in.

An extern declaration with `@axiom` tells the prover: "treat this function's contract as a fact without asking for a proof of the body." The prover then uses the contract at call sites exactly as it uses any other callee's contract — asserting the `requires:` and assuming the `ensures:`.

```lyric
@axiom("System.Math.Abs contract — documented in BCL spec")
extern func mathAbs(n: in Int): Int
  ensures: result >= 0
  ensures: result == n or result == -n
```

A `@proof_required` package that calls this function gets to assume `result >= 0` and `result == n or result == -n` after every call, without the prover ever looking at `System.Math.Abs`'s implementation.

The cost of this convenience is clear: a wrong axiom produces a wrong proof. If `mathAbs` actually returned a negative number in some edge case, and the proof relied on `result >= 0`, the proof would be unsound. The program would be certified as correct when it is not.

This is why axiom boundaries are socially heavyweight in Lyric. Every `@axiom` line appears in the package's contract metadata and in code review diffs. The decision log (D013) frames them as "explicit trust" — you are declaring that you trust this contract enough to stake the correctness of your proof on it. That declaration should be deliberate and reviewable.

The practical rule: keep axiom blocks small and tied to well-documented external specifications (BCL contracts, RFC-specified network protocols). Do not axiom away your own code.

## §17.7 `@proof_required(unsafe_blocks_allowed)`

Occasionally a function inside a `@proof_required` package makes a call the prover cannot reason about, and the `@axiom` pattern is not appropriate because the function is not an extern boundary — it is internal code with complex behavior. The escape hatch is `unsafe { }`:

```lyric
@proof_required(unsafe_blocks_allowed)
package Transfer

pub func executeWithAudit(
  from: in Account,
  to: in Account,
  amount: in Amount
): Result[(Account, Account), TransferError]
  requires: from.id != to.id
  ensures: result.isOk implies {
    val (newFrom, newTo) = result.value
    newFrom.balance + newTo.balance == from.balance + to.balance
  }
{
  unsafe {
    val logged = AuditLog.record(from.id, to.id, amount)
    assert(logged.isOk)
  }
  return execute(from, to, amount)
}
```

Inside an `unsafe { }` block, the prover generates no obligations. The `assert(logged.isOk)` at the end of the block becomes an *assumed* fact for the rest of the function — the prover treats it as if it were a proved hypothesis. If the assertion is wrong at runtime, the program will produce a bug; but the proof of the surrounding code can proceed.

Use `unsafe { }` sparingly and document the manual justification. Every `unsafe` block is a gap in the proof. The `(unsafe_blocks_allowed)` annotation forces you to declare the gap at the package level rather than hiding it inside a function body — anyone reading the package annotation knows to look for the blocks.

::: sidebar
**What is Z3?** Z3 is an SMT (Satisfiability Modulo Theories) solver built by Microsoft Research. Given a formula in a supported theory, Z3 can prove it always true, prove it sometimes false (producing a counterexample), or report `unknown` when the formula is outside what it can decide. Lyric feeds it the verification conditions generated from your contracts. You do not need to understand SMT theory to use `lyric prove` — the VC generator handles the translation — but it helps to know that Z3 works with decidable fragments (linear arithmetic, algebraic datatypes, finite quantifiers, bit vectors) and struggles outside those fragments. When Z3 reports `unknown`, it is telling you the formula is in territory it cannot decide, not that the formula is false. Chapter 18 covers the decidable fragment and what to do at its edges.
:::

## §17.8 `@proof_required(checked_arithmetic)`

Financial code has a particular concern: arithmetic operations that overflow silently. On 64-bit integers, `Long.max + 1` wraps around and becomes a large negative number, which can corrupt a balance.

The `checked_arithmetic` modifier adds an overflow VC to every arithmetic operation in the package:

```lyric
@proof_required(checked_arithmetic)
package Account

pub func credit(a: in Account, amount: in Amount): Result[Account, AccountError]
  ensures: result.isOk implies result.value.balance == a.balance + amountValue(amount)
{
  val v = amountValue(amount)
  if a.balance + v > 1_000_000_000_00 {
    return Err(OverflowError)
  }
  return Ok(a.copy(balance = a.balance + v))
}
```

With `checked_arithmetic`, the expression `a.balance + v` inside the `if` condition generates an additional goal: prove that the addition does not overflow `Long.max`. Because `a.balance` is of type `Cents` (range `0 ..= 1_000_000_000_00`) and `v` is also `Cents`, the sum is at most `2_000_000_000_00`, which is well within `Long.max`. Z3 discharges the overflow VC automatically.

The modifier is optional because overflow VCs add goals, and goals take time. For non-financial code, the overhead is not worth it. For any package that handles monetary amounts, enabling it provides a static guarantee that arithmetic never wraps — a guarantee runtime checking cannot provide because overflow is not an exception.

## Exercises

1. Create a package with `func divide(n: in Int, d: in Int): Int requires: d != 0 ensures: result * d + (n % d) == n` and mark it `@proof_required`. Run `lyric prove`. What goals does the verifier produce? Are they discharged by the trivial discharger or does Z3 engage?

2. Remove the `ensures:` clause from `debit` in the banking example, leaving `credit`'s postcondition in place. Mark `Transfer` `@proof_required` and try to prove `execute`'s conservation postcondition. What does the verifier report? What is missing from the hypothesis set in `--explain` output?

3. Work through the conservation proof step by step: start with `@proof_required` packages but no postconditions on `debit` and `credit`. Run `lyric prove --json` and capture the counterexample. Add `debit`'s postcondition, run again. Add `credit`'s, run again. Describe the progression.

4. Run `lyric prove --explain --goal 0` on the passing transfer proof. List the hypotheses shown. Which hypothesis corresponds to `debit`'s postcondition? Which to the `Account` range invariant? Which to the `requires:` precondition on `execute`?

5. Mark a module `@proof_required` that imports a `@runtime_checked` package. What diagnostic code does the compiler report? What are the two paths to resolve it — modifying the import target or adding an axiom boundary — and what does each commit you to?
