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
//! `collections_persistent_tests.l` (the `PersistentList[T]` ops below)
//! and `collections_persistent_map_tests.l` (`PersistentMap[K, V]`) are
//! BOTH CI-wired on `--target dotnet` and `--target jvm` (#6577 review
//! follow-up; #6708 for the map suite) — the cross-target claim above is
//! verified, not just structural.
//!
//! Every function here is `@experimental`, not `@stable`, despite that
//! CI verification: this module is brand new (#684) and, until #6568/#6569
//! were fixed, this scope note documented two genuine self-hosted MSIL
//! generic-codegen bugs found in adjacent code while building it, with no
//! other working precedent for this shape anywhere in the codebase.
//! `@stable` is earned by real-world usage accruing confidence beyond a
//! fresh test suite, matching the convention already used for
//! `Std.Collections.mapSize`/`mapIsEmpty` (`@experimental` pending JVM
//! parity validation, #3577).
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
//! `PersistentMap[K, V]` (#684, follow-up #6570) uses the same
//! bare-`slice`-of-`Std.Collections.MapEntry[K, V]` representation — a
//! persistent association list, keyed by a caller-supplied equality
//! predicate rather than a hash/ordering (Lyric has no generic `Eq`/`Ord`
//! interface to dispatch on).  This is the "naive-but-correct over
//! exotic" v1 the original #684 issue asked for, not a balanced BST —
//! a BST needs an ORDERING predicate (not just equality) and rebalancing,
//! a materially larger surface for the same O(n) worst-case complexity
//! profile this module already accepts throughout.  `pmapInsert`/
//! `pmapDelete`/`pmapLookup`/`pmapContainsKey` are all O(n); `pmapSize`/
//! `pmapIsEmpty` are O(1).
//!
//! Building this module surfaced (and, in the same change, fixed) two
//! previously-unknown self-hosted MSIL generic-codegen bugs with no prior
//! working precedent anywhere in the codebase — both now covered by
//! dedicated `lyric-compiler` self-tests:
//!   - #6568 — a union/record case field typed as the enclosing generic
//!     type's own open instantiation (a classic cons-list/BST node, e.g.
//!     `PLCons(head: T, tail: PersistentList[T])`) or as a container
//!     (`List[T]`/`slice[T]`) of the enclosing type's own parameter
//!     corrupted field reads at runtime.
//!   - #6569 — a generic function whose body invokes a closure PARAMETER
//!     inside a loop conditional over a `slice[UserGenericRecord[K, V]]`
//!     parameter (the exact shape `pmapInsert`/`pmapDelete` need for their
//!     caller-supplied equality predicate) monomorphized to a
//!     specialization whose first parameter was erased to `Object`.
//! `PersistentMap[K, V]` below exercises both previously-broken shapes
//! directly (`pmapInsert`/`pmapDelete` invoke `eq` inside a loop over
//! `slice[MapEntry[K, V]]`), verified end-to-end on BOTH targets by
//! `collections_persistent_map_tests.l`.  Building `PersistentMap` also
//! surfaced a THIRD generic-codegen gap — this one in the JVM backend, not
//! MSIL: reading a field off an element indexed out of a `List[T]`/
//! `slice[T]` returned from (or parameter to) a generic function, where `T`
//! is itself a nested generic-record instantiation over the enclosing
//! function's own type parameters (`MapEntry[K, V]`), failed to compile
//! (`error[J007]`, an erased-`Object`-receiver diagnostic).  Fixed in #6708
//! (`Jvm.Codegen.recordParamClassOf`, resolving a bare generic head through
//! the `ctx.ctors` construction registry — cross-package aware, closing
//! exactly this stdlib-record-consumed-from-another-package shape) —
//! `PersistentMap` is now verified on both targets, same as
//! `PersistentList[T]` above.
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

// ─── PersistentMap[K, V] operations (slice[MapEntry[K, V]]) ──────────────
// The empty map is `[]` — `val e: slice[MapEntry[K, V]] = []`.  Every
// lookup/insert/delete takes an explicit `eq: in (K, K) -> Bool` equality
// predicate — Lyric has no generic `Eq[K]` interface to dispatch key
// comparison automatically.
/// True when `m` has no entries.  O(1).
@experimental
pub func pmapIsEmpty[K, V](m: in slice[MapEntry[K, V]]): Bool {
  m.length == 0
}

/// Number of key-value entries.  O(1).
@experimental
pub func pmapSize[K, V](m: in slice[MapEntry[K, V]]): Int {
  m.length
}

/// Look up `key` in `m` using `eq` for key comparison.  Returns the first
/// matching entry's value, or `None` if no entry's key satisfies `eq`.
/// O(n).
@experimental
pub func pmapLookup[K, V](m: in slice[MapEntry[K, V]], key: in K, eq: in (K, K) -> Bool): Option[V] {
  var i = 0
  var found: Option[V] = None
  var done = false
  while i < m.length and not done {
    if eq(m[i].key, key) {
      found = Some(value = m[i].value)
      done = true
    }
    i = i + 1
  }
  found
}

/// True when some entry's key satisfies `eq` against `key`.  O(n).
@experimental
pub func pmapContainsKey[K, V](m: in slice[MapEntry[K, V]], key: in K, eq: in (K, K) -> Bool): Bool {
  match pmapLookup(m, key, eq) {
    case Some(_) -> true
    case None -> false
  }
}

/// Insert `key = value` into `m`, returning a new map.  `m` itself is
/// left untouched.  When an entry's key already satisfies `eq` against
/// `key`, its value is replaced in place (the entry's position is
/// preserved); otherwise the new entry is appended at the end.  O(n):
/// rebuilds the slice.
@experimental
pub func pmapInsert[K, V](
  m: in slice[MapEntry[K, V]], key: in K, value: in V, eq: in (K, K) -> Bool
): slice[MapEntry[K, V]] {
  val acc: List[MapEntry[K, V]] = newList()
  var i = 0
  var replaced = false
  while i < m.length {
    if eq(m[i].key, key) {
      acc.add(MapEntry(key = key, value = value))
      replaced = true
    } else {
      acc.add(m[i])
    }
    i = i + 1
  }
  if not replaced {
    acc.add(MapEntry(key = key, value = value))
  }
  acc.toArray()
}

/// Remove the entry whose key satisfies `eq` against `key`, returning a
/// new map.  A `key` with no matching entry returns `m` unchanged
/// (documented no-op).  O(n): rebuilds the slice.
@experimental
pub func pmapDelete[K, V](m: in slice[MapEntry[K, V]], key: in K, eq: in (K, K) -> Bool): slice[MapEntry[K, V]] {
  val acc: List[MapEntry[K, V]] = newList()
  var i = 0
  var removed = false
  while i < m.length {
    if eq(m[i].key, key) {
      removed = true
    } else {
      acc.add(m[i])
    }
    i = i + 1
  }
  if removed {
    acc.toArray()
  } else {
    m
  }
}

/// Snapshot into a fresh mutable `List[MapEntry[K, V]]`, insertion order.
@experimental
pub func pmapToList[K, V](m: in slice[MapEntry[K, V]]): List[MapEntry[K, V]] {
  val acc: List[MapEntry[K, V]] = newList()
  var i = 0
  while i < m.length {
    acc.add(m[i])
    i = i + 1
  }
  acc
}

/// Build a persistent map from `xs`, preserving order.  A duplicate key
/// in `xs` is NOT deduplicated (unlike `pmapInsert`) — callers that need
/// last-write-wins semantics should fold through `pmapInsert` instead.
@experimental
pub func pmapFromList[K, V](xs: in List[MapEntry[K, V]]): slice[MapEntry[K, V]] {
  xs.toArray()
}
