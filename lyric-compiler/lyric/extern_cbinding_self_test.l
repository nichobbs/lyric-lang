//! extern_cbinding_self_test.l — C bindings on the managed targets (D158).
//!
//! An `extern func` with `@library("name")` calls the named C library's
//! symbol: through P/Invoke on .NET and through the Foreign Function &
//! Memory API on the JVM.  These tests call the C library itself, so they
//! need nothing installed beyond the runtime.  A `NativePtr[T]` crosses
//! the call as a pointer in both directions.
//!
//! Run on both targets:
//!   lyric test lyric-compiler/lyric/extern_cbinding_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/extern_cbinding_self_test.l
@test_module
package Lyric.ExternCBindingSelfTest

import Std.Core
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
