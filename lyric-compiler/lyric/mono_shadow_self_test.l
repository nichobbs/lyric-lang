//! mono_shadow_self_test.l — #1855: a user-defined function must shadow an
//! imported generic of the same bare name in the monomorphizer.
//!
//! `Std.Core` exports proof-only generic identities in `core_proof.l`
//! (`identity`, `tag`, `pickFirst`, ...).  The monomorphizer seeds its
//! `genDecls` worklist with imported generics keyed by bare name.  Before the
//! fix it added an imported generic to `genDecls` even when the user's file
//! already defined a *non-generic* function of that name (the local is tracked
//! in `funcDecls` but not `genDecls`, so the "local shadows" guard missed it).
//!
//! The result: a user `func tag(o: in Option[Int]): Int` call was
//! monomorphised against the stdlib `tag[T](x: in T): T` — producing a broken
//! identity specialisation `tag__Option_Int` (return type `Option<Int>` instead
//! of `Int`, body just forwards its argument, the `match` dropped) that the call
//! site then targeted.  It surfaced specifically when the argument carried an
//! explicit type annotation (e.g. `val o: Option[Int] = Some(7)`), because that
//! is what let the bogus type-arg inference complete; the runtime symptom was
//! `Common Language Runtime detected an invalid program.`
//!
//! Run in CI via native `lyric test --target dotnet` (compiles in-process
//! through the self-hosted `Msil.Bridge`, which runs the monomorphizer with the
//! stdlib generics as imports — so the shadowing path under test is exercised).
//! Imports only `Std.*`.
@test_module
package Lyric.MonoShadowSelfTest

import Std.Core
import Std.Testing

// `tag` collides with `Std.Core.tag` (a `generic[T] func tag(x: in T): T`
// proof identity).  The local definition must win.
func tag(o: in Option[Int]): Int {
  match o {
    case Some(v) -> v
    case None -> -1
  }
}

// `identity` collides with `Std.Core.identity[T]` too — a second name to prove
// the shadow rule is general, not a one-off for `tag`.
func identity(o: in Option[Int]): String {
  match o {
    case Some(_) -> "some"
    case None -> "none"
  }
}

// Local union (not stdlib) — same shadowing path, different value type.
union Box {
  case Empty
  case Full(v: Int)
}

func tagBox(b: in Box): Int {
  match b {
    case Full(v) -> v
    case Empty -> -1
  }
}

test "shadowed `tag` via annotated Option local (the #1855 invalid-program repro)" {
  val o: Option[Int] = Some(7)
  assertEqualInt(tag(o), 7, "tag(Some(7)) -> 7")
  val n: Option[Int] = None
  assertEqualInt(tag(n), -1, "tag(None) -> -1")
}

test "shadowed `tag` via annotated if-expression result" {
  val o: Option[Int] = if true { Some(3) } else { None }
  assertEqualInt(tag(o), 3, "if-then Some(3) -> 3")
}

test "shadowed `tag` in argument position" {
  assertEqualInt(tag(Some(9)), 9, "tag(Some(9)) -> 9")
}

test "shadowed `identity` returns the user result, not the stdlib identity" {
  val o: Option[Int] = Some(1)
  assertEqual(identity(o), "some", "user identity(Some) -> \"some\"")
}

test "shadowing also covers a local-union annotated local" {
  val b: Box = Full(42)
  assertEqualInt(tagBox(b), 42, "tagBox(Full(42)) -> 42")
}
