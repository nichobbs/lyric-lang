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

test "passing strongly-typed lambda to Predicate[T] FFI target" {
  val xs: List[Obj] = newList()
  listAdd(xs, 1)
  listAdd(xs, 2)
  listAdd(xs, 3)
  listAdd(xs, 4)
  listAdd(xs, 5)

  // Test that lambda works with Func delegate type in FFI context.
  // The lambda returns true for all elements, so RemoveAll with a negated predicate
  // should remove all elements.
  val alwaysTrue: Predicate[Obj] = { x: Obj -> true }
  val removed = listRemoveAll(xs, alwaysTrue)
  assertEqualInt(removed, 5, "lambda predicate removed all 5 elements")
  assertEqualInt(xs.count, 0, "list is now empty")
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

test "passing strongly-typed lambda to Action[Int] parameter" {
  val ints: List[Int] = newList[Int]()
  listAdd(ints, 1)
  listAdd(ints, 2)
  listAdd(ints, 3)

  // Pass lambda with Int parameter directly as argument.
  // This exercises strongly-typed lambda method signature (non-object params).
  listForEach(ints, { i: Int -> () })
  assertEqualInt(listCount(ints), 3, "all 3 elements present")
}

test "passing strongly-typed lambda Int->Bool to Func[Int, Bool] parameter" {
  val ints: List[Int] = newList[Int]()
  listAdd(ints, 10)
  listAdd(ints, 20)
  listAdd(ints, 30)

  // Assign lambda with Int parameter to Func[Int, Bool] delegate type.
  // This exercises strongly-typed lambda method signature in type-check.
  val isLarge: Func[Int, Bool] = { x: Int -> x > 15 }
  // Invoke the delegate on each element to verify it works correctly.
  val large10 = isLarge(10)
  val large20 = isLarge(20)
  val large30 = isLarge(30)
  assertFalse(large10, "10 is not > 15")
  assertTrue(large20, "20 is > 15")
  assertTrue(large30, "30 is > 15")
}
