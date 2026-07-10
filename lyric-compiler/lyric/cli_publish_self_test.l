//! cli_publish_self_test.l — exercises the pure NU1102 retry/backoff
//! decision helpers in `Lyric.Cli` (cli/cli_shared.l): `shouldRetryRestore`
//! and `backoffMsForAttempt`. These back `runRestoreWithRetry`, which wraps
//! the `dotnet restore` calls in both `lyric publish` (cli_publish.l) and
//! `lyric restore` (cli_restore.l) with retry-on-NU1102 logic, but the
//! decision logic itself does no I/O and no process spawning, so it can be
//! exercised directly without a network connection or a real `dotnet`
//! invocation (#5239).
//!
//! Run in CI via:
//!
//!   lyric test lyric-compiler/lyric/cli_publish_self_test.l
@test_module
package Lyric.CliPublishSelfTest

import Std.Core
import Std.Testing
import Lyric.Cli as Cli

// ─── shouldRetryRestore: NU1102 retries through the max attempt ──────────

test "shouldRetryRestore: NU1102 in stdout retries on attempt 1" {
  assertTrue(
    Cli.shouldRetryRestore(1, "error NU1102: unable to find package", "", 1, false),
    "NU1102 in stdout on attempt 1 should retry"
  )
}

test "shouldRetryRestore: NU1102 in stderr retries on attempt 1" {
  assertTrue(
    Cli.shouldRetryRestore(1, "", "error NU1102: unable to find package", 1, false),
    "NU1102 in stderr on attempt 1 should retry"
  )
}

test "shouldRetryRestore: NU1102 retries through the last attempt before the max" {
  assertTrue(
    Cli.shouldRetryRestore(1, "NU1102", "", Cli.nu1102MaxAttempts - 1, false),
    "NU1102 on attempt (nu1102MaxAttempts - 1) should still retry"
  )
}

test "shouldRetryRestore: NU1102 does not retry once nu1102MaxAttempts is reached" {
  assertFalse(
    Cli.shouldRetryRestore(1, "NU1102", "", Cli.nu1102MaxAttempts, false),
    "NU1102 on the final attempt (nu1102MaxAttempts) must not retry"
  )
}

// ─── shouldRetryRestore: non-NU1102 / success / timeout never retry ──────

test "shouldRetryRestore: unrelated restore failure never retries" {
  assertFalse(
    Cli.shouldRetryRestore(1, "error NU1000: some other failure", "", 1, false),
    "a non-NU1102 failure must not retry even on the first attempt"
  )
}

test "shouldRetryRestore: success (exit code 0) never retries" {
  assertFalse(
    Cli.shouldRetryRestore(0, "NU1102", "", 1, false),
    "an exit code of 0 must not retry even if NU1102 text is present"
  )
}

test "shouldRetryRestore: a timed-out attempt never retries, even with NU1102 present" {
  assertFalse(
    Cli.shouldRetryRestore(1, "NU1102", "", 1, true),
    "a timed-out attempt must not retry"
  )
}

// ─── backoffMsForAttempt: escalation then plateau ─────────────────────────

test "backoffMsForAttempt: escalates by nu1102BaseBackoffMs per attempt through nu1102EscalationAttempts" {
  assertEqualInt(Cli.backoffMsForAttempt(1), Cli.nu1102BaseBackoffMs, "attempt 1 backoff")
  assertEqualInt(Cli.backoffMsForAttempt(2), 2 * Cli.nu1102BaseBackoffMs, "attempt 2 backoff")
  assertEqualInt(Cli.backoffMsForAttempt(3), 3 * Cli.nu1102BaseBackoffMs, "attempt 3 backoff")
  assertEqualInt(
    Cli.backoffMsForAttempt(Cli.nu1102EscalationAttempts),
    Cli.nu1102EscalationAttempts * Cli.nu1102BaseBackoffMs,
    "attempt nu1102EscalationAttempts backoff (top of the ramp)"
  )
}

test "backoffMsForAttempt: holds flat at nu1102PlateauBackoffMs past nu1102EscalationAttempts" {
  assertEqualInt(
    Cli.backoffMsForAttempt(Cli.nu1102EscalationAttempts + 1),
    Cli.nu1102PlateauBackoffMs,
    "attempt nu1102EscalationAttempts + 1 backoff (plateau)"
  )
  assertEqualInt(
    Cli.backoffMsForAttempt(Cli.nu1102MaxAttempts),
    Cli.nu1102PlateauBackoffMs,
    "final attempt backoff (still plateau)"
  )
}

test "backoffMsForAttempt: plateau equals the top of the escalation ramp" {
  assertEqualInt(
    Cli.nu1102PlateauBackoffMs,
    Cli.nu1102EscalationAttempts * Cli.nu1102BaseBackoffMs,
    "plateau backoff must equal escalationAttempts * baseBackoffMs"
  )
}
