// tests/health_tests.l — test suite for the Health package.
// Covers: registry construction, addLivenessCheck, addReadinessCheck,
// check field values, chaining multiple checks, and the stub handlers.

@test_module
package Health.HealthTests

import Std.Core
import Std.Testing
import Health
import Web

// ─── create ───────────────────────────────────────────────────────────────────

test "create returns an empty registry with no checks" {
  val registry = Health.create()
  assertEqualInt(registry.checks.length, 0, "empty registry has 0 checks")
}

// ─── addLivenessCheck ─────────────────────────────────────────────────────────

test "addLivenessCheck adds exactly one check to an empty registry" {
  val registry = Health.addLivenessCheck(Health.create(), "self", "MyApp.checkSelf")
  assertEqualInt(registry.checks.length, 1, "registry has 1 check after addLivenessCheck")
}

test "addLivenessCheck: check has the correct name" {
  val registry = Health.addLivenessCheck(Health.create(), "heartbeat", "MyApp.heartbeat")
  val check    = registry.checks[0]
  assertEqual(check.name, "heartbeat", "liveness check name")
}

test "addLivenessCheck: check has the correct handlerName" {
  val registry = Health.addLivenessCheck(Health.create(), "heartbeat", "MyApp.heartbeat")
  val check    = registry.checks[0]
  assertEqual(check.handlerName, "MyApp.heartbeat", "liveness check handlerName")
}

test "addLivenessCheck: check group is Liveness" {
  val registry = Health.addLivenessCheck(Health.create(), "live", "MyApp.live")
  val check    = registry.checks[0]
  match check.group {
    case CheckGroup.Liveness  -> ()
    case CheckGroup.Readiness -> assertTrue(false, "expected Liveness group, got Readiness")
  }
}

// ─── addReadinessCheck ────────────────────────────────────────────────────────

test "addReadinessCheck adds exactly one check to an empty registry" {
  val registry = Health.addReadinessCheck(Health.create(), "db", "MyApp.checkDb")
  assertEqualInt(registry.checks.length, 1, "registry has 1 check after addReadinessCheck")
}

test "addReadinessCheck: check has the correct name" {
  val registry = Health.addReadinessCheck(Health.create(), "cache", "MyApp.checkCache")
  val check    = registry.checks[0]
  assertEqual(check.name, "cache", "readiness check name")
}

test "addReadinessCheck: check has the correct handlerName" {
  val registry = Health.addReadinessCheck(Health.create(), "cache", "MyApp.checkCache")
  val check    = registry.checks[0]
  assertEqual(check.handlerName, "MyApp.checkCache", "readiness check handlerName")
}

test "addReadinessCheck: check group is Readiness" {
  val registry = Health.addReadinessCheck(Health.create(), "ready", "MyApp.ready")
  val check    = registry.checks[0]
  match check.group {
    case CheckGroup.Readiness -> ()
    case CheckGroup.Liveness  -> assertTrue(false, "expected Readiness group, got Liveness")
  }
}

// ─── Chaining multiple checks ─────────────────────────────────────────────────

test "adding a liveness then a readiness check yields 2 checks" {
  val registry =
    Health.addReadinessCheck(
      Health.addLivenessCheck(Health.create(), "live", "MyApp.live"),
      "db", "MyApp.checkDb")
  assertEqualInt(registry.checks.length, 2, "registry has 2 checks after chaining")
}

test "three chained checks are stored in insertion order" {
  val r0 = Health.create()
  val r1 = Health.addLivenessCheck(r0,  "live1", "MyApp.live1")
  val r2 = Health.addReadinessCheck(r1, "ready1", "MyApp.ready1")
  val r3 = Health.addReadinessCheck(r2, "ready2", "MyApp.ready2")
  assertEqualInt(r3.checks.length, 3, "three checks total")
  assertEqual(r3.checks[0].name, "live1",  "first check name")
  assertEqual(r3.checks[1].name, "ready1", "second check name")
  assertEqual(r3.checks[2].name, "ready2", "third check name")
}

// ─── Route handlers ──────────────────────────────────────────────────────────
// The __handle* functions are public (required for kernel dispatcher resolution)
// but intentionally not @stable.  These tests cover the current stub behavior
// that unconditionally returns {"status":"ok"} until the kernel dispatcher ships.

test "liveness handler returns Ok" {
  match Health.__handleLiveness() {
    case Ok(_)    -> ()
    case Err(err) -> assertTrue(false, "expected Ok from liveness handler, got Err: " + err.message)
  }
}

test "liveness handler Ok body contains 'ok'" {
  match Health.__handleLiveness() {
    case Ok(body) -> assertTrue(body.contains("ok"), "liveness body must contain 'ok'")
    case Err(_)   -> assertTrue(false, "expected Ok from liveness handler")
  }
}

test "readiness handler returns Ok" {
  match Health.__handleReadiness() {
    case Ok(_)    -> ()
    case Err(err) -> assertTrue(false, "expected Ok from readiness handler, got Err: " + err.message)
  }
}

test "readiness handler Ok body contains 'ok'" {
  match Health.__handleReadiness() {
    case Ok(body) -> assertTrue(body.contains("ok"), "readiness body must contain 'ok'")
    case Err(_)   -> assertTrue(false, "expected Ok from readiness handler")
  }
}
