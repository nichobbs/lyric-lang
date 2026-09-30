//! An `inout Self` parameter of an interface method, on both targets (#7783).
//!
//! On dotnet the interface slot erases `Self`, so the parameter is `object&`
//! in the signature while the impl body and its callers hold the concrete
//! class.  The body loaded the pointer's `object` without narrowing it before
//! a field store, and a caller passed its `Acc`-typed local's address where
//! `object&` is declared — both unverifiable, and managed pointers are
//! invariant.  The body now narrows each load through the pointer, and a
//! caller whose variable (or field, or forwarded `inout` parameter) has a
//! different type passes a temp of the parameter's type and copies it back
//! after the call, which is how the JVM passes every `out`/`inout` argument.
//! Runs on dotnet and JVM; the dotnet test DLL is verified by
//! `scripts/ilverify-selfhosted.sh` phase 4.
@test_module
package InoutSelfParamSelfTest

import Std.Core
import Std.Testing

record Acc {
  var n: Int
}

record Pair {
  var a: Acc
}

interface Merger {
  func merge(self: in Self, other: inout Self): Int
  func replace(self: in Self, other: inout Self): Int
}

func doubleIt(x: inout Acc): Unit {
  x.n = x.n * 2
}

impl Merger for Acc {
  func merge(self: in Self, other: inout Self): Int {
    other.n = other.n + self.n
    other.n
  }

  func replace(self: in Self, other: inout Self): Int {
    other = Acc(n = self.n * 100)
    doubleIt(other)
    other.n
  }
}

test "a field write through inout Self reaches the caller's variable" {
  val x = Acc(n = 5)
  var y = Acc(n = 7)
  assertEqualInt(x.merge(y), 12, "the body sees the merged value")
  assertEqualInt(y.n, 12, "the caller's record was mutated")
}

test "reassigning inout Self rebinds the caller's variable" {
  val x = Acc(n = 5)
  var y = Acc(n = 7)
  val before = y
  assertEqualInt(x.replace(y), 1000, "the new record, doubled through a forwarded inout")
  assertEqualInt(y.n, 1000, "the caller's variable holds the new record")
  assertEqualInt(before.n, 7, "the old record was not mutated")
}

test "a record field passed as inout Self is rebound too" {
  val x = Acc(n = 3)
  val p = Pair(a = Acc(n = 1))
  assertEqualInt(x.replace(p.a), 600, "the field's new record")
  assertEqualInt(p.a.n, 600, "the field now holds the new record")
}
