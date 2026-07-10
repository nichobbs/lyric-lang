//! byte_arithmetic_self_test.l — self-test for unsigned Byte division and modulo operations
//! Covers both standard arithmetic and all compound-assignment paths.
@test_module
package Lyric.ByteArithmeticSelfTest

import Std.Core
import Std.Collections
import Std.Testing

test "Byte unsigned division and modulo" {
  val x: Byte = 200.toByte()
  val y: Byte = 3.toByte()

  // 200 / 3 == 66 (unsigned; signed idiv would yield -18)
  val divRes: Byte = x / y
  assertEqualInt(divRes.toInt(), 66, "200 / 3 == 66")

  // 200 % 3 == 2 (unsigned; signed irem would yield -2)
  val modRes: Byte = x % y
  assertEqualInt(modRes.toInt(), 2, "200 % 3 == 2")
}

test "Byte compound assignments on local variables" {
  var x: Byte = 200.toByte()
  val y: Byte = 3.toByte()

  x /= y
  assertEqualInt(x.toInt(), 66, "200 /= 3 gives 66")

  var x2: Byte = 200.toByte()
  x2 %= y
  assertEqualInt(x2.toInt(), 2, "200 %= 3 gives 2")
}

test "Byte compound assignments on list elements" {
  val arr: List[Byte] = newList()
  arr.add(200.toByte())
  val y: Byte = 3.toByte()

  arr[0] /= y
  val d0: Byte = arr[0]
  assertEqualInt(d0.toInt(), 66, "arr[0] /= 3 gives 66")

  arr[0] = 200.toByte()
  arr[0] %= y
  val d1: Byte = arr[0]
  assertEqualInt(d1.toInt(), 2, "arr[0] %= 3 gives 2")
}

record ByteRecord {
  var value: Byte
}

test "Byte compound assignments on record fields" {
  val r = ByteRecord(value = 200.toByte())
  val y: Byte = 3.toByte()

  r.value /= y
  assertEqualInt(r.value.toInt(), 66, "r.value /= 3 gives 66")

  r.value = 200.toByte()
  r.value %= y
  assertEqualInt(r.value.toInt(), 2, "r.value %= 3 gives 2")
}

test "Byte compound assignments on hoisted closure variables" {
  var x: Byte = 200.toByte()
  val y: Byte = 3.toByte()

  // Creating a closure hoists 'x'.  The assertion reads the captured var
  // AFTER the call rather than binding the closure's (erased-object) return
  // to a primitive-annotated local: that bind shape skips the unbox on MSIL —
  // a separate pre-existing gap, not the Byte semantics under test here.
  val dummyFunc = { -> x /= y; 0 }

  dummyFunc()
  assertEqualInt(x.toInt(), 66, "hoisted x /= 3 updates the captured var to 66")

  var x2: Byte = 200.toByte()

  // Creating a second closure hoists 'x2'
  val dummyFunc2 = { -> x2 %= y; 0 }

  dummyFunc2()
  assertEqualInt(x2.toInt(), 2, "hoisted x2 %= 3 updates the captured var to 2")
}

// ─────────────────────────────────────────────────────────────────────────────
// Values >= 128: the canonical Byte representation is unsigned 0..255 on both
// targets (MSIL `conv.u1`; JVM masked-unsigned in-slot, docs/59 §4.3).  These
// cases pin equality, ordering, wraparound, and boxing round-trips where a
// signed JVM `byte` (-56 for 200) diverged from MSIL before canonicalization.
// ─────────────────────────────────────────────────────────────────────────────
// Declared Option[Byte] return, so the match bind recovers a real Byte payload.
func mkByteOpt(b: in Byte): Option[Byte] {
  Some(value = b)
}

func firstSliceByte(bs: slice[Byte]): Byte {
  bs[0]
}

test "Byte >= 128 round-trips through List[Byte]" {
  val xs: List[Byte] = newList()
  xs.add(200.toByte())
  xs.add(255.toByte())
  val b: Byte = 200.toByte()
  // Equality both ways: the boxed element against the primitive local.
  assertTrue(xs[0] == b, "xs[0] == b for 200")
  assertTrue(b == xs[0], "b == xs[0] for 200")
  val b0: Byte = xs[0]
  val b1: Byte = xs[1]
  assertEqualInt(b0.toInt(), 200, "List element reads back as 200, not -56")
  assertEqualInt(b1.toInt(), 255, "List element reads back as 255, not -1")
}

test "Byte >= 128 round-trips through slice[Byte]" {
  val bs: slice[Byte] = [200.toByte(), 100.toByte()]
  val f = firstSliceByte(bs)
  assertEqualInt(f.toInt(), 200, "slice element crosses a call boundary as 200")
}

test "Byte ordering is unsigned above 127" {
  val hi: Byte = 200.toByte()
  val lo: Byte = 100.toByte()
  assertTrue(hi > lo, "200 > 100 (signed compare would say -56 < 100)")
  assertTrue(lo < hi, "100 < 200")
  assertTrue(hi >= hi, "200 >= 200")
  assertTrue(not (hi < lo), "not (200 < 100)")
}

test "Byte arithmetic wraps unsigned" {
  var b: Byte = 200.toByte()
  b += 100.toByte()
  assertEqualInt(b.toInt(), 44, "200 + 100 wraps to 44")
  var m: Byte = 200.toByte()
  m *= 2.toByte()
  assertEqualInt(m.toInt(), 144, "200 * 2 wraps to 144")
  var s: Byte = 10.toByte()
  s -= 20.toByte()
  assertEqualInt(s.toInt(), 246, "10 - 20 wraps to 246")
}

test "Byte >= 128 round-trips through boxing (Option payload)" {
  val ob = mkByteOpt(200.toByte())
  var got = 0
  match ob {
    case Some(bv) -> {
      got = bv.toInt()
    }
    case None -> ()
  }
  assertEqualInt(got, 200, "boxed Byte payload unboxes to 200")
}

test "Byte >= 128 renders as its unsigned value" {
  val b: Byte = 200.toByte()
  assertEqual("v=" + b.toString(), "v=200", "Byte 200 stringifies as 200")
}
