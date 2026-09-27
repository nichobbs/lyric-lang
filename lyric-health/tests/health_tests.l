//! Test suite for the Health package.
//!
//! Covers: registry construction, function-reference registration via
//! addLivenessCheck / addReadinessCheck, runChecks execution (passing,
//! failing, and mixed registries), liveness/readiness group filtering,
//! the JSON response shape (including escaping), the
//! runLiveness / runReadiness handler-result mapping, duplicate/empty
//! name and timeoutMs registration preconditions, panic isolation, and
//! (on `--target dotnet`) the bounded-wait timeout enforcement.
@test_module
package Health.HealthTests

import Std.Core
import Std.Testing
import Std.Time
import Health

func passingCheck(): CheckStatus {
  return Health.pass()
}

func failingCheck(): CheckStatus {
  return Health.fail("connection refused")
}

func panickingCheck(): CheckStatus {
  panic("boom: internal check state corrupted")
}

func slowCheck(): CheckStatus {
  sleepMillis(500)
  return Health.pass()
}

// ─── Named helpers for assertPanics (no block-bodied lambdas, #7151) ──────────
func addLivenessCheckWithEmptyName(): Unit {
  val _ = Health.addLivenessCheck(Health.create(), "", { -> passingCheck() })
}

func addReadinessCheckWithEmptyName(): Unit {
  val _ = Health.addReadinessCheck(Health.create(), "", { -> passingCheck() })
}

func addLivenessCheckWithDuplicateName(): Unit {
  val registry = Health.addLivenessCheck(Health.create(), "dup", { -> passingCheck() })
  val _ = Health.addLivenessCheck(registry, "dup", { -> passingCheck() })
}

func addReadinessCheckWithNameAlreadyUsedByLiveness(): Unit {
  val registry = Health.addLivenessCheck(Health.create(), "shared", { -> passingCheck() })
  val _ = Health.addReadinessCheck(registry, "shared", { -> passingCheck() })
}

func addLivenessCheckWithTimeoutZero(): Unit {
  val _ = Health.addLivenessCheckWithTimeout(Health.create(), "self", { -> passingCheck() }, 0)
}

func addReadinessCheckWithTimeoutNegative(): Unit {
  val _ = Health.addReadinessCheckWithTimeout(Health.create(), "db", { -> passingCheck() }, -1)
}

// ─── HealthCheck / HealthRegistry invariants (direct construction) ────────────
func constructHealthCheckWithEmptyName(): Unit {
  val _ = HealthCheck(name = "", group = Liveness, handler = { -> passingCheck() }, timeoutMs = 1000)
}

func constructHealthCheckWithTimeoutZero(): Unit {
  val _ = HealthCheck(name = "self", group = Liveness, handler = { -> passingCheck() }, timeoutMs = 0)
}

func constructHealthCheckWithTimeoutNegativeOne(): Unit {
  val _ = HealthCheck(name = "self", group = Liveness, handler = { -> passingCheck() }, timeoutMs = -1)
}

func constructHealthRegistryWithDuplicateNames(): Unit {
  val a = HealthCheck(name = "dup", group = Liveness, handler = { -> passingCheck() }, timeoutMs = 1000)
  val b = HealthCheck(name = "dup", group = Readiness, handler = { -> passingCheck() }, timeoutMs = 1000)
  val checks: slice[HealthCheck] = [a, b]
  val _ = HealthRegistry(checks = checks)
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
  val check = registry.checks[0]
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
  val check = registry.checks[0]
  assertEqual(check.name, "cache", "readiness check name")
  assertTrue(Health.isReadiness(check.group), "check group is Readiness")
  assertFalse(Health.isLiveness(check.group), "check group is not Liveness")
}

test "three chained checks are stored in insertion order" {
  val r0 = Health.create()
  val r1 = Health.addLivenessCheck(r0, "live1", { -> passingCheck() })
  val r2 = Health.addReadinessCheck(r1, "ready1", { -> passingCheck() })
  val r3 = Health.addReadinessCheck(r2, "ready2", { -> passingCheck() })
  assertEqualInt(r3.checks.length, 3, "three checks total")
  assertEqual(r3.checks[0].name, "live1", "first check name")
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
    "passing response body"
  )
}

test "runChecks invokes a failing check and reports degraded with detail" {
  val registry = Health.addReadinessCheck(Health.create(), "db", { -> failingCheck() })
  val report = Health.runChecks(registry, Readiness)
  assertFalse(report.healthy, "single failing check reports degraded")
  assertEqual(
    report.body,
    "{\"status\":\"degraded\",\"checks\":{\"db\":{\"status\":\"fail\",\"detail\":\"connection refused\"}}}",
    "failing response body"
  )
}

test "runChecks aggregates a passing and a failing check as degraded" {
  var registry = Health.create()
  registry = Health.addReadinessCheck(registry, "cache", { -> passingCheck() })
  registry = Health.addReadinessCheck(registry, "db", { -> failingCheck() })
  val report = Health.runChecks(registry, Readiness)
  assertFalse(report.healthy, "mixed outcomes report degraded")
  assertEqual(
    report.body,
    "{\"status\":\"degraded\",\"checks\":{" + "\"cache\":{\"status\":\"ok\",\"detail\":\"\"}," +
      "\"db\":{\"status\":\"fail\",\"detail\":\"connection refused\"}}}",
    "mixed response body in registration order"
  )
}

test "runChecks on an empty group reports healthy with no checks" {
  val report = Health.runChecks(Health.create(), Liveness)
  assertTrue(report.healthy, "empty group is healthy")
  assertEqual(report.body, "{\"status\":\"ok\",\"checks\":{}}", "empty response body")
}

// ─── runChecks: group filtering ───────────────────────────────────────────────
test "runChecks runs only the requested group" {
  var registry = Health.create()
  registry = Health.addLivenessCheck(registry, "live-ok", { -> passingCheck() })
  registry = Health.addReadinessCheck(registry, "db-down", { -> failingCheck() })
  val liveReport = Health.runChecks(registry, Liveness)
  assertTrue(liveReport.healthy, "liveness ignores the failing readiness check")
  assertEqual(
    liveReport.body,
    "{\"status\":\"ok\",\"checks\":{\"live-ok\":{\"status\":\"ok\",\"detail\":\"\"}}}",
    "liveness body contains only liveness checks"
  )
  val readyReport = Health.runChecks(registry, Readiness)
  assertFalse(readyReport.healthy, "readiness sees the failing readiness check")
  assertEqual(
    readyReport.body,
    "{\"status\":\"degraded\",\"checks\":{\"db-down\":{\"status\":\"fail\",\"detail\":\"connection refused\"}}}",
    "readiness body contains only readiness checks"
  )
}

// ─── Response shape: escaping ─────────────────────────────────────────────────
test "runChecks escapes quotes and backslashes in names and details" {
  val registry = Health.addReadinessCheck(Health.create(), "q\"c", { -> Health.fail("path \\tmp \"quoted\"") })
  val report = Health.runChecks(registry, Readiness)
  assertEqual(
    report.body,
    "{\"status\":\"degraded\",\"checks\":{" +
      "\"q\\\"c\":{\"status\":\"fail\",\"detail\":\"path \\\\tmp \\\"quoted\\\"\"}}}",
    "escaped response body"
  )
}

test "runChecks escapes control characters in names and details (RFC 8259)" {
  // Name carries U+0001 (no shorthand -> ) and U+0008 backspace (-> \b);
  // detail carries U+000C form-feed (-> \f).
  val registry = Health.addReadinessCheck(Health.create(), "a\u{0001}b\u{0008}c", { -> Health.fail("x\u{000c}y") })
  val report = Health.runChecks(registry, Readiness)
  assertEqual(
    report.body,
    "{\"status\":\"degraded\",\"checks\":{" + "\"a\\u0001b\\bc\":{\"status\":\"fail\",\"detail\":\"x\\fy\"}}}",
    "control characters are escaped per RFC 8259"
  )

  // U+001F (US, code 31) exercises the hexDigit high-nibble path: code / 16
  // == 1, so the escape is \u001f, not \u000X (#3309).
  val registry2 = Health.addReadinessCheck(Health.create(), "a\u{001f}b", { -> Health.pass() })
  val report2 = Health.runChecks(registry2, Readiness)
  assertEqual(
    report2.body,
    "{\"status\":\"ok\",\"checks\":{" + "\"a\\u001fb\":{\"status\":\"ok\",\"detail\":\"\"}}}",
    "U+001F escapes to \\u001f (high nibble 1)"
  )
}

// ─── runLiveness / runReadiness handler mapping ───────────────────────────────
test "runLiveness returns Ok with the JSON body when healthy" {
  val registry = Health.addLivenessCheck(Health.create(), "self", { -> passingCheck() })
  match Health.runLiveness(registry) {
    case Ok(body) -> assertEqual(
      body,
      "{\"status\":\"ok\",\"checks\":{\"self\":{\"status\":\"ok\",\"detail\":\"\"}}}",
      "Ok body"
    )
    case Err(_) -> assertTrue(false, "expected Ok from a healthy registry")
  }
}

test "runReadiness returns Err naming failing checks when degraded" {
  var registry = Health.create()
  registry = Health.addReadinessCheck(registry, "db", { -> failingCheck() })
  registry = Health.addReadinessCheck(registry, "cache", { -> Health.fail("cold") })
  match Health.runReadiness(registry) {
    case Ok(_) -> assertTrue(false, "expected Err from a degraded registry")
    case Err(msg) -> assertEqual(msg, "health checks degraded: db, cache", "failing check names")
  }
}

test "runLiveness returns Err naming failing checks when degraded" {
  var registry = Health.create()
  registry = Health.addLivenessCheck(registry, "self", { -> failingCheck() })
  registry = Health.addLivenessCheck(registry, "disk", { -> Health.fail("full") })
  match Health.runLiveness(registry) {
    case Ok(_) -> assertTrue(false, "expected Err from a degraded liveness registry")
    case Err(msg) -> assertEqual(msg, "health checks degraded: self, disk", "failing check names")
  }
}

test "runReadiness returns Ok with the JSON body when ready" {
  val registry = Health.addReadinessCheck(Health.create(), "db", { -> passingCheck() })
  match Health.runReadiness(registry) {
    case Ok(body) -> assertEqual(
      body,
      "{\"status\":\"ok\",\"checks\":{\"db\":{\"status\":\"ok\",\"detail\":\"\"}}}",
      "Ok body"
    )
    case Err(_) -> assertTrue(false, "expected Ok from a ready registry")
  }
}

test "runLiveness ignores readiness failures" {
  var registry = Health.create()
  registry = Health.addLivenessCheck(registry, "self", { -> passingCheck() })
  registry = Health.addReadinessCheck(registry, "db", { -> failingCheck() })
  match Health.runLiveness(registry) {
    case Ok(_) -> ()
    case Err(_) -> assertTrue(false, "liveness must not see readiness failures")
  }
}

// ─── hasCheckNamed ─────────────────────────────────────────────────────────────
test "hasCheckNamed is false on an empty registry" {
  assertFalse(Health.hasCheckNamed(Health.create(), "self"), "empty registry has no named checks")
}

test "hasCheckNamed is true after registering that name, false for another" {
  val registry = Health.addLivenessCheck(Health.create(), "self", { -> passingCheck() })
  assertTrue(Health.hasCheckNamed(registry, "self"), "registered name is found")
  assertFalse(Health.hasCheckNamed(registry, "other"), "unregistered name is not found")
}

// ─── Registration preconditions: empty name ───────────────────────────────────
test "addLivenessCheck panics on an empty name" {
  assertPanics("empty liveness check name", addLivenessCheckWithEmptyName)
}

test "addReadinessCheck panics on an empty name" {
  assertPanics("empty readiness check name", addReadinessCheckWithEmptyName)
}

// ─── Registration preconditions: duplicate name ───────────────────────────────
test "addLivenessCheck panics on a name already registered in the same group" {
  assertPanics("duplicate liveness check name", addLivenessCheckWithDuplicateName)
}

test "addReadinessCheck panics on a name already registered as a liveness check" {
  assertPanics("name already used by a liveness check", addReadinessCheckWithNameAlreadyUsedByLiveness)
}

// ─── Registration preconditions: timeoutMs ────────────────────────────────────
test "addLivenessCheckWithTimeout panics on timeoutMs == 0" {
  assertPanics("timeoutMs must be >= 1", addLivenessCheckWithTimeoutZero)
}

test "addReadinessCheckWithTimeout panics on a negative timeoutMs" {
  assertPanics("negative timeoutMs", addReadinessCheckWithTimeoutNegative)
}

test "addLivenessCheckWithTimeout accepts timeoutMs == 1 (boundary)" {
  val registry = Health.addLivenessCheckWithTimeout(Health.create(), "self", { -> passingCheck() }, 1)
  assertEqualInt(registry.checks[0].timeoutMs, 1, "timeoutMs boundary value stored")
}

// ─── HealthCheck / HealthRegistry invariants: direct construction ─────────────
test "constructing a HealthCheck directly with an empty name violates the invariant" {
  assertPanics("empty name", constructHealthCheckWithEmptyName)
}

test "constructing a HealthCheck directly with timeoutMs == 0 violates the invariant" {
  assertPanics("timeoutMs == 0", constructHealthCheckWithTimeoutZero)
}

test "constructing a HealthCheck directly with timeoutMs == -1 violates the invariant" {
  assertPanics("timeoutMs == -1", constructHealthCheckWithTimeoutNegativeOne)
}

test "constructing a HealthRegistry directly with duplicate check names violates the invariant" {
  assertPanics("duplicate names", constructHealthRegistryWithDuplicateNames)
}

test "addLivenessCheck stores defaultCheckTimeoutMs" {
  val registry = Health.addLivenessCheck(Health.create(), "self", { -> passingCheck() })
  assertEqualInt(registry.checks[0].timeoutMs, Health.defaultCheckTimeoutMs, "default timeout used")
}

// ─── Panic isolation ───────────────────────────────────────────────────────────
test "runChecks isolates a panicking check as unhealthy with a generic message" {
  val registry = Health.addLivenessCheck(Health.create(), "flaky", { -> panickingCheck() })
  val report = Health.runChecks(registry, Liveness)
  assertFalse(report.healthy, "a panicking check reports degraded")
  assertEqual(
    report.body,
    "{\"status\":\"degraded\",\"checks\":{\"flaky\":{\"status\":\"fail\",\"detail\":\"check panicked\"}}}",
    "panic is reported with a generic detail, never the panic's own message"
  )
}

test "runChecks isolates a panicking check alongside a passing one" {
  var registry = Health.create()
  registry = Health.addReadinessCheck(registry, "ok", { -> passingCheck() })
  registry = Health.addReadinessCheck(registry, "flaky", { -> panickingCheck() })
  val report = Health.runChecks(registry, Readiness)
  assertFalse(report.healthy, "one panicking check degrades the whole group")
  assertEqual(
    report.body,
    "{\"status\":\"degraded\",\"checks\":{" + "\"ok\":{\"status\":\"ok\",\"detail\":\"\"}," +
      "\"flaky\":{\"status\":\"fail\",\"detail\":\"check panicked\"}}}",
    "the passing check still ran and reported correctly"
  )
}

// ─── Bounded-wait timeout enforcement ──────────────────────────────────────────
// `Health.timeoutEnforced` reflects whether `timeoutMs` is actually a
// preemptive bound on this target: true on `--target dotnet`
// (`Health.Kernel.Net`'s real `Task.Wait(int)`), false on `--target jvm`
// (no existing facility to preemptively bound an arbitrary check's
// execution time — see `runCheckIsolated`'s `@cfg(feature = "jvm")` arm and
// README.md "Platform parity"). This test asserts each target's real,
// documented behaviour rather than picking one and skipping the other.
test "runChecks honors timeoutMs exactly as much as this target enforces it" {
  val registry = Health.addLivenessCheckWithTimeout(Health.create(), "slow", { -> slowCheck() }, 50)
  val report = Health.runChecks(registry, Liveness)
  if timeoutEnforced {
    assertFalse(report.healthy, "a check exceeding its timeoutMs reports degraded on this target")
    assertEqual(
      report.body,
      "{\"status\":\"degraded\",\"checks\":{\"slow\":{\"status\":\"fail\",\"detail\":\"check \\\"slow\\\" timed out after 50ms\"}}}",
      "timed-out check reports the timeout detail, not the eventual pass()"
    )
  } else {
    assertTrue(report.healthy, "without enforcement, the slow check still runs to completion and passes")
  }
}

test "runChecks does not time out a check that finishes within its budget" {
  val registry = Health.addLivenessCheckWithTimeout(Health.create(), "fast", { -> passingCheck() }, 5000)
  val report = Health.runChecks(registry, Liveness)
  assertTrue(report.healthy, "a check well within its timeoutMs is not falsely reported as timed out")
}
