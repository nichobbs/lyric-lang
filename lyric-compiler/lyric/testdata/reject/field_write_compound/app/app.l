package App

import Std.String

record Box { s: String }

func f(): String {
  val b = Box(s = "a")
  b.s += "z"
  b.s
}

func main(): Int { 0 }
