//! Implicit unsigned widening zero-extends at every position (#7805).
//!
//! A `UInt` lowers to the same 32-bit representation as an `Int` on both
//! targets, so a `UInt` with its top bit set that widened implicitly to a
//! `ULong` was sign-extended (`4000000000u32` became 18446744073414584320).
//! The type checker now spells each such widening out as `.toULong()`, which
//! zero-extends (`conv.u8` / `Integer.toUnsignedLong`).  Every value below is
//! at least 2^31, so a sign extension changes it.  The positions the checker
//! used to reject (`return`, a function body's value, a slice literal element)
//! now widen like an initialiser, signed chain included.  Native has no
//! unsigned integer types yet, so this runs on dotnet and JVM.
@test_module
package UnsignedWidenSelfTest

import Std.Core
import Std.Collections
import Std.Testing

record Holder {
  var v: ULong
}

record Both {
  a: UInt
  b: ULong
}

union Size {
  case Known(n: ULong)
  case Unknown
}

func big(): UInt {
  4000000000u32
}

func passU(x: in ULong): ULong {
  x
}

func returnU(u: in UInt): ULong {
  return u
}

func tailU(u: in UInt): ULong {
  u
}

func exprU(u: in UInt): ULong = u

func branchU(c: in Bool, u: in UInt, l: in ULong): ULong {
  if c {
    u
  } else {
    l
  }
}

func matchU(k: in Int, u: in UInt, l: in ULong): ULong {
  match k {
    case 0 -> u
    case _ -> l
  }
}

func returnL(i: in Int): Long {
  return i
}

func tailL(i: in Int): Long {
  i
}

func branchL(c: in Bool, i: in Int, l: in Long): Long {
  if c {
    i
  } else {
    l
  }
}

func returnByte(b: in Byte): ULong {
  return b
}

func applyU(f: in (ULong) -> ULong, u: in UInt): ULong {
  f(u)
}

// Module-level values, field defaults and parameter defaults initialise a
// slot of their declared type too (#7811).
val modU: UInt = 4000000000u32

val modUL: ULong = modU

val modCall: ULong = big()

val modI: Int = -2000000000

val modL: Long = modI

record Defaults {
  n: Int
  u: ULong = modU
  c: ULong = big()
  l: Long = modI
}

exposed record ExposedDefaults {
  n: Int
  u: ULong = modU
}

protected type Tally {
  var total: ULong = modU
  func get(): ULong {
    total
  }
}

func defU(x: in ULong = modU): ULong {
  x
}

func defCall(x: in ULong = big()): ULong {
  x
}

func defL(x: in Long = modI): Long {
  x
}

record Widener {
  n: Int

  func widen(self: in Widener, u: in UInt): ULong {
    val x: ULong = u
    x
  }
}

func knownOf(s: in Size): ULong {
  match s {
    case Known(n) -> n
    case Unknown -> 0u64
  }
}

test "a binding zero-extends a UInt" {
  val u: UInt = 4000000000u32
  val a: ULong = u
  var b: ULong = u
  let c: ULong = big()
  assertEqual(toString(a), "4000000000", "val")
  assertEqual(toString(b), "4000000000", "var")
  assertEqual(toString(c), "4000000000", "let from a call")
}

test "assignment and compound assignment zero-extend a UInt" {
  val u: UInt = 4000000000u32
  var ul: ULong = 1u64
  ul += 4000000000u32
  assertEqual(toString(ul), "4000000001", "+= a literal")
  var b: ULong = 0u64
  b = u
  assertEqual(toString(b), "4000000000", "=")
  b += u
  assertEqual(toString(b), "8000000000", "+= a variable")
  b -= u
  assertEqual(toString(b), "4000000000", "-=")
}

test "an argument zero-extends a UInt" {
  val u: UInt = 4000000000u32
  val r = passU(u)
  assertEqual(toString(r), "4000000000", "direct call")
  val viaFn = applyU({ x: ULong -> x + 1u64 }, u)
  assertEqual(toString(viaFn), "4000000001", "call through a function value")
}

test "a constructor argument zero-extends a UInt" {
  val u: UInt = 4000000000u32
  val h = Holder(v = u)
  assertTrue(h.v == 4000000000u64, "named record field")
  val bh = Both(u, u)
  assertTrue(bh.b == 4000000000u64, "positional record field")
  assertTrue(knownOf(Known(n = u)) == 4000000000u64, "union case field")
}

test "field and element stores zero-extend a UInt" {
  val u: UInt = 4000000000u32
  val h = Holder(v = 0u64)
  h.v = u
  assertTrue(h.v == 4000000000u64, "field =")
  h.v += u
  assertTrue(h.v == 8000000000u64, "field +=")
  var xs: slice[ULong] = [0u64, 0u64]
  xs[0] = u
  xs[1] += u
  assertTrue(xs[0] == 4000000000u64, "slice element =")
  assertTrue(xs[1] == 4000000000u64, "slice element +=")
  val ls: List[ULong] = newList()
  ls.add(u)
  assertTrue(ls[0] == 4000000000u64, "List.add")
  val m: Map[String, ULong] = newMap()
  m.add("k", u)
  assertTrue(m["k"] == 4000000000u64, "Map.add")
}

test "a returned UInt zero-extends" {
  val u: UInt = 4000000000u32
  assertEqual(toString(returnU(u)), "4000000000", "return")
  assertEqual(toString(tailU(u)), "4000000000", "block tail")
  assertEqual(toString(exprU(u)), "4000000000", "expression body")
  assertEqual(toString(branchU(true, u, 1u64)), "4000000000", "if branch")
  assertEqual(toString(branchU(false, u, 1u64)), "1", "if else branch")
  assertEqual(toString(matchU(0, u, 1u64)), "4000000000", "match arm")
}

test "a slice or list literal element zero-extends a UInt" {
  val u: UInt = 4000000000u32
  val xs: slice[ULong] = [u, 1u64]
  assertTrue(xs[0] == 4000000000u64, "slice literal")
  assertTrue(xs[1] == 1u64, "slice literal second element")
  val ls: List[ULong] = [u, 2u64]
  assertTrue(ls[0] == 4000000000u64, "list literal")
}

test "a UInt field operand beside a ULong zero-extends" {
  val bh = Both(a = 4000000000u32, b = 1u64)
  val sum: ULong = bh.a + bh.b
  assertEqual(toString(sum), "4000000001", "UInt field + ULong field")
  val lt = bh.b < bh.a
  assertTrue(lt, "ULong field < UInt field with the top bit set")
}

test "a Byte widens without sign extension" {
  val b: Byte = 200.toByte()
  val ul: ULong = b
  val l: Long = b
  val i: Int = b
  assertEqual(toString(ul), "200", "Byte to ULong")
  assertEqual(toString(l), "200", "Byte to Long")
  assertEqual(toString(i), "200", "Byte to Int")
  assertEqual(toString(returnByte(b)), "200", "returned Byte to ULong")
}

test "the signed chain widens at return, branch and slice literal" {
  assertEqual(toString(returnL(-7)), "-7", "return")
  assertEqual(toString(tailL(-8)), "-8", "block tail")
  assertEqual(toString(branchL(true, -9, 1i64)), "-9", "if branch")
  val i: Int = -10
  val xs: slice[Long] = [i, 3000000000i64]
  assertEqual(toString(xs[0]), "-10", "slice literal")
}

test "toULong spells the widening out" {
  val u: UInt = 4000000000u32
  val b: Byte = 255.toByte()
  assertEqual(toString(u.toULong()), "4000000000", "UInt receiver")
  assertEqual(toString(b.toULong()), "255", "Byte receiver")
  assertEqual(toString(5u64.toULong()), "5", "ULong receiver")
}

test "a module-level val zero-extends a UInt (#7811)" {
  assertEqual(toString(modUL), "4000000000", "from another module val")
  assertEqual(toString(modCall), "4000000000", "from a call")
  assertEqual(toString(modL), "-2000000000", "the signed chain")
}

test "a field default zero-extends a UInt (#7811)" {
  val d = Defaults(n = 1)
  assertEqual(toString(d.u), "4000000000", "record field default from a module val")
  assertEqual(toString(d.c), "4000000000", "record field default from a call")
  assertEqual(toString(d.l), "-2000000000", "signed record field default")
  val e = ExposedDefaults(n = 1)
  assertEqual(toString(e.u), "4000000000", "exposed record field default")
  val t = Tally()
  assertEqual(toString(t.get()), "4000000000", "protected field initialiser")
}

test "a parameter default zero-extends a UInt (#7811)" {
  assertEqual(toString(defU()), "4000000000", "default from a module val")
  assertEqual(toString(defCall()), "4000000000", "default from a call")
  assertEqual(toString(defL()), "-2000000000", "signed default")
  assertEqual(toString(defU(7u64)), "7", "an explicit argument still wins")
}

test "a binding in a record's own method zero-extends a UInt (#7811)" {
  val w = Widener(n = 1)
  assertEqual(toString(w.widen(4000000000u32)), "4000000000", "record method binding")
}
