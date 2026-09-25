//! Operators on distinct types act on the underlying value (#7361).
//!
//! A distinct type is a wrapper class on dotnet and the JVM.  Before #7361
//! `==` compared references (always false for two constructions of the same
//! value), and derived arithmetic operated on the wrapper objects: memory
//! corruption on dotnet, a VerifyError on the JVM.  Every case here returned
//! a wrong value or crashed on at least one target.  Range re-checks of
//! derived arithmetic are in `range_subtype_arith_self_test.l`, which needs
//! `assertPanics` and so does not run on native.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/distinct_ops_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/distinct_ops_self_test.l
//!   lyric test --target native lyric-compiler/lyric/distinct_ops_self_test.l
@test_module
package Lyric.DistinctOpsSelfTest

import Std.Core
import Std.Collections
import Std.Testing

type UserId = Long

type Cents = Long range 0 ..= 100000 derives Add, Sub, Mul, Div, Mod, Compare

type Score = Int derives Add, Compare

type Ratio = Double derives Add, Mul, Compare

type Tag = Byte

record Account {
  id: UserId
  var balance: Cents
}

func sameUser(a: in UserId, b: in UserId): Bool = a == b

func otherUser(a: in UserId, b: in UserId): Bool = a != b

func total(a: in Cents, b: in Cents): Cents = a + b

func cheaper(a: in Cents, b: in Cents): Cents = if a < b { a } else { b }

func between(x: in Cents, lo: in Cents, hi: in Cents): Bool = lo <= x and x <= hi

func deposit(acct: in Account, amount: in Cents): Cents {
  acct.balance += amount
  acct.balance
}

func sumScores(xs: in List[Score]): Score {
  var acc = Score.from(0)
  for x in xs {
    acc += x
  }
  acc
}

func withdraw(balance: in Cents, amount: in Cents): Cents
  requires: amount <= balance
  ensures: result <= balance
{
  balance - amount
}

test "== and != compare underlying values" {
  assertTrue(sameUser(UserId.from(7i64), UserId.from(7i64)), "equal ids")
  assertTrue(not sameUser(UserId.from(7i64), UserId.from(8i64)), "different ids")
  assertTrue(otherUser(UserId.from(1i64), UserId.from(2i64)), "!=")
  assertTrue(not otherUser(UserId.from(3i64), UserId.from(3i64)), "!= on equal ids")
  assertTrue(Tag.from(200u8) == Tag.from(200u8), "Byte-backed ==")
}

test "derived arithmetic produces the underlying result" {
  assertEqual(toString(total(Cents.from(250i64), Cents.from(750i64))), "1000", "Long +")
  assertEqual(toString(Cents.from(900i64) - Cents.from(150i64)), "750", "Long -")
  assertEqual(toString(Cents.from(12i64) * Cents.from(11i64)), "132", "Long *")
  assertEqual(toString(Cents.from(100i64) / Cents.from(7i64)), "14", "Long /")
  assertEqual(toString(Cents.from(100i64) % Cents.from(7i64)), "2", "Long %")
  assertEqual(toString(Score.from(40) + Score.from(2)), "42", "Int +")
  assertTrue(Ratio.from(1.5) + Ratio.from(2.25) == Ratio.from(3.75), "Double + and ==")
  assertEqual(toString(Cents.from(1i64) + Cents.from(2i64) + Cents.from(3i64)), "6", "chained")
}

test "derived comparisons order by the underlying value" {
  assertEqual(toString(cheaper(Cents.from(30i64), Cents.from(20i64))), "20", "<")
  assertTrue(between(Cents.from(5i64), Cents.from(1i64), Cents.from(9i64)), "<= both ways")
  assertTrue(not between(Cents.from(10i64), Cents.from(1i64), Cents.from(9i64)), "above hi")
  assertTrue(Score.from(3) > Score.from(2), ">")
  assertTrue(Ratio.from(0.5) >= Ratio.from(0.5), ">= on Double")
}

test "compound assignment on a variable and a field" {
  val acct = Account(id = UserId.from(1i64), balance = Cents.from(100i64))
  assertEqual(toString(deposit(acct, Cents.from(25i64))), "125", "field +=")
  val xs: List[Score] = newList()
  xs.add(Score.from(1))
  xs.add(Score.from(2))
  xs.add(Score.from(3))
  assertEqual(toString(sumScores(xs)), "6", "variable += in a loop")
}

test "contract clauses compare distinct values" {
  assertEqual(toString(withdraw(Cents.from(50i64), Cents.from(20i64))), "30", "requires and ensures hold")
}

test "tryFrom is Ok in range and Err with the range message outside" {
  match Cents.tryFrom(5i64) {
    case Ok(c) -> assertEqual(toString(c), "5", "in range")
    case Err(_) -> assertTrue(false, "5 is in range")
  }
  match Cents.tryFrom(-1i64) {
    case Ok(_) -> assertTrue(false, "-1 is below the range")
    case Err(msg) -> assertEqual(msg, "Cents.tryFrom: value out of range [0, 100000]", "error text")
  }
  match UserId.tryFrom(9i64) {
    case Ok(u) -> assertTrue(u == UserId.from(9i64), "no range: always Ok")
    case Err(_) -> assertTrue(false, "UserId has no range")
  }
}
