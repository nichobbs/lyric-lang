//! record_method_jvm_self_test.l — executable regression test for record
//! instance-method dispatch on the self-hosted JVM backend (#2865, epic #2663).
//!
//! Before this slice a record's instance method (`RMFunc`, declared inside the
//! `record` body) was emitted as a STATIC method on the record's class
//! (`lowerFunc`, flags 0x0009), while a call `rec.method(args)` lowered to
//! `invokevirtual` (J3 `<class>#<method>` registry) — a mismatch the JVM rejects
//! at link time:
//!   "java.lang.VerifyError: ... Expecting non-static method ...".
//! Record *construction*, *field reads*, and *accessors* already worked; only
//! instance-method dispatch was broken, which blocked the very common
//! records-with-methods pattern.
//!
//! The fix emits each record `RMFunc` as a true non-static instance method
//! (slot 0 = `this`, flags 0x0001) via `lowerRecordMethod`, mirroring how
//! protected-type entries and `impl` methods are lowered (those already work).
//! `self.field` references inside the body resolve through `this` (`getfield`),
//! and generic type params erase to `Object` so the emitted method byte-matches
//! the registered `invokevirtual` descriptor (docs/44 J4).
//!
//! This module asserts the runtime values, under `java`, of:
//!   • a record method computing a value from its own fields (`self.field`);
//!   • a record method that takes an argument and combines it with a field;
//!   • a record method whose field is used inside a larger expression
//!     (field read through `this`);
//!   • a record method returning `Result[Int, String]` (drives J4 erased
//!     generics through an instance method: payload boxing + checkcast/unbox).
//!
//! Run in CI via the native `lyric test --target jvm`: the runnable program
//! synthesised from the `test` blocks is compiled IN-PROCESS through the
//! self-hosted `Jvm.Bridge` (`compileToJarBundled` bundles the user package plus
//! its transitive stdlib-import closure into one runnable JAR), run under `java`,
//! and every embedded assertion is checked.  Imports only `Std.*` (Std.Core
//! gives `Result`), so no `LYRIC_LOAD_COMPILER=1` is needed.
//!
//!   lyric test --target jvm lyric-compiler/jvm/record_method_jvm_self_test.l
@test_module
package Lyric.RecordMethodJvmSelfTest

import Std.Core
import Std.Testing

// A record with instance methods (declared inside the record body) reading its
// own field through `self`.
record Counter {
  n: Int
  func get(): Int {
    return self.n
  }
  func inc(): Int {
    return self.n + 1
  }
}

// A record method that takes argument(s) and combines them with a field.
record Accumulator {
  base: Int
  func add(x: in Int): Int {
    return self.base + x
  }
  func fma(a: in Int, b: in Int): Int {
    return self.base + a * b
  }
}

// A record whose method reads its field(s) inside a larger expression.
record Rect {
  width: Int
  height: Int
  func area(): Int {
    return self.width * self.height
  }
  func perimeter(): Int {
    return 2 * (self.width + self.height)
  }
}

// A record method returning a generic payload (`Result[Int, String]`),
// exercising J4 erased generics through an instance method.  The body is an
// `if/else` *tail expression* (no explicit `return` in the branches): an
// explicit-`return`-in-both-branches body trips an orthogonal, pre-existing
// JVM control-flow bug (`endsWithReturn` does not see returns nested inside an
// `if`/`else`, so `lowerFunc`/`lowerProtectedMethod`/`lowerRecordMethod` append
// a stray void `return` after a non-void body) — that gap is unrelated to
// record-method dispatch and reproduces identically for a top-level `func`.
record SafeDivider {
  numerator: Int
  func divide(d: in Int): Result[Int, String] {
    if d == 0 {
      Err("div by zero")
    } else {
      Ok(self.numerator / d)
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Record method returning a value computed from its own field.
// ─────────────────────────────────────────────────────────────────────────────
test "record method reads its own field via self" {
  val c = Counter(n = 41)
  assertEqualInt(c.get(), 41, "Counter(41).get() == 41")
}

test "record method computes from its own field" {
  val c = Counter(n = 10)
  assertEqualInt(c.inc(), 11, "Counter(10).inc() == 11")
}

// ─────────────────────────────────────────────────────────────────────────────
// Record method taking arguments, combining with a field.
// ─────────────────────────────────────────────────────────────────────────────
test "record method combines argument with field" {
  val a = Accumulator(base = 100)
  assertEqualInt(a.add(23), 123, "Accumulator(100).add(23) == 123")
}

test "record method with two arguments and a field" {
  val a = Accumulator(base = 5)
  assertEqualInt(a.fma(6, 7), 47, "Accumulator(5).fma(6, 7) == 5 + 6*7 == 47")
}

// ─────────────────────────────────────────────────────────────────────────────
// Record method whose field is read inside a larger expression.
// ─────────────────────────────────────────────────────────────────────────────
test "record method reads field inside an expression" {
  val r = Rect(width = 6, height = 7)
  assertEqualInt(r.area(), 42, "Rect(6, 7).area() == 42")
}

test "record method reads two fields inside an expression" {
  val r = Rect(width = 3, height = 4)
  assertEqualInt(r.perimeter(), 14, "Rect(3, 4).perimeter() == 2*(3+4) == 14")
}

// ─────────────────────────────────────────────────────────────────────────────
// Record method returning Result[Int, String] — J4 erased generics through an
// instance method (payload boxing on construction + checkcast/unbox on extract).
// ─────────────────────────────────────────────────────────────────────────────
test "record method returning Result Ok" {
  val d = SafeDivider(numerator = 100)
  val r = d.divide(4)
  val v = match r { case Ok(x) -> x; case Err(_) -> -1 }
  assertEqualInt(v, 25, "SafeDivider(100).divide(4) -> Ok(25)")
}

test "record method returning Result Err" {
  val d = SafeDivider(numerator = 100)
  val r = d.divide(0)
  val s = match r { case Ok(_) -> "no"; case Err(m) -> m }
  assertEqual(s, "div by zero", "SafeDivider(100).divide(0) -> Err(div by zero)")
}

// ─────────────────────────────────────────────────────────────────────────────
// Generic record method: typeParams erasure path (#2873).
// The `get()` return type is `T`, erased to `Object` in the method descriptor;
// `lowerRecordMethod` / `registerInstanceSigErased` must agree on the erased
// signature, and `getfield this.value` must read through the Object-typed field.
// ─────────────────────────────────────────────────────────────────────────────
record ValHolder[T] {
  value: T
  func get(): T {
    return self.value
  }
}

test "generic record method returns its T-typed field (Int instantiation)" {
  val h = ValHolder(value = 42)
  val v = h.get()
  assertEqualInt(v, 42, "ValHolder[Int](42).get() == 42")
}

test "generic record method returns its T-typed field (String instantiation)" {
  val h = ValHolder(value = "hello")
  val s = h.get()
  assertEqual(s, "hello", "ValHolder[String](hello).get() == hello")
}

// ─────────────────────────────────────────────────────────────────────────────
// Intra-record self.method() call (#2875): one record method calls another
// method on `self`, exercising the `selfClass` context for call-site resolution.
// ─────────────────────────────────────────────────────────────────────────────
record Chain {
  n: Int
  func step(): Int {
    return self.n + 1
  }
  func jump(): Int {
    return self.step() + 1
  }
}

test "record method calls another method on self (intra-record dispatch)" {
  val c = Chain(n = 10)
  assertEqualInt(c.step(), 11, "Chain(10).step() == 11")
  assertEqualInt(c.jump(), 12, "Chain(10).jump() == step() + 1 == 12")
}
