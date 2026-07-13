//! opaque_option_field_self_test.l — runtime regression test for matching an
//! `Option[T]` field stored inside an opaque type, on the MSIL backend (#5576).
//!
//! Before the fix, the opaque-type field-registration loop never recorded the
//! positional `fieldDeclaredNames` entry that the constructor-argument
//! type-hint recovery relies on.  So a bare `None` field initializer erased to
//! `Option_None<object>` instead of the field's declared `Option<T>`, and a
//! later `match` on the field's closed instantiation panicked as non-exhaustive
//! ("match not exhaustive ... arms=2") even with both arms present.  The
//! identical field in a plain `record` works.  The fix registers the positional
//! field name for opaque fields too, mirroring the record path.
//!
//! Runs on `--target dotnet` (the MSIL fix).  The JVM backend has a separate,
//! structurally-unrelated gap for the same shape (a class-load VerifyError; no
//! `fieldDeclaredNames` mechanism exists in the JVM emitter) tracked separately
//! — this test is not wired for `--target jvm`.
//!   lyric test --target dotnet lyric-compiler/lyric/opaque_option_field_self_test.l
//! Imports only `Std.*` (no `LYRIC_LOAD_COMPILER=1`).
@test_module
package Lyric.OpaqueOptionFieldSelfTest

import Std.Core
import Std.Testing

opaque type HolderS {
  v: Option[String]
}

func HolderS.value(self: in HolderS): Option[String] = self.v

func makeNoneS(): HolderS = HolderS(v = None)

func makeSomeS(s: in String): HolderS = HolderS(v = Some(value = s))

func readNoneS(): String {
  match makeNoneS().value() {
    case Some(s) -> s
    case None -> "none"
  }
}

func readSomeS(): String {
  match makeSomeS("hi").value() {
    case Some(s) -> s
    case None -> "none"
  }
}

opaque type HolderI {
  v: Option[Int]
}

func HolderI.value(self: in HolderI): Option[Int] = self.v

func makeNoneI(): HolderI = HolderI(v = None)

func readNoneI(): Int {
  match makeNoneI().value() {
    case Some(n) -> n
    case None -> 0 - 1
  }
}

test "opaque Option[String] field None matches, not panic (#5576)" {
  assertEqual(readNoneS(), "none", "None arm is reached, no exhaustiveness panic")
}

test "opaque Option[String] field Some matches with its payload" {
  assertEqual(readSomeS(), "hi", "Some payload is read")
}

test "opaque Option[Int] field None matches (generic-payload variant)" {
  assertEqualInt(readNoneI(), 0 - 1, "Int None arm is reached")
}
