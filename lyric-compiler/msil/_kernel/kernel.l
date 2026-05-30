// Msil.Kernel — pure-Lyric growable byte buffer for PE emission (#1492).
//
// Replaces the F# `Lyric.Jvm.Hosts.JvmByteHost` boundary so `--target dotnet`
// builds no longer drag `Lyric.Jvm.Hosts.dll` onto the runtime closure.  The
// buffer is a plain `List[Byte]`; the only host boundary is the audited
// `System.BitConverter` extern (System.Runtime) used for 64-bit / IEEE-754
// little-endian byte extraction, impractical in Lyric without bitwise
// primitives (#875).
//
// Endianness: `BitConverter.GetBytes` is host-endian; the compiler runs on
// little-endian targets (x64 / arm64), matching the explicit little-endian
// layout the former F# host produced and the LE assumption already pervasive
// in PE/MSIL emission.

package Msil.Kernel

import Std.Core
import Std.Collections

// Growable byte buffer.  The inner `List[Byte]` is the mutable store; the
// `buf*` helpers append into it in place (the record wrapper gives the buffer
// a distinct, opaque type at call sites).
pub record ByteWriter {
  data: List[Byte]
}

pub func bufNew(): ByteWriter {
  ByteWriter(data = newList())
}

// Arithmetic right-shift by 8 bits, expressed as floor division (Lyric `/`
// truncates toward zero, which is wrong for negative values).  Used to peel
// successive little-endian bytes off a two's-complement `Int`: e.g. for
// `v = -1` (0xFFFFFFFF) every byte must be 0xFF, but `-1 / 256 == 0` would
// stop after one byte.  `Int` is 32-bit, so this never negates `v` (which
// would overflow at `Int.MinValue`); it adjusts the truncated quotient
// instead.
func shr8(v: in Int): Int {
  val q = v / 256
  val r = v % 256
  if r < 0 { q - 1 } else { q }
}

// Append the low 8 bits of `v`, matching the former host's `byte v`
// (= `v & 0xFF`).  `v % 256` follows Lyric's sign-of-dividend remainder rule
// (`-1 % 256 == -1`), so normalise to `[0, 255]` for the correct unsigned byte.
pub func bufU1(w: in ByteWriter, v: in Int): Unit {
  w.data.add(((v % 256) + 256) % 256)
}

// 16-bit little-endian.  Peels the two low bytes via `bufU1` (which masks) and
// the arithmetic `shr8` shift, so a value whose bit 15 is set (passed as a
// negative `Int`) writes the same bytes the host's `(uint32 v) >>> 8 & 0xFF`
// would.  A naive `v / 256` truncates toward zero and corrupts the high byte
// for negatives (e.g. backward branch offsets), producing invalid IL.
pub func bufU2(w: in ByteWriter, v: in Int): Unit {
  bufU1(w, v)
  bufU1(w, shr8(v))
}

// 32-bit little-endian.  Same arithmetic-shift peeling as `bufU2`, four bytes.
pub func bufU4(w: in ByteWriter, v: in Int): Unit {
  var x = v
  bufU1(w, x)
  x = shr8(x)
  bufU1(w, x)
  x = shr8(x)
  bufU1(w, x)
  x = shr8(x)
  bufU1(w, x)
}

// Append a byte slice.  Slice elements are already in `[0, 255]`.
pub func bufBytes(w: in ByteWriter, bs: in slice[Byte]): Unit {
  var i = 0
  while i < bs.length {
    w.data.add(bs[i])
    i = i + 1
  }
}

// Append a byte list.
pub func bufByteList(w: in ByteWriter, bs: in List[Byte]): Unit {
  var i = 0
  while i < bs.count {
    w.data.add(bs[i])
    i = i + 1
  }
}

// Append every byte of another buffer.
pub func bufAppend(w: in ByteWriter, src: in ByteWriter): Unit {
  bufByteList(w, src.data)
}

// Current length in bytes.
pub func bufLen(w: in ByteWriter): Int {
  w.data.count
}

// The accumulated bytes, as a fresh copy.  The former host's `ToList()`
// returned a new list (not the live buffer); callers rely on that — some
// snapshot a sub-buffer with `bufToList` and keep appending to the writer
// afterwards, so returning the live `w.data` would alias and corrupt output.
pub func bufToList(w: in ByteWriter): List[Byte] {
  val acc: List[Byte] = newList()
  var i = 0
  while i < w.data.count {
    acc.add(w.data[i])
    i = i + 1
  }
  acc
}

// ── 64-bit and floating-point little-endian via System.BitConverter ──────────

@externTarget("System.BitConverter.GetBytes")
func i8GetBytes(v: in Long): slice[Byte] = ()

@externTarget("System.BitConverter.GetBytes")
func f8GetBytes(v: in Double): slice[Byte] = ()

// 64-bit little-endian.
pub func bufI8Le(w: in ByteWriter, v: in Long): Unit {
  bufBytes(w, i8GetBytes(v))
}

// IEEE-754 binary64 little-endian.
pub func bufF8Le(w: in ByteWriter, v: in Double): Unit {
  bufBytes(w, f8GetBytes(v))
}

// IEEE-754 binary32 (`ldc.r4`).  Unreachable: Lyric has no `Single` type
// (`Float` maps to `Double`), so the emitter never constructs the `OF4`
// opcode (verified: zero `OF4(` construction sites outside `opcodes.l`) —
// float constants emit as `ldc.r8` through `bufF8Le`.  Encoding a genuine
// 32-bit single here would need a `Single` type or value-type FFI support
// (neither exists); panic loudly rather than emit wrong bytes if a future
// float32 path ever reaches this.
pub func bufF4Le(w: in ByteWriter, v: in Double): Unit {
  panic("Msil.Kernel.bufF4Le: float32 (ldc.r4) is unsupported — Lyric has no "
    + "Single type; float constants must emit as ldc.r8 via bufF8Le.")
}

pub func bufZero(w: in ByteWriter, n: in Int): Unit {
  var i = 0
  while i < n {
    bufU1(w, 0)
    i = i + 1
  }
}

// Pad w to the next multiple of `align` bytes.
pub func bufPadTo(w: in ByteWriter, align: in Int): Unit {
  val r = bufLen(w) % align
  if r != 0 {
    bufZero(w, align - r)
  }
}
