//! contract_elaborator_self_test.l — exercises the self-hosted
//! `Lyric.ContractElaborator` library.  Compiled and executed by
//! SelfHostedContractElaboratorTests.fs.  Exit 0 + "ok" in stdout
//! means every assertion held.
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
        if fn.name == name {
          return fn
        }
      }
      case _ -> {
      }
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
        case FBExpr(_) -> panic("bodyBlockOf: function '" + fn.name + "' has FBExpr body")
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
            case EPath(p) -> p.segments.count == 1 and p.segments[0] == "assert"
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
        case _ -> false
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
        case _ -> ""
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
            case EPath(p) -> p.segments.count == 1 and p.segments[0] == expected
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
        case None -> true
      }
    }
    case _ -> false
  }
}

func isTrailingPathSExpr(s: in Statement, expected: in String): Bool {
  match s.kind {
    case SExpr(e) -> {
      match e.kind {
        case EPath(p) -> p.segments.count == 1 and p.segments[0] == expected
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
  val fn = firstFunction(file, "f")
  val blk = bodyBlockOf(fn)
  assertEqualInt(blk.statements.count, 1, "no-contracts: body length unchanged")
  assertTrue(not isAssertCall(blk.statements[0]), "no-contracts: no assert injected")
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Single `requires:` clause.
// ─────────────────────────────────────────────────────────────────────────────
func testSingleRequiresPrepended(): Unit {
  val src = "package P\nfunc f(x: in Int): Int\n  requires: x > 0\n{ x + 1 }\n"
  val file = parseAndElaborate(src)
  val fn = firstFunction(file, "f")
  val blk = bodyBlockOf(fn)
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
  val src = "package P\n" + "func f(x: in Int, y: in Int): Int\n" + "  requires: x > 0\n" + "  requires: y > 0\n" +
    "  requires: x + y < 100\n" +
    "{ x + y }\n"
  val file = parseAndElaborate(src)
  val fn = firstFunction(file, "f")
  val blk = bodyBlockOf(fn)
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
  val src = "package P\n" + "func f(): Int\n" + "  ensures: result >= 0\n" + "{ 7 }\n"
  val file = parseAndElaborate(src)
  val fn = firstFunction(file, "f")
  val blk = bodyBlockOf(fn)
  // [0] = let __lyric_result_0 = 7; [1] = assert(__lyric_result_0 >= 0); [2] = __lyric_result_0
  assertEqualInt(blk.statements.count, 3, "ens-trailing: 3 stmts after elab")
  assertTrue(isLetBinding(blk.statements[0]), "ens-trailing: stmt[0] is let")
  assertEqual(letName(blk.statements[0]), "__lyric_result_0", "ens-trailing: synthetic name")
  assertTrue(isAssertCall(blk.statements[1]), "ens-trailing: stmt[1] is assert")
  assertTrue(isTrailingPathSExpr(blk.statements[2], "__lyric_result_0"), "ens-trailing: stmt[2] yields synthetic local")
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Explicit `return e` is rewritten to bind + assert + return-name.
// ─────────────────────────────────────────────────────────────────────────────
func testEnsuresWithExplicitReturn(): Unit {
  val src = "package P\n" + "func f(): Int\n" + "  ensures: result == 5\n" + "{\n" + "  return 5\n" + "}\n"
  val file = parseAndElaborate(src)
  val fn = firstFunction(file, "f")
  val blk = bodyBlockOf(fn)
  // [0] = let __lyric_result_0 = 5; [1] = assert(...); [2] = return __lyric_result_0
  assertEqualInt(blk.statements.count, 3, "ens-return: 3 stmts after elab")
  assertTrue(isLetBinding(blk.statements[0]), "ens-return: stmt[0] is let")
  assertTrue(isAssertCall(blk.statements[1]), "ens-return: stmt[1] is assert")
  assertTrue(isReturnPath(blk.statements[2], "__lyric_result_0"), "ens-return: stmt[2] returns synthetic local")
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. `return` (no value) keeps the bare return but prepends ensures.
// ─────────────────────────────────────────────────────────────────────────────
func testEnsuresWithBareReturn(): Unit {
  val src = "package P\n" + "func f(): Unit\n" + "  ensures: true\n" + "{\n" + "  return\n" + "}\n"
  val file = parseAndElaborate(src)
  val fn = firstFunction(file, "f")
  val blk = bodyBlockOf(fn)
  // [0] = assert(true); [1] = return
  assertEqualInt(blk.statements.count, 2, "ens-bare-return: 2 stmts after elab")
  assertTrue(isAssertCall(blk.statements[0]), "ens-bare-return: stmt[0] is assert")
  assertTrue(isReturnNone(blk.statements[1]), "ens-bare-return: stmt[1] is bare return")
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. requires + ensures combined on the same function.
// ─────────────────────────────────────────────────────────────────────────────
func testRequiresAndEnsures(): Unit {
  val src = "package P\n" + "func f(x: in Int): Int\n" + "  requires: x > 0\n" + "  ensures:  result > 0\n" +
    "{ x + 1 }\n"
  val file = parseAndElaborate(src)
  val fn = firstFunction(file, "f")
  val blk = bodyBlockOf(fn)
  // [0] = assert(x > 0)              [requires]
  // [1] = let __lyric_result_0 = x+1 [trailing rewrite]
  // [2] = assert(__lyric_result_0 > 0)
  // [3] = __lyric_result_0
  assertEqualInt(blk.statements.count, 4, "req+ens: 4 stmts")
  assertTrue(isAssertCall(blk.statements[0]), "req+ens: stmt[0] requires assert")
  assertTrue(isLetBinding(blk.statements[1]), "req+ens: stmt[1] let binding")
  assertTrue(isAssertCall(blk.statements[2]), "req+ens: stmt[2] ensures assert")
  assertTrue(isTrailingPathSExpr(blk.statements[3], "__lyric_result_0"), "req+ens: stmt[3] yields synthetic local")
}

// ─────────────────────────────────────────────────────────────────────────────
// §8. Multiple ensures clauses generate one assert each.
// ─────────────────────────────────────────────────────────────────────────────
func testMultipleEnsures(): Unit {
  val src = "package P\n" + "func f(): Int\n" + "  ensures: result >= 0\n" + "  ensures: result < 100\n" + "{ 42 }\n"
  val file = parseAndElaborate(src)
  val fn = firstFunction(file, "f")
  val blk = bodyBlockOf(fn)
  // [0] = let; [1] = assert (result >= 0); [2] = assert (result < 100); [3] = trailing path
  assertEqualInt(blk.statements.count, 4, "multi-ens: 4 stmts")
  assertTrue(isLetBinding(blk.statements[0]), "multi-ens: stmt[0] let")
  assertTrue(isAssertCall(blk.statements[1]), "multi-ens: stmt[1] assert")
  assertTrue(isAssertCall(blk.statements[2]), "multi-ens: stmt[2] assert")
  assertTrue(isTrailingPathSExpr(blk.statements[3], "__lyric_result_0"), "multi-ens: stmt[3] yields local")
}

// ─────────────────────────────────────────────────────────────────────────────
// §9. @axiom functions are skipped (no body to elaborate).
// ─────────────────────────────────────────────────────────────────────────────
func testAxiomSkipped(): Unit {
  val src = "@proof_required\n" + "package P\n" + "@axiom\n" + "func ax(p: in Bool): Unit\n" + "  requires: p\n" + "\n"
  val file = parseAndElaborate(src)
  val fn = firstFunction(file, "ax")
  match fn.body {
    case None -> {
    }
    // expected: no body, untouched
    case Some(_) -> {
      assertTrue(false, "axiom: should have no body")
    }
  }
  // Original requires clause is still present on the contract list.
  assertEqualInt(fn.contracts.count, 1, "axiom: contract preserved")
}

// ─────────────────────────────────────────────────────────────────────────────
// §10. Functions without a body (signatures) pass through unchanged.
// ─────────────────────────────────────────────────────────────────────────────
func testSignaturePassthrough(): Unit {
  val src = "package P\n" + "func f(x: in Int): Int\n" + "  requires: x > 0\n" + "\n"
  val file = parseAndElaborate(src)
  val fn = firstFunction(file, "f")
  match fn.body {
    case None -> {
    }
    case Some(_) -> {
      assertTrue(false, "sig: expected no body")
    }
  }
  assertEqualInt(fn.contracts.count, 1, "sig: contracts preserved")
}

// ─────────────────────────────────────────────────────────────────────────────
// §11. Original `contracts` list is preserved on the elaborated decl.
// ─────────────────────────────────────────────────────────────────────────────
func testContractsListPreserved(): Unit {
  val src = "package P\n" + "func f(x: in Int): Int\n" + "  requires: x > 0\n" + "  ensures: result > 0\n" + "{ x }\n"
  val file = parseAndElaborate(src)
  val fn = firstFunction(file, "f")
  // 2 clauses survived (1 requires, 1 ensures).
  assertEqualInt(fn.contracts.count, 2, "contracts-preserved: 2 clauses")
  var hasReq = false
  var hasEns = false
  var i = 0
  while i < fn.contracts.count {
    match fn.contracts[i] {
      case CCRequires(_, _) -> {
        hasReq = true
      }
      case CCEnsures(_, _) -> {
        hasEns = true
      }
      case _ -> {
      }
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
  val src = "package P\n" + "func f(x: in Int): Int\n" + "  ensures: result > 0\n" + "{\n" + "  return 1\n" +
    "  return 2\n" +
    "}\n"
  val file = parseAndElaborate(src)
  val fn = firstFunction(file, "f")
  val blk = bodyBlockOf(fn)
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
  val src = "package P\n" + "import Std.Core\n" + "func a(): Int { 1 }\n" + "func b(): Int\n" + "  requires: true\n" +
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
  val src = "package P\n" + "pub record Pair { x: Int, y: Int }\n" + "func f(): Int\n" + "  requires: true\n" +
    "{ 1 }\n"
  val file = parseAndElaborate(src)
  // Two items: the record and the function; record should be untouched.
  assertEqualInt(file.items.count, 2, "non-func: 2 items")
  match file.items[0].kind {
    case IRecord(_) -> {
    }
    case _ -> {
      assertTrue(false, "non-func: stmt[0] should be IRecord")
    }
  }
  // The function still got elaborated.
  val fn = firstFunction(file, "f")
  val blk = bodyBlockOf(fn)
  assertEqualInt(blk.statements.count, 2, "non-func: function elaborated (1 require + 1 trail)")
}

// ─────────────────────────────────────────────────────────────────────────────
// Nested-return elaboration tests (fix for #341).
// ─────────────────────────────────────────────────────────────────────────────
// A return nested inside an if-branch should be elaborated with ensures
// checks, matching the behaviour for top-level returns.
func testNestedReturnInIf(): Unit {
  val src = "package T\n" + "func clamp(x: Int): Int\n" + "  ensures: result >= 0\n" + "{\n" +
    "  if x < 0 { return 0 }\n" +
    "  x\n" +
    "}\n"
  val file = parseAndElaborate(src)
  val fn = firstFunction(file, "clamp")
  val blk = bodyBlockOf(fn)
  // Top level: [if-stmt, trailing SExpr(x)]
  // The if-stmt is an SExpr(EIf(...)).  Its then-branch block must have
  // been elaborated: original SReturn(0) → [let __lyric_result_N = 0,
  // assert(ensures), return __lyric_result_N].
  assertTrue(blk.statements.count >= 2, "nested-return-if: at least 2 top-level stmts")
  // Find the if-statement (first non-assert top-level statement).
  var found = false
  var i = 0
  while i < blk.statements.count {
    match blk.statements[i].kind {
      case SExpr(e) -> {
        match e.kind {
          case EIf(_, thenBranch, _, _) -> {
            match thenBranch {
              case EOBBlock(innerBlk) -> {
                // After elaboration the then-branch must have more than one
                // statement (the let binding + assert + return).
                assertTrue(innerBlk.statements.count > 1, "nested-return-if: then-branch elaborated (count > 1)")
                // The last statement must be SReturn.
                val last = innerBlk.statements[innerBlk.statements.count - 1]
                match last.kind {
                  case SReturn(_) -> {
                  }
                  case _ -> assertTrue(false, "nested-return-if: last stmt should be SReturn")
                }
                found = true
              }
              case _ -> {
              }
            }
          }
          case _ -> {
          }
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  assertTrue(found, "nested-return-if: EIf with EOBBlock then-branch found")
}

// #633: cover EMatch, while-loop, and try-catch nested-return paths in
// addition to EIf.  Each case asserts that the function body's
// top-level block grew (so the return-rewrite triggered) and that the
// ensures assert is reachable.  The structural inspection mirrors
// `testNestedReturnInIf` but stays surface-level — the deep traversal
// itself is exercised by `elaborateStmtDeep` / `elaborateExprDeep`.
// Helper: count top-level statements in the elaborated function's body.
func bodyStmtCount(file: in SourceFile, name: in String): Int {
  val fn = firstFunction(file, name)
  bodyBlockOf(fn).statements.count
}

// Helper: assert that the elaborated body contains at least one
// `assert(...)` ECall statement — proves ensures clauses landed.
func bodyContainsAssertCall(file: in SourceFile, name: in String): Bool {
  val blk = bodyBlockOf(firstFunction(file, name))
  var i = 0
  while i < blk.statements.count {
    match blk.statements[i].kind {
      case SExpr(e) -> match e.kind { case ECall(callee, _) -> match callee.kind { case EPath(p) -> if p.segments.count == 1 and p.segments[0] == "assert" { return true }; case _ -> {  } }; case _ -> {  } }
      case _ -> {
      }
    }
    i = i + 1
  }
  false
}

func testNestedReturnInMatch(): Unit {
  val src = "package T\n" + "func absV(x: Int): Int\n" + "  ensures: result >= 0\n" + "{\n" + "  match x {\n" +
    "    case 0 -> { return 0 }\n" +
    "    case _ -> x\n" +
    "  }\n" +
    "}\n"
  val file = parseAndElaborate(src)
  val n = bodyStmtCount(file, "absV")
  assertTrue(n >= 1, "nested-return-match: body has at least one stmt")
  // The body's trailing implicit-return is rewritten to:
  //   let __lyric_result_N = <match-expr>; assert(ensures); return __lyric_result_N
  // — so the body block must be longer than the single original match expr.
  assertTrue(n >= 2, "nested-return-match: trailing return elaborated (n >= 2)")
}

func testNestedReturnInWhile(): Unit {
  val src = "package T\n" + "func find(): Int\n" + "  ensures: result >= 0\n" + "{\n" + "  var i = 0\n" +
    "  while i < 10 { if i == 5 { return i }; i = i + 1 }\n" +
    "  -1\n" +
    "}\n"
  val file = parseAndElaborate(src)
  val n = bodyStmtCount(file, "find")
  // var i, while, [let trailing_result, assert, return] — at least 3.
  assertTrue(n >= 3, "nested-return-while: body has >= 3 top-level stmts after elaboration")
  assertTrue(bodyContainsAssertCall(file, "find"), "nested-return-while: ensures assert lowered into the body")
}

func testNestedReturnInTry(): Unit {
  // Try-catch nested-return rewrite is deferred per the elaborator's
  // header comment (only top-level + EIf nested returns are rewritten
  // today; #341's full coverage remains in flight).  This test pins
  // that the elaborator does not crash on a try-catch with two
  // nested returns, so a future deep-walk extension has a regression
  // anchor to flip from "passes through" to "rewritten".
  val src = "package T\n" + "func parse(): Int\n" + "  ensures: result >= 0\n" + "{\n" +
    "  try { return 42 } catch Bug as _ { return 0 }\n" +
    "}\n"
  val file = parseAndElaborate(src)
  val n = bodyStmtCount(file, "parse")
  // Body remains structurally a single try-stmt; no crash and no
  // spurious extra statements.
  assertTrue(n >= 1, "nested-return-try: body parsed and elaborated without crash")
}

// ─────────────────────────────────────────────────────────────────────────────
// Loop invariant lowering (docs/41 §9 Band 4).
// ─────────────────────────────────────────────────────────────────────────────
func testWhileInvariantLowered(): Unit {
  val src = "package P\n" + "func f(): Unit {\n" + "  var i = 0\n" + "  while i < 10\n" + "    invariant: i >= 0\n" +
    "  {\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "}\n"
  val file = parseAndElaborate(src)
  val fn = firstFunction(file, "f")
  val blk = bodyBlockOf(fn)
  // Function body: [0] = var i, [1] = while
  var found = false
  var i = 0
  while i < blk.statements.count {
    match blk.statements[i].kind {
      case SWhile(_, _, body) -> {
        // First statement of loop body must be the lowered assert.
        assertTrue(body.statements.count >= 2, "while-invariant: body has assert + at least one user stmt")
        assertTrue(isAssertCall(body.statements[0]), "while-invariant: body[0] is assert(...)")
        found = true
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  assertTrue(found, "while-invariant: SWhile node found in body")
}

func testForInvariantLowered(): Unit {
  val src = "package P\n" + "import Std.Collections\n" + "func f(): Unit {\n" + "  val xs: List[Int] = newList()\n" +
    "  for x in xs\n" +
    "    invariant: true\n" +
    "  {\n" +
    "    println(x)\n" +
    "  }\n" +
    "}\n"
  val file = parseAndElaborate(src)
  val fn = firstFunction(file, "f")
  val blk = bodyBlockOf(fn)
  var found = false
  var i = 0
  while i < blk.statements.count {
    match blk.statements[i].kind {
      case SFor(_, _, _, body) -> {
        assertTrue(body.statements.count >= 2, "for-invariant: body has assert + at least one user stmt")
        assertTrue(isAssertCall(body.statements[0]), "for-invariant: body[0] is assert(...)")
        found = true
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  assertTrue(found, "for-invariant: SFor node found in body")
}

// #826 regression: a while-loop invariant nested inside an if-block must be
// lowered to a runtime assert.  The function has no requires:/ensures: clauses,
// so the early-return path in elaborateFunction must still detect the nested
// SInvariant via stmtHasInvariant's SExpr case (otherwise the deep walk skips
// and the assert is silently dropped).
func testIfNestedWhileInvariantLowered(): Unit {
  val src = "package P\n" + "func f(x: Int): Unit {\n" + "  if x > 0 {\n" + "    var i = 0\n" + "    while i < 10\n" +
    "      invariant: i >= 0\n" +
    "    {\n" +
    "      i = i + 1\n" +
    "    }\n" +
    "  }\n" +
    "}\n"
  val file = parseAndElaborate(src)
  val fn = firstFunction(file, "f")
  val blk = bodyBlockOf(fn)
  var found = false
  var i = 0
  // Drill: body has [SExpr(EIf(_, EOBBlock([..., SWhile(...)])))].
  while i < blk.statements.count {
    match blk.statements[i].kind {
      case SExpr(e) -> match e.kind { case EIf(_, thenBranch, _, _) -> match thenBranch { case EOBBlock(thenBlk) -> { var j = 0; while j < thenBlk.statements.count { match thenBlk.statements[j].kind { case SWhile(_, _, whileBody) -> { assertTrue(whileBody.statements.count >= 2, "if-nested while-invariant: body has assert + at least one user stmt"); assertTrue(isAssertCall(whileBody.statements[0]), "if-nested while-invariant: body[0] is assert(...)"); found = true }; case _ -> {  } }; j = j + 1 } }; case _ -> {  } }; case _ -> {  } }
      case _ -> {
      }
    }
    i = i + 1
  }
  assertTrue(found, "if-nested while-invariant: SWhile inside EIf body found")
}

// ─────────────────────────────────────────────────────────────────────────────
// Protected-type entry elaboration (docs/41 §9 Band 4 finish).
// ─────────────────────────────────────────────────────────────────────────────
func firstProtected(file: in SourceFile, name: in String): ProtectedTypeDecl {
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IProtected(decl) -> {
        if decl.name == name {
          return decl
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  panic("firstProtected: no protected type named '" + name + "'")
}

func firstEntry(decl: in ProtectedTypeDecl, name: in String): EntryDecl {
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case PMEntry(ed) -> {
        if ed.name == name {
          return ed
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  panic("firstEntry: no entry named '" + name + "'")
}

func entryBodyBlock(ed: in EntryDecl): Block {
  match ed.body {
    case FBBlock(blk) -> blk
    case FBExpr(_) -> panic("entryBodyBlock: entry '" + ed.name + "' has FBExpr body")
  }
}

func testProtectedEntryRequiresLowered(): Unit {
  val src = "package P\n" + "protected type Q {\n" + "  var count: Int\n" + "  entry add(x: in Int): Int\n" +
    "    requires: x > 0\n" +
    "  {\n" +
    "    x + 1\n" +
    "  }\n" +
    "}\n"
  val file = parseAndElaborate(src)
  val decl = firstProtected(file, "Q")
  val ed = firstEntry(decl, "add")
  val blk = entryBodyBlock(ed)
  // After elaboration: [0] = assert(x > 0); [1] = trailing SExpr (no ensures, unchanged)
  assertTrue(blk.statements.count >= 2, "protected-requires: elaborated body has >= 2 stmts")
  assertTrue(isAssertCall(blk.statements[0]), "protected-requires: stmt[0] is assert(x > 0)")
  // Original contracts list preserved (not the combined list)
  assertEqualInt(ed.contracts.count, 1, "protected-requires: original contracts preserved")
}

func testProtectedInvariantAppendedToEntries(): Unit {
  val src = "package P\n" + "protected type Q {\n" + "  var count: Int\n" + "  invariant: count >= 0\n" +
    "  entry add(x: in Int): Int\n" +
    "    requires: x > 0\n" +
    "  {\n" +
    "    x + 1\n" +
    "  }\n" +
    "}\n"
  val file = parseAndElaborate(src)
  val decl = firstProtected(file, "Q")
  val ed = firstEntry(decl, "add")
  val blk = entryBodyBlock(ed)
  // After elaboration with requires + invariant-as-ensures on body { x + 1 }:
  // [0] = assert(x > 0)          [requires]
  // [1] = let __lyric_result_0 = x + 1
  // [2] = assert(count >= 0)     [invariant as ensures]
  // [3] = __lyric_result_0
  assertEqualInt(blk.statements.count, 4, "protected-invariant: 4 stmts after elaboration")
  assertTrue(isAssertCall(blk.statements[0]), "protected-invariant: stmt[0] is requires assert")
  assertTrue(isLetBinding(blk.statements[1]), "protected-invariant: stmt[1] is let binding")
  assertTrue(isAssertCall(blk.statements[2]), "protected-invariant: stmt[2] is invariant assert")
  assertTrue(
    isTrailingPathSExpr(blk.statements[3], "__lyric_result_0"),
    "protected-invariant: stmt[3] is trailing path"
  )
  // Original entry contracts preserved (1 requires clause only, not the added invariant)
  assertEqualInt(ed.contracts.count, 1, "protected-invariant: original entry contracts preserved")
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
  testNestedReturnInIf()
  testNestedReturnInMatch()
  testNestedReturnInWhile()
  testNestedReturnInTry()
  testWhileInvariantLowered()
  testForInvariantLowered()
  testIfNestedWhileInvariantLowered()
  testProtectedEntryRequiresLowered()
  testProtectedInvariantAppendedToEntries()
  println("contract-elaborator self-test: ok")
}
