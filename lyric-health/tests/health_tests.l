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
// `__handleLiveness` / `__handleReadiness` are public so the kernel
// dispatcher can resolve them by name once it lands.  Until then, the
// downstream `runChecks` panics rather than silently reporting "ok"
// for an unimplemented health pipeline (#367: a silent stub on a
// health endpoint would let a degraded service ship as healthy).
//
// The tests below pin the panic contract via `Std.Testing.assertPanicsWith`
// (#1176).  Without these, a refactor of `runChecks` could regress to a
// silent `Ok("...")` stub without CI catching it.  The substring matched
// is the most stable part of the message: the literal "kernel dispatcher
// not yet implemented" — a future change of the message body wider than
// that is a deliberate API change that should be reflected in updated
// tests, not silently allowed.

test "liveness handler panics with kernel-dispatcher-missing message" {
  assertPanicsWith(
    "liveness handler panics",
    "kernel dispatcher not yet implemented",
    { -> val _ = Health.__handleLiveness() })
}

test "readiness handler panics with kernel-dispatcher-missing message" {
  assertPanicsWith(
    "readiness handler panics",
    "kernel dispatcher not yet implemented",
    { -> val _ = Health.__handleReadiness() })
}
