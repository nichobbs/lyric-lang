//! strings.l - String-typed functions lowered from TIR (docs/70 phase 4a, D520): literals,
//! concatenation, comparison, `length`, `toString`, locals, early exits and branch values.
//! `native-via-tir-e2e.sh` runs it under AddressSanitizer, so a leaked, double-released or
//! prematurely released string fails the run.
package StringsViaTir

import Std.Core
import Std.Console as Console

func greet(name: in String): String {
  "Hello, " + name
}

func twice(s: in String): String {
  s + s
}

func describe(n: in Int): String {
  if n < 0 {
    "neg"
  } else if n == 0 {
    "zero"
  } else {
    "pos:" + n.toString()
  }
}

func joinAll(n: in Int): String {
  var acc = ""
  for i in 0 .. n {
    acc = acc + i.toString()
  }
  acc
}

func firstNonEmpty(a: in String, b: in String): String {
  if a.length > 0 {
    a
  } else {
    b
  }
}

func early(s: in String): String {
  val t = s + "!"
  if t.length > 3 {
    return t
  }
  "short"
}

func same(a: in String, b: in String): Bool {
  a == b
}

func countdown(n: in Int): String {
  var result = ""
  var i = n
  while i > 0 {
    val piece = i.toString() + ","
    if i == 2 {
      i = i - 1
      continue
    }
    result = result + piece
    if i == 1 {
      break
    }
    i = i - 1
  }
  result
}

func main(): Unit {
  Console.println(greet("world"))
  Console.println(twice("ab"))
  Console.println(describe(-5))
  Console.println(describe(0))
  Console.println(describe(7))
  Console.println(joinAll(5))
  Console.println(firstNonEmpty("", "fallback"))
  Console.println(firstNonEmpty("first", "fallback"))
  Console.println(early("ab"))
  Console.println(early("abcd"))
  Console.println(same("x", "x").toString())
  Console.println(same("x", "y").toString())
  Console.println(countdown(4))
}
