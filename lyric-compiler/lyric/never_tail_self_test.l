//! never_tail_self_test.l — regression test for #5652 (closes #5563 item 3
//! too): a tail-position call to a `: Never`-declared function (one that
//! always diverges via `panic`) inside a differently-typed (Int/Long/Double/
//! Bool/String) function crashed on MSIL with `System.InvalidProgramException`
//! at JIT time.
//!
//! Root cause: `TNever` erases to `MVoid` (`Msil.Codegen.typeExprToMsilCtx`),
//! so a bare tail-position call to a `Never`-declared function leaves nothing
//! on the operand stack.  `lowerFuncMsil`'s FBBlock arm only coerced a
//! `MVoid`-tailed body when the declared return was `object` (boxing/lifted-
//! lambda case), and the FBExpr arm discarded the lowered type entirely —
//! both then emitted a bare `ret` against an Int/Long/Double/Bool/String
//! return signature with an empty stack.  The JVM backend already handled
//! this correctly via `emitNeverTailReturn` (jvm/codegen/05_stmts.l).
//!
//! Both the block-tail (`{ …never… }`) and `= expr` (`= …never…`) body forms
//! are covered, across every scalar type the two backends distinguish.  Each
//! caller's ENTIRE body diverges (the call to the `Never`-returning helper is
//! unconditional), so invoking it always panics — what distinguishes a
//! correct compile from the bug is WHICH message is caught.  Pre-fix on MSIL,
//! invoking the caller crashes the JIT with `InvalidProgramException`
//! ("Common Language Runtime detected an invalid program" — a DIFFERENT
//! message from the helper's own `panic(...)`, though still catchable by a
//! `catch Bug` since `InvalidProgramException` derives from `System.Exception`
//! and the woven catch clause targets that base type).  Checking for the real
//! panic message therefore fails pre-fix and passes post-fix on both targets.
//!
//! Each test below inlines its own `try { … } catch Bug as e { … }` rather
//! than going through `Std.Testing.assertPanicsWith` — that helper routes the
//! call through a `fn: () -> Unit` closure parameter, which hits an unrelated,
//! pre-existing JVM-only bug where the caught `Bug`'s `.message` reads back as
//! a JVM lambda class descriptor instead of the real panic text (reproduced
//! independently against the untouched `closure_correctness_self_test.l`'s
//! "assertPanicsWith compiles and runs in test_module" case — not this
//! change's concern). Calling the never-returning helper directly inside a
//! plain `try` (no intervening closure) sidesteps that gap entirely.
//!
//! Run via `lyric test lyric-compiler/lyric/never_tail_self_test.l` on both
//! `--target dotnet` and `--target jvm` (mirrors `bitwise_self_test.l`).
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.NeverTailSelfTest

import Std.Core
import Std.Testing

func neverInt(): Never {
  panic("never-tail-int")
}

func neverLong(): Never {
  panic("never-tail-long")
}

func neverDouble(): Never {
  panic("never-tail-double")
}

func neverBool(): Never {
  panic("never-tail-bool")
}

func neverString(): Never {
  panic("never-tail-string")
}

// ── block-tail form: `func f(): T { neverX() }` ─────────────────────────────
func blockTailInt(): Int {
  neverInt()
}

func blockTailLong(): Long {
  neverLong()
}

func blockTailDouble(): Double {
  neverDouble()
}

func blockTailBool(): Bool {
  neverBool()
}

func blockTailString(): String {
  neverString()
}

// ── `= expr` form: `func f(): T = neverX()` ─────────────────────────────────
func exprTailInt(): Int = neverInt()

func exprTailLong(): Long = neverLong()

func exprTailDouble(): Double = neverDouble()

func exprTailBool(): Bool = neverBool()

func exprTailString(): String = neverString()

test "block-tail Never call in an Int-returning function panics with the real message" {
  var msg = ""
  try {
    blockTailInt()
  } catch Bug as e {
    msg = e.message
  }
  assertTrue(msg.contains("never-tail-int"), "blockTailInt panic message: " + msg)
}

test "block-tail Never call in a Long-returning function panics with the real message" {
  var msg = ""
  try {
    blockTailLong()
  } catch Bug as e {
    msg = e.message
  }
  assertTrue(msg.contains("never-tail-long"), "blockTailLong panic message: " + msg)
}

test "block-tail Never call in a Double-returning function panics with the real message" {
  var msg = ""
  try {
    blockTailDouble()
  } catch Bug as e {
    msg = e.message
  }
  assertTrue(msg.contains("never-tail-double"), "blockTailDouble panic message: " + msg)
}

test "block-tail Never call in a Bool-returning function panics with the real message" {
  var msg = ""
  try {
    blockTailBool()
  } catch Bug as e {
    msg = e.message
  }
  assertTrue(msg.contains("never-tail-bool"), "blockTailBool panic message: " + msg)
}

test "block-tail Never call in a String-returning function panics with the real message" {
  var msg = ""
  try {
    blockTailString()
  } catch Bug as e {
    msg = e.message
  }
  assertTrue(msg.contains("never-tail-string"), "blockTailString panic message: " + msg)
}

test "'= expr' Never call in an Int-returning function panics with the real message" {
  var msg = ""
  try {
    exprTailInt()
  } catch Bug as e {
    msg = e.message
  }
  assertTrue(msg.contains("never-tail-int"), "exprTailInt panic message: " + msg)
}

test "'= expr' Never call in a Long-returning function panics with the real message" {
  var msg = ""
  try {
    exprTailLong()
  } catch Bug as e {
    msg = e.message
  }
  assertTrue(msg.contains("never-tail-long"), "exprTailLong panic message: " + msg)
}

test "'= expr' Never call in a Double-returning function panics with the real message" {
  var msg = ""
  try {
    exprTailDouble()
  } catch Bug as e {
    msg = e.message
  }
  assertTrue(msg.contains("never-tail-double"), "exprTailDouble panic message: " + msg)
}

test "'= expr' Never call in a Bool-returning function panics with the real message" {
  var msg = ""
  try {
    exprTailBool()
  } catch Bug as e {
    msg = e.message
  }
  assertTrue(msg.contains("never-tail-bool"), "exprTailBool panic message: " + msg)
}

test "'= expr' Never call in a String-returning function panics with the real message" {
  var msg = ""
  try {
    exprTailString()
  } catch Bug as e {
    msg = e.message
  }
  assertTrue(msg.contains("never-tail-string"), "exprTailString panic message: " + msg)
}
