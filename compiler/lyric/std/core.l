// std/core.l — first slice of a Lyric-side standard library.
//
// What's in this file is deliberately conservative: the M1.4 emitter
// erases generic type parameters to `obj`, so `Option[T]` and
// `Result[T, E]` work cleanly with reference-typed payloads but
// require boxing/unboxing at the boundary for value-typed payloads.
// The combinators here are first-order — no `(T) -> U` parameters —
// because the M1.4 emitter doesn't yet lower function-typed
// parameters to delegate types. Higher-order map/filter/fold land
// alongside reified generics in Phase 2.
//
// Multi-package compilation is also M2 work. Until then the test
// harness inlines this file into the user's package: the
// `package Std.Core` declaration is stripped at load time, and
// the surrounding source provides its own `package` line.
//
// Tracked into Phase 2:
//   * Promote to a real multi-package import via `import Std.Core`.
//   * Reified generics so `Option[T]` / `Result[T, E]` work for
//     value types without boundary boxing.
//   * Higher-order combinators (`mapOption`, `mapResult`, `filter`,
//     `fold`).
//   * `Map[K, V]` and `Set[T]` once collections have a real CLR
//     shape.

package Std.Core

// ---------------------------------------------------------------------------
// Option — the absence-or-presence container.
// ---------------------------------------------------------------------------

union Option {
  case Some(value: Int)
  case None
}

// Return the value inside `Some`, or `default` if `None`.
func unwrapOr(o: in Option, default: in Int): Int {
  match o {
    case Some(v) -> v
    case None    -> default
  }
}

// `true` iff the option is a Some.
func isSome(o: in Option): Bool {
  match o {
    case Some(v) -> true
    case None    -> false
  }
}

// `true` iff the option is None.
func isNone(o: in Option): Bool {
  match o {
    case Some(v) -> false
    case None    -> true
  }
}

// ---------------------------------------------------------------------------
// Result — the success-or-error container.
// ---------------------------------------------------------------------------

union Result {
  case Ok(value: Int)
  case Err(code: Int)
}

// `true` iff the result is Ok.
func isOk(r: in Result): Bool {
  match r {
    case Ok(v)  -> true
    case Err(c) -> false
  }
}

// Return the success value, or `default` on error.
func unwrapResultOr(r: in Result, default: in Int): Int {
  match r {
    case Ok(v)  -> v
    case Err(c) -> default
  }
}

// Get the error code (if any), or 0 on success.
func errCode(r: in Result): Int {
  match r {
    case Ok(v)  -> 0
    case Err(c) -> c
  }
}

// ---------------------------------------------------------------------------
// Slice helpers — work directly on the CLR T[] backing of a Lyric
// `slice[T]`. Non-generic for now because erasing the element type
// would force boxing on every read; once reified generics land in
// Phase 2 these become `generic[T]` properly.
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
