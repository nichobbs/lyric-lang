//! j3_lowering_self_test.l — J3 (docs/44 §5) regression test: codegen dispatch
//! for the lowering capabilities that already existed in `jvm/lowering.l` but
//! were unreachable, plus `defer` and module-level `val` (#2666, epic #2663).
//!
//! Covers, asserting every runtime value on `--target jvm`:
//!   - M-3 opaque   : `Counter(value = …)` construction + `$value()`-accessor
//!                    field read round-trip (dispatch → `lowerOpaqueType`).
//!   - M-3 protected: record-shaped class with field-args ctor + lock-wrapped
//!                    instance entries; bare-name field reads/writes resolve
//!                    through `selfClass`, entry calls resolve precisely.
//!   - M-3 wire     : `AppWire.bootstrap()` runs the DI bindings;
//!                    `AppWire.svc()` returns the exposed singleton.
//!   - M-2 defer    : the deferred block runs on a normal fall-off AND on an
//!                    early `return`, on every path, without clobbering the
//!                    captured return value.
//!   - m-2 module-`val`: a module-level `val` is a `static final` field read via
//!                    `getstatic` from any function in the package.
//!
//! Run by native `lyric test --target jvm`, which compiles this module
//! in-process through the self-hosted `Jvm.Bridge` (`compileToJarBundled`) and
//! runs it under `java`.  Imports only `Std.*`.
@test_module
package Jvm.J3LoweringSelfTest

import Std.Core
import Std.Testing

// ── m-2: module-level val ─────────────────────────────────────────────────────
val theAnswer: Int = 42
val greeting: String = "hello"

// ── M-3: opaque type ──────────────────────────────────────────────────────────
opaque type Amount {
  cents: Int
}

func amountCents(a: in Amount): Int {
  return a.cents
}

// ── M-3: protected type ───────────────────────────────────────────────────────
protected type Counter {
  var count: Int

  entry increment() {
    count = count + 1
  }

  entry add(n: in Int) {
    count = count + n
  }

  entry get(): Int {
    return count
  }
}

// ── M-3: wire block ───────────────────────────────────────────────────────────
record Widget {
  size: Int
}

wire WidgetWire {
  singleton widget: Widget = Widget(size = 17)
  expose widget
}

// ── M-2: defer ────────────────────────────────────────────────────────────────
// Returns the value captured at the (early or normal) return point; the deferred
// block bumps the observer counter on whichever exit path is taken (it must run
// exactly once and must not change the already-captured return value).
func deferReturns(early: in Bool, obs: in Counter): Int {
  var x = 1
  defer {
    obs.increment()
  }
  x = x + 1
  if early {
    return x
  }
  x = x + 10
  return x
}

// ── Tests ─────────────────────────────────────────────────────────────────────
test "module-level val is read via getstatic" {
  assertEqualInt(theAnswer, 42, "theAnswer")
  assertEqual(greeting, "hello", "greeting")
}

test "opaque type round-trips construction and field read" {
  val a = Amount(cents = 250)
  assertEqualInt(a.cents, 250, "direct field read")
  assertEqualInt(amountCents(a), 250, "field read via accessor function")
}

test "protected type entries mutate and read state" {
  val c = Counter(count = 0)
  c.increment()
  c.increment()
  c.increment()
  assertEqualInt(c.get(), 3, "three increments")
  c.add(10)
  assertEqualInt(c.get(), 13, "add 10")
}

test "wire block resolves the exposed singleton" {
  WidgetWire.bootstrap()
  val w = WidgetWire.widget()
  assertEqualInt(w.size, 17, "exposed widget size")
}

test "defer runs on a normal fall-off exit" {
  val obs = Counter(count = 0)
  val r = deferReturns(false, obs)
  assertEqualInt(r, 12, "normal-path return value (1+1+10)")
  assertEqualInt(obs.get(), 1, "deferred block ran once on fall-off")
}

test "defer runs on an early return exit" {
  val obs = Counter(count = 0)
  val r = deferReturns(true, obs)
  assertEqualInt(r, 2, "early-return value (1+1)")
  assertEqualInt(obs.get(), 1, "deferred block ran once on early return")
}
