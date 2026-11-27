//! wrapping.l - `List.set`, the wrapping integer methods and `default()` lowered from TIR (docs/70 phase 4a
//! part 8, D855): `set` is one kernel call, `wrappingAdd`/`wrappingSub`/`wrappingMul`/`wrappingNeg` are the plain
//! two's complement operations whatever the overflow checks, `default()` is the zero value of its expected type.
//! `native-via-tir-e2e.sh` runs it both ways.
package WrappingViaTir

import Std.Core
import Std.Collections
import Std.Console as Console

func bump(xs: in List[Int], i: in Int, v: in Int): Int {
  xs.set(i, v)
  xs[i]
}

func wrap(a: in Int, b: in Int): Int {
  a.wrappingAdd(b)
}

func wrapMul(a: in Long, b: in Long): Long {
  a.wrappingMul(b)
}

func wrapNeg(a: in Int): Int {
  a.wrappingNeg()
}

func zero(): Int {
  val z: Int = default()
  z
}

func wrapSub(a: in Int, b: in Int): Int {
  a.wrappingSub(b)
}

func wrapByte(a: in Byte, b: in Byte): Int {
  a.wrappingAdd(b).toInt()
}

func nameAt(xs: in List[String], i: in Int, v: in String): String {
  xs.set(i, v)
  xs[i]
}

func uintBig(u: in UInt): Bool {
  u.toDouble() > 3000000000.0
}

func main(): Unit {
  val xs: List[Int] = newList()
  xs.add(1)
  xs.add(2)
  println(toString(bump(xs, 1, 9)))
  println(toString(xs[0] + xs[1]))
  println(toString(wrap(2147483647, 1)))
  println(toString(wrapMul(9223372036854775807i64, 2i64)))
  println(toString(wrapNeg(0 - 2147483647 - 1)))
  println(toString(zero()))
  println(toString(wrapSub(0 - 2147483647 - 1, 1)))
  println(toString(wrapByte(250.toByte(), 100.toByte())))
  val names: List[String] = newList()
  names.add("a")
  names.add("b")
  println(nameAt(names, 0, "x" + "y"))
  println(names[0] + names[1])
  println(toString(uintBig(4000000000u32)))
}
