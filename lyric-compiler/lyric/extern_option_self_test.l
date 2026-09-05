//! extern_option_self_test.l — regression test for the @externTarget Option[T]
//! null-coercion convention (null-free FFI boundary), D107.
//!
//! An @externTarget whose declared return is Option[T] (T a reference type)
//! binds the underlying host method to its real nullable reference return `T`
//! and coerces the result into Option[T] at the call boundary: a null
//! reference becomes None, a non-null reference becomes Some(value).  This
//! lets the audited _kernel/ boundary consume nullable host APIs without any
//! `null` literal or nullable type in the language.
//!
//! Phase 1 (MSIL, D107) and Phase 2 (JVM, #3932, D-progress-877) both bind an
//! environment-variable read: `System.Environment.GetEnvironmentVariable` on
//! dotnet, `java.lang.System.getenv` on the JVM.  Both targets share the same
//! two test cases — an env var that's guaranteed unset coerces to None, and
//! PATH (set in every real process, on both targets) coerces to Some — so no
//! per-target setter is needed to exercise either branch.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/extern_option_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/extern_option_self_test.l
@test_module
package Lyric.ExternOptionSelfTest

import Std.Core
import Std.Testing

@cfg(target = "dotnet")
@externTarget("System.Environment.GetEnvironmentVariable")
func getEnvOpt(key: in String): Option[String] = ()

@cfg(target = "jvm")
@externTarget("java.lang.System.getenv")
func getEnvOpt(key: in String): Option[String] = ()

test "unset variable coerces null to None" {
  val isNone = match getEnvOpt("LYRIC_EXTERN_OPTION_TEST_GUARANTEED_UNSET_9f3a1c7e2b4d") {
    case None -> true
    case Some(_) -> false
  }
  assertTrue(isNone, "an unset env var must coerce the underlying host null to None")
}

test "set variable (PATH) coerces the value to Some" {
  val got = match getEnvOpt("PATH") { case None -> ""; case Some(v) -> v }
  assertTrue(
    got.length > 0,
    "PATH is set in every real process; the non-null return must coerce to Some(value) with a non-empty value"
  )
}
