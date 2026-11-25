//! ranged.l - range-checked distinct types lowered from TIR (docs/70 phase 4a, D538): `T.from` and the
//! derived arithmetic that goes through it panic outside the range with the managed targets' message,
//! the operators read their signedness and width from the wrapped primitive, and a `Byte`- or
//! `Double`-backed range compares as unsigned and ordered.  The last line panics out of range.
//! `native-via-tir-e2e.sh` runs it both ways and under AddressSanitizer.
package RangedViaTir

import Std.Core
import Std.Console as Console

type Cents = Long range 0 ..= 1000 derives Add, Sub, Mul, Compare

type Level = Byte range 1 ..= 5 derives Add, Compare

type Ratio = Double range 0.0 ..= 1.0 derives Add, Compare

ref record Wallet {
  var balance: Cents
}

func c(v: in Long): Cents {
  Cents.from(v)
}

func plus(a: in Cents, b: in Cents): Cents {
  a + b
}

func minus(a: in Cents, b: in Cents): Cents {
  a - b
}

func topUp(w: in Wallet, amount: in Cents): Cents {
  w.balance += amount
  w.balance
}

func lvl(v: in Byte): Level {
  Level.from(v)
}

func higher(a: in Level, b: in Level): Bool {
  a < b
}

func sum(a: in Level, b: in Level): Level {
  a + b
}

func half(): Ratio {
  Ratio.from(0.5)
}

func halves(): Ratio {
  half() + half()
}

func main(): Unit {
  println(toString(plus(c(250), c(750))))
  println(toString(minus(c(900), c(150))))
  val w = Wallet(balance = c(100))
  println(toString(topUp(w, c(50))))
  println(toString(c(10) < c(20)))
  println(toString(higher(lvl(200u8 - 197u8), lvl(5u8))))
  println(toString(sum(lvl(2u8), lvl(3u8))))
  println(toString(halves()))
  println(toString(minus(c(1), c(2))))
}
