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
//! Manual run:
//!   ./bin/lyric run lyric-compiler/msil/msil_self_test_m86.l
//!
//! Expected stdout (all checks print "=true"):
//!   val_init_ok=true
//!   val_append_ok=true
//!   val_second_ok=true
//!
//! CI wiring: not yet wired — requires F# emitter test runner which cannot
//! be added per CLAUDE.md.  Tracked in #2983.
package Msil.SelfTestM86

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

func check(label: in String, ok: in Bool): Int {
  if ok {
    println(label + "=true")
    0
  } else {
    println(label + "=false")
    1
  }
}

func main(): Int {
  var fails = 0
  val _ = sbAppend(sharedSb, "hello")
  fails = fails + check("val_init_ok", sbStr(sharedSb) == "hello")

  val _ = sbAppend(sharedSb, "-world")
  fails = fails + check("val_append_ok", sbStr(sharedSb) == "hello-world")

  val _ = sbAppend(sharedSb2, "second")
  fails = fails + check("val_second_ok", sbStr(sharedSb2) == "second")
  fails
}
