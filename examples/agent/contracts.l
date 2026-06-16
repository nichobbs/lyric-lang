//! Contract examples: requires, ensures, invariants, assert, old().
package Examples.Contracts
import Std.Core

// ─── Basic precondition and postcondition ────────────────────────────────────

pub func divide(n: in Int, d: in Int): Int
  requires: d != 0
  ensures: result * d + (n % d) == n
{
  return n / d
}

// ─── Multiple requires clauses ───────────────────────────────────────────────

pub func transfer(from: in Account, to: in Account, amount: in Amount): Result[TransferReceipt, TransferError]
  requires: from.id != to.id
  requires: amount > 0
{
  // ...
}

// ─── ensures with implies ────────────────────────────────────────────────────

pub func debit(a: in Account, amount: in Amount): Result[Account, AccountError]
  ensures: result.isOk implies result.value.balance == a.balance - amountValue(amount)
  ensures: result.isErr implies a.balance < amountValue(amount)
{
  if a.balance < amountValue(amount) {
    return Err(InsufficientFunds)
  }
  return Ok(a.copy(balance = a.balance - amountValue(amount)))
}

// ─── old() for pre-state in postconditions ───────────────────────────────────

func push(s: inout Stack[T], x: in T): Unit
  ensures: s.depth == old(s.depth) + 1
  ensures: s.top() == x
{
  // ...
}

// ─── forall in ensures ───────────────────────────────────────────────────────

pub func nonNegativeAll(xs: in slice[Int]): slice[Int]
  ensures: forall (x: Int) where result.contains(x) implies x >= 0
{
  return xs.filter { x -> x >= 0 }
}

// ─── assert vs requires ──────────────────────────────────────────────────────

pub func processItems(items: in slice[Item]): slice[Result[Processed, ItemError]]
  requires: items.length > 0              // caller obligation: PreconditionViolated if broken
{
  var results: slice[Result[Processed, ItemError]] = []
  for item in items {
    val processed = transform(item)
    assert(processed.id == item.id, "transform must preserve id")  // internal: AssertionFailed
    results = results.append(Ok(processed))
  }
  return results
}

// ─── opaque type with invariant ──────────────────────────────────────────────

pub opaque type Account {
  balance: Cents
  invariant: balance >= 0 and balance <= 1_000_000_000_00

  pub func make(initial: in Cents): Result[Account, ContractViolation] {
    if initial < 0 or initial > 1_000_000_000_00 {
      return Err(ContractViolation("balance out of range"))
    }
    return Ok(Account(balance = initial))
  }

  pub func balance(self: in Account): Cents = self.balance
}

// ─── @proof_required package annotation (declared at file top) ───────────────

// @proof_required
// package Money
//
// Enables: SMT verification of all contracts before compilation
// Restriction: may only call other @proof_required packages, primitives, or @axiom externs
// Run: lyric prove money.l
//      lyric prove --explain --goal 0 money.l
//      lyric prove --json money.l

// ─── @axiom for trusted extern boundaries ────────────────────────────────────

// @axiom("BCL System.Math spec")
// extern func mathAbs(n: in Int): Int
//   ensures: result >= 0
//   ensures: result == n or result == -n
