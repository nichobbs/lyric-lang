//! field_write_self_test.l - the writes to a record field that language reference §3.4 allows
//! (V0015 widening, #9008): only a field declared `var` is a place, and these programs
//! write only such fields, through every receiver the rule has to let through.  The writes it
//! rejects are the `testdata/reject/field_write_*` cases.
//!
//! Run by native `lyric test` on both targets:
//!   lyric test --target dotnet lyric-compiler/lyric/field_write_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/field_write_self_test.l
@test_module
package Lyric.FieldWriteSelfTest

import Std.Core
import Std.Collections
import Std.Testing

ref record Counter {
  var n: Int
  label: String
}

ref record Holder {
  var inner: Counter
  tag: String
}

record Cursor {
  var pos: Int
  size: Int
}

func bumpRef(c: in Counter): Int {
  c.n = c.n + 1
  c.n
}

func bumpCompound(c: in Counter): Int {
  c.n += 5
  c.n
}

func throughChain(h: in Holder): Int {
  h.inner.n = 7
  h.inner.n
}

func advance(c: inout Cursor): Int {
  c.pos = c.pos + 2
  c.pos
}

func varLocal(): Int {
  var c = Cursor(pos = 1, size = 10)
  c.pos = 4
  c.pos
}

func valRefLocal(): Int {
  val c = Counter(n = 1, label = "a")
  c.n = 3
  c.n
}

test "a var field of a ref record is written through a val binding and an in parameter" {
  assertEqual(valRefLocal(), 3, "val local")
  assertEqual(bumpRef(Counter(n = 1, label = "x")), 2, "in parameter")
  assertEqual(bumpCompound(Counter(n = 1, label = "x")), 6, "compound on an in parameter")
}

test "a var field is written through a field chain whose last field is var" {
  assertEqual(throughChain(Holder(inner = Counter(n = 1, label = "x"), tag = "t")), 7, "chain")
}

test "a var field of a value record is written through a var local and an inout parameter" {
  assertEqual(varLocal(), 4, "var local")
  var cur = Cursor(pos = 0, size = 3)
  assertEqual(advance(cur), 2, "inout")
  assertEqual(cur.pos, 2, "the caller sees it")
}
