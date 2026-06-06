//! book_ch03_tests.l — Chapter 3: Data Structures
//!
//! Verifies: records, unions (sum types), enums, tuples, arrays, and slices.
package Book.Ch03.Tests

import Std.Core
import Std.Testing

// ---------------------------------------------------------------------------
// §3.1 Records
// ---------------------------------------------------------------------------
record Point {
  x: Double
  y: Double
}

pub record Customer {
  pub id: Int
  pub email: String
  name: String
}

func testRecordConstruction(): Unit {
  val p = Point(x = 1.5, y = 2.5)
  assertTrue(p.x == 1.5, "record field x")
  assertTrue(p.y == 2.5, "record field y")
}

func testRecordFieldAccess(): Unit {
  val c = Customer(id = 1, email = "alice@example.com", name = "Alice")
  assertEqualInt(c.id, 1, "Customer.id")
  assertEqual(c.email, "alice@example.com", "Customer.email")
  assertEqual(c.name, "Alice", "Customer.name")
}

record Stats {
  min: Int
  max: Int
  sum: Int
  count: Int
}

func summarize(xs: in slice[Int]): Stats {
  var mn = xs[0]
  var mx = xs[0]
  var s = 0
  for x in xs {
    if x < mn {
      mn = x
    }
    if x > mx {
      mx = x
    }
    s += x
  }
  Stats(min = mn, max = mx, sum = s, count = xs.length)
}

func testRecordReturn(): Unit {
  val s = summarize([3, 1, 4, 1, 5, 9])
  assertEqualInt(s.min, 1, "Stats.min")
  assertEqualInt(s.max, 9, "Stats.max")
  assertEqualInt(s.sum, 23, "Stats.sum")
  assertEqualInt(s.count, 6, "Stats.count")
}

// ---------------------------------------------------------------------------
// §3.2 Union types (sum types)
// ---------------------------------------------------------------------------
union Shape {
  case Circle(radius: Double)
  case Rectangle(width: Double, height: Double)
  case Dot
}

func area(s: in Shape): Double {
  match s {
    case Circle(r) -> 3.14159 * r * r
    case Rectangle(w, h) -> w * h
    case Dot -> 0.0
  }
}

func testUnionConstruction(): Unit {
  val c = Circle(radius = 5.0)
  val r = Rectangle(width = 4.0, height = 3.0)
  val d = Dot

  assertTrue(area(c) > 78.0 and area(c) < 79.0, "Circle area ~78.54")
  assertTrue(area(r) == 12.0, "Rectangle area 12.0")
  assertTrue(area(d) == 0.0, "Dot area 0.0")
}

// ---------------------------------------------------------------------------
// §3.3 Enums
// ---------------------------------------------------------------------------
enum Color {
  case Red
  case Green
  case Blue
}

func colorName(c: in Color): String {
  match c {
    case Red -> "red"
    case Green -> "green"
    case Blue -> "blue"
  }
}

func testEnum(): Unit {
  assertEqual(colorName(Color.Red), "red", "enum Red")
  assertEqual(colorName(Color.Green), "green", "enum Green")
  assertEqual(colorName(Color.Blue), "blue", "enum Blue")
}

// ---------------------------------------------------------------------------
// §3.4 Tuples
// ---------------------------------------------------------------------------
func divmod(n: Int, d: Int): (Int, Int) {
  (n / d, n % d)
}

func testTuple(): Unit {
  val (q, r) = divmod(17, 5)
  assertEqualInt(q, 3, "divmod quotient")
  assertEqualInt(r, 2, "divmod remainder")
}

func testTupleConstruction(): Unit {
  val pair: (Int, String) = (1, "hello")
  val (n, s) = pair
  assertEqualInt(n, 1, "tuple destructure first")
  assertEqual(s, "hello", "tuple destructure second")
}

// ---------------------------------------------------------------------------
// §3.5 Arrays and slices
// ---------------------------------------------------------------------------
func testArray(): Unit {
  val fixed: slice[Int] = [10, 20, 30, 40]
  assertEqualInt(fixed.length, 4, "array length")
  assertEqualInt(fixed[0], 10, "array[0]")
  assertEqualInt(fixed[3], 40, "array[3]")
}

func testSlice(): Unit {
  val xs: slice[Int] = [1, 2, 3, 4, 5]
  assertEqualInt(xs.length, 5, "slice length")
  assertEqualInt(xs[0], 1, "slice[0]")
  assertEqualInt(xs[4], 5, "slice[4]")

  // Empty slice
  val empty: slice[Int] = []
  assertEqualInt(empty.length, 0, "empty slice length")
}

func testSliceIteration(): Unit {
  val xs = [10, 20, 30]
  var sum = 0
  for x in xs {
    sum += x
  }
  assertEqualInt(sum, 60, "slice iteration sum")
}

func testStringSlice(): Unit {
  val words: slice[String] = ["alpha", "beta", "gamma"]
  assertEqualInt(words.length, 3, "string slice length")
  assertEqual(words[1], "beta", "string slice[1]")
}

// ---------------------------------------------------------------------------
// §3.6 Option[T] (some / none)
// ---------------------------------------------------------------------------
func testOptionValues(): Unit {
  val name: Option[String] = Some(value = "Alice")
  val noName: Option[String] = None

  assertTrue(isSome(name), "Some is Some")
  assertTrue(isNone(noName), "None is None")

  val display = unwrapOr(name, "anonymous")
  assertEqual(display, "Alice", "unwrapOr with Some")

  val display2 = unwrapOr(noName, "anonymous")
  assertEqual(display2, "anonymous", "unwrapOr with None")
}

func main(): Unit {
  testRecordConstruction()
  testRecordFieldAccess()
  testRecordReturn()
  testUnionConstruction()
  testEnum()
  testTuple()
  testTupleConstruction()
  testArray()
  testSlice()
  testSliceIteration()
  testStringSlice()
  testOptionValues()
  println("book_ch03: ok")
}
