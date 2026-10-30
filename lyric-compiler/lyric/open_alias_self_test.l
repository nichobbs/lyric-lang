//! An unannotated local initialised from an open local is itself open (#7887),
//! and a name a constructor pattern binds to an open type argument fixes it
//! (#8250).
//!
//! `val o = None` leaves the element type open until a use fixes it. `val o2 = o`
//! is open too, so a use of either name fixes the element both are built at.
//! `val r = Ok(value = true)` leaves the error type open; `case Err(e)` binds
//! `e` at that argument, and what `e` flows into fixes it.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/open_alias_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/open_alias_self_test.l
//!   lyric test --target native lyric-compiler/lyric/open_alias_self_test.l
@test_module
package Lyric.OpenAliasSelfTest

import Std.Core
import Std.Collections
import Std.Testing

func viaAlias(): Int {
  val o = None
  val o2 = o
  val x: Option[Int] = o2
  match o {
    case Some(v) -> v
    case None -> -1
  }
}

func viaTwoHops(): String {
  val o = None
  val o2 = o
  val o3 = o2
  val x: Option[String] = o3
  match o {
    case Some(v) -> v
    case None -> "none"
  }
}

func evidenceThroughSource(): Int {
  val o = None
  val o2 = o
  val x: Option[Int] = o
  match o2 {
    case Some(v) -> v
    case None -> -2
  }
}

func resultAlias(): Int {
  val r = Ok(value = 5)
  val r2 = r
  val x: Result[Int, String] = r2
  match r {
    case Ok(v) -> v
    case Err(e) -> -1
  }
}

func listAlias(): Int {
  val xs = newList()
  val ys = xs
  val z: List[Int] = ys
  xs.add(3)
  xs.count
}

func listTwoHops(): Int {
  val xs = newList()
  val ys = xs
  val zs = ys
  val z: List[String] = zs
  ys.add("a")
  xs.count
}

func tupleAlias(): Int {
  val t = (None, 5)
  val t2 = t
  val x: (Option[Int], Int) = t2
  match t {
    case (Some(v), n) -> v + n
    case (None, n) -> n
  }
}

func fromPattern(): Result[Bool, String] {
  val r = Ok(value = true)
  match r {
    case Ok(v) -> Ok(value = v)
    case Err(e) -> Err(error = e)
  }
}

func fromPatternOtherArm(): Result[Int, String] {
  val r = Err(error = "boom")
  match r {
    case Ok(v) -> Ok(value = v)
    case Err(e) -> Err(error = e)
  }
}

test "an alias of an open Option is fixed by its own use" {
  assertEqual(toString(viaAlias()), "-1", "one hop")
}

test "an alias two hops away" {
  assertEqual(viaTwoHops(), "none", "two hops")
}

test "evidence through the source fixes the alias" {
  assertEqual(toString(evidenceThroughSource()), "-2", "source use")
}

test "an alias of an open Result" {
  assertEqual(toString(resultAlias()), "5", "Result alias")
}

test "an alias of an open list" {
  assertEqual(toString(listAlias()), "1", "one hop")
  assertEqual(toString(listTwoHops()), "1", "two hops")
}

test "an alias of an open tuple" {
  assertEqual(toString(tupleAlias()), "5", "tuple alias")
}

test "a type argument fixed only by a pattern binding" {
  match fromPattern() {
    case Ok(b) -> assertTrue(b, "Ok payload")
    case Err(e) -> assertTrue(false, "unexpected Err")
  }
  match fromPatternOtherArm() {
    case Ok(n) -> assertTrue(false, "unexpected Ok")
    case Err(e) -> assertEqual(e, "boom", "Err payload")
  }
}
