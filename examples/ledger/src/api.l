//! Ledger.Api — HTTP handler functions and route table.
//!
//! Each handler:
//!   1. Opens a span via OTel (so every request is traced end-to-end).
//!   2. Attaches business identifiers (account.id, transfer.id) as span attributes.
//!   3. Obtains a connection from the pool, delegates to the repository, and
//!      closes the connection before returning.
//!   4. Maps LedgerError variants to the correct HTTP status code.
//!
//! Route table:
//!   POST   /accounts              — create account
//!   GET    /accounts              — list all accounts (summary, no balance)
//!   GET    /accounts/{id}         — account detail with live balance
//!   GET    /accounts/{id}/entries — ledger entries for an account
//!   POST   /transfers             — record a transfer
//!   GET    /transfers/{id}        — transfer detail
@runtime_checked
package Ledger.Api

import Std.Core
import Std.Collections
import Std.Json
import Ledger.Accounting
import Ledger.Accounts
import Ledger.Transfers
import Db
import Web
import Web.Aspects
import OTel

// ─── Aspects ──────────────────────────────────────────────────────────────────
//
// RateLimit wraps all handlers (outermost layer).  RequiresAuth wraps only
// the mutation handlers and runs inside the rate limiter so that rejected
// requests still count against the quota.
//
// Config: env-var resolution (docs/26 §8) is not implemented yet, so none
// of the LYRIC_ASPECT_* variables below are actually read at runtime — the
// literal defaults in each `config { }` block are what runs.
//   LYRIC_ASPECT_THROTTLE_REQUESTSPERMINUTE  — not yet wired; see default below
//   LYRIC_ASPECT_THROTTLE_BURSTSIZE          — not yet wired; see default below
//   LYRIC_ASPECT_AUTH_JWTSECRET              — not yet wired; see default below
//   LYRIC_ASPECT_AUTH_ISSUER                 — not yet wired; see default below
//   LYRIC_ASPECT_AUTH_AUDIENCE               — not yet wired; see default below
aspect Throttle from Web.Aspects.RateLimit {
  matches: name like "handle*"
  config {
    requestsPerMinute: Int = 120
    burstSize: Int = 20
  }
}

aspect Auth from Web.Aspects.RequiresAuth {
  inside: Throttle
  matches: name in { handleCreateAccount, handleCreateTransfer }
  config {
    @sensitive
    jwtSecret: String = "REPLACE_ME_WITH_A_REAL_SECRET"
    // Obviously-invalid placeholder: an empty string here would let a JWT
    // signed with an empty key validate, silently accepting any token. Set
    // this directly in source before running the example for real — the
    // env var is not wired up.
    issuer: String = "ledger-service"
    audience: String = "ledger-api"
  }
}

// ─── Request body records ─────────────────────────────────────────────────────
//
// The Web kernel deserializes the JSON request body into these records via
// System.Text.Json before dispatching to the handler.
pub record CreateAccountRequest {
  name: String
  kind: String    // "asset" | "liability" | "equity" | "income" | "expense"
  currency: String    // ISO 4217 e.g. "USD"
}

pub record CreateTransferRequest {
  fromId: Long    // source account ID (minor-unit debited)
  toId: Long    // destination account ID (minor-unit credited)
  amount: Long    // amount in minor units (cents); must be > 0
  note: String  // free-text memo
}

// ─── Helpers ──────────────────────────────────────────────────────────────────
func withConn(f: in (DbConnection) -> Result[String, ApiError]): Result[String, ApiError] {
  match Db.connectFromEnv() {
    case Err(e) -> Err(Web.serviceUnavailable("database unavailable: " + e.message))
    case Ok(conn) -> {
      val res = f(conn)
      conn.close()
      res
    }
  }
}

func ledgerErrToApi(e: in LedgerError): ApiError {
  val msg = Ledger.Accounting.errorMessage(e)
  match e {
    case LedgerError.AccountNotFound(_) -> Web.notFound(msg)
    case LedgerError.TransferNotFound(_) -> Web.notFound(msg)
    case LedgerError.InsufficientFunds(_, _, _) -> Web.unprocessable(msg, [])
    case LedgerError.SameAccount -> Web.badRequest(msg)
    case LedgerError.InvalidAmount -> Web.badRequest(msg)
    case LedgerError.DatabaseError(_) -> Web.internalError(msg)
  }
}

func jsonArr(items: in List[String]): String {
  var buf: String = "["
  var first: Bool = true
  for item in items {
    if not first {
      buf = buf + ","
    }
    buf = buf + item
    first = false
  }
  return buf + "]"
}

// ─── Account handlers ─────────────────────────────────────────────────────────
// @body disambiguates request-body binding when the handler has multiple
// parameters.  authToken is injected from the Authorization: Bearer header
// by the Web dispatcher and validated by the Auth aspect before this body
// runs; it is intentionally unused inside the handler.
@post("/accounts")
pub func handleCreateAccount(@body req: in CreateAccountRequest, authToken: String): Result[String, ApiError] {
  val span = OTel.startSpan("ledger.account.create", 1)  // SpanKind.Server = 1
  match Ledger.Accounting.accountKindFromString(req.kind) {
    case None -> {
      OTel.endSpan(span)
      Err(Web.badRequest("unknown account kind: " + req.kind))
    }
    case Some(kind) -> match Db.connectFromEnv() { case Err(e) -> { OTel.setSpanError(span, e.message); OTel.endSpan(span); Err(Web.serviceUnavailable("database unavailable")) }; case Ok(conn) -> match Ledger.Accounts.createAccount(conn, req.name, kind, req.currency) { case Err(e) -> { conn.close(); OTel.setSpanError(span, Ledger.Accounting.errorMessage(e)); OTel.endSpan(span); Err(ledgerErrToApi(e)) }; case Ok(account) -> { conn.close(); OTel.setSpanAttribute(span, "account.id", account.id.toString()); OTel.setSpanAttribute(span, "account.kind", req.kind); OTel.setSpanAttribute(span, "account.currency", req.currency); OTel.endSpan(span); Ok(Ledger.Accounts.toJsonSummary(account)) } } }
  }
}

@get("/accounts")
pub func handleListAccounts(): Result[String, ApiError] {
  val span = OTel.startSpan("ledger.account.list", 1)
  match Db.connectFromEnv() {
    case Err(e) -> {
      OTel.setSpanError(span, e.message)
      OTel.endSpan(span)
      Err(Web.serviceUnavailable("database unavailable"))
    }
    case Ok(conn) -> match Ledger.Accounts.listAll(conn) { case Err(e) -> { conn.close(); OTel.setSpanError(span, Ledger.Accounting.errorMessage(e)); OTel.endSpan(span); Err(ledgerErrToApi(e)) }; case Ok(accounts) -> { conn.close(); OTel.endSpan(span); val jsons: List[String] = newList(); for a in accounts { jsons.add(Ledger.Accounts.toJsonSummary(a)) }; Ok(jsonArr(jsons)) } }
  }
}

@get("/accounts/{id}")
pub func handleGetAccount(id: Long): Result[String, ApiError] {
  val span = OTel.startSpan("ledger.account.get", 1)
  OTel.setSpanAttribute(span, "account.id", id.toString())
  match Db.connectFromEnv() {
    case Err(e) -> {
      OTel.setSpanError(span, e.message)
      OTel.endSpan(span)
      Err(Web.serviceUnavailable("database unavailable"))
    }
    case Ok(conn) -> match Ledger.Accounts.getById(conn, id) { case Err(e) -> { conn.close(); OTel.setSpanError(span, Ledger.Accounting.errorMessage(e)); OTel.endSpan(span); Err(ledgerErrToApi(e)) }; case Ok(None) -> { conn.close(); OTel.endSpan(span); Err(Web.notFound("account " + id.toString() + " not found")) }; case Ok(Some(account)) -> match Ledger.Accounts.getBalance(conn, id) { case Err(e) -> { conn.close(); OTel.setSpanError(span, Ledger.Accounting.errorMessage(e)); OTel.endSpan(span); Err(ledgerErrToApi(e)) }; case Ok(balance) -> { conn.close(); OTel.setSpanAttribute(span, "account.balance", balance.toString()); OTel.endSpan(span); Ok(Ledger.Accounts.toJson(account, balance)) } } }
  }
}

@get("/accounts/{id}/entries")
pub func handleGetAccountEntries(id: Long): Result[String, ApiError] {
  val span = OTel.startSpan("ledger.entries.list", 1)
  OTel.setSpanAttribute(span, "account.id", id.toString())
  match Db.connectFromEnv() {
    case Err(e) -> {
      OTel.setSpanError(span, e.message)
      OTel.endSpan(span)
      Err(Web.serviceUnavailable("database unavailable"))
    }
    case Ok(conn) -> match Ledger.Transfers.getEntriesForAccount(conn, id) { case Err(e) -> { conn.close(); OTel.setSpanError(span, Ledger.Accounting.errorMessage(e)); OTel.endSpan(span); Err(ledgerErrToApi(e)) }; case Ok(entries) -> { conn.close(); OTel.setSpanAttribute(span, "entry.count", entries.count.toString()); OTel.endSpan(span); val jsons: List[String] = newList(); for e in entries { jsons.add(Ledger.Transfers.entryToJson(e)) }; Ok(jsonArr(jsons)) } }
  }
}

// ─── Transfer handlers ────────────────────────────────────────────────────────
// See handleCreateAccount for @body / authToken rationale.
@post("/transfers")
pub func handleCreateTransfer(@body req: in CreateTransferRequest, authToken: String): Result[String, ApiError] {
  val span = OTel.startSpan("ledger.transfer.create", 1)

  // Fast-path validation before touching the database.
  if req.amount <= 0 {
    OTel.endSpan(span)
    return Err(Web.badRequest("amount must be greater than zero"))
  }
  if req.fromId == req.toId {
    OTel.endSpan(span)
    return Err(Web.badRequest("source and destination accounts must differ"))
  }

  OTel.setSpanAttribute(span, "transfer.from_id", req.fromId.toString())
  OTel.setSpanAttribute(span, "transfer.to_id", req.toId.toString())
  OTel.setSpanAttribute(span, "transfer.amount", req.amount.toString())

  // Fetch both balances before recording — these values are passed to
  // Ledger.Transfers.recordTransfer which in turn passes them to the
  // @proof_required balancePreservation oracle.
  match Db.connectFromEnv() {
    case Err(e) -> {
      OTel.setSpanError(span, e.message)
      OTel.endSpan(span)
      Err(Web.serviceUnavailable("database unavailable"))
    }
    case Ok(conn) -> match Ledger.Accounts.getBalance(conn, req.fromId) { case Err(e) -> { conn.close(); OTel.setSpanError(span, Ledger.Accounting.errorMessage(e)); OTel.endSpan(span); Err(ledgerErrToApi(e)) }; case Ok(fromBalance) -> { if fromBalance < req.amount { conn.close(); OTel.setSpanError(span, "insufficient funds"); OTel.endSpan(span); return Err(Web.unprocessable("insufficient funds: balance " + fromBalance.toString() + ", needed " + req.amount.toString(), [])) }; match Ledger.Accounts.getBalance(conn, req.toId) { case Err(e) -> { conn.close(); OTel.setSpanError(span, Ledger.Accounting.errorMessage(e)); OTel.endSpan(span); Err(ledgerErrToApi(e)) }; case Ok(toBalance) -> match Ledger.Transfers.recordTransfer(conn, req.fromId, req.toId, req.amount, req.note, fromBalance, toBalance) { case Err(e) -> { conn.close(); OTel.setSpanError(span, Ledger.Accounting.errorMessage(e)); OTel.endSpan(span); Err(ledgerErrToApi(e)) }; case Ok(transfer) -> { conn.close(); OTel.setSpanAttribute(span, "transfer.id", transfer.id.toString()); OTel.endSpan(span); Ok(Ledger.Transfers.transferToJson(transfer)) } } } } }
  }
}

@get("/transfers/{id}")
pub func handleGetTransfer(id: Long): Result[String, ApiError] {
  val span = OTel.startSpan("ledger.transfer.get", 1)
  OTel.setSpanAttribute(span, "transfer.id", id.toString())
  match Db.connectFromEnv() {
    case Err(e) -> {
      OTel.setSpanError(span, e.message)
      OTel.endSpan(span)
      Err(Web.serviceUnavailable("database unavailable"))
    }
    case Ok(conn) -> match Ledger.Transfers.getById(conn, id) { case Err(e) -> { conn.close(); OTel.setSpanError(span, Ledger.Accounting.errorMessage(e)); OTel.endSpan(span); Err(ledgerErrToApi(e)) }; case Ok(None) -> { conn.close(); OTel.endSpan(span); Err(Web.notFound("transfer " + id.toString() + " not found")) }; case Ok(Some(transfer)) -> { conn.close(); OTel.endSpan(span); Ok(Ledger.Transfers.transferToJson(transfer)) } }
  }
}

// ─── Route table ──────────────────────────────────────────────────────────────
pub func routes(): Web.Router {
  val r = Web.create()
  val r = Web.addPost(r, "/accounts", "Ledger.Api.handleCreateAccount")
  val r = Web.addGet(r, "/accounts", "Ledger.Api.handleListAccounts")
  val r = Web.addGet(r, "/accounts/{id}", "Ledger.Api.handleGetAccount")
  val r = Web.addGet(r, "/accounts/{id}/entries", "Ledger.Api.handleGetAccountEntries")
  val r = Web.addPost(r, "/transfers", "Ledger.Api.handleCreateTransfer")
  val r = Web.addGet(r, "/transfers/{id}", "Ledger.Api.handleGetTransfer")
  return r
}
