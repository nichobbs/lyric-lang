//! overloads.l - generic functions of one name that differ in their defaults (docs/70 phase 3c, #9431): each call
//! binds to the declaration that fills the fewest defaults and runs that declaration's body, from TIR.
//! `native-via-tir-e2e.sh` runs it both ways.
package OverloadsViaTir

import Std.Core
import Std.Console as Console

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
}
