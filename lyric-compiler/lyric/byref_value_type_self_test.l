//! byref_value_type_self_test.l — runtime regression test for `out`/`inout`
//! parameters whose pointee is a value type with no `ldind`/`stind` form
//! (#8206).
//!
//! On `--target dotnet` an assignment to such a parameter stored through the
//! managed pointer with `stind.ref`, and a read loaded with `ldind.ref`.  Both
//! are only defined for object references: a `Std.Time.Instant` (a
//! `System.DateTime`) parameter failed with `InvalidProgramException`, and a
//! generic record's `inout T` parameter instantiated at `Int` or `Double`
//! wrote a pointer-sized value into the caller's variable.  A struct pointee
//! now uses `ldobj`/`stobj`, and so does a type-parameter pointee, which is
//! correct whatever the instantiation.  The JVM and native backends were
//! already correct; the test runs on all three targets.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/byref_value_type_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/byref_value_type_self_test.l
//!   lyric test --target native lyric-compiler/lyric/byref_value_type_self_test.l
//!
//! `scripts/ilverify-selfhosted.sh` verifies the dotnet test DLL.  The extern
//! BCL struct cases (`System.TimeSpan`) are dotnet-only and live in
//! `byref_extern_struct_dotnet_self_test.l`.
@test_module
package Lyric.ByrefValueTypeSelfTest

import Std.Core
import Std.Testing
import Std.Time

record Box[T] {
  v: T

  func take(self: in Box[T], x: inout T): Unit {
    x = self.v
  }

  func give(self: in Box[T], x: out T): Unit {
    x = self.v
  }
}

func setInstant(i: inout Instant, ms: in Long): Unit {
  i = fromEpochMillis(ms)
}

func outInstant(i: out Instant): Unit {
  i = fromEpochMillis(7000i64)
}

// Reads the pointee before writing it, so the load through the pointer is
// exercised as well as the store.
func laterOf(i: inout Instant, other: in Instant): Unit {
  if instantAfter(other, i) {
    i = other
  }
}

// A `Duration` (a `System.TimeSpan` on dotnet) read and written through the
// pointer, with a compound-style read-modify-write.
func extend(d: inout Duration, by: in Duration): Unit {
  d = addDurations(d, by)
}

// Forwards its own `inout` parameter, whose slot already holds the pointer.
func forwardInstant(i: inout Instant): Unit {
  setInstant(i, 9000i64)
}

func setOpt(o: inout Option[Int], v: in Int): Unit {
  o = Some(value = v)
}

func bumpOpt(o: inout Option[Int]): Unit {
  o = match o { case Some(v) -> Some(value = v + 1); case None -> Some(value = 0) }
}

test "inout Instant is written through the pointer" {
  var i = fromEpochMillis(1000i64)
  setInstant(i, 5000i64)
  assertTrue(instantEquals(i, fromEpochMillis(5000i64)), "setInstant")
}

test "out Instant is written through the pointer" {
  var i = fromEpochMillis(0i64)
  outInstant(i)
  assertTrue(instantEquals(i, fromEpochMillis(7000i64)), "outInstant")
}

test "inout Instant is read and written through the pointer" {
  var i = fromEpochMillis(3000i64)
  laterOf(i, fromEpochMillis(2000i64))
  assertTrue(instantEquals(i, fromEpochMillis(3000i64)), "laterOf keeps the later value")
  laterOf(i, fromEpochMillis(4000i64))
  assertTrue(instantEquals(i, fromEpochMillis(4000i64)), "laterOf takes the later value")
}

test "inout Duration is read and written through the pointer" {
  var d = millis(250.0)
  extend(d, seconds(1.0))
  extend(d, millis(5.0))
  assertTrue(totalMillis(d) == 1255.0, "extend twice")
}

test "a forwarded inout Instant reaches the caller" {
  var i = fromEpochMillis(1i64)
  forwardInstant(i)
  assertTrue(instantEquals(i, fromEpochMillis(9000i64)), "forwardInstant")
}

test "a generic record's inout T at Int" {
  val b = Box(v = 7)
  var n = 1
  b.take(n)
  assertEqualInt(n, 7, "Box[Int].take")
  var m = 0
  Box(v = 42).give(m)
  assertEqualInt(m, 42, "Box[Int].give")
}

test "a generic record's inout T at Long and Double" {
  var l = 0i64
  Box(v = 5000000000i64).take(l)
  assertEqualLong(l, 5000000000i64, "Box[Long].take")
  var d = 0.0
  Box(v = 2.5).take(d)
  assertTrue(d == 2.5, "Box[Double].take")
}

test "a generic record's inout T at a struct and at a reference type" {
  var i = fromEpochMillis(0i64)
  Box(v = fromEpochMillis(6000i64)).take(i)
  assertTrue(instantEquals(i, fromEpochMillis(6000i64)), "Box[Instant].take")
  var s = "before"
  Box(v = "after").take(s)
  assertEqual(s, "after", "Box[String].take")
}

test "inout Option[Int]" {
  var o: Option[Int] = None
  setOpt(o, 5)
  bumpOpt(o)
  val got = match o { case Some(v) -> v; case None -> 0 }
  assertEqualInt(got, 6, "setOpt then bumpOpt")
}
