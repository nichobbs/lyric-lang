//! scalars.l - a program whose functions are all scalar, so `--via-tir` lowers them from
//! TIR (docs/70 phase 4a, D520); `native-via-tir-e2e.sh` runs it both ways.
package ScalarsViaTir

import Std.Core
import Std.Console as Console

func classify(x: in Int): Int {
  match x {
    case 1 -> 10
    case 2 ..= 5 -> 20
    case n if n > 100 -> n
    case _ -> 0
  }
}

func sumTo(n: in Int): Int {
  var acc = 0
  for i in 0 ..= n {
    acc += i
  }
  acc
}

func countUp(n: in Int): Int {
  var i = 0
  while i < n {
    i += 1
  }
  i
}

func skipOdd(n: in Int): Int {
  var acc = 0
  for i in 0 .. n {
    if i % 2 == 1 {
      continue
    }
    acc += i
  }
  acc
}

func quot(a: in Int, b: in Int): Int {
  a / b
}

func both(a: in Bool, b: in Bool): Bool {
  a and b
}

func main(): Unit {
  Console.println(classify(1).toString())
  Console.println(classify(3).toString())
  Console.println(classify(500).toString())
  Console.println(classify(50).toString())
  Console.println(sumTo(4).toString())
  Console.println(countUp(7).toString())
  Console.println(skipOdd(10).toString())
  Console.println(quot(20, 4).toString())
  Console.println(both(true, false).toString())
}
