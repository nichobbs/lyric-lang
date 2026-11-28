//! keptast.l - the construct the TIR lowering leaves on the AST path (docs/70 phase 4a, D859): `==` on a fixed array.
//! `toString` of an enum (D874) and `default()` of a `String`, a by-value record and a list (D875) lower from TIR and
//! are printed here to show they agree with the AST path.  The kept function falls back with its census reason and
//! the program prints what the AST path prints; `native-via-tir-e2e.sh` runs it both ways and requires the one
//! fallback, so the default build keeps it correct until the TIR lowering covers it.
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
  println("[" + blank() + "]")
  val z = zeroPair()
  println(toString(z.a) + "," + toString(z.b))
  println(toString(listLater()))
  println(toString(plain(4)))
}
