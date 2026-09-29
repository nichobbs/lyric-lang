//! generator_body_try_catch_jvm_self_test.l — executable regression test
//! (#7720) for `try`/`catch` inside an async-generator body on `--target jvm`.
//!
//! `Jvm.Lowering.lowerAsyncGenerator` lowers the generator body into the
//! synthesised class's `run()` through `lowerInsn`, which treats the
//! `LTryCatch` meta-insn as a no-op — ordinary functions get their exception
//! table from `lowerFunc`'s pre-pass, which the generator path never ran.  A
//! handler written in a generator body was therefore silently dropped: the
//! panic escaped the body instead of being caught.  `run()` now registers the
//! body's own handlers, in body order, ahead of its catch-all (which forwards
//! an escaping exception to the consumer's pull).
//!
//! JVM-only for now: the dotnet backend rejects a `try`/`catch` in a generator
//! body at build time (`synthesizeGeneratorMsil: field-count prediction
//! mismatch`, the `countGeneratorFieldsMsil` scope boundary), so this file
//! cannot yet run as a dual-target test.
//!
//! Run in CI via `scripts/ci/jvm-generics-self-tests-batch.sh`:
//!
//!   lyric test --target jvm lyric-compiler/jvm/generator_body_try_catch_jvm_self_test.l
@test_module
package Jvm.GeneratorBodyTryCatchJvmSelfTest

import Std.Core
import Std.Testing

async func genCatchesInBody(log: in List[String]): Int {
  yield 1
  try {
    panic("caught inside the generator")
  } catch Bug as e {
    log.add("caught: ${e.message}")
  }
  yield 2
}

test "a try/catch inside the generator body catches its own panic" {
  val log: List[String] = newList()
  var total = 0
  for x in genCatchesInBody(log) {
    total = total + x
  }
  assertEqualInt(total, 3, "both yields around the handled panic arrive")
  assertEqualInt(log.count, 1, "the body's own handler ran once")
  assertTrue(log[0].contains("caught inside the generator"), "the handler saw the body's panic")
}

async func genYieldInsideTry(log: in List[String]): Int {
  try {
    yield 1
    panic("after the first yield")
  } catch Bug as _ {
    log.add("handled")
  }
  yield 2
}

test "a panic after a yield inside a try is handled by the body, not the consumer" {
  val log: List[String] = newList()
  val seen: List[Int] = newList()
  for x in genYieldInsideTry(log) {
    seen.add(x)
    log.add("C${x}")
  }
  assertEqualInt(seen.count, 2, "both yields arrive")
  assertEqual(log[0], "C1", "consumer sees 1 before the body resumes")
  assertEqual(log[1], "handled", "the body's handler ran on the second pull")
  assertEqual(log[2], "C2", "then the consumer sees 2")
}
