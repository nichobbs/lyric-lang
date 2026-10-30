//! for_loop_dispose_enumerable_self_test.l - dual-target runtime regression
//! test for a `for` loop over a `Set[T]` or a map's key/value view leaving the
//! loop by any route (#7770, D143).
//!
//! D143 gave every `for` loop one disposal region: the non-generic
//! `IEnumerable` protocol that `Set[T]` and the key/value views use on
//! `--target dotnet` takes part in it (`beginForDisposeRegionMsil` /
//! `endForDisposeRegionMsil`), and `--target jvm` closes an `AutoCloseable`
//! iterator through `DeferCloseIterJvm`. `generator_dispose_self_test.l`
//! covers the generator path, whose disposal is observable through the
//! generator's `finally`. These enumerators have nothing to observe (a
//! `HashSet<T>` enumerator's `Dispose` does nothing), so each case shows what
//! is observable: the loop still produces the right result and runs the
//! consumer's own `defer` blocks in order whichever way it is left, the same
//! collection can be iterated again afterwards, and a disposal region that
//! was left or re-entered wrongly would surface as an invalid program or an
//! `InvalidCastException`. `scripts/ilverify-selfhosted.sh` verifies the IL
//! these loops compile to on dotnet.
//!
//! The cases cover `return`, `?` propagation, `break` and `continue` to an
//! enclosing loop, a caught panic, a loop nested in a loop over the same set,
//! and `await` in the loop body of an `async func`.
//!
//! Disposal of a user-visible enumerator (an extern `IEnumerable<T>` whose
//! enumerator counts `Dispose`, a JDK `AutoCloseable` iterator) is not covered
//! here: a `for` over an extern collection type does not reach the
//! non-generic protocol today, so there is no enumerator whose disposal a test
//! could count. The follow-up is tracked in the pull request that added this
//! file.
//!
//! Run via `lyric test`, compiled in-process on both targets:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/for_loop_dispose_enumerable_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/for_loop_dispose_enumerable_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.ForLoopDisposeEnumerableSelfTest

import Std.Core
import Std.Collections
import Std.Testing

func joinStrings(xs: in List[String]): String {
  var s = ""
  var i = 0
  while i < xs.count {
    if i > 0 {
      s = s + ","
    }
    s = s + xs[i]
    i = i + 1
  }
  s
}

func oneElement(x: in Int): Set[Int] {
  val s: Set[Int] = newSet()
  s.add(x)
  s
}

func threeInts(): Set[Int] {
  val s: Set[Int] = newSet()
  s.add(1)
  s.add(2)
  s.add(3)
  s
}

func sumSet(s: in Set[Int]): Int {
  var total = 0
  for x in s {
    total = total + x
  }
  total
}

func firstOf(s: in Set[Int], log: in List[String]): Int {
  defer {
    log.add("consumer defer")
  }
  for x in s {
    log.add("consumer ${x}")
    return x
  }
  -1
}

func rejectSeven(x: in Int): Result[Int, String] {
  if x == 7 {
    Err("seven")
  } else {
    Ok(x)
  }
}

func sumUntilRejected(s: in Set[Int], log: in List[String]): Result[Int, String] {
  var total = 0
  for x in s {
    val v = rejectSeven(x)?
    log.add("consumer ${v}")
    total = total + v
  }
  Ok(total)
}

func panicsInBody(s: in Set[Int], log: in List[String]): Int {
  var total = 0
  for x in s {
    log.add("consumer ${x}")
    panic("consumer failed")
  }
  total
}

func breakOuter(s: in Set[Int], log: in List[String]): Int {
  var rounds = 0
  outer: for round in [1, 2, 3] {
    rounds = rounds + 1
    for x in s {
      log.add("round ${round} got ${x}")
      break outer
    }
    log.add("round ${round} unreachable")
  }
  log.add("after outer")
  rounds
}

func continueOuter(s: in Set[Int], log: in List[String]): Int {
  var rounds = 0
  outer: for round in [1, 2] {
    rounds = rounds + 1
    for x in s {
      log.add("round ${round} got ${x}")
      continue outer
    }
    log.add("round ${round} unreachable")
  }
  rounds
}

func nestedSameSet(s: in Set[Int]): Int {
  var pairs = 0
  for a in s {
    for b in s {
      pairs = pairs + 1
    }
  }
  pairs
}

async func plusOne(x: in Int): Int {
  x + 1
}

async func firstAfterAwait(s: in Set[Int], log: in List[String]): Int {
  for x in s {
    val y = await plusOne(x)
    log.add("consumer ${y}")
    return y
  }
  -1
}

func keySum(m: in Map[Int, String]): Int {
  var total = 0
  for k in mapKeys(m) {
    total = total + k
  }
  total
}

func firstValueLength(m: in Map[Int, String], log: in List[String]): Int {
  defer {
    log.add("consumer defer")
  }
  for v in mapValues(m) {
    log.add("consumer ${v}")
    return v.length
  }
  -1
}

func breakOuterKeys(m: in Map[Int, String], log: in List[String]): Int {
  var rounds = 0
  outer: for round in [1, 2, 3] {
    rounds = rounds + 1
    for k in mapKeys(m) {
      log.add("round ${round} got ${k}")
      break outer
    }
  }
  rounds
}

test "for over a Set: running to the end visits every element" {
  assertEqualInt(sumSet(threeInts()), 6, "1 + 2 + 3")
}

test "for over a Set: return runs the consumer's defer after the loop and leaves the set usable" {
  val s = oneElement(7)
  val log: List[String] = newList()
  assertEqualInt(firstOf(s, log), 7, "returned the element")
  assertEqual(joinStrings(log), "consumer 7,consumer defer", "event order")
  assertEqualInt(sumSet(s), 7, "the set iterates again after the early return")
}

test "for over a Set: ? propagation leaves the loop and the set usable" {
  val s = oneElement(7)
  val log: List[String] = newList()
  match sumUntilRejected(s, log) {
    case Ok(v) -> assertTrue(false, "expected Err, got Ok(${v})")
    case Err(e) -> assertEqual(e, "seven", "the propagated error")
  }
  assertEqual(joinStrings(log), "", "the body never got past the rejected element")
  assertEqualInt(sumSet(s), 7, "the set iterates again after the propagation")
}

test "for over a Set: ? is not taken when no element is rejected" {
  val log: List[String] = newList()
  match sumUntilRejected(threeInts(), log) {
    case Ok(v) -> assertEqualInt(v, 6, "every element passed")
    case Err(e) -> assertTrue(false, "expected Ok, got Err(${e})")
  }
}

test "for over a Set: break to an outer loop stops both loops" {
  val log: List[String] = newList()
  assertEqualInt(breakOuter(oneElement(5), log), 1, "one round ran")
  assertEqual(joinStrings(log), "round 1 got 5,after outer", "event order")
}

test "for over a Set: continue to an outer loop starts a fresh iteration each round" {
  val log: List[String] = newList()
  assertEqualInt(continueOuter(oneElement(5), log), 2, "both rounds ran")
  assertEqual(joinStrings(log), "round 1 got 5,round 2 got 5", "event order")
}

test "for over a Set: a caught panic leaves the loop and the set usable" {
  val s = oneElement(9)
  val log: List[String] = newList()
  var caught = ""
  try {
    panicsInBody(s, log)
  } catch Bug as e {
    caught = e.message
    log.add("caller caught")
  }
  assertTrue(caught.contains("consumer failed"), "the body's panic reached the caller: '" + caught + "'")
  assertEqual(joinStrings(log), "consumer 9,caller caught", "event order")
  assertEqualInt(sumSet(s), 9, "the set iterates again after the panic")
}

test "for over a Set: a loop nested over the same set visits every pair" {
  assertEqualInt(nestedSameSet(threeInts()), 9, "3 x 3 pairs")
}

test "for over a Set: return after an await in an async func" {
  val log: List[String] = newList()
  val r = await firstAfterAwait(oneElement(4), log)
  assertEqualInt(r, 5, "returned the awaited value")
  assertEqual(joinStrings(log), "consumer 5", "event order")
}

test "for over a map's key view: running to the end and a labelled break" {
  val m: Map[Int, String] = newMap()
  m.add(10, "a")
  m.add(20, "bb")
  assertEqualInt(keySum(m), 30, "10 + 20")
  val log: List[String] = newList()
  m.remove(20)
  assertEqualInt(breakOuterKeys(m, log), 1, "one round ran")
  assertEqual(joinStrings(log), "round 1 got 10", "event order")
  assertEqualInt(keySum(m), 10, "the map iterates again after the break")
}

test "for over a map's value view: return runs the consumer's defer" {
  val m: Map[Int, String] = newMap()
  m.add(1, "xyz")
  val log: List[String] = newList()
  assertEqualInt(firstValueLength(m, log), 3, "length of the returned value")
  assertEqual(joinStrings(log), "consumer xyz,consumer defer", "event order")
}
