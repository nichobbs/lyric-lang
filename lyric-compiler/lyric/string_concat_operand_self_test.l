//! string_concat_operand_self_test.l — runtime regression test for the text a
//! scalar operand of a `String` `+`, `+=`, `.toString()`, `toString(x)` or an
//! interpolated segment renders as, whatever bound the operand (#9089).
//!
//! `String + x` stringifies `x` as `toString(x)` does (docs/01 §2.1): a `Char`
//! is the character, an `Int`, `Long`, `Byte`, `UInt` or `ULong` its decimal
//! digits, a `Bool` `true`/`false`, a `Double` or `Float` its shortest text.
//!
//! `--target native` is the load-bearing run. `Char` and `Int` both lower to an
//! `i32` there and the backend keeps no static types, so before #9089 it told
//! a `Char` from an `Int` by the operand's shape alone (a literal, an annotated
//! local): a `Char` bound by a pattern, a `for`, a tuple, a lambda parameter of
//! an inferred closure, a generic field or a `Map` lookup was rejected at
//! `String +` ("mixed String/non-String operands") or printed as its code
//! point by `.toString()` and interpolation, and `String + <Int>` was rejected
//! outright. `import Std.Xml` did not build for that reason. The type checker
//! now marks every stringified `Char` operand for that backend, so each case
//! below yields the same text on dotnet, the JVM and native; the last one goes
//! through `Std.Xml`, whose entity decoder is such a `"" + c` in a package of
//! the bundled standard library.
//!
//!   lyric test --target native lyric-compiler/lyric/string_concat_operand_self_test.l
@test_module
package Lyric.StringConcatOperandSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.Xml

record Holder {
  c: Char
  n: Int
}

record Box[T] {
  value: T
}

union Tok {
  case Ch(c: Char)
  case Num(n: Int)
  case Both(c: Char, n: Int)
}

type Age = Int range 0 ..= 150

func mkChar(): Char {
  'f'
}

func mkInt(): Int {
  41
}

func someChar(): Option[Char] {
  Some('&')
}

func someInt(): Option[Int] {
  Some(38)
}

func pair(): (Char, Int) {
  ('p', 7)
}

func okChar(): Result[Char, String] {
  Ok('r')
}

func wrap[T](x: in T): String {
  "<" + x + ">"
}

func wrapOpt[T](o: in Option[T]): String {
  match o {
    case Some(v) -> "<" + v + ">"
    case None -> "none"
  }
}

func showOpt[T](o: in Option[T]): String {
  match o {
    case Some(v) -> "${v}|" + v.toString() + "|" + toString(v)
    case None -> "none"
  }
}

func joinAll[T](xs: in List[T]): String {
  var acc = ""
  for x in xs {
    acc += x
    acc += ","
  }
  acc
}

func apply(f: in (Char) -> String, c: in Char): String {
  f(c)
}

func describe(t: in Tok): String {
  match t {
    case Ch(c) -> "ch " + c
    case Num(n) -> "num " + n
    case Both(c, n) -> "both " + c + " " + n
  }
}

test "a Char bound by an Option pattern" {
  match someChar() {
    case Some(c) -> {
      assertEqual("" + c, "&", "String + Char")
      assertEqual("a" + c + "b", "a&b", "String + Char + String")
      assertEqual(c.toString(), "&", ".toString()")
      assertEqual(toString(c), "&", "toString(x)")
      assertEqual("<${c}>", "<&>", "interpolation")
      var acc = "acc:"
      acc += c
      assertEqual(acc, "acc:&", "+=")
    }
    case None -> assertTrue(false, "expected Some")
  }
}

test "an Int bound by an Option pattern" {
  match someInt() {
    case Some(n) -> {
      assertEqual("" + n, "38", "String + Int")
      assertEqual(n.toString(), "38", ".toString()")
      assertEqual("<${n}>", "<38>", "interpolation")
      var acc = "acc:"
      acc += n
      assertEqual(acc, "acc:38", "+=")
    }
    case None -> assertTrue(false, "expected Some")
  }
}

test "a Char bound by a Result pattern" {
  match okChar() {
    case Ok(c) -> assertEqual("ok " + c, "ok r", "Ok(c)")
    case Err(_) -> assertTrue(false, "expected Ok")
  }
}

test "union case fields" {
  assertEqual(describe(Ch(c = 'u')), "ch u", "Char field")
  assertEqual(describe(Num(n = 9)), "num 9", "Int field")
  assertEqual(describe(Both(c = 'w', n = 3)), "both w 3", "Char and Int fields")
}

test "tuple bindings" {
  val (pc, pn) = pair()
  assertEqual("t " + pc + " " + pn, "t p 7", "destructuring val")
  match pair() {
    case (tc, tn) -> assertEqual("t " + tc + " " + tn, "t p 7", "tuple pattern")
  }
}

test "for-loop variables" {
  val xs: List[Char] = newList()
  xs.add('l')
  xs.add('m')
  var acc = ""
  for lc in xs {
    acc = acc + lc
  }
  assertEqual(acc, "lm", "List[Char]")
  val ys = ['s', 't']
  var acc2 = ""
  for sc in ys {
    acc2 = acc2 + sc + "."
  }
  assertEqual(acc2, "s.t.", "slice of Char")
  var acc3 = ""
  for i in 0 .. 3 {
    acc3 = acc3 + i
  }
  assertEqual(acc3, "012", "Int range")
}

test "lambda parameters" {
  assertEqual(apply({ c: Char -> "[" + c + "]" }, 'L'), "[L]", "annotated parameter")
  val f = { c: Char -> "<" + c + ">" }
  assertEqual(f('M'), "<M>", "closure local")
  assertEqual(apply({ c -> "(" + c + ")" }, 'N'), "(N)", "inferred parameter")
}

test "record fields and call results" {
  val h = Holder(c = 'h', n = 3)
  assertEqual("f " + h.c + " " + h.n, "f h 3", "record fields")
  val b = Box(value = 'b')
  assertEqual("g " + b.value, "g b", "generic record field at Char")
  val bi = Box(value = 12)
  assertEqual("g " + bi.value, "g 12", "generic record field at Int")
  assertEqual("c " + mkChar() + " " + mkInt(), "c f 41", "call results")
}

test "generic functions" {
  assertEqual(wrap('g'), "<g>", "T = Char")
  assertEqual(wrap(5), "<5>", "T = Int")
  assertEqual(wrap(true), "<true>", "T = Bool")
  assertEqual(wrapOpt(someChar()), "<&>", "Option[T] at Char")
  assertEqual(wrapOpt(someInt()), "<38>", "Option[T] at Int")
  assertEqual(showOpt(someChar()), "&|&|&", "stringified three ways at Char")
  assertEqual(showOpt(someInt()), "38|38|38", "stringified three ways at Int")
  val cs: List[Char] = newList()
  cs.add('x')
  cs.add('y')
  assertEqual(joinAll(cs), "x,y,", "List[T] at Char")
  val ns: List[Int] = newList()
  ns.add(1)
  ns.add(2)
  assertEqual(joinAll(ns), "1,2,", "List[T] at Int")
}

test "collection lookups and indexing" {
  val m: Map[String, Char] = newMap()
  m.add("k", 'v')
  match mapGet(m, "k") {
    case Some(mv) -> assertEqual("m " + mv, "m v", "Map value")
    case None -> assertTrue(false, "expected a value")
  }
  val s = "xyz"
  assertEqual("i " + s[1], "i y", "String index")
  val inferred = s[2]
  assertEqual("i " + inferred, "i z", "inferred local")
  val copy = inferred
  assertEqual("i " + copy, "i z", "alias of an inferred local")
  val xs: List[Char] = newList()
  xs.add('q')
  assertEqual("i " + xs[0], "i q", "List element")
}

test "expression operands" {
  val s = "xyz"
  val cond = if s.length > 1 { 'y' } else { 'n' }
  assertEqual("e " + cond, "e y", "if expression")
  assertEqual("e " + (match someChar() { case Some(q) -> q; case None -> '?' }), "e &", "match expression")
  assertEqual("e " + 'z', "e z", "literal")
  assertEqual("e " + 65.toChar(), "e A", "toChar()")
}

test "every scalar operand type" {
  val i: Int = -17
  val l: Long = 5000000000i64
  val d: Double = 1.5
  val fl: Float = 0.25f32
  val by: Byte = 200u8
  val u: UInt = 4000000000u32
  val ul: ULong = 18446744073709551615u64
  val age = Age.from(42)
  assertEqual("s " + i, "s -17", "Int")
  assertEqual("s " + l, "s 5000000000", "Long")
  assertEqual("s " + d, "s 1.5", "Double")
  assertEqual("s " + fl, "s 0.25", "Float")
  assertEqual("s " + true, "s true", "Bool")
  assertEqual("s " + by, "s 200", "Byte")
  assertEqual("s " + u, "s 4000000000", "UInt")
  assertEqual("s " + ul, "s 18446744073709551615", "ULong")
  assertEqual("s " + age, "s 42", "range subtype")
  assertEqual("s " + 1 + 2, "s 12", "left to right")
  var acc = ""
  acc += i
  acc += l
  acc += d
  acc += true
  acc += by
  acc += u
  acc += 'c'
  assertEqual(acc, "-1750000000001.5true2004000000000c", "+= of each")
}

test "a Char stringified inside a bundled standard library package" {
  match parseXml("<e>a &amp; b &lt;c&gt; &quot;d&quot; &apos;e&apos;</e>") {
    case Ok(doc) -> assertEqual(textContent(documentRoot(doc)), "a & b <c> \"d\" 'e'", "named entities")
    case Err(e) -> assertTrue(false, XmlError.message(e))
  }
}
