# D-progress-1041 — Tuples across the component boundary

**Status:** shipped (W4 follow-up, tracked in #8117 item 1)

A Lyric tuple `(A, B, ...)` of two or more value types is the WIT `tuple<a, b, ...>`.

## Decision

1. **Type.** `TTuple` resolves to a new `WTuple` over the element types (each a value
   type, so no `Unit`; one-element tuples do not exist in Lyric). It nests freely: in
   `Option`, `Result`, `List`, a record field, a variant payload, another tuple.
2. **Layout.** The canonical ABI lays a tuple out exactly as a record whose fields are the
   elements in order, so `alignOf`, `sizeOf`, `flatOf` and `needsFree` delegate to that
   record shape (`tupleFields`) instead of duplicating the rules.
3. **Shims.** Lift and load build the Lyric tuple literal from the element values; store
   and free destructure with `val (f0, f1) = v` (Lyric has no `.0` access). No
   `lowerflat` is generated: a tuple always spans at least two flat values, so it is
   returned through a return area like any multi-value result.
4. **WIT.** A tuple is written inline (`tuple<s32, string>`), never as a named type, so it
   adds nothing to the interface's definitions; its element types are collected as usual.

## Not changed

A tuple across a host import, and across Lyric packages, wait on the general import shim
and cross-package type work (#8117 items 2 and 3).
