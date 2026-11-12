//! closures.l - function types, lambdas and calls through function values lowered from TIR
//! (docs/70 phase 4a, D520): a closure is a heap object holding the code pointer and the
//! captured values.  `native-via-tir-e2e.sh` runs it both ways and under AddressSanitizer.
package ClosuresViaTir

import Std.Core
import Std.Console as Console

func apply(f: in (Int) -> Int, x: in Int): Int {
  f(x)
}

func twice(f: in (Int) -> Int, x: in Int): Int {
  f(f(x))
}

func makeAdder(n: in Int): (Int) -> Int {
  { x -> x + n }
}

func greet(prefix: in String): (String) -> String {
  { name -> prefix + name }
}

func nest(prefix: in String): () -> String {
  val inner: (String) -> String = { s -> prefix + s }
  { -> inner("x") }
}

func run(f: in () -> Unit): Unit {
  f()
}

func main(): Unit {
  val base = 10
  val add = makeAdder(base)
  println(toString(apply(add, 5)))
  println(toString(twice(add, 1)))
  val label = "n="
  val show: (Int) -> String = { n -> label + toString(n) }
  println(show(7))
  println(greet("hi ")("there"))
  val double: (Int) -> Int = { n -> n * 2 }
  println(toString(twice(double, 3)))
  run({ -> println("ran") })
  println(nest("p-")())
}
