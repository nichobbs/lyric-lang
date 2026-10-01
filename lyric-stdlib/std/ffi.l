//! std/ffi.l — C memory and C strings for `@library` bindings (D161).
//!
//! A C function that takes `const char*` needs a NUL-terminated UTF-8
//! buffer in C memory, and one that returns `char*` hands back such a
//! buffer.  `toCString` and `tryFromCString` convert between those and a
//! Lyric `String` on every target, over the C heap (`allocate` /
//! `release`) and the `nativeLoadByte` / `nativeStoreByte` intrinsics.
//!
//! Every function here takes or returns a `NativePtr`, so it is
//! `@unsafe_ffi` and callable only from `@unsafe_ffi` code (N0100).
//! Ownership follows C: a buffer from `allocate` or `toCString` is the
//! caller's until it is passed to `release` (or to a C function that
//! documents taking ownership), and is released exactly once.
@runtime_checked
@io
package Std.Ffi

import Std.Core
import Std.Collections
import Std.Encoding
import Std.FfiHost

/// Allocates `size` bytes on the C heap.  The contents are unspecified.
/// Panics when the C heap is exhausted.  Release the buffer with
/// `release`.
@unsafe_ffi
@experimental
pub func allocate(size: in Long): NativePtr[Byte]
  requires: size > 0
{
  val p = hostAllocate(size)
  if p == nativeNullPtr() {
    panic("Std.Ffi.allocate: the C heap could not supply the requested bytes")
  }
  p
}

/// Releases a buffer from `allocate` or `toCString`.  Releasing the null
/// pointer does nothing, as `free(3)` specifies.
@unsafe_ffi
@experimental
pub func release(p: in NativePtr[Byte]): Unit {
  hostRelease(p)
}

/// Copies `s` into a new NUL-terminated UTF-8 buffer on the C heap.  A NUL
/// inside `s` ends the string as C sees it.  Release the buffer with
/// `release`.
@unsafe_ffi
@experimental
pub func toCString(s: in String): NativePtr[Byte] {
  val bytes = encodeUtf8(s)
  val n = bytes.length
  val p = allocate(n.toLong() + 1)
  var i = 0
  while i < n {
    nativeStoreByte(p, i.toLong(), bytes[i])
    i += 1
  }
  nativeStoreByte(p, n.toLong(), 0u8)
  p
}

/// Reads the NUL-terminated UTF-8 string at `p`.  Returns `None` when `p`
/// is the null pointer or the bytes are not valid UTF-8.  The buffer stays
/// with its owner; this copies it.
@unsafe_ffi
@experimental
pub func tryFromCString(p: in NativePtr[Byte]): Option[String] {
  if p == nativeNullPtr() {
    return None
  }
  val bytes: List[Byte] = newList()
  var i: Long = 0
  var b = nativeLoadByte(p, i)
  while b != 0u8 {
    bytes.add(b)
    i += 1
    b = nativeLoadByte(p, i)
  }
  tryDecodeUtf8(bytes.toArray())
}
