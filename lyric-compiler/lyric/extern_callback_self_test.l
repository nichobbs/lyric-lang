//! extern_callback_self_test.l — C callbacks through `@library` bindings on
//! every target (D229).
//!
//! A Lyric closure passed to a callback parameter of a C binding becomes a
//! C function pointer (an `UnmanagedCallersOnly` trampoline on .NET, an
//! upcall stub on the JVM, a synthesised trampoline on native), and the same
//! closure passed as the userdata pointer is what C hands back to it.  The C
//! side is `testdata/lyriccbtest.c`, which calls a callback many times, with
//! the userdata first or last, with Int, Long, Double, Float, Byte and pointer
//! arguments and results, keeps one for a later call, and calls one from a
//! second thread.
//!
//! The library must be built and on the loader path, so this runs through
//! the e2e script rather than a bare `lyric test`:
//!   bash scripts/ci/extern-callback-e2e.sh dotnet jvm native
@test_module
package Lyric.ExternCallbackSelfTest

import Std.Core
import Std.Ffi
import Std.Testing

@library("lyriccbtest")
extern func cbtSum(f: (Int, NativePtr[Byte]) -> Int, ud: NativePtr[Byte], n: Int): Int = "cbt_sum"

@library("lyriccbtest")
extern func cbtEachLong(f: (NativeUserdata, Long) -> Unit, ud: NativeUserdata, n: Long): Unit = "cbt_each_long"

@library("lyriccbtest")
extern func cbtApplyDouble(f: (Double, NativePtr[Byte]) -> Double, ud: NativePtr[Byte], x: Double): Double = "cbt_apply_double"

@library("lyriccbtest")
extern func cbtApplyFloat(f: (Float, NativePtr[Byte]) -> Float, ud: NativePtr[Byte], x: Float): Float = "cbt_apply_float"

@library("lyriccbtest")
extern func cbtApplyByte(f: (Byte, NativePtr[Byte]) -> Byte, ud: NativePtr[Byte], x: Byte): Byte = "cbt_apply_byte"

@library("lyriccbtest")
extern func cbtApplyPtr(f: (NativePtr[Byte], NativePtr[Byte]) -> NativePtr[Byte], ud: NativePtr[Byte], p: NativePtr[Byte]): NativePtr[Byte] = "cbt_apply_ptr"

@library("lyriccbtest")
extern func cbtEcho(ud: NativePtr[Byte]): NativePtr[Byte] = "cbt_echo"

@library("lyriccbtest")
extern func cbtStore(f: (Int, NativePtr[Byte]) -> Int, ud: NativePtr[Byte]): Unit = "cbt_store"

@library("lyriccbtest")
extern func cbtCallStored(x: Int): Int = "cbt_call_stored"

@library("lyriccbtest")
extern func cbtCallOnThread(f: (Int, NativePtr[Byte]) -> Int, ud: NativePtr[Byte], x: Int): Int = "cbt_call_on_thread"

// A `ref record` has identity on every target (D157, D222), so a
// closure that captures one updates the caller's counter.
ref record Counter {
  var calls: Int
  var total: Long
}

func sumOfSquares(n: in Int): Int {
  val sq = { i: Int -> i * i }
  cbtSum(sq, sq, n)
}

func countedSum(n: in Int): Int {
  val c = Counter(calls = 0, total = 0)
  val f = { i: Int -> c.calls = c.calls + 1; i }
  val sum = cbtSum(f, f, n)
  sum * 1000 + c.calls
}

func eachLongTotal(n: in Long): Long {
  val c = Counter(calls = 0, total = 0)
  val f = { v: Long -> c.total = c.total + v; c.calls = c.calls + 1 }
  cbtEachLong(f, f, n)
  c.total + c.calls.toLong()
}

func applyDouble(x: in Double): Double {
  val scale = 2.5
  val f = { v: Double -> v * scale }
  cbtApplyDouble(f, f, x)
}

func applyFloat(x: in Float): Float {
  val f = { v: Float -> v + 0.5f32 }
  cbtApplyFloat(f, f, x)
}

func applyByte(x: in Byte): Byte {
  val f = { b: Byte -> if b == 200u8 { 250u8 } else { 1u8 } }
  cbtApplyByte(f, f, x)
}

// A callback whose argument and result are C pointers: it reads the byte
// C passed it and hands back the address one past it.
@unsafe_ffi
func applyPointer(): Int {
  val buf = Ffi.allocate(4)
  nativeStoreByte(buf, 0, 42u8)
  nativeStoreByte(buf, 1, 43u8)
  val c = Counter(calls = 0, total = 0)
  val f = { p: NativePtr[Byte] -> c.total = nativeLoadByte(p, 0).toLong(); cbtEcho(p) }
  val q = cbtApplyPtr(f, f, buf)
  val next = nativeLoadByte(q, 1).toInt()
  Ffi.release(buf)
  c.total.toInt() * 100 + next
}

// A C library that keeps a callback calls it after the registering call has
// returned, so the closure is kept until the program releases it.
@unsafe_ffi
func storedCallback(): Int {
  val c = Counter(calls = 0, total = 0)
  val f = { x: Int -> c.calls = c.calls + 1; x * 10 }
  val ud = nativeKeepCallback(f)
  cbtStore(f, ud)
  val a = cbtCallStored(4)
  val b = cbtCallStored(5)
  nativeReleaseCallback(ud)
  a + b + c.calls
}

// The kept pointer is the userdata C sees, so it comes back unchanged.
@unsafe_ffi
func keptPointerRoundTrips(): Bool {
  val f = { x: Int -> x }
  val ud = nativeKeepCallback(f)
  val back = cbtEcho(ud)
  val same = back == ud
  nativeReleaseCallback(ud)
  same
}

// A kept callback passed through a `NativeUserdata` parameter.
@unsafe_ffi
func keptUserdataFirst(): Long {
  val c = Counter(calls = 0, total = 0)
  val f = { v: Long -> c.total = c.total + v + 1 }
  val ud = nativeKeepCallback(f)
  cbtEachLong(f, ud, 2)
  nativeReleaseCallback(ud)
  c.total
}

func onThread(x: in Int): Int {
  val f = { v: Int -> v * 2 }
  cbtCallOnThread(f, f, x)
}

test "a callback runs once per call the C function makes" {
  assertEqualInt(sumOfSquares(5), 30, "0 + 1 + 4 + 9 + 16")
  assertEqualInt(countedSum(10), 45010, "sum 45, ten calls")
}

test "a callback C calls many times stays valid throughout" {
  val one = { i: Int -> 1 }
  assertEqualInt(cbtSum(one, one, 200000), 200000, "200000 calls")
}

test "the userdata may come first, with a Unit result and Long arguments" {
  assertTrue(eachLongTotal(3) == 3000000003, "0 + 1e9 + 2e9, three calls")
}

test "Double, Float and Byte arguments and results cross the callback" {
  assertTrue(applyDouble(2.0) == 5.0, "2.0 * 2.5 through a captured Double")
  assertTrue(applyFloat(1.25f32) == 1.75f32, "1.25 + 0.5 as a C float")
  assertTrue(applyByte(200u8) == 250u8, "a Byte above 127 stays unsigned both ways")
  assertTrue(applyByte(3u8) == 1u8, "another Byte")
}

test "pointer arguments and results cross the callback" {
  assertEqualInt(applyPointer(), 4243, "read 42 at the pointer C passed, 43 one past the returned one")
}

test "a kept callback is called on a later C call and released" {
  assertEqualInt(storedCallback(), 92, "40 + 50, two calls")
}

test "a kept callback's pointer passes through C unchanged" {
  assertTrue(keptPointerRoundTrips(), "cbt_echo returns the kept pointer")
  assertTrue(keptUserdataFirst() == 1000000002, "(0 + 1) + (1e9 + 1) through a NativeUserdata slot")
}

test "a callback runs on a thread C starts" {
  assertEqualInt(onThread(21), 42, "21 * 2 on a second thread")
}
