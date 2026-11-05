package App

import Std.Collections

// The spawned task reaches module state through a call; a module-level `List`
// is not `Send` (D404).
val seen: List[Int] = [1, 2, 3]

func seenCount(): Int {
  seen.count
}

async func report(): Int {
  seenCount()
}

async func run(): Int {
  scope {
    val t = spawn report()
    return await t
  }
}

func main(): Unit {
  println(toString(await run()))
}
