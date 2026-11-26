//! keptast.l - constructs the TIR lowering leaves on the AST path (docs/70 phase 4a, D859): `toString` of an enum
//! (the case name, not the ordinal), `==` on a fixed array, and `default()` of a `String`.  Each function falls back
//! with its census reason and the program prints what the AST path prints; `native-via-tir-e2e.sh` runs it both ways
//! and requires the three fallbacks, so the default build keeps them correct until the TIR lowering covers them.
package KeptAstViaTir

import Std.Core
import Std.Console as Console

enum Colour {
  case Red
  case Green
}

func name(c: in Colour): String {
  toString(c)
}

func same(a: in array[3, Int], b: in array[3, Int]): Bool {
  a == b
}

func blank(): String {
  val s: String = default()
  s
}

func plain(n: in Int): Int {
  n + 1
}

func main(): Unit {
  println(name(Green))
  val x: array[3, Int] = [1, 2, 3]
  val y: array[3, Int] = [1, 2, 3]
  println(toString(same(x, y)))
  println("[" + blank() + "]")
  println(toString(plain(4)))
}
