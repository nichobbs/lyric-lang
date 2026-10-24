//! benchmarks/bench_buffer.l — `buffer[T]` element reads and writes.
//!
//! Measures the inner loop of bulk numeric code: an element read, added to,
//! and written back, over a large buffer.  On `--target native` a write to a
//! buffer nothing else references is one load and a branch on its reference
//! count before the store (docs/67 §4.4), so `benchBufferInPlaceWrites`'s
//! allocation is the single `filled` call that builds the buffer, however many
//! writes follow; `benchBufferCopyOnFirstWrite` allocates one copy of the buffer
//! per iteration, the write that meets a shared block.
//!
//! `benchBufferPassIn` shows an `in` pass of a large buffer copying nothing, on
//! every target.
//!
//! Run with: lyric bench benchmarks/bench_buffer.l --target native
@bench_module
package Bench.Buffer

import Std.Core
import Std.Bench
import Std.Buffer

// ─── In-place writes to an unshared buffer ────────────────────────────────────
@bench
pub func benchBufferInPlaceWrites(): Unit {
  var b = filled(10000, 0)
  var r = 0
  while r < 100 {
    var i = 0
    while i < 10000 {
      b[i] = b[i] + i
      i = i + 1
    }
    r = r + 1
  }
  if b[9999] < 0 {
    println(toString(b[9999]))
  }
}

// ─── A write after the buffer was shared copies it once ───────────────────────
@bench
pub func benchBufferCopyOnFirstWrite(): Unit {
  var a = filled(10000, 1)
  var r = 0
  while r < 100 {
    var b = a
    b[0] = r
    a[1] = r
    r = r + 1
  }
  if a[1] < 0 {
    println(toString(a[1]))
  }
}

// ─── Passing a large buffer to an `in` parameter ──────────────────────────────
// A pass is a logical copy, so it marks the storage shared and copies nothing:
// the allocation per run is the one `filled` call plus a small handle per pass
// on every target, where an eager copy allocated a whole buffer per pass on
// dotnet and the JVM (docs/67 §4.4).
func firstElement(b: in buffer[Int]): Int {
  b[0]
}

@bench
pub func benchBufferPassIn(): Unit {
  var b = filled(100000, 1)
  var total = 0
  var r = 0
  while r < 1000 {
    total = total + firstElement(b)
    r = r + 1
  }
  if total < 0 {
    println(toString(total))
  }
}
