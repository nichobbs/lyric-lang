package App

// No expected function type fixes the type of `x` (T0231).
func main(): Unit {
  val f = { x -> false }
  println(toString(f(1)))
}
