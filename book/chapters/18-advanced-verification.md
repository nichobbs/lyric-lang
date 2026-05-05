# Advanced Verification

The previous chapter covered the shape of `@proof_required` verification: how to annotate a module, what `lyric prove` outputs, and how the Hoare call rule lets you prove `execute` from `debit` and `credit`'s contracts without re-analysing their bodies. This chapter goes deeper. You will see `old()` used in the full range of situations it was designed for, encounter `forall` and `exists` in both runtime and proof mode, work through the inductive reasoning the BST example requires, and develop a practical sense of where the SMT solver succeeds and where it does not. By the end you will know how to write contracts for complex data structures and how to recognize when a contract is about to push outside what the prover can discharge.

Not every contract in the world is provable. The SMT solver Z3 is fast and powerful within its decidable fragment — linear arithmetic, algebraic datatypes, bounded quantifiers — and silent when something falls outside it. That boundary is not a bug; it is the natural limit of automated reasoning over arbitrary programs. Understanding where the line falls, and how to either stay within it or handle the cases where you cannot, is most of what distinguishes a practitioner who uses `@proof_required` effectively from one who annotates a package and then fights the prover.

One theme runs through everything in this chapter: the contracts you write determine what the prover can do. A weak postcondition on a helper function leaves a gap in every proof that calls it. A `forall` over an unbounded domain makes goals undecidable. An `old()` that captures exactly what it needs — and nothing more — gives the prover the right fact at the right cost. The discipline of writing good contracts for verification is the discipline of writing contracts that are precise about what you mean.

## §18.1 `old()` in ensures clauses

The `old()` form is how postconditions refer to the pre-state of a function call — the values of arguments and fields at the moment the function was invoked, before any mutation occurred. You saw a brief introduction in Chapter 8. This section works through the full Stack example to show the complete picture.

Here is the immutable stack from worked example 11:

```lyric
@proof_required
package Stack

generic[T] pub opaque type Stack {
  items: slice[T]
}

generic[T] pub func push(s: in Stack[T], x: in T): Stack[T]
  ensures: result.items.length == old(s.items.length) + 1
  ensures: result.items[old(s.items.length)] == x
  ensures: forall (i: Nat) where i < old(s.items.length)
              implies result.items[i] == old(s.items[i])
{
  return Stack(items = s.items.append(x))
}
```

`old(s.items.length)` is the length of the stack when `push` was called. The first postcondition says the length increases by exactly one. The second says the new top element is `x`. The third says all existing elements are preserved at their original indices.

Because `s` is an `in` parameter — read-only — you might wonder whether `old` is even necessary here. The parameter will not change during the function's body, so `s.items.length` at the end of the function is the same as `s.items.length` at entry. That is true for `in` parameters. The convention is to use `old` for clarity about intent, and the prover accepts both forms for `in` parameters.

The situation is different for `inout` parameters. Consider a version of push that modifies the stack in place:

```lyric
generic[T] pub func pushInPlace(s: inout Stack[T], x: in T): Unit
  ensures: s.items.length == old(s.items.length) + 1
  ensures: s.items[old(s.items.length)] == x
{
  s = Stack(items = s.items.append(x))
}
```

Here `s.items.length` in the `ensures:` clause refers to the *post-state* — the length after the push. Without `old`, you could not write `s.items.length == old(s.items.length) + 1`; you would have only the post-state available, and the claim `s.items.length == s.items.length + 1` would be nonsensical. `old` is what makes postconditions about mutations expressible.

The snapshot is taken after `requires:` succeeds and before the body runs. The cost is proportional to what the contract reads: `old(s.items.length)` captures one integer; `old(s.items)` would capture a full slice snapshot. For the length contract, the runtime pays for one integer and nothing more. The contract validator reads the `old(...)` expressions syntactically and arranges for exactly those values to be snapshotted — not the whole parameter, just the fields the contract references.

There is a common mistake worth naming explicitly. Suppose you write:

```lyric
ensures: result.items.length == s.items.length + 1     // incorrect for inout
```

For an `inout` parameter, `s.items.length` in an `ensures:` clause refers to the post-state. After a push, the post-state length is `old_length + 1`. So this postcondition becomes `old_length + 1 == old_length + 1 + 1`, which is false — the prover reports a counterexample. For `in` parameters the mistake is less harmful because the pre-state and post-state are the same, but the intent is obscured. Use `old` wherever you mean "the value at the start of the call."

## §18.2 Universal and existential quantifiers

Lyric's contract sublanguage has two quantifiers: `forall` and `exists`. Their behavior differs between `@runtime_checked` and `@proof_required` mode, and the difference matters for both correctness and tractability.

**In `@runtime_checked` mode**, quantifiers iterate. The domain must be finitely enumerable — a slice, a set, a list, a finite enum, or a range subtype. The runtime walks the collection and checks the body for each element:

```lyric
@runtime_checked
package Filtering

pub func keepPositive(xs: in slice[Int]): slice[Int]
  ensures: forall (x: Int) where result.contains(x) implies x > 0
  ensures: forall (x: Int) where xs.contains(x) and x > 0 implies result.contains(x)
{
  return xs.filter { v -> v > 0 }
}
```

When this function returns, the runtime walks `result` and checks that every element is positive, then walks `xs` and checks that every positive element appears in `result`. If either check fails, the runtime stops at the first violating element and includes it in the counterexample output.

A `forall (x: Int)` over all integers — without constraining the domain to a specific collection — is a static error in `@runtime_checked` mode. There is no finite collection to iterate.

**In `@proof_required` mode**, quantifiers become logical formulae. The SMT solver reasons about them without enumeration, which means they can range over infinite domains:

```lyric
@proof_required
package SortedSet

generic[T] pub func insert(s: in SortedSet[T], x: in T): SortedSet[T]
  where T: Compare
  ensures: contains(result, x)
  ensures: forall (y: T) where contains(s, y) implies contains(result, y)
  ensures: size(result) == (if contains(s, x) then size(s) else size(s) + 1)
```

The `forall (y: T)` here is not iterated at runtime — in `@proof_required` mode it becomes a universally-quantified formula that Z3 reasons about. For `T: Int`, Z3 can discharge it because integer arithmetic and the datatype encoding of sorted sets sit within the decidable fragment. For `T: String`, the quantifier ranges over strings with an ordering relation, which pushes outside Z3's decidable fragment for free quantifiers; the prover may report `unknown` for some goals.

`exists` works analogously. It becomes an existential formula for the SMT solver, which can discharge it by finding a witness. `exists (x: T) where xs.contains(x) and x > threshold` translates to "there is an element in `xs` greater than `threshold`," which Z3 can verify or refute for integer-typed collections.

The practical advice: write `forall` and `exists` freely in `@proof_required` mode for integer-typed collections and bounded ranges. Be cautious with string or floating-point domains — check whether the goals discharge before relying on them.

## §18.3 The sorted set example

Worked example 3 demonstrates the pattern:

```lyric
@proof_required
package SortedSet

generic[T] pub func insert(s: in SortedSet[T], x: in T): SortedSet[T]
  where T: Compare
  ensures: contains(result, x)
  ensures: forall (y: T) where contains(s, y) implies contains(result, y)
  ensures: size(result) == (if contains(s, x) then size(s) else size(s) + 1)
```

For `SortedSet[Int]`, all three postconditions are in the decidable fragment. Z3 handles them in milliseconds:

- `contains(result, x)` — a lookup property on an algebraic datatype with integer keys.
- The `forall` — a conservation property: if `y` was in the set before insertion, it is still there. Z3 reasons about this using the datatype encoding of the sorted set.
- The size postcondition — integer arithmetic plus a conditional. Linear arithmetic with a conditional branch is textbook for Z3.

For `SortedSet[String]`, the situation changes. The first postcondition (`contains(result, x)`) likely discharges — it is a datatype property that does not depend on ordering reasoning. The second (`forall (y: T) ...`) depends on the ordering relation `Compare` instantiated for strings, which string comparison imposes. Z3's string theory handles equality and length well but ordering over arbitrary string values is outside the decidable fragment for free quantifiers. The prover will likely report `unknown` for this goal.

The size postcondition depends on whether `contains(s, x)` is decidable for the string key type. String equality is in the decidable fragment; the size goal likely discharges.

When you run `lyric prove` on `SortedSet[String]` and see `unknown`:

```
sortedSet.l:18:3: warning V0010: ensures (conservation) — unknown
  goal: insert/ensures/∀y. contains(s, y) ⇒ contains(result, y)
  note: string ordering quantifier outside decidable fragment
  options: narrow the contract, add a @pure lemma, or shift to @runtime_checked
```

The verifier tells you the goal is unresolved and gives you the next steps. The program is not certified as correct for `T: String` — it just has obligations the prover cannot discharge. Chapter 14 (property-based testing) complements the proof here: runtime testing over many generated inputs catches violations the prover cannot rule out statically.

## §18.4 Inductive data structures — the BST

Worked example 10 is the binary search tree. It is a good demonstration of how the prover handles recursive data structures:

```lyric
@proof_required
package Bst

generic[K] pub union Tree
  where K: Compare
{
  case Leaf
  case Node(left: Tree[K], key: K, right: Tree[K])
}

generic[K] @pure pub func isBst(t: in Tree[K]): Bool
  where K: Compare
{
  return match t {
    case Leaf -> true
    case Node(l, key, r) ->
      isBst(l) and isBst(r) and
      forall (lk: K) where keys(l).contains(lk) implies lk < key and
      forall (rk: K) where keys(r).contains(rk) implies rk > key
  }
}

generic[K] pub func insert(t: in Tree[K], k: in K): Tree[K]
  where K: Compare
  requires: isBst(t)
  ensures:  isBst(result)
  ensures:  contains(result, k)
  ensures:  forall (other: K) where contains(t, other) implies contains(result, other)
```

The `isBst` function is marked `@pure`, which makes it usable in contract expressions. The prover uses its definition as a rewrite rule: whenever it sees `isBst(Node(l, key, r))` in a formula, it can expand the definition.

For `K: Int`, Z3 discharges all three postconditions of `insert`. The key reasoning steps are:

1. **`isBst(result)`**: The implementation inserts into the left subtree when `k < key` and the right subtree when `k > key`. The prover expands `isBst` and verifies that the ordering invariant is maintained by the recursive structure. This involves reasoning over an inductive datatype, which Z3's algebraic datatype theory handles.

2. **`contains(result, k)`**: The inserted key is present. Base case: inserting into `Leaf` produces `Node(Leaf, k, Leaf)`, and `contains(Node(Leaf, k, Leaf), k)` is true by definition. Inductive case: the key goes either left or right; the recursive call ensures it is present in that subtree.

3. **The conservation `forall`**: Every key already in the tree remains present. This follows from the implementation's structure — the recursive cases preserve existing nodes.

For `K: String`, the third postcondition (the `forall` conservation) may push the solver to `unknown`, for the same reason as the sorted set case: free quantifiers over string ordering are outside the decidable fragment. The first two postconditions are more likely to discharge since they involve datatype membership rather than ordering.

When the solver discharges the goals, it typically takes milliseconds for any tree depth the VC generator can represent — the proof does not run on a specific tree, it reasons about all trees abstractly.

## §18.5 The decidable fragment

Knowing what discharges deterministically helps you write contracts that stay within it and recognize when you have stepped outside.

**What discharges well:**

- Linear integer arithmetic — sums, differences, multiplications by constants, comparisons. `a + b == c + d`, `x >= 0 and x <= 100`, `n * 2 == m` (constant multiplier).
- Fixed-size or bounded arrays and slices where the length is constrained by a range-typed index. `xs.length == old(xs.length) + 1` when `xs.length` is in a named range type.
- Quantifiers over finite ranges from range subtypes — `forall (i: Nat range 0 ..= 9) implies xs[i] >= 0`. The range is finite; Z3 can enumerate it or reason about it within bounded LIA.
- Quantifiers over slice lengths bounded by range-typed indices — `forall (i: Nat) where i < xs.length implies xs[i] > 0`, when `xs.length` is bounded by a range type.
- Propositional combinations of the above — `and`, `or`, `not`, `implies` over arithmetic facts.
- Algebraic datatypes (records, unions) with the above arithmetic in their fields.

**What pushes outside:**

- Free quantifiers over `String` — `forall (s: String) implies ...` without the domain being a finite collection. String ordering (lexicographic `<`) is not in Z3's decidable LIA fragment.
- Non-linear arithmetic where both operands are symbolic — `n * m` where both `n` and `m` are variables, not constants. This is outside LIA and into nonlinear arithmetic, where Z3 may time out or return `unknown`.
- Recursive functions with complex invariants and deep nesting — `isBst` of depth 10 is fine; a mutually recursive function pair with a shared invariant and non-trivial base cases may exhaust Z3's resources.
- Floating-point arithmetic — decidable in IEEE 754 theory but notoriously slow, and many operations produce formulas Z3 cannot close in a reasonable time budget.

**When the prover says `unknown`:**

You have four options, roughly in order of preference:

1. **Narrow the contract**. Instead of a universal `forall (x: String)`, restrict to a finite collection: `forall (x: String) where result.contains(x) implies ...`. The bounded domain is more tractable.

2. **Split into lemmas**. Write a `@pure` helper function that captures an intermediate property, give it an `ensures:` clause, and let the prover discharge the lemma separately. The main function's proof then uses the lemma's postcondition as a hypothesis. Smaller goals discharge more often.

3. **Shift to `@runtime_checked`**. Not every property needs static verification. If the obligation is outside the fragment, `@runtime_checked` catches violations for all inputs the program actually runs with. This is not a failure of verification; it is an appropriate use of the right tool.

4. **Use `unsafe { assert(...) }`** with an explicit manual justification. Reserve this for cases where you are confident the property holds and have a manual argument for it.

## §18.6 Lemmas and `@pure` helper functions

Large proofs often decompose cleanly into smaller, independently verifiable lemmas. Lyric supports this through `@pure` functions with `ensures:` clauses that the prover can use as hypotheses.

Here is the pattern applied to the balance conservation property:

```lyric
@pure func balancesConserved(
  before: (Cents, Cents),
  after: (Cents, Cents),
  amount: Cents
): Bool
  ensures: result implies
    after.0 + after.1 == before.0 + before.1 and
    after.0 == before.0 - amount and
    after.1 == before.1 + amount
{
  val (fromBefore, toBefore) = before
  val (fromAfter, toAfter) = after
  return fromAfter == fromBefore - amount and
         toAfter == toBefore + amount
}
```

This is a `@pure` function — it has no side effects and its body uses only arithmetic and comparisons. The `ensures:` clause captures the key conservation fact. The prover verifies the lemma once, when `balancesConserved` is compiled. After that, any `@proof_required` function that calls `balancesConserved` can assume its postcondition at the call site.

The main function then states its postcondition in terms of the lemma:

```lyric
pub func execute(
  from: in Account,
  to: in Account,
  amount: in Amount
): Result[(Account, Account), TransferError]
  requires: from.id != to.id
  ensures: result.isOk implies {
    val (newFrom, newTo) = result.value
    balancesConserved(
      (from.balance, to.balance),
      (newFrom.balance, newTo.balance),
      amountValue(amount)
    )
  }
```

At the call site to `balancesConserved` in the postcondition, the prover uses the lemma's `ensures:` to conclude the arithmetic facts. The proof of `execute` becomes: prove that the arguments to `balancesConserved` are what we claim, then apply the lemma's postcondition.

Breaking a large proof into named lemmas has two benefits: individual goals are smaller and more tractable for Z3, and the intermediate properties are named and can be understood independently. A failing goal now points to a specific lemma rather than to a large multi-clause postcondition.

## §18.7 Knowing when to stop

::: sidebar
**Should I use `@proof_required` for everything?** The answer is no, and it is worth being explicit about why. SMT verification is powerful but not free. Every contract obligation becomes an SMT query; a complex package can generate hundreds of goals. Some of those goals may be in the undecidable fragment, requiring manual intervention. Writing `ensures:` clauses precise enough to let the prover succeed takes discipline and iteration — it is more work than writing runtime-only contracts. The compilation time is longer; CI pipelines need to accommodate the solver's budget. The value is highest for money handling, safety-critical invariants, and security properties where the cost of a missed bug in production is large. For glue code, HTTP handlers, and UI-facing logic, `@runtime_checked` with well-written contracts gives most of the safety benefit at a fraction of the effort. Reach for `@proof_required` deliberately, for the packages where the stakes are high enough to justify it.
:::

The right approach is layered. Write contracts everywhere — `@runtime_checked` lets you define and enforce invariants immediately without any proof investment. Pick the packages where the invariants are the most critical and the domain is arithmetic-heavy, mark those `@proof_required`, and let the prover certify them. Leave the rest `@runtime_checked`. The `@proof_required` layer is thin and well-scoped; the `@runtime_checked` layer catches everything else at runtime.

The verification story in Lyric is not "prove everything" — it is "prove the things worth proving, check the rest." Both layers write contracts in the same syntax, use the same `requires:`/`ensures:` keywords, and produce the same counterexample format when something goes wrong. The choice of verification level is about depth of guarantee, not about a different style of programming.

## Exercises

1. Write `func safeAdd(a: in Cents, b: in Cents): Result[Cents, OverflowError]` in a package marked `@proof_required(checked_arithmetic)`. Add an `ensures:` clause that says `result.isOk implies result.value == a + b`. Run `lyric prove`. Does the overflow check discharge? What additional postcondition is needed to ensure `result.isErr implies a + b > Cents.max`?

2. Write `func filter[T](xs: in slice[T], pred: in (T -> Bool)): slice[T]` with two `ensures:` clauses: one using `forall` (every element of `result` satisfies `pred`) and one using `forall` (every element of `xs` satisfying `pred` appears in `result`). In `@runtime_checked` mode, both clauses iterate. In `@proof_required` mode, which discharges and which requires a more concrete domain type to be tractable?

3. Take the BST `insert` function with `K: String`. Run `lyric prove`. Which of the three postconditions — `isBst(result)`, `contains(result, k)`, the conservation `forall` — produce `unknown`? For the ones that do, try narrowing the contract by changing the `forall` to iterate over a bounded `slice[String]` extracted from the tree. Does that help?

4. Write a `@pure` lemma `func monotoneInsert(before: SortedSet[Int], after: SortedSet[Int], x: Int): Bool ensures: result implies (forall (y: Int) where contains(before, y) implies contains(after, y))`. Mark it `@pure` and use it in an `insert` postcondition. Run `lyric prove`. Does the prover discharge the goal using the lemma's postcondition as a hypothesis?

5. Write a function `func adjustBalance(a: inout Account, delta: in Int): Unit ensures: a.balance == old(a.balance) + delta` where `a` is an `inout` parameter. Implement it correctly, then implement a version that applies `delta * 2`. Observe that the prover reports a counterexample for the incorrect version. Verify that the correct version discharges. Then check: does the `Account` invariant (`balance >= 0`) generate an additional goal? What happens if `delta` can be negative?
