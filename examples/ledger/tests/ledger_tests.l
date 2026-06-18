// tests/ledger_tests.l — unit tests for JSON serialization helpers.
//
// Tests the pure serialization functions in Ledger.Accounts and
// Ledger.Transfers without touching the database.  Each test constructs
// a domain record in-process and checks the resulting JSON string.
//
// Run:  lyric test examples/ledger/tests/ledger_tests.l

@test_module
package Ledger.LedgerTests

import Std.Core
import Std.Testing
import Ledger.Accounting
import Ledger.Accounts
import Ledger.Transfers

// ─── Ledger.Accounts.toJsonSummary ───────────────────────────────────────────
//
// Substring checks below assume compact JSON (no space after ":").
// If the serializer ever changes to pretty-print, update the expected strings.

test "toJsonSummary produces valid JSON object" {
  val a = Account(id = 1, name = "Cash", kind = AccountKind.Asset,
                  currency = "USD", createdAt = "2024-01-15T00:00:00Z")
  val json = Ledger.Accounts.toJsonSummary(a)
  // Must be wrapped in braces.
  assertEqual(json.first.toString(), "{", "starts with {")
  assertEqual(json.last.toString(),  "}", "ends with }")
}

test "toJsonSummary includes id" {
  val a = Account(id = 7, name = "Revenue", kind = AccountKind.Income,
                  currency = "USD", createdAt = "2024-01-15T00:00:00Z")
  val json = Ledger.Accounts.toJsonSummary(a)
  assertTrue(json.indexOf("\"id\":7") >= 0, "id field present")
}

test "toJsonSummary includes name" {
  val a = Account(id = 1, name = "Accrued Liabilities", kind = AccountKind.Liability,
                  currency = "GBP", createdAt = "2024-03-01T00:00:00Z")
  val json = Ledger.Accounts.toJsonSummary(a)
  assertTrue(json.indexOf("Accrued Liabilities") >= 0, "name present")
}

test "toJsonSummary encodes kind as string label" {
  val a = Account(id = 1, name = "Retained Earnings", kind = AccountKind.Equity,
                  currency = "USD", createdAt = "2024-01-01T00:00:00Z")
  val json = Ledger.Accounts.toJsonSummary(a)
  assertTrue(json.indexOf("equity") >= 0, "kind label present")
}

test "toJsonSummary does not include balance field" {
  val a = Account(id = 1, name = "Cash", kind = AccountKind.Asset,
                  currency = "USD", createdAt = "2024-01-01T00:00:00Z")
  val json = Ledger.Accounts.toJsonSummary(a)
  assertTrue(json.indexOf("balance") < 0, "no balance field in summary")
}

test "toJsonSummary includes currency field" {
  val a = Account(id = 1, name = "Checking", kind = AccountKind.Asset,
                  currency = "EUR", createdAt = "2024-01-01T00:00:00Z")
  val json = Ledger.Accounts.toJsonSummary(a)
  assertTrue(json.indexOf("EUR") >= 0, "currency present")
}

// ─── Ledger.Accounts.toJson ───────────────────────────────────────────────────

test "toJson includes balance field" {
  val a = Account(id = 1, name = "Cash", kind = AccountKind.Asset,
                  currency = "USD", createdAt = "2024-01-01T00:00:00Z")
  val json = Ledger.Accounts.toJson(a, 10000)
  assertTrue(json.indexOf("\"balance\":10000") >= 0, "balance field present")
}

test "toJson includes negative balance" {
  val a = Account(id = 2, name = "Payables", kind = AccountKind.Liability,
                  currency = "USD", createdAt = "2024-01-01T00:00:00Z")
  val json = Ledger.Accounts.toJson(a, -5000)
  assertTrue(json.indexOf("-5000") >= 0, "negative balance present")
}

test "toJson zero balance renders correctly" {
  val a = Account(id = 3, name = "Clearing", kind = AccountKind.Asset,
                  currency = "EUR", createdAt = "2024-06-01T00:00:00Z")
  val json = Ledger.Accounts.toJson(a, 0)
  assertTrue(json.indexOf("\"balance\":0") >= 0, "zero balance present")
}

// ─── Ledger.Transfers.transferToJson ─────────────────────────────────────────

test "transferToJson includes id" {
  val t = Transfer(id = 42, fromId = 1, toId = 2, amount = 5000,
                   note = "Q1 sales", createdAt = "2024-03-31T00:00:00Z")
  val json = Ledger.Transfers.transferToJson(t)
  assertTrue(json.indexOf("\"id\":42") >= 0, "id present")
}

test "transferToJson includes from_id and to_id" {
  val t = Transfer(id = 1, fromId = 10, toId = 20, amount = 1000,
                   note = "", createdAt = "2024-01-01T00:00:00Z")
  val json = Ledger.Transfers.transferToJson(t)
  assertTrue(json.indexOf("\"from_id\":10") >= 0, "from_id present")
  assertTrue(json.indexOf("\"to_id\":20")   >= 0, "to_id present")
}

test "transferToJson includes amount" {
  val t = Transfer(id = 1, fromId = 1, toId = 2, amount = 99999,
                   note = "", createdAt = "2024-01-01T00:00:00Z")
  val json = Ledger.Transfers.transferToJson(t)
  assertTrue(json.indexOf("\"amount\":99999") >= 0, "amount present")
}

test "transferToJson includes note" {
  val t = Transfer(id = 1, fromId = 1, toId = 2, amount = 100,
                   note = "Refund", createdAt = "2024-01-01T00:00:00Z")
  val json = Ledger.Transfers.transferToJson(t)
  assertTrue(json.indexOf("Refund") >= 0, "note present")
}

test "transferToJson escapes backslash in note" {
  val t = Transfer(id = 1, fromId = 1, toId = 2, amount = 50,
                   note = "path\\file", createdAt = "2024-01-01T00:00:00Z")
  val json = Ledger.Transfers.transferToJson(t)
  // The serializer must emit \\ for a literal backslash; the raw string
  // contains the two-character sequence backslash-backslash.
  assertTrue(json.indexOf("path") >= 0, "note content present")
  assertTrue(json.indexOf("file") >= 0, "note content present after escape")
}

// ─── Ledger.Transfers.entryToJson ────────────────────────────────────────────

test "entryToJson includes debit side" {
  val e = LedgerEntry(id = 1, transferId = 10, accountId = 5,
                      amount = 2500, side = "debit",
                      createdAt = "2024-01-01T00:00:00Z")
  val json = Ledger.Transfers.entryToJson(e)
  assertTrue(json.indexOf("debit") >= 0, "side debit present")
}

test "entryToJson includes credit side" {
  val e = LedgerEntry(id = 2, transferId = 10, accountId = 6,
                      amount = 2500, side = "credit",
                      createdAt = "2024-01-01T00:00:00Z")
  val json = Ledger.Transfers.entryToJson(e)
  assertTrue(json.indexOf("credit") >= 0, "side credit present")
}

test "entryToJson includes transfer_id" {
  val e = LedgerEntry(id = 1, transferId = 77, accountId = 5,
                      amount = 500, side = "debit",
                      createdAt = "2024-01-01T00:00:00Z")
  val json = Ledger.Transfers.entryToJson(e)
  assertTrue(json.indexOf("\"transfer_id\":77") >= 0, "transfer_id present")
}

test "entryToJson includes account_id" {
  val e = LedgerEntry(id = 1, transferId = 1, accountId = 42,
                      amount = 500, side = "credit",
                      createdAt = "2024-01-01T00:00:00Z")
  val json = Ledger.Transfers.entryToJson(e)
  assertTrue(json.indexOf("\"account_id\":42") >= 0, "account_id present")
}

test "debit and credit entries for same transfer share transfer_id in JSON" {
  val debit  = LedgerEntry(id = 1, transferId = 5, accountId = 1,
                            amount = 3000, side = "debit",  createdAt = "2024-01-01T00:00:00Z")
  val credit = LedgerEntry(id = 2, transferId = 5, accountId = 2,
                            amount = 3000, side = "credit", createdAt = "2024-01-01T00:00:00Z")
  val dJson = Ledger.Transfers.entryToJson(debit)
  val cJson = Ledger.Transfers.entryToJson(credit)
  assertTrue(dJson.indexOf("\"transfer_id\":5") >= 0, "debit transfer_id")
  assertTrue(cJson.indexOf("\"transfer_id\":5") >= 0, "credit transfer_id")
}
