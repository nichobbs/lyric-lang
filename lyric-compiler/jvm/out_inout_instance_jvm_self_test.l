//! out_inout_instance_jvm_self_test.l — JVM regression test for `out`/`inout`
//! parameters on instance and interface methods (#1763).
//!
//! The free-function holder lowering (`lowerStaticCallWithHolders` /
//! `setupStaticParamSlotsAndHolders`) was tested in `out_inout_jvm_self_test.l`.
//! This file extends coverage to the three instance-method shapes:
//!
//!   • `impl T for X` methods — lowered by `lowerImplMethod`, dispatched via
//!     `invokevirtual` through the `<targetClass>#<method>` registry.
//!   • Record methods (`RMFunc`) — lowered by `lowerRecordMethod`, same registry.
//!   • Protected-type entries — lowered by `lowerProtectedMethod`, same registry.
//!
//! Also guards that bare sibling calls (`m(args)`) and explicit `self.m(args)`
//! calls inside an impl body route through `lowerVirtualCallWithHolders` when the
//! callee has holder params.
//!
//! Run via the native test runner on the JVM target:
//!
//!   lyric test --target jvm lyric-compiler/jvm/out_inout_instance_jvm_self_test.l
@test_module
package Lyric.OutInoutInstanceJvmSelfTest

import Std.Core
import Std.Testing

// ── impl method cases ─────────────────────────────────────────────────────────
interface Adder {
  func addTo(n: in Int, acc: inout Int): Unit
  func writeDouble(n: in Int, dst: out Int): Unit
}

record Counter {
  start: Int
}

impl Adder for Counter {
  func addTo(n: in Int, acc: inout Int): Unit {
    acc = acc + n + start
  }
  func writeDouble(n: in Int, dst: out Int): Unit {
    dst = n * 2 + start
  }
}

// Bare sibling call inside an impl body that has an out param.
interface Writer {
  func writeRaw(dst: out Int): Unit
  func writeVia(dst: out Int): Unit
}

record SimpleWriter {
  value: Int
}

impl Writer for SimpleWriter {
  func writeRaw(dst: out Int): Unit {
    dst = value
  }
  // bare sibling call: writeRaw(dst) — exercises lowerVirtualCallWithHolders
  // through the selfClass + "#" + funcName path in lowerGeneralStaticCall.
  func writeVia(dst: out Int): Unit {
    writeRaw(dst)
  }
}

// self.m(out arg) call inside an impl body.
interface SelfCaller {
  func baseOut(dst: out String): Unit
  func viaSelf(dst: out String): Unit
}

record SelfImpl {
  prefix: String
}

impl SelfCaller for SelfImpl {
  func baseOut(dst: out String): Unit {
    dst = prefix + "!"
  }
  func viaSelf(dst: out String): Unit {
    self.baseOut(dst)
  }
}

// ── record method cases ───────────────────────────────────────────────────────
record Vec2 {
  x: Int
  y: Int
  func getCoords(ox: out Int, oy: out Int): Unit {
    ox = x
    oy = y
  }
  func scale(factor: in Int, rx: inout Int, ry: inout Int): Unit {
    rx = rx * factor + x
    ry = ry * factor + y
  }
}

// ── protected-type entry case ─────────────────────────────────────────────────
protected type Accumulator {
  var total: Int
  entry drain(dst: out Int) {
    dst = total
    total = 0
  }
  entry add(n: in Int) {
    total = total + n
  }
  entry getTotal(): Int {
    return total
  }
}

// ── tests ─────────────────────────────────────────────────────────────────────
test "impl inout param: addTo accumulates via invokevirtual" {
  val c = Counter(start = 10)
  var acc: Int = 0
  c.addTo(5, acc)
  assertEqualInt(acc, 15, "acc should be 0 + 5 + 10")
  c.addTo(3, acc)
  assertEqualInt(acc, 28, "acc should be 15 + 3 + 10")
}

test "impl out param: writeDouble writes via invokevirtual" {
  val c = Counter(start = 1)
  var dst: Int = 0
  c.writeDouble(7, dst)
  assertEqualInt(dst, 15, "dst should be 7*2 + 1")
}

test "bare sibling call with out param inside impl body" {
  val w = SimpleWriter(value = 99)
  var dst: Int = 0
  w.writeVia(dst)
  assertEqualInt(dst, 99, "writeVia should forward via bare writeRaw")
}

test "self.m(out String arg) call inside impl body dispatches correctly" {
  val s = SelfImpl(prefix = "hello")
  var dst: String = ""
  s.viaSelf(dst)
  assertEqual(dst, "hello!", "viaSelf should forward via self.baseOut")
}

test "record method with multiple out params writes both" {
  val v = Vec2(x = 3, y = 7)
  var ox: Int = 0
  var oy: Int = 0
  v.getCoords(ox, oy)
  assertEqualInt(ox, 3, "ox should be v.x")
  assertEqualInt(oy, 7, "oy should be v.y")
}

test "record method with inout params reads and writes back" {
  val v = Vec2(x = 1, y = 2)
  var rx: Int = 10
  var ry: Int = 20
  v.scale(3, rx, ry)
  assertEqualInt(rx, 31, "rx should be 10*3 + 1")
  assertEqualInt(ry, 62, "ry should be 20*3 + 2")
}

test "protected-type entry with out param drains value to caller" {
  val a = Accumulator(total = 0)
  a.add(5)
  a.add(7)
  var dst: Int = 0
  a.drain(dst)
  assertEqualInt(dst, 12, "drain should write total to out param")
  assertEqualInt(a.getTotal(), 0, "drain should reset total to 0")
}
