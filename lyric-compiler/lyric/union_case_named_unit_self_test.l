//! union_case_named_unit_self_test.l - runtime regression test for a user
//! union case named `Unit` on both self-hosted backends (#8652).
//!
//! `case Unit` registers the bare constructor key `Unit`.  The JVM backend
//! resolved a bare `TRef` return type through that registry before the
//! reserved type keywords, so `func f(): Unit` was recorded as returning the
//! case class, and every call to a `Unit` function `checkcast` a void result:
//! `J008 Jvm.Lowering: stackmap simulation underflow at main`.  A reserved
//! type keyword always names the built-in type.  dotnet was never affected;
//! it is covered here so the two stay in step.
//!
//! Run by the native `lyric test` on BOTH targets:
//!   lyric test --target dotnet lyric-compiler/lyric/union_case_named_unit_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/union_case_named_unit_self_test.l
//! Imports only `Std.*`.
@test_module
package Lyric.UnionCaseNamedUnitSelfTest

import Std.Core
import Std.Collections
import Std.Testing

union Tok {
  case Unit
  case Num(n: Int)
}

func noop(): Unit {
}

func bump(log: in List[Int]): Unit {
  log.add(1)
}

func describe(t: in Tok): String {
  match t {
    case Unit -> "unit"
    case Num(n) -> "num" + toString(n)
  }
}

func passThrough(u: in Unit): Unit {
  u
}

test "a Unit-returning call as a statement beside a case named Unit" {
  noop()
  assertTrue(true, "reached")
}

test "a Unit call result bound to a val" {
  val x = noop()
  assertTrue(true, "bound")
}

test "a Unit function with a side effect runs" {
  val log: List[Int] = newList()
  bump(log)
  bump(log)
  assertEqualInt(log.count, 2, "both calls ran")
}

test "a Unit value passes through a Unit parameter" {
  val u = noop()
  val v = passThrough(u)
  assertTrue(true, "passed")
}

test "the union itself still constructs and matches" {
  assertEqual(describe(Unit), "unit", "nullary case")
  assertEqual(describe(Num(n = 7)), "num7", "payload case")
}

test "println still prints beside a case named Unit" {
  println("hi")
  assertTrue(true, "printed")
}
