//! propagate_never_value_self_test.l — runtime regression test for a `?` that
//! can never produce a value (#8257), on every target.
//!
//! A `?` whose operand can only be `Err(..)` or `None` (or an `if`/`match`
//! whose branches all are) always returns early.  When nothing fixes its
//! success type and the result is still read (`val s = None?; s.length`),
//! the lowered `match` gave `s` a type no path could fill: dotnet ran, but
//! the verifier rejected the never-taken member read on an `int` slot, and
//! native reported N0007.  `Lyric.Propagate` now lowers such a statement to
//! the return itself and drops the statements after it in the block.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/propagate_never_value_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/propagate_never_value_self_test.l
//!   lyric test --target native lyric-compiler/lyric/propagate_never_value_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.PropagateNeverValueSelfTest

import Std.Core
import Std.Collections
import Std.Testing

func noneMemberRead(fail: in Bool): Option[Int] {
  if fail {
    val s = None?
    return Some(value = s.length)
  }
  Some(value = 7)
}

func errMemberRead(fail: in Bool): Result[Int, String] {
  if fail {
    val s = Err(error = "stop")?
    return Ok(value = s.length)
  }
  Ok(value = 5)
}

func errTupleMemberRead(fail: in Bool): Result[Int, String] {
  if fail {
    val (s, n) = (Err(error = "t")?, 1)
    return Ok(value = s.length + n)
  }
  Ok(value = 5)
}

func noneMemberOfCall(fail: in Bool): Option[Int] {
  if fail {
    val n = None?.length
    return Some(value = n)
  }
  Some(value = 5)
}

func ifBranchesAllErr(c: in Bool): Result[Int, String] {
  val s = (if c { Err(error = "then") } else { Err(error = "else") })?
  Ok(value = s.length)
}

func matchArmsAllNone(n: in Int): Option[Int] {
  val s = (match n { case 0 -> None; case _ -> None })?
  Some(value = s.length)
}

func blockWithEffectsFirst(log: in List[String]): Result[Int, String] {
  val s = (if log.count == 0 { log.add("before"); Err(error = "block") } else { Err(error = "other") })?
  log.add("after")
  Ok(value = s.length)
}

func widensError(): Result[Int, Long] {
  val s = Err(error = 5)?
  Ok(value = s.length)
}

func tailPosition(): Option[Int] {
  None?
}

func logsBeforeNone(log: in List[String]): Option[Int] {
  log.add("one")
  val s = None?
  log.add("never")
  Some(value = s.length)
}

func resInt(r: in Result[Int, String]): String {
  match r {
    case Ok(v) -> "ok " + toString(v)
    case Err(e) -> "err " + e
  }
}

func resLong(r: in Result[Int, Long]): String {
  match r {
    case Ok(v) -> "ok " + toString(v)
    case Err(e) -> "err " + toString(e + 1i64)
  }
}

func optInt(o: in Option[Int]): String {
  match o {
    case Some(v) -> "some " + toString(v)
    case None -> "none"
  }
}

test "a None operand whose result is read returns None" {
  assertEqual(optInt(noneMemberRead(true)), "none", "a member read of None?")
  assertEqual(optInt(noneMemberRead(false)), "some 7", "not reached")
}

test "an Err operand whose result is read returns the error" {
  assertEqual(resInt(errMemberRead(true)), "err stop", "a member read of Err?")
  assertEqual(resInt(errMemberRead(false)), "ok 5", "not reached")
}

test "a tuple element and a receiver that never produce a value" {
  assertEqual(resInt(errTupleMemberRead(true)), "err t", "a tuple element read")
  assertEqual(resInt(errTupleMemberRead(false)), "ok 5", "tuple, not reached")
  assertEqual(optInt(noneMemberOfCall(true)), "none", "a member of the result")
  assertEqual(optInt(noneMemberOfCall(false)), "some 5", "member, not reached")
}

test "an if or match whose branches all fail" {
  assertEqual(resInt(ifBranchesAllErr(true)), "err then", "the then branch")
  assertEqual(resInt(ifBranchesAllErr(false)), "err else", "the else branch")
  assertEqual(optInt(matchArmsAllNone(0)), "none", "the first arm")
  assertEqual(optInt(matchArmsAllNone(3)), "none", "the other arm")
}

test "statements before the failing operand still run, those after do not" {
  val log: List[String] = newList()
  assertEqual(resInt(blockWithEffectsFirst(log)), "err block", "the block's error")
  assertEqualInt(log.count, 1, "only the statement before ran")
  assertEqual(log[0], "before", "the statement before the error")
  val log2: List[String] = newList()
  assertEqual(optInt(logsBeforeNone(log2)), "none", "None")
  assertEqualInt(log2.count, 1, "the statement after was dropped")
  assertEqual(log2[0], "one", "the statement before ran")
}

test "an error that widens to the function's is converted" {
  assertEqual(resLong(widensError()), "err 6", "Int into Long")
}

test "a failing operand in tail position" {
  assertEqual(optInt(tailPosition()), "none", "None? as the body")
}
