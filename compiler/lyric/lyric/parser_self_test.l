// parser_self_test.l — exercises the self-hosted Lyric.Parser library.
// Compiled and executed by the F# Expecto runner at
// compiler/tests/Lyric.Emitter.Tests/SelfHostedParserTests.fs.
// Each in-program assertion panics on mismatch; exit 0 + "ok" in
// stdout means every check held.
package Lyric.ParserSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.Parser

// ─────────────────────────────────────────────────────────────────────────────
// Helpers.
// ─────────────────────────────────────────────────────────────────────────────

func diagCount(pr: in ParseResult): Int {
  pr.diagnostics.count
}

func itemCount(pr: in ParseResult): Int {
  pr.file.items.count
}

func importCount(pr: in ParseResult): Int {
  pr.file.imports.count
}

func firstItemKindName(pr: in ParseResult): String {
  if pr.file.items.count == 0 { return "<none>" }
  match pr.file.items[0].kind {
    case IConst(_)        -> "const"
    case IVal(_)          -> "val"
    case IFunc(_)         -> "func"
    case ITypeAlias(_)    -> "alias"
    case IDistinctType(_) -> "distinct"
    case IRecord(_)       -> "record"
    case IExposedRec(_)   -> "exposed_rec"
    case IUnion(_)        -> "union"
    case IEnum(_)         -> "enum"
    case IOpaque(_)       -> "opaque"
    case IProtected(_)    -> "protected"
    case IInterface(_)    -> "interface"
    case IImpl(_)         -> "impl"
    case IWire(_)         -> "wire"
    case IScopeKind(_)    -> "scope_kind"
    case IExtern(_)       -> "extern"
    case IExternType(_)   -> "extern_type"
    case ITest(_)         -> "test"
    case IProperty(_)     -> "property"
    case IFixture(_)      -> "fixture"
    case IError           -> "error"
  }
}

func packageName(pr: in ParseResult): String {
  val segs = pr.file.packageDecl.path.segments
  if segs.count == 0 { return "" }
  var s = segs[0]
  var i = 1
  while i < segs.count {
    s = s + "." + segs[i]
    i = i + 1
  }
  s
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

func testEmptySource(): Unit {
  val pr = parse("")
  assertEqualInt(diagCount(pr), 0, "empty: no diagnostics")
  assertEqualInt(itemCount(pr), 0, "empty: no items")
}

func testPackageDecl(): Unit {
  val pr = parse("package Foo.Bar\n")
  assertEqualInt(diagCount(pr), 0, "package: no diagnostics")
  assertEqual(packageName(pr), "Foo.Bar", "package: name")
}

func testImport(): Unit {
  val pr = parse("package P\nimport Std.Core\n")
  assertEqualInt(diagCount(pr), 0, "import: no diagnostics")
  assertEqualInt(importCount(pr), 1, "import: one import")
}

func testFuncDecl(): Unit {
  val pr = parse("package P\nfunc add(x: in Int, y: in Int): Int { x + y }\n")
  assertEqualInt(diagCount(pr), 0, "func: no diagnostics")
  assertEqualInt(itemCount(pr), 1, "func: one item")
  assertEqual(firstItemKindName(pr), "func", "func: kind is func")
}

func testRecordDecl(): Unit {
  val pr = parse("package P\nrecord Point { x: Int; y: Int }\n")
  assertEqualInt(diagCount(pr), 0, "record: no diagnostics")
  assertEqualInt(itemCount(pr), 1, "record: one item")
  assertEqual(firstItemKindName(pr), "record", "record: kind is record")
}

func testUnionDecl(): Unit {
  val pr = parse("package P\nunion Color { case Red; case Green; case Blue }\n")
  assertEqualInt(diagCount(pr), 0, "union: no diagnostics")
  assertEqualInt(itemCount(pr), 1, "union: one item")
  assertEqual(firstItemKindName(pr), "union", "union: kind is union")
}

func testDistinctTypeDecl(): Unit {
  val pr = parse("package P\ntype Age = Int range 0 ..= 150\n")
  assertEqualInt(diagCount(pr), 0, "distinct: no diagnostics")
  assertEqualInt(itemCount(pr), 1, "distinct: one item")
  assertEqual(firstItemKindName(pr), "distinct", "distinct: kind")
}

func testTypeAliasDecl(): Unit {
  val pr = parse("package P\nalias Name = String\n")
  assertEqualInt(diagCount(pr), 0, "alias: no diagnostics")
  assertEqualInt(itemCount(pr), 1, "alias: one item")
  assertEqual(firstItemKindName(pr), "alias", "alias: kind")
}

func testValDecl(): Unit {
  val pr = parse("package P\nval pi: Double = 3.14159\n")
  assertEqualInt(diagCount(pr), 0, "val: no diagnostics")
  assertEqualInt(itemCount(pr), 1, "val: one item")
  assertEqual(firstItemKindName(pr), "val", "val: kind")
}

func testMultipleItems(): Unit {
  val src = "package P\nrecord A { x: Int }\nrecord B { y: String }\nfunc f(): Unit { }\n"
  val pr = parse(src)
  assertEqualInt(diagCount(pr), 0, "multi: no diagnostics")
  assertEqualInt(itemCount(pr), 3, "multi: three items")
}

func testFuncWithContracts(): Unit {
  val src = "package P\nfunc divide(x: in Int, y: in Int): Int\n  requires: y != 0\n  ensures: result * y == x\n  { x / y }\n"
  val pr = parse(src)
  assertEqualInt(diagCount(pr), 0, "contracts: no diagnostics")
  assertEqualInt(itemCount(pr), 1, "contracts: one item")
  assertEqual(firstItemKindName(pr), "func", "contracts: kind is func")
}

func testEnumDecl(): Unit {
  val pr = parse("package P\nenum Dir { case North; case South; case East; case West }\n")
  assertEqualInt(diagCount(pr), 0, "enum: no diagnostics")
  assertEqual(firstItemKindName(pr), "enum", "enum: kind")
}

func testInterfaceDecl(): Unit {
  val src = "package P\ninterface Printable { func print(self: in Self): Unit }\n"
  val pr = parse(src)
  assertEqualInt(diagCount(pr), 0, "interface: no diagnostics")
  assertEqual(firstItemKindName(pr), "interface", "interface: kind")
}

func testPubVisibility(): Unit {
  val pr = parse("package P\npub func foo(): Unit { }\n")
  assertEqualInt(diagCount(pr), 0, "pub: no diagnostics")
  assertEqualInt(itemCount(pr), 1, "pub: one item")
  val item = pr.file.items[0]
  match item.visibility {
    case Some(_) -> {}
    case None -> { assertTrue(false, "pub: visibility should be Some") }
  }
}

func testAnnotation(): Unit {
  val pr = parse("package P\n@pure\npub func foo(): Unit { }\n")
  assertEqualInt(diagCount(pr), 0, "ann: no diagnostics")
  assertEqualInt(itemCount(pr), 1, "ann: one item")
}

func testMatchExpr(): Unit {
  val src = "package P\nfunc f(x: in Int): String {\n  match x {\n    case 0 -> \"zero\"\n    case _ -> \"other\"\n  }\n}\n"
  val pr = parse(src)
  assertEqualInt(diagCount(pr), 0, "match: no diagnostics")
  assertEqual(firstItemKindName(pr), "func", "match: kind")
}

func testIfExpr(): Unit {
  val src = "package P\nfunc abs(x: in Int): Int { if x < 0 { -x } else { x } }\n"
  val pr = parse(src)
  assertEqualInt(diagCount(pr), 0, "if: no diagnostics")
}

func testGenericFunc(): Unit {
  val src = "package P\nfunc identity[T](x: in T): T { x }\n"
  val pr = parse(src)
  assertEqualInt(diagCount(pr), 0, "generic: no diagnostics")
  assertEqual(firstItemKindName(pr), "func", "generic: kind")
}

// ─────────────────────────────────────────────────────────────────────────────
// CST tests (Phase 5 §M5.1 stage 5' — red/green CST foundation).
//
// The parser now builds a lossless concrete syntax tree alongside the
// AST.  These tests verify:
//   * The root is `SkSourceFile`.
//   * Every byte of the input source survives `nodeSourceText` —
//     including comments (line + block) and whitespace.
//   * `RedNode` traversal yields children with non-decreasing offsets.
// ─────────────────────────────────────────────────────────────────────────────

func syntaxKindName(k: in SyntaxKind): String {
  match k {
    case SkSourceFile             -> "source_file"
    case SkModuleDocSection       -> "module_doc"
    case SkFileAnnotationsSection -> "file_anns"
    case SkPackageDecl            -> "package_decl"
    case SkImportSection          -> "import_section"
    case SkImportDecl             -> "import_decl"
    case SkItemSection            -> "item_section"
    case SkItem                   -> "item"
    case SkAnnotation             -> "annotation"
    case SkRaw                    -> "raw"
  }
}

/// Count direct CST children of a green node by `kind`.  Used to
/// assert that the structural shape matches the parsed source
/// without locking the test to specific child positions.
func countChildrenOfKind(n: in GreenNode, want: in SyntaxKind): Int {
  var c = 0
  var i = 0
  while i < n.children.count {
    match n.children[i] {
      case GcNode(child) -> {
        if syntaxKindName(child.kind) == syntaxKindName(want) { c = c + 1 }
      }
      case GcToken(_) -> {}
    }
    i = i + 1
  }
  c
}

/// Find the first direct CST child of `n` whose kind matches `want`,
/// or panic.  The CST is structurally fixed at the file/import/item
/// granularity so callers know the child exists.
func findChild(n: in GreenNode, want: in SyntaxKind): GreenNode {
  var i = 0
  while i < n.children.count {
    match n.children[i] {
      case GcNode(child) -> {
        if syntaxKindName(child.kind) == syntaxKindName(want) { return child }
      }
      case GcToken(_) -> {}
    }
    i = i + 1
  }
  panic("no child of kind " + syntaxKindName(want))
}

func testCstRootKind(): Unit {
  val src = "package P\n"
  val pr = parse(src)
  assertEqual(syntaxKindName(pr.cst.kind), "source_file", "cst: root is source_file")
}

func testCstLossless(): Unit {
  // Source includes a doc comment, a line comment, a block comment,
  // and irregular indentation — the round-trip must reproduce every
  // byte (post CR/LF normalisation).
  val src =
    "//! module doc\n" +
    "package P\n" +
    "\n" +
    "// pre-import line comment\n" +
    "import Std.Core /* trailing block */\n" +
    "\n" +
    "/// item doc\n" +
    "@pure\n" +
    "func add(x: in Int, y: in Int): Int {\n" +
    "  // body comment\n" +
    "  x + y\n" +
    "}\n"
  val pr = parse(src)
  assertEqualInt(diagCount(pr), 0, "cst-lossless: no diagnostics")
  val rebuilt = nodeSourceText(pr.source, pr.cst)
  assertEqual(rebuilt, src, "cst-lossless: byte-faithful round-trip")
}

func testCstShape(): Unit {
  val src = "package P\nimport Std.Core\nfunc f(): Unit { }\n"
  val pr = parse(src)
  assertEqualInt(diagCount(pr), 0, "cst-shape: no diagnostics")
  val root = pr.cst
  assertEqualInt(countChildrenOfKind(root, SkPackageDecl), 1, "cst-shape: one package_decl")
  assertEqualInt(countChildrenOfKind(root, SkImportSection), 1, "cst-shape: one import_section")
  assertEqualInt(countChildrenOfKind(root, SkItemSection), 1, "cst-shape: one item_section")
  val imports = findChild(root, SkImportSection)
  assertEqualInt(countChildrenOfKind(imports, SkImportDecl), 1, "cst-shape: one import_decl")
  val items = findChild(root, SkItemSection)
  assertEqualInt(countChildrenOfKind(items, SkItem), 1, "cst-shape: one item")
}

func testCstEmptySourceLossless(): Unit {
  val pr = parse("")
  assertEqual(syntaxKindName(pr.cst.kind), "source_file", "cst-empty: still a source_file")
  assertEqual(nodeSourceText(pr.source, pr.cst), "", "cst-empty: empty round-trip")
}

func testCstWidthMatchesText(): Unit {
  val src = "package P\nfunc f(): Unit { }\n"
  val pr = parse(src)
  assertEqualInt(pr.cst.width, src.length, "cst-width: width equals source length")
}

func testRedRootOffsets(): Unit {
  // Red-tree wrapper: the root sits at offset 0, and every child's
  // offset is the running sum of its preceding siblings' widths.
  val src = "package P\nimport Std.Core\n"
  val pr = parse(src)
  val red = makeRedRoot(pr.cst)
  assertEqualInt(red.offset, 0, "red-root: offset 0")
  val kids = redChildren(red)
  // First kid at 0, monotonic non-decreasing offsets thereafter.
  assertTrue(kids.count > 0, "red-root: has children")
  var prev = -1
  var i = 0
  while i < kids.count {
    val o = match kids[i] {
      case RcToken(_, _, off) -> off
      case RcNode(node) -> node.offset
    }
    assertTrue(o >= prev, "red-root: offsets monotonic")
    prev = o
    i = i + 1
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CST per-expression / per-statement / per-block / per-contract granularity
// (Phase 5 §M5.3 stage 6, D-progress-142).
// ─────────────────────────────────────────────────────────────────────────────

@pure
func skName(k: in SyntaxKind): String {
  match k {
    case SkSourceFile             -> "source_file"
    case SkModuleDocSection       -> "module_doc"
    case SkFileAnnotationsSection -> "file_anns"
    case SkPackageDecl            -> "package"
    case SkImportSection          -> "import_section"
    case SkImportDecl             -> "import"
    case SkItemSection            -> "item_section"
    case SkItem                   -> "item"
    case SkAnnotation             -> "annotation"
    case SkBlock                  -> "block"
    case SkStatement              -> "statement"
    case SkExpr                   -> "expr"
    case SkContractClause         -> "contract"
    case SkRaw                    -> "raw"
  }
}

/// Walk a green tree and count occurrences of each `SyntaxKind`
/// across the whole sub-tree (root included).  `target` matches any
/// node with that kind.
func countKind(n: in GreenNode, target: in SyntaxKind): Int {
  var hit = 0
  if skName(n.kind) == skName(target) { hit = 1 }
  var i = 0
  while i < n.children.count {
    match n.children[i] {
      case GcNode(child) -> { hit = hit + countKind(child, target) }
      case GcToken(_)    -> {}
    }
    i = i + 1
  }
  hit
}

func testCstHasSkBlockInsideFunc(): Unit {
  val pr = parse("package P\nfunc f(): Unit { val a = 1 }\n")
  val n = countKind(pr.cst, SkBlock)
  assertTrue(n >= 1, "CST: at least one SkBlock inside func")
}

func testCstHasSkStatementInsideFunc(): Unit {
  val pr = parse("package P\nfunc f(): Unit { val a = 1; val b = 2 }\n")
  val n = countKind(pr.cst, SkStatement)
  assertTrue(n >= 2, "CST: each statement gets its own SkStatement node")
}

func testCstHasSkExprInsideStatement(): Unit {
  // `parseExpr` is the wrapper-bearing entry — sub-precedence
  // helpers (`parseImpliesExpr`, `parseAddExpr`, etc.) don't re-enter
  // it, so a single binary expression like `1 + 2` produces only one
  // SkExpr node (the init).  Parens, function args, indices, and
  // explicit subscripts re-enter `parseExpr`, yielding nested
  // SkExpr nodes — exercise that here.
  val pr = parse("package P\nfunc f(): Int { val a = (1 + 2); a }\n")
  val n = countKind(pr.cst, SkExpr)
  // At minimum: the `(1 + 2)` init's outer parseExpr, the inner
  // parenthesised parseExpr, and the trailing-expression `a` —
  // three SkExpr nodes.
  assertTrue(n >= 3, "CST: SkExpr nests across paren / sub-expr boundaries")
}

func testCstHasSkContractClause(): Unit {
  val src =
    "package P\nfunc divide(x: in Int, y: in Int): Int\n" +
    "  requires: y != 0\n  ensures: result * y == x\n  { x / y }\n"
  val pr = parse(src)
  val n = countKind(pr.cst, SkContractClause)
  assertTrue(n == 2, "CST: two contract clauses (requires + ensures)")
}

func testCstNoSkContractClauseWhenAbsent(): Unit {
  val pr = parse("package P\nfunc f(): Int { 0 }\n")
  val n = countKind(pr.cst, SkContractClause)
  assertEqualInt(n, 0, "CST: no SkContractClause node when no clauses")
}

func testCstShapeIsLossless(): Unit {
  // Per-expression / per-statement granularity must keep the green
  // tree's lossless guarantee — `nodeSourceText` reproduces the
  // input byte-for-byte (modulo CR/LF normalisation).
  val src = "package P\nfunc f(): Int {\n  val a = 1 + 2\n  a\n}\n"
  val pr = parse(src)
  val rendered = nodeSourceText(pr.source, pr.cst)
  assertEqual(rendered, pr.source, "CST: lossless round-trip with finer granularity")
}

func main(): Unit {
  testEmptySource()
  testPackageDecl()
  testImport()
  testFuncDecl()
  testRecordDecl()
  testUnionDecl()
  testDistinctTypeDecl()
  testTypeAliasDecl()
  testValDecl()
  testMultipleItems()
  testFuncWithContracts()
  testEnumDecl()
  testInterfaceDecl()
  testPubVisibility()
  testAnnotation()
  testMatchExpr()
  testIfExpr()
  testGenericFunc()
  testCstRootKind()
  testCstLossless()
  testCstShape()
  testCstEmptySourceLossless()
  testCstWidthMatchesText()
  testRedRootOffsets()
  testCstHasSkBlockInsideFunc()
  testCstHasSkStatementInsideFunc()
  testCstHasSkExprInsideStatement()
  testCstHasSkContractClause()
  testCstNoSkContractClauseWhenAbsent()
  testCstShapeIsLossless()
  println("parser self-test: ok")
}
