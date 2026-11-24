//! numeric.l - numeric conversions and bitwise methods lowered from TIR (docs/70 phase 4a, D532):
//! `toFloat`, `toDouble`, `toInt`, `toLong`, `toByte`, `toUInt`, `toULong`, the checked `toNat` and
//! `toChar`, a `Float` receiver, and `.and/.or/.xor/.shl/.shr` on the signed and unsigned widths.
//! `native-via-tir-e2e.sh` runs it both ways and under AddressSanitizer.
package NumericViaTir

import Std.Core
import Std.Console as Console

func floats(i: in Int, l: in Long, b: in Byte, d: in Double): Double {
  val f: Float = i.toFloat()
  val g: Float = d.toFloat()
  val h: Float = l.toFloat()
  val k: Float = b.toFloat()
  f.toDouble() + g.toDouble() + h.toDouble() + k.toDouble() + b.toDouble()
}

func narrowing(d: in Double, f: in Float): Int {
  val a: Int = d.toInt()
  val b: Long = d.toLong()
  val c: Byte = d.toByte()
  val e: Int = f.toInt()
  a + b.toInt() + c.toInt() + e
}

func unsignedWidths(b: in Byte, u: in UInt): Long {
  val a: UInt = b.toUInt()
  val w: ULong = b.toULong()
  val x: ULong = u.toULong()
  a.toLong() + b.toLong() + u.toLong() + w.toInt().toLong() + x.toInt().toLong()
}

func nats(i: in Int, l: in Long, d: in Double): Long {
  i.toNat().toLong() + l.toNat().toLong() + d.toNat().toLong()
}

func chars(i: in Int, l: in Long, d: in Double): Int {
  val a: Char = i.toChar()
  val b: Char = l.toChar()
  val c: Char = d.toChar()
  a.toInt() + b.toInt() + c.toInt()
}

func bits(i: in Int, l: in Long, b: in Byte, u: in UInt, w: in ULong): Long {
  val a: Int = i.and(12).or(3).xor(5).shl(2).shr(1)
  val c: Long = l.and(255i64).shl(4).shr(2)
  val d: Byte = b.shl(1).shr(2)
  val e: UInt = u.shr(1)
  val f: ULong = w.shr(1)
  a.toLong() + c + d.toLong() + e.toLong() + f.toInt().toLong()
}

func negShift(i: in Int): Int {
  i.shr(1)
}

func main(): Unit {
  println(toString(floats(7, 100000000000, 250u8, 2.75)))
  println(toString(narrowing(-3.9, 5.5)))
  println(toString(unsignedWidths(200u8, 3000000000u32)))
  println(toString(nats(3, 4, 5.9)))
  println(toString(chars(65, 66, 67.5)))
  println(toString(bits(1234, 98765, 90u8, 4000000000u32, 9000000000000000000u64)))
  println(toString(negShift(-16)))
}
