// stdlib/tests/process_capture_tests.l — Tests for the CWE-78 argument
// quoting in `Std.ProcessCapture.quoteArg`.
//
// Pins the Windows CommandLineToArgvW round-trip for the three attack
// surfaces the fix targets:
//   1. Embedded double-quotes.
//   2. Trailing backslashes (the Windows path-injection vector).
//   3. Backslash-before-quote runs.

package Std.ProcessCapture.Tests

import Std.Core
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

func main(): Int {
  testQuoteSimple()
  testQuoteWithSpaces()
  testQuoteEmbeddedQuote()
  testQuoteTrailingBackslash()
  testQuoteBackslashBeforeQuote()
  testQuoteBackslashOnly()
  testQuoteEmpty()
  println("process_capture tests: ok")
  return 0
}
