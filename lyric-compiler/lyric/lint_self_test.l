//! lint_self_test.l — exercises the self-hosted `Lyric.Lint` rules against
//! parsed source strings.  Run in CI via native `lyric test` (no F# runner
//! shim).
@test_module
package Lyric.Lint.SelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.String as Str
import Lyric.Lint

func countCode(diags: in List[LintDiag], code: in String): Int {
  var i = 0
  var n = 0
  while i < diags.count {
    if diags[i].code == code {
      n = n + 1
    }
    i = i + 1
  }
  n
}

func anyMessageContains(diags: in List[LintDiag], code: in String, needle: in String): Bool {
  var i = 0
  var found = false
  while i < diags.count and not found {
    if diags[i].code == code and Str.contains(diags[i].message, needle) {
      found = true
    }
    i = i + 1
  }
  found
}

// ─────────────────────────────────────────────────────────────────────────────
// §1. Positive cases — one per signature position from #7549.
// ─────────────────────────────────────────────────────────────────────────────
test "L007: receiver of a pub type-associated function on a private type" {
  val src = "package P\n" + "record Widget { x: Int }\n" + "pub func Widget.create(n: in Int): Int { n }\n"
  val diags = lint(src)
  assertEqualInt(countCode(diags, "L007"), 1, "exactly one L007 for the private receiver")
  assertTrue(anyMessageContains(diags, "L007", "receiver 'Widget'"), "message names the receiver position")
  assertTrue(anyMessageContains(diags, "L007", "'Widget'"), "message names the private type")
}

test "L007: parameter of a pub func names a private type" {
  val src = "package P\n" + "record Widget { x: Int }\n" + "pub func useWidget(w: in Widget): Int { w.x }\n"
  val diags = lint(src)
  assertEqualInt(countCode(diags, "L007"), 1, "exactly one L007 for the private parameter type")
  assertTrue(anyMessageContains(diags, "L007", "parameter 'w'"), "message names the parameter position")
}

test "L007: return type of a pub func names a private type" {
  val src = "package P\n" + "record Widget { x: Int }\n" + "pub func makeWidget(): Widget { Widget(x = 1) }\n"
  val diags = lint(src)
  assertEqualInt(countCode(diags, "L007"), 1, "exactly one L007 for the private return type")
  assertTrue(anyMessageContains(diags, "L007", "return type"), "message names the return-type position")
}

test "L007: pub field of a pub record names a private type" {
  val src = "package P\n" + "record Inner { n: Int }\n" + "pub record Outer {\n" + "  pub inner: Inner\n" +
    "  hidden: Inner\n" +
    "}\n"
  val diags = lint(src)
  assertEqualInt(countCode(diags, "L007"), 1, "only the pub field is flagged, not the package-private one")
  assertTrue(anyMessageContains(diags, "L007", "field 'inner'"), "message names the pub field")
}

test "L007: pub field of a pub exposed record names a private type" {
  val src = "package P\n" + "record Inner { n: Int }\n" + "pub exposed record Outer {\n" + "  pub inner: Inner\n" +
    "}\n"
  val diags = lint(src)
  assertEqualInt(countCode(diags, "L007"), 1, "exposed record field flagged")
  assertTrue(anyMessageContains(diags, "L007", "exposed record"), "message identifies the exposed record")
}

test "L007: union case payload of a pub union names a private type" {
  val src = "package P\n" + "record Payload { n: Int }\n" + "pub union Outcome {\n" + "  case Ok(Payload)\n" +
    "  case Err(String)\n" +
    "}\n"
  val diags = lint(src)
  assertEqualInt(countCode(diags, "L007"), 1, "only the private-payload case is flagged")
  assertTrue(anyMessageContains(diags, "L007", "case 'Ok' payload"), "message names the case")
}

test "L007: named union case field names a private type" {
  val src = "package P\n" + "record Payload { n: Int }\n" + "pub union Outcome {\n" + "  case Ok(value: Payload)\n" +
    "}\n"
  val diags = lint(src)
  assertEqualInt(countCode(diags, "L007"), 1, "named case field flagged")
  assertTrue(anyMessageContains(diags, "L007", "case 'Ok' field 'value'"), "message names the case field")
}

test "L007: interface method signature (body-less sig) names a private type" {
  val src = "package P\n" + "record Widget { x: Int }\n" + "pub interface Factory {\n" + "  func make(): Widget\n" +
    "}\n"
  val diags = lint(src)
  assertEqualInt(countCode(diags, "L007"), 1, "interface sig return type flagged")
  assertTrue(
    anyMessageContains(diags, "L007", "interface 'Factory' method 'make'"),
    "message names the interface method"
  )
}

test "L007: interface default-method signature names a private type" {
  val src = "package P\n" + "record Widget { x: Int }\n" + "pub interface Factory {\n" +
    "  func make(w: in Widget): Widget { w }\n" +
    "}\n"
  val diags = lint(src)
  assertEqualInt(countCode(diags, "L007"), 2, "both the default method's parameter and return type flagged")
}

test "L007: protected type entry names a private type" {
  val src = "package P\n" + "record Item { n: Int }\n" + "pub protected type Box {\n" + "  var held: Int = 0\n" +
    "  pub entry put(item: in Item): Unit { held = 1 }\n" +
    "}\n"
  val diags = lint(src)
  assertEqualInt(countCode(diags, "L007"), 1, "protected entry parameter flagged (Box itself is pub)")
  assertTrue(anyMessageContains(diags, "L007", "entry 'put'"), "message names the entry")
}

test "L007: protected type itself private makes a pub entry unusable (receiver position)" {
  val src = "package P\n" + "protected type Box {\n" + "  var held: Int = 0\n" + "  pub entry get(): Int { held }\n" +
    "}\n"
  val diags = lint(src)
  assertEqualInt(countCode(diags, "L007"), 1, "receiver-position diagnostic for the private protected type")
  assertTrue(anyMessageContains(diags, "L007", "receiver 'Box'"), "message names the receiver")
}

// #7621: a generic protected type's own type parameter shadows a same-named
// private type in its members' signatures, as for records, unions and
// interfaces.
test "L007: generic protected type's own parameter is not a private type" {
  val src = "package P\n" + "record T { n: Int }\n" + "pub protected type Box[T] {\n" + "  var held: Option[T] = None\n" +
    "  pub entry put(item: in T): Unit { held = Some(item) }\n" +
    "  pub entry get(): Option[T] { held }\n" +
    "  pub func peek(): Option[T] { held }\n" +
    "}\n"
  val diags = lint(src)
  assertEqualInt(countCode(diags, "L007"), 0, "T is Box's generic parameter, not the private record T")
}

test "L007: pub val with explicit type annotation names a private type" {
  val src = "package P\n" + "record Widget { x: Int }\n" + "pub val zero: Widget = Widget(x = 0)\n"
  val diags = lint(src)
  assertEqualInt(countCode(diags, "L007"), 1, "val type flagged")
  assertTrue(anyMessageContains(diags, "L007", "pub val 'zero'"), "message names the val")
}

test "L007: alias to a private type is still private" {
  val src = "package P\n" + "record Widget { x: Int }\n" + "pub alias Handle = Widget\n" +
    "pub func makeHandle(): Handle { Handle(x = 1) }\n"
  val diags = lint(src)
  assertEqualInt(countCode(diags, "L007"), 1, "return type flagged even though the alias itself is pub")
  assertTrue(anyMessageContains(diags, "L007", "'Handle'"), "message names the alias, not the underlying record")
}

test "L007: generic argument inside a signature names a private type" {
  val src = "package P\n" + "record Widget { x: Int }\n" +
    "pub func wrapWidgets(xs: in List[Widget]): List[Widget] { xs }\n"
  val diags = lint(src)
  assertEqualInt(countCode(diags, "L007"), 2, "one hit for the parameter, one for the return type")
  assertTrue(anyMessageContains(diags, "L007", "parameter 'xs'"), "parameter position flagged")
  assertTrue(anyMessageContains(diags, "L007", "return type"), "return position flagged")
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Negative cases — no false positives.
// ─────────────────────────────────────────────────────────────────────────────
test "L007: pub type in a pub signature is not flagged" {
  val src = "package P\n" + "pub record Widget { x: Int }\n" + "pub func makeWidget(): Widget { Widget(x = 1) }\n"
  val diags = lint(src)
  assertEqualInt(countCode(diags, "L007"), 0, "no diagnostic for a pub receiver/return type")
}

test "L007: internal type in a pub signature is not flagged" {
  val src = "package P\n" + "internal record Widget { x: Int }\n" + "pub func makeWidget(): Widget { Widget(x = 1) }\n"
  val diags = lint(src)
  assertEqualInt(countCode(diags, "L007"), 0, "internal is cross-package visible, not package-private")
}

test "L007: package-private item using a package-private type is not flagged" {
  val src = "package P\n" + "record Widget { x: Int }\n" + "func makeWidget(): Widget { Widget(x = 1) }\n"
  val diags = lint(src)
  assertEqualInt(countCode(diags, "L007"), 0, "the item itself is package-private too, no cross-package surface")
}

test "L007: generic type parameter is not mistaken for a private type" {
  val src = "package P\n" + "record T { n: Int }\n" + "pub func identity[T](x: in T): T { x }\n"
  val diags = lint(src)
  assertEqualInt(countCode(diags, "L007"), 0, "the generic parameter T shadows the same-named private record")
}

test "L007: pub opaque type counts as visible (docs/01 §3)" {
  val src = "package P\n" + "pub opaque type Money { amount: Int }\n" +
    "pub func makeMoney(): Money { Money(amount = 0) }\n"
  val diags = lint(src)
  assertEqualInt(countCode(diags, "L007"), 0, "pub opaque type exposes its existence, not flagged")
}

test "L007: non-pub opaque type in a pub signature is flagged" {
  val src = "package P\n" + "opaque type Money { amount: Int }\n" +
    "pub func makeMoney(): Money { Money(amount = 0) }\n"
  val diags = lint(src)
  assertEqualInt(countCode(diags, "L007"), 1, "package-private opaque type flagged like any other private type")
}

test "L007: extern type is exempt" {
  val src = "package P\n" + "extern type JsonElement = \"System.Text.Json.JsonElement\"\n" +
    "pub func parse(): JsonElement { JsonElement.new() }\n"
  val diags = lint(src)
  assertEqualInt(countCode(diags, "L007"), 0, "extern types are FFI host bindings, exempt from these tiers")
}

test "L007: package-private field of a pub record is not flagged" {
  val src = "package P\n" + "record Inner { n: Int }\n" + "pub record Outer {\n" + "  inner: Inner\n" + "}\n"
  val diags = lint(src)
  assertEqualInt(
    countCode(diags, "L007"),
    0,
    "a package-private field is invisible cross-package regardless of its type"
  )
}

test "L007: protected type func member with no visibility modifier is not flagged" {
  val src = "package P\n" + "record Item { n: Int }\n" + "protected type Box {\n" + "  var held: Int = 0\n" +
    "  func helper(item: in Item): Unit { held = 1 }\n" +
    "}\n"
  val diags = lint(src)
  assertEqualInt(countCode(diags, "L007"), 0, "a package-private helper func is never externally reachable")
}
