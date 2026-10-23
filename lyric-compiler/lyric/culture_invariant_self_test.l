//! culture_invariant_self_test.l — stringification does not depend on the host
//! locale (#7911).  Every assertion holds on both targets in any process
//! culture; `scripts/ci/println-stringify-e2e.sh` runs this module on
//! `--target dotnet` under `de_DE` (decimal comma) and `sv_SE` (U+2212 minus
//! sign), where interpolation, `+`, `+=`, `.toString()`, `toString(x)`,
//! `format1`, negative integers and a generic payload used to follow the
//! locale.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/culture_invariant_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/culture_invariant_self_test.l
@test_module
package Lyric.CultureInvariantSelfTest

import Std.Core
import Std.Collections
import Std.Testing

record Reading {
  value: Double
  delta: Int
}

record Box[T] {
  v: T
}

func render[T](x: in T): String = toString(x)

func interpolated(d: in Double): String = "v=${d}"

test "Double interpolation uses a decimal point" {
  assertEqual(interpolated(1.5), "v=1.5", "interpolation")
  val d = 2.25
  assertEqual("" + d, "2.25", "String +")
  var s = "x"
  s += d
  assertEqual(s, "x2.25", "String +=")
  assertEqual(d.toString(), "2.25", "toString method")
  assertEqual(toString(d), "2.25", "toString function")
  assertEqual(format1("{0}", d), "2.25", "format1")
}

test "negative integers use an ASCII hyphen" {
  val n = -5
  val big = -9000000000i64
  assertEqual(toString(n), "-5", "toString Int")
  assertEqual(n.toString(), "-5", "method Int")
  assertEqual("${n}", "-5", "interpolation Int")
  assertEqual("" + n, "-5", "String + Int")
  assertEqual(toString(big), "-9000000000", "toString Long")
  assertEqual(big.toString(), "-9000000000", "method Long")
  assertEqual("${big}", "-9000000000", "interpolation Long")
}

test "a generic payload stringifies invariantly" {
  assertEqual(render(1.5), "1.5", "T = Double")
  assertEqual(render(-7), "-7", "T = Int")
  assertEqual(render(-70000000000i64), "-70000000000", "T = Long")
  val b: Box[Double] = Box(v = 0.5)
  assertEqual(render(b.v), "0.5", "a field of a generic record")
}

test "records read back through their fields" {
  val r = Reading(value = -3.75, delta = -2)
  assertEqual("${r.value}/${r.delta}", "-3.75/-2", "interpolated fields")
}
