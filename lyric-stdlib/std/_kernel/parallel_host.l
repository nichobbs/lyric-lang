//! std/_kernel/parallel_host.l - the sequential `Std.ParallelHost` for the managed targets
//! (docs/67 G8, D202).  There is no worker pool here: a loop runs in order on the calling thread,
//! which is a correct (if not faster) implementation of `Std.Parallel`'s contract, since it only
//! promises that every body runs once and has finished when the call returns.  The native twin
//! is `_kernel_native/parallel_host.l`.
//!
//! Internal: only Std.Parallel should import this.
@io
package Std.ParallelHost

import Std.Core
import Std.Buffer

pub func hostThreadCount(): Int {
  1
}

pub func hostRun(count: in Int, body: in (Int) -> Unit): Unit {
  var i = 0
  while i < count {
    body(i)
    i = i + 1
  }
}

/// Runs `body(start, chunk)` for every chunk of `chunkSize` elements of `b` in order, replacing
/// each chunk with the buffer the body returns (the same length).
pub func hostForChunks[T](b: inout buffer[T], chunkSize: in Int, body: in (Int, buffer[T]) -> buffer[T]): Unit
  where T: Plain
{
  val total = b.length
  var start = 0
  while start < total {
    val len = if start + chunkSize > total { total - start } else { chunkSize }
    val seed: T = b[start]
    var chunk = filled(len, seed)
    var j = 0
    while j < len {
      chunk[j] = b[start + j]
      j = j + 1
    }
    val updated = body(start, chunk)
    if updated.length != len {
      panic(
        "Std.Parallel.forChunks: the body returned " + updated.length.toString() + " elements for a chunk of " +
          len.toString()
      )
    }
    j = 0
    while j < len {
      b[start + j] = updated[j]
      j = j + 1
    }
    start = start + len
  }
}
