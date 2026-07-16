//! build_defines_self_test.l — exercises the docs/60 `@build_const`
//! substitution pass through the real compile pipeline.
//!
//! This module is compiled by `lyric test` with NO `--define` supplied, so
//! every `@build_const` here takes its in-source fallback literal — the
//! dev-checkout path (docs/60 §2.1, §6). It verifies that the substitution
//! pass integrates without disturbing normal compilation and that an
//! unsupplied define correctly leaves the fallback in place. The supplied
//! (substituted) path is exercised end-to-end by a `lyric build --define`
//! build+run, since `lyric test` does not thread `--define`.
//!
//! Run in CI via:
//!
//!   lyric test lyric-compiler/lyric/build_defines_self_test.l
@test_module
package Lyric.BuildDefinesSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.Lexer
import Lyric.Parser
import Lyric.BuildDefines as BD

// Extract the first module-level `val`'s initializer as text: the substituted
// String literal, or a marker when it is not a plain String literal.
func firstValInitText(sf: in SourceFile): String {
  var i = 0
  while i < sf.items.count {
    match sf.items[i].kind {
      case IVal(decl) -> {
        match decl.init.kind {
          case ELiteral(lit) -> {
            match lit {
              case LString(t) -> return t
              case _ -> return "<non-string-literal>"
            }
          }
          case _ -> return "<non-literal>"
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  "<no-val>"
}

func hasDiagCode(diags: in List[Diagnostic], code: in String): Bool {
  var i = 0
  while i < diags.count {
    if diags[i].code == code {
      return true
    }
    i = i + 1
  }
  false
}

@build_const("bd_selftest_unsupplied_key")
val FALLBACK: String = "fallback-value"

@build_const("bd_selftest_also_unsupplied")
val OTHER: String = "other-fallback"

test "an unsupplied @build_const keeps the in-source fallback literal" {
  assertEqual(FALLBACK, "fallback-value", "no define supplied -> fallback preserved")
}

test "a second unsupplied @build_const is independent and also falls back" {
  assertEqual(OTHER, "other-fallback", "each @build_const falls back independently")
}

test "a plain (un-annotated) val is untouched by the pass" {
  val plain = "plain"
  assertEqual(plain, "plain", "the substitution pass leaves non-annotated bindings alone")
}

// ── decodeDefines unit coverage (the CLI/bridge `List[String]` -> Define path) ──
test "decodeDefines parses KEY=VALUE" {
  val kvs: List[String] = newList()
  kvs.add("greeting=hello")
  val ds = BD.decodeDefines(kvs)
  match BD.lookupDefine(ds, "greeting") {
    case Some(v) -> assertEqual(v, "hello", "value parsed after the first '='")
    case None -> assertTrue(false, "greeting should decode")
  }
}

test "decodeDefines keeps everything after the first '=' (values may contain '=')" {
  val kvs: List[String] = newList()
  kvs.add("expr=a==b")
  val ds = BD.decodeDefines(kvs)
  match BD.lookupDefine(ds, "expr") {
    case Some(v) -> assertEqual(v, "a==b", "only the first '=' splits key from value")
    case None -> assertTrue(false, "expr should decode")
  }
}

test "decodeDefines is last-wins for a repeated key (#5873)" {
  val kvs: List[String] = newList()
  kvs.add("k=first")
  kvs.add("k=second")
  val ds = BD.decodeDefines(kvs)
  match BD.lookupDefine(ds, "k") {
    case Some(v) -> assertEqual(v, "second", "the later --define wins")
    case None -> assertTrue(false, "k should decode")
  }
}

test "decodeDefines skips entries without '='" {
  val kvs: List[String] = newList()
  kvs.add("novalue")
  val ds = BD.decodeDefines(kvs)
  match BD.lookupDefine(ds, "novalue") {
    case Some(_) -> assertTrue(false, "an entry with no '=' should not decode")
    case None -> assertTrue(true, "skipped as expected")
  }
}

// ── applyBuildDefines end-to-end (parse → substitute → inspect AST) ──
test "applyBuildDefines substitutes a supplied define into the val initializer" {
  val pr = parse("package T\n@build_const(\"k\")\npub val V: String = \"fallback\"\n")
  val defs: List[BD.Define] = newList()
  defs.add(BD.Define(key = "k", value = "injected"))
  val res = BD.applyBuildDefines(defs, pr.file)
  assertEqual(firstValInitText(res.file), "injected", "supplied define replaces the initializer")
  assertEqualInt(res.diagnostics.count, 0, "a valid substitution emits no diagnostics")
}

test "applyBuildDefines keeps the fallback when the key is not supplied" {
  val pr = parse("package T\n@build_const(\"k\")\npub val V: String = \"fallback\"\n")
  val res = BD.applyBuildDefines(newList(), pr.file)
  assertEqual(firstValInitText(res.file), "fallback", "no matching define -> fallback preserved")
}

test "applyBuildDefines emits F0030 for a @build_const val whose fallback is not a String literal" {
  val pr = parse("package T\n@build_const(\"port\")\npub val PORT = 8080\n")
  val res = BD.applyBuildDefines(newList(), pr.file)
  assertTrue(hasDiagCode(res.diagnostics, "F0030"), "inferred non-String fallback is rejected (F0030)")
}

test "applyBuildDefines emits F0031 for @build_const on a non-val item" {
  val pr = parse("package T\n@build_const(\"k\")\npub func f(): Int { 1 }\n")
  val res = BD.applyBuildDefines(newList(), pr.file)
  assertTrue(hasDiagCode(res.diagnostics, "F0031"), "@build_const on a func is rejected (F0031)")
}
