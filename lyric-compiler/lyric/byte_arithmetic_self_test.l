//! byte_arithmetic_self_test.l — self-test for unsigned Byte division and modulo operations
//! Covers both standard arithmetic and all compound-assignment paths.
@test_module
package Lyric.ByteArithmeticSelfTest

import Std.Core
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

test "Byte compound assignments on array elements" {
  val arr: Array[Byte] = newArray(1)
  arr[0] = 200.toByte()
  val y: Byte = 3.toByte()

  arr[0] /= y
  assertEqualInt(arr[0].toInt(), 66, "arr[0] /= 3 gives 66")

  arr[0] = 200.toByte()
  arr[0] %= y
  assertEqualInt(arr[0].toInt(), 2, "arr[0] %= 3 gives 2")
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

  // Creating a closure hoists 'x'
  val dummyFunc = func(): Byte {
    x /= y
    x
  }

  val res = dummyFunc()
  assertEqualInt(res.toInt(), 66, "hoisted x /= 3 gives 66")
  assertEqualInt(x.toInt(), 66, "hoisted x local is updated to 66")

  var x2: Byte = 200.toByte()

  // Creating a second closure hoists 'x2'
  val dummyFunc2 = func(): Byte {
    x2 %= y
    x2
  }

  val res2 = dummyFunc2()
  assertEqualInt(res2.toInt(), 2, "hoisted x2 %= 3 gives 2")
  assertEqualInt(x2.toInt(), 2, "hoisted x2 local is updated to 2")
}
