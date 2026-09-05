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

// #6832: `opaqueSignature` rendered a TRAILING annotation (the grammar
// places `@projectable` after the name, `opaque type User @projectable {`)
// as a LEADING line instead — mirrors `Lyric.Fmt.opaqueDoc`'s fix.
test "generated docs keep an opaque type's trailing annotation inline, not hoisted to a leading line" {
  val src = "package P\n\npub opaque type User @projectable {\n  name: String\n}\n"
  val docStr = generate(src)
  assertTrue(
    Str.contains(docStr, "pub opaque type User @projectable"),
    "doc: @projectable stays inline after the header"
  )
  assertFalse(
    Str.contains(docStr, "@projectable\npub opaque type User"),
    "doc: @projectable must not be hoisted to a leading line"
  )
}

// #6832: `fieldStr` silently dropped a field's TRAILING annotation
// (`passwordHash: String @hidden`) from `lyric doc` output entirely.
test "generated docs keep a field's trailing annotation instead of dropping it" {
  val src = "package P\n\npub record Secret {\n  passwordHash: String @hidden\n}\n"
  val docStr = generate(src)
  assertTrue(Str.contains(docStr, "passwordHash: String @hidden"), "doc: field trailing annotation preserved inline")
}

// #6833: the `TRefined` doc renderer (used wherever a refined type
// appears as a `TypeExpr`, e.g. a field type) dropped the range bound
// text entirely, always rendering `... range ...` regardless of the
// actual bounds.
test "generated docs render a refined field type's actual range bound" {
  val src = "package P\n\npub record Person {\n  age: Int range 0 .. 150\n}\n"
  val docStr = generate(src)
  assertTrue(
    Str.contains(docStr, "0 .. 150") or Str.contains(docStr, "0 ..< 150"),
    "doc: refined field type shows its real range bound"
  )
  assertFalse(Str.contains(docStr, "range ..."), "doc: refined field type must not render the '...' placeholder")
}

// #6833: `distinctSignature` never read `DistinctTypeDecl.rangeClause`
// at all, so a range-subtype declaration documented without its range
// (`type Age = Int range 0 .. 150` rendered as bare `type Age = Int`).
test "generated docs render a distinct range-subtype declaration's range bound" {
  val src = "package P\n\npub type Age = Int range 0 .. 150\n"
  val docStr = generate(src)
  assertTrue(Str.contains(docStr, "type Age = Int range 0 .. 150"), "doc: distinct range-subtype shows its range bound")
}
