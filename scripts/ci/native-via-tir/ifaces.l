//! ifaces.l - interfaces lowered from TIR (docs/70 phase 4a, D520): a heap record used as an
//! interface it implements (the box holds the retained object and the record's vtable), calls
//! through the box with scalar, string and record arguments and results, and a function that
//! takes and returns interface values.  `native-via-tir-e2e.sh` runs it both ways and under
//! AddressSanitizer.
package IfacesViaTir

import Std.Core
import Std.Console as Console

interface Shape {
  func area(): Int
  func label(): String
  func scaled(k: in Int): Int
}

ref record Rect {
  w: Int
  h: Int
  name: String
}

ref record Square {
  side: Int
}

impl Shape for Rect {
  func area(): Int {
    self.w * self.h
  }
  func label(): String {
    "rect " + self.name
  }
  func scaled(k: in Int): Int {
    self.w * self.h * k
  }
}

impl Shape for Square {
  func area(): Int {
    self.side * self.side
  }
  func label(): String {
    "square " + toString(self.side)
  }
  func scaled(k: in Int): Int {
    self.side * self.side * k
  }
}

func describe(s: in Shape): String {
  s.label() + "=" + toString(s.area()) + "/" + toString(s.scaled(3))
}

func pick(wide: in Bool): Shape {
  if wide {
    Rect(w = 4, h = 5, name = "big")
  } else {
    Square(side = 6)
  }
}

func total(a: in Shape, b: in Shape): Int {
  a.area() + b.area()
}

func main(): Unit {
  println(describe(Rect(w = 2, h = 3, name = "r")))
  println(describe(Square(side = 4)))
  println(describe(pick(true)))
  println(describe(pick(false)))
  println(toString(total(pick(true), Square(side = 2))))
}
