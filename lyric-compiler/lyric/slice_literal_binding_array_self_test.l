//! slice_literal_binding_array_self_test.l — regression test for an
//! unannotated binding of a bracket literal reaching a CLR-array parameter.
//!
//! `val parts = ["a", "b", n.toString()]` has the checked type `slice[String]`,
//! but the MSIL no-hint `EList` arm re-derived the representation from the
//! elements' syntax (`inferHomogeneousListElemTypeMsil`): an element that is a
//! call, a member access or an index has no peekable type, so the literal was
//! built as a `List<object>` held in an `object` local.  Passed to a parameter
//! whose CLR type is `String[]` (an `@externTarget` binding, a function of
//! another assembly) that `List` was read as an array: an empty or garbage
//! result, or an `AccessViolationException` (observed with `Lyric.Db`).
//! `Lyric.TypeChecker` now records the checked type of the literal(s) an
//! unannotated binding's initializer yields, so the literal is built at its
//! `slice[String]` type, as the annotated form is.
//!
//! The sensitive cases run under `DOTNET_TieredCompilation=0` too, where the
//! old miscompile faulted on the first call instead of after tier-up.
//!
//! Run via native `lyric test` (the extern makes this `--target dotnet` only):
//!   lyric test lyric-compiler/lyric/slice_literal_binding_array_self_test.l
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.SliceLiteralBindingArraySelfTest

import Std.Core
import Std.String as Str
import Std.Testing

@externStatic
@externTarget("System.IO.Path.Combine")
func pathCombine(parts: in slice[String]): String = ""

record Holder {
  name: String
}

func mk(n: in Int): String {
  "m" + n.toString()
}

// A same-project function takes a `slice[String]` as an erased value and hands
// it on to the array boundary, so the representation it is given must already
// be an array.
func forward(parts: in slice[String]): String {
  pathCombine(parts)
}

// The expected result: the inline literal, whose position fixes its type.
func joined(a: in String, b: in String, c: in String): String {
  pathCombine([a, b, c])
}

func callElement(n: in Int): String {
  val parts = ["a", "b", n.toString()]
  pathCombine(parts)
}

func userCallElement(n: in Int): String {
  val parts = ["a", mk(n), "c"]
  pathCombine(parts)
}

func memberElement(h: in Holder): String {
  val parts = ["a", h.name, "c"]
  pathCombine(parts)
}

func indexElement(xs: in slice[String]): String {
  val parts = ["a", xs[0], "c"]
  pathCombine(parts)
}

func ifInitializer(n: in Int): String {
  val parts = if n > 0 then ["a", "b", n.toString()] else ["a", n.toString()]
  pathCombine(parts)
}

func matchInitializer(n: in Int): String {
  val parts = match n { case 7 -> ["a", "b", n.toString()]; case _ -> ["a"] }
  pathCombine(parts)
}

func forwarded(n: in Int): String {
  val parts = ["a", "b", n.toString()]
  forward(parts)
}

func varBinding(n: in Int): String {
  var parts = ["a", "b", n.toString()]
  pathCombine(parts)
}

func crossAssembly(n: in Int): String {
  val parts = ["a", "b", n.toString()]
  Str.join(",", parts)
}

test "a call element of an unannotated slice binding builds a String[]" {
  assertTrue(callElement(7) == joined("a", "b", "7"), "n.toString() element")
  assertTrue(userCallElement(7) == joined("a", "m7", "c"), "user call element")
}

test "a member-access element of an unannotated slice binding builds a String[]" {
  assertTrue(memberElement(Holder(name = "x")) == joined("a", "x", "c"), "h.name element")
}

test "an index element of an unannotated slice binding builds a String[]" {
  val xs: slice[String] = ["p", "q"]
  assertTrue(indexElement(xs) == joined("a", "p", "c"), "xs[0] element")
}

test "an if or match initializer of an unannotated binding builds a String[]" {
  assertTrue(ifInitializer(7) == joined("a", "b", "7"), "if initializer")
  assertTrue(matchInitializer(7) == joined("a", "b", "7"), "match initializer")
}

test "an unannotated slice binding forwarded through a function keeps its array" {
  assertTrue(forwarded(7) == joined("a", "b", "7"), "forwarded to the extern")
}

test "an unannotated var binding of a slice literal builds a String[]" {
  assertTrue(varBinding(7) == joined("a", "b", "7"), "var binding")
}

test "an unannotated slice binding binds as String[] across the stdlib boundary" {
  assertTrue(crossAssembly(7) == "a,b,7", "Std.String.join over a bound literal")
}
