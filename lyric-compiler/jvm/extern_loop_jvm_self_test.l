//! extern_loop_jvm_self_test.l — CI gate for #3307: an `extern type` value bound
//! to a local and used across a basic-block boundary (a `while` loop back-edge,
//! or across an `if`) must keep its resolved JVM class in the StackMapTable
//! frame so the next `invokevirtual` verifies.
//!
//! Before the fix, `emitStore` (jvm/codegen/01_types.l) lowered every `JRef`
//! local store to a bare `LAstore`, which the frame builder records as
//! `java/lang/Object`.  A `sink.write(...)` after the loop header then failed
//! JVM bytecode verification: "Type 'java/lang/Object' is not assignable to
//! 'java/io/ByteArrayOutputStream'".  The fix emits `LAstoreAs(slot, cls)` so
//! the frame carries the real class.
//!
//! Run via the native test runner on the JVM target:
//!
//!   lyric test --target jvm lyric-compiler/jvm/extern_loop_jvm_self_test.l
//!
//! `lyric test` compiles the module in-process through the self-hosted
//! `Jvm.Bridge` and runs it under `java`, asserting every embedded assertion.
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.ExternLoopJvmSelfTest

import Std.Core
import Std.Testing

extern type JBAOS = "java.io.ByteArrayOutputStream"

// The exact #3307 minimal repro: an extern handle driven through a bare `while`
// loop.  `write(int)` writes the low byte; after three iterations `size()` is 3.
test "extern handle across a while loop verifies and runs (#3307)" {
  val sink = JBAOS.new()
  var i = 0
  while i < 3 {
    sink.write(65)
    i = i + 1
  }
  assertEqualInt(sink.size(), 3, "3x write(65) leaves size() == 3")
}

// An `if` inside the loop body is a further basic-block split over the same
// extern local — the frame must still type `sink` precisely at every target.
test "extern handle across a while loop with an inner if (#3307)" {
  val sink = JBAOS.new()
  var i = 0
  while i < 5 {
    if i % 2 == 0 {
      sink.write(88)
    } else {
      sink.write(89)
    }
    i = i + 1
  }
  // i = 0,2,4 -> 'X' (3x); i = 1,3 -> 'Y' (2x); total 5 bytes.
  assertEqualInt(sink.size(), 5, "5 conditional writes leave size() == 5")
}

// A `val`-bound extern handle reused after the loop (the post-loop use is its
// own basic-block successor) — the frame at the join must still carry the class.
test "extern handle used after a while loop (#3307)" {
  val sink = JBAOS.new()
  var i = 0
  while i < 4 {
    sink.write(90)
    i = i + 1
  }
  sink.write(90)
  assertEqualInt(sink.size(), 5, "4 in-loop writes + 1 post-loop write == 5")
}

// Two extern locals of the *same* class live across the loop — both slots must
// be framed with their class, not Object.
test "two extern handles across a loop (#3307)" {
  val a = JBAOS.new()
  val b = JBAOS.new()
  var i = 0
  while i < 3 {
    a.write(65)
    b.write(66)
    b.write(66)
    i = i + 1
  }
  assertEqualInt(a.size(), 3, "a accumulated 3 bytes")
  assertEqualInt(b.size(), 6, "b accumulated 6 bytes")
}
