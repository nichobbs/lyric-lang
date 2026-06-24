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

test "passing lambda directly to Action[T] FFI parameter" {
  val xs: List[Int] = List[Int].new()
  xs.Add(10)
  xs.Add(20)
  xs.Add(30)

  // Create a List to track invocations via side effects.
  val invoked: List[Int] = List[Int].new()

  // Pass lambda directly as argument to Action[Int] delegate parameter.
  // The lambda body modifies the captured list to verify invocation.
  xs.ForEach({ item: Int -> invoked.Add(item) })

  // Verify the delegate was actually invoked by checking the side effects.
  assertEqualInt(invoked.Count, 3, "lambda was invoked 3 times via delegate")
}

test "assign lambda with type annotation to Func[Obj, Bool]" {
  val xs: List[Obj] = List[Obj].new()
  xs.Add(1)
  xs.Add(2)
  xs.Add(3)

  // Assign lambda to Func delegate type and invoke it at runtime.
  // With annotation { x: Obj -> ... }, the type-checker sees Obj and accepts it.
  val checker: Func[Obj, Bool] = { x: Obj -> x != null }
  // Invoke the delegate on a list element and verify it returns true.
  val result: Bool = checker(xs[0])
  assertTrue(result, "delegate invoked and returned true for non-null element")
}
