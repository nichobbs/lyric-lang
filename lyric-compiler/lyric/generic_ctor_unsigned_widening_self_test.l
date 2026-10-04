//! generic_ctor_unsigned_widening_self_test.l — runtime regression test for
//! implicit unsigned widening through generic constructor arguments and tuple
//! elements (#7813).
//!
//! The `Byte < UInt < ULong` half of `generic_ctor_widening_self_test.l`.  A
//! `UInt` lowers to the same 32-bit representation as an `Int` on dotnet and
//! the JVM, so its widening to `ULong` must zero-extend (#7805): every `UInt`
//! below has its top bit set (`4000000000u32`), so a sign extension would turn
//! it into 18446744073414584320.  The type checker records each widening and
//! `Lyric.Mono` spells it out as `.toULong()` / `.toUInt()` (`conv.u8` /
//! `Integer.toUnsignedLong`) before the construction.  Native has no unsigned
//! integer types yet, so this runs on dotnet and JVM.
//!
//! Run via `lyric test`:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/generic_ctor_unsigned_widening_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/generic_ctor_unsigned_widening_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.GenericCtorUnsignedWideningSelfTest

import Std.Core
import Std.Collections
import Std.Testing

record Box[T] {
  value: T
}

union Size[T] {
  case Known(n: T)
  case Unknown
}

func big(): UInt {
  4000000000u32
}

func optU(o: in Option[ULong]): ULong {
  match o {
    case Some(v) -> v
    case None -> 0u64
  }
}

func tupleU(t: in (ULong, Int)): ULong {
  val (a, _) = t
  a
}

func someU(u: in UInt): Option[ULong] {
  return Some(u)
}

func tupleOf(u: in UInt): (ULong, Int) = (u, 1)

func takesOpt(o: in Option[ULong]): ULong {
  optU(o)
}

test "Some zero-extends a UInt to ULong" {
  val u = big()
  val a: Option[ULong] = Some(u)
  assertTrue(optU(a) == 4000000000u64, "Some(u) as Option[ULong] is 4000000000")
}

test "a tuple element zero-extends a UInt to ULong" {
  val u = big()
  val b: (ULong, Int) = (u, 1)
  assertTrue(tupleU(b) == 4000000000u64, "(u, 1) as (ULong, Int) is 4000000000")
}

test "Ok and Err zero-extend" {
  val u = big()
  val r: Result[ULong, String] = Ok(u)
  val ok = match r { case Ok(v) -> v; case Err(_) -> 0u64 }
  assertTrue(ok == 4000000000u64, "Ok(u) as Result[ULong, String]")
  val e: Result[Int, ULong] = Err(u)
  val err = match e { case Ok(_) -> 0u64; case Err(v) -> v }
  assertTrue(err == 4000000000u64, "Err(u) as Result[Int, ULong]")
}

test "a Byte widens to UInt and ULong" {
  val b: Byte = 255.toByte()
  val ou: Option[UInt] = Some(b)
  val got = match ou { case Some(v) -> v; case None -> 0u32 }
  assertTrue(got == 255u32, "Some(b) as Option[UInt]")
  val ol: Option[ULong] = Some(b)
  assertTrue(optU(ol) == 255u64, "Some(b) as Option[ULong]")
}

test "nested constructions zero-extend" {
  val u = big()
  val ot: Option[(ULong, Int)] = Some((u, 1))
  val got = match ot { case Some(t) -> tupleU(t); case None -> 0u64 }
  assertTrue(got == 4000000000u64, "Some((u, 1)) as Option[(ULong, Int)]")
  val xs: List[(ULong, Int)] = [(u, 1), (u, 2)]
  var total = 0u64
  for t in xs {
    total = total + tupleU(t)
  }
  assertTrue(total == 8000000000u64, "[(u, 1), (u, 2)] as List[(ULong, Int)]")
}

test "generic records and unions zero-extend" {
  val u = big()
  val b: Box[ULong] = Box(u)
  assertTrue(b.value == 4000000000u64, "Box(u) as Box[ULong]")
  val s: Size[ULong] = Known(n = u)
  val n = match s { case Known(v) -> v; case Unknown -> 0u64 }
  assertTrue(n == 4000000000u64, "Known(n = u) as Size[ULong]")
}

test "return, expression body and call argument zero-extend" {
  val u = big()
  assertTrue(optU(someU(u)) == 4000000000u64, "return Some(u)")
  assertTrue(tupleU(tupleOf(u)) == 4000000000u64, "an expression body's (u, 1)")
  assertTrue(takesOpt(Some(u)) == 4000000000u64, "Some(u) given an Option[ULong] parameter")
}

test "an integer literal argument takes the unsigned slot type" {
  val a: Option[ULong] = Some(4000000000)
  assertTrue(optU(a) == 4000000000u64, "Some(4000000000) as Option[ULong]")
  val b: (ULong, Int) = (5, 1)
  assertTrue(tupleU(b) == 5u64, "(5, 1) as (ULong, Int)")
}
