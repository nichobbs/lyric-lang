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

  // #6525 review: exercises the SELF-FIELD compound-write codegen arm
  // (`lowerAssignExprMsil`'s `selfAssignFieldKey` path) distinctly from
  // the general `recv.value += v` arm the tests above cover.
  func bump(v: in Byte): Unit {
    self.value += v
  }
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

// #5520: `/=`/`%=` above never leave the 0..255 range, so they never
// exercised the field's actual MSIL storage type — only `+=`/`*=` overflow
// it.  The field's MSIL storage stayed int32-backed and never re-narrowed a
// compound-store result (`h.value += 100.toByte()` on 200 kept 300 instead
// of wrapping to 44), diverging from the JVM's real byte field.  Fixed via
// `CodegenCtx.byteFields` (mirrors `FuncCtx.byteSlots` for locals).
//
// D163: plain `+=`/`*=`/`-=` panic on overflow in a debug build, so the
// in-range compound forms (operands > 127) check the unsigned representation
// and the explicit `wrapping*` methods check the 8-bit truncation.
test "Byte compound assignments on record fields stay unsigned, wrapping methods wrap (#5520)" {
  val r = ByteRecord(value = 200.toByte())
  r.value += 50.toByte()
  assertEqualInt(r.value.toInt(), 250, "r.value += 50 on 200 stays unsigned at 250")
  r.value = r.value.wrappingAdd(100.toByte())
  assertEqualInt(r.value.toInt(), 94, "r.value wrappingAdd 100 on 250 wraps unsigned to 94, not 350")

  val r2 = ByteRecord(value = 100.toByte())
  r2.value *= 2.toByte()
  assertEqualInt(r2.value.toInt(), 200, "r2.value *= 2 on 100 stays unsigned at 200")
  r2.value = r2.value.wrappingMul(3.toByte())
  assertEqualInt(r2.value.toInt(), 88, "r2.value wrappingMul 3 on 200 wraps unsigned to 88, not 600")

  val r3 = ByteRecord(value = 250.toByte())
  r3.value -= 200.toByte()
  assertEqualInt(r3.value.toInt(), 50, "r3.value -= 200 on 250 gives 50")
  r3.value = r3.value.wrappingSub(100.toByte())
  assertEqualInt(r3.value.toInt(), 206, "r3.value wrappingSub 100 on 50 wraps unsigned to 206, not -50")

  val r4 = ByteRecord(value = 200.toByte())
  r4.bump(50.toByte())
  assertEqualInt(r4.value.toInt(), 250, "self.value += v inside a record method stays unsigned at 250")
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

// #5520: `/=`/`%=` above never leave the 0..255 range, so they never
// exercised the hoisted cell's actual MSIL storage type — only `+=`/`*=`
// overflow it.  A hoisted Byte cell's MSIL closure-environment field stayed
// int32-backed and never re-narrowed a compound-store result (`x += 100` on
// 200 kept 300 instead of wrapping to 44), diverging from the JVM's real
// byte field. Fixed by making scalar `Byte`'s MSIL ABI genuinely U1
// end-to-end (`typeExprToMsilCtx`'s `TRef("Byte")` arm), so the existing
// hoisted-cell array-element-type selection (`finishHoistedCellMsil`) picks
// up the real `MByte` it always branched on rather than never receiving.
//
// D163: plain compound operators panic on overflow in a debug build, so the
// in-range forms check the unsigned representation and the `wrapping*`
// methods (assigned through the hoisted cell) check the truncation.
test "Byte compound assignments on hoisted closure variables stay unsigned, wrapping methods wrap (#5520)" {
  var x: Byte = 200.toByte()
  val dummyAdd = { -> x += 50.toByte(); 0 }
  dummyAdd()
  assertEqualInt(x.toInt(), 250, "hoisted x += 50 on 200 stays unsigned at 250")
  val dummyWrapAdd = { -> x = x.wrappingAdd(100.toByte()); 0 }
  dummyWrapAdd()
  assertEqualInt(x.toInt(), 94, "hoisted x wrappingAdd 100 on 250 wraps unsigned to 94, not 350")

  var x2: Byte = 100.toByte()
  val dummyMul = { -> x2 *= 2.toByte(); 0 }
  dummyMul()
  assertEqualInt(x2.toInt(), 200, "hoisted x2 *= 2 on 100 stays unsigned at 200")
  val dummyWrapMul = { -> x2 = x2.wrappingMul(3.toByte()); 0 }
  dummyWrapMul()
  assertEqualInt(x2.toInt(), 88, "hoisted x2 wrappingMul 3 on 200 wraps unsigned to 88, not 600")

  var x3: Byte = 250.toByte()
  val dummySub = { -> x3 -= 200.toByte(); 0 }
  dummySub()
  assertEqualInt(x3.toInt(), 50, "hoisted x3 -= 200 on 250 gives 50")
  val dummyWrapSub = { -> x3 = x3.wrappingSub(100.toByte()); 0 }
  dummyWrapSub()
  assertEqualInt(x3.toInt(), 206, "hoisted x3 wrappingSub 100 on 50 wraps unsigned to 206, not -50")

  // A plain (non-compound) store through the hoisted cell must also carry
  // the real value, not an unwrapped int32 remnant of an earlier compound op.
  var x4: Byte = 200.toByte()
  val dummyStore = { -> x4 = 44.toByte(); 0 }
  dummyStore()
  assertEqualInt(x4.toInt(), 44, "hoisted x4 = 44 stores the real Byte value")
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

// D163: plain operators panic on overflow in a debug build; the in-range
// forms pin the unsigned representation and `wrapping*` pins the wraparound.
test "Byte arithmetic stays unsigned, wrapping methods wrap" {
  var b: Byte = 200.toByte()
  b += 50.toByte()
  assertEqualInt(b.toInt(), 250, "200 + 50 == 250")
  assertEqualInt(b.wrappingAdd(100.toByte()).toInt(), 94, "250 wrappingAdd 100 wraps to 94")
  var m: Byte = 100.toByte()
  m *= 2.toByte()
  assertEqualInt(m.toInt(), 200, "100 * 2 == 200")
  assertEqualInt(m.wrappingMul(2.toByte()).toInt(), 144, "200 wrappingMul 2 wraps to 144")
  var s: Byte = 250.toByte()
  s -= 200.toByte()
  assertEqualInt(s.toInt(), 50, "250 - 200 == 50")
  assertEqualInt(s.wrappingSub(60.toByte()).toInt(), 246, "50 wrappingSub 60 wraps to 246")
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

// ── Hoisted Byte closure cell, ESCAPING closure, wraps on overflow (#6524) ────
// D163: plain `+=`/`*=`/`-=` panic on overflow in a debug build, so the
// escaping closures below use the explicit `wrapping*` methods to overflow.
// The existing "hoisted closure variables wrap on overflow" test above (#5520)
// only covers a closure that stays in the SAME function's scope (called
// directly, never returned out) — a comment on that test explicitly calls out
// this narrower shape. #6524 tracked whether a hoisted Byte cell shared by
// TWO closures that both ESCAPE their declaring function (via a returned
// record — the exact shape a real callback-pair/observer idiom uses) still
// wraps correctly on overflow: the cell must be heap-allocated (the
// declaring function's stack frame is gone by the time either closure runs),
// which is a different codegen path than a non-escaping closure's cell.
record BytePair6524 {
  setter: () -> Unit
  getter: () -> Int
}

func makeByteAdder6524(): BytePair6524 {
  var b: Byte = 200.toByte()
  BytePair6524(setter = { -> b = b.wrappingAdd(100.toByte()) }, getter = { -> b.toInt() })
}

func makeByteMul6524(): BytePair6524 {
  var b: Byte = 100.toByte()
  BytePair6524(setter = { -> b = b.wrappingMul(3.toByte()) }, getter = { -> b.toInt() })
}

func makeByteSub6524(): BytePair6524 {
  var b: Byte = 10.toByte()
  BytePair6524(setter = { -> b = b.wrappingSub(20.toByte()) }, getter = { -> b.toInt() })
}

test "hoisted Byte cell shared by an escaping closure pair wrapping add wraps (#6524)" {
  val p = makeByteAdder6524()
  val doSet = p.setter
  val doGet = p.getter
  doSet()
  assertEqualInt(doGet(), 44, "escaping-closure hoisted b wrappingAdd 100 on 200 wraps unsigned to 44, not 300")
}

test "hoisted Byte cell shared by an escaping closure pair wrapping mul wraps (#6524)" {
  val p = makeByteMul6524()
  val doSet = p.setter
  val doGet = p.getter
  doSet()
  assertEqualInt(doGet(), 44, "escaping-closure hoisted b wrappingMul 3 on 100 wraps unsigned to 44, not 300")
}

test "hoisted Byte cell shared by an escaping closure pair wrapping sub wraps (#6524)" {
  val p = makeByteSub6524()
  val doSet = p.setter
  val doGet = p.getter
  doSet()
  assertEqualInt(doGet(), 246, "escaping-closure hoisted b wrappingSub 20 on 10 wraps unsigned to 246, not -10")
}

test "hoisted Byte cell shared by an escaping closure pair: repeated get/set stays correct (#6524)" {
  val p = makeByteAdder6524()
  val doSet = p.setter
  val doGet = p.getter
  assertEqualInt(doGet(), 200, "getter before any setter call reads the initial value")
  doSet()
  assertEqualInt(doGet(), 44, "first setter call wraps 200+100 to 44")
  doSet()
  assertEqualInt(doGet(), 144, "second setter call adds 100 to 44 -> 144, no overflow")
}
