//! propagate_ctor_operand_try_self_test.l — runtime regression test for `?`
//! on a bare constructor inside a `try` in an async function (#8181), the
//! dotnet and JVM half of `propagate_ctor_operand_self_test.l` (the native
//! target has no `try`/`catch`, D-N-003).
//!
//! The type checker binds such an operand to a local annotated with its type
//! before `Lyric.Propagate` lowers the `?`; the pass looks through that local
//! when deciding whether the operand awaits, so a constructor operand stays
//! legal inside the protected region (F0045 fires only for an operand that
//! may await, `propagate_self_test.l`).
//!
//!   lyric test --target dotnet lyric-compiler/lyric/propagate_ctor_operand_try_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/propagate_ctor_operand_try_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.PropagateCtorOperandTrySelfTest

import Std.Core
import Std.Testing

async func okInTry(): Result[Int, String] {
  var n = 0
  try {
    val s = Ok(value = "inner")?
    n = s.length
  } catch Bug as b {
    n = -1
  }
  Ok(value = n)
}

async func errInTry(): Result[Int, String] {
  var n = 0
  try {
    val s: String = Err(error = "out")?
    n = s.length
  } catch Bug as b {
    n = -1
  }
  Ok(value = n)
}

async func noneInTry(): Option[Int] {
  var n = 0
  try {
    val s: String = None?
    n = s.length
  } catch Bug as b {
    n = -1
  }
  Some(value = n)
}

test "an Ok operand inside a try in an async function" {
  match await okInTry() {
    case Ok(v) -> assertEqualInt(v, 5, "\"inner\".length")
    case Err(e) -> assertEqual(e, "", "unexpected Err")
  }
}

test "an Err operand inside a try in an async function" {
  match await errInTry() {
    case Ok(v) -> assertEqualInt(v, -2, "unexpected Ok")
    case Err(e) -> assertEqual(e, "out", "propagated")
  }
}

test "a None operand inside a try in an async function" {
  match await noneInTry() {
    case Some(v) -> assertEqualInt(v, -2, "unexpected Some")
    case None -> assertTrue(true, "propagated")
  }
}
