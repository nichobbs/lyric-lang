//! Regression test for function default-parameter filling and named-arg
//! reordering at call sites (#1503).
@test_module
package Lyric.FuncDefaultArgsSelfTest

import Std.Core
import Std.Testing

func addWithDefault(a: in Int, b: in Int = 10): Int {
  a + b
}

func greetFull(first: in String, last: in String, suffix: in String = "!"): String {
  first + " " + last + suffix
}

func tri(x: in Int, y: in Int = 2, z: in Int = 3): Int {
  x + y + z
}

test "positional call with trailing default filled" {
  assertEqualInt(addWithDefault(5), 15, "5 + default(10) = 15")
}

test "explicit positional override of default" {
  assertEqualInt(addWithDefault(5, 20), 25, "5 + 20 = 25")
}

test "named args in declaration order — no reorder needed" {
  assertEqual(greetFull(first = "Ada", last = "Lovelace"), "Ada Lovelace!", "default suffix")
}

test "named args in reverse order are reordered to declaration order" {
  assertEqual(greetFull(last = "Turing", first = "Alan"), "Alan Turing!", "reversed named args with default suffix")
}

test "named args with explicit suffix override" {
  assertEqual(greetFull(first = "Grace", last = "Hopper", suffix = "."), "Grace Hopper.", "explicit suffix")
}

test "three-param function: only first arg provided, two defaults filled" {
  assertEqualInt(tri(1), 6, "1 + default(2) + default(3) = 6")
}

test "three-param function: first two provided, last default filled" {
  assertEqualInt(tri(1, 5), 9, "1 + 5 + default(3) = 9")
}

test "three-param function: all named args, out-of-order" {
  assertEqualInt(tri(z = 10, x = 1, y = 5), 16, "1+5+10=16 out-of-order named")
}
