//! println_extern_jvm_self_test.l — JVM runtime regression test for `println`
//! of an extern Java object reached through auto-FFI (#7858).
//!
//! `println` passed every reference other than `String`/`Object` to
//! `PrintStream.println(String)` unconverted, so the class failed
//! verification. It now prints what `toString(x)` returns.
//!
//! Each case prints the value and then its `toString` between the
//! `println-pairs-begin` and `println-pairs-end` markers;
//! `scripts/ci/println-stringify-e2e.sh` checks the pairs are equal. JVM-only:
//! the extern types are JDK classes.
//!
//!   lyric test --target jvm lyric-compiler/lyric/println_extern_jvm_self_test.l
@test_module
package Lyric.PrintlnExternJvmSelfTest

import Std.Core
import Std.Testing

extern type JDuration = "java.time.Duration"

extern type JLocalDate = "java.time.LocalDate"

test "toString of an extern object" {
  assertEqual(toString(JDuration.ofMinutes(90i64)), "PT1H30M", "Duration")
  assertEqual(toString(JLocalDate.of(2020, 1, 2)), "2020-01-02", "LocalDate")
}

test "println of an extern object" {
  val span = JDuration.ofMinutes(90i64)
  val day = JLocalDate.of(2020, 1, 2)
  println("println-pairs-begin")
  println(span)
  println(toString(span))
  println(day)
  println(toString(day))
  println(JDuration.ofSeconds(5i64))
  println(toString(JDuration.ofSeconds(5i64)))
  println("println-pairs-end")
  assertTrue(true, "printing an extern object does not throw")
}
