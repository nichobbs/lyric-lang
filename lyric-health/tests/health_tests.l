//! Test suite for the Health package.
//!
//! Covers: registry construction, function-reference registration via
//! addLivenessCheck / addReadinessCheck, runChecks execution (passing,
//! failing, and mixed registries), liveness/readiness group filtering,
//! the JSON response shape (including escaping), and the
//! runLiveness / runReadiness handler-result mapping.
@test_module
package Health.HealthTests

import Std.Core
import Std.Testing
import Health
import Web

func passingCheck(): CheckStatus {
  return Health.pass()
}

func failingCheck(): CheckStatus {
  return Health.fail("connection refused")
}

// ─── create ───────────────────────────────────────────────────────────────────

test "create returns an empty registry with no checks" {
  val registry = Health.create()
  assertEqualInt(registry.checks.length, 0, "empty registry has 0 checks")
}

// ─── Registration ─────────────────────────────────────────────────────────────

test "addLivenessCheck adds exactly one check to an empty registry" {
  val registry = Health.addLivenessCheck(Health.create(), "self", { -> passingCheck() })
  assertEqualInt(registry.checks.length, 1, "registry has 1 check after addLivenessCheck")
}

test "addLivenessCheck: check has the correct name and group" {
  val registry = Health.addLivenessCheck(Health.create(), "heartbeat", { -> passingCheck() })
  val check    = registry.checks[0]
  assertEqual(check.name, "heartbeat", "liveness check name")
  assertTrue(Health.isLiveness(check.group), "check group is Liveness")
  assertFalse(Health.isReadiness(check.group), "check group is not Readiness")
}

test "addReadinessCheck adds exactly one check to an empty registry" {
  val registry = Health.addReadinessCheck(Health.create(), "db", { -> passingCheck() })
  assertEqualInt(registry.checks.length, 1, "registry has 1 check after addReadinessCheck")
}

test "addReadinessCheck: check has the correct name and group" {
  val registry = Health.addReadinessCheck(Health.create(), "cache", { -> passingCheck() })
  val check    = registry.checks[0]
  assertEqual(check.name, "cache", "readiness check name")
  assertTrue(Health.isReadiness(check.group), "check group is Readiness")
  assertFalse(Health.isLiveness(check.group), "check group is not Liveness")
}

test "three chained checks are stored in insertion order" {
  val r0 = Health.create()
  val r1 = Health.addLivenessCheck(r0,  "live1",  { -> passingCheck() })
  val r2 = Health.addReadinessCheck(r1, "ready1", { -> passingCheck() })
  val r3 = Health.addReadinessCheck(r2, "ready2", { -> passingCheck() })
  assertEqualInt(r3.checks.length, 3, "three checks total")
  assertEqual(r3.checks[0].name, "live1",  "first check name")
  assertEqual(r3.checks[1].name, "ready1", "second check name")
  assertEqual(r3.checks[2].name, "ready2", "third check name")
}

// ─── CheckStatus factories ────────────────────────────────────────────────────

test "pass() is healthy with empty detail" {
  val status = Health.pass()
  assertTrue(status.healthy, "pass() is healthy")
  assertEqual(status.detail, "", "pass() has empty detail")
}

test "fail(detail) is unhealthy and carries the detail" {
  val status = Health.fail("db down")
  assertFalse(status.healthy, "fail() is unhealthy")
  assertEqual(status.detail, "db down", "fail() detail")
}

// ─── runChecks: execution ─────────────────────────────────────────────────────

test "runChecks invokes a passing check and reports healthy" {
  val registry = Health.addLivenessCheck(Health.create(), "self", { -> passingCheck() })
  val report = Health.runChecks(registry, Liveness)
  assertTrue(report.healthy, "single passing check reports healthy")
  assertEqual(
    report.body,
    "{\"status\":\"ok\",\"checks\":{\"self\":{\"status\":\"ok\",\"detail\":\"\"}}}",
    "passing response body")
}

test "runChecks invokes a failing check and reports degraded with detail" {
  val registry = Health.addReadinessCheck(Health.create(), "db", { -> failingCheck() })
  val report = Health.runChecks(registry, Readiness)
  assertFalse(report.healthy, "single failing check reports degraded")
  assertEqual(
    report.body,
    "{\"status\":\"degraded\",\"checks\":{\"db\":{\"status\":\"fail\",\"detail\":\"connection refused\"}}}",
    "failing response body")
}

test "runChecks aggregates a passing and a failing check as degraded" {
  var registry = Health.create()
  registry = Health.addReadinessCheck(registry, "cache", { -> passingCheck() })
  registry = Health.addReadinessCheck(registry, "db",    { -> failingCheck() })
  val report = Health.runChecks(registry, Readiness)
  assertFalse(report.healthy, "mixed outcomes report degraded")
  assertEqual(
    report.body,
    "{\"status\":\"degraded\",\"checks\":{" +
      "\"cache\":{\"status\":\"ok\",\"detail\":\"\"}," +
      "\"db\":{\"status\":\"fail\",\"detail\":\"connection refused\"}}}",
    "mixed response body in registration order")
}

test "runChecks on an empty group reports healthy with no checks" {
  val report = Health.runChecks(Health.create(), Liveness)
  assertTrue(report.healthy, "empty group is healthy")
  assertEqual(report.body, "{\"status\":\"ok\",\"checks\":{}}", "empty response body")
}

// ─── runChecks: group filtering ───────────────────────────────────────────────

test "runChecks runs only the requested group" {
  var registry = Health.create()
  registry = Health.addLivenessCheck(registry,  "live-ok",  { -> passingCheck() })
  registry = Health.addReadinessCheck(registry, "db-down",  { -> failingCheck() })
  val liveReport = Health.runChecks(registry, Liveness)
  assertTrue(liveReport.healthy, "liveness ignores the failing readiness check")
  assertEqual(
    liveReport.body,
    "{\"status\":\"ok\",\"checks\":{\"live-ok\":{\"status\":\"ok\",\"detail\":\"\"}}}",
    "liveness body contains only liveness checks")
  val readyReport = Health.runChecks(registry, Readiness)
  assertFalse(readyReport.healthy, "readiness sees the failing readiness check")
  assertEqual(
    readyReport.body,
    "{\"status\":\"degraded\",\"checks\":{\"db-down\":{\"status\":\"fail\",\"detail\":\"connection refused\"}}}",
    "readiness body contains only readiness checks")
}

// ─── Response shape: escaping ─────────────────────────────────────────────────

test "runChecks escapes quotes and backslashes in names and details" {
  val registry = Health.addReadinessCheck(
    Health.create(), "q\"c", { -> Health.fail("path \\tmp \"quoted\"") })
  val report = Health.runChecks(registry, Readiness)
  assertEqual(
    report.body,
    "{\"status\":\"degraded\",\"checks\":{" +
      "\"q\\\"c\":{\"status\":\"fail\",\"detail\":\"path \\\\tmp \\\"quoted\\\"\"}}}",
    "escaped response body")
}

test "runChecks escapes control characters in names and details (RFC 8259)" {
  // Name carries U+0001 (no shorthand -> ) and U+0008 backspace (-> \b);
  // detail carries U+000C form-feed (-> \f).
  val registry = Health.addReadinessCheck(
    Health.create(), "a\u{0001}b\u{0008}c", { -> Health.fail("x\u{000C}y") })
  val report = Health.runChecks(registry, Readiness)
  assertEqual(
    report.body,
    "{\"status\":\"degraded\",\"checks\":{" +
      "\"a\\u0001b\\bc\":{\"status\":\"fail\",\"detail\":\"x\\fy\"}}}",
    "control characters are escaped per RFC 8259")
}

// ─── runLiveness / runReadiness handler mapping ───────────────────────────────

test "runLiveness returns Ok with the JSON body when healthy" {
  val registry = Health.addLivenessCheck(Health.create(), "self", { -> passingCheck() })
  match Health.runLiveness(registry) {
    case Ok(body) -> assertEqual(
      body,
      "{\"status\":\"ok\",\"checks\":{\"self\":{\"status\":\"ok\",\"detail\":\"\"}}}",
      "Ok body")
    case Err(_) -> assertTrue(false, "expected Ok from a healthy registry")
  }
}

test "runReadiness returns a 503 ApiError naming failing checks when degraded" {
  var registry = Health.create()
  registry = Health.addReadinessCheck(registry, "db",    { -> failingCheck() })
  registry = Health.addReadinessCheck(registry, "cache", { -> Health.fail("cold") })
  match Health.runReadiness(registry) {
    case Ok(_) -> assertTrue(false, "expected Err from a degraded registry")
    case Err(e) -> {
      assertEqualInt(e.status, 503, "degraded maps to 503")
      assertEqual(e.message, "health checks degraded: db, cache", "failing check names")
    }
  }
}

test "runLiveness ignores readiness failures" {
  var registry = Health.create()
  registry = Health.addLivenessCheck(registry,  "self", { -> passingCheck() })
  registry = Health.addReadinessCheck(registry, "db",   { -> failingCheck() })
  match Health.runLiveness(registry) {
    case Ok(_) -> ()
    case Err(_) -> assertTrue(false, "liveness must not see readiness failures")
  }
}
