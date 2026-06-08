//! middle_end_passes_jvm_self_test.l — CI gate for the target-agnostic
//! middle-end passes wired into the self-hosted JVM bridge in band J2
//! (docs/44 §5 J2, #2665, epic #2663).
//!
//! Before J2, `jvm/bridge.l` ran only `typecheck → modecheck → elaborate →
//! derive → monoFile` and went straight to codegen — skipping aspect weaving,
//! `@cfg` erasure, and cross-package generic monomorphization that the MSIL
//! bridge already ran.  J2 ports those passes into the JVM bridge's
//! single-file (`compileToJar`) and bundled (`compileToJarBundled` via
//! `runMiddleEnd`) paths, mirroring the MSIL bridge's pass order.
//!
//! Run via the native test runner on the JVM target:
//!
//!   lyric test --target jvm lyric-compiler/jvm/middle_end_passes_jvm_self_test.l
//!
//! `lyric test` synthesises a runnable program from the `test` blocks and
//! compiles it IN-PROCESS through the self-hosted `Jvm.Bridge`
//! (`compileToJarBundled`), then runs it under `java` and asserts every
//! embedded assertion held.  Imports only `Std.*`, so no
//! `LYRIC_LOAD_COMPILER=1` is needed.
//!
//! Coverage (one cluster per J2-wired pass that is runtime-observable on the
//! JVM target):
//!   * `@cfg` erasure (M-4): an item gated on an inactive feature is dropped
//!     before type-check, so a same-named ungated fallback is the one that
//!     runs.  `lyric test` passes an empty active-feature set, so any
//!     `@cfg(feature = "X")` item erases — exactly the behaviour the MSIL
//!     project path applies, now wired on JVM via
//!     `compileToJarBundledWithFeatures`.
//!   * Aspect weaving (B-3): an `@inline_template` `around` aspect replaces a
//!     matched function's body with the rewritten template (`args.<param>`
//!     resolved to the bound argument), so the function returns the template's
//!     computed value at runtime.
//!
//! NOTE on `?`/`try` error-propagation (also wired by J2): the `?` pass IS
//! wired into both JVM bridge paths (and verified against the MSIL bridge by
//! `lyric-compiler/lyric/propagate_self_test.l`).  Its lowered output, however,
//! constructs and pattern-matches the generic `Result[T, E]` / `Option[T]`
//! types, which the JVM backend still erases to `Object` (docs/44 §5 M-1, a
//! MAJOR finding scheduled for band J4, #1707/#2574).  Until JVM generics land,
//! a `?`-using function cannot run under `java` (generic `Result` construction
//! VerifyErrors independently of `?`).  A runtime-observable JVM `?` assertion
//! is therefore deferred to J4 alongside the generics work; the pass wiring
//! itself is exercised end-to-end on MSIL today.
@test_module
package Jvm.MiddleEndPassesJvmSelfTest

import Std.Core
import Std.Testing

// ─────────────────────────────────────────────────────────────────────────────
// §1. `@cfg` erasure (M-4).
//
// `pickImpl` is declared twice: once gated on a feature that is never active
// (erased before type-check), once ungated.  Without cfg erasure the two
// declarations would collide; with it, only the ungated `42` survives.
// ─────────────────────────────────────────────────────────────────────────────
@cfg(feature = "never_active_j2_feature")
func pickImpl(): Int {
  999
}

func pickImpl(): Int {
  42
}

@cfg(feature = "never_active_j2_feature")
func pickLabel(): String {
  "gated"
}

func pickLabel(): String {
  "real"
}

test "@cfg erases an inactive-feature function (Int)" {
  assertEqualInt(pickImpl(), 42, "inactive-feature @cfg func erased; ungated fallback (42) runs")
}

test "@cfg erases an inactive-feature function (String)" {
  assertEqual(pickLabel(), "real", "inactive-feature @cfg func erased; ungated fallback runs")
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Aspect weaving (B-3) via `@inline_template`.
//
// The `around(args) -> ret` template body replaces the matched function's
// body; `args.x` is rewritten to the bound parameter `x`.  The woven function
// therefore returns the template's computed value (`x + x`) at runtime, which
// only happens if the weaver actually ran before codegen.
// ─────────────────────────────────────────────────────────────────────────────
@inline_template
pub aspect Doubler {
  matches: name like "wovenDouble*"
  around(args) -> ret {
    val base = args.x
    base + base
  }
}

@inline_template
pub aspect Tripler {
  matches: name like "wovenTriple*"
  around(args) -> ret {
    val base = args.x
    base + base + base
  }
}

// The source bodies return the raw argument; weaving rewrites them to the
// template, so the asserted runtime values prove the weave happened.
func wovenDouble(x: in Int): Int {
  x
}

func wovenTriple(x: in Int): Int {
  x
}

test "weave rewrites a matched function to its @inline_template body (double)" {
  assertEqualInt(wovenDouble(21), 42, "around-template doubled the argument (weave ran)")
}

test "weave rewrites a matched function to its @inline_template body (triple)" {
  assertEqualInt(wovenTriple(14), 42, "around-template tripled the argument (weave ran)")
}

// A function the aspects do NOT match is left untouched — confirms weaving is
// selective, not a blanket body rewrite.
func unwoven(x: in Int): Int {
  x
}

test "weave leaves a non-matching function untouched" {
  assertEqualInt(unwoven(42), 42, "non-matching function body unchanged by weave")
}
