/// Ledger.Accounts — account creation, lookup, and balance computation.
///
/// All functions accept an explicit DbConnection so callers control
/// connection lifetime and can participate in an outer transaction.
/// Balance is computed live from ledger_entries (no stored balance column),
/// which guarantees consistency with the double-entry invariant.

@runtime_checked
package Ledger.Accounts

import Std.Core
import Std.Json
import Ledger.Accounting
import Db

// ─── Create ───────────────────────────────────────────────────────────────────

/// Insert a new account and return it.
pub func createAccount(
  conn:     in DbConnection,
  name:     in String,
  kind:     in AccountKind,
  currency: in String
): Result[Account, LedgerError]
  requires: name.length > 0
  requires: currency.length > 0
{
  val sql = "INSERT INTO accounts (name, kind, currency) VALUES ($1, $2, $3) " +
            "RETURNING id, name, kind, currency, created_at"
  val params = [name, accountKindLabel(kind), currency]
  match conn.query(sql, params) {
    case Err(e) -> Err(LedgerError.DatabaseError(message = e.message))
    case Ok(rows) ->
      match rows {
        case []      -> Err(LedgerError.DatabaseError(message = "INSERT returned no rows"))
        case [r | _] -> Ok(rowToAccount(r))
      }
  }
}

// ─── Lookup ───────────────────────────────────────────────────────────────────

/// Fetch a single account by primary key.
pub func getById(
  conn: in DbConnection,
  id:   in Long
): Result[Option[Account], LedgerError] {
  val sql = "SELECT id, name, kind, currency, created_at FROM accounts WHERE id = $1"
  match conn.query(sql, [id.toString()]) {
    case Err(e)   -> Err(LedgerError.DatabaseError(message = e.message))
    case Ok(rows) ->
      match rows {
        case []      -> Ok(None)
        case [r | _] -> Ok(Some(value = rowToAccount(r)))
      }
  }
}

/// Fetch all accounts ordered by id.
pub func listAll(conn: in DbConnection): Result[[Account], LedgerError] {
  val sql = "SELECT id, name, kind, currency, created_at FROM accounts ORDER BY id"
  match conn.query(sql, []) {
    case Err(e)   -> Err(LedgerError.DatabaseError(message = e.message))
    case Ok(rows) ->
      var accounts: [Account] = []
      for r in rows {
        accounts = accounts + [rowToAccount(r)]
      }
      Ok(accounts)
  }
}

// ─── Balance ──────────────────────────────────────────────────────────────────

/// Compute the live balance for an account: sum(credit amounts) − sum(debit amounts).
/// Returns 0 for accounts with no entries.  The sign convention follows the
/// standard ledger view: positive = net credit (inflow), negative = net debit (outflow).
pub func getBalance(
  conn: in DbConnection,
  id:   in Long
): Result[Long, LedgerError] {
  val sql =
    "SELECT COALESCE(SUM(CASE WHEN side = 'credit' THEN amount ELSE -amount END), 0) AS balance " +
    "FROM ledger_entries WHERE account_id = $1"
  match conn.query(sql, [id.toString()]) {
    case Err(e)   -> Err(LedgerError.DatabaseError(message = e.message))
    case Ok(rows) ->
      match rows {
        case []      -> Ok(0)
        case [r | _] ->
          match Db.col(r, "balance") {
            case DbValue.DbLong(v)  -> Ok(v)
            case DbValue.DbInt(v)   -> Ok(v.toLong())
            case _                  -> Ok(0)
          }
      }
  }
}

// ─── JSON serialization ───────────────────────────────────────────────────────

/// Serialize an account with its live balance to a JSON object.
pub func toJson(a: in Account, balance: in Long): String {
  "{" +
  "\"id\":"         + a.id.toString()                          + "," +
  "\"name\":"       + Std.Json.encodeString(a.name)            + "," +
  "\"kind\":"       + Std.Json.encodeString(accountKindLabel(a.kind)) + "," +
  "\"currency\":"   + Std.Json.encodeString(a.currency)        + "," +
  "\"balance\":"    + balance.toString()                        + "," +
  "\"created_at\":" + Std.Json.encodeString(a.createdAt)       +
  "}"
}

/// Serialize an account without a balance field (for list endpoints).
pub func toJsonSummary(a: in Account): String {
  "{" +
  "\"id\":"         + a.id.toString()                          + "," +
  "\"name\":"       + Std.Json.encodeString(a.name)            + "," +
  "\"kind\":"       + Std.Json.encodeString(accountKindLabel(a.kind)) + "," +
  "\"currency\":"   + Std.Json.encodeString(a.currency)        + "," +
  "\"created_at\":" + Std.Json.encodeString(a.createdAt)       +
  "}"
}

// ─── Private helpers ──────────────────────────────────────────────────────────

func rowToAccount(row: in DbRow): Account {
  val kind = accountKindFromString(colText(row, "kind")).unwrapOr(AccountKind.Asset)
  return Account(
    id        = colLong(row, "id"),
    name      = colText(row, "name"),
    kind      = kind,
    currency  = colText(row, "currency"),
    createdAt = colText(row, "created_at"))
}

func colLong(row: in DbRow, name: in String): Long {
  match Db.col(row, name) {
    case DbValue.DbLong(v) -> v
    case DbValue.DbInt(v)  -> v.toLong()
    case _                 -> 0
  }
}

func colText(row: in DbRow, name: in String): String {
  match Db.col(row, name) {
    case DbValue.DbText(v)     -> v
    case DbValue.DbDateTime(v) -> v
    case _                     -> ""
  }
}
