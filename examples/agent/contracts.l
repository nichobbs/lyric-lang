//! Contract examples: requires, ensures, invariants, assert, old().
package Examples.Contracts

import Std.Core
import Std.Collections

// ─── Basic precondition and postcondition ────────────────────────────────────
pub func divide(n: in Int, d: in Int): Int
  requires: d != 0
  ensures: result * d + (n % d) == n
{
  return n / d
}

// ─── Multiple requires clauses ───────────────────────────────────────────────
pub type Cents = Long range 0 ..= 100_000_000_000

pub record Account {
  pub id: Long
  pub balance: Cents
}

pub record TransferReceipt {
  pub fromId: Long
  pub toId: Long
  pub amount: Long
}

pub union TransferError {
  case InsufficientFunds(needed: Long)
}

pub func transfer(source: in Account, target: in Account, amount: in Long): Result[TransferReceipt, TransferError]
  requires: source.id != target.id
  requires: amount > 0
{
  if source.balance.toLong() < amount {
    return Err(error = InsufficientFunds(needed = amount))
  }
  return Ok(value = TransferReceipt(fromId = source.id, toId = target.id, amount = amount))
}

// ─── ensures with implies ────────────────────────────────────────────────────
pub union AccountError {
  case Overdrawn
}

pub func debit(a: in Account, amount: in Long): Result[Account, AccountError]
  requires: amount > 0
  ensures: result.isOk implies a.balance.toLong() >= amount
  ensures: result.isErr implies a.balance.toLong() < amount
{
  if a.balance.toLong() < amount {
    return Err(error = Overdrawn)
  }
  return Ok(value = Account(id = a.id, balance = Cents.from(a.balance.toLong() - amount)))
}

// ─── old() for pre-state in postconditions ───────────────────────────────────
pub func incr(counter: inout Int): Unit
  ensures: counter == old(counter) + 1
{
  counter = counter + 1
}

// ─── forall in ensures ───────────────────────────────────────────────────────
pub func nonNegativeOnly(xs: in slice[Int]): List[Int]
  ensures: forall (x: Int) where result.contains(x) implies x >= 0
{
  val kept: List[Int] = newList()
  for x in xs {
    if x >= 0 {
      kept.add(x)
    }
  }
  return kept
}

// ─── assert vs requires ──────────────────────────────────────────────────────
pub func doubleAll(items: in slice[Int]): List[Int]
  requires: items.length > 0
{
  // caller obligation: PreconditionViolated if broken
  val results: List[Int] = newList()
  for item in items {
    val doubled = item * 2
    assert(doubled - item == item, "doubling must add the item once")  // internal: AssertionFailed
    results.add(doubled)
  }
  return results
}

// ─── opaque type with invariant ──────────────────────────────────────────────
pub opaque type Wallet {
  balance: Long
  invariant: balance >= 0 and balance <= 1_000_000_000_00
}

pub func makeWallet(initial: in Long): Result[Wallet, String] {
  if initial < 0 or initial > 1_000_000_000_00 {
    return Err(error = "balance out of range")
  }
  return Ok(value = Wallet(balance = initial))
}

pub func walletBalance(self: in Wallet): Long = self.balance

// ─── @proof_required package annotation (declared at file top) ───────────────
// @proof_required
// package Money
//
// Enables: SMT verification of all contracts before compilation
// Restriction: may only call other @proof_required packages, primitives, or @axiom externs
// Run: lyric prove money.l
//      lyric prove --explain --goal 0 money.l
//      lyric prove --json money.l
func main(): Unit {
  println("divide: ${toString(divide(17, 5))}")

  val a = Account(id = 1, balance = Cents.from(500))
  val b = Account(id = 2, balance = Cents.from(0))
  match transfer(a, b, 200) {
    case Ok(receipt) -> println(
      "transferred ${toString(receipt.amount)} from ${toString(receipt.fromId)} to ${toString(receipt.toId)}"
    )
    case Err(InsufficientFunds(needed)) -> println("needs ${toString(needed)}")
  }
  match debit(a, 900) {
    case Ok(_) -> println("debited")
    case Err(_) -> println("overdrawn")
  }

  var n = 41
  incr(n)
  println("incr: ${toString(n)}")

  val kept = nonNegativeOnly([3, -1, 4, -1, 5])
  println("kept ${toString(kept.count)}")
  println("doubled ${toString(doubleAll([1, 2, 3]).count)}")

  match makeWallet(250) {
    case Ok(w) -> println("wallet ${toString(walletBalance(w))}")
    case Err(e) -> println("wallet error: ${e}")
  }
  match makeWallet(-1) {
    case Ok(_) -> println("unexpected")
    case Err(e) -> println("wallet error: ${e}")
  }
}
