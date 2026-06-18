// std/sort.l - Stable merge sort over slices.
//
// `sort[T]` accepts an explicit comparator so it works for any element
// type without a built-in ordering constraint.  Two convenience wrappers
// (`sortInts`, `sortStrings`) bake in the natural orderings.
//
// Algorithm: top-down merge sort.  O(n log n) comparisons; O(n log n)
// allocation because each recursive level materialises left/right sub-
// slices through `Std.Collections.List[T]`.  A future Phase 2 revision
// can reduce that to O(n) by passing index ranges and a single scratch
// buffer once mutable slice views are available.
//
// Stability guarantee: `mergeSorted` appends from the left sub-slice
// when `cmp(left[i], right[j]) <= 0`, so equal elements from the left
// half always precede equal elements from the right half.

package Std.Sort

import Std.Collections

// =====================================================================
// Public surface.
// =====================================================================

/// Sort `xs` into a fresh slice using `cmp` as the ordering relation.
///
/// `cmp(a, b)` must return:
///   - a negative integer when `a` should precede `b`,
///   - zero when `a` and `b` are considered equal,
///   - a positive integer when `b` should precede `a`.
///
/// The sort is stable: equal elements preserve their original relative order.
@stable(since="1.0")
pub func sort[T](xs: in slice[T], cmp: in (T, T) -> Int): slice[T] {
  val n = xs.length
  if n <= 1 { return xs }
  val mid = n / 2
  val left  = sliceCopy(xs, 0, mid)
  val right = sliceCopy(xs, mid, n)
  return mergeSorted(sort(left, cmp), sort(right, cmp), cmp)
}

/// Sort an `Int` slice into ascending order.
@stable(since="1.0")
pub func sortInts(xs: in slice[Int]): slice[Int] {
  sort(xs, { a: Int, b: Int ->
    if a < b { -1 } else if a > b { 1 } else { 0 }
  })
}

/// Sort a `Long` slice into ascending order.
@stable(since="1.0")
pub func sortLongs(xs: in slice[Long]): slice[Long] {
  sort(xs, { a: Long, b: Long ->
    if a < b { -1 } else if a > b { 1 } else { 0 }
  })
}

/// Sort a `String` slice in ascending lexicographic order.
@stable(since="1.0")
pub func sortStrings(xs: in slice[String]): slice[String] {
  sort(xs, { a: String, b: String ->
    if a < b { -1 } else if a > b { 1 } else { 0 }
  })
}

/// True iff `xs` is non-strictly ordered according to `cmp`.
/// Vacuously true for empty and single-element slices.
@stable(since="1.0")
pub func isSorted[T](xs: in slice[T], cmp: in (T, T) -> Int): Bool {
  var i = 1
  while i < xs.length {
    if cmp(xs[i - 1], xs[i]) > 0 { return false }
    i = i + 1
  }
  return true
}

// =====================================================================
// Private helpers.
// =====================================================================

func sliceCopy[T](xs: in slice[T], lo: in Int, hi: in Int): slice[T] {
  val acc: List[T] = newList()
  var i = lo
  while i < hi {
    acc.add(xs[i])
    i = i + 1
  }
  return acc.toArray()
}

func mergeSorted[T](left: in slice[T], right: in slice[T], cmp: in (T, T) -> Int): slice[T] {
  val acc: List[T] = newList()
  var i = 0
  var j = 0
  while i < left.length and j < right.length {
    if cmp(left[i], right[j]) <= 0 {
      acc.add(left[i])
      i = i + 1
    } else {
      acc.add(right[j])
      j = j + 1
    }
  }
  while i < left.length {
    acc.add(left[i])
    i = i + 1
  }
  while j < right.length {
    acc.add(right[j])
    j = j + 1
  }
  return acc.toArray()
}
