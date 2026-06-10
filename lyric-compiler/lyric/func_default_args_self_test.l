//! Regression test for function named-arg reordering at call sites (#1503).
//!
//! The F# bootstrap type checker (used on the --target dotnet path) enforces
//! strict call-site arity (T0042) and does not yet understand default-param
//! omission.  Tests here always supply all declared arguments so they pass
//! both the F# type checker and the self-hosted type checker, isolating the
//! named-arg reorder codepath.  Default-param fill CI coverage is deferred
//! until the self-hosted type checker is the primary path for --target dotnet.
@test_module
package Lyric.FuncDefaultArgsSelfTest

import Std.Core
import Std.Testing

func addTwo(a: in Int, b: in Int): Int {
  a + b
}

func greetFull(first: in String, last: in String, suffix: in String): String {
  first + " " + last + suffix
}

func tri(x: in Int, y: in Int, z: in Int): Int {
  x + y + z
}

test "positional call — both args provided" {
  assertEqualInt(addTwo(5, 10), 15, "5 + 10 = 15")
}

test "named args in declaration order — no reorder needed" {
  assertEqual(greetFull(first = "Ada", last = "Lovelace", suffix = "!"), "Ada Lovelace!", "default suffix")
}

test "named args in reverse order are reordered to declaration order" {
  assertEqual(greetFull(last = "Turing", first = "Alan", suffix = "!"), "Alan Turing!", "reversed named args")
}

test "named args with explicit suffix override" {
  assertEqual(greetFull(first = "Grace", last = "Hopper", suffix = "."), "Grace Hopper.", "explicit suffix")
}

test "three-param function: all positional" {
  assertEqualInt(tri(1, 2, 3), 6, "1 + 2 + 3 = 6")
}

test "three-param function: first two positional, last named" {
  assertEqualInt(tri(1, 5, z = 3), 9, "1 + 5 + 3 = 9")
}

test "three-param function: all named args, out-of-order" {
  assertEqualInt(tri(z = 10, x = 1, y = 5), 16, "1+5+10=16 out-of-order named")
}

test "two-arg add: named in declaration order" {
  assertEqualInt(addTwo(a = 3, b = 7), 10, "named in order: 3+7=10")
}

test "two-arg add: named in reverse order" {
  assertEqualInt(addTwo(b = 7, a = 3), 10, "named reversed: 3+7=10")
}
