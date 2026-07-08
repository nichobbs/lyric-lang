//! lyric-compiler/lyric/stdlib_jvm_kernels_self_test.l
//!
//! @test_module covering four `lyric-stdlib/std/_kernel_jvm/*.l` kernels
//! migrated off the non-functional `extern package` mechanism onto plain
//! `extern type` + JVM auto-FFI: `environment_host.l`, `process_host.l`,
//! `log_host.l`, `unicode_host.l`.  Before this migration every function in
//! these four files crashed immediately on first call ("unsupported
//! method ... no matching user method, extern binding, or built-in
//! intrinsic") -- `extern package` parses but is a no-op in the type
//! checker and both codegens.
//!
//! Imports the KERNEL packages (`Std.EnvironmentHost` / `Std.ProcessHost` /
//! `Std.LogHost` / `Std.UnicodeHost`) directly rather than their public
//! wrappers (`Std.Environment` / `Std.Process` / `Std.Log`): three of the
//! four public wrappers currently hit separate, pre-existing, unrelated JVM
//! codegen bugs found while migrating these kernels (tracked as issues
//! #5377, #5378, #5380, #5381 -- see docs/03-decision-log.md for the full
//! writeup), so testing through them would conflate those bugs with this
//! migration's own correctness.  This file verifies the kernel functions
//! themselves resolve and behave correctly; the public-wrapper bugs are
//! each separately tracked and unaffected by this migration.
//!
//! `Std.EnvironmentHost.hostExit` / `Std.EnvironmentHost.
//! hostGetCommandLineArgs` are not exercised here: the former terminates
//! the JVM process (incompatible with a test harness expecting the process
//! to complete and report every test), the latter panics deliberately
//! (tracked as issue #5377) -- both are manually verified in the PR
//! description instead.
//!
//! Run via `lyric test --target jvm` so the self-hosted Jvm.Bridge pipeline
//! is exercised end-to-end.
@test_module
package Lyric.StdlibJvmKernelsSelfTest

import Std.Core
import Std.Testing
import Std.EnvironmentHost
import Std.ProcessHost
import Std.LogHost
import Std.UnicodeHost

// ── Std.EnvironmentHost ─────────────────────────────────────────────────────
test "hostGetVarOpt resolves a real environment variable via System.getenv" {
  // PATH is set in every POSIX process launched from a shell, including the
  // JVM this test runs under.
  match hostGetVarOpt("PATH") {
    case Some(v) -> assertTrue(v.length > 0, "PATH is set and non-empty")
    case None -> panic("PATH should be set in the test environment")
  }
}

test "hostGetVarOpt returns None for a variable that is not set" {
  match hostGetVarOpt("LYRIC_DEFINITELY_NOT_SET_KERNEL_TEST_XYZ") {
    case Some(_) -> panic("unexpected: variable should not be set")
    case None -> assertTrue(true, "correctly absent")
  }
}

test "hostRuntimeDirectory / hostRuntimeIdentifier / hostSetEnvironmentVariable do not crash" {
  // .NET-only concepts with no JVM equivalent; the empty-string /
  // no-op stubs must resolve and run without throwing.
  assertEqual(hostRuntimeDirectory(), "", "hostRuntimeDirectory is the empty-string stub on JVM")
  assertEqual(hostRuntimeIdentifier(), "", "hostRuntimeIdentifier is the empty-string stub on JVM")
  hostSetEnvironmentVariable("LYRIC_KERNEL_TEST_NOOP", "x")
  assertTrue(true, "hostSetEnvironmentVariable's no-op stub did not crash")
}

test "hostAppBaseDirectory is the empty-string stub; hostCurrentDirectory returns a real absolute path" {
  // hostAppBaseDirectory has no accurate JVM equivalent to .NET's
  // AppContext.BaseDirectory (see the kernel's doc comment) -- "" per the
  // established "empty = unavailable" convention, not a plausible-looking
  // but potentially wrong cwd substitute.
  assertEqual(hostAppBaseDirectory(), "", "hostAppBaseDirectory is the empty-string stub on JVM")
  // hostCurrentDirectory IS a genuine, accurate JVM equivalent (user.dir).
  val cwd = hostCurrentDirectory()
  assertTrue(cwd.length > 0, "hostCurrentDirectory is non-empty")
  assertTrue(cwd.startsWith("/"), "hostCurrentDirectory is a real POSIX absolute path")
}

test "hostGetCommandLineArgs panics (issue #5377) rather than crashing on the old extern package no-op" {
  // Regression for the JDK-has-no-argv-retrieval gap (issue #5377): this
  // must fail loud, not the generic "unsupported method" crash the old
  // extern package no-op produced.  Uses assertPanics (occurrence only),
  // not assertPanicsWith (message content): a closure-propagated panic's
  // .message is unreliable on JVM (issue #5388, found while writing this
  // test), independent of hostGetCommandLineArgs itself -- manually
  // verified the real panic text separately (see the PR description).
  assertPanics("hostGetCommandLineArgs panics rather than returning/crashing silently", { -> hostGetCommandLineArgs() })
}

// ── Std.ProcessHost ──────────────────────────────────────────────────────────
test "hostSpawn/hostWait/hostExitCode/hostDisposeProc run a real child process" {
  val proc = hostSpawn("/bin/sh", "\"-c\" \"exit 7\"")
  hostWait(proc)
  val code = hostExitCode(proc)
  hostDisposeProc(proc)
  assertEqualInt(code, 7, "child process exit code round-trips through ProcessBuilder/Process")
}

test "hostSpawn/hostWait/hostExitCode with a zero exit code" {
  val proc = hostSpawn("/bin/sh", "\"-c\" \"exit 0\"")
  hostWait(proc)
  val code = hostExitCode(proc)
  hostDisposeProc(proc)
  assertEqualInt(code, 0, "successful child process reports exit code 0")
}

// ── Std.LogHost ────────────────────────────────────────────────────────────
test "write resolves and runs without crashing (java.util.logging.Logger reference removed)" {
  // The old header comment claimed a java.util.logging.Logger-backed shim;
  // this kernel now matches the .NET twin exactly (a plain stderr write via
  // Std.ConsoleHost).  Capturing stderr content isn't exercised here; this
  // asserts the call resolves and returns rather than crashing the way the
  // extern package no-op did on every prior call.
  write("INFO", "stdlib_jvm_kernels_self_test smoke message")
  assertTrue(true, "Std.LogHost.write ran without throwing")
}

// ── Std.UnicodeHost ──────────────────────────────────────────────────────────
//
// Verifies jvmCategoryToNetConvention's translation table against known
// .NET System.Globalization.UnicodeCategory ordinals, cross-checked against
// an identical dotnet-target run of the same code points (see this PR's
// description) -- all five matched exactly.
test "hostUnicodeCategory matches the .NET UnicodeCategory convention for common categories" {
  assertEqualInt(hostUnicodeCategory('A'), 0, "'A' is UppercaseLetter (0)")
  assertEqualInt(hostUnicodeCategory('a'), 1, "'a' is LowercaseLetter (1)")
  assertEqualInt(hostUnicodeCategory('0'), 8, "'0' is DecimalDigitNumber (8)")
  assertEqualInt(hostUnicodeCategory('_'), 18, "'_' is ConnectorPunctuation (18)")
  assertEqualInt(hostUnicodeCategory(' '), 11, "' ' is SpaceSeparator (11)")
}

test "hostUnicodeCategory matches the .NET UnicodeCategory convention for less common categories" {
  assertEqualInt(hostUnicodeCategory('('), 20, "'(' is OpenPunctuation (20)")
  assertEqualInt(hostUnicodeCategory(')'), 21, "')' is ClosePunctuation (21)")
  assertEqualInt(hostUnicodeCategory('-'), 19, "'-' is DashPunctuation (19)")
  assertEqualInt(hostUnicodeCategory('+'), 25, "'+' is MathSymbol (25)")
  assertEqualInt(hostUnicodeCategory('$'), 26, "'$' is CurrencySymbol (26)")
}
