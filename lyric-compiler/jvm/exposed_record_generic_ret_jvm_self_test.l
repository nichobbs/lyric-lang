//! exposed_record_generic_ret_jvm_self_test.l — JVM-only regression test for
//! #6528: a same-file function whose return type is a GENERIC `exposed
//! record` declared LATER in the file.
//!
//! `collectFileSigsSeeded`'s `localRecordNames` pre-scan (in
//! `lyric-compiler/jvm/codegen/06_items.l`) only matched `IRecord`, not
//! `IExposedRec`, so `recordRetClassOf` couldn't recover a same-file
//! generic `exposed record`'s raw class regardless of declaration order —
//! that pre-scan exists specifically to let a function be declared BEFORE
//! the record it returns.  The failure surfaced as `NoClassDefFoundError`
//! against an unrelated, wrong class rather than resolving the real one.
//!
//! JVM-only: the identical repro shape hits a SEPARATE, pre-existing,
//! unrelated MSIL bug (generic `exposed record` fails to *load* at runtime
//! on `--target dotnet` with `System.TypeLoadException`, #6529), so this
//! file is wired into CI with `--target jvm` only, following the
//! established `*_jvm_self_test.l` convention (e.g. `generic_jvm_self_test.l`,
//! `record_method_jvm_self_test.l`) rather than the dual-target
//! `*_self_test.l` convention.
@test_module
package Lyric.ExposedRecordGenericRetJvmSelfTest

import Std.Testing

func makeGenericBox(v: in Int): GenericBox[Int] {
  GenericBox(value = v)
}

exposed record GenericBox[T] {
  value: T
}

test "exposed record generic return type resolves regardless of declaration order (#6528)" {
  val b = makeGenericBox(7)
  assertEqualInt(b.value, 7, "same-file function returning a later-declared generic exposed record resolves correctly")
}
