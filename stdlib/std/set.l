// std/set.l - Hash-based set with O(1) average membership test.
//
// `Set[T]` is a thin Lyric wrapper over the BCL `HashSet<T>` (declared
// as `extern type Set[T]` in `Std.CollectionsHost`).  BCL method dispatch
// is used for the core operations (`add`, `contains`, `remove`, `count`)
// the same way `List[T]` is used in `Std.Iter`.
//
// Set-algebra operations (`setUnion`, `setIntersection`, `setDifference`)
// materialise their arguments as slices via `setToSlice` (which routes
// through the `Lyric.Stdlib.SetHost.SetToArray` shim because `HashSet<T>`
// exposes `.ToArray()` only as a LINQ extension method).  Each algebra
// operation builds a fresh `Set[T]` and returns it.
//
// Naming convention: all exported functions carry a `set` prefix to avoid
// clashing with the identically-named BCL dispatch calls (`add`, `remove`,
// `contains`) that appear in the function bodies as receiver calls on the
// extern type.

package Std.Set

import Std.Core
import Std.CollectionsHost

// =====================================================================
// Single-set operations.
// =====================================================================

/// Test whether `item` is a member of `s`.
@stable(since="1.0")
pub func setContains[T](s: in Set[T], item: in T): Bool { s.contains(item) }

/// Add `item` to `s`.  No-op when `item` is already present.
@stable(since="1.0")
pub func setAdd[T](s: in Set[T], item: in T): Unit { s.add(item) }

/// Remove `item` from `s`.  Returns `true` if it was present, `false` if absent.
@stable(since="1.0")
pub func setRemove[T](s: in Set[T], item: in T): Bool { s.remove(item) }

/// Number of distinct elements in `s`.
@stable(since="1.0")
pub func setSize[T](s: in Set[T]): Int { s.count }

/// True when `s` has no elements.
@stable(since="1.0")
pub func setIsEmpty[T](s: in Set[T]): Bool { s.count == 0 }

// =====================================================================
// Conversion.
// =====================================================================

/// Build a set from the elements of `xs`.  Duplicate elements are silently
/// deduplicated; the result contains each value at most once.
@stable(since="1.0")
pub func setFromSlice[T](xs: in slice[T]): Set[T] {
  val s: Set[T] = newSet()
  for x in xs {
    s.add(x)
  }
  return s
}

/// Return all elements of `s` as an unordered slice.  The slice ordering
/// is determined by the BCL's internal bucket traversal and should not be
/// relied upon across calls.
@stable(since="1.0")
pub func setElements[T](s: in Set[T]): slice[T] {
  setToSlice(s)
}

// =====================================================================
// Set algebra — each returns a fresh set.
// =====================================================================

/// All elements that appear in `a`, `b`, or both.
@stable(since="1.0")
pub func setUnion[T](a: in Set[T], b: in Set[T]): Set[T] {
  val r: Set[T] = newSet()
  for x in setToSlice(a) {
    r.add(x)
  }
  for x in setToSlice(b) {
    r.add(x)
  }
  return r
}

/// Elements that appear in both `a` and `b`.
@stable(since="1.0")
pub func setIntersection[T](a: in Set[T], b: in Set[T]): Set[T] {
  val r: Set[T] = newSet()
  for x in setToSlice(a) {
    if b.contains(x) {
      r.add(x)
    }
  }
  return r
}

/// Elements that appear in `a` but not in `b`.
@stable(since="1.0")
pub func setDifference[T](a: in Set[T], b: in Set[T]): Set[T] {
  val r: Set[T] = newSet()
  for x in setToSlice(a) {
    if not b.contains(x) {
      r.add(x)
    }
  }
  return r
}

/// True iff every element of `sub` is also an element of `super_`.
@stable(since="1.0")
pub func setIsSubset[T](sub: in Set[T], super_: in Set[T]): Bool {
  for x in setToSlice(sub) {
    if not super_.contains(x) { return false }
  }
  return true
}

/// True iff `a` and `b` contain exactly the same elements.
@stable(since="1.0")
pub func setEquals[T](a: in Set[T], b: in Set[T]): Bool {
  if a.count != b.count { return false }
  for x in setToSlice(a) {
    if not b.contains(x) { return false }
  }
  return true
}
