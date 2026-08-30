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
//!     generics through an instance method: payload boxing + checkcast/unbox);
//!   • a 17-field record constructor (#6089: the synthesized ctor's hardcoded
//!     `maxStack = 16` overflowed the operand stack for wide records).
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

// ─────────────────────────────────────────────────────────────────────────────
// Wide record constructor (#6089): a record with 15+ fields tripped the
// top-level `LFunc`'s hardcoded `maxStack = 16` (every field push plus the
// receiver dup/new overruns 16 slots), producing "Operand stack overflow"
// VerifyError at class-load time.  `lowerFuncImpl` (lowering.l) now takes
// the larger of the caller-supplied floor and the inferred `asm.peakStack`,
// so the flat 16 floor grows to cover a genuinely wider stack instead of
// capping it.
// ─────────────────────────────────────────────────────────────────────────────
record Wide17 {
  f1: Int
  f2: Int
  f3: Int
  f4: Int
  f5: Int
  f6: Int
  f7: Int
  f8: Int
  f9: Int
  f10: Int
  f11: Int
  f12: Int
  f13: Int
  f14: Int
  f15: Int
  f16: Int
  f17: Int
}

test "17-field record constructor does not overflow the operand stack" {
  val w = Wide17(
    f1 = 1,
    f2 = 2,
    f3 = 3,
    f4 = 4,
    f5 = 5,
    f6 = 6,
    f7 = 7,
    f8 = 8,
    f9 = 9,
    f10 = 10,
    f11 = 11,
    f12 = 12,
    f13 = 13,
    f14 = 14,
    f15 = 15,
    f16 = 16,
    f17 = 17
  )
  assertEqualInt(w.f1, 1, "Wide17.f1 == 1")
  assertEqualInt(w.f9, 9, "Wide17.f9 == 9")
  assertEqualInt(w.f17, 17, "Wide17.f17 == 17")
}

// ─────────────────────────────────────────────────────────────────────────────
// #6660: a record method's own parameter typed as a generic instantiation
// whose type ARGUMENT is the ENCLOSING record's own unresolved type
// parameter (`Box[T]` on `record Extractor[T] { ... }`) is exactly the shape
// `recordParamGenericArgs` must not mistake for a real same-package type
// name.  Unlike a top-level generic `func`, `Lyric.Mono` never drops or
// specialises a record method's `T` — the JVM backend compiles it ONCE, with
// `T` erased to `Object` at runtime — so this method's own params are
// compiled with `T` still literally present in the AST.  `Box` is a
// USER-DEFINED generic union (not `Std.Core.Result`, whose cases the
// backend resolves through a separate, already-guarded kernel path that
// doesn't reach `recordParamGenericArgs` at all and so cannot exercise this
// fix) — `match b { case Full(v) -> ... }` below resolves `v`'s checkcast
// type through the ordinary `ctx.varGenericArgs` / `resolveConcreteTypeExpr`
// path every user generic goes through. Before this fix,
// `recordParamGenericArgs` had no guard comparing a generic arg name
// against the method's own `typeParams` (only `recordDeclaredElemType`, its
// sibling in the same param-setup loop, had one), so it registered a
// PHANTOM class guess (`<pkg>/T`) for `b`'s `ctx.varGenericArgs` entry; the
// `match b { ... }` below would then `checkcast` the `Full` payload against
// that nonexistent class, panicking `NoClassDefFoundError` (or a JVM
// `VerifyError` at class load) instead of returning the payload — a
// runtime crash, not a compile error, on every instantiation.
// ─────────────────────────────────────────────────────────────────────────────
union Box6660[T] {
  case Full(v: T)
  case Empty6660
}

record Extractor[T] {
  fallback: T
  func extractOrFallback(b: in Box6660[T]): T {
    match b {
      case Full(v) -> v
      case Empty6660 -> self.fallback
    }
  }
}

test "generic record method matches a user generic union parameter naming its own unresolved type parameter, populated case (#6660)" {
  val e = Extractor(fallback = -1)
  val v = e.extractOrFallback(Full(v = 7))
  assertEqualInt(v, 7, "Extractor[Int](fallback=-1).extractOrFallback(Full(7)) == 7")
}

test "generic record method matches a user generic union parameter naming its own unresolved type parameter, nullary case (#6660)" {
  val e = Extractor(fallback = -1)
  val v = e.extractOrFallback(Empty6660)
  assertEqualInt(v, -1, "Extractor[Int](fallback=-1).extractOrFallback(Empty6660) falls back to self.fallback == -1")
}

test "generic record method's user generic union parameter also works for a String instantiation of T (#6660)" {
  val e = Extractor(fallback = "none")
  val v = e.extractOrFallback(Full(v = "hi"))
  assertEqual(v, "hi", "Extractor[String](fallback=none).extractOrFallback(Full(hi)) == hi")
}

// ─────────────────────────────────────────────────────────────────────────────
// #6742: same class of bug as #6660, but with the unresolved type parameter
// NESTED inside another generic instantiation instead of appearing as a bare
// top-level arg — `Box6742[Box6742[T]]` on `record NestedExtractor[T]` nests
// `T` one level inside the outer parameter's own type argument (`Box6742[T]`).
// The #6660 fix's guard (`recordParamGenericArgs` in `03_match.l`) only
// inspected the TOP LEVEL of each arg via `typeParamIndexOf`: `Box6742[T]` is
// a `TGenericApp`, not a bare `TRef`, so the guard did not recognise it as
// carrying an unresolved type parameter and let it through to
// `eagerlyResolveGenericArgs`, which DOES recurse into nested `TGenericApp`
// args and rewrote the buried `T` to a phantom `<pkg>/T` class reference.
// That phantom then only surfaces as a `checkcast` target once the OUTER
// match's bound payload (`inner: Box6742[T]`) is matched a SECOND time —
// `extractNested` does exactly that (`match b { case Populated(inner) -> match
// inner { case Populated(v) -> v ... } ... }`), so `v`'s bind previously
// `checkcast`ed against the nonexistent phantom class and threw
// `NoClassDefFoundError` at runtime.  The fix widens the guard to a full
// recursive walk (`containsTypeParam`, mirroring the walk
// `returnTypeGenericArgsFiltered` already uses for a function's own return
// type) so a NESTED unresolved type parameter bails registration exactly
// like a top-level one does.
// ─────────────────────────────────────────────────────────────────────────────
union Box6742[T] {
  case Populated(v: T)
  case Empty6742
}

record NestedExtractor[T] {
  fallback: T
  func extractNested(b: in Box6742[Box6742[T]]): T {
    match b {
      case Populated(inner) -> {
        match inner {
          case Populated(v) -> v
          case Empty6742 -> self.fallback
        }
      }
      case Empty6742 -> self.fallback
    }
  }
}

test "generic record method matches a NESTED unresolved type parameter (Box6742[Box6742[T]]), populated/populated case (#6742)" {
  val e = NestedExtractor(fallback = -1)
  val v = e.extractNested(Populated(v = Populated(v = 7)))
  assertEqualInt(v, 7, "NestedExtractor[Int](fallback=-1).extractNested(Populated(Populated(7))) == 7")
}

test "generic record method matches a NESTED unresolved type parameter (Box6742[Box6742[T]]), populated/empty case (#6742)" {
  val e = NestedExtractor(fallback = -1)
  val v = e.extractNested(Populated(v = Empty6742))
  assertEqualInt(
    v,
    -1,
    "NestedExtractor[Int](fallback=-1).extractNested(Populated(Empty6742)) falls back to self.fallback == -1"
  )
}

test "generic record method matches a NESTED unresolved type parameter (Box6742[Box6742[T]]), outer empty case (#6742)" {
  val e = NestedExtractor(fallback = -1)
  val v = e.extractNested(Empty6742)
  assertEqualInt(v, -1, "NestedExtractor[Int](fallback=-1).extractNested(Empty6742) falls back to self.fallback == -1")
}

test "generic record method's NESTED unresolved type parameter also works for a String instantiation of T, across a different call site (#6742)" {
  val e = NestedExtractor(fallback = "none")
  val v = e.extractNested(Populated(v = Populated(v = "hi")))
  assertEqual(v, "hi", "NestedExtractor[String](fallback=none).extractNested(Populated(Populated(hi))) == hi")
}
