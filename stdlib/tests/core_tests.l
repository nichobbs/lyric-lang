// stdlib/tests/core_tests.l — Tests for Std.Core.
//
// Covers Option, Result, slice helpers, and higher-order combinators.
// Each test function panics on failure via Std.Testing assertions, so a
// clean exit (code 0) means every assertion held.
package Std.Core.Tests

import Std.Core
import Std.Testing

func testOption(): Unit {
  // unwrapOr
  assertEqualInt(unwrapOr(Some(value = 42), 0), 42, "unwrapOr Some")
  assertEqualInt(unwrapOr(None, 99), 99, "unwrapOr None")

  // isSome / isNone
  assertTrue(isSome(Some(value = 1)), "isSome Some")
  assertTrue(not isSome(None), "isSome None is false")
  assertTrue(isNone(None), "isNone None")
  assertTrue(not isNone(Some(value = 0)), "isNone Some is false")

  // mapOption — transforms value inside Some, passes None through
  val doubled = mapOption(Some(value = 3), { x: Int -> x * 2 })
  assertTrue(isSome(doubled), "mapOption Some produces Some")
  assertEqualInt(unwrapOr(doubled, 0), 6, "mapOption Some value")
  assertTrue(isNone(mapOption(None, { x: Int -> x * 2 })), "mapOption None stays None")

  // filterOption
  assertTrue(isSome(filterOption(Some(value = 10), { x: Int -> x > 5 })), "filter passes")
  assertTrue(isNone(filterOption(Some(value = 3), { x: Int -> x > 5 })), "filter rejects")
  assertTrue(isNone(filterOption(None, { x: Int -> x > 5 })), "filter on None")
}

func testResult(): Unit {
  // isOk / isErr
  assertTrue(isOk(Ok(value = 7)), "isOk Ok")
  assertTrue(not isOk(Err(error = 1)), "isOk Err is false")
  assertTrue(isErr(Err(error = 1)), "isErr Err")
  assertTrue(not isErr(Ok(value = 7)), "isErr Ok is false")

  // unwrapResultOr
  assertEqualInt(unwrapResultOr(Ok(value = 7), 0), 7, "unwrapResultOr Ok")
  assertEqualInt(unwrapResultOr(Err(error = 1), 99), 99, "unwrapResultOr Err")

  // unwrapErrOr
  assertEqualInt(unwrapErrOr(Err(error = 42), 0), 42, "unwrapErrOr Err")
  assertEqualInt(unwrapErrOr(Ok(value = 5), 77), 77, "unwrapErrOr Ok falls back")

  // mapResult — transforms Ok value, passes Err through
  val mapped = mapResult(Ok(value = 5), { x: Int -> x + 1 })
  assertTrue(isOk(mapped), "mapResult Ok stays Ok")
  assertEqualInt(unwrapResultOr(mapped, 0), 6, "mapResult Ok value")
  assertTrue(isErr(mapResult(Err(error = 42), { x: Int -> x + 1 })), "mapResult Err stays Err")
}

func testSliceHelpers(): Unit {
  val xs = [3, 1, 4, 1, 5, 9, 2, 6]

  assertEqualInt(sumInts(xs), 31, "sumInts")
  assertEqualInt(maxInt(xs), 9, "maxInt")
  assertEqualInt(countEq(xs, 1), 2, "countEq")

  assertEqualInt(countWhere(xs, { x: Int -> x > 3 }), 4, "countWhere gt 3")
  assertEqualInt(countWhere(xs, { x: Int -> x == 9 }), 1, "countWhere eq 9")
  assertEqualInt(countWhere(xs, { x: Int -> x > 100 }), 0, "countWhere none match")
}

func main(): Unit {
  testOption()
  testResult()
  testSliceHelpers()
  println("core: ok")
}
