//! contract_generic_call_self_test.l — contracts that call a generic function
//! on `result`, a parameter, an `old(...)` snapshot, a loop local or a
//! protected field compile without explicit type arguments and are enforced
//! at runtime (#7466).
//!
//! The contract elaborator binds `result` to a synthetic `__lyric_result_<n>`
//! local.  It used to leave that binding unannotated, so `Lyric.Mono` could
//! only type it from the returned expression, which for an `if` over
//! `Some(...)`/`None` it cannot; `ensures: isNone(result)` then failed with
//! M0004 and had to be written `isNone[Char](result)`.  The binding is now
//! annotated with the declared return type.
//!
//! Each contract is checked both ways: a call that satisfies it returns
//! normally, and a call that violates it panics.
//!
//! Run in CI via native `lyric test` on `--target dotnet`
//! (`compiler-self-tests-batch.sh`) and `--target jvm`
//! (`jvm-generics-self-tests-batch.sh`).  Imports only `Std.*`.
@test_module
package Lyric.ContractGenericCallSelfTest

import Std.Core
import Std.Testing

// `ensures:` on `result`, trailing `if` body.
func first(s: in String): Option[Char]
  ensures: (s.length > 0 and isSome(result)) or (s.length == 0 and isNone(result))
{
  if s.length > 0 {
    Some(value = s[0])
  } else {
    None
  }
}

// The same postcondition over a body that breaks it for a non-empty string.
func brokenFirst(s: in String): Option[Char]
  ensures: s.length == 0 or isSome(result)
{
  None
}

// `ensures:` on `result` bound by an early `return`, with a two-argument
// generic whose type argument also comes only from `result`.
func positive(n: in Int): Option[Int]
  ensures: isNone(result) or unwrapOr(result, 0) > 0
{
  if n <= 0 {
    return None
  }
  Some(value = n)
}

func brokenPositive(n: in Int): Option[Int]
  ensures: isNone(result) or unwrapOr(result, 0) > 0
{
  Some(value = n)
}

// `requires:` on a parameter and `old(...)` in an `ensures:`.
func bump(o: in Option[Long]): Long
  requires: isSome(o)
  ensures: isSome(old(o)) and result > unwrapOr(o, 0i64)
{
  unwrapOr(o, 0i64) + 1i64
}

// A loop invariant over a typed local.
func firstNegative(xs: in slice[Int]): Option[Int]
  ensures: isNone(result) or unwrapOr(result, 0) < 0
{
  var found: Option[Int] = None
  var i = 0
  while i < xs.length
    invariant: isNone(found) or unwrapOr(found, 0) < 0
  {
    if isNone(found) and xs[i] < 0 {
      found = Some(value = xs[i])
    }
    i = i + 1
  }
  found
}

// A protected entry's `ensures:` over `result` and a protected field.
protected type Slot {
  var held: Option[Int] = None
  entry put(v: in Int): Option[Int]
    ensures: isNone(result) or isSome(held)
  {
    val previous = held
    held = Some(value = v)
    previous
  }
}

func firstOfEmpty(): Unit {
  val _ = first("")
}

func brokenFirstOfText(): Unit {
  val _ = brokenFirst("abc")
}

func brokenPositiveOfNegative(): Unit {
  val _ = brokenPositive(0 - 3)
}

func bumpNone(): Unit {
  val none: Option[Long] = None
  val _ = bump(none)
}

test "ensures: isSome(result) / isNone(result) holds on both branches" {
  match first("hi") {
    case Some(c) -> assertTrue(c == 'h', "first(\"hi\") is Some('h')")
    case None -> assertTrue(false, "first(\"hi\") is Some")
  }
  assertTrue(isNone(first("")), "first(\"\") is None")
}

test "a violated ensures: on result panics" {
  assertPanics("brokenFirst(\"abc\") breaks its postcondition", brokenFirstOfText)
}

test "ensures: on an early-returned result holds" {
  assertTrue(isNone(positive(0)), "positive(0) is None")
  assertEqualInt(unwrapOr(positive(4), 0), 4, "positive(4) is Some(4)")
}

test "a violated ensures: on a two-argument generic call panics" {
  assertPanics("brokenPositive(-3) breaks its postcondition", brokenPositiveOfNegative)
}

test "requires: and old(...) over a generic call" {
  assertTrue(bump(Some(value = 41i64)) == 42i64, "bump(Some(41)) is 42")
  assertPanics("bump(None) breaks its precondition", bumpNone)
}

test "a loop invariant over a generic call" {
  val xs: slice[Int] = [3, 0 - 2, 5, 0 - 7]
  assertEqualInt(unwrapOr(firstNegative(xs), 0), 0 - 2, "firstNegative finds -2")
  val ys: slice[Int] = [1, 2]
  assertTrue(isNone(firstNegative(ys)), "no negative in [1, 2]")
}

test "a protected entry's ensures: over result and a field" {
  val s = Slot()
  val firstPut: Option[Int] = s.put(1)
  assertTrue(isNone(firstPut), "first put returns None")
  val secondPut: Option[Int] = s.put(2)
  assertEqualInt(unwrapOr(secondPut, 0), 1, "second put returns the previous value")
}

test "a satisfied postcondition does not panic" {
  firstOfEmpty()
  assertTrue(true, "first(\"\") returned normally")
}
