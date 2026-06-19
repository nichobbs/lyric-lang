//! lambda_ffi_delegate_self_test.l — End-to-end integration test
//! for strongly-typed lambda FFI delegates (Epic #1877).
//!
//! Passes a lambda structurally to an FFI delegate parameter
//! System.Predicate`1 on System.Collections.Generic.List`1.RemoveAll
//! to ensure nominal delegate instantiation with zero-thunks.
@test_module
package Lyric.LambdaFfiDelegateSelfTest

import Std.Core
import Std.Testing

extern type List[T] = "System.Collections.Generic.List`1"

extern type Predicate[T] = "System.Predicate`1"

extern type Obj = "System.Object"

@externTarget("System.Collections.Generic.List`1..ctor")
func newList[T](): List[T] = ()

@externTarget("System.Collections.Generic.List`1.Add")
func listAdd[T](xs: in List[T], x: in T): Unit = ()

@externTarget("System.Collections.Generic.List`1.get_Count")
func listCount[T](xs: in List[T]): Int = ()

@externTarget("System.Collections.Generic.List`1.RemoveAll")
func listRemoveAll[T](xs: in List[T], pred: in Predicate[T]): Int = ()

test "passing strongly-typed lambda to Predicate[T] FFI target" {
  val xs: List[Obj] = newList()
  listAdd(xs, 1)
  listAdd(xs, 2)
  listAdd(xs, 3)
  listAdd(xs, 4)
  listAdd(xs, 5)

  // lambda predicate always returns true (removes all)
  val removed = listRemoveAll(xs, { x: Obj -> true })
  assertEqualInt(removed, 5, "removed all elements")
  assertEqualInt(listCount(xs), 0, "0 elements remaining")
}
