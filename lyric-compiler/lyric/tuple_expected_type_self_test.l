//! tuple_expected_type_self_test.l — cross-target runtime regression test for
//! a tuple literal whose components take their types from an expected tuple
//! type (#7824).
//!
//! `(None, 1)` fixes nothing about its first component on its own: `None`
//! needs the `Option[T]` it is built at from the context.  The native backend
//! lowered a tuple literal's components bare even when the tuple had an
//! expected type, so `[(None, 1), (Some(2), 3)]` failed with N0007 even when
//! the binding was annotated `slice[(Option[Int], Int)]`.  It now passes each
//! component its expected component type, in every expected-type position: a
//! list element, an annotated binding, a return value, an argument, a nested
//! tuple, a record field, a union payload and an assignment.  Every case runs
//! on all three targets.
//!
//! Run via `lyric test`:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/tuple_expected_type_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/tuple_expected_type_self_test.l
//!   lyric test --target native lyric-compiler/lyric/tuple_expected_type_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.TupleExpectedTypeSelfTest

import Std.Core
import Std.Collections
import Std.Testing

record PairBox {
  pair: (Option[Int], Int)
  label: String
}

union Wrapped {
  case Held(p: (Option[Int], Int))
  case Empty
}

func optOr(o: in Option[Int], d: in Int): Int {
  match o {
    case Some(v) -> v
    case None -> d
  }
}

func pairSum(p: in (Option[Int], Int)): Int {
  match p {
    case (Some(v), w) -> v + w
    case (None, w) -> w
  }
}

func sumPairs(xs: in slice[(Option[Int], Int)]): Int {
  var t = 0
  for p in xs {
    t = t + pairSum(p)
  }
  t
}

func noneFirst(w: in Int): (Option[Int], Int) {
  (None, w)
}

func pickPair(useSome: in Bool): (Option[Int], Int) {
  if useSome {
    return (Some(10), 1)
  };
  (None, 2)
}

func matchedPair(k: in Int): (Option[Int], Int) {
  match k {
    case 0 -> (None, 5)
    case _ -> (Some(k), 5)
  }
}

func resultPair(ok: in Bool): (Result[Int, String], Int) {
  if ok {
    (Ok(4), 1)
  } else {
    (Err("bad"), 2)
  }
}

test "a list literal of tuples holding None" {
  var t = 0
  for p in [(None, 1), (Some(2), 3)] {
    t = t + pairSum(p)
  }
  assertEqualInt(t, 6, "unannotated literal")
  assertEqualInt(sumPairs([(None, 1), (Some(2), 3), (None, 4)]), 10, "literal argument")
}

test "an annotated slice of tuples holding None" {
  val xs: slice[(Option[Int], Int)] = [(None, 1), (Some(2), 3)]
  assertEqualInt(sumPairs(xs), 6, "annotated slice")
  assertEqualInt(xs.length, 2, "annotated slice length")
  assertEqualInt(pairSum(xs[0]) + pairSum(xs[1]), 6, "indexed reads")
}

test "a tuple return value holding None" {
  assertEqualInt(pairSum(noneFirst(8)), 8, "expression body")
  assertEqualInt(pairSum(pickPair(true)), 11, "return statement")
  assertEqualInt(pairSum(pickPair(false)), 2, "trailing value")
  assertEqualInt(pairSum(matchedPair(0)), 5, "match arm None")
  assertEqualInt(pairSum(matchedPair(3)), 8, "match arm Some")
  var r = 0
  match resultPair(false) {
    case (Ok(v), w) -> {
      r = v + w
    }
    case (Err(e), w) -> {
      r = e.length + w
    }
  }
  assertEqualInt(r, 5, "Result component")
}

test "an annotated binding, an argument and an assignment" {
  val p: (Option[Int], String) = (None, "abc")
  val (o, s) = p
  assertEqualInt(optOr(o, 1) + s.length, 4, "annotated val")
  assertEqualInt(pairSum((None, 6)), 6, "tuple argument")
  var q: (Option[Int], Int) = (Some(1), 1)
  q = (None, 9)
  assertEqualInt(pairSum(q), 9, "assignment")
  val e: (List[Int], Int) = ([], 3)
  val (l, n) = e
  assertEqualInt(l.count + n, 3, "empty list component")
}

test "nested tuples holding None" {
  val n: ((Option[Int], Int), Option[String]) = ((None, 1), None)
  val (inner, label) = n
  var t = pairSum(inner)
  match label {
    case Some(s) -> {
      t = t + s.length
    }
    case None -> {
      t = t + 100
    }
  }
  assertEqualInt(t, 101, "nested tuple")
  val m: slice[((Option[Int], Int), Int)] = [((None, 1), 2), ((Some(3), 4), 5)]
  var u = 0
  for x in m {
    val (a, b) = x
    u = u + pairSum(a) + b
  }
  assertEqualInt(u, 15, "nested tuples in a list")
}

test "tuples holding None in a record field and a union payload" {
  val b = PairBox(pair = (None, 4), label = "x")
  assertEqualInt(pairSum(b.pair) + b.label.length, 5, "record field")
  val w = Held((None, 6))
  var t = 0
  match w {
    case Held(p) -> {
      t = pairSum(p)
    }
    case Empty -> ()
  }
  assertEqualInt(t, 6, "union payload")
}
