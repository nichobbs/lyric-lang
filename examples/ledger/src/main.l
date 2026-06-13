//! Ledger — enterprise double-entry bookkeeping service.
//!
//! Wires together the HTTP router, health probes, and the Kestrel server.
//!
//! Build:   lyric build --manifest examples/ledger/lyric.toml
//! Run:     lyric run   --manifest examples/ledger/lyric.toml
//! Verify:  lyric prove examples/ledger/src/accounting.l --verbose
//!
//! Required environment:
//!   LYRIC_CONFIG_DB_CONNECTION_URL   — PostgreSQL URL
//!                                      e.g. "Host=localhost;Database=ledger;Username=app;Password=..."
//!   LYRIC_CONFIG_WEB_SERVER_PORT     — HTTP port (default 8080)
//!
//! Optional:
//!   LYRIC_CONFIG_WEB_SERVER_SWAGGERENABLED=true  — serve Swagger UI at /swagger
//!
//! Quick-start (after applying schema.sql):
//!
//!   # Create two accounts
//!   curl -s -X POST http://localhost:8080/accounts \
//!        -H 'Content-Type: application/json' \
//!        -d '{"name":"Cash","kind":"asset","currency":"USD"}' | jq .
//!
//!   curl -s -X POST http://localhost:8080/accounts \
//!        -H 'Content-Type: application/json' \
//!        -d '{"name":"Revenue","kind":"income","currency":"USD"}' | jq .
//!
//!   # Seed the Cash account with 100 USD (10000 cents) via a funding transfer.
//!   # In a real ledger you would have an Equity/Capital account as the source;
//!   # here we use a second transfer from Revenue for brevity.
//!
//!   # Transfer 50 USD from Cash (id=1) to Revenue (id=2)
//!   curl -s -X POST http://localhost:8080/transfers \
//!        -H 'Content-Type: application/json' \
//!        -d '{"fromId":1,"toId":2,"amount":5000,"note":"Q1 sales"}' | jq .
//!
//!   # Check balances
//!   curl -s http://localhost:8080/accounts/1 | jq .
//!   curl -s http://localhost:8080/accounts/2 | jq .
//!
//!   # Audit trail
//!   curl -s http://localhost:8080/accounts/1/entries | jq .
package Ledger

import Std.Core
import Ledger.Api
import Db
import Web
import Health

// ─── Health check functions ───────────────────────────────────────────────────
/// Liveness: the process is running and can handle requests.
func liveness(): CheckStatus {
  Health.pass()
}

/// Readiness: the PostgreSQL connection pool is reachable and responding.
func readiness(): CheckStatus {
  match Db.connectFromEnv() {
    case Err(e) -> Health.fail("database unreachable: " + e.message)
    case Ok(conn) -> match conn.query("SELECT 1 AS ok", []) { case Err(e) -> { conn.close(); Health.fail("database ping failed: " + e.message) }; case Ok(_) -> { conn.close(); Health.pass() } }
  }
}

// Checks are registered as function references (closures); Health invokes
// them directly — no name-based dispatch.
func healthRegistry(): HealthRegistry {
  val health = Health.create()
  val health = Health.addLivenessCheck(health, "process", { -> liveness() })
  Health.addReadinessCheck(health, "postgres", { -> readiness() })
}

/// GET /health/live — registered by name on the router below.
pub func healthLive(): Result[String, ApiError] {
  Health.runLiveness(healthRegistry())
}

/// GET /health/ready — registered by name on the router below.
pub func healthReady(): Result[String, ApiError] {
  Health.runReadiness(healthRegistry())
}

// ─── Entry point ──────────────────────────────────────────────────────────────
pub func main(): Unit {
  val router = Ledger.Api.routes()
  val router = Web.addGet(router, "/health/live", "Ledger.healthLive")
  val router = Web.addGet(router, "/health/ready", "Ledger.healthReady")

  Web.start(router)
}
