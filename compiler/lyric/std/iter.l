// std/iter.l - Iterator helpers over `slice[T]`.
//
// Bootstrap-grade scope: helpers that don't require allocating a new
// slice (`forEach`, `fold`, `any`, `all`, `count`, `find`, `sum`,
// `min`, `max`, `contains`).  Allocating helpers (`map`, `filter`,
// `take`, `drop`, `concat`) need either a host `Array.zeroCreate`
// shim plus indexed assignment, or stable behaviour for `List[T]`
// inside generic Lyric functions — both tracked as follow-ups.
package Std.Iter

import Std.Core

// =====================================================================
// Side-effecting iteration.
// =====================================================================

/// Run `f` on each element of `xs` in order.
pub func forEach[T](xs: in slice[T], f: in (T) -> Unit): Unit {
  for x in xs {
    f(x)
  }
}

// =====================================================================
// Folds.
// =====================================================================

/// Left-fold: `step(... step(step(init, xs[0]), xs[1]) ..., xs[n-1])`.
pub func fold[T, U](xs: in slice[T], init: in U, step: in (U, T) -> U): U {
  var acc = init
  for x in xs {
    acc = step(acc, x)
  }
  return acc
}

// =====================================================================
// Predicates.
// =====================================================================

/// `true` iff every element satisfies `pred`.  Vacuously true on `[]`.
pub func all[T](xs: in slice[T], pred: in (T) -> Bool): Bool {
  for x in xs {
    if not pred(x) { return false }
  }
  return true
}

/// `true` iff at least one element satisfies `pred`.  False on `[]`.
pub func any[T](xs: in slice[T], pred: in (T) -> Bool): Bool {
  for x in xs {
    if pred(x) { return true }
  }
  return false
}

/// Number of elements that satisfy `pred`.
pub func count[T](xs: in slice[T], pred: in (T) -> Bool): Int {
  var n = 0
  for x in xs {
    if pred(x) {
      n = n + 1
    }
  }
  return n
}

// =====================================================================
// Search.
// =====================================================================

/// First element satisfying `pred`, or `None`.
pub func find[T](xs: in slice[T], pred: in (T) -> Bool): Option[T] {
  for x in xs {
    if pred(x) { return Some(value = x) }
  }
  return None
}

// =====================================================================
// Numeric helpers (monomorphic to sidestep generic-arithmetic
// constraints; will collapse to `fold` once `where T: Add` is wired
// through codegen).
// =====================================================================

/// Sum of an Int slice.
pub func sumInt(xs: in slice[Int]): Int {
  var total = 0
  for x in xs {
    total = total + x
  }
  return total
}
