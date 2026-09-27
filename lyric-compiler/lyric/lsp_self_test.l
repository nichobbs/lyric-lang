//! lsp_self_test.l — exercises `Lyric.Lsp`'s hover/completion visibility
//! labeling (#6309): `itemSummary`/`symDetail` used to collapse every
//! declared visibility to `"pub "` via `Some(_) -> "pub "`, silently
//! mislabeling `internal` symbols. They now delegate to the canonical
//! `Lyric.Fmt.visibilityPrefixStr` three-way helper.
//!
//! Run via `lyric test lyric-compiler/lyric/lsp_self_test.l`.
@test_module
package Lyric.Lsp.SelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.String as Str
import Std.Json
import Lyric.Lsp

func openDoc(state: in LspState, uri: in String, text: in String): Unit {
  val params = "{\"textDocument\":{\"uri\":" + encodeString(uri) + ",\"text\":" + encodeString(text) + "}}"
  val req = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":" + params + "}"
  val _msgs = lspHandle(state, req)
}

func hoverAt(state: in LspState, uri: in String, line: in Int, character: in Int): String {
  val params = "{\"textDocument\":{\"uri\":" + encodeString(uri) + "},\"position\":{\"line\":" + ("" + line) +
    ",\"character\":" +
    ("" + character) +
    "}}"
  val req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"textDocument/hover\",\"params\":" + params + "}"
  val msgs = lspHandle(state, req)
  if msgs.count == 0 {
    ""
  } else {
    msgs[0]
  }
}

test "hover on an internal record reports internal, not pub" {
  val state = lspInit()
  val uri = "file:///lsp_self_test_internal.l"
  val src = "package P\n\ninternal record Foo {\n  x: Int\n}\n"
  openDoc(state, uri, src)
  // "Foo" starts at column 16 (0-based) on line index 2: "internal record Foo {"
  val hover = hoverAt(state, uri, 2, 17)
  assertTrue(Str.contains(hover, "internal record Foo"), "hover: internal record labeled internal")
  assertFalse(Str.contains(hover, "pub record Foo"), "hover: internal record must not be mislabeled pub")
}

test "hover on a pub record still reports pub" {
  val state = lspInit()
  val uri = "file:///lsp_self_test_pub.l"
  val src = "package P\n\npub record Bar {\n  x: Int\n}\n"
  openDoc(state, uri, src)
  // "Bar" starts at column 11 (0-based) on line index 2: "pub record Bar {"
  val hover = hoverAt(state, uri, 2, 12)
  assertTrue(Str.contains(hover, "pub record Bar"), "hover: pub record still labeled pub")
}

test "hover on a private (unmarked) record reports no visibility prefix" {
  val state = lspInit()
  val uri = "file:///lsp_self_test_private.l"
  val src = "package P\n\nrecord Baz {\n  x: Int\n}\n"
  openDoc(state, uri, src)
  // "Baz" starts at column 7 (0-based) on line index 2: "record Baz {"
  val hover = hoverAt(state, uri, 2, 8)
  assertTrue(Str.contains(hover, "record Baz"), "hover: private record body present")
  assertFalse(Str.contains(hover, "pub record Baz"), "hover: private record must not be labeled pub")
  assertFalse(Str.contains(hover, "internal record Baz"), "hover: private record must not be labeled internal")
}

// ── Framing: UTF-16 code units from the console (#7252) ─────────────────────
// `readLspFrame` receives raw UTF-16 code units.  A surrogate pair must decode
// to one code point; an unpaired or reversed surrogate becomes U+FFFD rather
// than an unpaired surrogate (a `Char` is a BMP scalar value).
func decodeCodeUnits(units: in slice[Int]): String {
  var acc = ""
  var pendingHigh = -1
  var i = 0
  while i < units.length {
    acc = lspAppendCodeUnit(acc, pendingHigh, units[i])
    i = i + 1
  }
  lspFlushCodeUnits(acc, pendingHigh)
}

test "LSP framing decodes BMP code units" {
  assertEqual(decodeCodeUnits([97, 233, 20013]), "aé中", "BMP code units decode to their characters")
}

test "LSP framing combines a surrogate pair into one code point" {
  assertEqual(decodeCodeUnits([97, 55357, 56832, 98]), "a😀b", "surrogate pair decodes to U+1F600")
}

test "LSP framing turns a lone high surrogate into U+FFFD" {
  assertEqual(decodeCodeUnits([97, 55357, 98]), "a�b", "high surrogate before a BMP code unit")
  assertEqual(decodeCodeUnits([97, 55357]), "a�", "high surrogate at end of input")
}

test "LSP framing turns a lone low surrogate into U+FFFD" {
  assertEqual(decodeCodeUnits([97, 56832, 98]), "a�b", "unpaired low surrogate")
}

test "LSP framing turns a reversed surrogate pair into two U+FFFD" {
  assertEqual(decodeCodeUnits([97, 56832, 55357, 98]), "a��b", "low surrogate before high surrogate")
}
