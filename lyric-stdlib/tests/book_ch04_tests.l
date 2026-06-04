// book_ch04_tests.l — Chapter 4: Functions and Parameter Modes
//
// Verifies: expression-bodied and block-bodied functions, in/out/inout modes,
// tuple returns, closures, lambdas, first-class functions, and control flow.
package Book.Ch04.Tests

import Std.Core
import Std.Iter
import Std.Parse
import Std.Testing

// ---------------------------------------------------------------------------
// §4.1 Basic function declarations
// ---------------------------------------------------------------------------

func add(x: Int, y: Int): Int = x + y

func greet(name: String): String {
  return "Hello, ${name}!"
}

func logMessage(msg: String): Unit {
  println("[INFO] ${msg}")
}

func testBasicFunctions(): Unit {
  assertEqualInt(add(3, 4), 7, "add(3, 4)")
  assertEqual(greet("Lyric"), "Hello, Lyric!", "greet")
  logMessage("test")
  assertTrue(true, "logMessage completed")
}

// ---------------------------------------------------------------------------
// §4.2 Parameter modes
// ---------------------------------------------------------------------------

func divmod(n: Int, d: Int, q: out Int, r: out Int) {
  q = n / d
  r = n % d
}

func increment(x: inout Int) {
  x = x + 1
}

func swap(xs: inout slice[Int], i: Int, j: Int) {
  val tmp = xs[i]
  xs[i] = xs[j]
  xs[j] = tmp
}

func testOutParameters(): Unit {
  var quotient: Int
  var remainder: Int
  divmod(17, 5, quotient, remainder)
  assertEqualInt(quotient, 3, "divmod quotient")
  assertEqualInt(remainder, 2, "divmod remainder")
}

func testInoutParameters(): Unit {
  var counter = 0
  increment(counter)
  assertEqualInt(counter, 1, "increment once")
  increment(counter)
  assertEqualInt(counter, 2, "increment twice")
}

func testInoutSlice(): Unit {
  var xs = [10, 20, 30]
  swap(xs, 0, 2)
  assertEqualInt(xs[0], 30, "swap xs[0]")
  assertEqualInt(xs[2], 10, "swap xs[2]")
}

// ---------------------------------------------------------------------------
// §4.3 Return values and multiple returns
// ---------------------------------------------------------------------------

func minMax(xs: in slice[Int]): (Int, Int) {
  var lo = xs[0]
  var hi = xs[0]
  for x in xs {
    if x < lo { lo = x }
    if x > hi { hi = x }
  }
  return (lo, hi)
}

func testTupleReturn(): Unit {
  val numbers = [3, 1, 4, 1, 5, 9, 2, 6]
  val (lo, hi) = minMax(numbers)
  assertEqualInt(lo, 1, "minMax lo")
  assertEqualInt(hi, 9, "minMax hi")
}

// ---------------------------------------------------------------------------
// §4.4 Closures and lambdas
// ---------------------------------------------------------------------------

func testClosures(): Unit {
  val double = { x: Int -> x * 2 }
  assertEqualInt(double(21), 42, "closure double(21)")

  val numbers = [1, 2, 3, 4, 5]
  val doubled = map(numbers, { x: Int -> x * 2 })
  assertEqualInt(doubled[0], 2, "map doubled[0]")
  assertEqualInt(doubled[4], 10, "map doubled[4]")

  val evens = filter(numbers, { x: Int -> x % 2 == 0 })
  assertEqualInt(evens.length, 2, "filter evens length")
  assertEqualInt(evens[0], 2, "filter evens[0]")
}

func testClosureCapture(): Unit {
  // Closures can use their own parameters and call other functions
  val square = { x: Int -> x * x }
  assertEqualInt(square(5), 25, "closure square(5)")
  assertEqualInt(square(3), 9,  "closure square(3)")
}

func testFirstClassClosures(): Unit {
  val addOne: (Int) -> Int = { x: Int -> x + 1 }
  val doubler: (Int) -> Int = { x: Int -> x * 2 }
  val sub3:   (Int) -> Int = { x: Int -> x - 3 }
  assertEqualInt(addOne(10), 11, "addOne(10) = 11")
  assertEqualInt(doubler(10), 20, "doubler(10) = 20")
  assertEqualInt(sub3(10),    7,  "sub3(10) = 7")
}

// ---------------------------------------------------------------------------
// §4.5 Control flow
// ---------------------------------------------------------------------------

func testIfExpression(): Unit {
  val score = 75
  val label = if score >= 60 then "pass" else "fail"
  assertEqual(label, "pass", "if expression pass")

  val label2 = if score < 50 then "fail" else "pass"
  assertEqual(label2, "pass", "if expression else branch")
}

func testForLoop(): Unit {
  var sum = 0
  for i in [0, 1, 2, 3, 4] {
    sum += i
  }
  assertEqualInt(sum, 10, "for slice sum")

  var sum2 = 0
  for i in [0, 1, 2, 3, 4] {
    sum2 += i
  }
  assertEqualInt(sum2, 10, "for second slice sum")
}

func testBreakContinue(): Unit {
  var found = -1
  for x in [10, 20, 30, 40, 50] {
    if x == 30 {
      found = x
      break
    }
  }
  assertEqualInt(found, 30, "break exits loop at 30")

  var odds = 0
  for x in [1, 3, 5] {
    odds += x
  }
  assertEqualInt(odds, 9, "sum of odds 1+3+5")
}

// ---------------------------------------------------------------------------
// §4.6 Error propagation
// ---------------------------------------------------------------------------

func parseAndDouble(raw: String): Result[Int, Int] {
  val parsed = tryParseInt(raw)
  if isErr(parsed) { return Err(error = -1) }
  return Ok(value = unwrapResult(parsed) * 2)
}

func testErrorPropagation(): Unit {
  val ok = parseAndDouble("21")
  assertTrue(isOk(ok), "parseAndDouble ok")
  assertEqualInt(unwrapResult(ok), 42, "parseAndDouble value")

  val err = parseAndDouble("xyz")
  assertTrue(isErr(err), "parseAndDouble err on invalid input")
}

func main(): Unit {
  testBasicFunctions()
  testTupleReturn()
  testClosures()
  testClosureCapture()
  testFirstClassClosures()
  testIfExpression()
  testForLoop()
  testBreakContinue()
  testErrorPropagation()
  println("book_ch04: ok")
}
