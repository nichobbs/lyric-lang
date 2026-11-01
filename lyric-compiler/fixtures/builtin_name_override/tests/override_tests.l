//! #7508 cross-package case: `OverrideLib` declares `newList` and `mapGet`
//! and this package imports them, so the bare calls below must reach
//! `OverrideLib`, not the builtin intrinsics.  `newMap` is not overridden and
//! must still lower to the intrinsic in the same file.
@test_module
package OverrideTests

import Std.Core
import Std.Testing
import Std.Collections.{Map, newMap}
import OverrideLib
import OverrideLib.{newList}

test "an imported package's newList overrides the builtin intrinsic" {
  assertEqualInt(newList(3), 3000, "OverrideLib.newList(3)")
}

test "an imported package's different-arity mapGet type-checks and lowers" {
  assertEqualInt(OverrideLib.mapGet(4, 2), 402, "OverrideLib.mapGet(4, 2)")
}

test "a bare Std.Collections call in the same file still uses the intrinsic" {
  val m: Map[String, Int] = newMap()
  m.add("a", 10)
  assertTrue(m.containsKey("a"), "newMap() builds a real, usable map")
  assertEqualInt(m.count, 1, "the intrinsic map holds the entry")
}
