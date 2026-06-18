//! Rbac — role-based access control service.
//!
//! Build:   lyric build --manifest examples/rbac/lyric.toml
//! Run:     lyric run   --manifest examples/rbac/lyric.toml
//! Verify:  lyric prove examples/rbac/src/policy.l --verbose
//!
//! Required environment:
//!   LYRIC_CONFIG_DB_CONNECTION_URL  — PostgreSQL URL
//!   LYRIC_ASPECT_AUTH_JWTSECRET     — JWT secret for mutation endpoints
//!
//! Optional:
//!   LYRIC_CONFIG_WEB_SERVER_PORT    — HTTP port (default: 8080)
//!
//! Quick-start (after applying schema.sql):
//!
//!   # Create a user
//!   curl -s -X POST http://localhost:8080/users \
//!        -H 'Content-Type: application/json' \
//!        -H 'Authorization: Bearer <token>' \
//!        -d '{"username":"alice"}' | jq .
//!
//!   # Grant the 'user' role (requires ManageUsers — grantor must be admin)
//!   curl -s -X POST http://localhost:8080/users/1/roles \
//!        -H 'Content-Type: application/json' \
//!        -H 'Authorization: Bearer <token>' \
//!        -d '{"role":"user","grantorId":0}' | jq .
//!
//!   # Check a permission
//!   curl -s -X POST http://localhost:8080/check \
//!        -H 'Content-Type: application/json' \
//!        -d '{"userId":1,"permission":"write"}' | jq .
package Rbac

import Std.Core
import Rbac.Api
import Db
import Web
import Health

func liveness(): CheckStatus {
  Health.pass()
}

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

pub func main(): Unit {
  val router = Rbac.Api.routes()
  val router = Web.addGet(router, "/health/live", "Rbac.healthLive")
  val router = Web.addGet(router, "/health/ready", "Rbac.healthReady")

  Web.start(router)
}
