//! `Float` is IEEE 754 binary32 on every backend (D155).
//!
//! Before D155 the MSIL and native backends lowered `Float` to binary64, so
//! `0.1f32 + 0.2f32` printed `0.30000000000000004` there and `0.3` on the
//! JVM.  These cases pin binary32 arithmetic, the literal rule (an unsuffixed
//! literal is a `Float` where one is required), the conversions, and .NET's
//! `Single.ToString()` rendering identically on every target.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/float32_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/float32_self_test.l
//!   lyric test --target native lyric-compiler/lyric/float32_self_test.l
@test_module
package Lyric.Float32SelfTest

import Std.Core
import Std.Collections
import Std.Testing

record Vec2 {
  x: Float
  y: Float
}

type Ratio = Float range 0.0 ..= 0.1

func half(f: in Float): Float = f / 2.0

func widen(f: in Float): Double = f

func tenth(): Float = 0.1

func pick(b: in Bool): Float = if b { 0.25 } else { 0.5 }

func checkedTenth(): Float
  ensures: result == 0.1
{
  0.1
}

func atMostTenth(x: in Float): Bool
  requires: x <= 0.1
{
  true
}

union Shape {
  case Circle(r: Float)
  case Rect(w: Float, h: Float)
}

func radius(s: in Shape): Float = match s { case Circle(r) -> r; case Rect(w, _) -> w }

record Small {
  v: Float
  invariant: v <= 0.1
}

func classify(f: in Float): String {
  match f {
    case 0.1 -> "tenth"
    case 0.0 ..= 1.0 -> "unit"
    case _ -> "other"
  }
}

test "arithmetic rounds to binary32" {
  val a: Float = 0.1
  val b = 0.2f32
  assertTrue(a + b == 0.3f32, "0.1 + 0.2 is the Float 0.3")
  assertTrue(16777216.0f32 + 1.0f32 == 16777216.0f32, "2^24 + 1 rounds back to 2^24")
  assertTrue(1.0f32 / 3.0f32 * 3.0f32 == 1.0f32, "1/3 * 3 rounds to 1")
}

test "a Float renders as Single.ToString() does" {
  assertEqual("${0.1f32 + 0.2f32}", "0.3", "0.1 + 0.2")
  assertEqual("${1.0f32 / 3.0f32}", "0.33333334", "1/3")
  assertEqual("${16777217.0f32}", "16777216", "2^24 + 1")
  assertEqual("${1e9f32}", "1E+09", "1e9")
  assertEqual("${100000000.0f32}", "100000000", "1e8")
  assertEqual("${1.234e-5f32}", "1.234E-05", "1.234e-5")
  assertEqual("${0.0001f32}", "0.0001", "1e-4")
  assertEqual("${0.00001f32}", "1E-05", "1e-5")
  assertEqual("${123456789.0f32}", "123456790", "rounded to binary32")
  val zero = 0.0f32
  assertEqual("${-zero}", "-0", "negative zero")
  assertEqual("${1.0f32 / zero}", "Infinity", "infinity")
  assertEqual("${-1.0f32 / zero}", "-Infinity", "negative infinity")
  assertEqual((2.5f32).toString(), "2.5", "toString")
  assertEqual(toString(1500.0f32), "1500", "free toString")
  assertEqual("v=" + 0.75f32.toString(), "v=0.75", "concatenation")
}

test "an unsuffixed literal is a Float where one is required" {
  val f: Float = 0.1
  assertTrue(f == 0.1f32, "binding")
  assertTrue(half(3.0) == 1.5f32, "argument and operand")
  val n: Float = -0.1
  assertTrue(n == -0.1f32, "negated literal")
  val v = Vec2(x = 0.5, y = 0.25)
  assertTrue(v.x + v.y == 0.75f32, "record fields")
  var acc: Float = 1.0
  acc += 0.5
  acc *= 2.0
  assertTrue(acc == 3.0f32, "compound assignment")
  val g: (Float) -> Float = { x -> x * 2.0 }
  assertTrue(g(1.25f32) == 2.5f32, "lambda")
  assertTrue(tenth() == 0.1f32, "return value")
  assertTrue(pick(true) + pick(false) == 0.75f32, "if branches")
  val xs: List[Float] = [0.1, 0.2]
  assertTrue(xs[0] + xs[1] == 0.3f32, "list literal elements")
}

func band(f: in Float): Int {
  match f {
    case -1 ..= 0 -> 0
    case 1 ..= 2 -> 1
    case _ -> 2
  }
}

func bandD(d: in Double): Int {
  match d {
    case 0 ..= 1 -> 0
    case _ -> 1
  }
}

test "literals in contracts and invariants are Floats too" {
  assertTrue(checkedTenth() == 0.1f32, "ensures compares against the Float 0.1")
  assertTrue(atMostTenth(0.1f32), "requires admits the Float 0.1 itself")
  val s = Small(v = 0.1f32)
  assertTrue(s.v == 0.1f32, "the invariant admits the Float 0.1")
}

test "a Float widens exactly to Double" {
  val d: Double = 0.1f32
  assertEqual(d.toString(), "0.10000000149011612", "binding")
  assertEqual(widen(0.1f32).toString(), "0.10000000149011612", "return")
  val mixed = 0.25f32 + 0.5
  assertEqual(mixed.toString(), "0.75", "a Float plus a Double is a Double")
  assertTrue(0.1f32 < 0.1000001, "comparison with a Double")
  val dbl: (Double) -> Double = { x -> x * 2.0 }
  assertEqual(dbl(0.1f32).toString(), "0.20000000298023224", "argument to a function value")
}

test "conversions to and from Float" {
  assertEqualInt((2.75f32).toInt(), 2, "toInt truncates")
  assertTrue((2.75f32).toLong() == 2i64, "toLong truncates")
  assertTrue((3).toFloat() == 3.0f32, "Int.toFloat")
  assertTrue((16777217i64).toFloat() == 16777216.0f32, "Long.toFloat rounds")
  assertTrue((200u8).toFloat() == 200.0f32, "Byte.toFloat is unsigned")
  assertEqual((0.1).toFloat().toDouble().toString(), "0.10000000149011612", "Double.toFloat rounds")
  assertTrue((65.0f32).toChar() == 'A', "toChar")
  assertTrue((300.75f32).toByte() == 44u8, "toByte truncates, then wraps modulo 256")
  assertTrue((2.5f32).toDouble() == 2.5, "toDouble")
  assertTrue(('A').toFloat() == 65.0f32, "Char.toFloat")
  assertTrue((300.75).toByte() == 44u8, "Double.toByte matches Float.toByte")
  assertTrue((200u8).toDouble() == 200.0, "Byte.toDouble is unsigned")
}

test "Floats in collections" {
  val xs: List[Float] = newList()
  xs.add(1.25f32)
  xs.add(0.5)
  assertTrue(xs[0] + xs[1] == 1.75f32, "list elements")
  val m: Map[String, Float] = newMap()
  m.add("k", 0.1)
  match mapGet(m, "k") {
    case Some(f) -> assertTrue(f == 0.1f32, "map value")
    case None -> assertTrue(false, "map value present")
  }
}

test "patterns and ranges use the nearest Float" {
  assertEqual(classify(0.1f32), "tenth", "literal pattern")
  assertEqual(classify(0.5f32), "unit", "range pattern")
  assertEqual(classify(1.5f32), "other", "outside the range")
  assertEqualInt(band(-0.5f32), 0, "integer bounds against a Float scrutinee")
  assertEqualInt(band(1.5f32), 1, "integer bounds, second arm")
  assertEqualInt(band(2.5f32), 2, "outside integer bounds")
  assertEqualInt(bandD(0.5), 0, "integer bounds against a Double scrutinee")
  assertEqualInt(bandD(1.5), 1, "outside integer bounds against a Double")
  match Ratio.tryFrom(0.1f32) {
    case Ok(_) -> assertTrue(true, "0.1f32 is within 0.0 ..= 0.1")
    case Err(_) -> assertTrue(false, "0.1f32 is within 0.0 ..= 0.1")
  }
  assertTrue(Ratio.from(0.05f32).toFloat() == 0.05f32, "toFloat reads the wrapped value back")
  assertTrue(Ratio.from(0.0f32).toFloat() == 0.0f32, "the lower bound round-trips")
  assertTrue(Ratio.from(0.1f32).toFloat() == 0.1f32, "the upper bound round-trips")
  match Ratio.tryFrom(0.2f32) {
    case Ok(_) -> assertTrue(false, "0.2f32 is outside 0.0 ..= 0.1")
    case Err(_) -> assertTrue(true, "0.2f32 is outside 0.0 ..= 0.1")
  }
}

test "NaN compares unordered" {
  val zero = 0.0f32
  val nan = zero / zero
  assertTrue(nan != nan, "NaN is not equal to itself")
  assertTrue(not (nan < 1.0f32), "NaN is not less than 1")
  assertEqual("${nan}", "NaN", "NaN renders as NaN")
}

test "an unsuffixed literal is a Float in a union case argument" {
  assertTrue(radius(Shape.Circle(r = 0.1)) == 0.1f32, "named case argument")
  assertTrue(radius(Circle(r = 2.5)) == 2.5f32, "unqualified case")
  assertTrue(radius(Shape.Rect(w = 0.3, h = 1.0)) == 0.3f32, "two fields")
}

// The smallest subnormals need one significant digit to round-trip; every
// target prints that one digit, as .NET does (#7987).
test "the smallest subnormals print one digit" {
  assertEqual(toString(1.0e-45f32), "1E-45", "the Float minimum subnormal")
  assertEqual(toString(3.0e-45f32), "3E-45", "twice the Float minimum subnormal")
  assertEqual(toString(6.0e-45f32), "6E-45", "four times the Float minimum subnormal")
  assertEqual(toString(5.0e-324), "5E-324", "the Double minimum subnormal")
  assertEqual(toString(1.0e-323), "1E-323", "twice the Double minimum subnormal")
  assertEqual(toString(8.0e-323), "8E-323", "16 times the Double minimum subnormal")
  assertEqual(toString(1.5e20), "1.5E+20", "a two-digit mantissa that one digit cannot round-trip")
  assertEqual(toString(1.5e10), "15000000000", "and in fixed notation")
}

protected type Gauge {
  var level: Float = 0.1f32
  invariant: level <= 0.1
  entry read(): Float {
    level
  }
  entry lower(by: in Float) {
    level = level - by
  }
}

// A protected invariant is type-checked like a contract clause, so an
// unsuffixed literal compared with a Float field is the nearest Float (#7988).
test "a protected invariant compares a Float field with a Float literal" {
  val g = Gauge()
  assertTrue(g.read() == 0.1f32, "the invariant holds at the initial value")
  g.lower(0.05f32)
  assertTrue(g.read() < 0.1f32, "and after an entry")
}
