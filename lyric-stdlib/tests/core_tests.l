//! stdlib/tests/core_tests.l — Tests for Std.Core.
//!
//! Covers Option, Result, slice helpers, and higher-order combinators.
//! Each test function panics on failure via Std.Testing assertions, so a
//! clean exit (code 0) means every assertion held.
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

func testAndThen(): Unit {
  val doubled = andThen(Some(value = 5), { x: Int -> Some(value = x * 2) })
  assertTrue(isSome(doubled), "andThen Some produces Some")
  assertEqualInt(unwrapOr(doubled, 0), 10, "andThen Some value")

  val chained = andThen(Some(value = 0), { x: Int -> None })
  assertTrue(isNone(chained), "andThen f returns None")

  assertTrue(isNone(andThen(None, { x: Int -> Some(value = x) })), "andThen on None is None")
}

func testOrElse(): Unit {
  val found = orElse(Some(value = 42), { () -> Some(value = 99) })
  assertEqualInt(unwrapOr(found, 0), 42, "orElse Some returns original")

  val fallback = orElse(None, { () -> Some(value = 99) })
  assertEqualInt(unwrapOr(fallback, 0), 99, "orElse None uses fallback")

  assertTrue(isNone(orElse(None, { () -> None })), "orElse None fallback None is None")
}

func testAndThenResult(): Unit {
  val ok = andThenResult(Ok(value = 5), { x: Int -> Ok(value = x + 1) })
  assertTrue(isOk(ok), "andThenResult Ok stays Ok")
  assertEqualInt(unwrapResultOr(ok, 0), 6, "andThenResult Ok value")

  val err: Result[Int, Int] = andThenResult(Ok(value = 5), { x: Int -> Err(error = 42) })
  assertTrue(isErr(err), "andThenResult returning Err yields Err")

  val passThrough: Result[Int, Int] = andThenResult(Err(error = 7), { x: Int -> Ok(value = x) })
  assertTrue(isErr(passThrough), "andThenResult on Err passes Err through")
  assertEqualInt(unwrapErrOr(passThrough, 0), 7, "andThenResult Err payload preserved")
}

func testMapResultErr(): Unit {
  val r: Result[Int, Int] = Ok(value = 5)
  val mapped = mapResultErr(r, { e: Int -> e * 2 })
  assertTrue(isOk(mapped), "mapResultErr Ok stays Ok")
  assertEqualInt(unwrapResultOr(mapped, 0), 5, "mapResultErr Ok value preserved")

  val rErr: Result[Int, Int] = Err(error = 21)
  val mapped2 = mapResultErr(rErr, { e: Int -> e * 2 })
  assertTrue(isErr(mapped2), "mapResultErr Err transforms")
  assertEqualInt(unwrapErrOr(mapped2, 0), 42, "mapResultErr Err value doubled")
}

func testUnwrapResult(): Unit {
  val r: Result[Int, String] = Ok(value = 42)
  assertEqualInt(unwrapResult(r), 42, "unwrapResult Ok returns value")
}

func testUnwrapOption(): Unit {
  val o: Option[Int] = Some(value = 99)
  assertEqualInt(unwrapOption(o), 99, "unwrapOption Some returns value")
}

func main(): Unit {
  testOption()
  testResult()
  testSliceHelpers()
  testAndThen()
  testOrElse()
  testAndThenResult()
  testMapResultErr()
  testUnwrapResult()
  testUnwrapOption()
  println("core: ok")
}
