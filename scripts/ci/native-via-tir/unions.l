//! unions.l - unions lowered from TIR (docs/70 phase 4a, D520): an inline tagged value (scalar
//! payloads) and a heap object with a reference payload, built and matched with bindings, a
//! literal sub-pattern and a wildcard.  `native-via-tir-e2e.sh` runs it both ways and then under
//! AddressSanitizer, so a leak or a double release of the heap payloads fails the run.
package UnionsViaTir

import Std.Core
import Std.Console as Console

union Shape {
  case Circle(r: Int)
  case Rect(w: Int, h: Int)
  case Empty
}

union Note {
  case Text(body: String)
  case Pair(left: String, right: String)
  case Nothing
}

func area(s: in Shape): Int {
  match s {
    case Circle(r) -> r * 3
    case Rect(w, h) -> w * h
    case Empty -> 0
  }
}

func unitCircle(s: in Shape): Bool {
  match s {
    case Circle(1) -> true
    case _ -> false
  }
}

func makeRect(w: in Int, h: in Int): Shape {
  Rect(w = w, h = h)
}

func render(n: in Note): String {
  match n {
    case Text(b) -> b
    case Pair(l, r) -> l + "," + r
    case Nothing -> "-"
  }
}

func twice(t: in String): Note {
  Pair(left = t, right = t)
}

func main(): Unit {
  println(toString(area(makeRect(3, 4))))
  println(toString(area(Circle(r = 5))))
  println(toString(area(Empty)))
  println(toString(unitCircle(Circle(r = 1))))
  println(toString(unitCircle(makeRect(1, 1))))
  println(render(Text(body = "hello")))
  println(render(twice("ab")))
  println(render(Nothing))
}
