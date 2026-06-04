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

@stable(since="1.0")
pub generic[T] union Option {
  case Some(value: T)
  case None
}

/// Return the value inside `Some`, or `default` if `None`.
@stable(since="1.0")
pub generic[T] func unwrapOr(o: in Option[T], default: in T): T {
  match o {
    case Some(v) -> v
    case None    -> default
  }
}

/// `true` iff the option is a Some.
@stable(since="1.0")
pub generic[T] func isSome(o: in Option[T]): Bool {
  match o {
    case Some(v) -> true
    case None    -> false
  }
}

/// `true` iff the option is None.
@stable(since="1.0")
pub generic[T] func isNone(o: in Option[T]): Bool {
  match o {
    case Some(v) -> false
    case None    -> true
  }
}

// ---------------------------------------------------------------------------
// Result - the success-or-error container.
// ---------------------------------------------------------------------------

@stable(since="1.0")
pub generic[T, E] union Result {
  case Ok(value: T)
  case Err(error: E)
}

/// `true` iff the result is Ok.
@stable(since="1.0")
pub generic[T, E] func isOk(r: in Result[T, E]): Bool {
  match r {
    case Ok(v)  -> true
    case Err(c) -> false
  }
}

/// `true` iff the result is Err.
@stable(since="1.0")
pub generic[T, E] func isErr(r: in Result[T, E]): Bool {
  match r {
    case Ok(v)  -> false
    case Err(c) -> true
  }
}

/// Return the success value, or `default` on error.
@stable(since="1.0")
pub generic[T, E] func unwrapResultOr(r: in Result[T, E], default: in T): T {
  match r {
    case Ok(v)  -> v
    case Err(c) -> default
  }
}

/// Return the error payload, or `default` on success.
@stable(since="1.0")
pub generic[T, E] func unwrapErrOr(r: in Result[T, E], default: in E): E {
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

/// Sum every Int in the slice.
@stable(since="1.0")
pub func sumInts(xs: in slice[Int]): Int {
  var total = 0
  for x in xs { total += x }
  return total
}

/// Maximum element. Caller is responsible for non-empty input.
@stable(since="1.0")
pub func maxInt(xs: in slice[Int]): Int {
  var best = xs[0]
  var i = 1
  while i < xs.length {
    if xs[i] > best { best = xs[i] }
    i += 1
  }
  return best
}

/// Count elements equal to `target`.
@stable(since="1.0")
pub func countEq(xs: in slice[Int], target: in Int): Int {
  var n = 0
  for x in xs { if x == target { n += 1 } }
  return n
}

// ---------------------------------------------------------------------------
// Higher-order Option / Result combinators.
// ---------------------------------------------------------------------------

/// Apply `f` to the value inside `Some`, or propagate `None`.
@stable(since="1.0")
pub generic[T, U] func mapOption(o: in Option[T], f: in (T) -> U): Option[U] {
  match o {
    case Some(v) -> Some(value = f(v))
    case None    -> None
  }
}

/// Apply `f` to the Ok value; pass an Err through unchanged.
@stable(since="1.0")
pub generic[T, U, E] func mapResult(r: in Result[T, E], f: in (T) -> U): Result[U, E] {
  match r {
    case Ok(v)  -> Ok(value = f(v))
    case Err(e) -> Err(error = e)
  }
}

/// Return `Some(value = x)` when `pred(x)` is true, else `None`.
@stable(since="1.0")
pub generic[T] func filterOption(o: in Option[T], pred: in (T) -> Bool): Option[T] {
  match o {
    case Some(v) -> if pred(v) { Some(value = v) } else { None }
    case None    -> None
  }
}

/// Count elements satisfying `pred`.
@stable(since="1.0")
pub func countWhere(xs: in slice[Int], pred: in (Int) -> Bool): Int {
  var n = 0
  for x in xs { if pred(x) { n += 1 } }
  return n
}

// ---------------------------------------------------------------------------
// Flatmap / chaining combinators.
// ---------------------------------------------------------------------------

/// Apply `f` to the value inside `Some`; return its result.  Propagate `None`.
@stable(since="1.0")
pub generic[T, U] func andThen(o: in Option[T], f: in (T) -> Option[U]): Option[U] {
  match o {
    case Some(v) -> f(v)
    case None    -> None
  }
}

/// Return `o` when it is `Some`; otherwise evaluate and return `other()`.
/// Useful for cascaded fallbacks: `findInCache(k) |> orElse { fetchFromDb(k) }`.
@stable(since="1.0")
pub generic[T] func orElse(o: in Option[T], other: in () -> Option[T]): Option[T] {
  match o {
    case Some(v) -> o
    case None    -> other()
  }
}

/// Apply `f` to the `Ok` value and return its result.  Propagate `Err` unchanged.
@stable(since="1.0")
pub generic[T, U, E] func andThenResult(r: in Result[T, E], f: in (T) -> Result[U, E]): Result[U, E] {
  match r {
    case Ok(v)  -> f(v)
    case Err(e) -> Err(error = e)
  }
}

/// Map the `Err` value of a Result, leaving `Ok` unchanged.
/// Use at package boundaries to convert an upstream error type to a local one.
@stable(since="1.0")
pub generic[T, E, F] func mapResultErr(r: in Result[T, E], f: in (E) -> F): Result[T, F] {
  match r {
    case Ok(v)  -> Ok(value = v)
    case Err(e) -> Err(error = f(e))
  }
}

/// Unwrap the `Ok` value of a Result, raising a `Bug` if the result is `Err`.
/// Only appropriate when the `Err` case is impossible by construction (e.g.
/// parsing a compile-time constant string). For user input, use match or `?`.
@stable(since="1.0")
pub generic[T, E] func unwrapResult(r: in Result[T, E]): T {
  match r {
    case Ok(v)  -> v
    case Err(_) -> panic("unwrapResult called on Err")
  }
}

/// Unwrap the `Some` value of an Option, raising a `Bug` if the option is `None`.
/// Only appropriate when `None` is impossible by construction.
@stable(since="1.0")
pub generic[T] func unwrapOption(o: in Option[T]): T {
  match o {
    case Some(v) -> v
    case None    -> panic("unwrapOption called on None")
  }
}
