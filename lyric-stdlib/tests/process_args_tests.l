//! tests/process_args_tests.l — Std.ProcessArgs, the argv encoder/decoder
//! every process kernel shares (#7234).
//!
//! `Std.Process.buildArgString` used to quote only arguments containing a
//! space, quote or backslash, doubling every backslash inside the quotes: an
//! argument `a\b` reached the child as `a\\b`, a tab or newline split one
//! argument into two, and an empty argument vanished.  These tests pin the
//! canonical CommandLineToArgvW round trip and exercise it through a real
//! child process.
@test_module
package Std.ProcessArgs.Tests

import Std.Core
import Std.Collections
import Std.Testing
import Std.ProcessArgs
import Std.Process

func listOf(xs: in slice[String]): List[String] {
  val acc: List[String] = newList()
  var i = 0
  while i < xs.length {
    acc.add(xs[i])
    i = i + 1
  }
  acc
}

func roundTrips(xs: in slice[String]): Bool {
  val back = argvSplit(argvJoin(listOf(xs)))
  if back.count != xs.length {
    return false
  }
  var i = 0
  while i < xs.length {
    if back[i] != xs[i] {
      return false
    }
    i = i + 1
  }
  true
}

test "argvJoin/argvSplit round-trip backslashes, quotes and trailing runs" {
  assertTrue(roundTrips(["a\\b", "C:\\dir\\", "a\\\"b", "\\", "\\\\", "x\\\\y"]), "backslash shapes")
  assertTrue(roundTrips(["say \"hi\"", "\"", "\"\""]), "quotes")
}

test "argvJoin/argvSplit keep blanks, tabs, newlines and empty arguments inside one argument" {
  assertTrue(roundTrips(["x y", "t\tab", "line1\nline2", "", "", "end"]), "separators stay inside their argument")
}

test "argvSplit decodes CommandLineToArgvW input it did not produce" {
  val parsed = argvSplit("plain \"quoted arg\" a\\\\\\\"b \"in \"\"double\"\" quotes\"")
  assertEqualInt(parsed.count, 4, "four arguments")
  assertEqual(parsed[0], "plain", "unquoted")
  assertEqual(parsed[1], "quoted arg", "quoted")
  assertEqual(parsed[2], "a\\\"b", "three backslashes before a quote: one backslash, literal quote")
  assertEqual(parsed[3], "in \"double\" quotes", "doubled quote inside quotes")
}

test "a child process receives every argument exactly as given" {
  val args = listOf(["[%s]", "a\\b", "x y", "", "t\tab", "q\"uote"])
  match Std.Process.runCapture("printf", args, 10000) {
    case Ok(r) -> assertEqual(r.stdout, "[a\\b][x y][][t\tab][q\"uote]", "printf echoes each argument back")
    case Err(e) -> assertTrue(false, "spawn failed: " + e)
  }
}
