//! protected_byref_self_test.l — `out`/`inout` parameters of protected-type
//! members (#8184), on every target.
//!
//! A protected `entry` or `func` takes its `out`/`inout` arguments by
//! reference like any other method (docs/01 §5.2, §7.5): the caller passes
//! the place, the member reads and writes the parameter while it holds the
//! instance lock, and the place has the final value when the call returns.
//! Before the fix dotnet emitted the member's signature without the by-ref
//! (InvalidProgramException at the caller, and TypeLoadException for an
//! interface method implemented by a protected type), and native rejected
//! the declaration with N0007.  This file covers entries and funcs with
//! `inout` and `out` at `Int`, `String` and record types, named arguments in
//! and out of order (evaluated in source order, D171), a field, a nested
//! field, an array element (D179) and the caller's own `inout` parameter as
//! the place, receivers that are fields and array elements, a member passing
//! its own field or parameter on by reference, a `when:` barrier entry, a
//! generic protected type, an interface implemented by a protected type
//! called through the interface, and two threads calling one entry with
//! their own locals.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/protected_byref_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/protected_byref_self_test.l
//!   lyric test --target native lyric-compiler/lyric/protected_byref_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.ProtectedByrefSelfTest

import Std.Core
import Std.Collections
import Std.Task
import Std.Testing

val trace: List[String] = newList()

func note(s: in String, v: in Int): Int {
  trace.add(s)
  v
}

// The evaluations logged since `start`, comma-separated.
func since(start: in Int): String {
  var acc = ""
  var i = start
  while i < trace.count {
    acc = if acc.length == 0 { trace[i] } else { acc + "," + trace[i] }
    i = i + 1
  }
  acc
}

record Pt {
  x: Int
  y: Int
}

record Cell {
  var f: Int
}

record Nest {
  var c: Cell
}

func addTo(x: inout Int, d: in Int): Unit {
  x = x + d
}

func setInt(x: out Int, v: in Int): Unit {
  x = v
}

protected type Counter {
  var total: Int = 0
  var log: String = ""
  // The issue's shape: adds `b` to the total and to `x`.
  entry addOut(x: inout Int, b: in Int): Int {
    total = total + b
    x = x + b
    total
  }
  entry takeTotal(x: out Int): Unit {
    x = total
  }
  entry tag(s: inout String, t: out String): Unit {
    log = log + s
    s = s + "!"
    t = log
  }
  entry movePt(p: inout Pt, d: in Int, was: out Pt): Unit {
    was = p
    p = Pt(x = p.x + d, y = p.y + d)
    total = total + d
  }
  func peek(x: out Int, s: inout String): Bool {
    x = total
    s = s + log
    total > 0
  }
  // Passes its own field on by reference, and its own parameter.
  entry bumpField(d: in Int): Int {
    addTo(total, d)
    total
  }
  entry twice(x: inout Int): Unit {
    addOut(x, 1)
    addTo(x, x)
  }
  func current(): Int = total
}

record Holder {
  c: Counter
  var k: Int
}

// The example in book chapter 10.
protected type Account {
  var balance: Int = 0
  entry withdraw(amount: in Int, taken: out Int): Bool {
    if amount > balance {
      taken = 0
      return false
    }
    balance = balance - amount
    taken = amount
    true
  }
}

protected type Slot {
  var full: Bool = false
  var item: Int = 0
  entry put(x: in Int): Unit
    when: not full
  {
    item = x
    full = true
  }
  // Waits for an item and moves it into `x`.
  entry takeInto(x: out Int, tag: inout String): Unit
    when: full
  {
    x = item
    full = false
    tag = tag + "+"
  }
}

protected type Store[T] {
  var v: T
  var hits: Int = 0
  // Passes its own field on by reference, bare and through `self`.
  entry hit(d: in Int): Int {
    addTo(hits, d)
    addTo(self.hits, d)
    hits
  }
  entry resetHits(): Unit {
    setInt(self.hits, 0)
  }
  // Swaps the stored value with `x`.
  entry swap(x: inout T): Unit {
    val prev = v
    v = x
    x = prev
  }
  func read(x: out T): Unit {
    x = v
  }
}

interface Sink {
  func put(self: in Self, x: inout Int, j: in Int): Unit
  func get(self: in Self, x: out Int, s: inout String): Int
}

protected type Bucket {
  var n: Int = 0
}

impl Sink for Bucket {
  func put(self: in Self, x: inout Int, j: in Int): Unit {
    n = n + j
    x = n
  }

  func get(self: in Self, x: out Int, s: inout String): Int {
    x = n
    s = s + "#"
    n * 2
  }
}

func throughSink(k: in Sink, y: inout Int, s: inout String): Int {
  k.put(y, 3)
  var w = 0
  val r = k.get(s = s, x = w)
  r * 1000 + w
}

func viaParam(c: in Counter, q: inout Int): Unit {
  c.addOut(q, 2)
  c.twice(q)
}

func addMany(c: in Counter, mine: inout Int): Unit {
  var i = 0
  while i < 500 {
    c.addOut(mine, 1)
    i = i + 1
  }
}

test "an entry with an inout Int, the issue's repro" {
  val c = Counter()
  var x = 1
  val t = c.addOut(x, 5)
  assertEqualInt(x, 6, "x")
  assertEqualInt(t, 5, "total")
  val t2 = c.addOut(x, 4) + 100
  assertEqualInt(x, 10, "x again")
  assertEqualInt(t2, 109, "in expression position")
}

test "an entry with an out Int" {
  val c = Counter(total = 42)
  var x = 0
  c.takeTotal(x)
  assertEqualInt(x, 42, "out")
}

test "inout and out String arguments" {
  val c = Counter()
  var s = "a"
  var t = ""
  c.tag(s, t)
  assertEqual(s, "a!", "inout")
  assertEqual(t, "a", "out")
  c.tag(s, t)
  assertEqual(s, "a!!", "inout again")
  assertEqual(t, "aa!", "out again")
}

test "inout and out record arguments" {
  val c = Counter()
  var p = Pt(x = 1, y = 2)
  var o = Pt(x = 0, y = 0)
  c.movePt(p, 10, o)
  assertEqualInt(p.x, 11, "inout x")
  assertEqualInt(p.y, 12, "inout y")
  assertEqualInt(o.x, 1, "out x")
  assertEqualInt(o.y, 2, "out y")
  assertEqualInt(c.current(), 10, "total")
}

test "a protected func with out and inout arguments" {
  val c = Counter(total = 3, log = "L")
  var x = 0
  var s = "s:"
  assertTrue(c.peek(x, s), "result")
  assertEqualInt(x, 3, "out")
  assertEqual(s, "s:L", "inout")
}

test "named arguments in and out of order, in source order" {
  val c = Counter()
  var x = 0
  c.addOut(x = x, b = 1)
  assertEqualInt(x, 1, "in order")
  c.addOut(b = 2, x = x)
  assertEqualInt(x, 3, "out of order")
  var o = Pt(x = 0, y = 0)
  var p = Pt(x = 5, y = 5)
  c.movePt(was = o, d = 1, p = p)
  assertEqualInt(o.x, 5, "out, out of order")
  assertEqualInt(p.x, 6, "inout, out of order")
  val start = trace.count
  var arr: array[3, Int] = [1, 2, 3]
  c.addOut(b = note("b", 10), x = arr[note("i", 1)])
  assertEqualInt(arr[1], 12, "element, named out of order")
  assertEqual(since(start), "b,i", "order")
}

test "an argument reading the by-reference place sees its value before the call" {
  val c = Counter()
  var x = 5
  c.addOut(b = x, x = x)
  assertEqualInt(x, 10, "b read before the call")
}

test "a field, a nested field and an array element as the place" {
  val c = Counter()
  var cell = Cell(f = 1)
  c.addOut(cell.f, 2)
  assertEqualInt(cell.f, 3, "field")
  var n = Nest(c = Cell(f = 0))
  c.addOut(n.c.f, 4)
  assertEqualInt(n.c.f, 4, "nested field")
  var arr: array[3, Int] = [1, 2, 3]
  var i = 2
  c.addOut(arr[i], 5)
  assertEqualInt(arr[2], 8, "element, computed index")
  c.takeTotal(arr[0])
  assertEqualInt(arr[0], 11, "out element")
  assertEqualInt(arr[1], 2, "other element untouched")
  var strs: array[2, String] = ["p", "q"]
  var t = ""
  c.tag(strs[1], t)
  assertEqual(strs[1], "q!", "String element")
  assertEqual(strs[0], "p", "other String element untouched")
}

test "the caller's inout parameter as the place" {
  val c = Counter()
  var y = 0
  viaParam(c, y)
  // addOut adds 2 (y = 2), twice adds 1 (y = 3) and doubles (y = 6).
  assertEqualInt(y, 6, "viaParam")
}

test "a member passing its own field and parameter on by reference" {
  val c = Counter(total = 1)
  assertEqualInt(c.bumpField(4), 5, "own field")
  var x = 10
  c.twice(x)
  assertEqualInt(x, 22, "own parameter")
  assertEqualInt(c.current(), 6, "total")
}

test "receivers that are fields and array elements" {
  var h = Holder(c = Counter(), k = 1)
  h.c.addOut(h.k, 7)
  assertEqualInt(h.k, 8, "a sibling field as the place")
  assertEqualInt(h.c.current(), 7, "receiver field")
  val cs: array[2, Counter] = [Counter(), Counter(total = 100)]
  var ks: array[2, Int] = [0, 0]
  cs[1].addOut(ks[0], 3)
  assertEqualInt(ks[0], 3, "argument element")
  assertEqualInt(cs[1].current(), 103, "receiver element")
  assertEqualInt(cs[0].current(), 0, "other receiver untouched")
}

test "an out parameter written on an early return" {
  val acct = Account(balance = 80)
  var got = -1
  assertTrue(acct.withdraw(50, got), "first withdrawal")
  assertEqualInt(got, 50, "taken")
  assertFalse(acct.withdraw(50, got), "second withdrawal")
  assertEqualInt(got, 0, "taken on the early return")
}

test "a when: barrier entry with by-reference parameters" {
  val s = Slot()
  s.put(7)
  var got = 0
  var tag = "t"
  s.takeInto(got, tag)
  assertEqualInt(got, 7, "out")
  assertEqual(tag, "t+", "inout")
  val sc = makeScope()
  var sum = 0
  var tags = ""
  scopeSpawn(sc, { -> var i = 1; while i <= 50 { s.put(i); i = i + 1 } })
  var j = 0
  while j < 50 {
    var v = 0
    s.takeInto(v, tags)
    sum = sum + v
    j = j + 1
  }
  val r = await awaitAll(sc)
  assertEqualInt(sum, 1275, "every item taken exactly once")
  assertEqualInt(tags.length, 50, "one tag per take")
}

test "a generic protected type at value, String and record types" {
  val si = Store(v = 1)
  var x = 2
  si.swap(x)
  assertEqualInt(x, 1, "Int swapped out")
  var y = 0
  si.read(y)
  assertEqualInt(y, 2, "Int read")
  val ss = Store(v = "a")
  var s = "b"
  ss.swap(s)
  assertEqual(s, "a", "String swapped out")
  var t = ""
  ss.read(t)
  assertEqual(t, "b", "String read")
  val sp = Store(v = Pt(x = 1, y = 1))
  var p = Pt(x = 2, y = 2)
  sp.swap(p)
  assertEqualInt(p.x, 1, "record swapped out")
  var q = Pt(x = 0, y = 0)
  sp.read(q)
  assertEqualInt(q.y, 2, "record read")
}

test "a generic protected type passing its own field on by reference" {
  val si = Store(v = 1)
  assertEqualInt(si.hit(2), 4, "bare and self.hits, Int instance")
  assertEqualInt(si.hit(1), 6, "again")
  si.resetHits()
  assertEqualInt(si.hit(0), 0, "out through self.hits")
  val ss = Store(v = "a")
  assertEqualInt(ss.hit(5), 10, "String instance")
  var t = ""
  ss.read(t)
  assertEqual(t, "a", "the T field is untouched")
}

test "an interface implemented by a protected type, called through the interface" {
  val b = Bucket()
  var y = 0
  b.put(y, 1)
  assertEqualInt(y, 1, "direct")
  b.put(j = 2, x = y)
  assertEqualInt(y, 3, "direct, named")
  var s = "a"
  assertEqualInt(throughSink(b, y, s), 12006, "through the interface")
  assertEqualInt(y, 6, "inout through the interface")
  assertEqual(s, "a#", "inout String through the interface")
  val k: Sink = b
  var arr: array[2, Int] = [0, 0]
  k.put(arr[1], 4)
  assertEqualInt(arr[1], 10, "element through the interface")
}

test "two threads call one entry with their own locals" {
  val c = Counter()
  val sc = makeScope()
  val mineA: List[Int] = newList()
  val mineB: List[Int] = newList()
  scopeSpawn(sc, { -> var a = 0; addMany(c, a); mineA.add(a) })
  scopeSpawn(sc, { -> var b = 1000; addMany(c, b); mineB.add(b) })
  val r = await awaitAll(sc)
  assertEqualInt(c.current(), 1000, "no lost update")
  assertEqualInt(mineA[0], 500, "first thread's local")
  assertEqualInt(mineB[0], 1500, "second thread's local")
}
