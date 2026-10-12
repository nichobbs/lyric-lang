//! member_local_shadow_self_test.l — a local that shadows a field inside a
//! member body (#8264), on every target.
//!
//! A protected `entry`/`func`, a record-body method and an `impl` method read
//! and write their own type's fields by bare name (docs/01 §7.5, §2.4), and a
//! binding of the same name — a parameter, a `val`/`var`/`let`, a `match`
//! arm or `for` binding, a lambda parameter — shadows the field for the rest
//! of its own scope, as any inner binding shadows an outer one.  Before the
//! fix, dotnet and native rewrote every bare occurrence of a protected
//! type's field name to `self.<name>` regardless of scope, so `var total =
//! 100; total = total + 5; total` returned 5 and wrote the field; a
//! record-body method's bare field lost to a same-named module `val` on
//! dotnet and native, and native rejected a bare field in a record or `impl`
//! method outright (N0007).  Every target also checked an `ensures:` or
//! invariant clause naming a field against a body local of that name at the
//! return site.  `Lyric.SelfFields` now resolves each bare name under the
//! type checker's scoping before any backend sees it.
//!
//! Also covered: a protected invariant reads the field even where a
//! parameter shares its name; an interface default copied into an `impl`
//! and the interface's own contract clauses never see the implementing
//! type's fields (on the JVM a default read the field even before #8264); a
//! bare `match`-arm pattern naming an enum case binds nothing, while a
//! `val`, `for` or tuple pattern of that name still binds; and a lambda reads a
//! field when it runs, as `self.<field>` does (the JVM read the field's value
//! when the lambda was made).  A breached invariant is in
//! `member_local_shadow_panics_self_test.l`, which needs `try` and so does
//! not run on native.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/member_local_shadow_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/member_local_shadow_self_test.l
//!   lyric test --target native lyric-compiler/lyric/member_local_shadow_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.MemberLocalShadowSelfTest

import Std.Core
import Std.Collections
import Std.Testing

// A module-level name every member below also declares as a field: a bare
// reference in a member body is the field, never this.
val total: Int = 777

func addTo(x: inout Int, n: in Int): Unit {
  x = x + n
}

func setTo(x: out Int, v: in Int): Unit {
  x = v
}

func twice(f: in (Int) -> Int, x: in Int): Int {
  f(x)
}

protected type Counter {
  var total: Int = 0
  var seen: Int = 0
  invariant: total >= 0
  entry shadowVar(): Int {
    var total = 100
    total = total + 5
    total
  }
  entry shadowVal(): Int {
    val total = 7
    total * 2
  }
  entry shadowLet(): Int {
    let total = 3
    total + 1
  }
  entry compound(): Int {
    var total = 10
    total += 5
    total -= 1
    total *= 2
    total
  }
  entry byInout(): Int {
    var total = 100
    addTo(total, 5)
    total
  }
  entry byOut(): Int {
    var total = 1
    setTo(total, 42)
    total
  }
  // The field is written before the inner block; the inner `total` is the
  // block's own, and the field is visible again after it.
  entry nested(c: in Bool): Int {
    total = 1
    if c {
      val total = 50
      seen = total
    }
    total
  }
  // The initializer reads the field: the new binding is not in scope yet.
  entry initFromField(): Int {
    total = 4
    val total = total + 1
    total * 10
  }
  entry matchArm(k: in Int): Int {
    val o: Option[Int] = if k > 0 { Some(value = k) } else { None }
    match o {
      case Some(total) -> total + 1000
      case None -> total
    }
  }
  entry forLoop(xs: in List[Int]): Int {
    var s = 0
    for total in xs {
      s = s + total
    }
    s + total
  }
  entry lambdaParam(): Int {
    val f = { total: Int -> total * 2 }
    twice(f, 21) + total
  }
  entry lambdaCapture(): Int {
    val total = 30
    val f = { x: Int -> x + total }
    twice(f, 3)
  }
  // `self.total` is the field while a local `total` is in scope.
  entry selfAlongside(): Int {
    val total = 99
    self.total = self.total + total
    self.total
  }
  // The parameter shadows the field.
  entry param(total: in Int): Int {
    seen = total
    total + 1
  }
  // A negative local is no breach of `invariant: total >= 0`, which is
  // checked against the field at the return.
  entry negativeLocal(): Int {
    var total = -5
    total
  }
  // `ensures:` names the field, unchanged by the body's own `total`.
  entry ensuresField(): Int
    ensures: total == old(total)
  {
    var total = 1
    total = total + 1
    total
  }
  func funcShadow(): Int {
    val total = 5
    total + 1
  }
  func peek(): Int {
    total
  }
  func seenValue(): Int {
    seen
  }
  // A lambda reads a field when it runs, as `self.total` does.
  entry liveCapture(): Int {
    val f = { k: Int -> k + total }
    total = 10
    f(1)
  }
  entry set(v: in Int): Unit {
    total = v
  }
}

protected type Gate {
  var total: Int = 1
  var opened: Bool = true
  entry take(): Int
    when: opened
  {
    var total = 10
    total = total + 1
    total
  }
  func peek(): Int {
    total
  }
}

protected type Box[T] {
  var item: T
  var total: Int = 0
  entry swap(v: in T): Int {
    val total = 7
    item = v
    total
  }
  func get(): T {
    item
  }
  func peek(): Int {
    total
  }
}

record Tally {
  total: Int

  func shadowed(): Int {
    var total = 100
    total = total + 5
    total
  }

  func plain(): Int {
    total
  }

  // An explicit `in` receiver and an expression body (#8216).
  func explicitIn(self: in Tally): Int = total

  func nested(c: in Bool): Int {
    if c {
      val total = 1
      return total
    }
    total
  }

  func lambdaParam(): Int {
    val f = { total: Int -> total + 1 }
    twice(f, 1) + total
  }
}

// A record method's lambda reads a field by its bare name when it runs (#8202:
// dotnet refused the bare name inside the lifted lambda with T0115, and the
// JVM read the field's value from when the lambda was made).
record Live {
  var n: Int

  func readLater(self: in Live): Int {
    val f = { -> n }
    self.n = 30
    val r: Int = f()
    r
  }
}

interface Sized {
  func size(): Int
  func shadowed(): Int
}

record Bag {
  total: Int
}

impl Sized for Bag {
  func size(): Int {
    total
  }

  func shadowed(): Int {
    val total = 9
    total
  }
}

// A dot-named method reaches its receiver's fields only through `self.`, so
// a local of a field's name is just a local.
func Bag.dotNamed(self: in Bag): Int {
  val total = 3
  self.total + total
}

// The invariant is about the field: a parameter of its name hides the field
// from the body, not from the invariant.
protected type Guard {
  var level: Int = 0
  invariant: level >= 0
  entry put(level: in Int): Int {
    self.level = 5
    level
  }
  func peek(): Int {
    level
  }
}

// An interface's default methods and contract clauses are written against
// the interface, which has no fields: a bare name in them is never a field
// of the implementing type, even one named like a module `val` they read.
val limit: Int = 10

interface Limited {
  func base(): Int
    requires: limit > 0
    ensures: limit == 10
  func cap(): Int {
    limit + base()
  }
}

record Capped {
  limit: Int
}

impl Limited for Capped {
  func base(): Int {
    limit
  }
}

interface Metered {
  func read(): Int
    ensures: limit > 0
  func ceiling(): Int {
    limit
  }
}

protected type Meter {
  var limit: Int = -4
}

impl Metered for Meter {
  func read(): Int {
    limit
  }
}

// A bare pattern naming an enum case is the case, not a binding, so it
// hides no field of that name.
enum Hue {
  case red
  case green
}

union Tagged {
  case Only(n: Int, hue: Hue)
}

func hueCode(h: in Hue): Int {
  match h {
    case Hue.red -> 1
    case Hue.green -> 2
  }
}

protected type Palette {
  var red: Int = 5
  entry pick(h: in Hue): Int {
    match h {
      case red -> red + 1
      case green -> red + 2
    }
  }
  // Outside a `match` arm a bare pattern always binds, even one named like
  // a case.
  entry valNamedLikeCase(): Int {
    val red = 40
    red + 2
  }
  entry forNamedLikeCase(xs: in List[Int]): Int {
    var s = 0
    for red in xs {
      s = s + red
    }
    s
  }
  entry tupleNamedLikeCase(): Int {
    val (red, b) = (7, 1)
    red + b
  }
  // `red` binds the `Hue` payload; it is neither the case nor the field.
  entry destructureNamedLikeCase(t: in Tagged): Int {
    val Only(n, red) = t
    n + hueCode(red) * 10
  }
  func peekRed(): Int {
    red
  }
}

// The same holds outside any member: these bindings were once dropped by the
// dotnet and JVM pattern binders, so a later `red` read the enum case.
func freeForNamedLikeCase(xs: in List[Int]): Int {
  var s = 0
  for red in xs {
    s = s + red
  }
  s
}

func freeTupleNamedLikeCase(): Int {
  val (red, b) = (7, 1)
  red + b
}

func freeDestructureNamedLikeCase(t: in Tagged): Int {
  val Only(n, red) = t
  n + hueCode(red) * 10
}

record Swatch {
  red: Int

  func local(): Int {
    val red = 3
    red
  }
}

test "a shadowing var is read, assigned and returned; the field is untouched" {
  val c = Counter()
  assertEqualInt(c.shadowVar(), 105, "local result")
  assertEqualInt(c.peek(), 0, "field unchanged")
}

test "a shadowing val and let" {
  val c = Counter()
  assertEqualInt(c.shadowVal(), 14, "val")
  assertEqualInt(c.shadowLet(), 4, "let")
  assertEqualInt(c.peek(), 0, "field unchanged")
}

test "compound assignment to a shadowing var" {
  val c = Counter()
  assertEqualInt(c.compound(), 28, "local result")
  assertEqualInt(c.peek(), 0, "field unchanged")
}

test "a shadowing var passed by inout and out" {
  val c = Counter()
  assertEqualInt(c.byInout(), 105, "inout")
  assertEqualInt(c.byOut(), 42, "out")
  assertEqualInt(c.peek(), 0, "field unchanged")
}

test "an inner-block shadow ends with the block" {
  val c = Counter()
  assertEqualInt(c.nested(true), 1, "field after the block")
  assertEqualInt(c.seenValue(), 50, "inner local inside the block")
  assertEqualInt(c.peek(), 1, "field")
}

test "a binding's initializer reads the field it shadows" {
  val c = Counter()
  assertEqualInt(c.initFromField(), 50, "local initialized from the field")
  assertEqualInt(c.peek(), 4, "field")
}

test "match-arm and for-loop bindings named like a field" {
  val c = Counter()
  c.set(3)
  assertEqualInt(c.matchArm(5), 1005, "arm binding")
  assertEqualInt(c.matchArm(0), 3, "field in the other arm")
  val xs: List[Int] = newList()
  xs.add(1)
  xs.add(2)
  assertEqualInt(c.forLoop(xs), 6, "loop binding, then the field")
}

test "a lambda parameter and a captured local named like a field" {
  val c = Counter()
  c.set(2)
  assertEqualInt(c.lambdaParam(), 44, "lambda parameter, then the field")
  assertEqualInt(c.lambdaCapture(), 33, "captured local")
  assertEqualInt(c.peek(), 2, "field unchanged")
}

test "self.total is the field while a local total is in scope" {
  val c = Counter()
  c.set(1)
  assertEqualInt(c.selfAlongside(), 100, "field updated through self")
  assertEqualInt(c.peek(), 100, "field")
}

test "a parameter shadows the field" {
  val c = Counter()
  assertEqualInt(c.param(8), 9, "parameter")
  assertEqualInt(c.seenValue(), 8, "parameter stored")
  assertEqualInt(c.peek(), 0, "field unchanged")
}

test "the invariant and ensures clauses check the field, not the local" {
  val c = Counter()
  assertEqualInt(c.negativeLocal(), -5, "negative local")
  assertEqualInt(c.ensuresField(), 2, "ensures over the field")
  assertEqualInt(c.peek(), 0, "field unchanged")
}

test "a func member's local shadows the field" {
  val c = Counter()
  assertEqualInt(c.funcShadow(), 6, "func local")
  assertEqualInt(c.peek(), 0, "field unchanged")
}

test "a when: entry's local shadows the field" {
  val g = Gate()
  assertEqualInt(g.take(), 11, "local")
  assertEqualInt(g.peek(), 1, "field unchanged")
}

test "a generic protected type's local shadows the field" {
  val b = Box(item = "a")
  assertEqualInt(b.swap("b"), 7, "local")
  assertEqual(b.get(), "b", "item written")
  assertEqualInt(b.peek(), 0, "field unchanged")
}

test "record-body methods: a local shadows the field, and the field beats a module val" {
  val t = Tally(total = 3)
  assertEqualInt(t.shadowed(), 105, "local")
  assertEqualInt(t.plain(), 3, "field, not the module val")
  assertEqualInt(t.explicitIn(), 3, "explicit `in` receiver: field, not the module val")
  assertEqualInt(t.nested(true), 1, "inner local")
  assertEqualInt(t.nested(false), 3, "field")
  assertEqualInt(t.lambdaParam(), 5, "lambda parameter, then the field")
  assertEqualInt(total, 777, "module val")
}

test "impl and dot-named methods" {
  val b = Bag(total = 4)
  assertEqualInt(b.size(), 4, "impl field")
  assertEqualInt(b.shadowed(), 9, "impl local")
  val s: Sized = b
  assertEqualInt(s.size(), 4, "through the interface")
  assertEqualInt(b.dotNamed(), 7, "dot-named: self.total plus the local")
}

test "a lambda reads the field when it runs" {
  val c = Counter()
  assertEqualInt(c.liveCapture(), 11, "field written after the lambda was made")
  val l = Live(n = 0)
  assertEqualInt(l.readLater(), 30, "record method: field written after the lambda was made")
}

test "a protected invariant reads the field, not a parameter of its name" {
  val g = Guard()
  assertEqualInt(g.put(-3), -3, "parameter")
  assertEqualInt(g.peek(), 5, "field")
}

test "an interface default and the interface's clauses see the module val, not the field" {
  val c = Capped(limit = -1)
  assertEqualInt(c.base(), -1, "impl body reads the field")
  assertEqualInt(c.cap(), 9, "default reads the module val")
  val l: Limited = c
  assertEqualInt(l.cap(), 9, "default through the interface")
  assertEqualInt(l.base(), -1, "impl through the interface")
}

test "a protected type's impl keeps its interface's names out of the fields' reach" {
  val m = Meter()
  assertEqualInt(m.read(), -4, "impl body reads the field")
  assertEqualInt(m.ceiling(), 10, "default reads the module val")
  val i: Metered = m
  assertEqualInt(i.ceiling(), 10, "default through the interface")
}

test "a bare pattern naming an enum case hides no field" {
  val p = Palette()
  assertEqualInt(p.pick(Hue.red), 6, "red arm reads the field")
  assertEqualInt(p.pick(Hue.green), 7, "green arm reads the field")
}

test "a val, for, tuple or constructor binding named like a case shadows the field" {
  val p = Palette()
  assertEqualInt(p.valNamedLikeCase(), 42, "val")
  val xs: List[Int] = newList()
  xs.add(2)
  xs.add(3)
  assertEqualInt(p.forNamedLikeCase(xs), 5, "for")
  assertEqualInt(p.tupleNamedLikeCase(), 8, "tuple")
  assertEqualInt(p.destructureNamedLikeCase(Only(n = 40, hue = Hue.green)), 60, "constructor destructure, green")
  assertEqualInt(p.destructureNamedLikeCase(Only(n = 40, hue = Hue.red)), 50, "constructor destructure, red")
  assertEqualInt(p.peekRed(), 5, "field unchanged")
  assertEqualInt(Swatch(red = 9).local(), 3, "record-body val")
}

test "outside a member, a for, tuple or constructor binding named like a case binds" {
  val xs: List[Int] = newList()
  xs.add(2)
  xs.add(3)
  assertEqualInt(freeForNamedLikeCase(xs), 5, "for")
  assertEqualInt(freeTupleNamedLikeCase(), 8, "tuple")
  assertEqualInt(freeDestructureNamedLikeCase(Only(n = 40, hue = Hue.green)), 60, "constructor destructure, green")
  assertEqualInt(freeDestructureNamedLikeCase(Only(n = 40, hue = Hue.red)), 50, "constructor destructure, red")
}
