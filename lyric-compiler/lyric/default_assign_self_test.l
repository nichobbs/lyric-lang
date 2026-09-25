//! `default()` assigned (not bound) into a primitive-typed target.
//!
//! A bare `default()` lowers to an erased `aconst_null` on the JVM. The
//! `val`/`var` initializer path already pushed the primitive zero, but an
//! assignment did not, so `value = default()` into an `out Int` parameter
//! unboxed the null and threw NullPointerException. Std.Json's field readers
//! hit this on every miss (#7251). MSIL was already correct; this runs on
//! both targets.
@test_module
package DefaultAssignSelfTest

import Std.Core
import Std.Testing

func outInt(value: out Int): Bool {
  value = default()
  false
}

func outLong(value: out Long): Bool {
  value = default()
  false
}

func outDouble(value: out Double): Bool {
  value = default()
  false
}

func outBool(value: out Bool): Bool {
  value = default()
  false
}

func outString(value: out String): Bool {
  value = default()
  false
}

record Counter {
  var n: Int
}

test "default() into out parameters of each primitive type" {
  var i = 5
  val _ = outInt(i)
  assertTrue(i == 0, "Int zero")
  var l = 5i64
  val _ = outLong(l)
  assertTrue(l == 0i64, "Long zero")
  var d = 5.0
  val _ = outDouble(d)
  assertTrue(d == 0.0, "Double zero")
  var b = true
  val _ = outBool(b)
  assertTrue(not b, "Bool false")
}

test "default() into a reference-typed out parameter still works" {
  var s = "x"
  val _ = outString(s)
  assertTrue(true, "no crash for a reference type")
}

test "default() reassigned into a local and a record field" {
  var n = 7
  n = default()
  assertTrue(n == 0, "local reset to zero")
  val c = Counter(n = 9)
  c.n = default()
  assertTrue(c.n == 0, "field reset to zero")
}

test "default() into a var captured by a closure" {
  var n = 3
  val reset = { -> n = default() }
  reset()
  assertTrue(n == 0, "captured var reset to zero")
}
