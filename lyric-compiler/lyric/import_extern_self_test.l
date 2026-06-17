@test_module
package Lyric.ImportExternSelfTest

import Std.Core
import Std.Testing
import extern System.{ Math as SystemMath }

test "Math.Max binds the int overload via import extern" {
  assertEqualInt(SystemMath.Max(2, 5), 5, "Max(2,5)")
  assertEqualInt(SystemMath.Max(10, 3), 10, "Max(10,3)")
}

test "Math.Min binds the int overload via import extern" {
  assertEqualInt(SystemMath.Min(10, 3), 3, "Min(10,3)")
  assertEqualInt(SystemMath.Min(2, 5), 2, "Min(2,5)")
}

test "Math.Abs binds the int overload via import extern" {
  assertEqualInt(SystemMath.Abs(-7), 7, "Abs(-7)")
  assertEqualInt(SystemMath.Abs(42), 42, "Abs(42)")
}
