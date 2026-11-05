package App

import Std.Collections

// A spawned task runs at the same time as its spawner, and a `List` is
// unsynchronised, so it is not `Send` (D404).
async func count(xs: in List[Int]): Int {
  xs.count
}

async func run(): Int {
  val xs: List[Int] = [1, 2, 3]
  scope {
    val t = spawn count(xs)
    return await t
  }
}

func main(): Unit {
  println(toString(await run()))
}
