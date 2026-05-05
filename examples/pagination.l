@proof_required
package Pagination

// Pagination helper: given a 0-based page index and a positive page
// size, compute the start offset and item count for that page.
//
// Run with:
//
//     lyric prove examples/pagination.l --verbose
//
// All obligations discharge under the shipped M4.2 verifier when z3 is
// on $PATH.  Without z3, arithmetic obligations go Unknown; pass
// --allow-unverified to suppress V0007 in that case.

// ---------------------------------------------------------------------------
// pageStart: offset of the first item on page `page`.
//
// Post-condition: result >= 0.
// Proof sketch: loop starts with start = 0 >= 0, and each iteration adds
// size > 0, so start stays non-negative.  At exit the loop invariant
// `start >= 0` implies the post.
// ---------------------------------------------------------------------------
pub func pageStart(page: Int, size: Int): Int
  requires: page >= 0
  requires: size  > 0
  ensures:  result >= 0
{
  var start: Int = 0
  var i: Int = 0
  while i < page
    invariant: i >= 0
    invariant: start >= 0
  {
    start = start + size
    i     = i + 1
  }
  return start
}

// ---------------------------------------------------------------------------
// pageCount: number of items on page `page`.
//
// Post-conditions:
//   1. result >= 0          — the count is never negative.
//   2. result <= size       — no page has more items than the page size.
//
// Proof sketch: three branches.
//   - remaining <= 0  -> return 0:          0 >= 0, 0 <= size (size > 0).
//   - remaining < size -> return remaining: remaining > 0 and < size,
//                           so 0 < remaining <= size.  Both posts hold.
//   - else             -> return size:      size > 0 >= 0, size <= size.
//
// The cross-call rule supplies `start >= 0` from pageStart's ensures, so
// the `remaining = total - start` binding carries enough information for
// the solver to reason about the branches.
// ---------------------------------------------------------------------------
pub func pageCount(page: Int, size: Int, total: Int): Int
  requires: page  >= 0
  requires: size   > 0
  requires: total >= 0
  ensures:  result >= 0
  ensures:  result <= size
{
  val start:     Int = pageStart(page, size)
  val remaining: Int = total - start
  if remaining <= 0 {
    return 0
  } else if remaining < size {
    return remaining
  } else {
    return size
  }
}
