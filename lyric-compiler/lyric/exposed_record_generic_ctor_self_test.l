//! exposed_record_generic_ctor_self_test.l — regression test for #6529: a
//! generic `exposed record`'s constructor and field read must route through
//! the same in-bundle generic (VAR/GENERICINST) path as a plain generic
//! `record`, not fall back to a plain (non-generic) TypeDef reference that
//! the CLR loader rejects with `System.TypeLoadException`.
@test_module
package Lyric.ExposedRecordGenericCtorSelfTest

import Std.Testing

func makeBox(v: Int): Box[Int] {
  Box(value = v)
}

exposed record Box[T] {
  value: T
}

test "generic exposed record construction and field read work on --target dotnet (#6529)" {
  val b = makeBox(7)
  assertEqualInt(b.value, 7, "generic exposed record field reads back the constructed value")
}
