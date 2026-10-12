//! An `impl` of a standard-library interface inherits its clauses: `lyric
//! prove` reads `Std.Stream`'s `ByteReader.read`, whose `requires: maxBytes
//! > 0` is what proves `ensures: maxBytes >= 1` here (#8231).
@proof_required
package Reader

import Std.Core
import Std.Stream
import Std.Errors

record Empty {
  n: Int
}

impl ByteReader for Empty {
  func read(maxBytes: in Nat): Result[slice[Byte], IOError]
    ensures: maxBytes >= 1
  {
    Err(error = IoError(path = "empty", message = "nothing to read"))
  }
}
