package App

import Std.Core

enum Color {
  case Red
  case Green
}

@derive(Ord)
record Swatch { c: Color; n: Int }

func main(): Int {
  0
}
