// std/core.l - first slice of a Lyric-side standard library.
//
// This package defines the small algebraic types and helpers that the
// rest of the stdlib builds on. Keep these APIs boring and stable:
// Option and Result appear in almost every safe wrapper.
//
// Tracked for the next stdlib slices:
//   * Higher-order combinators (`mapOption`, `mapResult`, `filter`,
//     `fold`).
//   * `Map[K, V]` and `Set[T]` once collections have a real CLR
//     shape.

package Std.Core

// ---------------------------------------------------------------------------
// Option - the absence-or-presence container.
// ---------------------------------------------------------------------------

generic[T] union Option {
  case Some(value: T)
  case None
}

// Return the value inside `Some`, or `default` if `None`.
generic[T] func unwrapOr(o: in Option[T], default: in T): T {
  match o {
    case Some(v) -> v
    case None    -> default
  }
}

// `true` iff the option is a Some.
generic[T] func isSome(o: in Option[T]): Bool {
  match o {
    case Some(v) -> true
    case None    -> false
  }
}

// `true` iff the option is None.
generic[T] func isNone(o: in Option[T]): Bool {
  match o {
    case Some(v) -> false
    case None    -> true
  }
}

// ---------------------------------------------------------------------------
// Result - the success-or-error container.
// ---------------------------------------------------------------------------

generic[T, E] union Result {
  case Ok(value: T)
  case Err(error: E)
}

// `true` iff the result is Ok.
generic[T, E] func isOk(r: in Result[T, E]): Bool {
  match r {
    case Ok(v)  -> true
    case Err(c) -> false
  }
}

// `true` iff the result is Err.
generic[T, E] func isErr(r: in Result[T, E]): Bool {
  match r {
    case Ok(v)  -> false
    case Err(c) -> true
  }
}

// Return the success value, or `default` on error.
generic[T, E] func unwrapResultOr(r: in Result[T, E], default: in T): T {
  match r {
    case Ok(v)  -> v
    case Err(c) -> default
  }
}

// Return the error payload, or `default` on success.
generic[T, E] func unwrapErrOr(r: in Result[T, E], default: in E): E {
  match r {
    case Ok(v)  -> default
    case Err(c) -> c
  }
}

// ---------------------------------------------------------------------------
// Slice helpers - intentionally small until higher-order functions and
// collection abstractions settle. These give examples and smoke tests a
// concrete place to stand without pretending this is the final slice API.
// ---------------------------------------------------------------------------

// Sum every Int in the slice.
func sumInts(xs: in slice[Int]): Int {
  var total = 0
  for x in xs { total += x }
  return total
}

// Maximum element. Caller is responsible for non-empty input;
// `requires:` enforcement of slice-shape contracts arrives with
// runtime-checked slice predicates.
func maxInt(xs: in slice[Int]): Int {
  var best = xs[0]
  var i = 1
  while i < xs.length {
    if xs[i] > best { best = xs[i] }
    i += 1
  }
  return best
}

// Count elements equal to `target`.
func countEq(xs: in slice[Int], target: in Int): Int {
  var n = 0
  for x in xs { if x == target { n += 1 } }
  return n
}

// ---------------------------------------------------------------------------
// Higher-order Option combinators — now that delegate lowering is in place.
// ---------------------------------------------------------------------------

// Apply `f` to the value inside `Some`, or return `None`.
func mapOption(o: in Option, f: in (Int) -> Int): Option {
  match o {
    case Some(v) -> Some(value = f(v))
    case None    -> None
  }
}

// Apply `f` to the Ok value, or propagate Err.
func mapResult(r: in Result, f: in (Int) -> Int): Result {
  match r {
    case Ok(v)  -> Ok(value = f(v))
    case Err(c) -> Err(code = c)
  }
}

// Return `Some(value = x)` when `pred(x)` is true, else `None`.
func filterOption(o: in Option, pred: in (Int) -> Bool): Option {
  match o {
    case Some(v) -> if pred(v) { Some(value = v) } else { None }
    case None    -> None
  }
}

// Count elements satisfying `pred`.
func countWhere(xs: in slice[Int], pred: in (Int) -> Bool): Int {
  var n = 0
  for x in xs { if pred(x) { n += 1 } }
  return n
}
