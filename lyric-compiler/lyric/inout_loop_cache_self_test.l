//! inout_loop_cache_self_test.l - a loop in an `out`/`inout` callee keeps the
//! caller's place in a local while nothing in the loop can reach it by another
//! path (#8371, D183 and D298), and reads and writes it in place otherwise.
//!
//! The JVM caches the place across a loop whose bytecode holds no call, field
//! access or allocation, and writes it back after the loop and on an
//! exception.  The cases pin that the result is the same as reading the place
//! at every use: plain counting loops over a local and over fields, a `break`,
//! a nested loop, and loops that reach the
//! place through a field, or a second argument.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/inout_loop_cache_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/inout_loop_cache_self_test.l
//!
//! The closure shape is in `inout_aliasing_closure_self_test.l` (native
//! closures capture values, #7891).
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.InoutLoopCacheSelfTest

import Std.Core
import Std.Testing

ref record Counters {
  var a: Int
  var b: Int
}

ref record Names {
  var s: String
}

func spin(x: inout Int, n: in Int): Unit {
  var i = 0
  while i < n {
    x = x + 1
    i = i + 1
  }
}

func spinUntil(x: inout Int, limit: in Int): Int {
  var i = 0
  while true {
    if x >= limit {
      break
    }
    x = x + 3
    i = i + 1
  }
  i
}

func nested(x: inout Int, n: in Int): Unit {
  var i = 0
  while i < n {
    var j = 0
    while j < n {
      x = x + i * j
      j = j + 1
    }
    i = i + 1
  }
}

func readOnly(x: inout Int, n: in Int): Int {
  var i = 0
  var acc = 0
  while i < n {
    acc = acc + x
    i = i + 1
  }
  acc
}

func writeOnly(x: out Int, n: in Int): Unit {
  var i = 0
  while i < n {
    x = i
    i = i + 1
  }
}

func spinLong(x: inout Long, n: in Int): Unit {
  var i = 0
  while i < n {
    x = x + 3
    i = i + 1
  }
}

func spinDouble(x: inout Double, n: in Int): Unit {
  var i = 0
  while i < n {
    x = x + 0.5
    i = i + 1
  }
}

func appendLoop(s: inout String, n: in Int): Unit {
  var i = 0
  while i < n {
    s = s + "x"
    i = i + 1
  }
}

func throughField(x: inout Int, c: in Counters, n: in Int): Unit {
  var i = 0
  while i < n {
    x = x + 1
    c.a = c.a + 10
    i = i + 1
  }
}

func twoPlaces(x: inout Int, y: inout Int, n: in Int): Unit {
  var i = 0
  while i < n {
    x = x + 1
    y = y * 2
    i = i + 1
  }
}

test "a counting loop over a local" {
  var x = 5
  spin(x, 1000)
  assertEqualInt(x, 1005, "local")
}

test "a counting loop over each field of a record" {
  val c = Counters(a = 0, b = 100)
  spin(c.a, 7)
  spin(c.b, 9)
  spin(c.a, 3)
  assertEqualInt(c.a, 10, "a")
  assertEqualInt(c.b, 109, "b")
}

test "a break leaves the loop with the place written" {
  var x = 0
  val steps = spinUntil(x, 10)
  assertEqualInt(x, 12, "x")
  assertEqualInt(steps, 4, "steps")
  val c = Counters(a = 1, b = 0)
  spinUntil(c.a, 20)
  assertEqualInt(c.a, 22, "field")
}

test "a nested loop" {
  var x = 1
  nested(x, 4)
  assertEqualInt(x, 37, "x")
}

test "a loop that only reads and a loop that only writes" {
  var x = 7
  assertEqualInt(readOnly(x, 3), 21, "read")
  assertEqualInt(x, 7, "unchanged")
  var y = 0
  writeOnly(y, 5)
  assertEqualInt(y, 4, "written")
  writeOnly(y, 0)
  assertEqualInt(y, 4, "no iteration leaves it")
}

test "other place types" {
  var l: Long = 10
  spinLong(l, 4)
  assertEqualLong(l, 22, "long")
  var d = 1.0
  spinDouble(d, 4)
  assertTrue(d == 3.0, "double")
  var s = "a"
  appendLoop(s, 3)
  assertEqual(s, "axxx", "string")
  val n = Names(s = "")
  appendLoop(n.s, 2)
  assertEqual(n.s, "xx", "string field")
}

test "a loop that also writes the place's own field sees both writes" {
  val c = Counters(a = 0, b = 0)
  throughField(c.a, c, 3)
  assertEqualInt(c.a, 33, "x then c.a each iteration")
}

test "two places are read and written in place" {
  var x = 0
  var y = 1
  twoPlaces(x, y, 4)
  assertEqualInt(x, 4, "x")
  assertEqualInt(y, 16, "y")
  var z = 1
  twoPlaces(z, z, 3)
  assertEqualInt(z, 22, "one place passed twice: (z + 1) * 2 three times")
}
