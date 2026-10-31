//! benchmarks/bench_inout.l - hot loops in an `inout` callee (#8371, D183).
//!
//! An `inout` parameter is a place reference on the JVM. The callee below is
//! called with several kinds of place (a local and three fields of a record),
//! so a reference read or write at each use would be a megamorphic call the
//! JIT cannot inline. The benchmarks keep that call mix and measure the loop.
//!
//! Run with: lyric bench benchmarks/bench_inout.l --target jvm
@bench_module
package Bench.Inout

import Std.Core
import Std.Time

ref record Counters {
  var a: Int
  var b: Int
  var c: Int
}

func spin(x: inout Int, n: in Int): Unit {
  var i = 0
  while i < n {
    x = x * 31 + i
    i = i + 1
  }
}

// Same loop, with a short-circuit condition and a `break`.
func spinUntil(x: inout Int, limit: in Int): Unit {
  var i = 0
  while true {
    if x >= limit {
      break
    }
    x = x + 3 + i % 3
    i = i + 1
  }
}

@bench
pub func benchInoutMixedPlaces(): Unit {
  var local = 0
  val r = Counters(a = 0, b = 0, c = 0)
  spin(local, 20000000)
  spin(r.a, 20000000)
  spin(r.b, 20000000)
  spin(r.c, 20000000)
  if local + r.a + r.b + r.c == 1 {
    println("bench_inout: sink")
  }
}

@bench
pub func benchInoutBreakLoop(): Unit {
  var local = 0
  val r = Counters(a = 0, b = 0, c = 0)
  spinUntil(local, 300000000)
  spinUntil(r.a, 300000000)
  spinUntil(r.b, 300000000)
  spinUntil(r.c, 300000000)
  if local + r.a + r.b + r.c == 1 {
    println("bench_inout: sink")
  }
}
