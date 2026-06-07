//! toarray_array_abi_self_test.l — regression test for the conversion half of
//! the cross-emitter slice ABI fork (#2592): `List.toArray()` on a concrete
//! `List[T]` must materialise a genuine CLR `T[]`, so the result binds at an
//! array-typed boundary into the F#-built, array-based stdlib.
//!
//! Before the fix, `List.toArray()` was a no-op in the self-hosted emitter
//! (it returned the `List` receiver unchanged), so handing `xs.toArray()` to
//! e.g. `Std.Core.sumInts(Int[])` passed a `List`, not an `Int[]`, and the
//! array-based F# body operated on the wrong representation.  The fix
//! (`codegen.l` `toArray` arm → `MListOp(LoToArray, e)`) emits a real
//! `List<e>.ToArray()` returning `e[]` for a concrete `List<e>`.
//!
//! Run via native `lyric test` (in-process `Msil.Bridge`).  Imports only
//! `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed:
//!
//!   lyric test lyric-compiler/lyric/toarray_array_abi_self_test.l
@test_module
package Lyric.ToArrayArrayAbiSelfTest

import Std.Core
import Std.Collections
import Std.String as Str
import Std.Testing

test "concrete List[Int].toArray() binds as Int[] across the F# stdlib boundary" {
  val xs: List[Int] = newList()
  xs.add(10)
  xs.add(20)
  xs.add(30)
  // sumInts iterates a real Int[]; a List-backed argument would sum wrong/fault.
  assertEqualInt(sumInts(xs.toArray()), 60, "sumInts(xs.toArray()) == 60")
  assertEqualInt(maxInt(xs.toArray()), 30, "maxInt(xs.toArray()) == 30")
}

test "empty concrete List[Int].toArray() is an empty Int[]" {
  val xs: List[Int] = newList()
  assertEqualInt(sumInts(xs.toArray()), 0, "sumInts(empty) == 0")
}

test "concrete List[String].toArray() binds as String[] across the F# stdlib boundary" {
  val ws: List[String] = newList()
  ws.add("a")
  ws.add("b")
  ws.add("c")
  assertTrue(Str.join(",", ws.toArray()) == "a,b,c", "join(ws.toArray()) == a,b,c")
}
