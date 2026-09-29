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

// #7745: the handler entry starts at depth 1 and the yields inside and after
// the `try` push two-slot Long/Double operands; `run()`'s `max_stack` is the
// exact tracked peak, so both must be counted for the class to verify.
async func genWideInsideTry(a: in Long, b: in Long, log: in List[String]): Long {
  try {
    yield a * b + a
    panic("after the wide yield")
  } catch Bug as _ {
    log.add("handled")
  }
  yield b + a * b
}

test "Long yields inside and after a try keep their values" {
  val log: List[String] = newList()
  val seen: List[Long] = newList()
  for x in genWideInsideTry(4000000000, 2, log) {
    seen.add(x)
  }
  assertEqualInt(seen.count, 2, "both yields arrive")
  assertEqualLong(seen[0], 12000000000, "4e9 * 2 + 4e9")
  assertEqualLong(seen[1], 8000000002, "2 + 4e9 * 2")
  assertEqualInt(log.count, 1, "the body's handler ran once")
}

async func genDoubleInsideTry(x: in Double, log: in List[String]): Double {
  try {
    yield (x + 1.0) * (x - 1.0)
    panic("after the Double yield")
  } catch Bug as _ {
    log.add("handled")
    yield x * (x + x * 0.5)
  }
}

test "Double yields inside a try and its handler keep their values" {
  val log: List[String] = newList()
  val seen: List[Double] = newList()
  for d in genDoubleInsideTry(3.0, log) {
    seen.add(d)
  }
  assertEqualInt(seen.count, 2, "the try-body yield and the handler yield arrive")
  assertTrue(seen[0] == 8.0, "(3 + 1) * (3 - 1) = 8")
  assertTrue(seen[1] == 13.5, "3 * (3 + 3 * 0.5) = 13.5")
  assertEqualInt(log.count, 1, "the body's handler ran once")
}
