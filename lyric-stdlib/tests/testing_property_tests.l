//! Tests for Std.Testing.Property shrinking (#7284). Uses the
//! `func main(): Unit` + `println "ok"` shape run via `lyric run` in the
//! "Stdlib runtime suites on dotnet" CI step (.github/workflows/ci.yml).
package Std.Testing.Property.Tests

import Std.Core
import Std.Collections
import Std.Random
import Std.Testing
import Std.Testing.Property

// Steps down by one, so reaching the minimal counterexample from 1000000 takes
// about a million shrink rounds, which overflowed the stack when each round
// recursed.
func stepDown(n: in Int): List[Int] {
  val xs: List[Int] = newList()
  if n > 0 {
    xs.add(n - 1)
  }
  xs
}

func panicMessage(run: in () -> Unit): String {
  var msg = ""
  try {
    run()
  } catch Bug as b {
    msg = b.message
  }
  msg
}

func testForAllShrinksIteratively(): Unit {
  val msg = panicMessage(
    { ->
      forAll(makeRandom(1), 1, { r: Random -> 1000000 }, stepDown, { n: Int -> toString(n) }, { n: Int -> n < 10 })
    }
  )
  assertTrue(msg == "property failed: 10", "forAll shrinks 1000000 down to 10, got: " + msg)
}

func testForAllIntShrinksToBoundary(): Unit {
  val msg = panicMessage({ -> forAllInt(makeRandom(7), 1000, 100000, 1, { n: Int -> n < 1000 }) })
  assertTrue(msg.length > 0, "forAllInt reports a counterexample")
}

func testForAllIntPairShrinks(): Unit {
  val msg = panicMessage({ -> forAllIntPair(makeRandom(3), 0, 100000, 5, { x: Int, y: Int -> false }) })
  assertTrue(msg == "property failed for pair: (0, 0)", "pair shrinks to (0, 0), got: " + msg)
}

func main(): Unit {
  testForAllShrinksIteratively()
  testForAllIntShrinksToBoundary()
  testForAllIntPairShrinks()
  println("ok")
}
