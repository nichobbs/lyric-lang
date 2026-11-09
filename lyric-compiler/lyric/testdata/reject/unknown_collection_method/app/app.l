package App

import Std.Collections

// `insert` and `get` are no members of a `List` or `Map`: a collection has
// only the members the backends lower by name (#7683).
func main(): Unit {
  val xs: List[Int] = newList()
  xs.insert(0, 1)
  val m: Map[String, Int] = newMap()
  println(toString(m.get("a")))
}
