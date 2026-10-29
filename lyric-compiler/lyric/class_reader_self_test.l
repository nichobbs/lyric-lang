//! class_reader_self_test.l — adversarial-input tests for `Jvm.ClassReader`,
//! the JVM auto-FFI class-file parser, driven with hand-built class files:
//! modified-UTF-8 constant-pool strings, including surrogate halves encoded as
//! separate 3-byte sequences (#7252).  The archives those class files come out
//! of are read by `Std.Zip`, whose hostile-input tests are
//! `lyric-stdlib/tests/zip_tests.l`; the happy path (real JDK jmod decoding)
//! is `auto_ffi_jvm_self_test.l`.
//!
//! Placed in `lyric-compiler/lyric/` (not `lyric-compiler/jvm/`) and run on the
//! default `dotnet` target so `lyric test` resolves the `Jvm.ClassReader`
//! import from the pre-compiled stage-1 bundle DLLs in-process.  No
//! `LYRIC_LOAD_COMPILER=1` recompile is needed.
//!
//! Run via:
//!   lyric test lyric-compiler/lyric/class_reader_self_test.l
@test_module
package Lyric.ClassReaderSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Jvm.ClassReader

// ── Jvm.ClassReader modified UTF-8 (#7252) ───────────────────────────────────
// A class file's CONSTANT_Utf8 entries are "modified UTF-8": a supplementary-
// plane character is its UTF-16 surrogate pair, each half its own 3-byte
// sequence.  A pair must decode to one code point; an unpaired or reversed
// surrogate becomes U+FFFD rather than an unpaired UTF-16 surrogate.
// The binary name of a minimal class file whose this_class name is the
// modified-UTF-8 bytes `nameBytes`, or "<none>" if it does not parse.
func classNameFromUtf8(nameBytes: in List[Int]): String {
  val b: List[Byte] = newList()
  b.add(202u8)
  b.add(254u8)
  b.add(186u8)
  b.add(190u8)   // magic 0xCAFEBABE
  b.add(0u8)
  b.add(0u8)
  b.add(0u8)
  b.add(65u8)   // minor 0, major 65
  b.add(0u8)
  b.add(3u8)   // constant_pool_count: #1 Utf8, #2 Class
  b.add(1u8)   // #1 CONSTANT_Utf8
  b.add((nameBytes.count / 256).toByte())
  b.add((nameBytes.count % 256).toByte())
  var i = 0
  while i < nameBytes.count {
    b.add(nameBytes[i].toByte())
    i = i + 1
  }
  b.add(7u8)   // #2 CONSTANT_Class -> #1
  b.add(0u8)
  b.add(1u8)
  b.add(0u8)
  b.add(33u8)   // access_flags: ACC_PUBLIC | ACC_SUPER
  b.add(0u8)
  b.add(2u8)   // this_class #2
  b.add(0u8)
  b.add(0u8)   // super_class none
  var z = 0
  while z < 8 {
    b.add(0u8)   // interfaces, fields, methods, attributes counts
    z = z + 1
  }
  match parseClass(b.toArray()) {
    case Some(info) -> info.binaryName
    case None -> "<none>"
  }
}

func bytesOf(vals: in slice[Int]): List[Int] {
  val l: List[Int] = newList()
  var i = 0
  while i < vals.length {
    l.add(vals[i])
    i = i + 1
  }
  l
}

test "ClassReader decodes 1-, 2- and 3-byte modified UTF-8" {
  // "a", U+00E9 (C3 A9), U+4E2D (E4 B8 AD)
  assertEqual(classNameFromUtf8(bytesOf([97, 195, 169, 228, 184, 173])), "aé中", "BMP sequences decode")
}

test "ClassReader combines a CESU-8 surrogate pair into one code point" {
  // U+1F600 = high D83D (ED A0 BD) + low DE00 (ED B8 80)
  assertEqual(
    classNameFromUtf8(bytesOf([97, 237, 160, 189, 237, 184, 128, 98])),
    "a😀b",
    "surrogate pair decodes to U+1F600"
  )
}

test "ClassReader turns a lone high surrogate into U+FFFD" {
  assertEqual(classNameFromUtf8(bytesOf([97, 237, 160, 189, 98])), "a�b", "unpaired high surrogate")
  assertEqual(
    classNameFromUtf8(bytesOf([237, 160, 189, 228, 184, 173])),
    "�中",
    "high surrogate before a non-surrogate 3-byte sequence"
  )
}

test "ClassReader turns a lone low surrogate into U+FFFD" {
  assertEqual(classNameFromUtf8(bytesOf([97, 237, 184, 128, 98])), "a�b", "unpaired low surrogate")
}

test "ClassReader turns a reversed surrogate pair into two U+FFFD" {
  assertEqual(
    classNameFromUtf8(bytesOf([97, 237, 184, 128, 237, 160, 189, 98])),
    "a��b",
    "low surrogate before high surrogate"
  )
}
