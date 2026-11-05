//! std/buffer.l - Construction and conversion for `buffer[T]` (D185).
//!
//! A `buffer[T]` is a contiguous, runtime-length sequence of `Plain`
//! elements with value semantics: assigning, passing or capturing one
//! behaves as a copy, and a write through one binding is never visible
//! through another.  Elements are read and written with `b[i]`, the length
//! is `b.length`, and `for x in b` iterates a snapshot.  The length is fixed
//! at creation; `grow` and `truncate` return a new buffer.
//!
//! These functions are written against the buffer's own operations, plus the
//! two members that move between a buffer and the `List` that represents it
//! on a target that represents a buffer as a list; the compiler lowers those
//! members, and they are usable only in this package.  `list.__lyric_buffer_from_list()`
//! initialises a binding annotated with its `buffer[T]` type, which is where the
//! dotnet and JVM lowering reads the element type from.
//!
//! The `ensures:` clauses state each result's length and its elements; a
//! slice's elements never change once it exists (D400), so a slice result's
//! elements are stated too.  `lyric prove` applies them at a call (#8753);
//! the element clauses quantify over indices, so a runtime-checked build
//! skips them (W0002) and checks the lengths.
@runtime_checked
@pure
package Std.Buffer

import Std.Collections

/// A buffer of `count` copies of `value`.
@stable(since = "1.0")
pub func filled[T](count: in Int, value: in T): buffer[T]
  where T: Plain
  requires: count >= 0
  ensures: result.length == count
  ensures: forall (i: Int) where 0 <= i and i < count implies result[i] == value
{
  val items: List[T] = newListWithCapacity(count)
  var i = 0
  while i < count {
    items.add(value)
    i = i + 1
  }
  val made: buffer[T] = items.__lyric_buffer_from_list()
  made
}

/// A buffer holding a copy of the elements of `items`.
@stable(since = "1.0")
pub func fromSlice[T](items: in slice[T]): buffer[T]
  where T: Plain
  ensures: result.length == items.length
  ensures: forall (i: Int) where 0 <= i and i < items.length implies result[i] == items[i]
{
  val dst: List[T] = newListWithCapacity(items.length)
  var i = 0
  while i < items.length {
    dst.add(items[i])
    i = i + 1
  }
  val made: buffer[T] = dst.__lyric_buffer_from_list()
  made
}

/// The elements `lo ..< hi` of `b`, copied into a slice.  A later write
/// to `b` is not seen through the slice.
@stable(since = "1.0")
pub func view[T](b: in buffer[T], lo: in Int, hi: in Int): slice[T]
  where T: Plain
  requires: lo >= 0 and lo <= hi and hi <= b.length
  ensures: result.length == hi - lo
  ensures: forall (i: Int) where 0 <= i and i < hi - lo implies result[i] == b[lo + i]
{
  val dst: List[T] = newListWithCapacity(hi - lo)
  var i = lo
  while i < hi {
    dst.add(b[i])
    i = i + 1
  }
  dst.toArray()
}

/// All the elements of `b`, copied into a slice.
@stable(since = "1.0")
pub func toSlice[T](b: in buffer[T]): slice[T]
  where T: Plain
  ensures: result.length == b.length
  ensures: forall (i: Int) where 0 <= i and i < b.length implies result[i] == b[i]
{
  view(b, 0, b.length)
}

/// A buffer of `length` elements: those of `b`, then copies of `fill`.
@stable(since = "1.0")
pub func grow[T](b: in buffer[T], length: in Int, fill: in T): buffer[T]
  where T: Plain
  requires: length >= b.length
  ensures: result.length == length
  ensures: forall (i: Int) where 0 <= i and i < b.length implies result[i] == b[i]
  ensures: forall (i: Int) where b.length <= i and i < length implies result[i] == fill
{
  val dst: List[T] = newListWithCapacity(length)
  var i = 0
  while i < b.length {
    dst.add(b[i])
    i = i + 1
  }
  while i < length {
    dst.add(fill)
    i = i + 1
  }
  val made: buffer[T] = dst.__lyric_buffer_from_list()
  made
}

/// The first `length` elements of `b`.
@stable(since = "1.0")
pub func truncate[T](b: in buffer[T], length: in Int): buffer[T]
  where T: Plain
  requires: length >= 0 and length <= b.length
  ensures: result.length == length
  ensures: forall (i: Int) where 0 <= i and i < length implies result[i] == b[i]
{
  val dst: List[T] = newListWithCapacity(length)
  var i = 0
  while i < length {
    dst.add(b[i])
    i = i + 1
  }
  val made: buffer[T] = dst.__lyric_buffer_from_list()
  made
}
