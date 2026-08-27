//! stdlib/tests/process_capture_tests.l — Tests for the CWE-78 argument
//! quoting in `Std.ProcessCapture.quoteArg` plus the diagnostic capture
//! surface (`runCaptureWithDiagnostics`, `CaptureResult`).
//!
//! CWE-78 set pins the Windows CommandLineToArgvW round-trip for three
//! attack surfaces:
//!   1. Embedded double-quotes.
//!   2. Trailing backslashes (the Windows path-injection vector).
//!   3. Backslash-before-quote runs.
//!
//! `runCaptureWithDiagnostics` set uses `sh -c "..."` so the tests run on
//! Linux and macOS CI; Windows coverage is tracked in #1116.
package Std.ProcessCapture.Tests

import Std.Core
import Std.Collections
import Std.ProcessCapture
import Std.Testing

func testQuoteSimple(): Unit {
  // A plain word still gets wrapped in `"..."` — over-escaping by design.
  assertEqual(quoteArg("hello"), "\"hello\"", "plain word is quoted")
}

func testQuoteWithSpaces(): Unit {
  assertEqual(quoteArg("hello world"), "\"hello world\"", "spaces preserved inside quotes")
}

func testQuoteEmbeddedQuote(): Unit {
  // `path"quoted"` becomes `"path\"quoted\""` so the CRT sees one arg.
  assertEqual(quoteArg("path\"quoted\""), "\"path\\\"quoted\\\"\"", "internal quotes are backslash-escaped")
}

func testQuoteTrailingBackslash(): Unit {
  // The headline CWE-78 case.  Input `C:\dir\` — without doubling the
  // trailing backslash the closing `"` would be escaped by it and the
  // next argument would be merged.
  assertEqual(quoteArg("C:\\dir\\"), "\"C:\\\\dir\\\\\"", "trailing backslash is doubled")
}

func testQuoteBackslashBeforeQuote(): Unit {
  // `a\"b` — the `\` must be doubled AND the `"` escaped, so the
  // resulting `\\\"` decodes back to a literal `\"` (not just `"`).
  assertEqual(quoteArg("a\\\"b"), "\"a\\\\\\\"b\"", "backslash-before-quote round-trips")
}

func testQuoteBackslashOnly(): Unit {
  // A single `\` becomes `\\` inside the quoted span.
  assertEqual(quoteArg("\\"), "\"\\\\\"", "single backslash is doubled")
}

func testQuoteEmpty(): Unit {
  // The empty string still gets the bracketing quotes so the receiving
  // tokeniser sees an explicit empty argument rather than nothing.
  assertEqual(quoteArg(""), "\"\"", "empty string becomes empty quoted token")
}

// ─── buildArgString — joining + spacing semantics (#786) ─────────────────────
func testBuildArgStringMultiple(): Unit {
  val args: List[String] = newList()
  args.add("ls")
  args.add("-la")
  args.add("/tmp")
  assertEqual(buildArgString(args), "\"ls\" \"-la\" \"/tmp\"", "three plain args joined by single spaces, each quoted")
}

func testBuildArgStringSingle(): Unit {
  val args: List[String] = newList()
  args.add("solo")
  assertEqual(buildArgString(args), "\"solo\"", "single arg has no leading space")
}

func testBuildArgStringEmpty(): Unit {
  val args: List[String] = newList()
  assertEqual(buildArgString(args), "", "empty list produces empty string")
}

func testBuildArgStringEmptyMember(): Unit {
  val args: List[String] = newList()
  args.add("cmd")
  args.add("")
  args.add("after")
  assertEqual(buildArgString(args), "\"cmd\" \"\" \"after\"", "empty middle arg still gets a bracketing pair")
}

func testBuildArgStringCwe78Vector(): Unit {
  // The trailing-backslash arg pattern (CWE-78 surface): one arg ends
  // with a single `\` and the next contains `&` and a space.  Joining
  // must double the trailing backslash before the closing `"` so the
  // shell never sees `\"` followed by an unquoted `&`.
  val args: List[String] = newList()
  args.add("path\\")
  // "path\"
  args.add("&malicious flag")
  // contains & and space
  // Expected: `"path\\" "&malicious flag"` — trailing backslash on the
  // first arg is doubled, the second arg's contents are wrapped as-is.
  assertEqual(
    buildArgString(args),
    "\"path\\\\\" \"&malicious flag\"",
    "trailing-backslash arg can't bleed into the next token"
  )
}

// ─── runCaptureWithDiagnostics — exit code / stderr surface (#1055) ──────────
func makeShArgs(cmd: in String): List[String] {
  val args: List[String] = newList()
  args.add("-c")
  args.add(cmd)
  args
}

func testDiagnosticsStdout(): Unit {
  val r = runCaptureWithDiagnostics("sh", makeShArgs("printf 'hi'"), "")
  assertEqual(r.stdout, "hi", "stdout surfaced")
  assertEqualInt(r.exitCode, 0, "exit code is 0")
  assertTrue(not r.timedOut, "no timeout fired")
}

func testDiagnosticsStderr(): Unit {
  // Generator/solver failure scenario: process exits non-zero and emits
  // a diagnostic message on stderr.  The diagnostic-capture surface must
  // surface both so callers can format actionable error messages.
  val r = runCaptureWithDiagnostics("sh", makeShArgs("printf 'diag-msg' >&2; exit 3"), "")
  assertEqual(r.stderr, "diag-msg", "stderr surfaced verbatim")
  assertEqualInt(r.exitCode, 3, "non-zero exit code propagated")
  assertEqual(r.stdout, "", "stdout empty when only stderr emitted")
}

func testDiagnosticsSpawnFailure(): Unit {
  // Nonexistent executable: stdout/stderr empty, exitCode = -1, no
  // timeout.  Callers distinguish spawn-failure from genuine non-zero
  // exit via the sentinel exit code (-1) and the empty captured streams.
  val r = runCaptureWithDiagnostics("__lyric_definitely_nonexistent_exe_xyz__", newList(), "")
  assertEqualInt(r.exitCode, -1, "spawn failure reports exit code -1")
  assertEqual(r.stdout, "", "spawn failure produces empty stdout")
  assertEqual(r.stderr, "", "spawn failure produces empty stderr")
  assertTrue(not r.timedOut, "spawn failure is not a timeout")
}

// ─── stdoutBytes / stderrBytes — raw-bytes capture (#4753) ──────────────────
func testDiagnosticsStdoutBytesInvalidUtf8(): Unit {
  // printf octal escapes emit raw bytes 0xFF and 0xFE — never valid UTF-8
  // lead bytes — interleaved with plain ASCII.  `stdoutBytes` must equal
  // the exact bytes the child wrote, independent of whatever the UTF-8
  // decoder does with the invalid sequence when producing `stdout`.
  val r = runCaptureWithDiagnostics("sh", makeShArgs("printf 'AB\\377\\376CD'"), "")
  assertEqualInt(r.stdoutBytes.length, 6, "raw byte count includes the invalid bytes")
  assertEqualInt(r.stdoutBytes[0].toInt(), 65, "byte[0] 'A'")
  assertEqualInt(r.stdoutBytes[1].toInt(), 66, "byte[1] 'B'")
  assertEqualInt(r.stdoutBytes[2].toInt(), 255, "byte[2] 0xFF (invalid UTF-8 lead byte)")
  assertEqualInt(r.stdoutBytes[3].toInt(), 254, "byte[3] 0xFE (invalid UTF-8 lead byte)")
  assertEqualInt(r.stdoutBytes[4].toInt(), 67, "byte[4] 'C'")
  assertEqualInt(r.stdoutBytes[5].toInt(), 68, "byte[5] 'D'")
}

func testDiagnosticsStdoutBytesMultibyteUtf8(): Unit {
  // \303\251 = 0xC3 0xA9 (é, U+00E9), \303\274 = 0xC3 0xBC (ü, U+00FC):
  // valid multi-byte UTF-8 sequences.  `stdoutBytes` must match the raw
  // encoded bytes exactly, and decoding those same bytes must reproduce
  // the `stdout` String — proving `stdoutBytes` is the source `stdout`
  // was decoded from, not an independent (and potentially divergent)
  // re-encode of it.
  val r = runCaptureWithDiagnostics("sh", makeShArgs("printf '\\303\\251\\303\\274'"), "")
  assertEqualInt(r.stdoutBytes.length, 4, "utf-8 multibyte byte count")
  assertEqualInt(r.stdoutBytes[0].toInt(), 195, "byte[0] 0xC3")
  assertEqualInt(r.stdoutBytes[1].toInt(), 169, "byte[1] 0xA9")
  assertEqualInt(r.stdoutBytes[2].toInt(), 195, "byte[2] 0xC3")
  assertEqualInt(r.stdoutBytes[3].toInt(), 188, "byte[3] 0xBC")
  assertEqual(r.stdout, "éü", "decoded stdout matches the same content the bytes encode")
}

func testDiagnosticsStderrBytes(): Unit {
  // stderrBytes mirrors stdoutBytes on the stderr pipe.
  val r = runCaptureWithDiagnostics("sh", makeShArgs("printf '\\377X' >&2"), "")
  assertEqualInt(r.stderrBytes.length, 2, "stderr raw byte count")
  assertEqualInt(r.stderrBytes[0].toInt(), 255, "stderr byte[0] 0xFF")
  assertEqualInt(r.stderrBytes[1].toInt(), 88, "stderr byte[1] 'X'")
}

func testDiagnosticsBytesEmptyOnSpawnFailure(): Unit {
  val r = runCaptureWithDiagnostics("__lyric_definitely_nonexistent_exe_xyz__", newList(), "")
  assertEqualInt(r.stdoutBytes.length, 0, "spawn failure produces empty stdoutBytes")
  assertEqualInt(r.stderrBytes.length, 0, "spawn failure produces empty stderrBytes")
}

func testDiagnosticsTimeoutSpawnFailure(): Unit {
  // #6261: a failed LAUNCH through the Timeout entry point must return a
  // failed CaptureResult, not throw.  Before the fix, `hostRunCaptureTimeout`
  // had no try/catch wrapper (unlike `hostRunCapture`), so this crashed with
  // an unhandled exception instead of surfacing exitCode = -1.
  val r = runCaptureWithDiagnosticsTimeout("__lyric_definitely_nonexistent_exe_xyz__", newList(), "", 5000)
  assertEqualInt(r.exitCode, -1, "spawn failure via Timeout entry point reports exit code -1")
  assertEqual(r.stdout, "", "spawn failure produces empty stdout")
  assertEqual(r.stderr, "", "spawn failure produces empty stderr")
  assertTrue(not r.timedOut, "spawn failure is not a timeout")
}

func main(): Int {
  testQuoteSimple()
  testQuoteWithSpaces()
  testQuoteEmbeddedQuote()
  testQuoteTrailingBackslash()
  testQuoteBackslashBeforeQuote()
  testQuoteBackslashOnly()
  testQuoteEmpty()
  testBuildArgStringMultiple()
  testBuildArgStringSingle()
  testBuildArgStringEmpty()
  testBuildArgStringEmptyMember()
  testBuildArgStringCwe78Vector()
  testDiagnosticsStdout()
  testDiagnosticsStderr()
  testDiagnosticsSpawnFailure()
  testDiagnosticsStdoutBytesInvalidUtf8()
  testDiagnosticsStdoutBytesMultibyteUtf8()
  testDiagnosticsStderrBytes()
  testDiagnosticsBytesEmptyOnSpawnFailure()
  testDiagnosticsTimeoutSpawnFailure()
  println("process_capture tests: ok")
  return 0
}
