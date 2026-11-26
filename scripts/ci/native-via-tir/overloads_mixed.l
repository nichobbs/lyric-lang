//! overloads_mixed.l - a non-generic function overloaded with generic functions of the same name (docs/70 phase 3c,
//! #9431): each call binds to the declaration the checker picks (the one that fills the fewest defaults), from TIR.
//! The AST path cannot compile this set (N0007, #9444), so `native-via-tir-e2e.sh` checks the TIR build against a fixed
//! output and does not compare the two paths.  The non-generic function comes first, so the generic overloads are the
//! second and third declarations of the set and take `__o1` and `__o2`.
package OverloadsMixedViaTir

import Std.Core
import Std.Console as Console

func gen(x: in Int): Int {
  77
}

func gen[T](x: in T, y: in Int = 1, z: in Int = 2): Int {
  y + z
}

func gen[T](x: in T, y: in Int = 1): Int {
  y * 100
}

func main(): Unit {
  println(toString(gen("a")))
  println(toString(gen("a", 3)))
  println(toString(gen("a", 3, 4)))
  println(toString(gen(5)))
}
