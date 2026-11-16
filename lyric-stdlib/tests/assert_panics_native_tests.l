//! Std.Testing.assertPanics and assertPanicsWith on `--target native` (D608).
//!
//! Native cannot unwind (D-N-003), so the body runs in a forked child and the
//! parent reads how it ended. These cases pin the contract shared with the
//! managed targets (a panic passes, a normal return fails with the message, the
//! test run continues) and the two ways native differs: the body's in-memory
//! effects stay in the child, and a body that ends the process some other way
//! is reported as such rather than as a panic.
//!
//!   lyric test --target native lyric-stdlib/tests/assert_panics_native_tests.l
@test_module
@runtime_checked
package Std.Testing.AssertPanicsNativeTests

import Std.Core
import Std.Collections
import Std.Environment
import Std.Testing

func needsPositive(x: in Int): Int
  requires: x > 0
{
  x
}

func allocateThenPanic(n: in Int): Unit {
  val items: List[String] = newList()
  var i = 0
  while i < n {
    items.add("item-" + toString(i))
    i = i + 1
  }
  panic("after " + toString(items.count) + " allocations")
}

test "a body that panics passes" {
  assertPanics("panic", { -> panic("boom") })
}

test "a body that returns normally fails with the managed message" {
  assertPanicsWith(
    "the failure of the inner assertion",
    "assertPanics 'returns' failed: function returned normally, expected a panic",
    { -> assertPanics("returns", { -> () }) }
  )
}

test "assertPanicsWith sees the panic message" {
  assertPanicsWith("message", "unique-marker-7", { -> panic("unique-marker-7 inside") })
  assertPanicsWith(
    "a wrong substring fails",
    "did not contain expected substring",
    { -> assertPanicsWith("inner", "not-there", { -> panic("something else") }) }
  )
}

test "a panic after allocating reference-counted data leaves the parent intact" {
  val before: List[String] = newList()
  before.add("kept")
  assertPanicsWith("allocate then panic", "after 500 allocations", { -> allocateThenPanic(500) })
  assertEqualInt(before.count, 1, "the parent's list is untouched")
  assertEqual(before[0], "kept", "the parent's string is untouched")
}

test "a test continues after a trapped panic, repeatedly" {
  var i = 0
  while i < 20 {
    assertPanics("loop", { -> panic("again") })
    i = i + 1
  }
  assertEqualInt(i, 20, "all twenty trapped panics returned to the loop")
}

test "assertPanics nests" {
  assertPanics(
    "outer passes when its body ends in a panic",
    { -> assertPanics("inner", { -> panic("deep") }); panic("after inner") }
  )
  assertPanicsWith(
    "outer sees the inner failure",
    "function returned normally",
    { -> assertPanics("inner", { -> () }) }
  )
}

test "a contract violation is a panic" {
  assertEqualInt(needsPositive(3), 3, "a satisfied precondition returns")
  assertPanics("requires: x > 0", { -> val _ = needsPositive(0) })
}

test "the body's in-memory effects stay in the child (native differs from the managed targets)" {
  val touched: List[Int] = newList()
  assertPanics("add then panic", { -> touched.add(1); panic("after adding") })
  assertEqualInt(touched.count, 0, "the list was filled in the forked child")
}

test "a body that ends the process is reported, not taken for a panic" {
  assertPanicsWith("exit", "exit status 3 instead of panicking", { -> assertPanics("exits", { -> exitCode(3) }) })
}
