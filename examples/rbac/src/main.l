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

pub func liveness(): Result[Unit, String] {
  Ok(())
}

pub func readiness(): Result[Unit, String] {
  match Db.connectPostgres() {
    case Err(e) -> Err("postgres unreachable: " + e.message)
    case Ok(conn) -> match conn.query("SELECT 1 AS ok", []) { case Err(e) -> { conn.close(); Err("postgres ping failed: " + e.message) }; case Ok(_) -> { conn.close(); Ok(()) } }
  }
}

pub func main(): Unit {
  val router = Rbac.Api.routes()

  val health = Health.create()
  val health = Health.addLivenessCheck(health, "process", "Rbac.liveness")
  val health = Health.addReadinessCheck(health, "postgres", "Rbac.readiness")
  val router = Health.registerRoutes(router, health)

  Web.start(router)
}
