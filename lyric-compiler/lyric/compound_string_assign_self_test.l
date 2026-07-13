//! compound_string_assign_self_test.l — runtime regression test for
//! compound-assignment `s += <rhs>` onto a `String` target (#5657).
//!
//! Before the fix the type checker discarded the assignment operator in
//! `SAssign`, so `s += true` / `s += 3.5` / `s += 42` were all rejected by
//! T0063 (checked as if they were `s = <rhs>`) even though binary `+` already
//! accepts `"" + true` etc.  The fix special-cases `+=` onto a String target
//! to accept any RHS, mirroring binary `+`'s "any operand + String = String".
//! The MSIL/JVM compound-combine codegen was already correct for plain-variable
//! targets, so once the check passes these lower to the same lowercase-Bool /
//! no-trailing-`.0`-Double stringification as `+` (#5552/#4688).
//!
//! Run by native `lyric test` on BOTH targets (like `bitwise_self_test.l`):
//!   lyric test --target dotnet lyric-compiler/lyric/compound_string_assign_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/compound_string_assign_self_test.l
//! Imports only `Std.*` (no `LYRIC_LOAD_COMPILER=1`).
@test_module
package Lyric.CompoundStringAssignSelfTest

import Std.Core
import Std.Testing

func boolAppend(): String {
  var s = "flag="
  s += true
  s
}

func boolAppendFalse(): String {
  var s = ""
  s += false
  s
}

func doubleAppendFrac(): String {
  var s = "n="
  s += 3.5
  s
}

func doubleAppendWhole(): String {
  var s = "n="
  s += 42.0
  s
}

func intAppend(): String {
  var s = "n="
  s += 42
  s
}

func stringAppend(): String {
  var s = "a"
  s += "b"
  s
}

test "s += Bool stringifies lowercase (#5657)" {
  assertEqual(boolAppend(), "flag=true", "s += true")
  assertEqual(boolAppendFalse(), "false", "s += false")
}

test "s += Double: fraction kept, whole value omits trailing .0 (#4688 parity)" {
  assertEqual(doubleAppendFrac(), "n=3.5", "s += 3.5")
  assertEqual(doubleAppendWhole(), "n=42", "s += 42.0 has no trailing .0")
}

test "s += Int" {
  assertEqual(intAppend(), "n=42", "s += 42")
}

test "s += String (same-type compound append still works)" {
  assertEqual(stringAppend(), "ab", "s += \"b\"")
}
