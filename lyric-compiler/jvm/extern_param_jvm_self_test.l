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
