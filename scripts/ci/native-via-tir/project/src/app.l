//! app.l - the entry package of the via-TIR project fixture; every call into `Calc` crosses the
//! package boundary.
package App

import Std.Core
import Std.Console as Console
import Calc

func total(x: in Int): Int {
  Calc.scale(x, 3) + Calc.apply(Mul(by = 4), x)
}

func main(): Unit {
  println(toString(total(5)))
  val p = Calc.swap(Pair(left = 1, right = 2))
  println(toString(p.left))
  println(toString(Calc.apply(Add, 21)))
}
