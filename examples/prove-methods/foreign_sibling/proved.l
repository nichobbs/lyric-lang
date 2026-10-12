//! A file of another package in the same directory is no part of this
//! package's build: its `ByteReader` is not the one this `impl` implements,
//! and its `requires: maxBytes > 1000` is not assumed.  The interface is
//! `Std.Stream`'s, which only promises `maxBytes > 0`, so `ensures:
//! maxBytes > 500` is refuted (#8231).
@proof_required
package Proved

import Std.Core
import Std.Stream
import Std.Errors

record F {
  n: Int
}

impl ByteReader for F {
  func read(maxBytes: in Nat): Result[slice[Byte], IOError]
    ensures: maxBytes > 500
  {
    Err(error = IoError(path = "p", message = "x"))
  }
}
