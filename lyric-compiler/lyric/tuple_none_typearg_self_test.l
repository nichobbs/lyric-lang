//! tuple_none_typearg_self_test.l — regression test for #4965: a bare
//! `None` literal constructed inside a tuple literal used to lose its
//! declared type argument on MSIL, erasing to `Option_None<object>`
//! instead of the annotated `Option[T]`.
//!
//! Root cause: `lowerExprMsil`'s `ETuple` arm (`lyric-compiler/msil/codegen.l`)
//! lowered each element with a bare recursive call and never propagated the
//! enclosing binding's per-element expected type — unlike the `EList` arm,
//! which pushes each element's declared type onto `collExpect` before
//! lowering it. A `val t: (Int, Option[String]) = (1, None)` binding DOES
//! push the full tuple annotation onto `collExpect` before lowering the
//! tuple literal; `ETuple` simply never read it back out per element. Fixed
//! by reading `collExpectTop` when it holds a matching-arity `MTuple` and
//! threading each element's own expected type through both `collExpect`
//! and `contextHintTyArgs` (mirroring `EList`), so a nullary case like
//! `None` constructs the closed `Option_None<String>` instance a later
//! `match`/destructure expects instead of an untyped one that fails to
//! match its own `None` arm.
//!
//! MSIL-only bug (JVM erases generic type arguments entirely — there is no
//! `Option_None<T>` reified class to mis-instantiate there — so this
//! reproduces only on `--target dotnet`).
//! Imports only `Std.*`.
@test_module
package Lyric.TupleNoneTypeArgSelfTest

import Std.Core
import Std.Testing

test "a bare None element inside an annotated tuple literal keeps its declared type argument" {
  val t: (Int, Option[String]) = (1, None)
  match t {
    case (_, None) -> assertTrue(true, "tuple's None element matched None correctly")
    case (_, Some(_)) -> assertTrue(false, "tuple's None element must not match Some (or throw InvalidCastException)")
  }
}

test "a Some(...) element inside an annotated tuple literal also keeps its declared type" {
  val t: (Int, Option[String]) = (2, Some("x"))
  match t {
    case (_, Some(v)) -> assertEqual(v, "x", "tuple's Some element carried its value through")
    case (_, None) -> assertTrue(false, "tuple's Some element must not match None")
  }
}

test "None nested two levels deep in a tuple annotation still keeps its type argument" {
  val t: (Option[Int], (Int, Option[String])) = (None, (3, None))
  match t {
    case (None, (_, None)) -> assertTrue(true, "both nested None elements matched correctly")
    case (_, _) -> assertTrue(false, "a nested None element lost its declared type argument")
  }
}
