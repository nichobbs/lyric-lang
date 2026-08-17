//! synthesized_method_self_test.l — regression tests for compiler-synthesized
//! named method dispatch (#1499, #1507, #6407).
//!
//! Two classes of methods previously failed with "unsupported method" at the
//! call site even though the MethodDef was correctly emitted:
//!
//!   #1499 — protected-type entry methods (Monitor-locked): `c.bump()` panicked
//!            because `addPackageTokens` counted the PMEntry row but never
//!            registered it in `methodTokens`, so `lowerMethodCallMsil` fell
//!            through to the error stub.
//!
//!   #1507 — compiler-synthesized free functions (derives): `p.equals(q)` / `p.show()`
//!            panicked because the synthesized IFuncs live in `funcTokens` (keyed
//!            `cls + "." + memberName`) while `lowerMethodCallMsil` only searched
//!            `methodTokens` (keyed `cls + "/" + memberName`).  The `==` operator
//!            worked because `BEq` has a dedicated `derivedEqualsTokenMsil` path
//!            that reads `funcTokens` directly.
//!
//! Both fixes are in `lyric-compiler/msil/codegen.l`:
//!   — `addPackageTokens` IProtected arm now registers PMEntry/PMFunc in methodTokens.
//!   — `lowerMethodCallMsil` MClass arm now falls back to funcTokens on miss.
//!
//! The JVM counterpart fixes are in `lyric-compiler/jvm/codegen/04_calls.l` and
//! `lyric-compiler/jvm/codegen/06_items.l`:
//!   — `lowerMethodCall` JRef arm now tries the free-function key `cls + "." + memberName`
//!     after the instance-method `cls + "#" + memberName` lookup misses.
//!   — `lowerFunc` now strips the `TypeName.` prefix from synthesised names
//!     (JVMS §4.2.2 forbids `.` in unqualified names), so `Point.equals` is
//!     emitted as method name `equals`; the call site already dispatches on the
//!     plain member name, so both sides agree.
//!
//! §6 covers a third class, #6407 — a protected-type `entry`/`func` that
//! ALSO declares an explicit `self: in <ProtectedType>` receiver param (never
//! required — protected-type members have an implicit receiver, unlike
//! record/impl methods, D037 — but nothing in the grammar forbids it). Both
//! backends double-counted the receiver, emitting a method descriptor with an
//! extra real parameter that no call site ever supplied an argument for:
//!   — JVM: `lowerProtectedMethod` (`jvm/codegen/06_items.l`) now strips a
//!     leading `self` param, matching what `registerInstanceSigErased`
//!     already registers for the call site (`NoSuchMethodError` before).
//!   — MSIL: `addPackageTokens`'s `IProtected` arm and `lowerProtectedMsil`'s
//!     `PMEntry` case (`msil/codegen.l`) now both strip a leading `self` param
//!     before registering/emitting (`InvalidProgramException` before).
//! See docs/03-decision-log.md D-progress-749 for the full root cause.
//!
//! Compile and run via native `lyric test` (both targets):
//!   lyric test lyric-compiler/lyric/synthesized_method_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/synthesized_method_self_test.l
//!
//! No LYRIC_LOAD_COMPILER=1 needed — imports only Std.*.
@test_module
package Lyric.SynthesizedMethodSelfTest

import Std.Core
import Std.Testing

// ─────────────────────────────────────────────────────────────────────────────
// §1. Protected-type entry dispatch (#1499)
// ─────────────────────────────────────────────────────────────────────────────
// A minimal counter wrapped in a protected type.  The `bump` entry is emitted
// with Monitor.Enter/Exit locking by `lowerProtectedMsil`.  Before the fix,
// calling `c.bump()` threw at runtime with "unsupported method 'bump'".
protected type Counter {
  var count: Int = 0
  entry bump(): Unit {
    count = count + 1
  }
  entry get(): Int {
    count
  }
}

test "protected entry: bump increments counter" {
  val c = Counter(count = 0)
  c.bump()
  assertEqualInt(c.get(), 1, "bump once -> count == 1")
}

test "protected entry: multiple bumps accumulate" {
  val c = Counter(count = 0)
  c.bump()
  c.bump()
  c.bump()
  assertEqualInt(c.get(), 3, "bump three times -> count == 3")
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Protected-type helper func dispatch
// ─────────────────────────────────────────────────────────────────────────────
// A PMFunc (non-entry helper) registered alongside an entry.
protected type Accumulator {
  var total: Int = 0
  entry add(n: in Int): Unit {
    total = total + n
  }
  func value(): Int {
    total
  }
}

test "protected func: value() dispatches" {
  val a = Accumulator(total = 0)
  a.add(10)
  a.add(5)
  assertEqualInt(a.value(), 15, "add(10)+add(5) -> 15")
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. @derive(Equals) — explicit .equals() call (#1507)
// ─────────────────────────────────────────────────────────────────────────────
// `p.equals(q)` calls the synthesized free function `Point.equals(self, other)`
// registered in funcTokens.  Before the fix it fell through to the "unsupported
// method" stub.
@derive(Equals)
record Point {
  x: Int
  y: Int
}

test "derive Equals: equals() same values" {
  val p = Point(x = 1, y = 2)
  val q = Point(x = 1, y = 2)
  assertTrue(p.equals(q), "equals: same field values -> true")
}

test "derive Equals: equals() different values" {
  val p = Point(x = 1, y = 2)
  val q = Point(x = 3, y = 4)
  assertFalse(p.equals(q), "equals: different field values -> false")
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. @derive(Show) — explicit .show() call (#1507)
// ─────────────────────────────────────────────────────────────────────────────
@derive(Show)
record Color {
  r: Int
  g: Int
  b: Int
}

test "derive Show: show() returns non-empty string" {
  val c = Color(r = 255, g = 128, b = 0)
  val s = c.show()
  assertTrue(s.length > 0, "show: non-empty result for Color(255, 128, 0)")
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. @derive(Equals) consistency: == agrees with .equals() (#1507)
// ─────────────────────────────────────────────────────────────────────────────
test "derive Equals: == agrees with .equals()" {
  val p = Point(x = 7, y = 9)
  val q = Point(x = 7, y = 9)
  val r = Point(x = 1, y = 2)
  assertTrue(p.equals(q), "equals: same values agrees with ==")
  assertFalse(p.equals(r), "equals: different values agrees with !=")
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. Protected-type entry/func with an explicit `self` receiver param (#6407)
// ─────────────────────────────────────────────────────────────────────────────
// `entry`/`func` bodies inside a `protected type` always have an IMPLICIT
// receiver — bare field names desugar to `EMember(ESelf, name)` and `ESelf`
// always resolves to the instance, regardless of whether an explicit `self`
// param was declared (unlike record/impl methods, D037, where an explicit
// `self: in Type` receiver IS the convention — see docs/49). Nothing in the
// grammar forbids ALSO writing one on a protected-type member (`ParamList`
// accepts any name), so before this fix, declaring `self: in <ProtectedType>`
// as a member's leading param caused both backends to double-count the
// receiver: the emitted method descriptor carried an extra real parameter for
// `self` that no call site (`c.add(m)`) ever supplied an argument for.
//   • JVM: `registerInstanceSig`/`registerInstanceSigErased` already stripped
//     the leading `self` param when registering the call-site descriptor, but
//     `lowerProtectedMethod` (`jvm/codegen/06_items.l`) did not strip it when
//     emitting the actual method — descriptor mismatch, `NoSuchMethodError`.
//   • MSIL: neither the call-site registration (`addPackageTokens`'s
//     `IProtected` arm) nor `lowerProtectedMsil`'s `PMEntry` case stripped
//     `self`, so the declared method arity (2: `self`, `m`) never matched
//     what the call site's explicit argument list actually pushed (1: `m`
//     alone) — malformed IL, `InvalidProgramException`.
// See docs/03-decision-log.md D-progress-749 for the full root cause.
protected type SelfParamCounter {
  var total: Long = 0i64
  entry add(self: in SelfParamCounter, m: Long): Long {
    total = total + m
    total
  }
  entry addTwo(self: in SelfParamCounter, a: Long, b: Long): Long {
    total = total + a + b
    total
  }
  entry reset(self: in SelfParamCounter): Unit {
    total = 0i64
  }
  func peek(self: in SelfParamCounter): Long {
    total
  }
}

test "protected entry with explicit self param + Long param + return (#6407)" {
  val c = SelfParamCounter(total = 0i64)
  val r = c.add(5i64)
  assertEqualLong(r, 5i64, "add(5) -> 5")
}

test "protected entry with explicit self param mutates state across two calls (#6407)" {
  val c = SelfParamCounter(total = 0i64)
  val r1 = c.add(3i64)
  val r2 = c.add(4i64)
  assertEqualLong(r1, 3i64, "first add(3) -> 3")
  assertEqualLong(r2, 7i64, "second add(4) -> 7 (state persists across calls)")
}

test "protected type with multiple explicit-self entries + a no-param entry and func (#6407)" {
  val c = SelfParamCounter(total = 0i64)
  val sum = c.addTwo(1i64, 2i64)
  assertEqualLong(sum, 3i64, "addTwo(1, 2) -> 3")
  assertEqualLong(c.peek(), 3i64, "peek() after addTwo(1, 2) -> 3")
  c.reset()
  assertEqualLong(c.peek(), 0i64, "reset() then peek() -> 0")
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. Protected-type sibling member dispatch (#6483)
// ─────────────────────────────────────────────────────────────────────────────
// One member body calling a sibling member of the SAME protected type — by
// bare name and through explicit `self.` — including an entry calling a
// sibling ENTRY (safe: the Monitor/monitorenter lock wrappers are reentrant
// on both targets).  Before #6483, protected members were never registered
// in the method-sig space, so the bare call was rejected with T0020 at
// check time.
protected type SiblingCounter {
  var total: Int = 0
  entry add(n: in Int): Unit {
    total = total + n
  }
  func doubled(): Int {
    total * 2
  }
  entry bumpAndDouble(n: in Int): Int {
    add(n)
    doubled()
  }
  entry viaSelfDouble(n: in Int): Int {
    self.add(n)
    self.doubled()
  }
  entry addTwice(n: in Int): Unit {
    add(n)
    add(n)
  }
  entry get(): Int {
    total
  }
}

test "protected entry calls sibling func + entry by bare name (#6483)" {
  val c = SiblingCounter(total = 0)
  assertEqualInt(c.bumpAndDouble(5), 10, "add(5) then doubled() -> 10")
}

test "protected entry calls siblings through explicit self (#6483)" {
  val c = SiblingCounter(total = 3)
  assertEqualInt(c.viaSelfDouble(2), 10, "self.add(2) on 3 then self.doubled() -> 10")
}

test "protected entry calls a sibling entry twice: reentrant lock (#6483)" {
  val c = SiblingCounter(total = 0)
  c.addTwice(4)
  assertEqualInt(c.get(), 8, "addTwice(4) -> 8 (entry-from-entry reentrancy)")
}

// #6489-on-protected (#6491 review): when a free function and a sibling
// member share a bare name, the sibling member wins inside a protected
// member body — the same method-wins order records and impls pin in
// self_method_call_self_test.l, on both targets.
func report(): Int {
  1
}

protected type ShadowedCounter {
  var total: Int = 0
  func report(): Int {
    total + 2
  }
  entry viaBareShadowed(): Int {
    report()
  }
  entry viaFree(): Int {
    freeOnlyReport()
  }
}

func freeOnlyReport(): Int {
  41
}

test "protected member bare call shadowed by a sibling member resolves the member (#6491)" {
  val c = ShadowedCounter(total = 5)
  assertEqualInt(c.viaBareShadowed(), 7, "sibling member wins over the same-named free function")
}

test "protected member bare call with no same-named sibling resolves the free function (#6491)" {
  val c = ShadowedCounter(total = 0)
  assertEqualInt(c.viaFree(), 41, "free-function resolution unaffected when no sibling shadows it")
}
