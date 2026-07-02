//! extern_param_jvm_self_test.l — CI gate for #3334: an `extern type` value used
//! as a function parameter or return type must resolve to the real JVM class in
//! the method descriptor, not the same-package `<pkg>/<Alias>` fallback.
//!
//! Before the fix, `typeExprToJvm` mapped a parameter/return `TRef` named after
//! an `extern type` alias (e.g. `JBAOS`) to `JRef("<pkg>/JBAOS")`, so the
//! emitted descriptor referenced `Main/JBAOS` and the program died at runtime
//! with `NoClassDefFoundError: Main/JBAOS`.  `typeExprToJvmExtern` now consults
//! the file's extern-type table in both the registered `JvmFuncSig`
//! (`collectFileSigs`) and the emitted method (`lowerFunc` /
//! `setupStaticParamSlotsAndHolders`), keeping the two in lockstep.
//!
//! Run via the native test runner on the JVM target:
//!
//!   lyric test --target jvm lyric-compiler/jvm/extern_param_jvm_self_test.l
//!
//! Compiled in-process through the self-hosted `Jvm.Bridge` and run under
//! `java`.  Imports only `Std.*`.
@test_module
package Lyric.ExternParamJvmSelfTest

import Std.Core
import Std.Testing

extern type JBAOS = "java.io.ByteArrayOutputStream"

// Extern handle as a parameter, driven through a loop inside the callee — also
// confirms the #3307 frame-typing fix holds for an extern *parameter* local.
func fill(sink: in JBAOS, n: in Int): Unit {
  var i = 0
  while i < n {
    sink.write(65)
    i = i + 1
  }
}

// Extern handle as a return type.
func makeSink(): JBAOS {
  JBAOS.new()
}

test "extern-type parameter resolves to the real JVM class (#3334)" {
  val sink = JBAOS.new()
  fill(sink, 4)
  assertEqualInt(sink.size(), 4, "fill(sink, 4) wrote 4 bytes through an extern param")
}

test "extern-type return value is usable by the caller (#3334)" {
  val s = makeSink()
  s.write(66)
  s.write(66)
  assertEqualInt(s.size(), 2, "extern handle returned from makeSink() accepts writes")
}

test "extern handle round-trips through create -> pass -> read (#3334)" {
  val sink = makeSink()
  fill(sink, 7)
  assertEqualInt(sink.size(), 7, "makeSink() then fill(_, 7) yields size() == 7")
}

// ── Discarded FFI call values (epic #2663) ────────────────────────────────────
// An if-without-else whose trailing expression is a non-void FFI call leaked
// the call's return value onto the operand stack at the join label; inside a
// loop the leaked value reached a back-edge branch target and failed
// StackMapTable verification (the Std.ProcessCaptureHost
// `proc.destroyForcibly()` poll-loop shape).
extern type JSB = "java.lang.StringBuilder"

extern type JSys = "java.lang.System"

test "if-without-else discards a trailing ref-returning FFI call value" {
  val sb = JSB.new()
  var n = 0
  while n < 3 {
    if n > 0 {
      sb.append(",")
    }
    sb.append(toString(n))
    n = n + 1
  }
  assertEqual(sb.toString(), "0,1,2", "append() returns StringBuilder; the if-tail value must be discarded at the join")
}

test "statement-position long-returning FFI call is discarded with pop2" {
  var i = 0
  while i < 2 {
    JSys.nanoTime()
    if i == 0 {
      JSys.nanoTime()
    }
    i = i + 1
  }
  assertEqualInt(i, 2, "loop completed after discarding category-2 long values in statement and if-tail position")
}
