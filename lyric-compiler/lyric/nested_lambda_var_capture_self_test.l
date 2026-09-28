//! nested_lambda_var_capture_self_test.l — dual-target runtime regression
//! test for by-reference closure capture of a `var` local declared INSIDE a
//! lambda body and mutated by a closure nested in that lambda (#7694).
//!
//! The by-reference capture pre-pass (`runClosureCapturePrePassJvm`, #7690)
//! hoists a `var` referenced inside a nested lambda to a heap cell so the
//! closure and the enclosing scope share one mutable location. On the JVM
//! backend `lowerLambda` built the lambda body's `FuncCtx` via `makeFuncCtx`
//! (whose `hoistedVarNames` starts empty) and never ran the pre-pass over the
//! lambda's own body, so a `var` declared inside a lambda was captured BY
//! VALUE by a closure nested in it: the nested closure's writes went to its
//! own copy and the enclosing lambda read back the original value — a silent
//! wrong-value miscompile (`{ -> var x = 0; val inner = { -> x = x + 1 };
//! inner(); x }()` returned 0, not 1). Fixed by running the pre-pass on every
//! lambda body `lowerLambda` builds (and on a `spawn` operand's body in
//! `lowerSpawnCallable`, which builds its own fresh `FuncCtx` the same way).
//!
//! The MSIL backend was already correct: it lifts every lambda to a function
//! lowered through `lowerFuncMsilScoped`, which has always run the pre-pass.
//! Covered here on both targets so the two stay in lockstep.
//!
//! Variants: the outer lambda inside a top-level function, a record method,
//! a top-level `impl <Iface> for <Record>` method, and a protected-type
//! entry; several mutations; a closure three lambdas deep mutating a `var` of
//! the outermost lambda; and a `var` declared in a middle lambda mutated by
//! the innermost one; a `var` inside a `spawn` operand; and a `var` inside a
//! branch block of an expression-bodied function (`runClosureCapturePrePassJvm`
//! skipped mutable-var collection for `= expr` bodies, which the `spawn` fix
//! made reachable too). The impl-method case shares the file with the other
//! closures on purpose: that layout is what #7693 desynced on MSIL.
//!
//! Every closure-call result is bound with an explicit `Int` annotation to
//! stay clear of the unrelated MSIL unannotated-closure-result bug (#7711).
//!
//! Run via `lyric test`, compiled in-process on both targets:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/nested_lambda_var_capture_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/nested_lambda_var_capture_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.NestedLambdaVarCaptureSelfTest

import Std.Core
import Std.Testing

func topLevelSingle(): Int {
  val outer = { -> var x = 0; val inner = { -> x = x + 1 }; inner(); val r: Int = x; r }
  val v: Int = outer()
  return v
}

func topLevelMany(): Int {
  val outer = { ->
    var x = 1
    var calls = 0
    val inner = { -> x = x * 2; calls = calls + 1 }
    inner()
    inner()
    inner()
    val r: Int = x + calls * 100
    r
  }
  val v: Int = outer()
  return v
}

func threeDeep(): Int {
  val a = { -> var x = 0; val b = { -> val c = { -> x = x + 5 }; c(); c() }; b(); val r: Int = x; r }
  val v: Int = a()
  return v
}

func middleLambdaVar(): Int {
  val a = { -> val b = { -> var y = 1; val c = { -> y = y * 3 }; c(); c(); val r: Int = y; r }; val rb: Int = b(); rb }
  val v: Int = a()
  return v
}

// A `var` in a block of an expression-bodied function: the pre-pass used to
// skip mutable-var collection for an `= expr` body entirely.
func exprBodied(flag: in Bool): Int = if flag { var x = 2; val inner = { -> x = x + 3 }; inner(); val r: Int = x; r } else { 0 }

// A `var` in a `spawn` operand: `lowerSpawnCallable` builds its own fresh
// `FuncCtx` for the operand, just like `lowerLambda`.
func viaSpawn(): Int {
  scope {
    val t = spawn if true { var x = 0; val inner = { -> x = x + 4 }; inner(); val r: Int = x; r } else { 0 }
    val v: Int = await t
    return v
  }
}

record Counter {
  base: Int
  func run(): Int {
    val outer = { -> var x = self.base; val inner = { -> x = x + 1 }; inner(); inner(); val r: Int = x; r }
    val v: Int = outer()
    return v
  }
}

interface Runner {
  func go(): Int
}

record Stepper {
  k: Int
}

impl Runner for Stepper {
  func go(): Int {
    val outer = { -> var x = self.k; val inner = { -> x = x + 10 }; inner(); val r: Int = x; r }
    val v: Int = outer()
    return v
  }
}

protected type Tally {
  var total: Int = 0
  entry add(k: in Int): Int {
    val outer = { -> var x = k; val inner = { -> x = x + 10 }; inner(); val r: Int = x; r }
    val v: Int = outer()
    total = total + v
    total
  }
}

test "top-level function: nested closure mutates a var of its enclosing lambda (#7694)" {
  assertEqualInt(topLevelSingle(), 1, "x after one nested-closure increment")
}

test "top-level function: several mutations of two captured vars" {
  assertEqualInt(topLevelMany(), 308, "x = 8 after three doublings, calls = 3")
}

test "three lambdas deep: innermost closure mutates the outermost lambda's var" {
  assertEqualInt(threeDeep(), 10, "x after two +5 bumps two lambdas down")
}

test "middle lambda's var mutated by the innermost closure" {
  assertEqualInt(middleLambdaVar(), 9, "y after two triplings")
}

test "expression-bodied function: closure mutates a var in a branch block" {
  assertEqualInt(exprBodied(true), 5, "x after one +3 from 2")
}

test "spawn operand: closure mutates a var declared in the spawned expression" {
  assertEqualInt(viaSpawn(), 4, "x after one +4, joined through await")
}

test "record method: nested closure mutates a var of its enclosing lambda" {
  assertEqualInt(Counter(base = 5).run(), 7, "x after two increments from base 5")
}

test "impl method: nested closure mutates a var of its enclosing lambda" {
  val runner: Runner = Stepper(k = 1)
  assertEqualInt(runner.go(), 11, "impl method")
}

test "protected-type entry: nested closure mutates a var of its enclosing lambda" {
  val t = Tally()
  assertEqualInt(t.add(1), 11, "total after one entry call (x = 1 + 10)")
  assertEqualInt(t.add(2), 23, "total after second entry call (x = 2 + 10)")
}
