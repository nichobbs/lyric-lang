//! tuples.l - tuples lowered from TIR (docs/70 phase 4a, D520): a tuple is a heap record of its
//! elements, a destructuring `let` and a tuple pattern read them back.  `native-via-tir-e2e.sh`
//! runs it both ways and under AddressSanitizer.
package TuplesViaTir

import Std.Core
import Std.Console as Console

func pair(n: in Int): (Int, String) {
  (n, "n" + toString(n))
}

func swap(p: in (Int, Int)): (Int, Int) {
  val (a, b) = p
  (b, a)
}

func describe(p: in (Int, String)): String {
  match p {
    case (n, s) -> match n {
      case 0 -> "zero:" + s
      case 1 -> "one"
      case _ -> s + "/" + toString(n)
    }
  }
}

func nested(): Int {
  val ((a, b), c) = ((1, 2), 3)
  a * 100 + b * 10 + c
}

func label(): String {
  val (n, s) = pair(5)
  s + "=" + toString(n)
}

func main(): Unit {
  println(label())
  val (x, y) = swap((3, 4))
  println(toString(x) + "," + toString(y))
  println(describe(pair(0)))
  println(describe((1, "ignored")))
  println(describe(pair(9)))
  println(toString(nested()))
}
