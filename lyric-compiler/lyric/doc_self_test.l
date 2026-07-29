//! doc_self_test.l — exercises the self-hosted `Lyric.Doc` generator's field
//! visibility labeling (#6309): the collapsing two-way match
//! `Some(_) -> "pub "` in `fieldStr` used to silently mislabel every
//! `internal` record field as `pub` in generated Markdown docs. It now
//! delegates to the canonical `Lyric.Fmt.visibilityPrefixStr` three-way
//! helper.
//!
//! Run via `lyric test lyric-compiler/lyric/doc_self_test.l`.
@test_module
package Lyric.Doc.SelfTest

import Std.Core
import Std.Testing
import Std.String as Str
import Lyric.Doc

test "generated docs label an internal field internal, not pub" {
  val src = "package P\n\npub record Foo {\n  internal x: Int\n  y: String\n}\n"
  val docStr = generate(src)
  assertTrue(Str.contains(docStr, "internal x: Int"), "doc: internal field labeled internal")
  assertFalse(Str.contains(docStr, "pub x: Int"), "doc: internal field must not be mislabeled pub")
}

test "generated docs still label a pub field pub" {
  val src = "package P\n\npub record Bar {\n  pub x: Int\n}\n"
  val docStr = generate(src)
  assertTrue(Str.contains(docStr, "pub x: Int"), "doc: pub field still labeled pub")
}

test "generated docs give a private (unmarked) field no visibility prefix" {
  val src = "package P\n\npub record Baz {\n  x: Int\n}\n"
  val docStr = generate(src)
  assertTrue(Str.contains(docStr, "x: Int"), "doc: private field present")
  assertFalse(Str.contains(docStr, "pub x: Int"), "doc: private field must not be labeled pub")
  assertFalse(Str.contains(docStr, "internal x: Int"), "doc: private field must not be labeled internal")
}
