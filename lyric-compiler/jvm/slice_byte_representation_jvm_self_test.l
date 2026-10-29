//! slice_byte_representation_jvm_self_test.l — runtime regression suite for
//! the two `slice[Byte]` shapes added to #7806 while writing `Std.Zip` and
//! `Std.PluginCatalogue`.
//!
//! On the JVM a `slice[Byte]` value is either a `byte[]` or a boxed
//! `Object[]`, depending on where it came from: a payload bound by a `match`
//! arm (`case Ok(b) -> b`) is unboxed to `byte[]`, while a parameter, a
//! `.slice(...)` of one, or a `List[Byte].toArray()` stays `Object[]`.  Two
//! places mixed the representations without converting:
//!   - the join of a value-producing `if` or `match`, whose later arms were
//!     coerced without the `byte[]` -> `Object[]` boxing, so the result local
//!     failed verification ("'[B' is not assignable to '[Ljava/lang/Object;'");
//!   - `xs.concat(ys)`, which converted `ys` to an array but not to `xs`'s
//!     representation, so `System.arraycopy` between them failed verification
//!     or threw `ArrayStoreException`.
//!
//! Run in CI via native `lyric test` on both targets; the JVM run is the
//! load-bearing one.
@test_module
package Lyric.SliceByteRepresentationSelfTest

import Std.Core
import Std.Collections
import Std.Testing

func built(n: in Int): Result[slice[Byte], String] {
  val acc: List[Byte] = newList()
  var i = 0
  while i < n {
    acc.add((i + 10).toByte())
    i = i + 1
  }
  Ok(value = acc.toArray())
}

func bytesOf(vals: in List[Int]): slice[Byte] {
  val acc: List[Byte] = newList()
  for v in vals {
    acc.add(v.toByte())
  }
  acc.toArray()
}

// The then-arm is a parameter's `.slice`, the else-arm a match-bound payload.
func pickIf(data: in slice[Byte], method: in Int): Result[slice[Byte], String] {
  val bytes = if method == 0 {
    data.slice(1, 3)
  } else {
    match built(4) {
      case Ok(b) -> b
      case Err(e) -> return Err(error = e)
    }
  }
  Ok(value = bytes)
}

// The same two representations, the other way round.
func pickIfReversed(data: in slice[Byte], method: in Int): Result[slice[Byte], String] {
  val bytes = if method == 0 {
    match built(2) {
      case Ok(b) -> b
      case Err(e) -> return Err(error = e)
    }
  } else {
    data.slice(0, 1)
  }
  Ok(value = bytes)
}

func pickMatch(data: in slice[Byte], method: in Int): Result[slice[Byte], String] {
  val bytes = match method {
    case 0 -> data.slice(0, 2)
    case _ -> match built(3) { case Ok(b) -> b; case Err(e) -> return Err(error = e) }
  }
  Ok(value = bytes)
}

func sum(bytes: in slice[Byte]): Int {
  var total = 0
  for b in bytes {
    total = total + b.toInt()
  }
  total
}

func unwrapLen(r: in Result[slice[Byte], String]): Int {
  match r {
    case Ok(b) -> b.length
    case Err(_) -> -1
  }
}

func unwrapSum(r: in Result[slice[Byte], String]): Int {
  match r {
    case Ok(b) -> sum(b)
    case Err(_) -> -1
  }
}

test "a value-producing if joins a parameter slice with a match-bound slice" {
  val data = bytesOf([1, 2, 3])
  assertEqualInt(unwrapLen(pickIf(data, 0)), 2, "then-arm length")
  assertEqualInt(unwrapSum(pickIf(data, 0)), 5, "then-arm contents")
  assertEqualInt(unwrapLen(pickIf(data, 1)), 4, "else-arm length")
  assertEqualInt(unwrapSum(pickIf(data, 1)), 46, "else-arm contents")
  assertEqualInt(unwrapSum(pickIfReversed(data, 0)), 21, "match-bound then-arm")
  assertEqualInt(unwrapSum(pickIfReversed(data, 1)), 1, "parameter else-arm")
}

test "a value-producing match joins a parameter slice with a match-bound slice" {
  val data = bytesOf([4, 5, 6])
  assertEqualInt(unwrapSum(pickMatch(data, 0)), 9, "first arm")
  assertEqualInt(unwrapSum(pickMatch(data, 1)), 33, "second arm")
}

test "concat of a match-bound slice with a literal and with a parameter-shaped slice" {
  val good = match built(3) { case Ok(b) -> b; case Err(e) -> panic(e) }
  val longer = good.concat([0u8])
  val other = bytesOf([7, 8])
  assertEqualInt(longer.length, 4, "concat with a literal")
  assertEqualInt(sum(longer), 33, "concat contents")
  val both = good.concat(other)
  assertEqualInt(both.length, 5, "match-bound receiver, list-built argument")
  assertEqualInt(sum(both), 48, "contents in order")
  val reversed = other.concat(good)
  assertEqualInt(reversed.length, 5, "list-built receiver, match-bound argument")
  assertEqualInt(reversed[0].toInt(), 7, "receiver first")
  assertEqualInt(reversed[2].toInt(), 10, "then the argument")
}
