//! lists.l - `List[T]` and `slice[T]` lowered from TIR (docs/70 phase 4a, D520): list and slice
//! literals, `newList`, `add`/`removeAt`/`clear`, indexing and element assignment, `count` and
//! `length`, and `for` over a list with reference elements.  `native-via-tir-e2e.sh` runs it both
//! ways and under AddressSanitizer.
package ListsViaTir

import Std.Core
import Std.Collections
import Std.Console as Console

record Tag {
  name: String
  n: Int
}

func sum(xs: in slice[Int]): Int {
  var t = 0
  for x in xs {
    t = t + x
  }
  t
}

func firstAndLen(xs: in slice[Int]): Int {
  xs[0] * 10 + xs.length
}

func squares(n: in Int): List[Int] {
  val res: List[Int] = newList()
  var i = 1
  while i <= n {
    res.add(i * i)
    i = i + 1
  }
  res
}

func joined(words: in List[String]): String {
  var s = ""
  for w in words {
    if w == "skip" {
      continue
    }
    if w == "stop" {
      break
    }
    s = s + w + ","
  }
  s
}

func tags(): List[Tag] {
  val xs: List[Tag] = newList()
  xs.add(Tag(name = "a", n = 1))
  xs.add(Tag(name = "b", n = 2))
  xs.add(Tag(name = "c", n = 3))
  xs
}

func tagTotal(xs: in List[Tag]): Int {
  var t = 0
  for x in xs {
    t = t + x.n
  }
  t
}

func edit(): String {
  val xs: List[String] = newList()
  xs.add("x")
  xs.add("y")
  xs.add("z")
  xs[1] = "Y"
  xs.removeAt(0)
  xs.add(0, "w")
  xs[0] + xs[1] + xs[2] + toString(xs.count)
}

func clearIt(): Int {
  val xs = squares(4)
  xs.clear()
  xs.count
}

func combine(): Int {
  val a: slice[Int] = [1, 2, 3]
  val b = a.append(4).concat([5, 6]).slice(1, 5)
  sum(b) * 10 + b.length
}

func main(): Unit {
  val lit: slice[Int] = [1, 2, 3, 4]
  println(toString(sum(lit)))
  println(toString(firstAndLen(lit)))
  println(toString(sum(squares(5).toArray())))
  val words: List[String] = ["a", "skip", "b", "stop", "c"]
  println(joined(words))
  println(toString(tagTotal(tags())))
  println(edit())
  println(toString(clearIt()))
  println(toString(combine()))
}
