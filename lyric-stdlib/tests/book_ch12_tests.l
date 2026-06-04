// book_ch12_tests.l — Chapter 12: Standard Library
//
// Verifies: Std.Core combinators, Std.String, Std.Collections, Std.Math,
// Std.Parse, Std.Sort, and Std.Iter using correct free-function call forms.
package Book.Ch12.Tests

import Std.Core
import Std.String
import Std.Collections
import Std.Math
import Std.Parse
import Std.Sort
import Std.Iter
import Std.Testing

// ---------------------------------------------------------------------------
// §12.2 Std.Core
// ---------------------------------------------------------------------------

func testCoreResult(): Unit {
  val r: Result[Int, Int] = Ok(value = 42)

  // mapResult transforms the Ok value
  val doubled = mapResult(r, { v: Int -> v * 2 })
  assertTrue(isOk(doubled), "mapResult Ok stays Ok")
  assertEqualInt(unwrapResultOr(doubled, 0), 84, "mapResult Ok doubled")

  // mapResultErr transforms the Err value
  val rErr: Result[Int, Int] = Err(error = 5)
  val mapped = mapResultErr(rErr, { e: Int -> e * 3 })
  assertTrue(isErr(mapped), "mapResultErr Err stays Err")
  assertEqualInt(unwrapErrOr(mapped, 0), 15, "mapResultErr Err value")

  // unwrapResultOr
  assertEqualInt(unwrapResultOr(r, 0), 42, "unwrapResultOr Ok")
  assertEqualInt(unwrapResultOr(rErr, 99), 99, "unwrapResultOr Err default")
}

func testCoreOption(): Unit {
  val opt: Option[String] = Some(value = "hello")

  // mapOption transforms Some
  val upper = mapOption(opt, { s: String -> toUpper(s) })
  assertTrue(isSome(upper), "mapOption Some stays Some")
  assertEqual(unwrapOr(upper, ""), "HELLO", "mapOption value")

  // unwrapOr
  assertEqual(unwrapOr(opt, "default"), "hello", "unwrapOr Some")
  val none: Option[String] = None
  assertEqual(unwrapOr(none, "default"), "default", "unwrapOr None")

  // isSome / isNone
  assertTrue(isSome(opt), "isSome Some")
  assertTrue(isNone(none), "isNone None")
}

func parseDoubleInt(raw: String): Result[Int, Int] {
  val parsed = tryParseInt(raw)
  if isErr(parsed) { return Err(error = -1) }
  return Ok(value = unwrapResult(parsed) * 2)
}

func testCorePropagation(): Unit {
  assertTrue(isOk(parseDoubleInt("21")), "parseDouble ok")
  assertEqualInt(unwrapResult(parseDoubleInt("21")), 42, "parseDouble value")
  assertTrue(isErr(parseDoubleInt("bad")), "parseDouble err")
}

// ---------------------------------------------------------------------------
// §12.3 Std.String
// ---------------------------------------------------------------------------

func testString(): Unit {
  val parts = split("a,b,c", ",")
  assertEqualInt(parts.length, 3, "split count")
  assertEqual(parts[0], "a", "split[0]")
  assertEqual(parts[2], "c", "split[2]")

  assertEqual(join(" | ", parts), "a | b | c", "join")
  assertEqual(trim("  hello  "), "hello", "trim")
  assertEqual(toUpper("hello"), "HELLO", "toUpper")
  assertEqual(toLower("WORLD"), "world", "toLower")
  assertEqual(substring("hello", 1, 3), "ell", "substring")
  assertTrue(startsWith("hello", "he"), "startsWith")
  assertTrue(endsWith("hello", "lo"), "endsWith")
  assertTrue(contains("hello world", "world"), "contains")
  assertEqual(replace("aabbcc", "bb", "XX"), "aaXXcc", "replace")
}

// ---------------------------------------------------------------------------
// §12.4 Std.Collections
// ---------------------------------------------------------------------------

func testCollectionsList(): Unit {
  var list: List[String] = newList()
  list.add("alpha")
  list.add("beta")
  list.add("gamma")
  assertEqualInt(list.count, 3, "List count")
  assertEqual(list[0], "alpha", "List[0]")
  assertEqual(list[1], "beta",  "List[1]")

  // Iteration
  var n = 0
  for item in list { n += 1 }
  assertEqualInt(n, 3, "List iteration count")
}

func testCollectionsMap(): Unit {
  var m: Map[String, Int] = newMap()
  m.add("age", 30)
  m.add("score", 95)

  assertTrue(m.containsKey("age"), "Map containsKey age")
  assertTrue(not m.containsKey("missing"), "Map missing key")
  assertEqualInt(unwrapOr(mapGet(m, "age"), 0), 30, "Map.get age")
  assertEqualInt(unwrapOr(mapGet(m, "score"), 0), 95, "Map.get score")
}

// ---------------------------------------------------------------------------
// §12.5 Std.Math
// ---------------------------------------------------------------------------

func testMath(): Unit {
  assertEqualInt(absInt(-5), 5, "absInt(-5)")
  assertEqualInt(absInt(5),  5, "absInt(5)")
  assertEqualInt(minPairInt(3, 7), 3, "minPairInt(3,7)")
  assertEqualInt(maxPairInt(3, 7), 7, "maxPairInt(3,7)")
  assertTrue(sqrt(4.0) == 2.0, "sqrt(4.0)")
  assertTrue(sqrt(9.0) == 3.0, "sqrt(9.0)")
  assertTrue(pow(2.0, 10.0) == 1024.0, "pow(2,10)")
  assertTrue(floor(3.7) == 3.0, "floor(3.7)")
  assertTrue(ceiling(3.2) == 4.0, "ceiling(3.2)")
}

// ---------------------------------------------------------------------------
// §12.6 Std.Parse
// ---------------------------------------------------------------------------

func testParse(): Unit {
  val ok = tryParseInt("42")
  assertTrue(isOk(ok), "tryParseInt 42")
  assertEqualInt(unwrapResult(ok), 42, "tryParseInt value")

  val bad = tryParseInt("xyz")
  assertTrue(isErr(bad), "tryParseInt xyz fails")

  val longOk = tryParseLong("9000000000")
  assertTrue(isOk(longOk), "tryParseLong ok")

  val dbl = tryParseDouble("3.14")
  assertTrue(isOk(dbl), "tryParseDouble ok")

  val boolT = tryParseBool("true")
  assertTrue(isOk(boolT), "tryParseBool true")
  assertTrue(unwrapResult(boolT), "tryParseBool value")
}

// ---------------------------------------------------------------------------
// §12.7 Std.Sort
// ---------------------------------------------------------------------------

func testSort(): Unit {
  val sorted = sortInts([3, 1, 4, 1, 5, 9, 2, 6])
  assertEqualInt(sorted[0], 1, "sortInts[0]")
  assertEqualInt(sorted[7], 9, "sortInts[7]")

  val sortedStrings = sortStrings(["banana", "apple", "cherry"])
  assertEqual(sortedStrings[0], "apple",  "sortStrings[0]")
  assertEqual(sortedStrings[1], "banana", "sortStrings[1]")
  assertEqual(sortedStrings[2], "cherry", "sortStrings[2]")
}

// ---------------------------------------------------------------------------
// §12.8 Std.Iter
// ---------------------------------------------------------------------------

func testIter(): Unit {
  val numbers = [1, 2, 3, 4, 5]

  val doubled = map(numbers, { x: Int -> x * 2 })
  assertEqualInt(doubled[0], 2, "map doubled[0]")
  assertEqualInt(doubled[4], 10, "map doubled[4]")

  val evens = filter(numbers, { x: Int -> x % 2 == 0 })
  assertEqualInt(evens.length, 2, "filter evens count")

  val sum = fold(numbers, 0, { acc: Int, x: Int -> acc + x })
  assertEqualInt(sum, 15, "fold sum")

  assertTrue(all(numbers, { x: Int -> x > 0 }), "all positive")
  assertTrue(any(numbers, { x: Int -> x > 4 }), "any gt 4")
  assertTrue(not all(numbers, { x: Int -> x > 3 }), "not all gt 3")

  val first = find(numbers, { x: Int -> x > 3 })
  assertTrue(isSome(first), "find found")
  assertEqualInt(unwrapOr(first, 0), 4, "find first gt 3 is 4")

  val taken = take(numbers, 3)
  assertEqualInt(taken.length, 3, "take 3")
  assertEqualInt(taken[0], 1, "take[0]")

  val dropped = drop(numbers, 2)
  assertEqualInt(dropped.length, 3, "drop 2")
  assertEqualInt(dropped[0], 3, "drop[0]")
}

func main(): Unit {
  testCoreResult()
  testCoreOption()
  testCorePropagation()
  testString()
  testCollectionsList()
  testCollectionsMap()
  testMath()
  testParse()
  testSort()
  testIter()
  println("book_ch12: ok")
}
