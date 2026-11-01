//! msil_bare_enum_case_guard_self_test.l - codegen-level regression test for
//! T0222, the bare-enum-case backstop of the MSIL backend (docs/01 §9.2,
//! #8667).
//!
//! A bare enum case (`Error`, no `Enum.` prefix, no expected enum type) is
//! resolved by scope: the current package's own enum, else an enum of an
//! imported package.  When several enums declare the case and none is visible
//! the lowering used to read the first-registered one, an order that differs
//! between a bundle and its restored dependencies, and so emitted another
//! enum's ordinal without a word (#8648).  It is now T0222.
//!
//! No source program reaches the backstop today: the type checker rejects a
//! bare case no import makes visible (T0020, T0123) before codegen runs, and
//! a survey of every project in this repository and of all 73 cloud-agents
//! entries found the fallback unreached.  So, like
//! `msil_operand_guard_self_test.l`, this test registers two same-case enums
//! straight into a `CodegenCtx` and calls the resolver every bare-case lowering
//! site uses, asserting the positioned diagnostic - and that a visible
//! declarer, or a case only one enum declares, is not reported.
//!
//! The JVM and native twins are covered by `bare_enum_case_t0222_self_test.l`.
//!
//! Run in CI via native `lyric test` (imports `Msil.Codegen`, resolved by
//! linking the already-compiled compiler DLLs as restored deps):
//!
//!   lyric test --target dotnet lyric-compiler/msil/msil_bare_enum_case_guard_self_test.l
@test_module
package Msil.BareEnumCaseGuardSelfTest

import Msil.Codegen
import Msil.Lowering
import Lyric.Lexer
import Lyric.Parser
import Std.Core
import Std.Collections
import Std.Testing

func spanAt(line: in Int, col: in Int): Span {
  val p = Position(offset = line * 100 + col, line = line, column = col)
  Span(startPos = p, endPos = p)
}

func enumDecl(name: in String, caseNames: in List[String]): EnumDecl {
  val cases: List[EnumCase] = newList()
  for c in caseNames {
    cases.add(EnumCase(docComments = newList(), annotations = newList(), name = c, span = spanAt(1, 1)))
  }
  EnumDecl(name = name, cases = cases, span = spanAt(1, 1))
}

// `GuardA.Mood { Calm, Error }` registers before `GuardB.Sev { Error, Warning }`:
// `Error` is 1 in the first and 0 in the second.
func ctxWithTwoErrorEnums(): CodegenCtx {
  val cctx = newCodegenCtx("GuardApp", newList(), newList(), 1, 0)
  registerEnumDeclMsil(cctx, "GuardA", enumDecl("Mood", ["Calm", "Error"]))
  registerEnumDeclMsil(cctx, "GuardB", enumDecl("Sev", ["Error", "Warning"]))
  cctx
}

func funcIn(pkg: in String): FuncCtx {
  makeFuncCtxMsil(pkg, pkg + ".Program", "main", 0, MVoid)
}

func t0222Count(cctx: in CodegenCtx): Int {
  var n = 0
  for d in cctx.diagnostics {
    if d.code == "T0222" {
      n = n + 1
    }
  }
  n
}

test "no declarer is visible: T0222, positioned at the reference" {
  val cctx = ctxWithTwoErrorEnums()
  val ord = resolveBareEnumCaseOrdinalByScope(cctx, funcIn("GuardApp"), "Error", spanAt(7, 13))
  assertEqualInt(t0222Count(cctx), 1, "one T0222")
  assertEqualInt(cctx.diagnostics[0].span.startPos.line, 7, "line")
  assertEqualInt(cctx.diagnostics[0].span.startPos.column, 13, "column")
  assertTrue(cctx.diagnostics[0].message.contains("GuardA.Mood"), "names the first declaring enum")
  assertTrue(cctx.diagnostics[0].message.contains("GuardB.Sev"), "names the second declaring enum")
  assertTrue(isSome(ord), "codegen still produces a value so the build reports every error, not just the first")
}

test "the current package's own enum wins" {
  val cctx = ctxWithTwoErrorEnums()
  val ord = resolveBareEnumCaseOrdinalByScope(cctx, funcIn("GuardB"), "Error", spanAt(1, 1))
  assertEqualInt(t0222Count(cctx), 0, "no diagnostic")
  assertEqualInt(unwrapOr(ord, -1), 0, "Sev.Error")
  val other = ctxWithTwoErrorEnums()
  val ordA = resolveBareEnumCaseOrdinalByScope(other, funcIn("GuardA"), "Error", spanAt(1, 1))
  assertEqualInt(t0222Count(other), 0, "no diagnostic")
  assertEqualInt(unwrapOr(ordA, -1), 1, "Mood.Error")
}

test "an imported package's enum is visible, not the first registered" {
  val cctx = ctxWithTwoErrorEnums()
  val imports: List[String] = newList()
  imports.add("GuardB")
  cctx.pkgImports.add("GuardApp", imports)
  val ord = resolveBareEnumCaseOrdinalByScope(cctx, funcIn("GuardApp"), "Error", spanAt(1, 1))
  assertEqualInt(t0222Count(cctx), 0, "no diagnostic")
  assertEqualInt(unwrapOr(ord, -1), 0, "Sev.Error through the import, though Mood registered first")
}

test "a case only one enum declares is never ambiguous" {
  val cctx = ctxWithTwoErrorEnums()
  val calm = resolveBareEnumCaseOrdinalByScope(cctx, funcIn("GuardApp"), "Calm", spanAt(1, 1))
  val warning = resolveBareEnumCaseOrdinalByScope(cctx, funcIn("GuardApp"), "Warning", spanAt(1, 1))
  assertEqualInt(t0222Count(cctx), 0, "no diagnostic")
  assertEqualInt(unwrapOr(calm, -1), 0, "Mood.Calm")
  assertEqualInt(unwrapOr(warning, -1), 1, "Sev.Warning")
}

test "a package registered twice is one declarer, not an ambiguity" {
  val cctx = newCodegenCtx("GuardApp", newList(), newList(), 1, 0)
  registerEnumDeclMsil(cctx, "GuardA", enumDecl("Mood", ["Calm", "Error"]))
  registerEnumDeclMsil(cctx, "GuardA", enumDecl("Mood", ["Calm", "Error"]))
  val ord = resolveBareEnumCaseOrdinalByScope(cctx, funcIn("GuardApp"), "Error", spanAt(1, 1))
  assertEqualInt(t0222Count(cctx), 0, "a diamond-resolved restored package registers twice (#6638)")
  assertEqualInt(unwrapOr(ord, -1), 1, "Mood.Error")
}
