/// Ledger.Accounting — domain types and machine-checked accounting invariants.
///
/// Every function in this package is verified by the Phase 4 proof engine.
/// Run standalone with:
///
///   lyric prove examples/ledger/src/accounting.l --verbose
///
/// The three public proof obligations:
///
///   makeDebit        — a debit entry carries the exact transfer amount on the
///                      source account and bears the "debit" label.
///   makeCredit       — symmetric for the destination account / "credit" label.
///   balancePreservation — crediting B by X and debiting A by X leaves the
///                      sum (A + B) unchanged; Z3 closes this as a linear
///                      arithmetic tautology.
///
/// Runtime-checked packages (Ledger.Accounts, Ledger.Transfers) call these
/// functions; the mode checker (V0002) permits runtime-checked → proof-required
/// calls in that direction only.

@proof_required
package Ledger.Accounting

import Std.Core

// ─── Identity types ───────────────────────────────────────────────────────────
//
// Distinct type aliases turn ID-swap bugs into compile errors.
// `type X = Long` produces a nominally distinct type; values of type Long
// are not assignable to AccountId without an explicit constructor, and vice
// versa.  The bootstrap emitter represents them as Long at the CLR level.

/// Nominal account identifier.  Not interchangeable with TransferId.
pub type AccountId  = Long

/// Nominal transfer identifier.  Not interchangeable with AccountId.
pub type TransferId = Long

/// Nominal ledger-entry identifier.
pub type EntryId    = Long

// ─── Amount ───────────────────────────────────────────────────────────────────

/// A monetary amount in integer minor units (cents for USD, pence for GBP, …).
/// The range constraint makes negative amounts a compile-time type error in
/// @proof_required code and a runtime panic in @runtime_checked code.
pub type Amount = Long range 0 ..= 9_223_372_036_854_775_807

// ─── Account kind ─────────────────────────────────────────────────────────────

pub enum AccountKind {
  case Asset
  case Liability
  case Equity
  case Income
  case Expense
}

pub func accountKindLabel(k: in AccountKind): String {
  match k {
    case AccountKind.Asset     -> "asset"
    case AccountKind.Liability -> "liability"
    case AccountKind.Equity    -> "equity"
    case AccountKind.Income    -> "income"
    case AccountKind.Expense   -> "expense"
  }
}

pub func accountKindFromString(s: in String): Option[AccountKind] {
  match s {
    case "asset"     -> Some(value = AccountKind.Asset)
    case "liability" -> Some(value = AccountKind.Liability)
    case "equity"    -> Some(value = AccountKind.Equity)
    case "income"    -> Some(value = AccountKind.Income)
    case "expense"   -> Some(value = AccountKind.Expense)
    case _           -> None
  }
}

// ─── Domain records ───────────────────────────────────────────────────────────

pub record Account {
  id:        Long
  name:      String
  kind:      AccountKind
  currency:  String
  createdAt: String
}

pub record Transfer {
  id:        Long
  fromId:    Long
  toId:      Long
  amount:    Long
  note:      String
  createdAt: String
}

pub record LedgerEntry {
  id:         Long
  transferId: Long
  accountId:  Long
  amount:     Long
  side:       String    // "debit" or "credit"
  createdAt:  String
}

// ─── Error type ───────────────────────────────────────────────────────────────

pub enum LedgerError {
  case AccountNotFound(id: Long)
  case TransferNotFound(id: Long)
  case InsufficientFunds(accountId: Long, balance: Long, needed: Long)
  case SameAccount
  case InvalidAmount
  case DatabaseError(message: String)
}

pub func errorMessage(e: in LedgerError): String {
  match e {
    case LedgerError.AccountNotFound(id) ->
      "account " + id.toString() + " not found"
    case LedgerError.TransferNotFound(id) ->
      "transfer " + id.toString() + " not found"
    case LedgerError.InsufficientFunds(accountId, balance, needed) ->
      "insufficient funds on account " + accountId.toString() +
      ": balance " + balance.toString() + ", needed " + needed.toString()
    case LedgerError.SameAccount ->
      "source and destination accounts must differ"
    case LedgerError.InvalidAmount ->
      "amount must be greater than zero"
    case LedgerError.DatabaseError(msg) ->
      "database error: " + msg
  }
}

// ─── Provable accounting invariants ───────────────────────────────────────────

/// Construct the debit side of a double-entry transfer.
///
/// Proved properties (verifier closes by substitution):
///   result.amount    == amount      — exact amount, no rounding
///   result.side      == "debit"     — correct ledger side
///   result.accountId == accountId   — charged to the right account
pub func makeDebit(
  transferId: in Long,
  accountId:  in Long,
  amount:     in Long
): LedgerEntry
  requires: amount > 0
  ensures:  result.amount    == amount
  ensures:  result.side      == "debit"
  ensures:  result.accountId == accountId
{
  return LedgerEntry(
    id         = 0,
    transferId = transferId,
    accountId  = accountId,
    amount     = amount,
    side       = "debit",
    createdAt  = "")
}

/// Construct the credit side of a double-entry transfer.
///
/// Symmetric to makeDebit; the verifier closes by substitution.
pub func makeCredit(
  transferId: in Long,
  accountId:  in Long,
  amount:     in Long
): LedgerEntry
  requires: amount > 0
  ensures:  result.amount    == amount
  ensures:  result.side      == "credit"
  ensures:  result.accountId == accountId
{
  return LedgerEntry(
    id         = 0,
    transferId = transferId,
    accountId  = accountId,
    amount     = amount,
    side       = "credit",
    createdAt  = "")
}

/// The double-entry identity: transferring X from A to B leaves the total
/// balance (A + B) unchanged.
///
/// Proved by Z3 as a linear arithmetic tautology (or by the trivial
/// syntactic discharger after normalisation).  The `assert` statement
/// adds the identity to the assumed hypotheses for the `return` goal,
/// so the verifier closes the `ensures` without an external solver.
///
/// Call site (Ledger.Transfers.recordTransfer) must satisfy the `requires`
/// preconditions before the transfer is written to the database — the mode
/// checker enforces this via the Hoare call rule.
pub func balancePreservation(
  fromBalance: in Long,
  toBalance:   in Long,
  amount:      in Long
): Bool
  requires: amount > 0
  requires: fromBalance >= amount
  ensures:  result == true
  ensures:  (fromBalance - amount) + (toBalance + amount) == fromBalance + toBalance
{
  assert (fromBalance - amount) + (toBalance + amount) == fromBalance + toBalance
  return true
}
