//! method_closure_var_capture_self_test.l — dual-target runtime regression
//! test for by-reference closure capture of a `var` local declared INSIDE a
//! record method, a protected-type member, or an impl method (#7690), plus
//! the MSIL lambda-numbering desync between impl-method and record-method
//! closures in one file (#7693).
//!
//! `lowerFuncMsilScoped` (top-level functions and lifted lambdas) has always
//! run the by-reference closure-capture pre-pass (#1479 v2):
//! `collectInLambdaNamesBlock`/`collectInLambdaNamesExpr` populate
//! `FuncCtx.hoistedVarNames` with every name referenced inside a nested
//! lambda, so a `var` local in that set is hoisted to a heap cell at its
//! declaration instead of a plain stack slot, letting the closure and the
//! enclosing scope share one mutable location. `lowerRecordMethodMsil` and
//! `lowerImplMethodMsil` never ran this pre-pass, so a closure declared
//! inside a record method or an impl method that mutated a captured `var`
//! panicked at compile time on `--target dotnet`:
//!
//!   error[T0120]: MSIL codegen failed: Msil.Codegen: internal error —
//!   captured mutable (`var`) local 'x' was not hoisted to a heap cell
//!
//! Fixed by extracting the pre-pass into a shared `runClosureCapturePrePassMsil`
//! helper and running it in every MSIL method-lowering path that can contain
//! closures: `lowerFuncMsilScoped`, `lowerImplMethodMsil`,
//! `lowerRecordMethodMsil`, and the protected-type `entry` lowering (which
//! builds its own `FuncCtx` directly rather than going through either of the
//! above). A `protected type func` member routes through `lowerImplMethodMsil`
//! already, so it needed no separate fix — covered here too via `Counter`'s
//! `doubleOf`.
//!
//! The JVM backend had the identical gap for the same three method-lowering
//! paths (`lowerRecordMethod`, `lowerImplMethod`, `lowerProtectedMethod`, all
//! built via `makeFuncCtxInstance`, whose `hoistedVarNames` started and
//! stayed empty) — but silently, with no compile-time panic: a closure that
//! mutated a captured `var` there wrote straight to the method's own local
//! slot instead of the heap cell the closure and the method share, so a
//! WRONG VALUE surfaced at run time instead of a diagnostic. Fixed the same
//! way via a shared `runClosureCapturePrePassJvm` helper.
//!
//! This file deliberately puts top-level `impl <Iface> for <Record>` methods
//! with capturing closures AFTER record methods with capturing closures, in
//! ONE compiled file — the regression shape for #7693. `Msil.Bridge`'s
//! `collectImplEntriesMsil` pre-pass lowers every top-level `impl` block's
//! methods (and their `ELambda`s) BEFORE `codegenMPackage`'s main per-item
//! loop reaches the records declared ahead of them, while `liftLambdasMsil`
//! numbers `__lambda_<i>` in file-declaration order. With one running
//! `cctx.lambdaTicker` the impl method's lambda took the index the lift had
//! given the first record-method lambda, so each `ELambda` site was bound to
//! another lambda's lifted body and captures and the build failed with
//!
//!   error[T0115]: cannot resolve name '<captured-name>' to a value here
//!   (in <pkg>.__lambda_<n>)
//!
//! Fixed by computing each item's lift-assigned starting lambda index
//! (`computeLambdaBasesMsil`, which replays the lift's own per-item walker
//! `collectItemLambdasBfsMsil`) and re-anchoring the ticker to it before
//! lowering the item, in the impl pre-pass and the main loop alike. The
//! desync is not `var`-specific: the `Labelled`/`Tagger` cases capture plain
//! `val`s under names that differ between the record method and the impl
//! method. The JVM backend numbers `<pkg>$Lambda$<n>` at the `ELambda` site
//! itself (no separate lifting pre-pass), so it never had this desync; the
//! cases run on both targets regardless.
//!
//! Run via `lyric test`, compiled in-process on both targets:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/method_closure_var_capture_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/method_closure_var_capture_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
//!
//! The generic-record-method case (a closure capturing `var x: T` inside a
//! generic record method) is not covered here: inside a generic record
//! method the annotation `var x: T` resolved `T` as a class on both
//! backends (#7695). Fixed in #7695; the case (`Box[T].captureThenReturn`,
//! instantiated with a value type, a reference type, and an in-bundle
//! record) is covered in `generic_method_body_typevar_self_test.l` instead,
//! alongside the sibling body-local-annotation shapes (`val`, `List[T]`,
//! `Option[T]`) #7695 also fixed.
@test_module
package Lyric.MethodClosureVarCaptureSelfTest

import Std.Core
import Std.Testing

record Plain {
  value: Int
  func compute(): Int {
    var x: Int
    val f = { -> x = self.value }
    f()
    return x
  }
  func compoundBump(times: in Int): Int {
    var acc = 0
    val bump = { -> acc = acc + self.value }
    var i = 0
    while i < times {
      bump()
      i = i + 1
    }
    return acc
  }
  func initialisedThenCaptured(): Int {
    var y = 10
    val f = { -> y = y + self.value }
    f()
    return y
  }
}

test "record method: closure captures and assigns an uninitialised var (#7690)" {
  val p = Plain(value = 41)
  assertEqualInt(p.compute(), 41, "closure-assigned uninitialised var read back after call")
}

test "record method: closure compound-mutates a captured var across several calls" {
  val p = Plain(value = 3)
  assertEqualInt(p.compoundBump(4), 12, "acc after four closure-driven compound bumps")
}

test "record method: closure mutates an already-initialised captured var" {
  val p = Plain(value = 7)
  assertEqualInt(p.initialisedThenCaptured(), 17, "y after closure adds self.value once")
}

protected type Counter {
  var total: Int = 0
  entry bump(by: in Int): Int {
    var delta: Int
    val f = { -> delta = by * 2 }
    f()
    total = total + delta
    total
  }
  // A protected-type `func` member is read-only (mode-checker-enforced —
  // only `entry` may write a field), but it still lowers through
  // `lowerImplMethodMsil` (`PMFunc` desugars into that path, see
  // `lyric-compiler/msil/codegen.l`'s `PMFunc` arm) rather than building its
  // own `FuncCtx` the way `entry` does, so this exercises the SAME fix as
  // the plain impl-method case above via a distinct AST shape (a protected
  // type's `func`, not a top-level `impl` block) — it captures and mutates a
  // local `var`, never a field.
  func doubleOf(x: in Int): Int {
    var r: Int
    val f = { -> r = x * 2 }
    f()
    r
  }
}

test "protected-type entry: closure captures and assigns an uninitialised var (#7690)" {
  val c = Counter()
  assertEqualInt(c.bump(5), 10, "total after entry closure assigns delta = by * 2")
  assertEqualInt(c.bump(3), 16, "total after second entry closure call")
}

test "protected-type func member: closure captures and assigns an uninitialised local var" {
  val c = Counter()
  assertEqualInt(c.doubleOf(9), 18, "r after func-member closure assigns x * 2")
}

// A record-method closure capturing plain `val`s, declared before the
// `Tagger` impl below whose closure captures DIFFERENTLY-named `val`s (#7693).
record Labelled {
  prefix: String
  func label(n: in Int): String {
    val shown = n * 10
    val sep = ":"
    val f = { -> self.prefix + sep + toString(shown) }
    f()
  }
}

interface Doubler {
  func doubleValue(): Int
}

record Wrapped {
  value: Int
}

impl Doubler for Wrapped {
  func doubleValue(): Int {
    var x: Int
    val f = { -> x = self.value * 2 }
    f()
    return x
  }
}

interface Accumulator {
  func accumulate(times: in Int): Int
}

record Adder {
  step: Int
}

impl Accumulator for Adder {
  func accumulate(times: in Int): Int {
    var acc = 0
    val bump = { -> acc = acc + self.step }
    var i = 0
    while i < times {
      bump()
      i = i + 1
    }
    return acc
  }
}

interface Tagger {
  func tag(base: in Int): Int
}

record Tagged {
  offset: Int
}

impl Tagger for Tagged {
  func tag(base: in Int): Int {
    val scaled = base * 3
    val extra = self.offset
    // A nested closure inside the impl-method closure: its lifted index is
    // assigned in the lift's deferred (breadth-first) phase, after every
    // top-level item's direct lambdas.
    val h = { -> val inner = { -> scaled + extra + 1 }; inner() }
    val r: Int = h()
    r
  }
}

// A default interface method with a capturing closure: `liftLambdasMsil`
// never walked `IInterface` default-method bodies, so its lambda had no lifted
// token (#7693 audit).
interface Scaler {
  func factor(): Int
  func scaled(n: in Int): Int {
    val bumped = n + 1
    val f = { -> bumped * 2 }
    val r: Int = f()
    r
  }
}

record ScaleBy {
  k: Int
}

impl Scaler for ScaleBy {
  func factor(): Int = self.k
}

test "impl method: closure captures and assigns an uninitialised var (#7690)" {
  val w = Wrapped(value = 21)
  assertEqualInt(w.doubleValue(), 42, "closure-assigned uninitialised var inside impl method")
}

test "impl method: closure compound-mutates a captured var across several calls" {
  val a = Adder(step = 3)
  assertEqualInt(a.accumulate(4), 12, "acc after four closure-driven compound bumps in an impl method")
}

test "record method: closure captures differently-named vals alongside impl closures (#7693)" {
  val l = Labelled(prefix = "n")
  assertEqual(l.label(4), "n:40", "record-method closure reads its own captured vals, not an impl closure's")
}

test "impl method: closure captures vals alongside record-method closures (#7693)" {
  val t = Tagged(offset = 5)
  assertEqualInt(t.tag(7), 27, "impl-method closure (and its nested closure) read their own captured vals")
}

test "impl method called through the interface after record-method closures run (#7693)" {
  val d: Doubler = Wrapped(value = 8)
  val p = Plain(value = 2)
  assertEqualInt(
    p.compute() + d.doubleValue(),
    18,
    "record-method and impl-method closures each bind their own captures"
  )
}

test "default interface method: closure captures a param-derived val (#7693)" {
  val s: Scaler = ScaleBy(k = 3)
  assertEqualInt(s.scaled(4), 10, "default-method closure reads its own captured val")
  assertEqualInt(s.factor(), 3, "impl method alongside the default method")
}
