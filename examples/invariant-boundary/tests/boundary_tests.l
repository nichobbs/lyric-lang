//! Public-boundary and `inout` invariant re-checks (#7222).
@test_module
package Inv.BoundaryTests

import Std.Core
import Std.Testing
import Inv.Types
import Inv.Api

test "a valid value crosses every boundary" {
  var c = newCounter(3)
  assertEqualInt(readCount(c), 3, "in parameter")
  assertEqualInt(untouched(c), 3, "inout parameter left valid")
}

test "a public function taking a broken value panics before its body" {
  val c = newCounter(1)
  c.count = -1
  assertPanicsWith("in parameter", "InvariantViolated: Inv.Types.Counter", { -> val _ = readCount(c) })
}

test "a public function returning a broken value panics" {
  assertPanicsWith("result", "InvariantViolated: Inv.Types.Counter", { -> val _ = makeBroken() })
}

test "an inout parameter written to a broken value panics on exit" {
  var c = newCounter(1)
  assertPanicsWith("inout", "InvariantViolated: Inv.Types.Counter invariant count >= 0", { -> breakInPlace(c) })
}

test "an inout parameter of the declaring package's own type is re-checked on exit" {
  var c = newCounter(1)
  assertPanicsWith("local inout", "InvariantViolated: Inv.Types.Counter invariant count >= 0", { -> breakLocal(c) })
}

test "a generic invariant type crosses every boundary when valid" {
  val c = newCell(3, "a")
  assertEqualInt(readCell(c), 3, "generic in parameter")
}

test "a public function taking a broken generic value panics before its body" {
  val c = newCell(1, "a")
  c.n = -1
  assertPanicsWith("generic in parameter", "InvariantViolated: Inv.Types.Cell", { -> val _ = readCell(c) })
}

test "a public function returning a broken generic value panics" {
  assertPanicsWith("generic result", "InvariantViolated: Inv.Types.Cell", { -> val _ = makeBrokenCell() })
}

test "an inout generic parameter written to a broken value panics on exit" {
  var c = newCell(1, "a")
  assertPanicsWith("generic inout", "InvariantViolated: Inv.Types.Cell invariant n >= 0", { -> breakCell(c) })
}
