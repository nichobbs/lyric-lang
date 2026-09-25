//! std/sort.l - Stable merge sort over slices.
//!
//! `sort[T]` accepts an explicit comparator so it works for any element
//! type without a built-in ordering constraint.  Convenience wrappers
//! (`sortInts`, `sortLongs`, `sortStrings`) bake in the natural orderings.
//!
//! Algorithm: bottom-up merge sort.  Runs of 16 elements are
//! insertion-sorted in place, then merged pairwise, doubling the run width
//! each pass and alternating between two buffers that are each allocated
//! once.  O(n log n) comparisons, O(n) extra space, no recursion.  The
//! earlier top-down version copied every element into fresh sub-slices at
//! each recursion level (#7281).
//!
//! Stability guarantee: insertion sort only moves an element past a
//! strictly greater one, and `mergeRuns` takes from the left run when
//! `cmp(left, right) <= 0`, so equal elements keep their original order.
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
@stable(since = "1.0")
pub func sort[T](xs: in slice[T], cmp: in (T, T) -> Int): slice[T] {
  val n = xs.length
  if n <= 1 {
    return xs
  }
  // Runs this short are insertion-sorted: fewer comparisons and no buffer
  // traffic for the small ranges merge sort handles poorly. A local rather
  // than a module val because generic bodies are specialised into the
  // caller's package, where this package's private vals do not resolve.
  val insertionRun = 16
  val a: List[T] = newListWithCapacity(n)
  val b: List[T] = newListWithCapacity(n)
  for x in xs {
    a.add(x)
    b.add(x)
  }
  var lo = 0
  while lo < n {
    val hi = if lo + insertionRun < n { lo + insertionRun } else { n }
    insertionSortRange(a, lo, hi, cmp)
    lo = hi
  }
  var src = a
  var dst = b
  var width = insertionRun
  while width < n {
    var left = 0
    while left < n {
      val mid = if left + width < n { left + width } else { n }
      val right = if left + 2 * width < n { left + 2 * width } else { n }
      mergeRuns(src, dst, left, mid, right, cmp)
      left = right
    }
    val swap = src
    src = dst
    dst = swap
    width = width * 2
  }
  src.toArray()
}

/// Sort an `Int` slice into ascending order.
@stable(since = "1.0")
pub func sortInts(xs: in slice[Int]): slice[Int] {
  sort(xs, { a: Int, b: Int -> if a < b { -1 } else if a > b { 1 } else { 0 } })
}

/// Sort a `Long` slice into ascending order.
@stable(since = "1.0")
pub func sortLongs(xs: in slice[Long]): slice[Long] {
  sort(xs, { a: Long, b: Long -> if a < b { -1 } else if a > b { 1 } else { 0 } })
}

/// Sort a `String` slice in ascending lexicographic order.
@stable(since = "1.0")
pub func sortStrings(xs: in slice[String]): slice[String] {
  sort(xs, { a: String, b: String -> if a < b { -1 } else if a > b { 1 } else { 0 } })
}

/// True iff `xs` is non-strictly ordered according to `cmp`.
/// Vacuously true for empty and single-element slices.
@stable(since = "1.0")
pub func isSorted[T](xs: in slice[T], cmp: in (T, T) -> Int): Bool {
  var i = 1
  while i < xs.length {
    if cmp(xs[i - 1], xs[i]) > 0 {
      return false
    }
    i = i + 1
  }
  return true
}

// =====================================================================
// Private helpers.
// =====================================================================
// Stable insertion sort of `xs[lo, hi)` in place.
func insertionSortRange[T](xs: in List[T], lo: in Int, hi: in Int, cmp: in (T, T) -> Int): Unit {
  var i = lo + 1
  while i < hi {
    val key = xs[i]
    var j = i - 1
    while j >= lo and cmp(xs[j], key) > 0 {
      xs[j + 1] = xs[j]
      j = j - 1
    }
    xs[j + 1] = key
    i = i + 1
  }
}

// Merge the sorted runs `src[lo, mid)` and `src[mid, hi)` into `dst[lo, hi)`.
func mergeRuns[T](src: in List[T], dst: in List[T], lo: in Int, mid: in Int, hi: in Int, cmp: in (T, T) -> Int): Unit {
  var i = lo
  var j = mid
  var k = lo
  while i < mid and j < hi {
    if cmp(src[i], src[j]) <= 0 {
      dst[k] = src[i]
      i = i + 1
    } else {
      dst[k] = src[j]
      j = j + 1
    }
    k = k + 1
  }
  while i < mid {
    dst[k] = src[i]
    i = i + 1
    k = k + 1
  }
  while j < hi {
    dst[k] = src[j]
    j = j + 1
    k = k + 1
  }
}
