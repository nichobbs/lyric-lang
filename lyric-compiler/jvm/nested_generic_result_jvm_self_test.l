//! nested_generic_result_jvm_self_test.l — JVM regression tests for #8242
//! (nested generic and function-typed call results) and #8528 (a constructor
//! nested in a constructor inside a `try` body).
@test_module
package Jvm.NestedGenericResultSelfTest

import Std.Core
import Std.Testing

extern type JNrBytesIn = "java.io.ByteArrayInputStream"

extern type JNrDataIn = "java.io.DataInputStream"

func grid(n: in Long): List[List[Long]] {
  val outer: List[List[Long]] = newList()
  val row: List[Long] = newList()
  row.add(n)
  row.add(n + 1)
  outer.add(row)
  outer
}

func gridWith(n: in Long, seed: in List[Long]): List[List[Long]] {
  val outer: List[List[Long]] = newList()
  outer.add(seed)
  outer
}

func adder(k: in Long): (Long) -> Option[Long] {
  { x: Long -> Some(x + k) }
}

func pickAdder(k: in Long, seed: in List[Long]): (Long) -> Option[Long] {
  { x: Long -> Some(x + k + seed.count) }
}

test "List[List[Long]] result read two levels deep" {
  val g = grid(10)
  val v: Long = g[0][1]
  assertEqualLong(v + 1, 12, "inner element used as Long")
}

test "List[List[Long]] result with an element argument" {
  val seed: List[Long] = newList()
  seed.add(7)
  val g = gridWith(1, seed)
  val v: Long = g[0][0]
  assertEqualLong(v * 2, 14, "inner element used as Long")
}

test "function-typed result called and matched" {
  val f = adder(5)
  val r = match f(3) { case Some(n) -> n; case None -> -1 }
  assertEqualLong(r, 8, "Some payload")
}

test "function-typed result with a collection argument" {
  val seed: List[Long] = newList()
  seed.add(1)
  val f = pickAdder(5, seed)
  val r = match f(3) { case Some(n) -> n; case None -> -1 }
  assertEqualLong(r, 9, "Some payload")
}

func readFirst(): Int {
  val bytes: slice[Byte] = [7, 8, 9]
  try {
    val din = JNrDataIn.new(JNrBytesIn.new(bytes))
    din.read()
  } catch Bug as _ {
    -1
  }
}

// The abandoned slots sit before wide (two-slot) locals, so a frame that
// dropped the gap would also misplace the Long and Double.
func readWide(): Long {
  val bytes: slice[Byte] = [7, 8, 9]
  try {
    val din = JNrDataIn.new(JNrBytesIn.new(bytes))
    val wide: Long = 5000000000i64
    val d: Double = 1.5
    din.read().toLong() + wide + d.toLong()
  } catch Bug as _ {
    -1i64
  }
}

test "frame gap before Long and Double locals in a try body" {
  assertEqualLong(readWide(), 5000000008i64, "7 + 5e9 + 1")
}

test "constructor nested in a constructor inside a try body" {
  assertEqualInt(readFirst(), 7, "read through nested constructors")
}
