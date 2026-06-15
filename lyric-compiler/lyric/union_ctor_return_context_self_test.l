//! #3813 follow-up: a generic union case constructor built where the only
//! ambient context is the enclosing function's *declared return type* must
//! only borrow that return type's type-args when it shares the constructor's
//! generic head.
//!
//! Regression for the lyric-storage `list` pagination-token shape: a bare
//! `Some(value = s)` (head `Option`) built inside a function returning
//! `Result[Rec, E]` (head `Result`) previously borrowed `Result`'s first arg
//! and emitted `Option_Some<Rec>` instead of inferring `<String>` from `s`, so
//! a later `match` on the resulting `Option[String]` field failed "not
//! exhaustive".  Run in CI via native `lyric test` (imports only Std.*).
//!
//! Scope note: the `else { None }` arm of an *unannotated* `if`/`else` binding
//! is a separate, pre-existing gap — the nullary `None` has no argument to
//! infer from and the sibling `Some` arm's type is not propagated to it, so it
//! erases to `Option_None<object>`.  That is tracked in #3820 and is NOT what
//! this test (or the #3813 fix) covers; every case here exercises a `Some`
//! constructor whose argument pins the type.
@test_module
package Lyric.UnionCtorReturnContextSelfTest

import Std.Core
import Std.Testing

record PErr {
  code: String
}

record Page {
  tok: Option[String]
  truncated: Bool
}

// `Some(value = t)` is constructed here, in a `val`, where the only ambient
// type context is `mkPage`'s declared return type `Result[Page, PErr]` (head
// `Result`, not `Option`).  It must come out `Option_Some<String>`.
func mkPage(t: in String): Result[Page, PErr] {
  val nextTok = Some(value = t)
  Ok(Page(tok = nextTok, truncated = true))
}

func pageTok(r: in Result[Page, PErr], sentinel: in String): String {
  match r {
    case Err(_) -> sentinel
    case Ok(p) -> match p.tok { case None -> sentinel; case Some(s) -> s }
  }
}

test "bare Some in a Result[Rec,E] fn infers its arg type, not the return type" {
  assertEqual(
    pageTok(mkPage("cursor"), "MISS"),
    "cursor",
    "Some(t) built in a val inside mkPage must be Option_Some<String>, matchable as Page.tok"
  )
}

// Direct shape: `Some(s)` as a record-field constructor argument inside a
// `Result[Rec, E]`-returning function.
func wrapTok(s: in String): Result[Page, PErr] {
  Ok(Page(tok = Some(value = s), truncated = true))
}

test "Some built directly as a record-field ctor arg infers from its arg" {
  assertEqual(pageTok(wrapTok("direct"), "MISS"), "direct", "Some(s) as a ctor arg is Option_Some<String>")
}
