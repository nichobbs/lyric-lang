//! slice_fastpath_self_test.l — `slice[T]` element access and copies give
//! the same results whichever runtime representation a slice has (#7259).
//!
//! On MSIL a `slice[T]` value is either a genuine CLI `T[]` or a
//! `List`-backed slice (#2539). Index reads, index writes, `for` iteration
//! and slice copies test the representation once and use
//! `ldelem`/`stelem`/`Array.Copy` for a real array, keeping the boxing `IList`
//! path for anything else. Every source this module can build (literals,
//! `.slice`/`.concat`/`.append`, `List.toArray()`, generic helpers, BCL
//! arrays from `encodeUtf8` and `String.Split`) is a real array under the
//! current code generator, so these cases pin the fast paths' results for
//! each primitive element type; the `IList` fallback is the unchanged
//! pre-#7259 code, reached only by slices from other assemblies. JVM and
//! native have one representation each; the module runs there for parity.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/slice_fastpath_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/slice_fastpath_self_test.l
//!   lyric test --target native lyric-compiler/lyric/slice_fastpath_self_test.l
@test_module
package Lyric.SliceFastpathSelfTest

import Std.Core
import Std.Collections
import Std.Encoding
import Std.Testing

func sumByIndex(xs: in slice[Int]): Int {
  var total = 0
  var i = 0
  while i < xs.length {
    total = total + xs[i]
    i = i + 1
  }
  total
}

func sumByFor(xs: in slice[Int]): Int {
  var total = 0
  for x in xs {
    total = total + x
  }
  total
}

func byteSum(xs: in slice[Byte]): Int {
  var total = 0
  for b in xs {
    total = total + b.toInt()
  }
  var i = 0
  while i < xs.length {
    total = total + xs[i].toInt()
    i = i + 1
  }
  total
}

func joinFor(xs: in slice[String]): String {
  var acc = ""
  for s in xs {
    acc = acc + s + ";"
  }
  acc
}

func intList(n: in Int): List[Int] {
  val xs: List[Int] = newList()
  var i = 1
  while i <= n {
    xs.add(i)
    i = i + 1
  }
  xs
}

test "Int reads agree for a literal, a copy, a sub-slice and a List-built slice" {
  val lit: slice[Int] = [1, 2, 3, 4, 5]
  val fromList = intList(5).toArray()
  assertEqualInt(sumByIndex(lit), 15, "literal by index")
  assertEqualInt(sumByFor(lit), 15, "literal by for")
  assertEqualInt(sumByIndex(fromList), 15, "toArray by index")
  assertEqualInt(sumByFor(fromList), 15, "toArray by for")
  assertEqualInt(sumByIndex(lit.slice(1, 4)), 9, "sub-slice by index")
  assertEqualInt(sumByFor(fromList.slice(1, 4)), 9, "sub-slice of toArray by for")
  assertEqualInt(sumByIndex(lit.concat(fromList)), 30, "concat by index")
  assertEqualInt(sumByFor(lit.append(10)), 25, "append by for")
}

test "Int writes land in the slice that was written" {
  var xs: slice[Int] = [0, 0, 0, 0]
  xs[0] = 7
  xs[3] = 9
  assertEqualInt(xs[0], 7, "first write")
  assertEqualInt(xs[3], 9, "last write")
  assertEqualInt(sumByFor(xs), 16, "writes seen by for")
  var ys = intList(4).toArray()
  ys[1] = 20
  assertEqualInt(ys[1], 20, "write into toArray result")
  assertEqualInt(sumByIndex(ys), 28, "toArray write seen by index")
}

test "Byte reads and copies agree for encoder output, sub-slices and concatenation" {
  val bytes = encodeUtf8("ABCDE")
  assertEqualInt(byteSum(bytes), 2 * (65 + 66 + 67 + 68 + 69), "encodeUtf8 output")
  val mid = bytes.slice(1, 4)
  assertEqualInt(mid.length, 3, "sub-slice length")
  assertEqualInt(mid[0].toInt(), 66, "sub-slice first byte")
  assertEqualInt(mid[2].toInt(), 68, "sub-slice last byte")
  val both = mid.concat(bytes.slice(0, 1))
  assertEqualInt(both.length, 4, "concat length")
  assertEqualInt(both[3].toInt(), 65, "concat tail byte")
  val lit: slice[Byte] = [1u8, 2u8, 255u8]
  assertEqualInt(byteSum(lit), 2 * 258, "byte literal")
  var w = bytes.slice(0, 2)
  w[1] = 0u8
  assertEqualInt(w[1].toInt(), 0, "byte write")
  assertEqualInt(bytes[1].toInt(), 66, "sub-slice is a copy")
}

test "String reads agree for a BCL array, a literal and a copy" {
  val parts = "a,b,c".split(",")
  assertEqual(joinFor(parts), "a;b;c;", "split output by for")
  assertEqual(parts[2], "c", "split output by index")
  val lit: slice[String] = ["x", "y"]
  assertEqual(joinFor(lit.concat(parts.slice(0, 1))), "x;y;a;", "concat of literal and split")
  var ws = lit.slice(0, 2)
  ws[0] = "z"
  assertEqual(ws[0], "z", "string write")
  assertEqual(lit[0], "x", "copy leaves the source untouched")
}

test "Char, Bool, Long and Double slices read and write through both paths" {
  var cs: slice[Char] = ['a', 'b', 'c']
  cs[1] = 'z'
  assertTrue(cs[1] == 'z', "char write")
  assertTrue(cs.slice(1, 3)[1] == 'c', "char sub-slice read")
  var bs: slice[Bool] = [false, false]
  bs[1] = true
  assertTrue(bs[1] and not bs[0], "bool write")
  var ls: slice[Long] = [1i64, 2i64]
  ls[0] = 9000000000i64
  assertTrue(ls.concat(ls)[2] == 9000000000i64, "long concat read")
  var ds: slice[Double] = [0.5, 1.5]
  ds[1] = 2.25
  var dsum = 0.0
  for d in ds {
    dsum = dsum + d
  }
  assertTrue(dsum == 2.75, "double write and for")
}

test "an Int written into a slice[Long] is widened, not truncated or garbled (#7341)" {
  var ls: slice[Long] = [0i64, 0i64]
  ls[0] = 4
  ls[1] = 0 - 7
  assertTrue(ls[0] == 4i64, "positive Int widened")
  assertTrue(ls[1] == 0i64 - 7i64, "negative Int sign-extended")
  var total = 0i64
  for v in ls {
    total = total + v
  }
  assertTrue(total == 0i64 - 3i64, "widened values read back by for")
}

test "compound assignment on slice elements updates in place (#7343)" {
  var xs: slice[Int] = [1, 2, 3]
  xs[1] += 40
  xs[2] *= 5
  xs[0] -= 11
  assertEqualInt(xs[0], 0 - 10, "Int -=")
  assertEqualInt(xs[1], 42, "Int +=")
  assertEqualInt(xs[2], 15, "Int *=")
  val bl: List[Byte] = newList()
  bl.add(250)
  bl.add(7)
  var bs: slice[Byte] = bl.toArray()
  bs[0] += 10.toByte()
  bs[1] /= 2.toByte()
  assertEqualInt(bs[0].toInt(), 4, "Byte += wraps unsigned")
  assertEqualInt(bs[1].toInt(), 3, "Byte /=")
  var ls: slice[Long] = [9000000000i64, 1i64]
  ls[0] += 3
  ls[1] -= 8
  assertTrue(ls[0] == 9000000003i64, "Long += widened Int rhs")
  assertTrue(ls[1] == 0i64 - 7i64, "Long -= sign-extended Int rhs")
  var ds: slice[Double] = [1.5]
  ds[0] *= 3.0
  assertTrue(ds[0] == 4.5, "Double *=")
  var ss: slice[String] = ["a", "b"]
  ss[1] += "c"
  assertEqual(ss[1], "bc", "String += String")
}

func countedIndex(calls: in List[Int], i: in Int): Int {
  calls.add(i)
  i
}

test "slice compound assignment evaluates its index once" {
  val calls: List[Int] = newList()
  var xs: slice[Int] = [10, 20]
  xs[countedIndex(calls, 1)] += 5
  assertEqualInt(calls.count, 1, "index evaluated once")
  assertEqualInt(xs[1], 25, "element updated")
}

test "an Int stored into a List[Long] or Map[String, Long] is widened (#7343)" {
  val xs: List[Long] = newList()
  xs.add(0i64)
  xs.add(0i64)
  xs[0] = 4
  xs[1] = 0 - 7
  assertTrue(xs[0] == 4i64, "List[Long] positive Int widened")
  assertTrue(xs[1] == 0i64 - 7i64, "List[Long] negative Int sign-extended")
  xs[1] += 3
  assertTrue(xs[1] == 0i64 - 4i64, "List[Long] += widened Int rhs")
  val m: Map[String, Long] = newMap()
  m["a"] = 0 - 9
  assertTrue(m["a"] == 0i64 - 9i64, "Map[String, Long] value widened")
  m["a"] += 2
  assertTrue(m["a"] == 0i64 - 7i64, "Map[String, Long] += widened Int rhs")
}

test "an empty slice copies and iterates cleanly" {
  val empty: slice[Int] = []
  assertEqualInt(empty.slice(0, 0).length, 0, "empty sub-slice")
  assertEqualInt(sumByFor(empty.concat(empty)), 0, "empty concat")
  assertEqualInt(sumByFor(intList(0).toArray()), 0, "empty toArray")
}
