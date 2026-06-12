//! msil_self_test_m86.l — Stage M86: package-level class-typed val .cctor (#1576).
//!
//! Exercises the fix for issue #1576: a package-level `val` whose initializer
//! is a non-literal class-typed expression (e.g., `val sb: SB = newSb()` where
//! `SB = "System.Text.StringBuilder"`) must emit and run a `.cctor` that stores
//! the constructed object into the backing static field with the correct CLR type
//! (CLASS + TypeRef, not degraded to `object`).
//!
//! Before the fix, `typeExprToMsilCtx` fell through to `MClass("Pkg.SB")` for
//! reference-type externs (the value-type branch short-circuited but the
//! reference-type case was missing), and `codegenMPackage` used the context-free
//! `typeExprToMsil` which also couldn't resolve extern CLR names.  Both caused
//! `bufMsilTypeWithCtx` to encode the field as `ELEMENT_TYPE_OBJECT`, so the
//! CLR loaded the field typed as `object` while the `.cctor` stored a real
//! `StringBuilder` — a type mismatch that either caused an NRE on access or
//! a `InvalidProgramException` at JIT time.
//!
//! Checks:
//!   * A package-level `val sb: SB = newSb()` initializes without NRE.
//!   * Append through the shared field accumulates correctly (proves the field
//!     holds a live object across calls).
//!   * A second class-typed package val (`val sb2: SB = newSb()`) is also
//!     initialized correctly (multiple .cctor entries).
//!
//! Run in CI via native `lyric test` (the auto_ffi_self_test.l precedent;
//! compiled in-process through the self-hosted `Msil.Bridge`):
//!
//!   lyric test --target dotnet lyric-compiler/msil/msil_self_test_m86.l
@test_module
package Msil.SelfTestM86

import Std.Core
import Std.Testing

extern type SB = "System.Text.StringBuilder"

@externTarget("System.Text.StringBuilder..ctor")
func newSb(): SB = ()

@externTarget("System.Text.StringBuilder.Append")
@externInstance
func sbAppend(sb: in SB, s: in String): SB = ()

@externTarget("System.Text.StringBuilder.ToString")
@externInstance
func sbStr(sb: in SB): String = ()

val sharedSb: SB = newSb()

val sharedSb2: SB = newSb()

test "package-level class-typed val initializes and accumulates via .cctor" {
  val _ = sbAppend(sharedSb, "hello")
  assertEqual(sbStr(sharedSb), "hello", "val_init_ok")
  val _ = sbAppend(sharedSb, "-world")
  assertEqual(sbStr(sharedSb), "hello-world", "val_append_ok")
}

test "second class-typed package val initializes independently" {
  val _ = sbAppend(sharedSb2, "second")
  assertEqual(sbStr(sharedSb2), "second", "val_second_ok")
}
