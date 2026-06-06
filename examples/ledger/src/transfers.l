//! Ledger.Transfers — transfer recording and ledger entry retrieval.
//!
//! The public `recordTransfer` function enforces three safety layers:
//!
//!   1. Precondition check  — amount > 0 and fromId != toId (requires: clauses,
//!      checked at runtime by the @runtime_checked mode checker).
//!   2. Balance proof oracle — calls Ledger.Accounting.balancePreservation,
//!      whose @proof_required preconditions must be satisfied at the call site.
//!      The verifier discharges the proof obligation at compile time; if it
//!      cannot, the build fails.
//!   3. Atomic DB write     — debit + credit entries are written inside a single
//!      explicit transaction.  A network failure after the debit but before the
//!      commit causes an automatic rollback; partial writes are impossible.
@runtime_checked
package Ledger.Transfers

import Std.Core
import Std.Collections
import Std.Json
import Ledger.Accounting
import Db

// ─── Record a transfer ────────────────────────────────────────────────────────
/// Write a double-entry transfer to the database atomically.
///
/// Callers must verify sufficient funds and pass the source and destination
/// balances so the proof oracle can be satisfied.  This separation keeps
/// the proof obligations visible at the call site (in api.l) rather than
/// hidden inside the repository function.
pub func recordTransfer(
  conn: in DbConnection,
  fromId: in Long,
  toId: in Long,
  amount: in Long,
  note: in String,
  fromBalance: in Long,
  toBalance: in Long,
): Result[Transfer, LedgerError]
  requires: amount > 0
  requires: fromId != toId
  requires: fromBalance >= amount
{
  // Invoke the proof oracle: balancePreservation's @proof_required requires:
  // clauses must hold here. The compiler verifies this via the Hoare call
  // rule before allowing the build to proceed.
  val _ = Ledger.Accounting.balancePreservation(fromBalance, toBalance, amount)

  match conn.transaction() {
    case Err(e) -> Err(LedgerError.DatabaseError(message = e.message))
    case Ok(tx) -> writeAtomically(tx, fromId, toId, amount, note)
  }
}

// ─── Retrieve ─────────────────────────────────────────────────────────────────
pub func getById(conn: in DbConnection, id: in Long): Result[Option[Transfer], LedgerError] {
  val sql = "SELECT id, from_id, to_id, amount, note, created_at " + "FROM transfers WHERE id = $1"
  match conn.query(sql, [id.toString()]) {
    case Err(e) -> Err(LedgerError.DatabaseError(message = e.message))
    case Ok(rows) -> if rows.count == 0 { Ok(None) } else { val r = rows[0]; Ok(Some(value = rowToTransfer(r))) }
  }
}

pub func getEntriesForAccount(conn: in DbConnection, id: in Long): Result[List[LedgerEntry], LedgerError] {
  val sql = "SELECT id, transfer_id, account_id, amount, side, created_at " +
    "FROM ledger_entries WHERE account_id = $1 ORDER BY id"
  match conn.query(sql, [id.toString()]) {
    case Err(e) -> Err(LedgerError.DatabaseError(message = e.message))
    case Ok(rows) -> {
      val entries: List[LedgerEntry] = newList()
      for r in rows {
        entries.add(rowToEntry(r))
      }
      Ok(entries)
    }
  }
}

// ─── JSON serialization ───────────────────────────────────────────────────────
pub func transferToJson(t: in Transfer): String {
  "{" + "\"id\":" + t.id.toString() + "," + "\"from_id\":" + t.fromId.toString() + "," + "\"to_id\":" +
    t.toId.toString() +
    "," +
    "\"amount\":" +
    t.amount.toString() +
    "," +
    "\"note\":" +
    Std.Json.encodeString(t.note) +
    "," +
    "\"created_at\":" +
    Std.Json.encodeString(t.createdAt) +
    "}"
}

pub func entryToJson(e: in LedgerEntry): String {
  "{" + "\"id\":" + e.id.toString() + "," + "\"transfer_id\":" + e.transferId.toString() + "," + "\"account_id\":" +
    e.accountId.toString() +
    "," +
    "\"amount\":" +
    e.amount.toString() +
    "," +
    "\"side\":" +
    Std.Json.encodeString(e.side) +
    "," +
    "\"created_at\":" +
    Std.Json.encodeString(e.createdAt) +
    "}"
}

// ─── Private helpers ──────────────────────────────────────────────────────────
func writeAtomically(
  tx: in DbTransaction, fromId: in Long, toId: in Long, amount: in Long, note: in String
): Result[Transfer, LedgerError] {
  // Insert the transfer header.
  val insertSql = "INSERT INTO transfers (from_id, to_id, amount, note) " + "VALUES ($1, $2, $3, $4) " +
    "RETURNING id, from_id, to_id, amount, note, created_at"
  match tx.query(insertSql, [fromId.toString(), toId.toString(), amount.toString(), note]) {
    case Err(e) -> {
      val _ = tx.rollback()
      Err(LedgerError.DatabaseError(message = e.message))
    }
    case Ok(rows) -> if rows.count == 0 {
      val _ = tx.rollback()
      Err(LedgerError.DatabaseError(message = "INSERT transfers returned no rows"))
    } else {
      val r = rows[0]
      val transfer = rowToTransfer(r)
      // Build entries via the @proof_required constructors so the verifier
      // sees the structural guarantee: debit.amount == credit.amount == amount.
      val debit = Ledger.Accounting.makeDebit(transfer.id, fromId, amount)
      val credit = Ledger.Accounting.makeCredit(transfer.id, toId, amount)
      match insertEntry(tx, debit) {
        case Err(e) -> {
          val _ = tx.rollback()
          Err(e)
        }
        case Ok(_) -> match insertEntry(tx, credit) { case Err(e) -> { val _ = tx.rollback(); Err(e) }; case Ok(_) -> match tx.commit() { case Err(e) -> Err(LedgerError.DatabaseError(message = e.message)); case Ok(_) -> Ok(transfer) } }
      }
    }
  }
}

func insertEntry(tx: in DbTransaction, ent: in LedgerEntry): Result[Unit, LedgerError] {
  val sql = "INSERT INTO ledger_entries (transfer_id, account_id, amount, side) " + "VALUES ($1, $2, $3, $4)"
  val params = [ent.transferId.toString(), ent.accountId.toString(), ent.amount.toString(), ent.side]
  match tx.execute(sql, params) {
    case Err(e) -> Err(LedgerError.DatabaseError(message = e.message))
    case Ok(_) -> Ok(())
  }
}

func rowToTransfer(row: in DbRow): Transfer {
  return Transfer(
    id = colLong(row, "id"),
    fromId = colLong(row, "from_id"),
    toId = colLong(row, "to_id"),
    amount = colLong(row, "amount"),
    note = colText(row, "note"),
    createdAt = colText(row, "created_at")
  )
}

func rowToEntry(row: in DbRow): LedgerEntry {
  return LedgerEntry(
    id = colLong(row, "id"),
    transferId = colLong(row, "transfer_id"),
    accountId = colLong(row, "account_id"),
    amount = colLong(row, "amount"),
    side = colText(row, "side"),
    createdAt = colText(row, "created_at")
  )
}

func colLong(row: in DbRow, name: in String): Long {
  match Db.col(row, name) {
    case DbValue.DbLong(v) -> v
    case DbValue.DbInt(v) -> v.toLong()
    case _ -> 0
  }
}

func colText(row: in DbRow, name: in String): String {
  match Db.col(row, name) {
    case DbValue.DbText(v) -> v
    case DbValue.DbDateTime(v) -> v
    case _ -> ""
  }
}
