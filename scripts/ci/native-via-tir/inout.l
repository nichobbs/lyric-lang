//! inout.l - out and inout parameters, and assignment to record fields, lowered from TIR (docs/70
//! phase 4a, D520): a by-reference parameter is the address of the caller's cell.
//! `native-via-tir-e2e.sh` runs it both ways and under AddressSanitizer.
package InoutViaTir

import Std.Core
import Std.Console as Console

ref record Counter {
  var n: Int
  var tag: String
}

func bump(x: inout Int): Unit {
  x = x + 1
}

func fill(k: out Int): Unit {
  k = 42
}

func setStr(s: inout String, v: in String): Unit {
  s = v
}

func touch(c: inout Counter): Unit {
  c.n = c.n + 1
  c.tag = c.tag + "!"
}

func swapTags(a: inout Counter, b: inout Counter): Unit {
  val t = a.tag
  a.tag = b.tag
  b.tag = t
}

func main(): Unit {
  var total = 0
  var i = 0
  while i < 3 {
    bump(total)
    i = i + 1
  }
  println(toString(total))
  var k = 0
  fill(k)
  println(toString(k))
  var s = "a"
  setStr(s, "b" + "c")
  println(s)
  var c = Counter(n = 1, tag = "t")
  touch(c)
  touch(c)
  bump(c.n)
  println(toString(c.n) + c.tag)
  var d = Counter(n = 0, tag = "d")
  swapTags(c, d)
  println(c.tag + d.tag)
}
