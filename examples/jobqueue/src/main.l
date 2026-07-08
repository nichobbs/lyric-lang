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

/// GET /health/live
pub func healthLive(req: in Web.Request): Web.Response {
  match Health.runLiveness(healthRegistry()) {
    case Ok(body) -> Web.json(200, body)
    case Err(msg) -> Web.errorResponse(Web.serviceUnavailable(msg))
  }
}

/// GET /health/ready
pub func healthReady(req: in Web.Request): Web.Response {
  match Health.runReadiness(healthRegistry()) {
    case Ok(body) -> Web.json(200, body)
    case Err(msg) -> Web.errorResponse(Web.serviceUnavailable(msg))
  }
}

// Web.Handler is an interface, not a stored closure — see JobQueue.Api's
// handler-wrapper comment (issue #5363).
record HealthLiveHandler {
}

impl Web.Handler for HealthLiveHandler {
  func handle(req: in Web.Request): Web.Response {
    healthLive(req)
  }
}

record HealthReadyHandler {
}

impl Web.Handler for HealthReadyHandler {
  func handle(req: in Web.Request): Web.Response {
    healthReady(req)
  }
}

pub func main(): Unit {
  var router = JobQueue.Api.routes()

  // Register the background worker poller.  Fires every
  // Worker.pollIntervalMs milliseconds (default 2 s) — NOTE: registered
  // workers are not yet actually invoked by Web.serve (issue #5359);
  // run JobQueue.Worker's poll loop as a separate process/entry point
  // until that ships.
  val router = Web.addWorker(router, "job-poller", JobQueue.Worker.Worker.pollIntervalMs, "JobQueue.Worker.workerTick")

  val router = Web.addGet(router, "/health/live", HealthLiveHandler())
  val router = Web.addGet(router, "/health/ready", HealthReadyHandler())

  Web.start(router)
}
