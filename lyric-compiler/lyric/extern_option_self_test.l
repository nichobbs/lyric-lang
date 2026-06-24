//! extern_option_self_test.l — regression test for the @externTarget Option[T]
//! null-coercion convention (null-free FFI boundary).
//!
//! An @externTarget whose declared return is Option[T] (T a reference type)
//! binds the MemberRef to the BCL's nullable reference return `T` and coerces
//! the result into Option[T] at the call boundary: a null reference becomes
//! None, a non-null reference becomes Some(value).  This lets the audited
//! _kernel/ boundary consume nullable BCL APIs without any `null` literal or
//! nullable type in the language.
//!
//!   lyric test lyric-compiler/lyric/extern_option_self_test.l
@test_module
package Lyric.ExternOptionSelfTest

import Std.Core
import Std.Testing

// System.Environment.GetEnvironmentVariable returns a nullable string (null
// when the variable is unset).  Declared Option[String]; the emitter coerces.
@externTarget("System.Environment.GetEnvironmentVariable")
func getEnvOpt(key: in String): Option[String] = ()

@externTarget("System.Environment.SetEnvironmentVariable")
func setEnv(key: in String, value: in String): Unit = ()

test "unset variable coerces null to None" {
  val isNone = match getEnvOpt("LYRIC_EXTERN_OPTION_UNSET_XYZ_42") { case None -> true; case Some(_) -> false }
  assertTrue(isNone, "an unset env var must coerce the BCL null to None")
}

test "set variable coerces the value to Some" {
  setEnv("LYRIC_EXTERN_OPTION_SET_42", "hello-option")
  val got = match getEnvOpt("LYRIC_EXTERN_OPTION_SET_42") { case None -> "<none>"; case Some(v) -> v }
  assertEqual(got, "hello-option", "a set env var must coerce the value to Some(value)")
}
