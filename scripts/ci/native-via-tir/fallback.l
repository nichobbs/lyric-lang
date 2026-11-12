//! fallback.l - generic records, unions and functions stay on the AST path (docs/70 phase 4a,
//! D520, #9023): the TIR lowering has no instantiation of them until phase 3c monomorphises, so
//! each falls back with a census reason and the program still builds and prints what the AST path
//! prints, with one function lowered from TIR beside them.  `native-via-tir-e2e.sh` runs it both
//! ways and then under AddressSanitizer.
package FallbackViaTir

import Std.Core
import Std.Console as Console

record Box[T] {
  value: T
}

union Maybe[T] {
  case Has(v: T)
  case Nada
}

func unbox(b: in Box[Int]): Int {
  b.value
}

func pick(m: in Maybe[Int]): Int {
  match m {
    case Has(v) -> v
    case Nada -> 0
  }
}

func ident[T](x: in T): T {
  x
}

func plain(n: in Int): Int {
  n * 2
}

func main(): Unit {
  println(toString(plain(unbox(Box(value = 21)))))
  println(toString(pick(Has(v = 5))))
  println(toString(ident(7)))
}
