//! nested_constructor_pattern_self_test.l — regression test for the MSIL
//! nested-constructor-pattern silent-miscompile bug fixed alongside PR #3908.
//!
//! Bug: `lowerPatternTestMsil`'s `PConstructor` arm (`lyric-compiler/msil/codegen.l`)
//!   previously emitted only the head `isinst` check for a constructor pattern's
//!   case, never recursing into refutable field sub-patterns. So `case Ok(None)`
//!   matched any `Ok(..)` value regardless of what the field actually held: a
//!   `match` listing `Ok(None)` before `Ok(Some(x))` swallowed every
//!   `Ok(Some(..))` value into the `Ok(None)` arm. The fix introduced
//!   `patternIsRefutableMsil` (decide whether a sub-pattern needs a runtime
//!   test at all) and `testCaseFieldMsil` (extract + recursively test a
//!   constructor's field) so each refutable field sub-pattern is actually
//!   tested, not just the outer case tag.
//!
//! These tests pin the corrected behavior directly, without going through a
//! nested `match` (which routes through a separate scrutinee and would not
//! have caught the bug): each test lists sibling constructor-pattern arms in
//! one `match` where an earlier, more general-looking arm (`Ok(None)`) must
//! NOT swallow a later, more specific arm (`Ok(Some(x))`). The two-level
//! nesting tests use a second union type (`Shape`) rather than a `record`:
//! per docs/grammar.ebnf, a `record` destructures with brace syntax
//! (`Foo { n }`, `RecordPattern`), not constructor-call syntax (`Foo(n)`,
//! `ConstructorPattern`) — a record nested inside a constructor pattern hits
//! an unrelated field-binding bug, tracked separately in #4608.
//!
//! Compiles in-process via the self-hosted MSIL bridge; no
//! `LYRIC_LOAD_COMPILER=1` needed since this module imports only `Std.*`.
//!
//! Run:
//!   lyric test lyric-compiler/lyric/nested_constructor_pattern_self_test.l
@test_module
package Lyric.NestedConstructorPatternSelfTest

import Std.Core
import Std.Testing

union Shape {
  case Circle(radius: Int)
  case Square(side: Int)
}

test "#3908: Ok(None) arm does not match Ok(Some(42))" {
  val r: Result[Option[Int], String] = Ok(Some(42))
  val got = match r { case Ok(None) -> -1; case Ok(Some(x)) -> x; case Err(_) -> -2 }
  assertEqualInt(got, 42, "Ok(Some(42)) must reach the Ok(Some(x)) arm, not Ok(None)")
}

test "#3908: Ok(Some(x)) binds correctly when Ok(None) arm precedes it" {
  val r: Result[Option[Int], String] = Ok(Some(7))
  val got = match r { case Ok(None) -> 0; case Ok(Some(x)) -> x + 100; case Err(_) -> -1 }
  assertEqualInt(got, 107, "the Ok(Some(x)) binding must carry the real field value")
}

test "#3908: Ok(None) arm is still reachable for an actual None" {
  val r: Result[Option[Int], String] = Ok(None)
  val got = match r { case Ok(None) -> 99; case Ok(Some(x)) -> x; case Err(_) -> -1 }
  assertEqualInt(got, 99, "Ok(None) must still match when the field really is None")
}

test "#3908: nested two-level constructor pattern Ok(Some(Circle(radius)))" {
  val r: Result[Option[Shape], String] = Ok(Some(Circle(radius = 5)))
  val got = match r {
    case Ok(None) -> -1
    case Ok(Some(Circle(radius))) -> radius * 10
    case Ok(Some(Square(_))) -> -3
    case Err(_) -> -2
  }
  assertEqualInt(got, 50, "two-level nested constructor pattern must extract the real field")
}

test "#3908: nested two-level pattern does not swallow Ok(None)" {
  val r: Result[Option[Shape], String] = Ok(None)
  val got = match r {
    case Ok(None) -> 42
    case Ok(Some(Circle(radius))) -> radius
    case Ok(Some(Square(_))) -> -3
    case Err(_) -> -1
  }
  assertEqualInt(got, 42, "Ok(None) must still reach its own arm even with a nested-constructor sibling")
}

test "#3908: two-level nesting distinguishes sibling union cases" {
  val r: Result[Option[Shape], String] = Ok(Some(Square(side = 4)))
  val got = match r {
    case Ok(None) -> -1
    case Ok(Some(Circle(_))) -> -2
    case Ok(Some(Square(side))) -> side * 100
    case Err(_) -> -3
  }
  assertEqualInt(got, 400, "must distinguish Circle vs Square at the nested level, not just test the outer Some")
}
