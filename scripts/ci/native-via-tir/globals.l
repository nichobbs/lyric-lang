//! globals.l - module-level `val`s read from TIR (docs/70 phase 4a part 6, D535): a literal initialiser is
//! inlined as a constant, a string literal is built at each read, and any other initialiser is the
//! hoisted function whose global `mvensure.<init>` computes on first use.  Every function lowers from TIR
//! and prints what the AST path prints.
package GlobalsViaTir

import Std.Core
import Std.Console as Console

val LIMIT: Int = 41

val BIG: Long = 3000000000

val NAME: String = "gv"

val TWICE: Int = LIMIT * 2

val GREETING: String = "hello " + NAME

val NEG: Int = -5

val LETTER: Char = 'x'

val RATIO: Double = 1.5

val FLAG: Bool = true

func limitPlus(n: in Int): Int {
  LIMIT + n
}

func big(): Long {
  BIG + BIG
}

func twice(): Int {
  TWICE
}

func label(): String {
  NAME
}

func greeting(): String {
  GREETING
}

func literals(): String {
  toString(NEG) + toString(LETTER) + toString(RATIO) + toString(FLAG)
}

func main(): Unit {
  println(toString(limitPlus(1)))
  println(toString(big()))
  println(toString(twice()))
  println(label())
  println(greeting())
  println(greeting())
  println(literals())
}
