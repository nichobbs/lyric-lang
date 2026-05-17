// contract_elaborator_self_test.l — exercises the self-hosted
// `Lyric.ContractElaborator` library.  Compiled and executed by
// SelfHostedContractElaboratorTests.fs.  Exit 0 + "ok" in stdout
// means every assertion held.
package Lyric.ContractElaboratorSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.Lexer
import Lyric.Parser
import Lyric.ContractElaborator


// ─────────────────────────────────────────────────────────────────────────────
// Helpers — shape inspection of the elaborated AST.
// ─────────────────────────────────────────────────────────────────────────────

func parseAndElaborate(src: in String): SourceFile {
  val pr = parse(src)
  elaborateFile(pr.file)
}

func firstFunction(file: in SourceFile, name: in String): FunctionDecl {
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(fn) -> {
        if fn.name == name { return fn }
      }
      case _ -> {}
    }
    i = i + 1
  }
  panic("firstFunction: no function named '" + name + "'")
}

func bodyBlockOf(fn: in FunctionDecl): Block {
  match fn.body {
    case Some(b) -> {
      match b {
        case FBBlock(blk) -> blk
        case FBExpr(_)    -> panic("bodyBlockOf: function '" + fn.name + "' has FBExpr body")
      }
    }
    case None -> panic("bodyBlockOf: function '" + fn.name + "' has no body")
  }
}

// Statement-shape predicates.

func isAssertCall(s: in Statement): Bool {
  match s.kind {
    case SExpr(e) -> {
      match e.kind {
        case ECall(callee, _) -> {
          match callee.kind {
            case EPath(p) ->
              p.segments.count == 1 and p.segments[0] == "assert"
            case _ -> false
          }
        }
        case _ -> false
      }
    }
    case _ -> false
  }
}

func isLetBinding(s: in Statement): Bool {
  match s.kind {
    case SLocal(b) -> {
      match b {
        case LBLet(_, _, _) -> true
        case _              -> false
      }
    }
    case _ -> false
  }
}

func letName(s: in Statement): String {
  match s.kind {
    case SLocal(b) -> {
      match b {
        case LBLet(n, _, _) -> n
        case _              -> ""
      }
    }
    case _ -> ""
  }
}

func isReturnPath(s: in Statement, expected: in String): Bool {
  match s.kind {
    case SReturn(valOpt) -> {
      match valOpt {
        case Some(e) -> {
          match e.kind {
            case EPath(p) ->
              p.segments.count == 1 and p.segments[0] == expected
            case _ -> false
          }
        }
        case None -> false
      }
    }
    case _ -> false
  }
}

func isReturnNone(s: in Statement): Bool {
  match s.kind {
    case SReturn(valOpt) -> {
      match valOpt {
        case Some(_) -> false
        case None    -> true
      }
    }
    case _ -> false
  }
}

func isTrailingPathSExpr(s: in Statement, expected: in String): Bool {
  match s.kind {
    case SExpr(e) -> {
      match e.kind {
        case EPath(p) ->
          p.segments.count == 1 and p.segments[0] == expected
        case _ -> false
      }
    }
    case _ -> false
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// §1. Identity: empty contracts → identity-shaped output.
// ─────────────────────────────────────────────────────────────────────────────

func testNoContractsPassthrough(): Unit {
  val src = "package P\nfunc f(): Int { 1 }\n"
  val file = parseAndElaborate(src)
  val fn   = firstFunction(file, "f")
  val blk  = bodyBlockOf(fn)
  assertEqualInt(blk.statements.count, 1, "no-contracts: body length unchanged")
  assertTrue(not isAssertCall(blk.statements[0]), "no-contracts: no assert injected")
}


// ─────────────────────────────────────────────────────────────────────────────
// §2. Single `requires:` clause.
// ─────────────────────────────────────────────────────────────────────────────

func testSingleRequiresPrepended(): Unit {
  val src = "package P\nfunc f(x: in Int): Int\n  requires: x > 0\n{ x + 1 }\n"
  val file = parseAndElaborate(src)
  val fn   = firstFunction(file, "f")
  val blk  = bodyBlockOf(fn)
  // [0] = assert(x > 0); [1] = trailing SExpr (no ensures so unchanged).
  assertEqualInt(blk.statements.count, 2, "single-req: 1 assert + 1 trailing stmt")
  assertTrue(isAssertCall(blk.statements[0]), "single-req: stmt[0] is assert(...)")
  // Original contracts list preserved.
  assertEqualInt(fn.contracts.count, 1, "single-req: contracts list preserved")
}


// ─────────────────────────────────────────────────────────────────────────────
// §3. Multiple `requires:` clauses preserved in source order.
// ─────────────────────────────────────────────────────────────────────────────

func testMultipleRequires(): Unit {
  val src =
    "package P\n" +
    "func f(x: in Int, y: in Int): Int\n" +
    "  requires: x > 0\n" +
    "  requires: y > 0\n" +
    "  requires: x + y < 100\n" +
    "{ x + y }\n"
  val file = parseAndElaborate(src)
  val fn   = firstFunction(file, "f")
  val blk  = bodyBlockOf(fn)
  // 3 asserts + 1 trailing.
  assertEqualInt(blk.statements.count, 4, "multi-req: 3 asserts + 1 trailing")
  assertTrue(isAssertCall(blk.statements[0]), "multi-req: stmt[0] assert")
  assertTrue(isAssertCall(blk.statements[1]), "multi-req: stmt[1] assert")
  assertTrue(isAssertCall(blk.statements[2]), "multi-req: stmt[2] assert")
}


// ─────────────────────────────────────────────────────────────────────────────
// §4. Single `ensures:` rewrites the trailing SExpr.
// ─────────────────────────────────────────────────────────────────────────────

func testSingleEnsuresTrailing(): Unit {
  val src =
    "package P\n" +
    "func f(): Int\n" +
    "  ensures: result >= 0\n" +
    "{ 7 }\n"
  val file = parseAndElaborate(src)
  val fn   = firstFunction(file, "f")
  val blk  = bodyBlockOf(fn)
  // [0] = let __lyric_result_0 = 7; [1] = assert(__lyric_result_0 >= 0); [2] = __lyric_result_0
  assertEqualInt(blk.statements.count, 3, "ens-trailing: 3 stmts after elab")
  assertTrue(isLetBinding(blk.statements[0]), "ens-trailing: stmt[0] is let")
  assertEqual(letName(blk.statements[0]), "__lyric_result_0", "ens-trailing: synthetic name")
  assertTrue(isAssertCall(blk.statements[1]), "ens-trailing: stmt[1] is assert")
  assertTrue(isTrailingPathSExpr(blk.statements[2], "__lyric_result_0"),
             "ens-trailing: stmt[2] yields synthetic local")
}


// ─────────────────────────────────────────────────────────────────────────────
// §5. Explicit `return e` is rewritten to bind + assert + return-name.
// ─────────────────────────────────────────────────────────────────────────────

func testEnsuresWithExplicitReturn(): Unit {
  val src =
    "package P\n" +
    "func f(): Int\n" +
    "  ensures: result == 5\n" +
    "{\n" +
    "  return 5\n" +
    "}\n"
  val file = parseAndElaborate(src)
  val fn   = firstFunction(file, "f")
  val blk  = bodyBlockOf(fn)
  // [0] = let __lyric_result_0 = 5; [1] = assert(...); [2] = return __lyric_result_0
  assertEqualInt(blk.statements.count, 3, "ens-return: 3 stmts after elab")
  assertTrue(isLetBinding(blk.statements[0]), "ens-return: stmt[0] is let")
  assertTrue(isAssertCall(blk.statements[1]),  "ens-return: stmt[1] is assert")
  assertTrue(isReturnPath(blk.statements[2], "__lyric_result_0"),
             "ens-return: stmt[2] returns synthetic local")
}


// ─────────────────────────────────────────────────────────────────────────────
// §6. `return` (no value) keeps the bare return but prepends ensures.
// ─────────────────────────────────────────────────────────────────────────────

func testEnsuresWithBareReturn(): Unit {
  val src =
    "package P\n" +
    "func f(): Unit\n" +
    "  ensures: true\n" +
    "{\n" +
    "  return\n" +
    "}\n"
  val file = parseAndElaborate(src)
  val fn   = firstFunction(file, "f")
  val blk  = bodyBlockOf(fn)
  // [0] = assert(true); [1] = return
  assertEqualInt(blk.statements.count, 2, "ens-bare-return: 2 stmts after elab")
  assertTrue(isAssertCall(blk.statements[0]), "ens-bare-return: stmt[0] is assert")
  assertTrue(isReturnNone(blk.statements[1]), "ens-bare-return: stmt[1] is bare return")
}


// ─────────────────────────────────────────────────────────────────────────────
// §7. requires + ensures combined on the same function.
// ─────────────────────────────────────────────────────────────────────────────

func testRequiresAndEnsures(): Unit {
  val src =
    "package P\n" +
    "func f(x: in Int): Int\n" +
    "  requires: x > 0\n" +
    "  ensures:  result > 0\n" +
    "{ x + 1 }\n"
  val file = parseAndElaborate(src)
  val fn   = firstFunction(file, "f")
  val blk  = bodyBlockOf(fn)
  // [0] = assert(x > 0)              [requires]
  // [1] = let __lyric_result_0 = x+1 [trailing rewrite]
  // [2] = assert(__lyric_result_0 > 0)
  // [3] = __lyric_result_0
  assertEqualInt(blk.statements.count, 4, "req+ens: 4 stmts")
  assertTrue(isAssertCall(blk.statements[0]), "req+ens: stmt[0] requires assert")
  assertTrue(isLetBinding(blk.statements[1]), "req+ens: stmt[1] let binding")
  assertTrue(isAssertCall(blk.statements[2]), "req+ens: stmt[2] ensures assert")
  assertTrue(isTrailingPathSExpr(blk.statements[3], "__lyric_result_0"),
             "req+ens: stmt[3] yields synthetic local")
}


// ─────────────────────────────────────────────────────────────────────────────
// §8. Multiple ensures clauses generate one assert each.
// ─────────────────────────────────────────────────────────────────────────────

func testMultipleEnsures(): Unit {
  val src =
    "package P\n" +
    "func f(): Int\n" +
    "  ensures: result >= 0\n" +
    "  ensures: result < 100\n" +
    "{ 42 }\n"
  val file = parseAndElaborate(src)
  val fn   = firstFunction(file, "f")
  val blk  = bodyBlockOf(fn)
  // [0] = let; [1] = assert (result >= 0); [2] = assert (result < 100); [3] = trailing path
  assertEqualInt(blk.statements.count, 4, "multi-ens: 4 stmts")
  assertTrue(isLetBinding(blk.statements[0]), "multi-ens: stmt[0] let")
  assertTrue(isAssertCall(blk.statements[1]), "multi-ens: stmt[1] assert")
  assertTrue(isAssertCall(blk.statements[2]), "multi-ens: stmt[2] assert")
  assertTrue(isTrailingPathSExpr(blk.statements[3], "__lyric_result_0"),
             "multi-ens: stmt[3] yields local")
}


// ─────────────────────────────────────────────────────────────────────────────
// §9. @axiom functions are skipped (no body to elaborate).
// ─────────────────────────────────────────────────────────────────────────────

func testAxiomSkipped(): Unit {
  val src =
    "@proof_required\n" +
    "package P\n" +
    "@axiom\n" +
    "func ax(p: in Bool): Unit\n" +
    "  requires: p\n" +
    "\n"
  val file = parseAndElaborate(src)
  val fn   = firstFunction(file, "ax")
  match fn.body {
    case None -> {}                          // expected: no body, untouched
    case Some(_) -> { assertTrue(false, "axiom: should have no body") }
  }
  // Original requires clause is still present on the contract list.
  assertEqualInt(fn.contracts.count, 1, "axiom: contract preserved")
}


// ─────────────────────────────────────────────────────────────────────────────
// §10. Functions without a body (signatures) pass through unchanged.
// ─────────────────────────────────────────────────────────────────────────────

func testSignaturePassthrough(): Unit {
  val src =
    "package P\n" +
    "func f(x: in Int): Int\n" +
    "  requires: x > 0\n" +
    "\n"
  val file = parseAndElaborate(src)
  val fn   = firstFunction(file, "f")
  match fn.body {
    case None -> {}
    case Some(_) -> { assertTrue(false, "sig: expected no body") }
  }
  assertEqualInt(fn.contracts.count, 1, "sig: contracts preserved")
}


// ─────────────────────────────────────────────────────────────────────────────
// §11. Original `contracts` list is preserved on the elaborated decl.
// ─────────────────────────────────────────────────────────────────────────────

func testContractsListPreserved(): Unit {
  val src =
    "package P\n" +
    "func f(x: in Int): Int\n" +
    "  requires: x > 0\n" +
    "  ensures: result > 0\n" +
    "{ x }\n"
  val file = parseAndElaborate(src)
  val fn   = firstFunction(file, "f")
  // 2 clauses survived (1 requires, 1 ensures).
  assertEqualInt(fn.contracts.count, 2, "contracts-preserved: 2 clauses")
  var hasReq = false
  var hasEns = false
  var i = 0
  while i < fn.contracts.count {
    match fn.contracts[i] {
      case CCRequires(_, _) -> { hasReq = true }
      case CCEnsures(_, _)  -> { hasEns = true }
      case _                -> {}
    }
    i = i + 1
  }
  assertTrue(hasReq, "contracts-preserved: CCRequires retained")
  assertTrue(hasEns, "contracts-preserved: CCEnsures retained")
}


// ─────────────────────────────────────────────────────────────────────────────
// §12. Synthetic names are unique across multiple returns in one body.
// ─────────────────────────────────────────────────────────────────────────────

func testSyntheticNamesUnique(): Unit {
  val src =
    "package P\n" +
    "func f(x: in Int): Int\n" +
    "  ensures: result > 0\n" +
    "{\n" +
    "  return 1\n" +
    "  return 2\n" +
    "}\n"
  val file = parseAndElaborate(src)
  val fn   = firstFunction(file, "f")
  val blk  = bodyBlockOf(fn)
  // First top-level return is rewritten to use __lyric_result_0; second to __lyric_result_1.
  // Statements: [let __lyric_result_0 = 1, assert, return __lyric_result_0,
  //              let __lyric_result_1 = 2, assert, return __lyric_result_1]
  assertEqualInt(blk.statements.count, 6, "unique-names: 6 stmts")
  assertEqual(letName(blk.statements[0]), "__lyric_result_0", "unique-names: first synth")
  assertEqual(letName(blk.statements[3]), "__lyric_result_1", "unique-names: second synth")
}


// ─────────────────────────────────────────────────────────────────────────────
// §13. File-level identity preserved (package decl, imports, items count).
// ─────────────────────────────────────────────────────────────────────────────

func testFileLevelIdentity(): Unit {
  val src =
    "package P\n" +
    "import Std.Core\n" +
    "func a(): Int { 1 }\n" +
    "func b(): Int\n" +
    "  requires: true\n" +
    "{ 2 }\n"
  val file = parseAndElaborate(src)
  assertEqualInt(file.items.count, 2, "file-id: 2 items preserved")
  assertEqualInt(file.imports.count, 1, "file-id: 1 import preserved")
  assertTrue(file.packageDecl.path.segments.count == 1, "file-id: package decl preserved")
  assertEqual(file.packageDecl.path.segments[0], "P", "file-id: package name preserved")
}


// ─────────────────────────────────────────────────────────────────────────────
// §14. Non-function items are passed through unchanged.
// ─────────────────────────────────────────────────────────────────────────────

func testNonFuncItemsPassthrough(): Unit {
  val src =
    "package P\n" +
    "pub record Pair { x: Int, y: Int }\n" +
    "func f(): Int\n" +
    "  requires: true\n" +
    "{ 1 }\n"
  val file = parseAndElaborate(src)
  // Two items: the record and the function; record should be untouched.
  assertEqualInt(file.items.count, 2, "non-func: 2 items")
  match file.items[0].kind {
    case IRecord(_) -> {}
    case _          -> { assertTrue(false, "non-func: stmt[0] should be IRecord") }
  }
  // The function still got elaborated.
  val fn = firstFunction(file, "f")
  val blk = bodyBlockOf(fn)
  assertEqualInt(blk.statements.count, 2, "non-func: function elaborated (1 require + 1 trail)")
}


// ─────────────────────────────────────────────────────────────────────────────
// Test runner.
// ─────────────────────────────────────────────────────────────────────────────

func main(): Unit {
  testNoContractsPassthrough()
  testSingleRequiresPrepended()
  testMultipleRequires()
  testSingleEnsuresTrailing()
  testEnsuresWithExplicitReturn()
  testEnsuresWithBareReturn()
  testRequiresAndEnsures()
  testMultipleEnsures()
  testAxiomSkipped()
  testSignaturePassthrough()
  testContractsListPreserved()
  testSyntheticNamesUnique()
  testFileLevelIdentity()
  testNonFuncItemsPassthrough()
  println("contract-elaborator self-test: ok")
}
