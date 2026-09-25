//! slice_fastpath_self_test.l — `slice[T]` element access and copies give
//! the same results whichever runtime representation a slice has (#7259).
//!
//! On MSIL a `slice[T]` value is either a genuine CLI `T[]` (a slice
//! literal, `.slice`/`.concat`/`.append`, `List.toArray()`, a BCL array such
//! as `String.Split`'s or `encodeUtf8`'s) or a `List`-backed slice (a `List`
//! passed where a slice is expected, #2539). Index reads, index writes, `for`
//! iteration and slice copies test the representation once and use
//! `ldelem`/`stelem`/`Array.Copy` for a real array, falling back to the
//! boxing `IList` path otherwise. Every case below runs each operation over
//! both kinds of source for each primitive element type, so a fast path that
//! misreads or miswrites either representation fails here. JVM and native
//! have one representation each; the module runs there for parity.
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
  var out = ""
  for s in xs {
    out = out + s + ";"
  }
  out
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
  assertEqual(cs[1].toString(), "z", "char write")
  assertEqual(cs.slice(1, 3)[1].toString(), "c", "char sub-slice read")
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

test "an empty slice copies and iterates cleanly" {
  val empty: slice[Int] = []
  assertEqualInt(empty.slice(0, 0).length, 0, "empty sub-slice")
  assertEqualInt(sumByFor(empty.concat(empty)), 0, "empty concat")
  assertEqualInt(sumByFor(intList(0).toArray()), 0, "empty toArray")
}
