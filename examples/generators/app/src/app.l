//! Prints what the Acme.Describe generator produced for two records; a
//! union it does not describe gets a build warning.
@runtime_checked
@io
package Acme.App

import Std.Core
import Std.Console as Console

@generate(Acme.Describe)
record Order {
  id: Int
  note: String
}

@generate(Acme.Describe)
record Point {
  x: Long
  y: Long
}

// The generator describes records only: on a union it reports a warning
// (AD001) and emits nothing, and the build goes on.
@generate(Acme.Describe)
union Shape {
  case Circle(r: Int)
  case Square(side: Int)
}

func main(): Int {
  val o = Order(id = 7, note = "rush")
  val p = Point(x = 1, y = 2)
  Console.println(o.describe())
  Console.println(p.describe())
  0
}
