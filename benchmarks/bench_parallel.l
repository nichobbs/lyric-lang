//! benchmarks/bench_parallel.l - Std.Parallel.forChunks scaling (docs/67 G8).
//!
//! One buffer of a million elements goes through a per-element kernel heavy enough that the work,
//! not the copy-in and copy-out of the chunks, dominates.  `benchChunksParallel` runs it with
//! `forChunks`, which uses every thread the pool has (`LYRIC_THREADS` picks the count); the
//! `benchChunksSerial` twin runs the same kernel in one loop.  `scripts/ci/parallel-e2e.sh`
//! compares `benchChunksParallel` at one thread and at all of them and requires it to scale.
//!
//! Run with: lyric bench benchmarks/bench_parallel.l --target native
@bench_module
package Bench.Parallel

import Std.Core
import Std.Buffer as Buf
import Std.Parallel
import Std.Bench

val elements: Int = 1000000

val chunk: Int = 8192

func kernel(seed: Int): Int {
  var x = seed
  var k = 0
  while k < 40 {
    x = (x * 1103 + 12345) % 1000003
    k = k + 1
  }
  x
}

func input(): buffer[Int] {
  var b = Buf.filled(elements, 0)
  var i = 0
  while i < elements {
    b[i] = i
    i = i + 1
  }
  b
}

@bench
pub func benchChunksParallel(): Unit {
  var b = input()
  forChunks(
    b,
    chunk,
    { start: Int, c: buffer[Int] -> var w = c; var j = 0; while j < w.length { w[j] = kernel(w[j]); j = j + 1 }; w }
  )
  if b[7] < 0 {
    println(toString(b[7]))
  }
}

@bench
pub func benchChunksSerial(): Unit {
  var b = input()
  var j = 0
  while j < b.length {
    b[j] = kernel(b[j])
    j = j + 1
  }
  if b[7] < 0 {
    println(toString(b[7]))
  }
}
