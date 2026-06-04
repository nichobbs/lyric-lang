// book_ch05_tests.l — Chapter 5: Pattern Matching
//
// Verifies exhaustive matching, constructor patterns, guards, literal patterns,
// tuple patterns, record destructuring, ranges, alternatives, and wildcards.
package Book.Ch05.Tests

import Std.Core
import Std.Testing

// ---------------------------------------------------------------------------
// §5.1 Exhaustive match on unions
// ---------------------------------------------------------------------------

union Shape {
  case Circle(radius: Double)
  case Rectangle(width: Double, height: Double)
  case Dot
}

func describe(s: in Shape): String {
  match s {
    case Circle(r)       -> if r > 100.0 then "large circle" else "circle r=${toString(r)}"
    case Rectangle(w, h) -> if w == h then "square ${toString(w)}x${toString(h)}" else "rectangle ${toString(w)}x${toString(h)}"
    case Dot             -> "dot"
  }
}

func testExhaustiveMatch(): Unit {
  assertEqual(describe(Circle(radius = 5.0)),   "circle r=5", "small circle")
  assertEqual(describe(Circle(radius = 200.0)), "large circle", "large circle guard")
  assertEqual(describe(Rectangle(width = 4.0, height = 4.0)), "square 4x4", "square guard")
  assertEqual(describe(Rectangle(width = 3.0, height = 2.0)), "rectangle 3x2", "rectangle")
  assertEqual(describe(Dot), "dot", "dot")
}

// ---------------------------------------------------------------------------
// §5.2 Literal patterns
// ---------------------------------------------------------------------------

func classify(n: Int): String {
  match n {
    case 0  -> "zero"
    case 1  -> "one"
    case 42 -> "the answer"
    case _  -> "other"
  }
}

func testLiteralPatterns(): Unit {
  assertEqual(classify(0),  "zero",       "literal 0")
  assertEqual(classify(1),  "one",        "literal 1")
  assertEqual(classify(42), "the answer", "literal 42")
  assertEqual(classify(99), "other",      "wildcard")
}

// ---------------------------------------------------------------------------
// §5.3 Option/Result pattern matching
// ---------------------------------------------------------------------------

func safeDivide(a: Int, b: Int): Option[Int] {
  if b == 0 then None else Some(value = a / b)
}

func testOptionMatch(): Unit {
  match safeDivide(10, 2) {
    case Some(v) -> assertEqualInt(v, 5, "Some(5)")
    case None    -> assertTrue(false, "should not be None")
  }

  match safeDivide(10, 0) {
    case Some(_) -> assertTrue(false, "should not be Some")
    case None    -> assertTrue(true, "None for div by zero")
  }
}

func testResultMatch(): Unit {
  val ok: Result[Int, String] = Ok(value = 42)
  val err: Result[Int, String] = Err(error = "bad")

  match ok {
    case Ok(v)  -> assertEqualInt(v, 42, "match Ok value")
    case Err(e) -> assertTrue(false, "should be Ok")
  }

  match err {
    case Ok(_)  -> assertTrue(false, "should be Err")
    case Err(e) -> assertEqual(e, "bad", "match Err value")
  }
}

// ---------------------------------------------------------------------------
// §5.4 Tuple patterns
// ---------------------------------------------------------------------------

func classifyPair(pair: in (Int, Int)): String {
  match pair {
    case (0, 0) -> "origin"
    case (x, 0) -> "on x-axis at ${toString(x)}"
    case (0, y) -> "on y-axis at ${toString(y)}"
    case (x, y) -> "${toString(x)},${toString(y)}"
  }
}

func testTuplePattern(): Unit {
  assertEqual(classifyPair((0, 0)), "origin", "origin")
  assertEqual(classifyPair((5, 0)), "on x-axis at 5", "x-axis")
  assertEqual(classifyPair((0, 3)), "on y-axis at 3", "y-axis")
  assertEqual(classifyPair((2, 4)), "2,4", "general point")
}

// ---------------------------------------------------------------------------
// §5.5 Alternative patterns
// ---------------------------------------------------------------------------

enum Day { case Mon; case Tue; case Wed; case Thu; case Fri; case Sat; case Sun }

func isWeekend(d: in Day): Bool {
  match d {
    case Sat | Sun -> true
    case _         -> false
  }
}

func testAlternativePattern(): Unit {
  assertTrue(isWeekend(Day.Sat), "Saturday is weekend")
  assertTrue(isWeekend(Day.Sun), "Sunday is weekend")
  assertTrue(not isWeekend(Day.Mon), "Monday not weekend")
  assertTrue(not isWeekend(Day.Fri), "Friday not weekend")
}

// ---------------------------------------------------------------------------
// §5.6 Binding patterns in nested structures
// ---------------------------------------------------------------------------

union Tree {
  case Leaf(value: Int)
  case Node(left: Tree, right: Tree)
}

func sumTree(t: in Tree): Int {
  match t {
    case Leaf(v)    -> v
    case Node(l, r) -> sumTree(l) + sumTree(r)
  }
}

func testNestedMatch(): Unit {
  val tree = Node(
    left  = Node(left = Leaf(value = 1), right = Leaf(value = 2)),
    right = Leaf(value = 3)
  )
  assertEqualInt(sumTree(tree), 6, "tree sum = 1+2+3")
}

// ---------------------------------------------------------------------------
// §5.7 Bool match
// ---------------------------------------------------------------------------

func describe_bool(b: Bool): String {
  match b {
    case true  -> "yes"
    case false -> "no"
  }
}

func testBoolMatch(): Unit {
  assertEqual(describe_bool(true),  "yes", "Bool true")
  assertEqual(describe_bool(false), "no",  "Bool false")
}

// ---------------------------------------------------------------------------
// §5.8 Wildcard and binding
// ---------------------------------------------------------------------------

func firstElement(xs: in slice[Int]): Option[Int] {
  if xs.length == 0 then None else Some(value = xs[0])
}

func testWildcard(): Unit {
  match firstElement([1, 2, 3]) {
    case Some(v) -> assertEqualInt(v, 1, "first element")
    case _       -> assertTrue(false, "unexpected None")
  }
}

func main(): Unit {
  testExhaustiveMatch()
  testLiteralPatterns()
  testOptionMatch()
  testResultMatch()
  testTuplePattern()
  testAlternativePattern()
  testNestedMatch()
  testBoolMatch()
  testWildcard()
  println("book_ch05: ok")
}
