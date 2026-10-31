package App

import Std.Core

func bigger[T](a: in T, b: in T): Bool
  where T: Compare
{
  a > b
}

aspect Pos {
  matches: name in { f }
  ensures: bigger(result, 1u64)
  around(call) -> ret {
    ret = call.proceed()
  }
}

func f(x: ULong): ULong {
  return x
}

func main(): Unit {
  println(f(18446744073709551615u64))
}
