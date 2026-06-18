//! Named-argument record construction must store each value into its own field
//! regardless of call-site argument order (D-progress-357).
@test_module
package Lyric.NamedArgOrderSelfTest

import Std.Core
import Std.Testing

record R3 {
  a: String
  b: Option[String]
  c: Bool
  // A wider record mixing List / Option / Bool / Int fields, to exercise
  // reordering across heterogeneous field types.
}

record Wide {
  name: String
  flag: Bool
  opt: Option[String]
  count: Int
  label: String
}

test "named args in declaration order" {
  val r = R3(a = "A", b = Some(value = "B"), c = true)
  assertEqual(r.a, "A", "a")
  assertTrue(r.c, "c")
  match r.b {
    case None -> assertTrue(false, "b should be Some")
    case Some(v) -> assertEqual(v, "B", "b value")
  }
}

test "named args in reverse order land in the right fields" {
  val r = R3(c = true, b = Some(value = "B"), a = "A")
  assertEqual(r.a, "A", "a (reverse-order)")
  assertTrue(r.c, "c (reverse-order)")
  match r.b {
    case None -> assertTrue(false, "b should be Some (reverse-order)")
    case Some(v) -> assertEqual(v, "B", "b value (reverse-order)")
  }
}

test "named args in scrambled order across heterogeneous fields" {
  val w = Wide(count = 7, label = "L", name = "N", opt = Some(value = "O"), flag = true)
  assertEqual(w.name, "N", "name")
  assertTrue(w.flag, "flag")
  assertEqualInt(w.count, 7, "count")
  assertEqual(w.label, "L", "label")
  match w.opt {
    case None -> assertTrue(false, "opt should be Some")
    case Some(v) -> assertEqual(v, "O", "opt value")
  }
}

test "scrambled order with primitive and string fields round-trips" {
  // No Option payload here — isolates the reorder from the separate
  // None-as-field-value defect (#1731).
  val w = Wide(label = "L2", count = 9, flag = true, name = "N2", opt = Some(value = "x"))
  assertEqual(w.name, "N2", "name")
  assertEqual(w.label, "L2", "label")
  assertEqualInt(w.count, 9, "count")
  assertTrue(w.flag, "flag")
}
