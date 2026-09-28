//! impl_method_closure_var_capture_self_test.l — dual-target runtime
//! regression test for by-reference closure capture of a `var` local
//! declared inside an `impl <Iface> for <Record>` method (#7690).
//!
//! Split out from `method_closure_var_capture_self_test.l` (which covers the
//! record-method and protected-type-entry/func cases) because combining a
//! top-level `impl` block and a record method, each with its own
//! var-capturing closure, in ONE compiled file hits an unrelated,
//! pre-existing MSIL lambda-numbering bug: `Msil.Bridge`'s
//! `collectImplEntriesMsil` pre-pass lowers every top-level `impl` block's
//! methods (and their `ELambda`s) BEFORE the main per-item codegen loop
//! reaches the file's records, while the separate front-end
//! `liftLambdasMsil` pass numbers `__lambda_<i>` by raw file-declaration
//! order — so the two disagree on which lifted `__lambda_<i>` owns which
//! lambda's captures whenever both kinds of closure-bearing item coexist.
//! Tracked in #7693; merge the two files once that is fixed.
//!
//! `lowerImplMethodMsil` never ran the by-reference closure-capture pre-pass
//! (#1479 v2) that `lowerFuncMsilScoped` (top-level functions and lifted
//! lambdas) has always run, so a closure inside an impl method that mutated
//! a captured `var` panicked at compile time on `--target dotnet`:
//!
//!   error[T0120]: MSIL codegen failed: Msil.Codegen: internal error —
//!   captured mutable (`var`) local 'x' was not hoisted to a heap cell
//!
//! Fixed by running the shared `runClosureCapturePrePassMsil` helper in
//! `lowerImplMethodMsil` too. The JVM backend had the identical gap in
//! `lowerImplMethod` (built via `makeFuncCtxInstance`, whose
//! `hoistedVarNames` started and stayed empty) — but silently: a closure
//! that mutated a captured `var` wrote to the method's own local slot
//! instead of the shared heap cell, a wrong-value miscompile with no
//! diagnostic. Fixed via the shared `runClosureCapturePrePassJvm` helper.
//!
//! Run via `lyric test`, compiled in-process on both targets:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/impl_method_closure_var_capture_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/impl_method_closure_var_capture_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.ImplMethodClosureVarCaptureSelfTest

import Std.Core
import Std.Testing

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

test "impl method: closure captures and assigns an uninitialised var (#7690)" {
  val w = Wrapped(value = 21)
  assertEqualInt(w.doubleValue(), 42, "closure-assigned uninitialised var inside impl method")
}

test "impl method: closure compound-mutates a captured var across several calls" {
  val a = Adder(step = 3)
  assertEqualInt(a.accumulate(4), 12, "acc after four closure-driven compound bumps in an impl method")
}
