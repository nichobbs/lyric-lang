//! A call evaluates its receiver first, then its arguments exactly once,
//! left to right as written, then the defaults of the parameters it leaves
//! out, and passes the values in parameter order (#8158, D171).
//!
//! Every backend used to evaluate the arguments in parameter order, so
//! `two(b = pos(x), a = zero(x))` ran `zero(x)` first and `pos` saw `x = 0`.
//! The type checker now records each call whose arguments, written out of
//! parameter order, would run observably differently, and
//! `Lyric.Mono.desugarCheckedFile` evaluates them into temporaries in source
//! order before the call, so every backend inherits the order.  Each case
//! logs every evaluation to `trace` and checks the order it ran in, for every
//! callee shape: free, generic, record-body, `impl`, interface, dot-named,
//! protected-type and restored (stdlib) callees, record, exposed-record,
//! generic-record and union-case constructors, and `.copy`.
//!
//! Every case runs on dotnet, the JVM and native.
@test_module
package NamedArgEvalOrderSelfTest

import Std.Core
import Std.Collections
import Std.String as Str
import Std.Testing

val trace: List[String] = newList()

func note(s: in String, v: in Int): Int {
  trace.add(s)
  v
}

func noteStr(s: in String, v: in String): String {
  trace.add(s)
  v
}

func noteSome(s: in String, v: in Int): Option[Int] {
  trace.add(s)
  Some(value = v)
}

func noteOk(s: in String, v: in Int): Result[Int, String] {
  trace.add(s)
  Ok(value = v)
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

func two(a: in Int, b: in Int): Int {
  a * 10 + b
}

func three(a: in Int, b: in Int, c: in Int): Int {
  a * 100 + b * 10 + c
}

func mid(a: in Int, d: in Int = note("d", 4), b: in Int): Int {
  a * 100 + d * 10 + b
}

func literalDefault(a: in Int, d: in Int = 4, b: in Int): Int {
  a * 100 + d * 10 + b
}

func wide(a: in Long, b: in Long): Long {
  a * 10i64 + b
}

func opts(a: in Option[Int], b: in Option[Int]): Int {
  match a {
    case Some(x) -> match b { case Some(y) -> x * 10 + y; case None -> x * 10 }
    case None -> -1
  }
}

func pick[T](first: in T, second: in T, takeSecond: in Bool): T {
  if takeSecond {
    second
  } else {
    first
  }
}

func zero(x: inout Int): Int {
  x = 0
  0
}

func pos(x: in Int): Int
  requires: x > 0
{
  x
}

func bump(x: inout Int, by: in Int): Int {
  x = x + by
  x
}

record Pair {
  a: Int
  b: Int
}

record Tagged {
  a: Int
  tag: String = noteStr("tag", "t")
  b: Int
}

exposed record Wire {
  a: Int
  b: Int
}

record Box[T] {
  first: T
  second: T
}

union Shape {
  case Rect(w: Int, h: Int)
  case Dot
}

union Tagged2[T] {
  case Both(left: T, right: T)
  case Neither
}

record Acc {
  n: Int

  func mix(self: in Acc, a: in Int, b: in Int): Int {
    self.n + a * 10 + b
  }

  func mixD(self: in Acc, a: in Int, d: in Int = note("d", 4), b: in Int): Int {
    self.n + a * 100 + d * 10 + b
  }

  func viaSibling(self: in Acc): Int {
    mix(b = note("b", 2), a = note("a", 1))
  }
}

func Acc.scaled(self: in Acc, k: in Int, j: in Int): Int {
  self.n * k + j
}

func mkAcc(n: in Int): Acc {
  trace.add("recv")
  Acc(n = n)
}

interface Sizer {
  func size(self: in Self, a: in Int, b: in Int): Int

  func sized(self: in Self, b: in Int, a: in Int): Int {
    self.size(b = b, a = a)
  }
}

record Sq {
  s: Int
}

impl Sizer for Sq {
  func size(self: in Sq, a: in Int, b: in Int): Int {
    self.s + a * 10 + b
  }
}

protected type Counter {
  var total: Int = 0
  entry add2(a: in Int, b: in Int): Int {
    total = total + a * 10 + b
    total
  }
}

async func noteAsync(s: in String, v: in Int): Int {
  trace.add(s)
  v
}

async func viaAwait(): Int {
  two(b = await noteAsync("b", 2), a = note("a", 1))
}

func bytes(a: in Byte, b: in Int): Int {
  a.toInt() * 10 + b
}

func viaPropagate(): Result[Int, String] {
  val r = two(b = noteOk("b", 2)?, a = note("a", 1))
  Ok(value = r)
}

// The reordered call is itself an operand evaluated after another one.
func nestedPropagate(): Result[Int, String] {
  val r = two(note("x", 1), two(b = noteOk("b", 2)?, a = note("a", 1)))
  Ok(value = r)
}

async func nestedAwait(): Int {
  two(note("x", 1), two(b = await noteAsync("b", 2), a = note("a", 1)))
}

func logBoth(a: in Int, b: in Int): Unit {
  trace.add("call" + toString(a) + toString(b))
}

// ─── Free functions ──────────────────────────────────────────────────────────
test "named arguments run in source order, not parameter order" {
  val t0 = trace.count
  val r = two(b = note("b", 2), a = note("a", 1))
  assertEqualInt(r, 12, "value")
  assertEqual(since(t0), "b,a", "order")
}

test "an inout argument's effect is seen only by the arguments after it" {
  var x = 1
  val r = two(b = pos(x), a = zero(x))
  assertEqualInt(r, 1, "pos saw x = 1")
  assertEqualInt(x, 0, "zero ran")
}

test "a variable read before a later argument changes it keeps its value" {
  var x = 1
  val r = two(b = x, a = zero(x))
  assertEqualInt(r, 1, "b read x before zero(x)")
  var y = 1
  val s = two(b = y, a = bump(y, 5))
  assertEqualInt(s, 61, "b = 1, a = 6")
}

test "positional and named arguments mix in source order" {
  val t0 = trace.count
  val r = three(note("x", 1), c = note("c", 3), b = note("b", 2))
  assertEqualInt(r, 123, "value")
  assertEqual(since(t0), "x,c,b", "order")
  val t1 = trace.count
  val s = three(c = note("c", 3), note("y", 2), a = note("a", 1))
  assertEqualInt(s, 123, "positional fills the free parameter")
  assertEqual(since(t1), "c,y,a", "order with a positional after a named argument")
}

test "an omitted default runs after every explicit argument" {
  val t0 = trace.count
  val r = mid(a = note("a", 1), b = note("b", 2))
  assertEqualInt(r, 142, "value")
  assertEqual(since(t0), "a,b,d", "default last")
  val t1 = trace.count
  val s = mid(b = note("b", 2), a = note("a", 1))
  assertEqualInt(s, 142, "value reordered")
  assertEqual(since(t1), "b,a,d", "explicit in source order, default last")
  val t2 = trace.count
  val u = literalDefault(b = note("b", 2), a = note("a", 1))
  assertEqualInt(u, 142, "literal default")
  assertEqual(since(t2), "b,a", "order with a literal default")
}

test "arguments widened to their parameters run in source order" {
  val t0 = trace.count
  val r = wide(b = note("b", 2), a = note("a", 1))
  assertEqualLong(r, 12i64, "value")
  assertEqual(since(t0), "b,a", "order")
}

test "generic-typed arguments run in source order" {
  val t0 = trace.count
  val r = opts(b = noteSome("b", 2), a = noteSome("a", 1))
  assertEqualInt(r, 12, "option value")
  assertEqual(since(t0), "b,a", "option order")
  val t1 = trace.count
  val p = pick(second = noteStr("second", "s"), takeSecond = true, first = noteStr("first", "f"))
  assertEqual(p, "s", "generic value")
  assertEqual(since(t1), "second,first", "generic order")
}

test "nested calls each run their own arguments in source order" {
  val t0 = trace.count
  val r = two(b = two(b = note("bb", 1), a = note("ba", 2)), a = note("a", 3))
  assertEqualInt(r, 51, "value")
  assertEqual(since(t0), "bb,ba,a", "order")
}

test "a reordered call under a short-circuit, a branch or a loop runs only when reached" {
  val t0 = trace.count
  val skipped = false and two(b = note("b", 2), a = note("a", 1)) > 0
  assertFalse(skipped, "and")
  assertEqual(since(t0), "", "the right operand never ran")
  val t1 = trace.count
  val v = if trace.count < 0 {
    two(b = note("x", 0), a = note("y", 0))
  } else {
    two(b = note("b", 2), a = note("a", 1))
  }
  assertEqualInt(v, 12, "branch value")
  assertEqual(since(t1), "b,a", "only the taken branch ran")
  val t2 = trace.count
  var i = 0
  while two(b = note("b", i), a = note("a", 0)) < 2 {
    i = i + 1
  }
  assertEqual(since(t2), "b,a,b,a,b,a", "the condition ran on every iteration")
}

test "an argument with await runs in source order" {
  val t0 = trace.count
  assertEqualInt(await viaAwait(), 12, "value")
  assertEqual(since(t0), "b,a", "order")
  val t1 = trace.count
  assertEqualInt(await nestedAwait(), 22, "nested value")
  assertEqual(since(t1), "x,b,a", "nested order")
}

test "a reordered call runs in source order as a statement, in a lambda and in a string" {
  val t0 = trace.count
  logBoth(b = note("b", 2), a = note("a", 1))
  assertEqual(since(t0), "b,a,call12", "statement")
  val t1 = trace.count
  val f = { k: Int -> two(b = note("b", k), a = note("a", 1)) }
  assertEqualInt(f(2), 12, "lambda value")
  assertEqual(since(t1), "b,a", "lambda order")
  val t2 = trace.count
  val s = "v=${two(b = note("b", 2), a = note("a", 1))}"
  assertEqual(s, "v=12", "interpolated value")
  assertEqual(since(t2), "b,a", "interpolated order")
}

test "a narrower argument runs in source order" {
  val t0 = trace.count
  val r = bytes(b = note("b", 2), a = note("a", 1).toByte())
  assertEqualInt(r, 12, "value")
  assertEqual(since(t0), "b,a", "order")
}

test "an argument with ? runs in source order" {
  val t0 = trace.count
  match viaPropagate() {
    case Ok(v) -> assertEqualInt(v, 12, "value")
    case Err(e) -> assertTrue(false, "unexpected error " + e)
  }
  assertEqual(since(t0), "b,a", "order")
  val t1 = trace.count
  match nestedPropagate() {
    case Ok(v) -> assertEqualInt(v, 22, "nested value")
    case Err(e) -> assertTrue(false, "unexpected error " + e)
  }
  assertEqual(since(t1), "x,b,a", "nested order")
}

// ─── Methods ─────────────────────────────────────────────────────────────────
test "a record method's receiver runs first, then its arguments in source order" {
  val t0 = trace.count
  val r = mkAcc(100).mix(b = note("b", 2), a = note("a", 1))
  assertEqualInt(r, 112, "value")
  assertEqual(since(t0), "recv,b,a", "order")
  val t1 = trace.count
  val acc = Acc(n = 100)
  assertEqualInt(acc.viaSibling(), 112, "bare sibling call")
  assertEqual(since(t1), "b,a", "sibling order")
  val t2 = trace.count
  assertEqualInt(acc.mixD(b = note("b", 2), a = note("a", 1)), 242, "omitted middle default")
  assertEqual(since(t2), "b,a,d", "method default last")
}

test "a dot-named function's arguments run in source order" {
  val t0 = trace.count
  val r = mkAcc(5).scaled(j = note("j", 1), k = note("k", 2))
  assertEqualInt(r, 11, "value")
  assertEqual(since(t0), "recv,j,k", "order")
}

test "impl and interface methods run their arguments in source order" {
  val t0 = trace.count
  val sq = Sq(s = 100)
  assertEqualInt(sq.size(b = note("b", 2), a = note("a", 1)), 112, "impl value")
  assertEqual(since(t0), "b,a", "impl order")
  val t1 = trace.count
  val sz: Sizer = sq
  assertEqualInt(sz.size(b = note("b", 2), a = note("a", 1)), 112, "interface value")
  assertEqual(since(t1), "b,a", "interface order")
  val t2 = trace.count
  assertEqualInt(sz.sized(a = note("a", 1), b = note("b", 2)), 112, "interface default method value")
  assertEqual(since(t2), "a,b", "interface default method order")
}

test "a protected-type entry's arguments run in source order" {
  val t0 = trace.count
  val c = Counter()
  assertEqualInt(c.add2(b = note("b", 2), a = note("a", 1)), 12, "value")
  assertEqual(since(t0), "b,a", "order")
}

test "a restored callee's arguments run in source order" {
  val t0 = trace.count
  val r = Str.substring(count = note("count", 2), start = note("start", 1), s = noteStr("s", "hello"))
  assertEqual(r, "el", "value")
  assertEqual(since(t0), "count,start,s", "order")
}

// ─── Constructors ────────────────────────────────────────────────────────────
test "a record constructor's fields run in source order" {
  val t0 = trace.count
  val p = Pair(b = note("b", 2), a = note("a", 1))
  assertEqualInt(p.a * 10 + p.b, 12, "value")
  assertEqual(since(t0), "b,a", "order")
  val t1 = trace.count
  val t = Tagged(b = note("b", 2), a = note("a", 1))
  assertEqual(t.tag, "t", "default field")
  assertEqual(since(t1), "b,a,tag", "omitted field default last")
  val t2 = trace.count
  val q = Pair(b = note("b", 2), note("a", 1))
  assertEqualInt(q.a * 10 + q.b, 12, "positional after named")
  assertEqual(since(t2), "b,a", "positional after named order")
}

test "an exposed record's fields run in source order" {
  val t0 = trace.count
  val w = Wire(b = note("b", 2), a = note("a", 1))
  assertEqualInt(w.a * 10 + w.b, 12, "value")
  assertEqual(since(t0), "b,a", "order")
}

test "a generic record's fields run in source order" {
  val t0 = trace.count
  val bx = Box(second = noteStr("second", "s"), first = noteStr("first", "f"))
  assertEqual(bx.first, "f", "first")
  assertEqual(bx.second, "s", "second")
  assertEqual(since(t0), "second,first", "order")
  val t1 = trace.count
  val bo = Box(second = noteSome("second", 2), first = noteSome("first", 1))
  assertEqualInt(opts(a = bo.first, b = bo.second), 12, "option value")
  assertEqual(since(t1), "second,first", "option order")
}

test "a union case's named fields run in source order" {
  val t0 = trace.count
  val sh = Rect(h = note("h", 2), w = note("w", 3))
  match sh {
    case Rect(w, h) -> assertEqualInt(w * 10 + h, 32, "value")
    case Dot -> assertTrue(false, "expected Rect")
  }
  assertEqual(since(t0), "h,w", "order")
  val t1 = trace.count
  val g = Both(right = note("right", 2), left = note("left", 1))
  match g {
    case Both(l, r) -> assertEqualInt(l * 10 + r, 12, "generic case value")
    case Neither -> assertTrue(false, "expected Both")
  }
  assertEqual(since(t1), "right,left", "generic case order")
}

test "a copy's fields run in source order" {
  val t0 = trace.count
  val p = Pair(a = 0, b = 0).copy(b = note("b", 2), a = note("a", 1))
  assertEqualInt(p.a * 10 + p.b, 12, "value")
  assertEqual(since(t0), "b,a", "order")
}

// ─── Places passed by reference beside ? and await (#8171) ─────────────────
// The `?` and `await` hoists bind every operand evaluated before the argument
// that holds one to a fresh local.  A local bound to the place an `out` or
// `inout` argument names is a copy, so the callee wrote the copy and the
// caller's variable, field or element kept its value.  The place now stays
// in the call and the other arguments run in source order before it.
func noteErr(s: in String): Result[Int, String] {
  trace.add(s)
  Err(error = "failed at " + s)
}

func setTo(x: inout Int, v: in Int): Unit {
  x = v
}

func putOut(x: out Int, v: in Int): Unit {
  x = v
}

func addBoth(x: inout Int, a: in Int, b: in Int): Unit {
  x = x + a * 10 + b
}

record Cell {
  var v: Int
}

record Adder {
  base: Int

  func addInto(self: in Adder, x: inout Int, v: in Int): Unit {
    x = x + self.base + v
  }
}

func mkAdder(base: in Int): Adder {
  trace.add("recv")
  Adder(base = base)
}

func at(s: in String, i: in Int): Int {
  trace.add(s)
  i
}

func inoutBeforePropagate(): Result[Int, String] {
  var x = 1
  setTo(x, noteOk("v", 7)?)
  Ok(value = x)
}

func outBeforePropagate(): Result[Int, String] {
  var x = 0
  putOut(x, noteOk("v", 4)?)
  Ok(value = x)
}

func fieldBeforePropagate(): Result[Int, String] {
  var c = Cell(v = 1)
  setTo(c.v, noteOk("v", 9)?)
  Ok(value = c.v)
}

func inoutBetweenPropagates(): Result[Int, String] {
  var x = 1
  addBoth(x, note("a", 2), noteOk("b", 3)?)
  Ok(value = x)
}

func namedInoutAfterPropagate(): Result[Int, String] {
  var x = 1
  setTo(v = noteOk("v", 6)?, x = x)
  Ok(value = x)
}

func namedInoutBeforePropagate(): Result[Int, String] {
  var x = 1
  addBoth(b = noteOk("b", 3)?, x = x, a = note("a", 2))
  Ok(value = x)
}

func receiverBeforePropagate(): Result[Int, String] {
  var x = 1
  mkAdder(100).addInto(x, noteOk("v", 5)?)
  val ad = Adder(base = 10)
  ad.addInto(x, noteOk("w", 2)?)
  Ok(value = x)
}

func indexedReceiverBeforePropagate(): Result[Int, String] {
  val adders: List[Adder] = newList()
  adders.add(Adder(base = 10))
  adders.add(Adder(base = 20))
  var x = 1
  adders[at("i", 1)].addInto(x, noteOk("v", 3)?)
  Ok(value = x)
}

func errAfterInout(x: inout Int): Result[Int, String] {
  addBoth(x, note("a", 2), noteErr("e")?)
  Ok(value = x)
}

func errBeforeNamedInout(x: inout Int): Result[Int, String] {
  setTo(v = noteErr("e")?, x = x)
  Ok(value = x)
}

async func inoutBeforeAwait(): Int {
  var x = 1
  setTo(x, await noteAsync("v", 8))
  var c = Cell(v = 1)
  addBoth(c.v, note("a", 2), await noteAsync("b", 3))
  x * 100 + c.v
}

test "an inout argument before a ? argument is written, not a copy of it" {
  val t0 = trace.count
  match inoutBeforePropagate() {
    case Ok(v) -> assertEqualInt(v, 7, "the variable was written")
    case Err(e) -> assertTrue(false, "unexpected error " + e)
  }
  assertEqual(since(t0), "v", "order")
  val t1 = trace.count
  match inoutBetweenPropagates() {
    case Ok(v) -> assertEqualInt(v, 24, "the variable was updated")
    case Err(e) -> assertTrue(false, "unexpected error " + e)
  }
  assertEqual(since(t1), "a,b", "the arguments run in source order")
}

test "an out argument before a ? argument is written" {
  match outBeforePropagate() {
    case Ok(v) -> assertEqualInt(v, 4, "the variable was written")
    case Err(e) -> assertTrue(false, "unexpected error " + e)
  }
}

test "a field passed inout before a ? argument is written" {
  match fieldBeforePropagate() {
    case Ok(v) -> assertEqualInt(v, 9, "the field was written")
    case Err(e) -> assertTrue(false, "unexpected error " + e)
  }
}

test "a named inout argument beside a ? argument is written in either order" {
  match namedInoutAfterPropagate() {
    case Ok(v) -> assertEqualInt(v, 6, "written after the ? argument")
    case Err(e) -> assertTrue(false, "unexpected error " + e)
  }
  val t1 = trace.count
  match namedInoutBeforePropagate() {
    case Ok(v) -> assertEqualInt(v, 24, "updated beside reordered arguments")
    case Err(e) -> assertTrue(false, "unexpected error " + e)
  }
  assertEqual(since(t1), "b,a", "the arguments run in source order")
}

test "a method's receiver runs first and its inout argument is written" {
  val t0 = trace.count
  match receiverBeforePropagate() {
    case Ok(v) -> assertEqualInt(v, 118, "both calls wrote the variable")
    case Err(e) -> assertTrue(false, "unexpected error " + e)
  }
  assertEqual(since(t0), "recv,v,w", "order")
  val t1 = trace.count
  match indexedReceiverBeforePropagate() {
    case Ok(v) -> assertEqualInt(v, 24, "the element's method wrote the variable")
    case Err(e) -> assertTrue(false, "unexpected error " + e)
  }
  assertEqual(since(t1), "i,v", "the receiver's index runs once, first")
}

test "a ? that fails before the call leaves the inout argument unwritten" {
  val t0 = trace.count
  var x = 1
  match errAfterInout(x) {
    case Ok(_) -> assertTrue(false, "expected the error")
    case Err(e) -> assertEqual(e, "failed at e", "the error propagated")
  }
  assertEqualInt(x, 1, "the call never ran")
  assertEqual(since(t0), "a,e", "the arguments before the ? ran")
  match errBeforeNamedInout(x) {
    case Ok(_) -> assertTrue(false, "expected the error")
    case Err(e) -> assertEqual(e, "failed at e", "the error propagated")
  }
  assertEqualInt(x, 1, "the reordered call never ran")
}

test "an inout argument before an await argument is written" {
  val t0 = trace.count
  assertEqualInt(await inoutBeforeAwait(), 824, "the variable and the field were written")
  assertEqual(since(t0), "v,a,b", "order")
}

test "a receiver element's index runs once, before the reordered arguments" {
  val accs: List[Acc] = newList()
  accs.add(Acc(n = 100))
  val t0 = trace.count
  val r = accs[at("i", 0)].mix(b = note("b", 2), a = note("a", 1))
  assertEqualInt(r, 112, "value")
  assertEqual(since(t0), "i,b,a", "order")
}

// ─── Operands bound to temporaries keep the type their position expects ─────
// A bracket literal passed where a `List[T]` is expected is built as that
// list; bound to a temporary (by the D171 rewrite or by the `?`/`await`
// hoist) it was built as an array and then read as a list.  A lambda,
// `newList()`, `None`, a slice literal and an `Int` widened to `Long` are
// covered beside it (#8171).
func fillAfter(v: in Int, x: inout Int, xs: in List[Int]): Unit {
  x = x + v * 10 + xs.count * 100
}

func fillBefore(x: inout Int, v: in Int, xs: in List[Int]): Unit {
  x = x + v * 10 + xs.count * 100
}

func listed(v: in Int, w: in Int, xs: in List[Int]): Int {
  v * 10 + w + xs.count * 100
}

func summary(xs: in List[Int], o: in Option[Int], f: in (Int) -> Int, s: in slice[Int], w: in Long, v: in Int): String {
  val extra = match o { case Some(q) -> q; case None -> 50 }
  toString(xs.count * 1000 + extra + f(v) + s.length * 100000) + "/" + toString(w)
}

func listAfterPropagate(): Result[Int, String] {
  var x = 1
  fillAfter(noteOk("v", 3)?, x, [1, 2])
  Ok(value = x)
}

func listAfterInoutAndPropagate(): Result[Int, String] {
  var x = 1
  fillBefore(x, noteOk("v", 3)?, [1, 2])
  Ok(value = x)
}

func operandsBeforePropagate(): Result[String, String] {
  val a = summary(newList(), None, { n -> n * 2 }, [9], 5, noteOk("v", 3)?)
  val b = summary([1, 2], Some(value = 7), { n -> n + 1 }, [8, 9], 6, noteOk("w", 3)?)
  Ok(value = a + " " + b)
}

async func operandsBeforeAwait(): String {
  summary([1, 2], None, { n -> n * 3 }, [7], 4, await noteAsync("v", 2))
}

test "a list literal after a ? beside an inout argument stays a list" {
  match listAfterPropagate() {
    case Ok(v) -> assertEqualInt(v, 231, "after the ? argument")
    case Err(e) -> assertTrue(false, "unexpected error " + e)
  }
  match listAfterInoutAndPropagate() {
    case Ok(v) -> assertEqualInt(v, 231, "after the inout and ? arguments")
    case Err(e) -> assertTrue(false, "unexpected error " + e)
  }
}

test "a list literal bound by a reordered call stays a list" {
  val t0 = trace.count
  var x = 1
  fillAfter(xs = [1, 2], v = note("v", 3), x = x)
  assertEqualInt(x, 231, "with an inout argument")
  assertEqualInt(listed(xs = [1, 2], w = note("w", 1), v = note("v", 3)), 231, "without one")
  assertEqual(since(t0), "v,w,v", "order")
}

test "operands bound before a ? or await keep their expected types" {
  match operandsBeforePropagate() {
    case Ok(s) -> assertEqual(s, "100056/5 202011/6", "values")
    case Err(e) -> assertTrue(false, "unexpected error " + e)
  }
  assertEqual(await operandsBeforeAwait(), "102056/4", "await value")
}

// ─── A place's index after a ? runs in its own turn ──────────────────────────
func setFrom(v: in Int, c: in Int, x: inout Int): Unit {
  x = v * 10 + c
}

func addFour(a: in Int, x: inout Int, v: in Int, c: in Int): Unit {
  x = x + a * 1000 + v * 10 + c
}

func incr(x: inout Int): Result[Int, String] {
  trace.add("incr")
  x = x + 1
  Ok(value = x * 10)
}

func indexedPlaceAfterPropagate(cells: in List[Cell]): Result[Int, String] {
  setFrom(noteOk("v", 1)?, note("c", 2), cells[at("i", 0)].v)
  Ok(value = cells[0].v)
}

func readAfterInoutPropagate(): Result[Int, String] {
  var x = 1
  addFour(note("a", 1), x, incr(x)?, x)
  Ok(value = x)
}

func namedReadAfterInoutPropagate(): Result[Int, String] {
  var x = 1
  addFour(a = note("a", 1), x = x, v = incr(x)?, c = x)
  Ok(value = x)
}

test "an inout place's index runs after the arguments written before it" {
  val cells: List[Cell] = newList()
  cells.add(Cell(v = 0))
  val t0 = trace.count
  match indexedPlaceAfterPropagate(cells) {
    case Ok(v) -> assertEqualInt(v, 12, "the element's field was written")
    case Err(e) -> assertTrue(false, "unexpected error " + e)
  }
  assertEqual(since(t0), "v,c,i", "order")
}

test "an argument after a ? reads the place the ? changed" {
  val t0 = trace.count
  match readAfterInoutPropagate() {
    case Ok(v) -> assertEqualInt(v, 1204, "positional")
    case Err(e) -> assertTrue(false, "unexpected error " + e)
  }
  assertEqual(since(t0), "a,incr", "positional order")
  val t1 = trace.count
  match namedReadAfterInoutPropagate() {
    case Ok(v) -> assertEqualInt(v, 1204, "named")
    case Err(e) -> assertTrue(false, "unexpected error " + e)
  }
  assertEqual(since(t1), "a,incr", "named order")
}
