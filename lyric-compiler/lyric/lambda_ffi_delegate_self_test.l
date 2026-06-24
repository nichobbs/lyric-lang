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

// Helper: test a predicate against multiple values and count matches
@externTarget("System.Linq.Enumerable.Count")
func linqCount(source: in Obj, predicate: in Func[Obj, Bool]): Int = ()

test "passing strongly-typed lambda to Func[T, Bool] FFI parameter" {
  val xs: List[Obj] = newList()
  listAdd(xs, 1)
  listAdd(xs, 2)
  listAdd(xs, 3)
  listAdd(xs, 4)
  listAdd(xs, 5)

  // Directly pass lambda to function expecting Func[T, Bool] parameter
  // This tests argSatisfiesParam and delegate creation at the call site
  val matchCount = linqCount(xs, { x: Obj -> true })
  assertEqualInt(matchCount, 5, "all 5 elements match predicate")
}

test "passing strongly-typed lambda to Action[T] FFI parameter" {
  val xs: List[Obj] = newList()
  listAdd(xs, 1)
  listAdd(xs, 2)
  listAdd(xs, 3)

  // Directly pass lambda to function expecting Action[T] parameter
  // This tests argSatisfiesParam and delegate creation at the call site
  listForEach(xs, { _: Obj -> () })
  assertEqualInt(xs.count, 3, "all 3 elements present after ForEach")
}
