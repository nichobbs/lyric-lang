//! Testing.Conformance — the shared harness behind the conformance suites.
//!
//! A conformance suite is a function that takes a factory for the
//! implementation under test and exercises the contract the library's
//! interface documents.  Every in-tree backend runs its suite from
//! `lyric-testing/tests/`, and an out-of-tree backend runs the same suite from
//! its own test module:
//!
//!   import Testing.Conformance
//!   import Testing.Conformance.Cache as CacheConformance
//!
//!   test "MyRedisCacheStore conforms to CacheStore" {
//!     val checks = CacheConformance.run({ -> connectMyStore() }, { s -> sleepSeconds(s) })
//!     Conformance.requireConformance(checks)
//!   }
//!
//! A suite never aborts at the first failure: each case runs under
//! `runCase`, which records a failed expectation, or a panic raised by the
//! backend, against the case's name and carries on with the next case.
//! `requireConformance` then fails the calling test once, listing every
//! failed case.
@runtime_checked
@io
package Testing.Conformance

import Std.Core
import Std.Collections
import Std.String as Str

/// The running tally of one suite: how many expectations held and the
/// description of every one that did not.
@stable(since = "0.1")
pub ref record Checks {
  suite: String
  var current: String
  var passedCount: Int
  var failureList: List[String]
  var caseCount: Int
}

/// Start the tally for the suite named `suite`.
@stable(since = "0.1")
pub func newChecks(suite: in String): Checks {
  return Checks(suite = suite, current = "", passedCount = 0, failureList = newList(), caseCount = 0)
}

/// Run one named case.  A panic from the body (a contract violation inside
/// the backend, for instance) is recorded as a failure of this case, not
/// propagated, so the remaining cases still run.
@stable(since = "0.1")
pub func runCase(checks: in Checks, name: in String, body: () -> Unit): Unit {
  checks.current = name
  checks.caseCount = checks.caseCount + 1
  try {
    body()
  } catch Bug as b {
    recordFailure(checks, "panicked: " + b.message)
  }
  checks.current = ""
}

/// Start a case by hand, for a suite whose cases cannot run inside a plain
/// closure (the `async` ones).  Pair it with `casePanicked` in a `catch`.
@stable(since = "0.1")
pub func beginCase(checks: in Checks, name: in String): Unit {
  checks.current = name
  checks.caseCount = checks.caseCount + 1
}

/// Record that the case in progress panicked.
@stable(since = "0.1")
pub func casePanicked(checks: in Checks, message: in String): Unit {
  recordFailure(checks, "panicked: " + message)
}

func recordFailure(checks: in Checks, what: in String): Unit {
  checks.failureList.add(checks.suite + " / " + checks.current + ": " + what)
}

/// Expect `cond` to hold.
@stable(since = "0.1")
pub func expectTrue(checks: in Checks, cond: in Bool, what: in String): Unit {
  if cond {
    checks.passedCount = checks.passedCount + 1
  } else {
    recordFailure(checks, what)
  }
}

/// Expect two strings to be equal.
@stable(since = "0.1")
pub func expectEqual(checks: in Checks, actual: in String, expected: in String, what: in String): Unit {
  if actual == expected {
    checks.passedCount = checks.passedCount + 1
  } else {
    recordFailure(checks, what + " (expected \"" + expected + "\", got \"" + actual + "\")")
  }
}

/// Expect two `Int`s to be equal.
@stable(since = "0.1")
pub func expectEqualInt(checks: in Checks, actual: in Int, expected: in Int, what: in String): Unit {
  expectEqual(checks, actual.toString(), expected.toString(), what)
}

/// Expect two `Long`s to be equal.
@stable(since = "0.1")
pub func expectEqualLong(checks: in Checks, actual: in Long, expected: in Long, what: in String): Unit {
  expectEqual(checks, actual.toString(), expected.toString(), what)
}

/// Expect an `Option[String]` to hold exactly `expected`.
@stable(since = "0.1")
pub func expectSome(checks: in Checks, actual: in Option[String], expected: in String, what: in String): Unit {
  match actual {
    case Some(v) -> expectEqual(checks, v, expected, what)
    case None -> recordFailure(checks, what + " (expected Some(\"" + expected + "\"), got None)")
  }
}

/// Expect an `Option[String]` to be `None`.
@stable(since = "0.1")
pub func expectNone(checks: in Checks, actual: in Option[String], what: in String): Unit {
  match actual {
    case Some(v) -> recordFailure(checks, what + " (expected None, got Some(\"" + v + "\"))")
    case None -> {
      checks.passedCount = checks.passedCount + 1
    }
  }
}

/// Record a failure unconditionally (for a branch that must not be reached).
@stable(since = "0.1")
pub func failCase(checks: in Checks, what: in String): Unit {
  recordFailure(checks, what)
}

/// The number of expectations that held.
@stable(since = "0.1")
pub func passedCount(checks: in Checks): Int {
  return checks.passedCount
}

/// The number of cases the suite ran.
@stable(since = "0.1")
pub func caseCount(checks: in Checks): Int {
  return checks.caseCount
}

/// One line per failed expectation; empty when the backend conforms.
@stable(since = "0.1")
pub func failures(checks: in Checks): slice[String] {
  return checks.failureList.toArray()
}

/// A human-readable summary of the run.
@stable(since = "0.1")
pub func summary(checks: in Checks): String {
  val n = checks.failureList.count
  if n == 0 {
    return checks.suite + ": " + checks.caseCount.toString() + " cases, " + checks.passedCount.toString() +
      " expectations, all held"
  }
  return checks.suite + ": " + n.toString() + " expectation(s) failed across " + checks.caseCount.toString() +
    " cases\n  " +
    Str.join("\n  ", checks.failureList.toArray())
}

/// Fail the calling test (a panic) when any expectation failed, naming every
/// failure.  Also fails when the suite ran no case at all, so an empty run can
/// never read as a pass.
@stable(since = "0.1")
pub func requireConformance(checks: in Checks): Unit {
  if checks.caseCount == 0 {
    panic(checks.suite + ": the suite ran no cases")
  }
  if checks.failureList.count > 0 {
    panic(summary(checks))
  }
}
