//! name_resolution_self_test.l — runtime regression test for bare and
//! qualified name resolution on both self-hosted backends.
//!
//! * #8350: a module-level `val`, a local or a parameter of function type
//!   hides an imported function of the same name in call position (the call
//!   used to bind the import silently).
//! * #7799: an aliased facade import (`import Std.Collections as Coll`)
//!   reaches what the facade re-exports from its own imports
//!   (`Coll.newList()`), as the bare name does.
//! * #8562: an explicit type argument that names an `alias` specialises the
//!   generic on the alias's target.
//!
//! Run by the native `lyric test` on BOTH targets:
//!   lyric test --target dotnet lyric-compiler/lyric/name_resolution_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/name_resolution_self_test.l
@test_module
package Lyric.NameResolutionSelfTest

import Std.Core
import Std.Collections as Coll
import Std.Testing

alias Count = Int

func sum2[T](a: in T, b: in T): T
  where T: Add
{
  a + b
}

func first[T](xs: in Coll.List[T]): T = xs[0]

val isSome: (Option[Int]) -> Bool = { o -> false }

func moduleValCall(): Bool {
  val o: Option[Int] = Some(value = 1)
  isSome(o)
}

func parameterCall(isNone: in (Option[Int]) -> Bool): Bool {
  val o: Option[Int] = Some(value = 1)
  isNone(o)
}

func localCall(): Bool {
  val isSome: (Option[Int]) -> Bool = { o -> false }
  val o: Option[Int] = Some(value = 1)
  isSome(o)
}

test "a module-level function-typed val hides the imported function in call position" {
  assertFalse(moduleValCall(), "isSome(o) calls the val, which answers false")
  assertTrue(Std.Core.isSome(Some(value = 1)), "the import is still reachable qualified")
}

test "a function-typed parameter and local hide the imported function" {
  assertFalse(parameterCall({ o -> false }), "the parameter answers false")
  assertFalse(localCall(), "the local answers false")
}

test "an aliased facade import reaches a re-exported function" {
  val xs: Coll.List[Int] = Coll.newList()
  xs.add(3)
  xs.add(4)
  assertEqualInt(first(xs), 3, "Coll.newList() builds a usable list")
  assertEqualInt(xs.count, 2, "the list holds both elements")
  val m: Coll.Map[String, Int] = Coll.newMap()
  m.add("a", 9)
  assertEqualInt(m.count, 1, "Coll.newMap() builds a usable map")
}

test "an explicit alias type argument specialises on the alias target" {
  val total: Count = sum2[Count](1, 2)
  assertEqualInt(total, 3, "sum2[Count]")
  assertEqualInt(sum2[Int](4, 5), 9, "sum2[Int] still works")
}
