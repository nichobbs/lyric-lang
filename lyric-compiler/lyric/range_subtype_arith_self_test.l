//! Derived arithmetic on a named range subtype is re-checked (#7226).
//!
//! `Cents` erases to `Long`, and only `Cents.from`/`tryFrom` checked its
//! range, so `a - b` could produce a negative `Cents`.  Every derived
//! operation and compound assignment now goes through `Cents.from`.  Runs on
//! dotnet and JVM (native has no `assertPanics`).
@test_module
package RangeSubtypeArithSelfTest

import Std.Core
import Std.Testing

type Cents = Long range 0 ..= 1000 derives Add, Sub, Mul, Compare

record Wallet {
  var balance: Cents
}

func c(v: in Long): Cents = Cents.from(v)

func str(x: in Cents): String = toString(x)

func minus(a: in Cents, b: in Cents): Cents = a - b

func plus(a: in Cents, b: in Cents): Cents = a + b

func topUp(start: in Long, add: in Long): Cents {
  var total = c(start)
  total += c(add)
  total
}

func spend(start: in Long, amount: in Long): Cents {
  val w = Wallet(balance = c(start))
  w.balance -= c(amount)
  w.balance
}

test "in-range derived arithmetic is unchanged" {
  assertEqual(str(minus(c(10), c(4))), "6", "10 - 4")
  assertEqual(str(plus(c(400), c(600))), "1000", "400 + 600 is exactly the upper bound")
  assertEqual(str(c(20) * c(50)), "1000", "20 * 50")
}

test "a derived result outside the range fails like Cents.from" {
  assertPanics("5 - 10 is negative", { -> val _ = minus(c(5), c(10)) })
  assertPanics("600 + 600 exceeds 1000", { -> val _ = plus(c(600), c(600)) })
  assertPanics("100 * 20 exceeds 1000", { -> val _ = c(100) * c(20) })
}

test "compound assignment on a variable or field is re-checked" {
  assertEqual(str(topUp(100, 200)), "300", "100 += 200")
  assertPanics("900 += 200 exceeds 1000", { -> val _ = topUp(900, 200) })
  assertEqual(str(spend(50, 20)), "30", "field -= in range")
  assertPanics("field -= below zero", { -> val _ = spend(10, 20) })
}
