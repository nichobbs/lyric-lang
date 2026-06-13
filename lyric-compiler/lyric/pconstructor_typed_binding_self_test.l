//! pconstructor_typed_binding_self_test.l — executable regression test for
//! issue #1891: `lowerPatternBindMsil` used to allocate an `MObject` local
//! for every `PConstructor`-bound variable, even when the case-class field's
//! declared type was concrete (`String`, `Int`, `Option[T]`).  Passing such
//! a binding to a typed parameter then failed JIT verification at runtime
//! (`InvalidProgramException`), which forced site-local workarounds across
//! the parser and type checker (explicit `Option[...]` ascriptions,
//! brace-wrapped arms, hoisted `val noInner` locals).
//!
//! The fix makes the `PConstructor` arm look up the field's declared type
//! via `cctx.fieldMsilTypes` and allocate the binding slot at that concrete
//! type, mirroring the record-field path.  Every test below binds a typed
//! payload out of a union case and feeds it straight into a parameter of
//! that declared type — the exact shape that used to produce invalid IL.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/pconstructor_typed_binding_self_test.l
//!
//! `lyric test` compiles this module in-process through the self-hosted
//! `Msil.Bridge` and runs the produced PE, so a regression to the blanket
//! `MObject` slot fails here with a runtime verification error.  Imports
//! only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.PConstructorTypedBindingSelfTest

import Std.Core
import Std.Testing

union Tag {
  case Tagged(label: String, n: Int)
  case Anon(n: Int)
  case Bare
}

// The String-typed parameter is the verification trap: before the #1891 fix
// the bound payload sat in an `object` slot and this call did not verify.
func useString(s: in String): Int {
  s.length
}

func useInt(n: in Int): Int {
  n + 1
}

test "named union payloads bind at their declared types" {
  val t = Tagged(label = "hello", n = 4)
  match t {
    case Tagged(label, n) -> {
      assertTrue(useString(label) == 5, "Tagged.label binds as String")
      assertTrue(useInt(n) == 5, "Tagged.n binds as Int")
    }
    case _ -> assertTrue(false, "expected Tagged")
  }
}

test "union payload feeds typed parameters across arms" {
  val anon = Anon(n = 41)
  val viaArms = match anon { case Tagged(label, _) -> useString(label); case Anon(n) -> useInt(n); case Bare -> 0 }
  assertTrue(viaArms == 42, "Anon.n binds as Int across arms")
}

test "generic Option payload binds as String" {
  val opt: Option[String] = Some("abc")
  val len = match opt { case Some(s) -> useString(s); case None -> 0 }
  assertTrue(len == 3, "Some(s) binds as String")
}

test "generic Result payloads bind as String" {
  val ok: Result[String, String] = Ok("yes")
  val err: Result[String, String] = Err("no!")
  val a = match ok { case Ok(v) -> useString(v); case Err(e) -> 0 - useString(e) }
  val b = match err { case Ok(v) -> useString(v); case Err(e) -> 0 - useString(e) }
  assertTrue(a == 3, "Ok payload binds as String")
  assertTrue(b == -3, "Err payload binds as String")
}

test "val-bound match over Option keeps its payload type" {
  // The natural shape the #1891 workarounds avoided:
  // `val x = match ... { case Some(s) -> Some(s); case None -> None }`
  // with no type ascription and bare un-braced arms.
  val src: Option[String] = Some("xyz")
  val copied = match src { case Some(s) -> Some(s); case None -> None }
  match copied {
    case Some(s) -> assertTrue(useString(s) == 3, "round-tripped payload binds as String")
    case None -> assertTrue(false, "expected Some")
  }
}

// NOTE: deeply *nested* constructor bindings — e.g.
// `case Some(Tagged(label, n)) -> useString(label)` — are a separate codegen
// path from the single-level typed binding #1891 fixed.  They currently
// populate the inner binding slot incorrectly and trip a runtime
// NullReferenceException; that gap is tracked in #3280 and is out of scope
// for #1891 (whose acceptance is the single-level `case Some(s: String)`
// shape).  Re-add a nested case here once #3280 lands.
