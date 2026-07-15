//! func_val_local_rettype_self_test.l — #5774 (found while investigating
//! #5304): an un-annotated local bound from a call to a function whose OWN
//! declared return type is itself function-shaped
//! (`func makeAdder(x: Int): (Int) -> Int { ... }`, `val f = makeAdder(5)`,
//! no `(Int) -> Int` annotation on `f`) never registered `f`'s return type in
//! `fctx.funcValRetTypes`.  Invoking `f` later left the delegate's boxed
//! `object` result un-unboxed, which — whenever that boxed value was then
//! used somewhere requiring the real value type (most sharply: returned
//! directly as a function's own typed result) — produced genuinely invalid
//! IL: `ilverify` reported `[StackUnexpected] found object, expected Int32`,
//! and the compiled program returned a different garbage integer on every
//! run of the SAME binary (an unboxed object-reference bit pattern read as
//! Int32).  Reproduced in a plain single-file build — no multi-package
//! bundle or cross-package call required, despite #5304's original
//! description implicating package-bundle ordering specifically.
//!
//! Fixed by extending the existing #5511 "function-typed record field"
//! inference path (`cctx.fieldFuncRetTypes`/`recordFieldFuncKeyMsil`,
//! originally for `val fld = h.f`) to also recognise a plain call to a known
//! same-package top-level function whose declared return type is
//! `TFunction`, registered once per function in `addPackageTokens`'s IFunc
//! pass under a `"func:" + pkgName + "." + funcName` key.
//!
//! #5790 (review finding on the original #5774 fix): the initial landing
//! keyed this registration by BARE name only, first-registration-wins — which
//! let a same-name overload at a DIFFERENT arity (D-progress-324/#1536:
//! overloading by arity is a shipped, tested feature) silently steal another
//! overload's function-value return/param types, reproducing the same
//! miscompile class this fix exists to close.  Fixed by arity-qualifying the
//! key (mirroring `funcRetTypes`' `arityKey`/bare-name dual registration and
//! its call-site arity-first lookup precedence); the bare-name key remains as
//! a fallback only.  See the last test below for the regression case.
//!
//! Run in CI via native `lyric test --target dotnet`:
//!
//!   lyric test lyric-compiler/lyric/func_val_local_rettype_self_test.l
//!
//! MSIL target only — the fix lives in `msil/codegen.l`; #5304's original
//! panic-based repro was also MSIL/`Msil.Lowering`-specific.  Imports only
//! `Std.*`.
@test_module
package Lyric.FuncValLocalRetTypeSelfTest

import Std.Core
import Std.Testing

// HOF returning a closure: the shape that #5774 hit.
func makeAdder(x: in Int): (Int) -> Int {
  { y: Int -> x + y }
}

func makeGreeter(name: in String): () -> String {
  { -> "hello, " + name }
}

func makeMultiParam(scale: in Int): (Int, Int) -> Int {
  { a: Int, b: Int -> (a + b) * scale }
}

test "un-annotated closure local, invoked and directly returned (#5774 exact repro)" {
  assertEqualInt(directReturn(), 15, "directReturn() == 15")
}

func directReturn(): Int {
  val f = makeAdder(5)
  f(10)
}

test "un-annotated closure local, invoked and stored before use" {
  val f = makeAdder(7)
  val r = f(3)
  assertEqualInt(r, 10, "makeAdder(7)(3) == 10")
}

test "un-annotated closure local, invoked twice with different arguments" {
  val f = makeAdder(1)
  assertEqualInt(f(1), 2, "makeAdder(1)(1) == 2")
  assertEqualInt(f(100), 101, "makeAdder(1)(100) == 101")
}

test "un-annotated closure local, zero-arg / String-returning" {
  val greet = makeGreeter("world")
  assertEqual(greet(), "hello, world", "makeGreeter(\"world\")() == \"hello, world\"")
}

test "un-annotated closure local, two-parameter" {
  val f = makeMultiParam(2)
  assertEqualInt(f(3, 4), 14, "makeMultiParam(2)(3,4) == (3+4)*2 == 14")
}

test "explicitly-annotated closure local still works (pre-existing path, no regression)" {
  val f: (Int) -> Int = makeAdder(5)
  assertEqualInt(f(10), 15, "annotated makeAdder(5)(10) == 15")
}

// Two same-name overloads (D-progress-324/#1536) at different arities, each
// returning a DIFFERENT function-shaped type.  #5790: a bare-name-only key
// would let the second overload's call site silently inherit the first
// overload's return/param types.
func makeOp(x: in Int): (Int) -> Int {
  { y: Int -> x + y }
}

func makeOp(x: in Int, label: in String): () -> String {
  { -> label + toString(x) }
}

test "overloaded HOF-returning functions at different arities resolve independently (#5790)" {
  val f = makeOp(5)
  assertEqualInt(f(10), 15, "makeOp(5)(10) == 15 (1-arity overload)")
  val g = makeOp(7, "n=")
  assertEqual(g(), "n=7", "makeOp(7, \"n=\")() == \"n=7\" (2-arity overload)")
}
