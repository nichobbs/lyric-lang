//! bmode_runtime_self_test.l — end-to-end runtime regression test for
//! B'-mode aspect specialisation (docs/55 / D114, docs/56 / D115) on both
//! self-hosted backends (#4600).
//!
//! Before this test, B'-mode coverage was AST-only: the six B'-mode cases
//! in `weaver_self_test.l` inspect the woven `SourceFile` shape (presence
//! of `__lyric_bmode_*` functions, parameter shapes, injected locals) but
//! never compile and run the output on either target, so a real MSIL or
//! JVM codegen bug in the B'-mode path (synthesised `__LyricBModeCallContext`
//! / `__LyricBModeCfg_*` / `__LyricBModeArgs_*` records, lambda-typed
//! parameters, thin wrapper functions calling across a closure boundary)
//! could regress silently on either backend.
//!
//! `Weaver.resolveFromInstances` resolves an unqualified `from Template`
//! reference against `pkgName + "." + fqn}` (`lookupFromTemplate`, #3543),
//! and both self-hosted single-file bridges collect `pub aspect` templates
//! from the compiled file's OWN package before weaving
//! (`Jvm.Bridge.compileProjectToJarBundledWithFeatures` /
//! `Msil.Bridge.compileToMsilWithVersion`), so a template and its
//! `from`-instance declared in the SAME file/package resolve without
//! needing a separate path-dependency package — exactly what a from-instance
//! resolving to a `pub aspect` template WITHOUT `@inline_template` needs to
//! route through B'-mode specialisation (`isBMode` in `Lyric.Weaver`).
//!
//! Run via native `lyric test` on BOTH targets (mirrors `aspect_weave_self_test.l`):
//!
//!   lyric test lyric-compiler/lyric/bmode_runtime_self_test.l                # MSIL
//!   lyric test --target jvm lyric-compiler/lyric/bmode_runtime_self_test.l   # JVM
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
//!
//! Coverage:
//!   - a plain (non-row) B'-mode from-instance template that genuinely
//!     runs and affects the woven function's return value (not just a
//!     compile-time AST shape check);
//!   - two matched functions of DISTINCT shapes (`Int -> Int`,
//!     `String -> String`) sharing the same template — each gets its own
//!     shape-keyed specialised function (docs/55 §3.2 point 2), and both
//!     must independently codegen and run correctly;
//!   - a row-constrained (`where TArgs has { ... }`, docs/56 / D115)
//!     template whose body reads `args.<field>` — proving the synthesised
//!     `__LyricBModeArgs_*` record threads the REAL call-site argument
//!     value at runtime, not just a compile-time placeholder;
//!   - a `config { }` override on the from-instance flowing through the
//!     shared `__LyricBModeCfg_*` record into the specialised function.
@test_module
package Lyric.BmodeRuntimeSelfTest

import Std.Core
import Std.Testing

// ─────────────────────────────────────────────────────────────────────────────
// §1. Plain B'-mode from-instance: the aspect genuinely runs and affects the
// woven function's return value.
// ─────────────────────────────────────────────────────────────────────────────
pub aspect Doubler {
  around(call) -> ret {
    ret = call.proceed() * 2
  }
}

aspect ApplyDoubler from Doubler {
  matches: name in { addOne }
}

func addOne(x: Int): Int {
  return x + 1
}

test "B'-mode from-instance template genuinely runs: doubles the target's result" {
  // addOne(20) = 21, doubled by the woven B'-mode aspect = 42.
  assertEqualInt(addOne(20), 42, "addOne(20) woven through B'-mode from-instance")
  assertEqualInt(addOne(-1), 0, "addOne(-1) woven through B'-mode from-instance")
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Shape-keyed dedup (docs/55 §3.2 point 2): the SAME template applied to
// two matched functions of DIFFERENT shapes (Int->Int, String->String) each
// gets its own specialised function; both must run correctly — proof that
// codegen for a second, distinct `__lyric_bmode_*` shape doesn't collide
// with (or corrupt) the first.
// ─────────────────────────────────────────────────────────────────────────────
pub aspect Tag {
  around(call) -> ret {
    ret = call.proceed()
  }
}

aspect ApplyTagInt from Tag {
  matches: name in { passInt }
}

aspect ApplyTagStr from Tag {
  matches: name in { passStr }
}

func passInt(x: Int): Int {
  return x * 3
}

func passStr(s: String): String {
  return s
}

test "B'-mode shape-keyed specialisation: distinct shapes both run correctly" {
  assertEqualInt(passInt(7), 21, "passInt(7) woven through its own Int-shaped specialisation")
  assertEqual(passStr("hi"), "hi", "passStr woven through its own String-shaped specialisation")
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Row-constrained B'-mode (docs/56 / D115): `where TArgs has { ... }`
// threads a real parameter value from the matched call site through the
// synthesised `__LyricBModeArgs_*` record into the shared specialised
// function.  A `config { }` override on the from-instance also flows
// through the shared `__LyricBModeCfg_*` record.  Both must be observable
// at runtime, not just present in the woven AST.
// ─────────────────────────────────────────────────────────────────────────────
pub aspect Scale {
  config {
    factor: Int = 2
  }
  around(call) -> ret where TArgs has { base: Int } {
    ret = args.base * config.factor
  }
}

aspect ApplyScale from Scale {
  matches: name in { scaleMe }
  config {
    factor: Int = 5
  }
}

func scaleMe(base: Int): Int {
  return base
}

test "B'-mode row-constrained template threads the real arg value and config override" {
  // scaleMe's own body just returns base unchanged; the woven aspect reads
  // args.base (from the synthesised row-typed args record) and multiplies
  // by the consumer's overridden factor (5, not the template default of 2).
  assertEqualInt(scaleMe(10), 50, "scaleMe(10) = args.base(10) * config.factor(5) via B'-mode row args")
  assertEqualInt(scaleMe(0), 0, "scaleMe(0) = 0 * 5 via B'-mode row args")
}
