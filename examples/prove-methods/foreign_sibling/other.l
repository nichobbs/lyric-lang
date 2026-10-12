//! Another package's interface that happens to share a name with
//! `Std.Stream.ByteReader`.
package Other

pub interface ByteReader {
  func read(maxBytes: in Int): Int
    requires: maxBytes > 1000
}
