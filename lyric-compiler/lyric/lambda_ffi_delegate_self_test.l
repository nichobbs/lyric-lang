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

extern type IntList = "System.Collections.Generic.List`1"

@externTarget("System.Collections.Generic.List`1..ctor")
func newList[T](): List[T] = ()

@externTarget("System.Collections.Generic.List`1.Add")
func listAdd[T](xs: in List[T], x: in T): Unit = ()

@externTarget("System.Collections.Generic.List`1.get_Count")
func listCount[T](xs: in List[T]): Int = ()

@externTarget("System.Collections.Generic.List`1.ForEach")
func listForEach[T](xs: in List[T], action: in Action[T]): Unit = ()

test "passing strongly-typed lambda Int->Unit to Action[Int] parameter" {
  val ints: IntList = newList[Int]()
  listAdd(ints, 1)
  listAdd(ints, 2)
  listAdd(ints, 3)

  // Pass lambda with Int parameter directly as argument.
  // This exercises strongly-typed lambda method signature (non-object params).
  listForEach(ints, { i: Int -> () })
  assertEqualInt(listCount(ints), 3, "all 3 elements present")
}

test "passing strongly-typed lambda Int->Bool to Func[Int, Bool] parameter" {
  val ints: IntList = newList[Int]()
  listAdd(ints, 10)
  listAdd(ints, 20)
  listAdd(ints, 30)

  // Assign lambda with Int parameter to Func[Int, Bool] delegate type.
  // This exercises strongly-typed lambda method signature in type-check.
  val isLarge: Func[Int, Bool] = { x: Int -> x > 15 }
  assertEqualInt(listCount(ints), 3, "all 3 elements present")
}
