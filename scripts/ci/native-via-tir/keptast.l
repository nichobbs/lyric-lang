//! keptast.l - constructs the TIR lowering leaves on the AST path or used to (docs/70 phase 4a, D859): `default()` of
//! a `String` is still kept (`T.default()` of a generic specialisation is the same builtin and means each field's
//! declared default for a record, which a null value is not), while `toString` of an enum (D874) and `==` and `!=`
//! on fixed arrays of scalars (D876) lower from TIR.  The program prints what the AST path prints and
//! `native-via-tir-e2e.sh` requires the one fallback and that the other two do not fall back.
package KeptAstViaTir

import Std.Core
import Std.Console as Console

type Metres = Double

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

func sameFloats(a: in array[2, Double], b: in array[2, Double]): Bool {
  a == b
}

func nanValue(zero: in Double): Double {
  zero / zero
}

func sameMetres(a: in array[2, Metres], b: in array[2, Metres]): Bool {
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
  println(name(Blue))
  val x: array[3, Int] = [1, 2, 3]
  val y: array[3, Int] = [1, 2, 3]
  println(toString(same(x, y)))
  val w: array[3, Int] = [1, 2, 4]
  println(toString(same(x, w)))
  println(toString(differs(x, w)))
  val f1: array[2, Double] = [0.0, 1.0]
  val f2: array[2, Double] = [-0.0, 1.0]
  println(toString(sameFloats(f1, f2)))
  val n = nanValue(0.0)
  val g1: array[2, Double] = [n, 1.0]
  val g2: array[2, Double] = [n, 1.0]
  println(toString(sameFloats(g1, g2)))
  val m1: array[2, Metres] = [Metres.from(n), Metres.from(2.0)]
  val m2: array[2, Metres] = [Metres.from(n), Metres.from(2.0)]
  println(toString(sameMetres(m1, m2)))
  println("[" + blank() + "]")
  println(toString(plain(4)))
}
