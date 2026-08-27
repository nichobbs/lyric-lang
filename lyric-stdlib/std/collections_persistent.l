//! std/collections_persistent.l — persistent (immutable, non-mutating)
//! List operations, extending D038's "native stdlib over BCL wrappers"
//! direction to a verification-friendly collection variant (#684).
//!
//! `Std.Collections.List[T]` is a mutable, in-place-updated structure —
//! every write observes through every reference that shares the same
//! underlying storage.  This module instead provides functions that
//! never mutate: every "modifying" operation (`plistCons`, `plistInsert`,
//! `plistDelete`, ...) builds and returns a brand-new value, leaving its
//! input completely untouched — so two values derived from the same
//! starting point never observe each other's "writes".
//!
//! Pure Lyric, no BCL/JVM extern boundary — cross-target by construction
//! (unlike `Std.Collections.List`, which is backed by a BCL/JDK
//! collection type), and so contracts/proofs apply throughout (D038).
//! `collections_persistent_tests.l` is CI-wired on BOTH `--target dotnet`
//! and `--target jvm` (#6577 review follow-up) — the cross-target claim
//! above is verified, not just structural.
//!
//! Every function here is `@experimental`, not `@stable`, despite that
//! CI verification: this module is brand new (#684) and the scope note
//! below documents two genuine, previously-unknown self-hosted MSIL
//! generic-codegen bugs (#6568, #6569) found in adjacent code while
//! building it, with no other working precedent for this shape anywhere
//! in the codebase.  `@stable` is earned by real-world usage accruing
//! confidence beyond a fresh test suite, matching the convention already
//! used for `Std.Collections.mapSize`/`mapIsEmpty` (`@experimental`
//! pending JVM parity validation, #3577).
//!
//! Representation: rather than a bespoke `PersistentList[T]` nominal
//! type, the persistent value IS a `slice[T]` — `slice[T]` is already
//! immutable at the language level (`docs/01-language-reference.md`
//! §5.2: "there is no in-place mutation"), so no wrapper type is needed
//! to keep the "never mutates" contract.  This mirrors `Std.Sort.sort[T]`,
//! which likewise operates on bare `slice[T]` rather than inventing a
//! `SortedSlice[T]` type.  `plistCons`/`plistHead`/`plistTail`/
//! `plistLookup`/`plistInsert`/`plistDelete`/`plistToList`/
//! `plistFromList` are head-to-tail order; `plistHead`/`plistLookup` are
//! O(1), the rest rebuild the slice, O(n).
//!
//! Scope note (#684, tracked follow-up #6570): the issue also asked for
//! a persistent `Map` (and, as a stretch goal, a `Set`).  Hand-probing
//! the self-hosted MSIL backend while building both surfaced two
//! reproducible generic code-generation bugs — each filed with a
//! minimal isolated repro — with no working precedent anywhere in this
//! codebase today:
//!   - #6568 — a union/record case field typed as the enclosing generic
//!     type's own open instantiation (a classic cons-list/BST node, e.g.
//!     `PLCons(head: T, tail: PersistentList[T])`) or as a container
//!     (`List[T]`/`slice[T]`) of the enclosing type's own parameter
//!     corrupts field reads at runtime (silently wrong values,
//!     `MissingFieldException`, or `MissingMethodException`, depending
//!     on the exact shape).
//!   - #6569 — a generic function whose body invokes a closure
//!     PARAMETER inside a loop conditional over a
//!     `slice[UserGenericRecord[K, V]]` parameter (the natural shape
//!     for a `pmapInsert`/`pmapDelete` keyed by a caller-supplied
//!     equality/comparator predicate) monomorphizes to a specialization
//!     whose first parameter is erased to `Object` instead of the real
//!     slice type, crashing with `NullReferenceException` on the very
//!     first call.
//! Every existing recursive type in this codebase (e.g. `Std.Yaml`'s
//! `YamlValue`) is non-generic; every existing generic type (e.g.
//! `Option`/`Result`/`List`/`Map`) is non-recursive and never invokes a
//! closure parameter over its own generic container shape.  `PersistentList[T]`
//! above is a proven-safe subset (plain `slice[T]`, no closures invoked
//! over a user-generic-record container) that sidesteps both gaps; the
//! persistent `Map`/`Set` are deferred to #6570 (blocked on #6568/#6569)
//! rather than shipped broken or stubbed.
@runtime_checked
package Std.Collections.Persistent

import Std.Core
import Std.Collections

// ─── PersistentList[T] operations (slice[T]) ─────────────────────────────
// The empty list is `[]` — `val e: slice[Int] = []`.
@experimental
pub func plistIsEmpty[T](lst: in slice[T]): Bool {
  lst.length == 0
}

/// Number of elements.  O(1).
@experimental
pub func plistLength[T](lst: in slice[T]): Int {
  lst.length
}

/// The first element, or `None` for the empty list.  O(1).
@experimental
pub func plistHead[T](lst: in slice[T]): Option[T] {
  if lst.length == 0 {
    None
  } else {
    Some(value = lst[0])
  }
}

/// Every element after the first, or `None` for the empty list.  O(n):
/// rebuilds a fresh slice for the remainder.
@experimental
pub func plistTail[T](lst: in slice[T]): Option[slice[T]] {
  if lst.length == 0 {
    None
  } else {
    val acc: List[T] = newList()
    var i = 1
    while i < lst.length {
      acc.add(lst[i])
      i = i + 1
    }
    Some(value = acc.toArray())
  }
}

/// Prepend `x` to `lst`, returning a new list.  `lst` itself is left
/// untouched — any other value that referenced it before the call still
/// sees the original list.  O(n): rebuilds the slice.
@experimental
pub func plistCons[T](x: in T, lst: in slice[T]): slice[T] {
  val acc: List[T] = newList()
  acc.add(x)
  var i = 0
  while i < lst.length {
    acc.add(lst[i])
    i = i + 1
  }
  acc.toArray()
}

/// The element at `index` (0-based), or `None` if out of range.  O(1).
@experimental
pub func plistLookup[T](lst: in slice[T], index: in Int): Option[T] {
  if index < 0 or index >= lst.length {
    None
  } else {
    Some(value = lst[index])
  }
}

/// Insert `x` before position `index`, returning a new list.  `index <= 0`
/// inserts at the front; `index >=` the current length appends at the
/// end.  O(n): rebuilds the slice.
@experimental
pub func plistInsert[T](lst: in slice[T], index: in Int, x: in T): slice[T] {
  val n = lst.length
  val clamped = if index < 0 { 0 } else if index > n { n } else { index }
  val acc: List[T] = newList()
  var i = 0
  while i < clamped {
    acc.add(lst[i])
    i = i + 1
  }
  acc.add(x)
  while i < n {
    acc.add(lst[i])
    i = i + 1
  }
  acc.toArray()
}

/// Remove the element at `index`, returning a new list.  Out-of-range
/// `index` (negative, or `>=` the current length) returns `lst`
/// unchanged.  O(n): rebuilds the slice.
@experimental
pub func plistDelete[T](lst: in slice[T], index: in Int): slice[T] {
  if index < 0 or index >= lst.length {
    lst
  } else {
    val acc: List[T] = newList()
    var i = 0
    while i < lst.length {
      if i != index {
        acc.add(lst[i])
      }
      i = i + 1
    }
    acc.toArray()
  }
}

/// Snapshot into a fresh mutable `Std.Collections.List[T]`, front-to-back.
@experimental
pub func plistToList[T](lst: in slice[T]): List[T] {
  val acc: List[T] = newList()
  var i = 0
  while i < lst.length {
    acc.add(lst[i])
    i = i + 1
  }
  acc
}

/// Build a persistent list from `xs`, preserving order (`xs[0]` becomes
/// the head).
@experimental
pub func plistFromList[T](xs: in List[T]): slice[T] {
  xs.toArray()
}
