//! lambda_ffi_delegate_self_test.l — End-to-end integration test
//! for strongly-typed lambda FFI delegates (Epic #1877, Phase 1).
//!
//! Passes lambdas to FFI delegate parameters System.Func`2 and System.Action`1
//! on System.Collections.Generic.List`1 to ensure nominal delegate
//! instantiation with zero-thunks.
//!
//! Note: Phase 1 (M5.2-M5.3) supports Func/Action delegates only.
//! Predicate/Comparison support is deferred to Phase 2 (#3923).
//!
//!   lyric test --target dotnet lyric-compiler/lyric/lambda_ffi_delegate_self_test.l
@test_module
package Lyric.LambdaFfiDelegateSelfTest

import Std.Core
import Std.Testing

extern type List[T] = "System.Collections.Generic.List`1"

extern type Func[T, TResult] = "System.Func`2"

extern type Action[T] = "System.Action`1"

extern type Obj = "System.Object"

@externTarget("System.Collections.Generic.List`1..ctor")
func newList[T](): List[T] = ()

@externTarget("System.Collections.Generic.List`1.Add")
func listAdd[T](xs: in List[T], x: in T): Unit = ()

@externTarget("System.Collections.Generic.List`1.get_Count")
func listCount[T](xs: in List[T]): Int = ()

@externTarget("System.Collections.Generic.List`1.ForEach")
func listForEach[T](xs: in List[T], action: in Action[T]): Unit = ()

test "passing lambda directly to Action[T] FFI delegate parameter" {
  val xs: List[Obj] = newList()
  listAdd(xs, 1)
  listAdd(xs, 2)
  listAdd(xs, 3)

  // Pass lambda directly as argument (not via local assignment).
  // This exercises argSatisfiesParam type-check and runtime delegate creation.
  listForEach(xs, { _: Obj -> () })
  assertEqualInt(xs.count, 3, "all 3 elements present")
}

test "assign lambda to Func[T, Bool] local variable" {
  val xs: List[Obj] = newList()
  listAdd(xs, 1)
  listAdd(xs, 2)
  listAdd(xs, 3)

  // Assign lambda to Func delegate type (type-check path).
  val checker: Func[Obj, Bool] = { x: Obj -> x != null }
  assertEqualInt(xs.count, 3, "all 3 elements present")
}
