//! range_for_jvm_self_test.l — regression coverage for range-driven `for`
//! (`for i in lo ..< hi` / `lo ..= hi`) on BOTH targets (#4878 follow-up,
//! band J4).  Range `for` on the JVM (`emitCountingForJvm`) reached MSIL parity
//! here: before, a counted loop panicked with `ERange not supported in JVM
//! codegen`.  Unlike `for_loop_slice_self_test.l` (dotnet-only, exercises the
//! erased-element slice-iteration auto-FFI path, #2595), this module drives only
//! range counters — Int and Long, half-open and closed, empty, plus `break` /
//! `continue` and nesting — so it runs cleanly on `--target jvm`.  Imports only
//! `Std.*`.
//!
//!   lyric test --target dotnet lyric-compiler/jvm/range_for_jvm_self_test.l
//!   lyric test --target jvm    lyric-compiler/jvm/range_for_jvm_self_test.l
@test_module
package Jvm.RangeForJvmSelfTest

import Std.Core
import Std.Testing

func sumHalfOpen(n: Int): Int {
  var s = 0
  for i in 0 ..< n {
    s = s + i
  }
  s
}

func sumClosed(lo: Int, hi: Int): Int {
  var s = 0
  for i in lo ..= hi {
    s = s + i
  }
  s
}

func sumLong(n: Long): Long {
  var s: Long = 0i64
  for m in 0i64 ..< n {
    s = s + m
  }
  s
}

// Long counter through a CLOSED range (`lcmp` + `ifgt` exit path).
func sumLongClosed(lo: Long, hi: Long): Long {
  var s: Long = 0i64
  for m in lo ..= hi {
    s = s + m
  }
  s
}

// Count iterations of a general half-open Long range so the empty cases
// (`lo == hi` and descending `lo > hi`) exercise the `lcmp` + `ifge` exit path.
func countLongHalfOpen(lo: Long, hi: Long): Long {
  var c: Long = 0i64
  for m in lo ..< hi {
    c = c + 1i64
  }
  c
}

func sumWithBreakContinue(): Int {
  var s = 0
  for i in 0 ..< 10 {
    if i == 3 {
      continue
    }
    if i == 7 {
      break
    }
    s = s + i
  }
  s
}

func nestedGrid(): Int {
  var g = 0
  for r in 0 ..< 3 {
    for c in 0 ..< 3 {
      g = g + r * 10 + c
    }
  }
  g
}

// Count iterations of a general half-open `lo ..< hi` so the empty case with a
// NON-zero `lo == hi` is exercised directly (the exit test must fire on the very
// first check).
func countHalfOpen(lo: Int, hi: Int): Int {
  var c = 0
  for i in lo ..< hi {
    c = c + 1
  }
  c
}

test "half-open range sums 0..<5 to 10" {
  assertEqualInt(sumHalfOpen(5), 10, "0+1+2+3+4")
}

test "half-open range with n=0 is empty" {
  assertEqualInt(sumHalfOpen(0), 0, "empty loop body never runs")
}

test "closed range sums 1..=4 to 10" {
  assertEqualInt(sumClosed(1, 4), 10, "1+2+3+4")
}

test "closed range 3..=3 runs once" {
  assertEqualInt(sumClosed(3, 3), 3, "single iteration at the bound")
}

test "empty half-open range 3..<3 never runs (lo == hi > 0)" {
  assertEqualInt(countHalfOpen(3, 3), 0, "3..<3 has zero iterations")
  assertEqualInt(countHalfOpen(5, 2), 0, "a descending lo > hi is also empty")
}

test "Long-counter half-open range sums 0i64..<4i64 to 6" {
  assertEqualLong(sumLong(4i64), 6i64, "0+1+2+3 as Long")
}

test "Long-counter closed range sums 1i64..=4i64 to 10" {
  assertEqualLong(sumLongClosed(1i64, 4i64), 10i64, "1+2+3+4 as Long (lcmp/ifgt exit)")
}

test "Long-counter closed range 3i64..=3i64 runs once" {
  assertEqualLong(sumLongClosed(3i64, 3i64), 3i64, "single iteration at the Long bound")
}

test "Long-counter empty ranges never run" {
  assertEqualLong(countLongHalfOpen(3i64, 3i64), 0i64, "3i64..<3i64 has zero iterations")
  assertEqualLong(countLongHalfOpen(5i64, 2i64), 0i64, "a descending Long lo > hi is also empty")
}

test "continue advances the counter, break exits" {
  assertEqualInt(sumWithBreakContinue(), 18, "0+1+2+4+5+6 (skip 3, stop at 7)")
}

test "nested range loops accumulate correctly" {
  assertEqualInt(nestedGrid(), 99, "sum of r*10+c for r,c in 0..<3")
}
