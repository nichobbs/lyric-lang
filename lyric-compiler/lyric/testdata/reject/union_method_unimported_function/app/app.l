package App

import Std.Console

func main(): Unit {
  val o: Option[Int] = Some(value = 1)
  println(toString(o.frob()))
}
