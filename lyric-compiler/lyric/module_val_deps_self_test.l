//! module_val_deps_self_test.l — runtime regression test for module-level
//! `pub val` chains where a later untyped `val`'s initializer reads an
//! earlier module-level `val`/`const` by bare name (#5955).
//!
//! On MSIL, the pre-scan that predicts each untyped `val`'s field type (used
//! to register `cctx.staticValMsilTypes` so OTHER functions' `EPath` lowering
//! knows what MSIL type a bare `ldsfld` read produces) fell back to `MObject`
//! for any initializer shape it didn't recognise — including a plain `EPath`
//! reference to an earlier val, or an arithmetic/string-concat `EBinop` over
//! one.  The real field type, computed later by fully lowering the
//! initializer in Phase 4, was often a concrete primitive (`Int`/`String`/…),
//! so the predicted and actual field types silently diverged.  A consumer
//! function's `ldsfld` under the wrong predicted type crashed at runtime
//! (`InvalidProgramException` / `NullReferenceException` depending on the
//! JIT).  Fixed by threading a `valTypeEnv: Map[String, MsilType]` through
//! the pre-scan (mirroring the existing literal-foldability `constEnv`) and
//! extending `inferUntypedStaticValMsilType` to resolve `EPath` and the
//! common `EBinop` shapes against it.
//!
//! JVM was never affected: `prelowerModuleVals` derives every module val's
//! field type from a REAL lowering pass, in declaration order, before any
//! other codegen runs — so a later val's `EPath` read of an earlier val
//! always sees the already-corrected real type.  This file still runs on
//! both targets as a parity pin.
//!
//! Run by the native `lyric test` on BOTH targets (like `block_shadow_self_test.l`):
//!   lyric test --target dotnet lyric-compiler/lyric/module_val_deps_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/module_val_deps_self_test.l
//! `lyric test` synthesises a program from the `test` blocks and compiles it
//! in-process through the self-hosted `Msil.Bridge` / `Jvm.Bridge`, then
//! asserts every embedded value.  Imports only `Std.*` (no
//! `LYRIC_LOAD_COMPILER=1`).
@test_module
package Lyric.ModuleValDepsSelfTest

import Std.Core
import Std.Testing

// 1. The exact #5955 repro: a second module val's initializer reads the
//    first by bare name.
pub val baseInt = 40

pub val derivedInt = baseInt + 2

// 2. A chain of three dependent vals — each reads only its immediate
//    predecessor.
pub val chainStart = 10

pub val chainMiddle = chainStart + 5

pub val chainEnd = chainMiddle * 2

// 3. A derived val whose initializer reads TWO earlier vals.
pub val leftOperand = 3

pub val rightOperand = 4

pub val sumOfBoth = leftOperand + rightOperand

// 4. A String-typed dependent val (BAdd's string-concat arm, not the
//    arithmetic arm).
pub val greetingPrefix = "Hello, "

pub val greetingFull = greetingPrefix + "Lyric"

// 5. A dependent val using each arithmetic BMod/BDiv arm (#5988): the field-type
//    predictor must agree with `lowerBinopMsil`'s real result type for `%` and
//    `/` (both are MInt for Int operands) or a consumer's `ldsfld` diverges.
pub val modResult = derivedInt % 5

pub val divResult = derivedInt / 6

// 5b. Same BMod/BDiv arms with a Double-typed lhs (#5992): the field-type
//     predictor must agree with `lowerBinopMsil`'s real result type for `%`
//     and `/` over Double operands (MDouble), not just Int.
pub val doubleBase = 5.5

pub val doubleModResult = doubleBase % 2.0

pub val doubleDivResult = doubleBase / 2.0

// 6. Control: independent vals with no cross-references must keep working.
pub val independentOne = 100

pub val independentTwo = 200

// 7. Self-qualified reads of THIS package's own module-level vals (#6386 —
//    JVM parity for MSIL's self-qualified fix, #6296). Covers both a
//    literal-initialised val (`baseInt`) and a computed one (`derivedInt`,
//    whose real field type is only known after `derivedInt`'s initializer is
//    lowered) — on JVM both resolve through `tryQualifiedModuleValJvm`'s
//    self-qualified branch, which reads the already-prelowered
//    `ctx.moduleVals` entry regardless of literal-vs-computed. This file's
//    single-file scope can't also exercise the cross-package-in-bundle shape
//    (`Other.Pkg.name` from a second package) — that shape is covered on
//    MSIL by `msil_project_bridge_self_test.l`'s multi-package
//    `compileAndRun` harness; `lyric test`'s single-file synthesis has no
//    equivalent multi-package entry point, so a JVM cross-package-in-bundle
//    regression test is a tracked gap, not exercised here.
test "self-qualified literal module val read (#6386)" {
  assertEqualInt(Lyric.ModuleValDepsSelfTest.baseInt, 40, "qualified baseInt")
  assertEqualInt(Lyric.ModuleValDepsSelfTest.baseInt, baseInt, "qualified == unqualified baseInt")
}

test "self-qualified computed module val read (#6386)" {
  assertEqualInt(Lyric.ModuleValDepsSelfTest.derivedInt, 42, "qualified derivedInt")
  assertEqualInt(Lyric.ModuleValDepsSelfTest.derivedInt, derivedInt, "qualified == unqualified derivedInt")
}

test "base+derived Int module val chain (#5955 repro)" {
  assertEqualInt(baseInt, 40, "baseInt")
  assertEqualInt(derivedInt, 42, "derivedInt")
}

test "chain of three dependent module vals" {
  assertEqualInt(chainStart, 10, "chainStart")
  assertEqualInt(chainMiddle, 15, "chainMiddle")
  assertEqualInt(chainEnd, 30, "chainEnd")
}

test "derived val reading two earlier vals" {
  assertEqualInt(leftOperand, 3, "leftOperand")
  assertEqualInt(rightOperand, 4, "rightOperand")
  assertEqualInt(sumOfBoth, 7, "sumOfBoth")
}

test "String-typed dependent module val" {
  assertEqual(greetingPrefix, "Hello, ", "greetingPrefix")
  assertEqual(greetingFull, "Hello, Lyric", "greetingFull")
}

test "BMod/BDiv dependent module vals predict the right field type (#5988)" {
  assertEqualInt(modResult, 2, "modResult (42 % 5)")
  assertEqualInt(divResult, 7, "divResult (42 / 6)")
}

test "Double-lhs BMod/BDiv dependent module vals predict the right field type (#5992)" {
  assertTrue(doubleModResult == 1.5, "doubleModResult (5.5 % 2.0)")
  assertTrue(doubleDivResult == 2.75, "doubleDivResult (5.5 / 2.0)")
}

test "independent module vals still work" {
  assertEqualInt(independentOne, 100, "independentOne")
  assertEqualInt(independentTwo, 200, "independentTwo")
}
