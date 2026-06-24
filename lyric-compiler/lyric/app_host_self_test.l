//! app_host_self_test.l — exercises the pure placeholder-binding logic of
//! `Lyric.AppHost` (`bindAppHost` / `findBytes`).  Hermetic: builds a synthetic
//! apphost template in memory (prefix + 64-byte placeholder + NUL-padded
//! reserved region + suffix), binds a managed DLL name into it, and asserts the
//! splice matches `Microsoft.NET.HostModel.HostWriter` semantics — path bytes,
//! NUL terminator, zero-filled remainder, preserved surrounding bytes, and the
//! length invariant.  Run in CI via native `lyric test`; imports only `Std.*`
//! and `Lyric.AppHost`.
@test_module
package Lyric.AppHost.SelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.Encoding as Enc
import Lyric.AppHost as AppHost

// ─────────────────────────────────────────────────────────────────────────────
// §1. Helpers
// ─────────────────────────────────────────────────────────────────────────────

// Local copies of the binder's constants.  Reading another package's
// module-level `pub val` directly from a `@test_module` is not reliably
// initialized under `lyric test` (cross-package static-init gap, #3086), so the
// test keeps its own copies.  These must match `Lyric.AppHost`'s `PLACEHOLDER`
// and `RESERVED_BYTES`; the splice assertions below cross-check that they do —
// a mismatch would make `bindAppHost` report a missing placeholder and fail.
val PLACEHOLDER_HEX: String =
  "c3ab8ff13720e8ad9047dd39466b3c8974e592c2fa383d4a3960714caef0c4f2"
val RESERVED: Int = 1024

// Append every byte of `s` to `acc`.
func addSlice(acc: in List[Byte], s: in slice[Byte]): Unit {
  var i = 0
  while i < s.length {
    acc.add(s[i])
    i += 1
  }
}

// Append the UTF-8 bytes of `str` to `acc`.
func addStr(acc: in List[Byte], str: in String): Unit {
  addSlice(acc, Enc.encodeUtf8(str))
}

// Build a synthetic apphost template: `prefix` bytes, then the placeholder and
// its NUL-padded RESERVED_BYTES region, then `suffix` bytes.  Returns the
// template and the offset of the reserved region.
func makeTemplate(prefix: in String, suffix: in String): List[Byte] {
  val acc: List[Byte] = newList()
  addStr(acc, prefix)
  addStr(acc, PLACEHOLDER_HEX)
  // Pad out to the full reserved region (placeholder is 64 bytes).
  var z = Enc.encodeUtf8(PLACEHOLDER_HEX).length
  while z < RESERVED {
    acc.add(0)
    z += 1
  }
  addStr(acc, suffix)
  acc
}

func byteAt(buf: in List[Byte], i: in Int): Int {
  buf[i].toInt()
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Tests
// ─────────────────────────────────────────────────────────────────────────────

// A well-formed bind splices the path + NUL, zero-fills the rest of the
// reserved region, preserves surrounding bytes, and keeps the total length.
test "bind splices path and preserves length" {
  val prefix = "ELFSTUB"
  val suffix = "TRAILERBYTES"
  val tpl = makeTemplate(prefix, suffix)
  val tplLen = tpl.count
  val idx = Enc.encodeUtf8(prefix).length

  match AppHost.bindAppHost(tpl, "app.dll") {
    case Err(m) -> panic("bindAppHost unexpectedly failed: " + m)
    case Ok(outBytes) -> {
      assertEqualInt(outBytes.count, tplLen, "bind: length preserved")

      // Prefix bytes unchanged.
      var i = 0
      while i < idx {
        assertEqualInt(byteAt(outBytes, i), byteAt(tpl, i), "bind: prefix byte preserved")
        i += 1
      }

      // The path bytes are spliced at the reserved-region offset.
      val pathBytes = Enc.encodeUtf8("app.dll")
      var p = 0
      while p < pathBytes.length {
        assertEqualInt(byteAt(outBytes, idx + p), pathBytes[p].toInt(), "bind: path byte spliced")
        p += 1
      }
      // The NUL terminator and every byte after the path through the end of
      // the reserved region must be zero — checked across the whole region,
      // not just the boundaries, so a partial zero-fill bug cannot slip through.
      var zr = pathBytes.length
      while zr < RESERVED {
        assertEqualInt(byteAt(outBytes, idx + zr), 0, "bind: reserved region byte zero")
        zr += 1
      }

      // Suffix bytes after the reserved region are unchanged.
      val suffixBytes = Enc.encodeUtf8(suffix)
      var s = 0
      while s < suffixBytes.length {
        assertEqualInt(
          byteAt(outBytes, idx + RESERVED + s),
          suffixBytes[s].toInt(),
          "bind: suffix byte preserved"
        )
        s += 1
      }
    }
  }
}

// findBytes locates the placeholder and reports -1 when it is absent.
test "findBytes locates and reports absence" {
  val tpl = makeTemplate("AB", "CD")
  val needle = Enc.encodeUtf8(PLACEHOLDER_HEX)
  assertEqualInt(AppHost.findBytes(tpl, needle), 2, "findBytes: placeholder at offset 2")

  val noHit: List[Byte] = newList()
  addStr(noHit, "no placeholder here at all")
  assertEqualInt(AppHost.findBytes(noHit, needle), -1, "findBytes: absent reports -1")
}

// Binding a template with no placeholder is an error, not a silent pass.
test "bind rejects missing placeholder" {
  val noPlaceholder: List[Byte] = newList()
  addStr(noPlaceholder, "this is not a real apphost binary")
  match AppHost.bindAppHost(noPlaceholder, "app.dll") {
    case Ok(_) -> panic("bind should reject a template without the placeholder")
    case Err(_) -> assertTrue(true, "bind: missing placeholder rejected")
  }
}

// A duplicated placeholder is ambiguous and must be rejected.
test "bind rejects ambiguous placeholder" {
  val acc: List[Byte] = newList()
  addStr(acc, PLACEHOLDER_HEX)
  // pad first region
  var z = Enc.encodeUtf8(PLACEHOLDER_HEX).length
  while z < RESERVED {
    acc.add(0)
    z += 1
  }
  // a second placeholder occurrence
  addStr(acc, PLACEHOLDER_HEX)
  var z2 = Enc.encodeUtf8(PLACEHOLDER_HEX).length
  while z2 < RESERVED {
    acc.add(0)
    z2 += 1
  }
  match AppHost.bindAppHost(acc, "app.dll") {
    case Ok(_) -> panic("bind should reject a template with two placeholders")
    case Err(_) -> assertTrue(true, "bind: ambiguous placeholder rejected")
  }
}

// A path that does not fit the reserved region is rejected.
test "bind rejects oversized path" {
  val tpl = makeTemplate("", "")
  // Build a path of RESERVED_BYTES characters (path + NUL would exceed it).
  var big = ""
  var i = 0
  while i < RESERVED {
    big = big + "x"
    i += 1
  }
  match AppHost.bindAppHost(tpl, big) {
    case Ok(_) -> panic("bind should reject a path that overflows the reserved region")
    case Err(_) -> assertTrue(true, "bind: oversized path rejected")
  }
}

// launcherName appends `.exe` only on Windows RIDs.
test "launcherName is RID-aware" {
  assertEqual(AppHost.launcherName("hello", "linux-x64"), "hello", "launcherName: bare on linux")
  assertEqual(AppHost.launcherName("hello", "osx-arm64"), "hello", "launcherName: bare on macOS")
  assertEqual(AppHost.launcherName("hello", "win-x64"), "hello.exe", "launcherName: .exe on windows")
}
