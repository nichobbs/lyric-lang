// std/iter.l - Iterator helpers over `slice[T]`.
//
// Includes both non-allocating helpers (`forEach`, `fold`, `any`,
// `all`, `count`, `find`, `sumInt`) and allocating helpers
// (`map`, `filter`, `take`, `drop`, `concat`).  Allocating helpers
// build a `List[T]` via the generic FFI in `Std.Collections`, then
// return `list.toArray()` so the caller sees `slice[T]`.
package Std.Iter

import Std.Core
import Std.Collections

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
// Allocating helpers — build a `List[T]` via Std.Collections then
// return `.toArray()` so the result is a `slice[T]`.
// =====================================================================

/// Map each element through `f`, collecting the results into a fresh
/// slice.  `mapTo([1, 2, 3], { n: Int -> n * 2 }) == [2, 4, 6]`.
pub func map[T, U](xs: in slice[T], f: in (T) -> U): slice[U] {
  val acc: List[U] = newList()
  for x in xs {
    acc.add(f(x))
  }
  return acc.toArray()
}

/// Keep only the elements that satisfy `pred`.
pub func filter[T](xs: in slice[T], pred: in (T) -> Bool): slice[T] {
  val acc: List[T] = newList()
  for x in xs {
    if pred(x) {
      acc.add(x)
    }
  }
  return acc.toArray()
}

/// First `n` elements, or fewer if `xs.length < n`.  Negative `n`
/// returns the empty slice (the inner counter never reaches a
/// negative threshold).
pub func take[T](xs: in slice[T], n: in Int): slice[T] {
  val acc: List[T] = newList()
  var i = 0
  for x in xs {
    if i < n {
      acc.add(x)
    }
    i = i + 1
  }
  return acc.toArray()
}

/// Skip the first `n` elements.  Negative `n` returns a copy of the
/// whole slice.
pub func drop[T](xs: in slice[T], n: in Int): slice[T] {
  val acc: List[T] = newList()
  var i = 0
  for x in xs {
    if i >= n {
      acc.add(x)
    }
    i = i + 1
  }
  return acc.toArray()
}

/// Concatenate two slices, allocating a fresh result.  Use repeatedly
/// for variable-arity concat — `concat(concat(a, b), c)` etc.
pub func concat[T](a: in slice[T], b: in slice[T]): slice[T] {
  val acc: List[T] = newList()
  for x in a {
    acc.add(x)
  }
  for x in b {
    acc.add(x)
  }
  return acc.toArray()
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

/// Sum every element of a `slice[Long]`.  Empty slices return 0.
pub func sumLong(xs: in slice[Long]): Long {
  var total: Long = 0i64
  for x in xs {
    total = total + x
  }
  return total
}

/// Sum every element of a `slice[Double]`.  Empty slices return 0.0.
pub func sumDouble(xs: in slice[Double]): Double {
  var total: Double = 0.0
  for x in xs {
    total = total + x
  }
  return total
}

/// Return the smallest Int in `xs`.  `None` for empty slices.
pub func iterMinInt(xs: in slice[Int]): Option[Int] {
  if xs.length == 0 {
    return None
  }
  var best: Int = xs[0]
  for x in xs {
    if x < best {
      best = x
    }
  }
  return Some(value = best)
}

/// Return the largest Int in `xs`.  `None` for empty slices.
pub func iterMaxInt(xs: in slice[Int]): Option[Int] {
  if xs.length == 0 {
    return None
  }
  var best: Int = xs[0]
  for x in xs {
    if x > best {
      best = x
    }
  }
  return Some(value = best)
}

/// Return the smallest Long in `xs`.  `None` for empty slices.
pub func minLong(xs: in slice[Long]): Option[Long] {
  if xs.length == 0 {
    return None
  }
  var best: Long = xs[0]
  for x in xs {
    if x < best {
      best = x
    }
  }
  return Some(value = best)
}

/// Return the largest Long in `xs`.  `None` for empty slices.
pub func maxLong(xs: in slice[Long]): Option[Long] {
  if xs.length == 0 {
    return None
  }
  var best: Long = xs[0]
  for x in xs {
    if x > best {
      best = x
    }
  }
  return Some(value = best)
}

/// Reverse a `slice[T]` into a fresh slice; the original is unchanged.
pub func reverse[T](xs: in slice[T]): slice[T] {
  val acc: List[T] = newList()
  val n: Int = xs.length
  var i: Int = 0
  while i < n {
    acc.add(xs[n - 1 - i])
    i = i + 1
  }
  return acc.toArray()
}
