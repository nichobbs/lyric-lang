@test_module
package WindowsSmokeTests

import Std.Testing

test "arithmetic" {
  assertEqualInt(1 + 1, 2, "one plus one")
}

test "strings" {
  assertEqual("ab" + "c", "abc", "concatenation")
}
