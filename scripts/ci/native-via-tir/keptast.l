//! keptast.l - constructs the TIR lowering used to leave on the AST path (docs/70 phase 4a, D859): `toString` of an
//! enum (D874), `default()` of a `String`, a by-value record and a list (D875), and `==` and `!=` on fixed arrays of
//! scalars (D876).  The program prints what the AST path prints and `native-via-tir-e2e.sh` requires that none of
//! them falls back, so a regression to the AST path fails there.
package KeptAstViaTir

import Std.Core
import Std.Console as Console

enum Colour {
  case Red
  case Green
  case Blue
}

func name(c: in Colour): String {
  toString(c)
}

func same(a: in array[3, Int], b: in array[3, Int]): Bool {
  a == b
}

func differs(a: in array[3, Int], b: in array[3, Int]): Bool {
  a != b
}

func blank(): String {
  val s: String = default()
  s
}

record Pair {
  a: Int
  b: Int
}

func zeroPair(): Pair {
  val p: Pair = default()
  p
}

func listLater(): Int {
  var xs: List[Int] = default()
  xs = [1, 2]
  xs.count
}

func plain(n: in Int): Int {
  n + 1
}

func main(): Unit {
  println(name(Green))
  println(name(Blue))
  val x: array[3, Int] = [1, 2, 3]
  val y: array[3, Int] = [1, 2, 3]
  println(toString(same(x, y)))
  val w: array[3, Int] = [1, 2, 4]
  println(toString(same(x, w)))
  println(toString(differs(x, w)))
  println("[" + blank() + "]")
  val z = zeroPair()
  println(toString(z.a) + "," + toString(z.b))
  println(toString(listLater()))
  println(toString(plain(4)))
}
