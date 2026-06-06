//! JobQueue — background job queue service entry point.
//!
//! Build:   lyric build --manifest examples/jobqueue/lyric.toml
//! Run:     lyric run   --manifest examples/jobqueue/lyric.toml
//! Verify:  lyric prove examples/jobqueue/src/domain.l --verbose
//!
//! Required environment:
//!   LYRIC_CONFIG_DB_CONNECTION_URL     — PostgreSQL URL
//!   LYRIC_CONFIG_WORKER_WORKER_ID      — unique worker identity (default: "worker-1")
//!   LYRIC_ASPECT_AUTH_JWTSECRET        — JWT secret for POST /jobs
//!
//! Optional:
//!   LYRIC_CONFIG_WORKER_POLL_INTERVALMS  — poll cadence in ms (default: 2000)
//!   LYRIC_CONFIG_WEB_SERVER_PORT         — HTTP port (default: 8080)
//!
//! Quick-start (after applying schema.sql):
//!
//!   # Enqueue a no-op job
//!   curl -s -X POST http://localhost:8080/jobs \
//!        -H 'Content-Type: application/json' \
//!        -H 'Authorization: Bearer <token>' \
//!        -d '{"kind":"noop","payload":"{}","maxRetries":3}' | jq .
//!
//!   # Poll job status
//!   curl -s http://localhost:8080/jobs/1 | jq .
//!
//!   # List pending jobs
//!   curl -s 'http://localhost:8080/jobs?status=pending' | jq .
package JobQueue

import Std.Core
import JobQueue.Api
import JobQueue.Worker
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
  var router = JobQueue.Api.routes()

  // Register the background worker poller.
  // Fires every Worker.pollIntervalMs milliseconds (default 2 s).
  val router = Web.addWorker(router, "job-poller", JobQueue.Worker.Worker.pollIntervalMs, "JobQueue.Worker.workerTick")

  val health = Health.create()
  val health = Health.addLivenessCheck(health, "process", "JobQueue.liveness")
  val health = Health.addReadinessCheck(health, "postgres", "JobQueue.readiness")
  val router = Health.registerRoutes(router, health)

  Web.start(router)
}
