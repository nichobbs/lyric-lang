// stdlib/tests/process_capture_tests.l — Tests for the CWE-78 argument
// quoting in `Std.ProcessCapture.quoteArg` plus the diagnostic capture
// surface (`runCaptureWithDiagnostics`, `CaptureResult`).
//
// CWE-78 set pins the Windows CommandLineToArgvW round-trip for three
// attack surfaces:
//   1. Embedded double-quotes.
//   2. Trailing backslashes (the Windows path-injection vector).
//   3. Backslash-before-quote runs.
//
// `runCaptureWithDiagnostics` set uses `sh -c "..."` so the tests run on
// Linux and macOS CI; Windows coverage is tracked in #1116.

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
  assertEqual(quoteArg("hello world"), "\"hello world\"",
              "spaces preserved inside quotes")
}

func testQuoteEmbeddedQuote(): Unit {
  // `path"quoted"` becomes `"path\"quoted\""` so the CRT sees one arg.
  assertEqual(quoteArg("path\"quoted\""), "\"path\\\"quoted\\\"\"",
              "internal quotes are backslash-escaped")
}

func testQuoteTrailingBackslash(): Unit {
  // The headline CWE-78 case.  Input `C:\dir\` — without doubling the
  // trailing backslash the closing `"` would be escaped by it and the
  // next argument would be merged.
  assertEqual(quoteArg("C:\\dir\\"), "\"C:\\\\dir\\\\\"",
              "trailing backslash is doubled")
}

func testQuoteBackslashBeforeQuote(): Unit {
  // `a\"b` — the `\` must be doubled AND the `"` escaped, so the
  // resulting `\\\"` decodes back to a literal `\"` (not just `"`).
  assertEqual(quoteArg("a\\\"b"), "\"a\\\\\\\"b\"",
              "backslash-before-quote round-trips")
}

func testQuoteBackslashOnly(): Unit {
  // A single `\` becomes `\\` inside the quoted span.
  assertEqual(quoteArg("\\"), "\"\\\\\"",
              "single backslash is doubled")
}

func testQuoteEmpty(): Unit {
  // The empty string still gets the bracketing quotes so the receiving
  // tokeniser sees an explicit empty argument rather than nothing.
  assertEqual(quoteArg(""), "\"\"",
              "empty string becomes empty quoted token")
}

// ─── buildArgString — joining + spacing semantics (#786) ─────────────────────

func testBuildArgStringMultiple(): Unit {
  val args: List[String] = newList()
  args.add("ls")
  args.add("-la")
  args.add("/tmp")
  assertEqual(buildArgString(args), "\"ls\" \"-la\" \"/tmp\"",
              "three plain args joined by single spaces, each quoted")
}

func testBuildArgStringSingle(): Unit {
  val args: List[String] = newList()
  args.add("solo")
  assertEqual(buildArgString(args), "\"solo\"",
              "single arg has no leading space")
}

func testBuildArgStringEmpty(): Unit {
  val args: List[String] = newList()
  assertEqual(buildArgString(args), "",
              "empty list produces empty string")
}

func testBuildArgStringEmptyMember(): Unit {
  val args: List[String] = newList()
  args.add("cmd")
  args.add("")
  args.add("after")
  assertEqual(buildArgString(args), "\"cmd\" \"\" \"after\"",
              "empty middle arg still gets a bracketing pair")
}

func testBuildArgStringCwe78Vector(): Unit {
  // The trailing-backslash arg pattern (CWE-78 surface): one arg ends
  // with a single `\` and the next contains `&` and a space.  Joining
  // must double the trailing backslash before the closing `"` so the
  // shell never sees `\"` followed by an unquoted `&`.
  val args: List[String] = newList()
  args.add("path\\")           // "path\"
  args.add("&malicious flag")  // contains & and space
  // Expected: `"path\\" "&malicious flag"` — trailing backslash on the
  // first arg is doubled, the second arg's contents are wrapped as-is.
  assertEqual(buildArgString(args), "\"path\\\\\" \"&malicious flag\"",
              "trailing-backslash arg can't bleed into the next token")
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
  val r = runCaptureWithDiagnostics(
    "sh", makeShArgs("printf 'diag-msg' >&2; exit 3"), "")
  assertEqual(r.stderr, "diag-msg", "stderr surfaced verbatim")
  assertEqualInt(r.exitCode, 3, "non-zero exit code propagated")
  assertEqual(r.stdout, "", "stdout empty when only stderr emitted")
}

func testDiagnosticsSpawnFailure(): Unit {
  // Nonexistent executable: stdout/stderr empty, exitCode = -1, no
  // timeout.  Callers distinguish spawn-failure from genuine non-zero
  // exit via the sentinel exit code (-1) and the empty captured streams.
  val r = runCaptureWithDiagnostics(
    "__lyric_definitely_nonexistent_exe_xyz__",
    newList(),
    "")
  assertEqualInt(r.exitCode, -1, "spawn failure reports exit code -1")
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
  println("process_capture tests: ok")
  return 0
}
