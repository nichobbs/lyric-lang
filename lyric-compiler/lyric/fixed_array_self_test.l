//! `array[N, T]` (D167, docs/67 §4.3): a fixed-length array with value
//! semantics, the same behaviour on every target.
//!
//! Construction from a bracket literal and zero fill, indexing, element
//! writes through a `var` local, a `var` field and an `inout` parameter,
//! copies on assignment, passing and returning, `.length`, `for x in a`,
//! `.toSlice()`, `==` / `!=`, and range-subtype index elision.  Out-of-range
//! panics are in `fixed_array_panic_self_test.l` (dotnet and the JVM) and
//! `scripts/ci/fixed-array-e2e.sh` (native).
//!
//!   lyric test --target dotnet lyric-compiler/lyric/fixed_array_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/fixed_array_self_test.l
//!   lyric test --target native lyric-compiler/lyric/fixed_array_self_test.l
@test_module
package Lyric.FixedArraySelfTest

import Std.Core
import Std.Collections
import Std.Testing

enum Mode {
  case Idle
  case Busy
}

type Cents = Int range 0 ..= 100

type Slot = Int range 0 ..= 3

record Vec3 {
  x: Float
  y: Float
  z: Float
}

record Mat {
  cells: array[4, Float]
}

record Counter {
  var hits: array[3, Int]
  var name: String
}

record Particle {
  var pos: array[3, Float]
  var alive: Bool
}

val SIZE: Int = 3

record Reading {
  var values: array[SIZE, Float]
}

func sumOf(a: in array[4, Int]): Int {
  var t = 0
  for x in a {
    t = t + x
  }
  t
}

func bump(a: inout array[4, Int], i: in Int) {
  a[i] = a[i] + 10
}

func firstTwo(): array[2, Int] {
  val a: array[2, Int] = [7, 8]
  a
}

func keep(a: in array[4, Int]): array[4, Int] {
  var b = a
  b[0] = 99
  b
}

func at(a: in array[4, Int], i: in Slot): Int {
  a[i]
}

func rowSum(m: in array[2, array[3, Int]], r: in Int): Int {
  var t = 0
  for x in m[r] {
    t = t + x
  }
  t
}

test "a bracket literal builds an array and elements read back" {
  val a: array[4, Int] = [10, 20, 30, 40]
  assertEqualInt(a[0], 10, "first")
  assertEqualInt(a[3], 40, "last")
  val f: array[3, Float] = [1.5, 2.5, 3.5]
  assertTrue(f[1] == 2.5f32, "Float element")
  val b: array[2, Bool] = [true, false]
  assertTrue(b[0] and not b[1], "Bool elements")
  assertEqualInt(sumOf([1, 2, 3, 4]), 10, "a literal argument")
}

test "an array of arrays and an array of records" {
  val m: array[2, array[3, Int]] = [[1, 2, 3], [4, 5, 6]]
  assertEqualInt(m[0][2], 3, "row 0 col 2")
  assertEqualInt(m[1][0], 4, "row 1 col 0")
  val vs: array[2, Vec3] = [Vec3(x = 1.0, y = 2.0, z = 3.0), Vec3(x = 4.0, y = 5.0, z = 6.0)]
  assertTrue(vs[1].y == 5.0f32, "record element field")
  assertEqualInt(rowSum(m, 1), 15, "a row iterated")
}

test "an array without an initializer is zero filled" {
  var ints: array[4, Int]
  var floats: array[3, Float]
  var flags: array[2, Bool]
  var modes: array[2, Mode]
  var vecs: array[2, Vec3]
  var grid: array[2, array[2, Int]]
  var cents: array[2, Cents]
  assertEqualInt(ints[3], 0, "Int zero")
  assertTrue(floats[2] == 0.0f32, "Float zero")
  assertTrue(not flags[1], "Bool zero")
  assertTrue(modes[1] == Idle, "an enum's first case")
  assertTrue(vecs[1].z == 0.0f32, "a record of zeros")
  assertEqualInt(grid[1][1], 0, "nested zero")
  assertEqualInt(cents[0].value, 0, "a range subtype containing zero")
}

test "a field of array type with no default is zero filled" {
  val c = Counter(name = "c")
  assertEqualInt(c.hits[2], 0, "hits zero")
  val m = Mat()
  assertTrue(m.cells[3] == 0.0f32, "cells zero")
  val p = Particle(alive = true)
  assertTrue(p.pos[0] == 0.0f32, "pos zero")
}

test "elements are written through a var local, a var field and an inout parameter" {
  var a: array[4, Int] = [1, 2, 3, 4]
  a[1] = 20
  a[2] += 5
  assertEqualInt(a[1], 20, "assigned")
  assertEqualInt(a[2], 8, "compound assigned")
  val c = Counter(name = "c")
  c.hits[1] = 5
  c.hits[1] = c.hits[1] + 1
  assertEqualInt(c.hits[1], 6, "a var field's element")
  val p = Particle(alive = true)
  p.pos[2] = 1.5
  assertTrue(p.pos[2] == 1.5f32, "a Float field element")
  bump(a, 0)
  assertEqualInt(a[0], 11, "an inout parameter")
  var g: array[2, array[2, Int]] = [[1, 2], [3, 4]]
  g[1][0] = 30
  g[0][1] += 7
  assertEqualInt(g[1][0], 30, "nested write")
  assertEqualInt(g[0][1], 9, "nested compound write")
}

test "assigning, passing and returning copies the array" {
  var a: array[4, Int] = [1, 2, 3, 4]
  var b = a
  b[0] = 100
  assertEqualInt(a[0], 1, "the original is untouched by a write to the copy")
  assertEqualInt(b[0], 100, "the copy changed")
  a[1] = 200
  assertEqualInt(b[1], 2, "and the copy is untouched by a write to the original")
  val k = keep(a)
  assertEqualInt(a[0], 1, "a callee's local copy")
  assertEqualInt(k[0], 99, "the returned copy")
  val snapshot = a
  a[2] = 300
  assertEqualInt(snapshot[2], 3, "a val bound to a var's array keeps its value")
  val r = firstTwo()
  assertEqualInt(r[1], 8, "a returned literal")
}

test "a field copies the array it is built from and hands out copies" {
  var src: array[4, Float] = [1.0, 2.0, 3.0, 4.0]
  val m = Mat(cells = src)
  src[0] = 9.0
  assertTrue(m.cells[0] == 1.0f32, "the record kept the value at construction")
  var taken = m.cells
  taken[1] = 8.0
  assertTrue(m.cells[1] == 2.0f32, "a copy taken from a field is independent")
  val c = Counter(name = "c")
  var h = c.hits
  h[0] = 5
  assertEqualInt(c.hits[0], 0, "a var field's array copied out")
  val p = Particle(alive = true)
  var q = p.pos
  p.pos[0] = 3.0
  assertTrue(q[0] == 0.0f32, "and unaffected by a later write to the field")
}

test "length is the compile-time length" {
  val a: array[4, Int] = [1, 2, 3, 4]
  var z: array[7, Float]
  assertEqualInt(a.length, 4, "literal array")
  assertEqualInt(z.length, 7, "zero filled array")
  val m: array[2, array[3, Int]] = [[1, 2, 3], [4, 5, 6]]
  assertEqualInt(m.length, 2, "outer")
  assertEqualInt(m[0].length, 3, "inner")
}

test "for iterates the elements of the array as it is when the loop starts" {
  var a: array[4, Int] = [1, 2, 3, 4]
  var seen = 0
  for x in a {
    a[3] = 100
    seen = seen + x
  }
  assertEqualInt(seen, 10, "the loop saw the original elements")
  assertEqualInt(a[3], 100, "the write still happened")
  var n = 0
  for x in a {
    if x == 2 {
      continue
    }
    if x == 100 {
      break
    }
    n = n + 1
  }
  assertEqualInt(n, 2, "continue and break")
}

test "toSlice copies the elements into a slice" {
  var a: array[3, Int] = [5, 6, 7]
  val s = a.toSlice()
  a[0] = 50
  assertEqualInt(s.length, 3, "length")
  assertEqualInt(s[0], 5, "a copy, not a view")
  assertEqualInt(s[2], 7, "last element")
}

test "equality compares element by element" {
  val a: array[3, Int] = [1, 2, 3]
  val b: array[3, Int] = [1, 2, 3]
  val c: array[3, Int] = [1, 2, 4]
  assertTrue(a == b, "equal arrays")
  assertTrue(a != c, "differing last element")
  assertTrue(not (a == c), "not equal")
  val x: array[2, Vec3] = [Vec3(x = 1.0, y = 2.0, z = 3.0), Vec3(x = 4.0, y = 5.0, z = 6.0)]
  val y: array[2, Vec3] = [Vec3(x = 1.0, y = 2.0, z = 3.0), Vec3(x = 4.0, y = 5.0, z = 6.0)]
  val z: array[2, Vec3] = [Vec3(x = 1.0, y = 2.0, z = 3.0), Vec3(x = 4.0, y = 5.0, z = 7.0)]
  assertTrue(x == y, "records compare by value")
  assertTrue(x != z, "one differing field")
  val m: array[2, array[2, Int]] = [[1, 2], [3, 4]]
  val n: array[2, array[2, Int]] = [[1, 2], [3, 4]]
  val o: array[2, array[2, Int]] = [[1, 2], [3, 5]]
  assertTrue(m == n, "nested arrays")
  assertTrue(m != o, "nested difference")
  assertTrue(Mat(cells = [1.0, 2.0, 3.0, 4.0]) == Mat(cells = [1.0, 2.0, 3.0, 4.0]), "a record holding an array")
  assertTrue(Mat(cells = [1.0, 2.0, 3.0, 4.0]) != Mat(cells = [1.0, 2.0, 3.0, 5.0]), "a differing array field")
  val f: array[2, Float] = [0.0, 1.0]
  assertTrue(f == f, "reflexive")
}

test "a range-subtype index reads the same element as an Int index" {
  val a: array[4, Int] = [10, 20, 30, 40]
  val s: Slot = Slot.from(2)
  assertEqualInt(at(a, s), 30, "a Slot index")
  assertEqualInt(a[s], 30, "inline")
  var w: array[4, Int]
  w[s] = 5
  assertEqualInt(w[2], 5, "a Slot index on a write")
  val lit = a[3]
  assertEqualInt(lit, 40, "a literal index")
}

test ".copy of a record carries its array over as a copy" {
  val p = Particle(alive = true)
  p.pos[0] = 1.0
  val q = p.copy(alive = false)
  p.pos[0] = 5.0
  assertTrue(q.pos[0] == 1.0f32, "the copy kept the array it was made from")
  q.pos[1] = 2.0
  assertTrue(p.pos[1] == 0.0f32, "and a write to the copy is not seen through the original")
  val m = Mat(cells = [1.0, 2.0, 3.0, 4.0])
  val n = m.copy(cells = [4.0, 3.0, 2.0, 1.0])
  assertTrue(m.cells[0] == 1.0f32 and n.cells[0] == 4.0f32, "a by-value record copy with a new array")
}

test "an array length can name a constant" {
  var a: array[SIZE, Int]
  a[2] = 4
  assertEqualInt(a.length, 3, "the constant is the length")
  val r = Reading()
  r.values[2] = 1.5
  assertTrue(r.values[2] == 1.5f32 and r.values.length == 3, "a field sized by a constant")
  val lit: array[SIZE, Int] = [1, 2, 3]
  assertEqualInt(lit[2], 3, "a literal of that many elements")
}

type LongSlot = Long range 0 ..= 3

record Tally {
  var hits: array[4, Int]
}

record Rows {
  var row: array[3, Int]
}

record Holder {
  var items: array[4, Int]
}

record Box[T] {
  var data: array[2, T]
}

func nextIdx(n: inout Int): Int {
  n = n + 1
  1
}

func ident[T](x: in T): T {
  x
}

func keepIn(a: in array[4, Int]): Holder {
  Holder(items = a)
}

func bumpRow(r: inout array[3, Int]) {
  r[0] = r[0] + 1
}

test "a compound assignment evaluates its index once and writes the array itself" {
  var a: array[4, Int] = [1, 2, 3, 4]
  val i = 1
  a[i + 1] += 10
  assertEqualInt(a[2], 13, "an arithmetic index")
  var n = 0
  a[nextIdx(n)] += 5
  assertEqualInt(a[1], 7, "a call index")
  assertEqualInt(n, 1, "the call ran once")
  val t = Tally()
  val k = 1
  t.hits[k * 2] += 1
  t.hits[k * 2] += 1
  assertEqualInt(t.hits[2], 2, "a var field's element")
  var g: array[2, array[3, Int]]
  g[i][i + 1] += 4
  assertEqualInt(g[1][2], 4, "a nested element")
  a[i + 2] -= 1
  a[i * 2] *= 3
  assertEqualInt(a[3], 3, "-=")
  assertEqualInt(a[2], 39, "*=")
}

test "an array stored into a var or a field never shares storage with a val or a read" {
  val a: array[4, Int] = [1, 2, 3, 4]
  var b = a
  b[0] = 100
  assertEqualInt(a[0], 1, "a val's array stored in a var")
  var v: array[4, Int] = [1, 2, 3, 4]
  val w = ident(v)
  v[0] = 9
  assertEqualInt(w[0], 1, "a var read and passed to a generic function")
  val x = ident(a)
  var y = x
  y[1] = 50
  assertEqualInt(a[1], 2, "a generic result stored in a var")
  val h = keepIn(v)
  v[1] = 77
  assertEqualInt(h.items[1], 2, "an array passed in and stored in a field")
  val tally = Tally()
  var src: array[4, Int] = [5, 6, 7, 8]
  val t2 = tally.copy(hits = src)
  src[0] = 0
  assertEqualInt(t2.hits[0], 5, "a .copy argument")
  val bsrc: array[2, Int] = [1, 2]
  val bx = Box(data = bsrc)
  var d = bx.data
  d[0] = 7
  assertEqualInt(bx.data[0], 1, "an array of a generic record's field")
  val bx2 = bx.copy()
  bx2.data[1] = 9
  assertEqualInt(bx.data[1], 2, "a .copy of a generic record")
}

test "an inout argument may be a var local or a var field holding an array" {
  var row: array[3, Int] = [1, 2, 3]
  bumpRow(row)
  assertEqualInt(row[0], 2, "a var local")
  val r = Rows()
  bumpRow(r.row)
  bumpRow(r.row)
  assertEqualInt(r.row[0], 2, "a var field")
}

test "an index may be any integer type or a range subtype of one" {
  val a: array[4, Int] = [10, 20, 30, 40]
  val l: Long = 2
  assertEqualInt(a[l], 30, "a Long")
  val b: Byte = 3u8
  assertEqualInt(a[b], 40, "a Byte")
  assertEqualInt(a[2i64], 30, "a suffixed literal")
  val ls: LongSlot = LongSlot.from(3)
  assertEqualInt(a[ls], 40, "a range subtype over Long")
  var w: array[4, Int]
  w[l] = 8
  w[l] += 1
  assertEqualInt(w[2], 9, "a Long index on a write")
}

record Cell[T] {
  var v: T
}

type Row = array[2, Int]

union Slotted {
  case Full(a: array[2, Int])
  case Empty
}

record Holding {
  o: Option[array[2, Int]]
}

record Pool {
  var items: array[3, Bucket]
}

record Bucket {
  var hits: array[2, Int]
}

func put[T](o: out T, v: in T) {
  o = v
}

func getCell[T](c: in Cell[T]): T {
  c.v
}

func sameGen[T](a: in T, b: in T): Bool {
  a == b
}

func countGen[T](a: in T): Int {
  var n = 0
  for x in a {
    n = n + 1
  }
  n
}

test "a generic function over T = array copies, compares and iterates like concrete code" {
  val src: array[3, Int] = [1, 2, 3]
  var dst: array[3, Int]
  put(dst, src)
  dst[0] = 9
  assertEqualInt(src[0], 1, "a store through an out parameter of generic type")
  val cell = Cell(v = src)
  var got = getCell(cell)
  got[0] = 7
  assertEqualInt(getCell(cell)[0], 1, "a generic read of a var field is a copy once stored in a var")
  val same: array[3, Int] = [1, 2, 3]
  val other: array[3, Int] = [1, 2, 4]
  assertTrue(sameGen(src, same), "== on T = array compares the elements")
  assertTrue(not sameGen(src, other), "and tells a difference")
  assertEqualInt(countGen(src), 3, "for over T = array")
}

test "one generic over arrays of two lengths gets two specialisations" {
  val two: array[2, Int] = [1, 2]
  val three: array[3, Int] = [1, 2, 3]
  assertEqualInt(countGen(two), 2, "length 2")
  assertEqualInt(countGen(three), 3, "length 3")
}

test "== looks inside options, tuples, unions, distinct types and records" {
  val a: array[2, Int] = [1, 2]
  val b: array[2, Int] = [1, 2]
  val c: array[2, Int] = [1, 3]
  assertTrue(Some(a) == Some(b), "an Option of arrays")
  assertTrue(Some(a) != Some(c), "differing arrays in an Option")
  val none1: Option[array[2, Int]] = None
  val none2: Option[array[2, Int]] = None
  assertTrue(none1 == none2, "None")
  assertTrue(none1 != Some(a), "None and Some")
  assertTrue((1, a) == (1, b), "a tuple")
  assertTrue((1, a) != (1, c), "a tuple with differing arrays")
  assertTrue(Full(a) == Full(b), "a union case")
  assertTrue(Full(a) != Full(c), "a union case with differing arrays")
  assertTrue(Full(a) != Empty, "different cases")
  val ra = Row.from(a)
  val rb = Row.from(b)
  val rc = Row.from(c)
  assertTrue(ra == rb and ra != rc, "a distinct type over an array")
  assertTrue(Holding(o = Some(a)) == Holding(o = Some(b)), "a record holding an Option of an array")
  assertTrue(Holding(o = Some(a)) != Holding(o = Some(c)), "a record with a differing Option of arrays")
  val xs: array[2, Option[array[2, Int]]] = [Some(a), None]
  val ys: array[2, Option[array[2, Int]]] = [Some(b), None]
  val zs: array[2, Option[array[2, Int]]] = [Some(c), None]
  assertTrue(xs == ys and xs != zs, "an array of Options of arrays")
}

test "toSlice copies an element that is an array" {
  var g: array[2, array[2, Int]] = [[1, 2], [3, 4]]
  val s = g.toSlice()
  g[0][0] = 99
  assertEqualInt(s[0][0], 1, "the slice owns its row")
}

test "an element of an array of records with an array field is written through" {
  val p = Pool()
  val i = 1
  p.items[i].hits[1] = 5
  p.items[i].hits[1] += 2
  assertEqualInt(p.items[1].hits[1], 7, "a field element of a record element")
  assertEqualInt(p.items[0].hits[1], 0, "no other element changed")
  var cs: array[2, Bucket]
  cs[i].hits[0] = 3
  assertEqualInt(cs[1].hits[0], 3, "through a var local")
}

test "an element of a generic record's array field is written through" {
  var src: array[3, Int] = [4, 5, 6]
  val c = Cell(v = src)
  c.v[2] = 7
  c.v[1] += 10
  src[0] = 9
  assertEqualInt(c.v[0], 4, "the field owns its copy")
  assertEqualInt(c.v[1], 15, "a compound write through the field")
  assertEqualInt(c.v[2], 7, "a write through the field")
  assertEqualInt(src[2], 6, "the source is unchanged")
}

test "a distinct type over an array is made from a bracket literal or an array" {
  var src: array[2, Int] = [8, 9]
  val g = Row.from([1, 2])
  val h = Row.from(src)
  src[0] = 0
  assertEqualInt(g.value[1], 2, "from a literal")
  assertEqualInt(h.value[0], 8, "from a copy of a var")
  assertEqualInt(g.value.length, 2, "the length")
}

func gridOf(row: in array[2, Int]): array[2, array[2, Int]] {
  var g: array[2, array[2, Int]] = [row, row]
  g[0][0] = 7
  g
}

test "a bracket literal of arrays copies each element array" {
  val a: array[2, Int] = [1, 2]
  var m: array[2, array[2, Int]] = [a, a]
  m[0][0] = 9
  assertEqualInt(a[0], 1, "the val the rows came from is unchanged")
  assertEqualInt(m[1][0], 1, "the rows do not share storage")
  var v: array[2, Int] = [3, 4]
  var n: array[2, array[2, Int]] = [v, v]
  n[1][1] = 8
  assertEqualInt(v[1], 4, "a var element is copied too")
  assertEqualInt(n[0][1], 4, "and its rows are distinct")
  val g = gridOf(a)
  assertEqualInt(a[0], 1, "an in parameter's array is not written")
  assertEqualInt(g[1][0], 1, "the second row is its own copy")
}

protected type HitTable {
  var hits: array[3, Int]
  entry hit(i: in Int): Int {
    hits[i] += 1
    hits[i]
  }
}

test "a protected type's array field with no default is zero filled" {
  val t = HitTable()
  assertEqualInt(t.hit(1), 1, "the first hit on a zeroed field")
  assertEqualInt(t.hit(1), 2, "the field keeps its writes")
  assertEqualInt(t.hit(2), 1, "another element starts at zero")
}

func totalOf[N: Nat](a: in array[N, Int]): Int {
  var t = 0
  for x in a {
    t = t + x
  }
  t
}

func doubledOf[N: Nat](a: in array[N, Int]): array[N, Int] {
  var r = a
  for i in 0 ..< N {
    r[i] = a[i] * 2
  }
  r
}

func countOf[T, N: Nat](a: in array[N, T]): Int = a.length

func sameArrays[N: Nat](a: in array[N, Int], b: in array[N, Int]): Bool = a == b

test "a value-generic length is bound by the argument's array" {
  val a: array[3, Int] = [1, 2, 3]
  val b: array[4, Int] = [5, 6, 7, 8]
  assertEqualInt(totalOf(a), 6, "N bound to 3")
  assertEqualInt(totalOf(b), 26, "N bound to 4")
  assertEqualInt(totalOf[3](a), 6, "an explicit length")
  val d = doubledOf(a)
  assertEqualInt(d.length, 3, "the result has the bound length")
  assertEqualInt(d[2], 6, "and the doubled elements")
  assertEqualInt(totalOf(doubledOf(b)), 52, "a result passed on")
  assertEqualInt(a[0], 1, "the argument is not written")
  val names: array[2, String] = ["x", "y"]
  assertEqualInt(countOf(names), 2, "a type and a value parameter together")
  assertEqualInt(countOf(b), 4, "the same generic at another length")
  assertTrue(sameArrays(d, doubledOf(a)), "== inside a value-generic body")
  assertFalse(sameArrays(a, d), "and !=")
}
