//! recpat.l - record patterns lowered from TIR (docs/70 phase 4a, D520): a `match` arm and a
//! destructuring `val` on a by-value record and on a heap record, with literal and string
//! sub-patterns.  The TIR lowering is tried before the AST one.  `native-via-tir-e2e.sh` runs it
//! both ways and under AddressSanitizer.
package RecpatViaTir

import Std.Core
import Std.Console as Console

record P {
  x: Int
  y: Int
}

record Tag {
  name: String
  n: Int
}

func pick(p: in P): Int {
  match p {
    case P { x = 0, y = b } -> b
    case P { x = a, y = 9 } -> a * 100
    case P { x = a, y = b } -> a + b
  }
}

func label(t: in Tag): String {
  match t {
    case Tag { name = "root", n } -> "R" + toString(n)
    case Tag { name, n = 0 } -> name + "!"
    case Tag { name, n } -> name + toString(n)
  }
}

func swapSum(p: in P): Int {
  val P { x, y } = p
  x * 10 + y
}

func tagLen(t: in Tag): Int {
  val Tag { name, n } = t
  name.length + n
}

func main(): Unit {
  println(toString(pick(P(x = 0, y = 7))))
  println(toString(pick(P(x = 3, y = 9))))
  println(toString(pick(P(x = 2, y = 5))))
  println(label(Tag(name = "root", n = 4)))
  println(label(Tag(name = "leaf", n = 0)))
  println(label(Tag(name = "leaf", n = 2)))
  println(toString(swapSum(P(x = 4, y = 2))))
  println(toString(tagLen(Tag(name = "abc", n = 5))))
}
