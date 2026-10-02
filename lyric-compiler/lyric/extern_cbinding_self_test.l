//! extern_cbinding_self_test.l — C bindings on every target (D158).
//!
//! An `extern func` with `@library("name")` calls the named C library's
//! symbol: through P/Invoke on .NET, through the Foreign Function &
//! Memory API on the JVM, and through a direct call linked with
//! `-l<name>` on native.  These tests call the C library itself, so they
//! need nothing installed beyond the runtime.  A `NativePtr[T]` crosses
//! the call as a pointer in both directions, and `Std.Ffi` moves bytes
//! and strings through C memory (D161).
//!
//! Run on every target:
//!   lyric test lyric-compiler/lyric/extern_cbinding_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/extern_cbinding_self_test.l
//!   lyric test --target native lyric-compiler/lyric/extern_cbinding_self_test.l
@test_module
package Lyric.ExternCBindingSelfTest

import Std.Core
import Std.Ffi
import Std.Testing

@library("c")
extern func cAbs(x: Int): Int = "abs"

@library("c")
extern func cLabs(x: Long): Long = "labs"

@library("c")
extern func cToUpper(c: Int): Int = "toupper"

// glibc exports ldexp from the C library itself, as macOS's libSystem
// does, so this needs no separate maths library.
@library("c")
extern func cLdexp(x: Double, e: Int): Double = "ldexp"

// A C `float` is a `Float` on every target (D155, #7966).
@library("c")
extern func cLdexpf(x: Float, e: Int): Float = "ldexpf"

// A file name is passed to the loader as written: glibc's unversioned
// libm.so is a linker script, not a loadable library (CI runs on glibc).
@library("libm.so.6")
extern func mFloor(x: Double): Double = "floor"

@library("c")
extern func cMalloc(size: Long): NativePtr[Byte] = "malloc"

@library("c")
extern func cMemset(p: NativePtr[Byte], value: Int, size: Long): NativePtr[Byte] = "memset"

@library("c")
extern func cFree(p: NativePtr[Byte]): Unit = "free"

@library("c")
extern func cStrlen(p: NativePtr[Byte]): Long = "strlen"

func absOf(x: in Int): Int {
  cAbs(x)
}

test "an Int C function returns its result" {
  assertEqualInt(cAbs(-42), 42, "abs(-42)")
  assertEqualInt(absOf(7), 7, "called from another function")
  assertEqualInt(cToUpper(97), 65, "toupper('a')")
}

test "a Long C function passes and returns 64 bits" {
  assertTrue(cLabs(-5000000000) == 5000000000, "labs(-5000000000)")
}

test "a Double argument and result cross the call" {
  assertTrue(cLdexp(1.5, 3) == 12.0, "ldexp(1.5, 3)")
}

test "a Float argument and result cross the call as a C float" {
  assertTrue(cLdexpf(1.5f32, 3) == 12.0f32, "ldexpf(1.5, 3)")
  assertTrue(cLdexpf(0.1, 1) == 0.2f32, "ldexpf(0.1, 1) doubles the Float nearest 0.1")
}

test "a library named by its file name loads as written" {
  assertTrue(mFloor(2.75) == 2.0, "floor(2.75) from libm.so.6")
}

test "repeated calls reuse one binding" {
  var total = 0
  var i = 0
  while i < 100 {
    total = total + cAbs(0 - i)
    i = i + 1
  }
  assertEqualInt(total, 4950, "the sum of abs(-i) for i below 100")
}

// Pointer values stay inside `@unsafe_ffi` code (N0100).
@unsafe_ffi
func pointerRoundTrip(size: in Long): Int {
  val p: NativePtr[Byte] = cMalloc(size)
  val q: NativePtr[Byte] = cMemset(p, 0, size)
  cFree(q)
  cFree(nativeNullPtr())
  cAbs(-1)
}

test "a pointer crosses the call in both directions" {
  assertEqualInt(pointerRoundTrip(64), 1, "malloc, memset and free round-tripped the pointer")
}

@unsafe_ffi
func byteRoundTrip(): Int {
  val p = allocate(4)
  nativeStoreByte(p, 0, 7u8)
  nativeStoreByte(p, 1, 255u8)
  nativeStoreByte(p, 3i64, 128u8)
  val sum = nativeLoadByte(p, 0).toInt() + nativeLoadByte(p, 1).toInt() + nativeLoadByte(p, 3).toInt()
  release(p)
  sum
}

test "bytes stored in C memory load back unchanged" {
  assertEqualInt(byteRoundTrip(), 390, "7 + 255 + 128 read back from a C buffer")
}

@unsafe_ffi
func cStringLength(s: in String): Long {
  val p = toCString(s)
  val n = cStrlen(p)
  release(p)
  n
}

@unsafe_ffi
func cStringRoundTrip(s: in String): Option[String] {
  val p = toCString(s)
  val back = tryFromCString(p)
  release(p)
  back
}

@unsafe_ffi
func nullCString(): Option[String] {
  tryFromCString(nativeNullPtr())
}

@unsafe_ffi
func invalidUtf8CString(): Option[String] {
  val p = allocate(2)
  nativeStoreByte(p, 0, 255u8)
  nativeStoreByte(p, 1, 0u8)
  val r = tryFromCString(p)
  release(p)
  r
}

test "a C string is NUL-terminated UTF-8" {
  assertTrue(cStringLength("hello") == 5, "strlen of an ASCII string")
  assertTrue(cStringLength("") == 0, "strlen of the empty string")
  assertTrue(cStringLength("hé") == 3, "the accented letter takes two UTF-8 bytes")
}

test "a string survives the round trip through C memory" {
  match cStringRoundTrip("café 中") {
    case Some(s) -> assertTrue(s == "café 中", "the round-tripped string")
    case None -> assertTrue(false, "the round trip lost the string")
  }
  match cStringRoundTrip("") {
    case Some(s) -> assertTrue(s == "", "the empty string round-trips")
    case None -> assertTrue(false, "the empty round trip lost the string")
  }
}

test "a null pointer or invalid UTF-8 reads as None" {
  assertTrue(nullCString().isNone(), "the null pointer")
  assertTrue(invalidUtf8CString().isNone(), "a lone 0xFF byte")
}
