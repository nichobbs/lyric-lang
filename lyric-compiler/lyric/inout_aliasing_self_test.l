//! inout_aliasing_self_test.l — an `out`/`inout` parameter refers to the
//! caller's place itself (D183, #8263), on every target.
//!
//! When the place passed to an `out`/`inout` parameter is also reachable from
//! inside the callee — a field of an object the callee was also given, a
//! field of the protected object whose member is running, the same place
//! passed twice — a write the callee makes through either path is seen
//! through the other at once.  Before #8263 the JVM copied the place into a
//! holder before the call and back after it, so the later write was lost
//! (`bump(r.f, r)` gave 1, not 2), and a protected member's place was copied
//! back after its lock was released, losing concurrent updates.  An array
//! element is the one place passed by copy in and copy out (D179); the last
//! case pins that exception.  The cases a lambda takes part in (a closure the
//! callee calls that writes the caller's local, and a callee that panics
//! after writing) are in `inout_aliasing_closure_self_test.l`, since native
//! closures capture values (#7891) and native has no `try`.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/inout_aliasing_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/inout_aliasing_self_test.l
//!   lyric test --target native lyric-compiler/lyric/inout_aliasing_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.InoutAliasingSelfTest

import Std.Core
import Std.Collections
import Std.Task
import Std.Testing

record R {
  var f: Int
}

record Nest {
  var c: R
}

record Deep {
  var n: Nest
}

record Pt {
  x: Int
  y: Int
}

record PtHolder {
  var p: Pt
}

record Words {
  var s: String
}

record Kinds {
  var l: Long
  var d: Double
  var b: Bool
  var y: Byte
}

record Acc {
  var k: Int

  // `x` names `self.k` when the call passes `a.k` on `a`.
  func addBoth(self: in Acc, x: inout Int): Int {
    x = x + 1
    self.k = self.k + 1
    x
  }
}

interface Bumper {
  func bumpBoth(self: in Self, x: inout Int, r: in R): Int
}

record PlainBumper {
  step: Int
}

impl Bumper for PlainBumper {
  func bumpBoth(self: in Self, x: inout Int, r: in R): Int {
    x = x + step
    r.f = r.f + step
    x
  }
}

record Num {
  n: Int
}

record NumHolder {
  var v: Num
}

interface Stepper {
  func stepInto(self: in Self, x: inout Self, h: in NumHolder): Int
}

// `x` is erased to the interface slot's type; it still names `h.v`.
impl Stepper for Num {
  func stepInto(self: in Self, x: inout Self, h: in NumHolder): Int {
    x = Num(n = x.n + 1)
    h.v = Num(n = h.v.n + 10)
    x.n
  }
}

func addThenRead(y: inout Int, d: in Int): Int {
  y = y + d
  y
}

// A spawned task is joined before the function returns, so it may pass the
// caller's place on.
func spawnBump(x: inout Int): Int {
  scope {
    val t = spawn addThenRead(x, 5)
    val r = await t
    return r + x
  }
}

// A local declared in a module initialiser, a field default, a default
// argument or a range bound is passed by reference like any other (the JVM
// hoists it wherever its block is lowered).
func bumpOne(x: inout Int): Unit {
  x = x + 1
}

func nxt(x: inout Int): Int {
  x = x + 1
  x
}

val initialised: Int = if true { var t = 40; bumpOne(t); t } else { 0 }

record Defaulted {
  var f: Int = if true { var u = 7; bumpOne(u); u } else { 0 }
}

func withDefault(a: in Int = if true { var w = 3; bumpOne(w); w } else { 0 }): Int = a

// The lambda holds the value `x` had when it was created.
func captureThenWrite(x: inout Int): Int {
  val g = { -> x }
  x = 5
  g()
}

// The issue's first repro: `x` and `r.f` are one place.
func bump(x: inout Int, r: in R): Unit {
  x = x + 1
  r.f = r.f + 1
}

func readAfterOtherWrite(x: inout Int, r: in R): Int {
  r.f = 40
  x
}

func writeThenReadOther(x: inout Int, r: in R): Int {
  x = 7
  r.f
}

func setOut(x: out Int, r: in R): Int {
  x = 5
  r.f
}

func twoRefs(a: inout Int, b: inout Int): Int {
  a = a + 1
  b = b + 10
  a
}

func nestBump(x: inout Int, d: in Deep): Int {
  x = x + 1
  d.n.c.f = d.n.c.f + 100
  x
}

func fwdOuter(x: inout Int, r: in R): Int {
  fwdInner(x, r)
  x
}

func fwdInner(y: inout Int, r: in R): Unit {
  y = y + 1
  r.f = r.f * 10
}

func appendBoth(s: inout String, w: in Words): String {
  s = s + "a"
  w.s = w.s + "b"
  s
}

func movePt(p: inout Pt, h: in PtHolder): Int {
  p = Pt(x = 1, y = 1)
  h.p = Pt(x = h.p.x + 10, y = 0)
  p.x
}

func longAlias(l: inout Long, k: in Kinds): Long {
  l = l + 1i64
  k.l = k.l + 1i64
  l
}

func doubleAlias(d: inout Double, k: in Kinds): Double {
  d = d + 0.5
  k.d = k.d + 0.25
  d
}

func boolAlias(b: inout Bool, k: in Kinds): Bool {
  b = not b
  k.b = not k.b
  b
}

func byteAlias(y: inout Byte, k: in Kinds): Int {
  y = (y.toInt() + 1).toByte()
  k.y = (k.y.toInt() + 2).toByte()
  y.toInt()
}

// `x` and `y` name one place.
func genericAlias[T](x: inout T, y: inout T, v: in T): T {
  y = v
  x
}

func addTo(x: inout Int, d: in Int): Unit {
  x = x + d
}

func elemAlias(x: inout Int, a: inout array[3, Int]): Int {
  x = x + 1
  a[0] = a[0] + 100
  x
}

protected type Counter {
  var total: Int = 0
  // Adds `b` to the total and to `x`.
  entry addOut(x: inout Int, b: in Int): Int {
    total = total + b
    x = x + b
    total
  }
  // The issue's second repro: its own field as the place.
  entry selfAlias(): Int {
    addOut(total, 1)
    total
  }
  // Passes its own field to a function outside the type.
  entry bumpField(): Unit {
    addTo(total, 1)
  }
  func current(): Int = total
}

func addManyOutside(c: in Counter, n: in Int): Unit {
  var i = 0
  while i < n {
    c.addOut(c.total, 1)
    i = i + 1
  }
}

func bumpManyInside(c: in Counter, n: in Int): Unit {
  var i = 0
  while i < n {
    c.bumpField()
    i = i + 1
  }
}

test "a field passed by reference beside its object (the issue's bump(r.f, r))" {
  val r = R(f = 0)
  bump(r.f, r)
  assertEqualInt(r.f, 2, "both writes kept")
}

test "a protected member passes its own field to a sibling member" {
  val c = Counter()
  assertEqualInt(c.selfAlias(), 2, "selfAlias")
}

test "a protected field passed from outside to the protected member" {
  val c = Counter(total = 3)
  c.addOut(c.total, 3)
  assertEqualInt(c.current(), 9, "c.addOut(c.total, 3)")
}

test "a read through the parameter sees a write through another path" {
  val r = R(f = 1)
  assertEqualInt(readAfterOtherWrite(r.f, r), 40, "read after the field write")
}

test "a write through the parameter is seen through another path at once" {
  val r = R(f = 1)
  assertEqualInt(writeThenReadOther(r.f, r), 7, "field read after the parameter write")
  assertEqualInt(r.f, 7, "after the call")
}

test "an out parameter refers to the place" {
  val r = R(f = 0)
  assertEqualInt(setOut(r.f, r), 5, "out write seen through the object")
  var x = 1
  val seen = setOut(x, R(f = 3))
  assertEqualInt(x, 5, "out local")
  assertEqualInt(seen, 3, "other argument")
}

test "one place passed to two parameters" {
  var x = 0
  assertEqualInt(twoRefs(x, x), 11, "a sees b's write")
  assertEqualInt(x, 11, "local")
  val r = R(f = 0)
  assertEqualInt(twoRefs(r.f, r.f), 11, "field twice")
  assertEqualInt(r.f, 11, "field")
}

test "a nested field path" {
  val d = Deep(n = Nest(c = R(f = 1)))
  assertEqualInt(nestBump(d.n.c.f, d), 102, "nested")
  assertEqualInt(d.n.c.f, 102, "after the call")
}

test "a parameter passed on by reference stays the caller's place" {
  val r = R(f = 1)
  assertEqualInt(fwdOuter(r.f, r), 20, "forwarded")
  assertEqualInt(r.f, 20, "after the call")
}

test "String and record places" {
  val w = Words(s = "")
  assertEqual(appendBoth(w.s, w), "ab", "String")
  assertEqual(w.s, "ab", "String after the call")
  val h = PtHolder(p = Pt(x = 0, y = 0))
  assertEqualInt(movePt(h.p, h), 11, "record")
  assertEqualInt(h.p.x, 11, "record after the call")
}

test "Long, Double, Bool and Byte places" {
  val k = Kinds(l = 1i64, d = 1.0, b = false, y = 3.toByte())
  assertTrue(longAlias(k.l, k) == 3i64, "Long")
  assertTrue(doubleAlias(k.d, k) == 1.75, "Double")
  assertFalse(boolAlias(k.b, k), "Bool")
  assertEqualInt(byteAlias(k.y, k), 6, "Byte")
  assertEqualInt(k.y.toInt(), 6, "Byte after the call")
}

test "a generic parameter refers to the place" {
  val r = R(f = 1)
  assertEqualInt(genericAlias(r.f, r.f, 9), 9, "Int field")
  var n = 1
  assertEqualInt(genericAlias(n, n, 8), 8, "Int local")
  val w = Words(s = "a")
  assertEqual(genericAlias(w.s, w.s, "z"), "z", "String field")
}

test "a method's parameter naming a field of its own receiver" {
  val a = Acc(k = 0)
  assertEqualInt(a.addBoth(a.k), 2, "through the parameter, after the receiver write")
  assertEqualInt(a.k, 2, "after the call")
}

test "an interface method's parameter refers to the place" {
  val r = R(f = 1)
  val bp: Bumper = PlainBumper(step = 2)
  assertEqualInt(bp.bumpBoth(r.f, r), 5, "through the interface")
  assertEqualInt(r.f, 5, "after the call")
}

test "an inout Self parameter refers to the place" {
  val h = NumHolder(v = Num(n = 0))
  assertEqualInt(h.v.stepInto(h.v, h), 11, "a field")
  assertEqualInt(h.v.n, 11, "the field after the call")
  var m = Num(n = 3)
  val other = NumHolder(v = Num(n = 0))
  assertEqualInt(m.stepInto(m, other), 4, "a local")
  assertEqualInt(m.n, 4, "the local after the call")
}

test "a lambda captures an out/inout parameter's value" {
  var x = 1
  assertEqualInt(captureThenWrite(x), 1, "the value when the lambda was created")
  assertEqualInt(x, 5, "the place")
}

test "a local passed by reference in a range bound, an initialiser and a default" {
  var n = 2
  var s = 0
  for i in 0 ..< nxt(n) {
    s = s + i
  }
  assertEqualInt(n, 3, "the range bound's call wrote n")
  assertEqualInt(s, 3, "0 + 1 + 2")
  var m = 0
  var c = 0
  for j in nxt(m) ..= nxt(m) {
    c = c + j
  }
  assertEqualInt(c, 3, "1 ..= 2")
  assertEqualInt(initialised, 41, "a module val initialiser")
  assertEqualInt(Defaulted().f, 8, "a field default")
  assertEqualInt(withDefault(), 4, "a default argument")
}

test "a spawned task passes the caller's place on" {
  var x = 1
  assertEqualInt(spawnBump(x), 12, "the task's write is seen by the function")
  assertEqualInt(x, 6, "the caller")
}

test "a protected field passed from outside, by concurrent callers" {
  val c = Counter()
  val sc = makeScope()
  scopeSpawn(sc, { -> addManyOutside(c, 300) })
  scopeSpawn(sc, { -> addManyOutside(c, 300) })
  scopeSpawn(sc, { -> addManyOutside(c, 300) })
  val r = await awaitAll(sc)
  // Each call adds 1 to the total and 1 through `x`, which is the total.
  assertEqualInt(c.current(), 1800, "no lost update")
}

test "a protected member passing its own field on, by concurrent callers" {
  val c = Counter()
  val sc = makeScope()
  scopeSpawn(sc, { -> bumpManyInside(c, 300) })
  scopeSpawn(sc, { -> bumpManyInside(c, 300) })
  scopeSpawn(sc, { -> bumpManyInside(c, 300) })
  val r = await awaitAll(sc)
  assertEqualInt(c.current(), 900, "no lost update")
}

test "an array element is copied in and copied out (D179)" {
  var a: array[3, Int] = [1, 2, 3]
  // The callee's write through the array is overwritten by the element's
  // store back when the call returns.
  assertEqualInt(elemAlias(a[0], a), 2, "the element's temporary")
  assertEqualInt(a[0], 2, "the store back is the last write")
  assertEqualInt(a[1], 2, "other element untouched")
}
