//! generator_closure_var_capture_self_test.l — dual-target runtime regression
//! test for by-reference closure capture of a `var` local declared inside an
//! async generator body (#7715).
//!
//! Neither backend ran the by-reference closure-capture pre-pass over a
//! generator body, so a `var` it declared and a nested closure mutated never
//! became a heap cell:
//!
//!   * `--target jvm` (`lowerGeneratorBody`, built via
//!     `makeFuncCtxForGenerator` with an empty `hoistedVarNames`) gave the
//!     `var` a plain slot, and the closure wrote a by-value copy, so every
//!     yield after the mutation produced the pre-mutation value — a silent
//!     wrong-value miscompile.
//!   * `--target dotnet` (`synthesizeGeneratorMsil`'s `MoveNext` `FuncCtx`)
//!     panicked at compile time with the `hoistedVarNames`-miss invariant
//!     ("captured mutable (`var`) local 'x' was not hoisted to a heap cell").
//!
//! Both now run the shared pre-pass (`runClosureCapturePrePassJvm` /
//! `runClosureCapturePrePassMsil`).  On MSIL the cell local is an ordinary
//! `MoveNext` local, so the generator's yield save/restore carries the cell
//! REFERENCE across resumptions; the Pass-1 field-count predictor
//! (`countGeneratorFieldsMsil`) now counts a captured `var` as the two slots
//! `finishHoistedCellMsil` allocates.  On JVM the body runs to completion on
//! its own producer thread, so the cell's slot stays live across yields.
//!
//! The cases cover a mutation before the first yield, mutations between
//! yields, a closure first called after a yield, a `var` declared inside a
//! loop body (a fresh cell per iteration), a closure that reads back the
//! value it wrote, and accumulation over a list.  The last case walks the
//! list by index: a `for` loop inside a generator body is broken on both
//! backends independently of closures (MSIL field-count mismatch, JVM
//! `VerifyError`), which is a separate bug.
//!
//! Run via `lyric test`, compiled in-process on both targets:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/generator_closure_var_capture_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/generator_closure_var_capture_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.GeneratorClosureVarCaptureSelfTest

import Std.Core
import Std.Testing

async func genAssignedByClosure(v: in Int): Int {
  var x = 0
  val f = { -> x = v * 3 }
  f()
  yield x
}

async func genMutateBetweenYields(step: in Int): Int {
  var acc = 1
  val bump = { -> acc = acc + step }
  yield acc
  bump()
  yield acc
  bump()
  bump()
  yield acc
}

async func genClosureCalledAfterYield(): Int {
  var x = 5
  val setTo = { n: Int -> x = n }
  yield x
  setTo(40)
  yield x
  setTo(x + 2)
  yield x
}

async func genVarInLoopBody(n: in Int): Int {
  var i = 0
  while i < n {
    var cell = i * 10
    val add = { -> cell = cell + 1 }
    add()
    yield cell
    add()
    yield cell
    i = i + 1
  }
}

async func genClosureReadsAndWrites(): Int {
  var counter = 0
  val next = { -> counter = counter + 1; counter }
  val a: Int = next()
  yield a
  val b: Int = next()
  yield b
  yield counter
}

async func genIndexedLoopCapture(items: in List[Int]): Int {
  var total = 0
  val add = { k: Int -> total = total + k }
  var i = 0
  while i < items.count {
    add(items[i])
    yield total
    i = i + 1
  }
  yield total * 100
}

func collect(xs: in List[Int]): String {
  var s = ""
  var i = 0
  while i < xs.count {
    if i > 0 {
      s = s + ","
    }
    s = s + toString(xs[i])
    i = i + 1
  }
  s
}

test "generator: closure assigns a captured var before the first yield" {
  val got: List[Int] = newList()
  for x in genAssignedByClosure(7) {
    got.add(x)
  }
  assertEqual(collect(got), "21", "x after closure assigns v * 3")
}

test "generator: closure mutates a captured var between yields" {
  val got: List[Int] = newList()
  for x in genMutateBetweenYields(4) {
    got.add(x)
  }
  assertEqual(collect(got), "1,5,13", "acc across three yields")
}

test "generator: closure called after a yield writes the shared var" {
  val got: List[Int] = newList()
  for x in genClosureCalledAfterYield() {
    got.add(x)
  }
  assertEqual(collect(got), "5,40,42", "x across three yields")
}

test "generator: var declared inside a loop body captured by a closure" {
  val got: List[Int] = newList()
  for x in genVarInLoopBody(3) {
    got.add(x)
  }
  assertEqual(collect(got), "1,2,11,12,21,22", "per-iteration cell values")
}

test "generator: closure reads and writes the captured var and returns it" {
  val got: List[Int] = newList()
  for x in genClosureReadsAndWrites() {
    got.add(x)
  }
  assertEqual(collect(got), "1,2,2", "counter across yields")
}

test "generator: closure accumulates a list across a loop with yields" {
  val items: List[Int] = newList()
  items.add(2)
  items.add(3)
  items.add(5)
  val got: List[Int] = newList()
  for x in genIndexedLoopCapture(items) {
    got.add(x)
  }
  assertEqual(collect(got), "2,5,10,1000", "running total then total * 100")
}

// An uninitialised captured `var` takes the default-seeded cell path.
async func genUninitialisedCaptured(v: in Int): Int {
  var r: Int
  val set = { -> r = v + 1 }
  set()
  yield r
  set()
  yield r * 2
}

// Declared after every generator above: its field tokens are only right if
// each generator's Pass-1 field-count prediction matched real synthesis.
record AfterCapturingGenerators {
  a: Int
  b: String
}

test "generator: uninitialised captured var, then a record declared after the generators" {
  val got: List[Int] = newList()
  for x in genUninitialisedCaptured(4) {
    got.add(x)
  }
  assertEqual(collect(got), "5,10", "r after closure assigns v + 1")
  val rec = AfterCapturingGenerators(a = 9, b = "ok")
  assertEqualInt(rec.a, 9, "record field a after capturing generators")
  assertEqual(rec.b, "ok", "record field b after capturing generators")
}
