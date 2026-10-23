//! Declares public functions whose bare names collide with the stdlib-kernel
//! intrinsics `newList` and `mapGet`, each with a different arity from the
//! real ones so a call can only reach one body or the other.
package OverrideLib

import Std.Core

pub func newList(n: in Int): Int {
  n * 1000
}

pub func mapGet(n: in Int, m: in Int): Int {
  n * 100 + m
}
