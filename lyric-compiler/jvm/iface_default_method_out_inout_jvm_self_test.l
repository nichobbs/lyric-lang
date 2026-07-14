//! iface_default_method_out_inout_jvm_self_test.l — JVM regression test for
//! #3604: interface default-method (`IMFunc`) dispatch with `out`/`inout`
//! params through an interface-typed binding.
//!
//! Empirically confirmed via a standalone repro (published `lyric` 0.4.26,
//! since this sandbox cannot build `./bin/lyric` from source) that this was
//! actually TWO distinct bugs, both triggered by dispatching an interface
//! default method through an interface-typed binding (`val a: Adder = c;
//! a.m(...)`), not just the `out`/`inout` combination the issue's title
//! names:
//!
//!   1. A PLAIN (no `out`/`inout`) default method call failed with
//!      `IncompatibleClassChangeError: Expected instance not static method
//!      'String Pkg.Iface.method()'` — `codegenPackageWithSigsSeeded`'s
//!      `IInterface`/`IMFunc` arm lowered a default method's body via
//!      `lowerFunc` (the free-function path: `flags = 0x0009` i.e.
//!      `ACC_PUBLIC | ACC_STATIC`, `setupStaticParamSlotsAndHolders` with
//!      slot 0 = the first parameter), while every call site dispatches it
//!      via `invokeinterface` (`registerIfaceSig` marks it `isIface = true`)
//!      — `invokeinterface` requires a non-static instance method.  Fixed by
//!      routing `IMFunc` through `lowerImplMethod` instead (same non-static
//!      instance-method codegen — `flags = 0x0001`, slot 0 = `this`,
//!      `setupInstanceParamSlotsAndHolders` — already used for `impl`
//!      methods on a concrete class; an interface's own default method is
//!      the same shape with the interface as the "target class").
//!
//!   2. An `out`/`inout`-parameter default method call failed with
//!      `IncompatibleClassChangeError: Found interface Pkg.Iface, but class
//!      was expected` — `Jvm.Codegen.lowerVirtualCallWithHolders` (the
//!      holder-argument call-site lowering `04_calls.l`) hard-coded
//!      `invokevirtual` unconditionally, never consulting `sig.isIface` the
//!      way the non-holder call path already does.  Every `out`/`inout`
//!      call routes through this holder path BEFORE the non-holder path's
//!      `isIface` check ever runs, so this bug applied equally to an
//!      abstract interface method overridden via `impl` (not just an
//!      `IMFunc` default body) whenever dispatched with `out`/`inout`
//!      params through an interface-typed receiver — the pre-existing
//!      `out_inout_instance_jvm_self_test.l` never caught this because it
//!      only dispatches through the CONCRETE record type, never through the
//!      interface type.  Fixed by making `lowerVirtualCallWithHolders`
//!      branch on `sig.isIface` exactly like the non-holder path (emitting
//!      `invokeinterface` with `argCount = 1 + jvmArgSlotCount(sig.params)`).
//!
//! Both cases below dispatch through an interface-typed `val` binding
//! (`val a: Adder = Counter(...)`) — the shape from the original repro — to
//! pin both fixes.  A third case covers an ABSTRACT interface method with
//! `out`/`inout` params overridden via `impl` (bug #2 without bug #1), and a
//! fourth covers a plain default method with no `out`/`inout` at all (bug #1
//! without bug #2), so the two fixes are independently exercised.
//!
//! Run by native `lyric test --target jvm`, which compiles this module
//! in-process through the self-hosted `Jvm.Bridge` (`compileToJarBundled`)
//! and runs it under `java`.  Imports only `Std.*`.
@test_module
package Jvm.IfaceDefaultMethodOutInoutSelfTest

import Std.Core
import Std.Testing

// ── Case 1 & 2: a default method (`IMFunc`) with `out`/`inout` params,
// dispatched through an interface-typed binding — the exact repro shape. ──
interface Adder {
  func label(): String
  func addTo(n: in Int, acc: inout Int): Unit {
    acc = acc + n
  }
  func writeDoubled(n: in Int, dst: out Int): Unit {
    dst = n * 2
  }
}

record Counter {
  tag: String
}

impl Adder for Counter {
  func label(): String {
    self.tag
  }
}

test "interface default method with inout param dispatches through an interface-typed binding" {
  val c = Counter(tag = "x")
  val a: Adder = c
  var acc: Int = 5
  a.addTo(3, acc)
  assertEqualInt(acc, 8, "acc should be 5 + 3")
}

test "interface default method with out param dispatches through an interface-typed binding" {
  val c = Counter(tag = "y")
  val a: Adder = c
  var dst: Int = 0
  a.writeDoubled(7, dst)
  assertEqualInt(dst, 14, "dst should be 7*2")
}

// ── Case 3: an ABSTRACT interface method (not a default body) with
// `out`/`inout` params, overridden via `impl`, dispatched through an
// interface-typed binding — isolates bug #2 (lowerVirtualCallWithHolders)
// from bug #1 (IMFunc codegen), since no default-method body is involved. ──
interface Scaler {
  func scaleInto(factor: in Int, acc: inout Int): Unit
}

record Doubler {
  base: Int
}

impl Scaler for Doubler {
  func scaleInto(factor: in Int, acc: inout Int): Unit {
    acc = acc * factor + base
  }
}

test "abstract interface method with inout param dispatches through an interface-typed binding" {
  val d = Doubler(base = 1)
  val s: Scaler = d
  var acc: Int = 10
  s.scaleInto(3, acc)
  assertEqualInt(acc, 31, "acc should be 10*3 + 1")
}

// ── Case 4: a default method with NO out/inout params — isolates bug #1
// (IMFunc static-vs-instance codegen) from bug #2 (holder call-site opcode),
// since no holder-mode parameter is involved. ──
interface Greeter {
  func label(): String
  func greet(): String {
    "hello " + label()
  }
}

record Person {
  name: String
}

impl Greeter for Person {
  func label(): String {
    self.name
  }
}

test "plain interface default method (no holder params) dispatches through an interface-typed binding" {
  val p = Person(name = "Ada")
  val g: Greeter = p
  assertEqual(g.greet(), "hello Ada", "greet should combine the literal with label()")
}
