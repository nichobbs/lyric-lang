//! std/parallel.l - Std.Parallel: data-parallel loops over a worker pool (docs/67 G8, D202).
//!
//! `forRange` runs a body for every index of a range, `forChunks` splits a `buffer[T]` into
//! disjoint chunks and hands each to a body, and `threadCount` says how many threads share the
//! work.  On `--target native` the work runs on a pool of OS threads (the processor count, or
//! `LYRIC_THREADS`); on the managed targets the same calls run in order on the calling thread, so
//! a program computes the same results everywhere and only the native build is faster.
//!
//! `forChunks` is the structured way to write one buffer from several threads: the runtime, not
//! user code, owns the split, so the chunks cannot overlap (the kernel twins implement it:
//! staged copies on a pool on native, in order on the managed targets).  Each body receives the index of its
//! chunk's first element and a private copy of the chunk, and returns the chunk's new contents
//! (the same length); the results are copied back into the buffer once every body has finished.
//! Because a body never sees the buffer itself, no two bodies can touch the same storage, and the
//! copy-on-write rule of `buffer[T]` (D185) is never involved.
//!
//! A body runs on a pool thread, concurrently with the others.  It may read what it captured
//! (captured values are immutable or copy-on-write) and must not mutate shared reference-typed
//! state such as a `List` or `Map` held outside; share mutable state through a `protected type`.
//! A panic in a body ends the process on native, as everywhere there.
@runtime_checked
@io
package Std.Parallel

import Std.Core
import Std.ParallelHost

/// How many threads a parallel loop uses: the pool's workers plus the calling thread.
/// 1 on the managed targets, on wasm32-wasi, and when `LYRIC_THREADS=1`.
@stable(since = "1.0")
pub func threadCount(): Int
  ensures: result >= 1
{
  hostThreadCount()
}

/// Calls `body(i)` for every `i` in `0 ..< count`, spread across the pool.  Returns when every
/// call has finished.  Calls for different `i` may run at the same time and in any order.
@stable(since = "1.0")
pub func forRange(count: in Int, body: in (Int) -> Unit): Unit
  requires: count >= 0
{
  hostRun(count, body)
}

/// Splits `b` into chunks of `chunkSize` elements (the last may be shorter) and runs `body` on
/// every chunk across the pool.  `body(start, chunk)` receives the chunk's first index in `b` and
/// a copy of its elements, and returns the chunk's new elements, which must be the same length.
/// When every body has finished the results replace the chunks in `b`.
@stable(since = "1.0")
pub func forChunks[T](b: inout buffer[T], chunkSize: in Int, body: in (Int, buffer[T]) -> buffer[T]): Unit
  where T: Plain
  requires: chunkSize > 0
{
  hostForChunks(b, chunkSize, body)
}
