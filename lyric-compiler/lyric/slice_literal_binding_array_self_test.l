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
//! The same literal in a position that is not a binding's initializer: a
//! lambda's result, a tuple element, a generic constructor argument
//! (`Some(...)`, `Box(...)`), the receiver of a slice method, or an element of
//! another literal used as a `for` iterable, is recorded the same way (the
//! checker records every literal with a non-literal element whose checked type
//! is a closed slice, and a position that names the slice type builds it from
//! that type instead).
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

record Box[T] {
  v: T
}

func mkp(n: in Int): slice[String] {
  ["a", "b", n.toString()]
}

func lambdaResult(n: in Int): String {
  val g = { -> ["a", "b", n.toString()] }
  pathCombine(g())
}

func lambdaWithParam(n: in Int): String {
  val g = { k: Int -> ["a", "b", k.toString()] }
  pathCombine(g(n))
}

func lambdaBlockTail(n: in Int): String {
  val g = { -> val k = 1; ["a", "b", n.toString()] }
  pathCombine(g())
}

func lambdaReturn(n: in Int): String {
  val g = { -> return ["a", "b", n.toString()] }
  pathCombine(g())
}

func tupleElement(n: in Int): String {
  val t = (["a", "b", n.toString()], 1)
  val (p, _) = t
  pathCombine(p)
}

func someArgument(n: in Int): String {
  val o = Some(value = ["a", "b", n.toString()])
  match o {
    case Some(p) -> pathCombine(p)
    case None -> ""
  }
}

func genericCtorArgument(n: in Int): String {
  val b = Box(v = ["a", "b", n.toString()])
  pathCombine(b.v)
}

func forIterableElement(n: in Int): String {
  for p in [["a", "b", n.toString()]] {
    return pathCombine(p)
  }
  ""
}

func receiverToArray(n: in Int): String {
  val p = ["a", "b", n.toString()].toArray()
  pathCombine(p)
}

func receiverConcat(n: in Int): String {
  pathCombine(["a", n.toString()].concat(["b"]))
}

func receiverSlice(n: in Int): String {
  val p = ["a", "b", n.toString()].slice(0, 3)
  pathCombine(p)
}

// One branch is a literal with a call element, the other a call returning a
// slice (already a real array): both reach the boundary as arrays.
func ifLiteralOrCall(n: in Int): String {
  val p = if n > 0 then ["a", "b", n.toString()] else mkp(n)
  pathCombine(p)
}

func ifCallOrLiteral(n: in Int): String {
  val p = if n > 0 then mkp(n) else ["a", "b", n.toString()]
  pathCombine(p)
}

func matchLiteralOrCall(n: in Int): String {
  val p = match n { case 7 -> ["a", "b", n.toString()]; case _ -> mkp(n) }
  pathCombine(p)
}

func matchCallOrLiteral(n: in Int): String {
  val p = match n { case 7 -> mkp(n); case _ -> ["a", "b", n.toString()] }
  pathCombine(p)
}

func sumLongs(xs: in slice[Long]): Long {
  var t: Long = 0
  for x in xs {
    t = t + x
  }
  t
}

test "a lambda's result literal builds a String[]" {
  assertTrue(lambdaResult(7) == joined("a", "b", "7"), "expression body")
  assertTrue(lambdaWithParam(7) == joined("a", "b", "7"), "parameter element")
  assertTrue(lambdaBlockTail(7) == joined("a", "b", "7"), "block tail")
  assertTrue(lambdaReturn(7) == joined("a", "b", "7"), "explicit return")
}

test "a tuple element literal builds a String[]" {
  assertTrue(tupleElement(7) == joined("a", "b", "7"), "tuple element")
}

test "a generic constructor argument literal builds a String[]" {
  assertTrue(someArgument(7) == joined("a", "b", "7"), "Some(...)")
  assertTrue(genericCtorArgument(7) == joined("a", "b", "7"), "Box(...)")
}

test "a literal nested in a for iterable builds a String[]" {
  assertTrue(forIterableElement(7) == joined("a", "b", "7"), "[[...]] iterable")
}

test "a literal that is a slice method's receiver builds a String[]" {
  assertTrue(receiverToArray(7) == joined("a", "b", "7"), "toArray receiver")
  assertTrue(receiverConcat(7) == joined("a", "7", "b"), "concat receiver")
  assertTrue(receiverSlice(7) == joined("a", "b", "7"), "slice receiver")
}

test "an if or match initializer mixing a literal and a call builds a String[] on both branches" {
  assertTrue(ifLiteralOrCall(7) == joined("a", "b", "7"), "if, literal branch")
  assertTrue(ifLiteralOrCall(0) == joined("a", "b", "0"), "if, call branch")
  assertTrue(ifCallOrLiteral(7) == joined("a", "b", "7"), "if (call first), call branch")
  assertTrue(ifCallOrLiteral(0) == joined("a", "b", "0"), "if (call first), literal branch")
  assertTrue(matchLiteralOrCall(7) == joined("a", "b", "7"), "match, literal arm")
  assertTrue(matchLiteralOrCall(8) == joined("a", "b", "8"), "match, call arm")
  assertTrue(matchCallOrLiteral(7) == joined("a", "b", "7"), "match (call first), call arm")
  assertTrue(matchCallOrLiteral(8) == joined("a", "b", "8"), "match (call first), literal arm")
}

test "a position that names a wider slice type still widens its literal" {
  val n = 3
  assertTrue(sumLongs([1, 2, n]) == 6, "Int elements for a slice[Long] parameter")
  val ys: slice[Long] = [1, 2, n]
  assertTrue(sumLongs(ys) == 6, "Int elements for a slice[Long] binding")
}
