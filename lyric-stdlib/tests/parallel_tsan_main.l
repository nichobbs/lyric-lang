//! A program (not a test module) that drives Std.Parallel hard enough for ThreadSanitizer: a
//! protected tally hit from every thread, forChunks over three element types, a body that starts
//! another loop, and several loops one after another.  `scripts/ci/parallel-e2e.sh` compiles its
//! IR with `-fsanitize=thread` and runs it; any data race or wrong answer is a failure.
package Std.Parallel.TsanMain

import Std.Core
import Std.Collections
import Std.Buffer as Buf
import Std.Console as Console
import Std.Parallel

protected type Tally {
  var total: Int = 0
  entry add(n: in Int) {
    total = total + n
  }
  func sum(): Int {
    return total
  }
}

func fail(message: String): Int {
  Console.println("FAIL: " + message)
  1
}

func heavy(x: Int): Int {
  var v = x
  var k = 0
  while k < 20 {
    v = (v * 31 + 7) % 10007
    k = k + 1
  }
  v
}

func main(): Int {
  val tally = Tally()
  forRange(5000, { i: Int -> tally.add(i) })
  if tally.sum() != 12497500 {
    return fail("tally " + tally.sum().toString())
  }

  var ints = Buf.filled(50000, 0)
  var i = 0
  while i < ints.length {
    ints[i] = i
    i = i + 1
  }
  forChunks(
    ints,
    777,
    { start: Int, c: buffer[Int] -> var w = c; var j = 0; while j < w.length { w[j] = heavy(w[j]); j = j + 1 }; w }
  )
  var bad = 0
  i = 0
  while i < ints.length {
    if ints[i] != heavy(i) {
      bad = bad + 1
    }
    i = i + 1
  }
  if bad != 0 {
    return fail("forChunks Int: " + bad.toString() + " wrong")
  }

  var floats = Buf.filled(20000, 2.0f32)
  forChunks(
    floats,
    500,
    { start: Int, c: buffer[Float] ->
      var w = c
      var j = 0
      while j < w.length {
        w[j] = w[j] * 1.5f32 + start.toFloat()
        j = j + 1
      }
      w
    }
  )
  if floats[0] != 3.0f32 or floats[19999] != 3.0f32 + 19500.0f32 {
    return fail("forChunks Float")
  }

  var bytes = Buf.filled(10000, 1u8)
  forChunks(bytes, 100, { start: Int, c: buffer[Byte] -> Buf.filled(c.length, 9u8) })
  if bytes[9999] != 9u8 {
    return fail("forChunks Byte")
  }

  var outer = Buf.filled(64, 0)
  forChunks(
    outer,
    8,
    { start: Int, c: buffer[Int] ->
      var inner = c
      forChunks(inner, 2, { s2: Int, d: buffer[Int] -> Buf.filled(d.length, start + s2) })
      inner
    }
  )
  if outer[63] != 62 or outer[0] != 0 {
    return fail("nested forChunks " + outer[63].toString())
  }

  var round = 0
  while round < 20 {
    forRange(300, { k: Int -> tally.add(1) })
    round = round + 1
  }
  if tally.sum() != 12497500 + 6000 {
    return fail("tally after rounds")
  }
  Console.println("parallel tsan program ok (" + threadCount().toString() + " threads)")
  0
}
