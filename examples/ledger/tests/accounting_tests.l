// tests/accounting_tests.l — unit tests for Ledger.Accounting.
//
// Covers the @proof_required accounting invariants, account-kind utilities,
// and the LedgerError message formatter.  No I/O; every test is pure.
//
// Run:  lyric test examples/ledger/tests/accounting_tests.l

@test_module
package Ledger.AccountingTests

import Std.Core
import Std.Testing
import Ledger.Accounting

// ─── makeDebit ────────────────────────────────────────────────────────────────

test "makeDebit carries the transfer amount" {
  val entry = Ledger.Accounting.makeDebit(1, 42, 5000)
  assertEqual(entry.amount.toString(), "5000", "amount")
}

test "makeDebit labels the side as debit" {
  val entry = Ledger.Accounting.makeDebit(1, 42, 5000)
  assertEqual(entry.side, "debit", "side")
}

test "makeDebit assigns the correct accountId" {
  val entry = Ledger.Accounting.makeDebit(1, 42, 5000)
  assertEqual(entry.accountId.toString(), "42", "accountId")
}

test "makeDebit binds the transferId" {
  val entry = Ledger.Accounting.makeDebit(7, 42, 5000)
  assertEqual(entry.transferId.toString(), "7", "transferId")
}

// ─── makeCredit ───────────────────────────────────────────────────────────────

test "makeCredit carries the transfer amount" {
  val entry = Ledger.Accounting.makeCredit(1, 99, 5000)
  assertEqual(entry.amount.toString(), "5000", "amount")
}

test "makeCredit labels the side as credit" {
  val entry = Ledger.Accounting.makeCredit(1, 99, 5000)
  assertEqual(entry.side, "credit", "side")
}

test "makeCredit assigns the correct accountId" {
  val entry = Ledger.Accounting.makeCredit(1, 99, 5000)
  assertEqual(entry.accountId.toString(), "99", "accountId")
}

// ─── Double-entry identity ────────────────────────────────────────────────────

test "debit and credit amounts are equal for the same transfer" {
  val amount = 7500
  val debit  = Ledger.Accounting.makeDebit(10, 1, amount)
  val credit = Ledger.Accounting.makeCredit(10, 2, amount)
  assertEqual(debit.amount.toString(), credit.amount.toString(), "debit == credit")
}

test "debit and credit are on different accounts" {
  val debit  = Ledger.Accounting.makeDebit(1, 10, 100)
  val credit = Ledger.Accounting.makeCredit(1, 20, 100)
  assertTrue(debit.accountId != credit.accountId, "different accounts")
}

// ─── balancePreservation ─────────────────────────────────────────────────────
//
// balancePreservation is a proof oracle: its @proof_required contracts
// guarantee it returns true for every input that satisfies `requires:`.
// Inputs that violate `requires:` (e.g. fromBalance < amount) trigger a
// contract assertion rather than returning false, so negative "should return
// false" tests are not applicable to this function.

test "balancePreservation returns true" {
  val ok = Ledger.Accounting.balancePreservation(10000, 0, 3000)
  assertTrue(ok, "holds for typical transfer")
}

test "balancePreservation holds when from-balance exactly equals amount" {
  val ok = Ledger.Accounting.balancePreservation(5000, 1000, 5000)
  assertTrue(ok, "holds at exact balance boundary")
}

test "balancePreservation holds for large amounts" {
  val ok = Ledger.Accounting.balancePreservation(1000000, 500000, 999999)
  assertTrue(ok, "holds for large amounts")
}

test "balancePreservation holds for minimum transfer of 1" {
  val ok = Ledger.Accounting.balancePreservation(1, 0, 1)
  assertTrue(ok, "holds for 1-unit transfer")
}

// ─── accountKindLabel / accountKindFromString ─────────────────────────────────

test "accountKindFromString parses asset" {
  match Ledger.Accounting.accountKindFromString("asset") {
    case None    -> assertTrue(false, "should parse 'asset'")
    case Some(k) -> assertEqual(Ledger.Accounting.accountKindLabel(k), "asset", "round-trip")
  }
}

test "accountKindFromString parses liability" {
  match Ledger.Accounting.accountKindFromString("liability") {
    case None    -> assertTrue(false, "should parse 'liability'")
    case Some(k) -> assertEqual(Ledger.Accounting.accountKindLabel(k), "liability", "round-trip")
  }
}

test "accountKindFromString parses equity" {
  match Ledger.Accounting.accountKindFromString("equity") {
    case None    -> assertTrue(false, "should parse 'equity'")
    case Some(k) -> assertEqual(Ledger.Accounting.accountKindLabel(k), "equity", "round-trip")
  }
}

test "accountKindFromString parses income" {
  match Ledger.Accounting.accountKindFromString("income") {
    case None    -> assertTrue(false, "should parse 'income'")
    case Some(k) -> assertEqual(Ledger.Accounting.accountKindLabel(k), "income", "round-trip")
  }
}

test "accountKindFromString parses expense" {
  match Ledger.Accounting.accountKindFromString("expense") {
    case None    -> assertTrue(false, "should parse 'expense'")
    case Some(k) -> assertEqual(Ledger.Accounting.accountKindLabel(k), "expense", "round-trip")
  }
}

test "accountKindFromString returns None for unknown kind" {
  assertTrue(isNone(Ledger.Accounting.accountKindFromString("unknown")), "unknown → None")
}

test "accountKindFromString returns None for empty string" {
  assertTrue(isNone(Ledger.Accounting.accountKindFromString("")), "empty → None")
}

// ─── errorMessage ─────────────────────────────────────────────────────────────

test "errorMessage AccountNotFound contains the id" {
  val msg = Ledger.Accounting.errorMessage(LedgerError.AccountNotFound(id = 42))
  assertTrue(msg != "", "non-empty")
  // The id must appear somewhere in the message.
  val expected = "42"
  assertTrue(msg.indexOf(expected) >= 0, "message contains id 42")
}

test "errorMessage TransferNotFound contains the id" {
  val msg = Ledger.Accounting.errorMessage(LedgerError.TransferNotFound(id = 99))
  assertTrue(msg.indexOf("99") >= 0, "message contains id 99")
}

test "errorMessage InsufficientFunds contains balance and needed" {
  val msg = Ledger.Accounting.errorMessage(
    LedgerError.InsufficientFunds(accountId = 1, balance = 100, needed = 500))
  assertTrue(msg.indexOf("100") >= 0, "message contains balance")
  assertTrue(msg.indexOf("500") >= 0, "message contains needed")
}

test "errorMessage SameAccount mentions differ" {
  val msg = Ledger.Accounting.errorMessage(LedgerError.SameAccount)
  assertTrue(msg.indexOf("differ") >= 0, "message mentions 'differ'")
}

test "errorMessage InvalidAmount mentions zero" {
  val msg = Ledger.Accounting.errorMessage(LedgerError.InvalidAmount)
  assertTrue(msg.indexOf("zero") >= 0, "message mentions 'zero'")
}

test "errorMessage DatabaseError includes the driver message" {
  val msg = Ledger.Accounting.errorMessage(
    LedgerError.DatabaseError(message = "connection refused"))
  assertTrue(msg.indexOf("connection refused") >= 0, "includes driver message")
}
