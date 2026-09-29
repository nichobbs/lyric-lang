//! impl_generic_target_self_test.l — dual-target runtime regression test for
//! an `impl` block whose target is a generic record (`impl[T] I for Box[T]`,
//! #7704), plus by-value non-receiver `Self` parameters (#7755).
//!
//! Before #7704 no such impl compiled: the type checker resolved the impl's
//! target and its methods' signatures without the impl's own type parameters
//! in scope (T0010 "unknown type name 'T'"), the jvm backend refused the
//! generic target shape outright (J008), and the dotnet backend named the
//! target `<pkg>.__impl_target`.  Past those, both backends lowered the impl
//! methods with an empty type-parameter list, so none of the handling a
//! method declared inside `record Box[T]` gets applied: on dotnet, `T` in the
//! signature and in body annotations must be the class's `!0` and `self` the
//! open instantiation `Box`1<!0>` (`FuncCtx.reifiedGenerics`, #7695); on jvm,
//! `T` must erase to `Object` in the descriptor and in body annotations
//! (`FuncCtx.typeParams`).  An impl for a single instantiation
//! (`impl I for Box[Int]`) is rejected as T0145.
//!
//! The `Mergeable` methods take and return `Self`, so the `T`-typed field of
//! a `Self` parameter (`other.value`) is read inside the impl: on dotnet that
//! parameter is `castclass`ed to the open instantiation in the prologue
//! (`narrowSelfParamsMsil`), and a bare sibling call returning `Self`
//! (`pickSelf(false, other).value` in `twice`) is narrowed the same way.
//! `Combine.combine` spells the receiver explicitly (`self: in Self`).  The
//! non-generic `Acc` impls cover the by-value `Self` parameter narrowing
//! (#7755) on its own.  Each body declares `T`-typed locals — `val y: T`,
//! a no-initialiser `var x: T`, `List[T]`, `Option[T]`, a closure-captured
//! `var x: T` — and every generic case is instantiated with `Int`, `String`
//! and a record, called on the concrete receiver and, for `Counted`, through
//! an interface-typed binding.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/impl_generic_target_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/impl_generic_target_self_test.l
//!
//! The dotnet DLL is also verified by `scripts/ilverify-selfhosted.sh`.
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.ImplGenericTargetSelfTest

import Std.Core
import Std.Collections
import Std.Testing

record Pair {
  a: Int
  b: String
}

interface Counted {
  func countWith(extra: in Int): Int
}

interface Mergeable {
  func pickSelf(useMine: in Bool, other: in Self): Self
  func viaList(other: in Self): Self
  func viaOption(present: in Bool, other: in Self): Self
  func replaced(other: in Self): Self
  func twice(other: in Self): Self
}

interface Combine {
  func combine(self: in Self, other: in Self): Self
}

record Box[T] {
  value: T
}

record Acc {
  total: Int
  label: String
}

impl[T] Counted for Box[T] {
  func countWith(extra: in Int): Int {
    val xs: List[T] = newList()
    xs.add(self.value)
    var i = 0
    while i < extra {
      val y: T = value
      xs.add(y)
      i = i + 1
    }
    xs.count
  }
}

impl[T] Mergeable for Box[T] {
  func pickSelf(useMine: in Bool, other: in Self): Self {
    var x: T
    if useMine {
      x = self.value
    } else {
      x = other.value
    }
    Box(value = x)
  }

  func viaList(other: in Self): Self {
    val xs: List[T] = newList()
    xs.add(other.value)
    xs.add(self.value)
    Box(value = xs[0])
  }

  func viaOption(present: in Bool, other: in Self): Self {
    val o: Option[T] = if present { Some(value = other.value) } else { None }
    match o {
      case Some(v) -> Box(value = v)
      case None -> Box(value = self.value)
    }
  }

  func replaced(other: in Self): Self {
    var x: T = self.value
    val theirs: T = other.value
    val f = { -> x = theirs }
    f()
    Box(value = x)
  }

  func twice(other: in Self): Self {
    val v: T = pickSelf(false, other).value
    Box(value = v)
  }
}

impl[T] Combine for Box[T] {
  func combine(self: in Self, other: in Self): Self {
    val keep: T = other.value
    Box(value = keep)
  }
}

impl Combine for Acc {
  func combine(self: in Self, other: in Self): Self {
    Acc(total = self.total + other.total, label = self.label + other.label)
  }
}

impl Mergeable for Acc {
  func pickSelf(useMine: in Bool, other: in Self): Self {
    if useMine {
      return Acc(total = self.total, label = self.label)
    }
    Acc(total = other.total, label = other.label)
  }

  func viaList(other: in Self): Self {
    val totals: List[Int] = newList()
    totals.add(other.total)
    Acc(total = totals[0], label = other.label)
  }

  func viaOption(present: in Bool, other: in Self): Self {
    val o: Option[Int] = if present { Some(value = other.total) } else { None }
    match o {
      case Some(t) -> Acc(total = t, label = other.label)
      case None -> Acc(total = self.total, label = self.label)
    }
  }

  func replaced(other: in Self): Self {
    Acc(total = other.total, label = self.label)
  }

  func twice(other: in Self): Self {
    val t = pickSelf(false, other).total
    Acc(total = t, label = self.label)
  }
}

test "Box[Int]: T-typed locals, fields and Self params in impl methods" {
  val b = Box(value = 41)
  val o = Box(value = 7)
  assertEqualInt(b.countWith(2), 3, "countWith(2)")
  assertEqualInt(b.pickSelf(true, o).value, 41, "pickSelf(true, o)")
  assertEqualInt(b.pickSelf(false, o).value, 7, "pickSelf(false, o)")
  assertEqualInt(b.viaList(o).value, 7, "viaList(o)")
  assertEqualInt(b.viaOption(true, o).value, 7, "viaOption(true, o)")
  assertEqualInt(b.viaOption(false, o).value, 41, "viaOption(false, o)")
  assertEqualInt(b.replaced(o).value, 7, "replaced(o)")
  assertEqualInt(b.twice(o).value, 7, "twice(o)")
  assertEqualInt(b.combine(o).value, 7, "combine(o)")
}

test "Box[String]: T-typed locals, fields and Self params in impl methods" {
  val b = Box(value = "mine")
  val o = Box(value = "theirs")
  assertEqualInt(b.countWith(0), 1, "countWith(0)")
  assertEqual(b.pickSelf(true, o).value, "mine", "pickSelf(true, o)")
  assertEqual(b.pickSelf(false, o).value, "theirs", "pickSelf(false, o)")
  assertEqual(b.viaList(o).value, "theirs", "viaList(o)")
  assertEqual(b.viaOption(false, o).value, "mine", "viaOption(false, o)")
  assertEqual(b.replaced(o).value, "theirs", "replaced(o)")
  assertEqual(b.twice(o).value, "theirs", "twice(o)")
  assertEqual(b.combine(o).value, "theirs", "combine(o)")
}

test "Box[Pair]: T-typed locals, fields and Self params in impl methods" {
  val b = Box(value = Pair(a = 1, b = "one"))
  val o = Box(value = Pair(a = 2, b = "two"))
  assertEqualInt(b.countWith(3), 4, "countWith(3)")
  assertEqualInt(b.pickSelf(true, o).value.a, 1, "pickSelf(true, o).a")
  assertEqual(b.pickSelf(false, o).value.b, "two", "pickSelf(false, o).b")
  assertEqualInt(b.viaList(o).value.a, 2, "viaList(o).a")
  assertEqual(b.viaOption(true, o).value.b, "two", "viaOption(true, o).b")
  assertEqualInt(b.replaced(o).value.a, 2, "replaced(o).a")
  assertEqual(b.twice(o).value.b, "two", "twice(o).b")
  assertEqualInt(b.combine(o).value.a, 2, "combine(o).a")
}

test "Box[T] impl dispatched through interface-typed bindings" {
  val c1: Counted = Box(value = 5)
  assertEqualInt(c1.countWith(1), 2, "Counted Box[Int]")
  val c2: Counted = Box(value = "s")
  assertEqualInt(c2.countWith(2), 3, "Counted Box[String]")
  val c3: Counted = Box(value = Pair(a = 3, b = "three"))
  assertEqualInt(c3.countWith(0), 1, "Counted Box[Pair]")
}

test "non-generic record: by-value Self params and an explicit self receiver" {
  val a = Acc(total = 1, label = "a")
  val b = Acc(total = 2, label = "b")
  val c = a.combine(b)
  assertEqualInt(c.total, 3, "combine total")
  assertEqual(c.label, "ab", "combine label")
  assertEqualInt(a.pickSelf(false, b).total, 2, "pickSelf(false, b)")
  assertEqualInt(a.viaList(b).total, 2, "viaList(b)")
  assertEqual(a.viaOption(false, b).label, "a", "viaOption(false, b)")
  val r = a.replaced(b)
  assertEqualInt(r.total, 2, "replaced total")
  assertEqual(r.label, "a", "replaced label")
  assertEqualInt(a.twice(b).total, 2, "twice(b)")
}
