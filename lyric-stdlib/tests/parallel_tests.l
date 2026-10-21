//! stdlib/tests/parallel_tests.l - Std.Parallel (docs/67 G8).
//!
//! The same tests run on every target: on native the loops use the worker pool, elsewhere they run
//! in order, and each assertion is about results that must not depend on which.
@test_module
package Std.Parallel.Tests

import Std.Core
import Std.Collections
import Std.Buffer as Buf
import Std.Parallel
import Std.Testing

protected type Tally {
  var total: Int = 0
  var calls: Int = 0
  entry add(n: in Int) {
    total = total + n
    calls = calls + 1
  }
  func sum(): Int {
    return total
  }
  func count(): Int {
    return calls
  }
}

func ramp(n: Int): buffer[Int] {
  var b = Buf.filled(n, 0)
  var i = 0
  while i < n {
    b[i] = i
    i = i + 1
  }
  b
}

test "there is at least one thread" {
  assertTrue(threadCount() >= 1, "threadCount")
}

test "forRange calls the body once for every index" {
  val tally = Tally()
  forRange(1000, { i: Int -> tally.add(i) })
  assertEqualInt(tally.count(), 1000, "calls")
  assertEqualInt(tally.sum(), 499500, "sum of 0 ..< 1000")
}

test "forRange with nothing to do does nothing" {
  val tally = Tally()
  forRange(0, { i: Int -> tally.add(i) })
  assertEqualInt(tally.count(), 0, "calls")
}

test "forChunks rewrites every element, the last chunk shorter" {
  var b = ramp(10007)
  forChunks(
    b,
    1000,
    { start: Int, chunk: buffer[Int] ->
      var c = chunk
      var j = 0
      while j < c.length {
        c[j] = c[j] * 2 + 1
        j = j + 1
      }
      c
    }
  )
  assertEqualInt(b.length, 10007, "length")
  var bad = 0
  var i = 0
  while i < b.length {
    if b[i] != i * 2 + 1 {
      bad = bad + 1
    }
    i = i + 1
  }
  assertEqualInt(bad, 0, "elements differing from the expected values")
}

test "a body is told where its chunk starts" {
  var b = ramp(2500)
  forChunks(
    b,
    700,
    { start: Int, chunk: buffer[Int] -> var c = chunk; var j = 0; while j < c.length { c[j] = start; j = j + 1 }; c }
  )
  assertEqualInt(b[0], 0, "first chunk")
  assertEqualInt(b[699], 0, "end of first chunk")
  assertEqualInt(b[700], 700, "second chunk")
  assertEqualInt(b[2499], 2100, "last, shorter chunk")
}

test "chunk sizes of one, of the whole buffer, and beyond it" {
  var a = ramp(64)
  forChunks(a, 1, { start: Int, chunk: buffer[Int] -> Buf.filled(1, chunk[0] + 100) })
  assertEqualInt(a[63], 163, "chunks of one")
  var b = ramp(64)
  forChunks(b, 64, { start: Int, chunk: buffer[Int] -> Buf.filled(64, 7) })
  assertEqualInt(b[10], 7, "one chunk")
  var c = ramp(64)
  forChunks(c, 10000, { start: Int, chunk: buffer[Int] -> Buf.filled(chunk.length, 9) })
  assertEqualInt(c[63], 9, "chunk larger than the buffer")
}

test "an empty buffer is left alone" {
  var e = Buf.filled(0, 0)
  forChunks(e, 8, { start: Int, chunk: buffer[Int] -> chunk })
  assertEqualInt(e.length, 0, "still empty")
}

test "a buffer shared with another binding is not disturbed" {
  var a = ramp(100)
  val keep = a
  forChunks(a, 10, { start: Int, chunk: buffer[Int] -> Buf.filled(chunk.length, 1) })
  assertEqualInt(keep[50], 50, "the other binding keeps its values")
  assertEqualInt(a[50], 1, "the buffer changed")
}

test "float and byte buffers work too" {
  var f = Buf.filled(300, 1.5f32)
  forChunks(
    f,
    64,
    { start: Int, chunk: buffer[Float] ->
      var c = chunk
      var j = 0
      while j < c.length {
        c[j] = c[j] * 2.0f32
        j = j + 1
      }
      c
    }
  )
  assertTrue(f[299] == 3.0f32, "float")
  var by = Buf.filled(300, 3u8)
  forChunks(by, 100, { start: Int, chunk: buffer[Byte] -> Buf.filled(chunk.length, 200u8) })
  assertTrue(by[150] == 200u8, "byte")
}

test "a heavy body gives the same answer as a plain loop" {
  val n = 20000
  var par = ramp(n)
  forChunks(
    par,
    512,
    { start: Int, chunk: buffer[Int] ->
      var c = chunk
      var j = 0
      while j < c.length {
        var x = c[j]
        var k = 0
        while k < 50 {
          x = (x * 31 + 7) % 10007
          k = k + 1
        }
        c[j] = x
        j = j + 1
      }
      c
    }
  )
  var bad = 0
  var i = 0
  while i < n {
    var x = i
    var k = 0
    while k < 50 {
      x = (x * 31 + 7) % 10007
      k = k + 1
    }
    if par[i] != x {
      bad = bad + 1
    }
    i = i + 1
  }
  assertEqualInt(bad, 0, "elements differing from the sequential result")
}
