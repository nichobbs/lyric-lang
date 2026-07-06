//! module_val_self_test.l — regression test for module-level `val` declarations
//! (M5.2 stage 3: module-level vals as static readonly fields).
//!
//! Module-level vals at package scope are emitted as static readonly fields
//! initialized in the host-class .cctor.  Two paths exist:
//!
//!   - Literal Int/Bool/Char/Unit inits: inlined into `constValues` by the
//!     token pre-scan; `EPath` emits `ldc.i4` directly (no static field).
//!   - All other inits (String literals, binary ops, function calls, etc.):
//!     emitted as a static field; `EPath` emits `ldsfld <field-token>`.
//!
//! The tests below exercise both paths and verify that function bodies can
//! read module-level vals of each kind at runtime.
//!
//! An untyped (no `: Type` annotation) module-level val whose type must be
//! inferred from its initializer is a THIRD path, gated on #5298: the token
//! pre-scan used to default an untyped val's recorded MSIL type to `MObject`
//! regardless of what the initializer actually produced, so a later `.length`
//! read mis-dispatched through the List/IList fallback and crashed at runtime
//! with `InvalidCastException: String -> IList`. `untypedGreeting` below
//! covers the regression. `untypedNegInt` covers the same bug class for a
//! negative-literal `Int` (`EPrefix(PreNeg, ...)`, #5300), a follow-up gap
//! the inference function initially missed.
//!
//! JVM target parity is tracked in issue #2210.  The JVM emitter currently
//! no-ops on `IVal` items at package scope; this CI step covers MSIL only.
//!
//! Also covers `extern type`-typed module vals: the #1576 codegen fix ensures
//! that a `val` whose type is a reference-typed `extern type` (e.g. `StringBuilder`)
//! encodes its FieldDef signature as `ELEMENT_TYPE_CLASS + TypeRef` (correct CLR
//! FQN) rather than `ELEMENT_TYPE_OBJECT`, and that the `.cctor` properly
//! initializes the field.
//!
//! Runs in CI via:
//!
//!   lyric test lyric-compiler/lyric/module_val_self_test.l
@test_module
package Lyric.ModuleValSelfTest

import Std.Core
import Std.Testing

// ── Extern-type val test infrastructure (#1576) ───────────────────────────────
// StringBuilder is a reference-typed extern: its FieldDef must encode as
// ELEMENT_TYPE_CLASS + TypeRef, not ELEMENT_TYPE_OBJECT.
extern type SB = "System.Text.StringBuilder"

@externTarget("System.Text.StringBuilder..ctor")
func newSb(): SB = ()

@externTarget("System.Text.StringBuilder.ToString")
@externInstance
func sbToString(sb: in SB): String = ()

// ── Literal inits (inline ldc.i4 path) ────────────────────────────────────────
// Literal IVal items (Int/Bool in the ldc.i4 range) DO emit a FieldDef row
// (fieldDefRow increments unconditionally in Pass 1b), but they are NOT entered
// into staticValTokens.  EPath reads them via constValues and emits ldc.i4
// directly — no ldsfld.  The FieldDef row allocation is required for correct
// token alignment of all subsequent IVal/IConst/IFunc items.
val literalInt: Int = 42

val literalBool: Bool = true

val derivedLit: Int = literalInt

// EPath referencing an earlier literal val
// ── Non-literal inits (static field path) ─────────────────────────────────────
// isLiteralI4ExprMsilWithEnv returns false → FieldDef row + ldsfld.
val greeting: String = "Hello, World"

val computedSum: Int = 1 + 1

// EBinop → non-literal, static field
val negated: Int = 0 - 55

// EBinop → non-literal, static field
// Reference-typed extern val: initialized via newSb() in .cctor (#1576).
val sharedSb: SB = newSb()

// ── Untyped inits (type must be inferred from the initializer, #5298) ────────
// No `: String` annotation: before the fix, the pre-scan recorded MObject for
// this field's read type (instead of the String the initializer actually
// produces), so `.length` below crashed with InvalidCastException.
val untypedGreeting = "https://"

func untypedGreetingLength(): Int {
  untypedGreeting.length
}

// `-40` parses as EPrefix(PreNeg, ELiteral(LInt(40))) (#5300): before the
// fix, inferUntypedStaticValMsilType fell through to MObject for this AST
// shape even though the field's real FieldDef type is Int32 — the same
// "recorded type != real field type" bug class as #5298, triggered by a
// negative literal instead of a string.
val untypedNegInt = -40

func untypedNegIntPlusTen(): Int {
  untypedNegInt + 10
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────
test "literal Int val resolves correctly" {
  assertEqualInt(literalInt, 42, "literalInt")
}

test "literal Bool val resolves correctly" {
  assertTrue(literalBool, "literalBool")
}

test "derived literal val (val-of-val) resolves correctly" {
  assertEqualInt(derivedLit, 42, "derivedLit")
}

test "String val resolves via static field" {
  assertEqual(greeting, "Hello, World", "greeting")
}

test "computed Int val resolves via static field" {
  assertEqualInt(computedSum, 2, "computedSum")
}

test "negated Int val resolves via static field" {
  assertEqualInt(negated, -55, "negated")
}

test "module-level val usable in local expression" {
  val doubled = literalInt * 2
  assertEqualInt(doubled, 84, "doubled literalInt")
}

test "module-level String val usable in string operations" {
  val len = greeting.length
  assertEqualInt(len, 12, "greeting.length")
}

test "extern-type val initialized in .cctor (#1576)" {
  val result = sbToString(sharedSb)
  assertEqual(result, "", "extern-type val is non-null: empty StringBuilder produces empty string")
}

test "untyped module-level String val infers String, not MObject (#5298)" {
  assertEqualInt(untypedGreeting.length, 8, "untypedGreeting.length")
}

test "untyped module-level String val readable from a helper function (#5298)" {
  assertEqualInt(untypedGreetingLength(), 8, "untypedGreetingLength()")
}

test "untyped negative-literal Int val infers Int, not MObject (#5300)" {
  assertEqualInt(untypedNegInt, -40, "untypedNegInt")
}

test "untyped negative-literal Int val usable in arithmetic via a helper function (#5300)" {
  assertEqualInt(untypedNegIntPlusTen(), -30, "untypedNegIntPlusTen()")
}
