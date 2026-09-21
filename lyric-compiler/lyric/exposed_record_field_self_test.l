//! exposed_record_field_self_test.l — regression test for `exposed record`
//! construction, field reads, and compound-assignment writes on the JVM
//! backend (#6526).
//!
//! `IExposedRec` was missing from four of the JVM backend's core item
//! "collect" pre-passes (`collectFileSigsSeeded`, `collectFileCasesExtern`,
//! `collectFileDeclaredTypeFqns`, `collectFileCtors` in
//! `lyric-compiler/jvm/codegen/06_items.l`) even though `lowerRecord`
//! itself already emitted a correct class for `exposed record` — the class
//! was right, but nothing that CONSTRUCTS or READS/WRITES it could find its
//! registered shape. This left `exposed record` fundamentally non-functional
//! on `--target jvm`: construction failed at runtime with
//! `NoSuchMethodError` (the ctor was never registered, so a call site
//! resolved the bogus `()Object`-guess descriptor instead of the real
//! `<init>`), and any numeric field's compound-assignment (`h.value += v`)
//! panicked at compile time (`emitCompoundCombineJvm`'s erased-reference-
//! target guard, since `recordFieldType` fell back to `java.lang.Object`
//! for every unregistered field). Plain assignment and reads silently
//! erased to `Object` too, though those degrade less loudly. MSIL was
//! unaffected — `exposed record` worked correctly there throughout.
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed; run via
//! native `lyric test` on both `--target dotnet` (control — already worked)
//! and `--target jvm` (the fix).
@test_module
package Lyric.ExposedRecordFieldSelfTest

import Std.Testing

exposed record Holder {
  var value: Int
  label: String
}

test "exposed record constructs and reads back correctly" {
  val h = Holder(value = 42, label = "answer")
  assertEqualInt(h.value, 42, "constructed field reads back as 42")
  assertEqual(h.label, "answer", "constructed String field reads back correctly")
}

test "exposed record numeric field plain assignment" {
  var h = Holder(value = 1, label = "x")
  h.value = 99
  assertEqualInt(h.value, 99, "plain assignment overwrites the field")
}

test "exposed record numeric field compound assignment" {
  var h = Holder(value = 5, label = "x")
  h.value += 3
  assertEqualInt(h.value, 8, "h.value += 3 on 5 gives 8")

  h.value *= 2
  assertEqualInt(h.value, 16, "h.value *= 2 on 8 gives 16")

  h.value -= 20
  assertEqualInt(h.value, -4, "h.value -= 20 on 16 gives -4")
}

exposed record ByteHolder {
  var value: Byte
}

// #5520's record-field fix (MSIL) plus #6526's registration fix (JVM)
// together: an exposed record's Byte field wraps unsigned on overflow on
// BOTH targets.
test "exposed record Byte field compound assignment wraps unsigned" {
  var h = ByteHolder(value = 200.toByte())
  h.value += 100.toByte()
  assertEqualInt(h.value.toInt(), 44, "h.value += 100 on 200 wraps unsigned to 44, not 300")
}

// #6533 follow-up audit (MSIL only): `Msil.Codegen.liftLambdasMsil`'s
// `IRecord` match arm (which BFS-collects lambda literals from a record's
// body methods so each gets a lifted synthetic IFunc token) had no
// `IExposedRec` sibling, even though `exposed record` wraps the identical
// `RecordDecl` shape. A lambda literal inside an `exposed record` body
// method compiled clean but panicked at codegen time ("lambda token
// missing ... liftLambdasMsil pre-pass was not run").
exposed record Adder {
  base: Int

  func addOne(self: in Adder): Int {
    val inc = { x: Int -> x + 1 }
    inc(self.base)
  }
}

test "exposed record body method containing a lambda literal lowers correctly (#6533 follow-up)" {
  val a = Adder(base = 10)
  assertEqualInt(a.addOne(), 11, "lambda literal inside an exposed-record body method executes correctly")
}

// #6533 follow-up audit (MSIL only): `Msil.Codegen.allReferencedNamesMsil`'s
// `IRecord` match arm (which collects bare module-level names referenced
// from a record's field default-value initializers, so each gets a
// synthesized value thunk) had the same missing `IExposedRec` sibling.
val exposedDefaultBase: Int = 42

exposed record WithDefault {
  count: Int = exposedDefaultBase
}

test "exposed record field default referencing a bare module-level val resolves correctly (#6533 follow-up)" {
  val w = WithDefault()
  assertEqualInt(w.count, 42, "default-value bare-name reference resolves to the module-level val")
}
