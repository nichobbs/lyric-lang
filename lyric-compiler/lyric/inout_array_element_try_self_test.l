//! inout_array_element_try_self_test.l — an array element passed to an
//! `out`/`inout` parameter whose callee panics, caught by `try` (#8180,
//! D179), on `--target dotnet` and `--target jvm`.
//!
//! The element is copied into a temporary and stored back only when the call
//! returns, so a callee that writes the element and then panics leaves the
//! element unchanged.  `--target native` has no `try` (D-N-003: no
//! unwinding), so this file is not run there; the rest of the array-element
//! coverage, native included, is `inout_array_element_self_test.l`.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/inout_array_element_try_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/inout_array_element_try_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.InoutArrayElementTrySelfTest

import Std.Core
import Std.Testing

func setThenPanic(x: inout Int): Unit {
  x = 9
  panic("after the write")
}

func fillThenPanic(r: inout array[2, Int]): Unit {
  r[0] = 9
  panic("after the write")
}

test "a panicking callee leaves the element unchanged" {
  var a: array[2, Int] = [1, 2]
  var caught = false
  try {
    setThenPanic(a[0])
  } catch Bug as b {
    caught = true
  }
  assertTrue(caught, "the panic was caught")
  assertEqualInt(a[0], 1, "nothing was stored back")
}

test "a panicking callee leaves a row unchanged" {
  var m: array[2, array[2, Int]] = [[0, 0], [0, 0]]
  var caught = false
  try {
    fillThenPanic(m[0])
  } catch Bug as b {
    caught = true
  }
  assertTrue(caught, "the panic was caught")
  assertEqualInt(m[0][0], 0, "the row's copy was written, not the row")
}
