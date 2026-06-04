// module_val_self_test.l — regression test for module-level `val` declarations
// (M5.2 stage 3: module-level vals as static readonly fields).
//
// Module-level vals at package scope are emitted as static readonly fields
// initialized in the host-class .cctor.  Two paths exist:
//
//   - Literal Int/Bool/Char/Unit inits: inlined into `constValues` by the
//     token pre-scan; `EPath` emits `ldc.i4` directly (no static field).
//   - All other inits (String literals, binary ops, function calls, etc.):
//     emitted as a static field; `EPath` emits `ldsfld <field-token>`.
//
// The tests below exercise both paths and verify that function bodies can
// read module-level vals of each kind at runtime.
//
// Runs in CI via:
//
//   lyric test lyric-compiler/lyric/module_val_self_test.l

@test_module
package Lyric.ModuleValSelfTest

import Std.Core
import Std.Testing

// ── Literal inits (inline ldc.i4 path) ────────────────────────────────────────
// These do NOT emit a static FieldDef — isLiteralI4ExprMsilWithEnv returns true,
// the pre-scan skips token allocation, and EPath emits ldc.i4 directly.

val literalInt: Int = 42
val literalBool: Bool = true
val derivedLit: Int = literalInt    // EPath referencing an earlier literal val

// ── Non-literal inits (static field path) ─────────────────────────────────────
// isLiteralI4ExprMsilWithEnv returns false → FieldDef row + ldsfld.

val greeting: String = "Hello, World"
val computedSum: Int = 1 + 1        // EBinop → non-literal, static field
val negated: Int = 0 - 55           // EBinop → non-literal, static field

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
