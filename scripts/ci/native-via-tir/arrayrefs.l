//! arrayrefs.l - `array[N, T]` of references (a counted list on native) lowered from TIR (docs/70
//! phase 4a, D520): the builder's `XArrayCopy` at a store, `XZeroValue` for `var a: array[N, String]`,
//! element reads and writes with the array's own bounds check, compound assignment and `for`.
//! `native-via-tir-e2e.sh` runs it both ways and under AddressSanitizer.
package ArrayRefsViaTir

import Std.Core
import Std.Console as Console

record Tag {
  name: String
  n: Int
}

func fill(): array[3, String] {
  var a: array[3, String]
  a[0] = "x"
  a[1] = "yy"
  a[2] = a[0] + a[1]
  a
}

func joined(a: in array[3, String]): String {
  var s = ""
  for x in a {
    s = s + x + ","
  }
  s
}

func aliasing(): String {
  var a: array[2, String] = ["p", "q"]
  var b = a
  b[0] = "Z"
  a[0] + b[0] + toString(a.length)
}

func tags(): Int {
  var ts: array[2, Tag] = [Tag(name = "a", n = 1), Tag(name = "bb", n = 2)]
  ts[1] = Tag(name = "ccc", n = 5)
  ts[0].n + ts[1].n + ts[1].name.length
}

func compound(): String {
  var a: array[2, String] = ["a", "b"]
  a[1] += "!"
  a[0] + a[1]
}

func main(): Unit {
  println(joined(fill()))
  println(aliasing())
  println(toString(tags()))
  println(compound())
}
