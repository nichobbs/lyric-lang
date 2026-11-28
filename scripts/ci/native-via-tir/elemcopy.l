//! elemcopy.l - an array element passed by reference is copied in and out around the call (D179), lowered from
//! TIR (docs/70 phase 4a).  The callee writes the whole array beside the element, so the store back is the last
//! write; `native-via-tir-e2e.sh` runs it both ways and checks that nothing falls back to the AST path.
package ElemCopyViaTir

import Std.Core
import Std.Console as Console

func elemAlias(x: inout Int, a: inout array[3, Int]): Int {
  a[0] = 100
  x = x + 1
  a[0] + x
}

func fill(x: out Int): Unit {
  x = 7
}

func main(): Unit {
  var a: array[3, Int] = [1, 2, 3]
  Console.println(toString(elemAlias(a[0], a)))
  Console.println(toString(a[0]))
  var b: array[3, Int] = [0, 0, 0]
  fill(b[1])
  Console.println(toString(b[1]))
}
