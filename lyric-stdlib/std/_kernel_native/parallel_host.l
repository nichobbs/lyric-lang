//! std/_kernel_native/parallel_host.l - native `Std.ParallelHost`: the worker pool of
//! `lyric-rt` (`lyric_parallel.c`, docs/67 G8, D202) behind the surface the managed twins
//! implement sequentially.
//!
//! `hostRun(count, body)` hands `body` to `lyric_parallel_for` as a callback with a trailing
//! user-data slot (the closure itself, as `Std.Task` hands one to `lyric_thread_spawn_detached`).
//! The call is synchronous, so the closure outlives every use of it and needs no extra retain.
//!
//! Internal: only Std.Parallel should import this.
@axiom("lyric_parallel_threads and lyric_parallel_for (lyric-rt) conform to their documented contracts: every index runs exactly once, all bodies have finished when the call returns, and writes made by a body happen before the return")
@io
package Std.ParallelHost

import Std.Core
import Std.Collections
import Std.Buffer

extern func rtParallelThreads(): Int = "lyric_parallel_threads"

extern func rtParallelFor(count: Long, body: (Long, NativePtr[Byte]) -> Unit, userdata: NativePtr[Byte]): Unit = "lyric_parallel_for"

pub func hostThreadCount(): Int {
  rtParallelThreads()
}

@unsafe_ffi
pub func hostRun(count: in Int, body: in (Int) -> Unit): Unit {
  val worker: (Long) -> Unit = { i: Long -> body(i.toInt()) }
  rtParallelFor(count.toLong(), worker, worker)
}

/// Splits `b` into chunks of `chunkSize` elements and runs `body(start, chunk)` on every chunk
/// across the pool.  Each body gets a private copy of its chunk and returns the chunk's new
/// elements (the same length); the results replace the chunks in `b` once every body has
/// finished, so no two threads ever write the same storage and copy-on-write (D186) is never in
/// play.
pub func hostForChunks[T](b: inout buffer[T], chunkSize: in Int, body: in (Int, buffer[T]) -> buffer[T]): Unit
  where T: Plain
{
  val total = b.length
  if total == 0 {
    return
  }
  val source = b
  val chunks = (total + chunkSize - 1) / chunkSize
  val results: List[buffer[T]] = newListWithCapacity(chunks)
  var k = 0
  while k < chunks {
    results.add(filled(0, source[0]))
    k = k + 1
  }
  val work: (Int) -> Unit = { i: Int ->
    val start = i * chunkSize
    val len = if start + chunkSize > total { total - start } else { chunkSize }
    var chunk = filled(len, source[start])
    var j = 0
    while j < len {
      chunk[j] = source[start + j]
      j = j + 1
    }
    val updated = body(start, chunk)
    if updated.length != len {
      panic(
        "Std.Parallel.forChunks: the body returned " + updated.length.toString() + " elements for a chunk of " +
          len.toString()
      )
    }
    // Each index is written by exactly one body and the list was filled to its final length above,
    // so no slot is shared and the backing store never moves while the pool runs.
    results[i] = updated
  }
  hostRun(chunks, work)
  var merged = filled(total, source[0])
  var c = 0
  while c < chunks {
    val start = c * chunkSize
    val piece = results[c]
    var j = 0
    while j < piece.length {
      merged[start + j] = piece[j]
      j = j + 1
    }
    c = c + 1
  }
  b = merged
}
