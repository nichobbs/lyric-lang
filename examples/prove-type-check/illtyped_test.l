//! A test body with a type error (#8308): the type checker checks the body
//! itself, so `lyric prove` and `lyric build` reject it as `lyric test` does.
@test_module
package IllTypedTest

import Std.Testing

func double(x: in Int): Int {
  x * 2
}

test "double of a string" {
  assertEqualInt(double("x"), 4, "double")
}
