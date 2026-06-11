//! kernel_self_test.l — unit tests for ByteWriter normalisation corner cases.
//!
//! Exercises the unsigned-normalisation arithmetic in `bufU1`, `bufU2`, and
//! `bufU4` for boundary inputs (negative values, overflow, max values).  The
//! tests are written as a plain `func main` program rather than `@test_module`
//! to avoid the `Msil.Kernel.ByteWriter` vs `Std.Stream.ByteWriter` name
//! collision that blocks `@test_module` compilation (#3085).
//!
//! Checks:
//!   bufU1_neg1      — bufU1(-1) appends byte 255
//!   bufU1_256       — bufU1(256) appends byte 0 (wraps)
//!   bufU1_255       — bufU1(255) appends byte 255
//!   bufU2_neg1      — bufU2(-1) appends [255, 255]
//!   bufU2_0x8000    — bufU2(0x8000) appends [0, 128]
//!   bufU4_neg1      — bufU4(-1) appends [255, 255, 255, 255]
//!   bufU4_0x80000000 — bufU4(0x80000000) appends [0, 0, 0, 128]
//!
//! Run via the F# bootstrap emitter (avoids #3085):
//!
//!   ./bin/lyric run lyric-compiler/msil/kernel_self_test.l
//!
//! Migration to native `lyric test` is blocked by #3085.
package Msil.KernelSelfTest

import Msil.Kernel
import Std.Core
import Std.Collections

func check(label: in String, ok: in Bool): Unit {
  if ok {
    println(label + "=true")
  } else {
    println(label + "=FAIL")
  }
}

func byteAt(w: in ByteWriter, i: in Int): Int {
  w.data[i]
}

pub func main(): Int {
  // bufU1 normalisation tests
  val w1 = bufNew()
  bufU1(w1, -1)
  check("bufU1_neg1", byteAt(w1, 0) == 255)

  val w2 = bufNew()
  bufU1(w2, 256)
  check("bufU1_256", byteAt(w2, 0) == 0)

  val w3 = bufNew()
  bufU1(w3, 255)
  check("bufU1_255", byteAt(w3, 0) == 255)

  // bufU2 little-endian tests
  val w4 = bufNew()
  bufU2(w4, -1)
  check("bufU2_neg1", byteAt(w4, 0) == 255 and byteAt(w4, 1) == 255)

  val w5 = bufNew()
  bufU2(w5, 0x8000)
  check("bufU2_0x8000", byteAt(w5, 0) == 0 and byteAt(w5, 1) == 128)

  // bufU4 little-endian tests
  val w6 = bufNew()
  bufU4(w6, -1)
  check("bufU4_neg1", byteAt(w6, 0) == 255 and byteAt(w6, 1) == 255 and byteAt(w6, 2) == 255 and byteAt(w6, 3) == 255)

  val w7 = bufNew()
  bufU4(w7, 0x80000000)
  check("bufU4_0x80000000", byteAt(w7, 0) == 0 and byteAt(w7, 1) == 0 and byteAt(w7, 2) == 0 and byteAt(w7, 3) == 128)

  0
}
