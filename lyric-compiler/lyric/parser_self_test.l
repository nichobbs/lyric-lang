// parser_self_test.l — exercises the self-hosted Lyric.Parser library.
// Compiled and executed by the F# Expecto runner at
// compiler/tests/Lyric.Emitter.Tests/SelfHostedParserTests.fs.
// Each in-program assertion panics on mismatch; exit 0 + "ok" in
// stdout means every check held.
package Lyric.ParserSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.Lexer
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
    case IConfig(_)       -> "config"
    case IAspect(_)       -> "aspect"
    case IError           -> "error"
  }
}

// Number of statements in the first item's function-body block (-1/-2/-3/-4
// for the various "not a block-bodied function" shapes).  Used to assert that a
// brace-`if` statement does not glue a following operator into one binop (#1943).
func firstFuncBodyStmtCount(pr: in ParseResult): Int {
  if pr.file.items.count == 0 { return -1 }
  match pr.file.items[0].kind {
    case IFunc(fd) ->
      match fd.body {
        case Some(b) ->
          match b {
            case FBBlock(blk) -> blk.statements.count
            case FBExpr(_)    -> -2
          }
        case None -> -3
      }
    case _ -> -4
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

// #1943: a brace-terminated `if` in statement position is a complete statement,
// not the left operand of a following binary operator.  `if n > 10 { return
// 100 }` then a bare `-1` on the next line must parse as TWO statements (the
// if-statement and the `-1` fall-through value), not one glued `(if …) - 1`.
func testIfStmtDoesNotGlueOperator(): Unit {
  val pr = parse("package P\nfunc f(n: in Int): Int {\n  if n > 10 { return 100 }\n  -1\n}\n")
  assertEqualInt(diagCount(pr), 0, "if-stmt-sei: no diagnostics")
  assertEqualInt(firstFuncBodyStmtCount(pr), 2, "if-stmt-sei: two statements, not a glued binop")
}

// The same for `match` in statement position.
func testMatchStmtDoesNotGlueOperator(): Unit {
  val pr = parse("package P\nfunc f(n: in Int): Int {\n  match n { case _ -> { return 1 } }\n  -1\n}\n")
  assertEqualInt(diagCount(pr), 0, "match-stmt-sei: no diagnostics")
  assertEqualInt(firstFuncBodyStmtCount(pr), 2, "match-stmt-sei: two statements, not a glued binop")
}

// Value position is unaffected: an `if` after `=` is an ordinary operand, so the
// initialiser is a single expression (one `val` statement).
func testValueIfStillSingleExpr(): Unit {
  val pr = parse("package P\nfunc f(c: in Bool): Int {\n  val x = if c { 1 } else { 2 }\n  x\n}\n")
  assertEqualInt(diagCount(pr), 0, "value-if: no diagnostics")
  assertEqualInt(firstFuncBodyStmtCount(pr), 2, "value-if: val-stmt + trailing x")
}

func testRecordDecl(): Unit {
  val pr = parse("package P\nrecord Point { x: Int; y: Int }\n")
  assertEqualInt(diagCount(pr), 0, "record: no diagnostics")
  assertEqualInt(itemCount(pr), 1, "record: one item")
  assertEqual(firstItemKindName(pr), "record", "record: kind is record")
}

// Returns the `isMutable` flag of the first field of the first record in the
// parsed file, or panics if the shape is not a record-with-a-field.  Used by
// the `var`-field regression tests below.
func firstRecordFieldIsMutable(pr: in ParseResult): Bool {
  if pr.file.items.count == 0 { panic("no items") }
  match pr.file.items[0].kind {
    case IRecord(decl) -> {
      if decl.members.count == 0 { panic("record has no members") }
      match decl.members[0] {
        case RMField(f) -> f.isMutable
        case _          -> panic("first member is not a field")
      }
    }
    case _ -> panic("first item is not a record")
  }
}

// `var`-prefixed mutable record fields (language reference §3.4) must
// parse without diagnostics.
func testMutableRecordField(): Unit {
  val pr = parse("package P\nrecord Counter {\n  var count: Int\n  step: Int\n}\n")
  assertEqualInt(diagCount(pr), 0, "var-field: no diagnostics")
  assertEqualInt(itemCount(pr), 1, "var-field: one item")
  assertEqual(firstItemKindName(pr), "record", "var-field: kind is record")
  assertTrue(firstRecordFieldIsMutable(pr), "var-field: first field is mutable")
}

func testImmutableRecordField(): Unit {
  val pr = parse("package P\nrecord Point { x: Int; y: Int }\n")
  assertEqualInt(diagCount(pr), 0, "plain-field: no diagnostics")
  assertTrue(not firstRecordFieldIsMutable(pr), "plain-field: first field is immutable")
}

// `pub var` ordering: visibility precedes the `var` marker.
func testPubMutableRecordField(): Unit {
  val pr = parse("package P\nrecord Box {\n  pub var value: String\n}\n")
  assertEqualInt(diagCount(pr), 0, "pub-var-field: no diagnostics")
  assertTrue(firstRecordFieldIsMutable(pr), "pub-var-field: field is mutable")
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

// ── D046 config block parser (self-host mirror of F# bootstrap) ──

func testConfigBlock(): Unit {
  val src = "package P\nconfig Settings { port: Int = 8080 }\n"
  val pr = parse(src)
  assertEqualInt(diagCount(pr), 0, "config: no diagnostics")
  assertEqualInt(itemCount(pr), 1, "config: one item")
  assertEqual(firstItemKindName(pr), "config", "config: kind")
}

func testConfigBlockMultipleFields(): Unit {
  val src = "package P\nconfig Settings { port: Int = 8080; host: String = \"0.0.0.0\"; secret: String }\n"
  val pr = parse(src)
  assertEqualInt(diagCount(pr), 0, "config-multi: no diagnostics")
  match pr.file.items[0].kind {
    case IConfig(cd) -> {
      assertEqual(cd.name, "Settings", "config-multi: name")
      assertEqualInt(cd.fields.count, 3, "config-multi: three fields")
    }
    case _ -> assertTrue(false, "config-multi: expected IConfig")
  }
}

func testConfigAsParamName(): Unit {
  // `config` must remain usable as a parameter name; the dispatch is
  // context-sensitive (only fires when followed by an identifier in
  // module scope, not inside a function signature).
  val src = "package P\nfunc describe(config: in String): String { config }\n"
  val pr = parse(src)
  assertEqualInt(diagCount(pr), 0, "config-as-param: no diagnostics")
  assertEqual(firstItemKindName(pr), "func", "config-as-param: kind is func")
}

// ── D047 aspect block parser (self-host mirror of F# bootstrap) ──

func testAspectBlock(): Unit {
  val src =
    "package P\naspect Logging {\n" +
    "  matches: name like \"handle*\"\n" +
    "  around(args) -> ret { proceed(args) }\n" +
    "}\n"
  val pr = parse(src)
  assertEqualInt(diagCount(pr), 0, "aspect: no diagnostics")
  assertEqualInt(itemCount(pr), 1, "aspect: one item")
  assertEqual(firstItemKindName(pr), "aspect", "aspect: kind")
  match pr.file.items[0].kind {
    case IAspect(ad) -> {
      assertEqual(ad.name, "Logging", "aspect: name")
      assertEqualInt(ad.matches.count, 1, "aspect: one matcher")
      match ad.around {
        case Some(_) -> {}
        case None -> assertTrue(false, "aspect: around present")
      }
    }
    case _ -> assertTrue(false, "aspect: expected IAspect")
  }
}

func testAspectAsParamName(): Unit {
  val src = "package P\nfunc tag(aspect: in String): String { aspect }\n"
  val pr = parse(src)
  assertEqualInt(diagCount(pr), 0, "aspect-as-param: no diagnostics")
  assertEqual(firstItemKindName(pr), "func", "aspect-as-param: kind is func")
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

// #425 item 3: peek/peekAt past the last token used to return a
// synthetic TEof with span 0:0, which made diagnostics raised against
// the synthetic token point at the start of the file.  The fix routes
// the out-of-bounds peeks through `syntheticEofSpan`, anchored at the
// real EOF's end position.
func testPeekPastEofUsesSourceEnd(): Unit {
  val src = "package P\n"
  val lr = lex(src)
  var st = makeParseState(lr.tokens, lr.diagnostics)
  // Walk to one position past the last real token.
  while st.pos < lr.tokens.count { st.pos = st.pos + 1 }
  val sp = peek(st).span
  val realEof = lr.tokens[lr.tokens.count - 1].span
  assertTrue(sp.startPos.offset == realEof.endPos.offset,
             "peek-past-EOF: span starts at real EOF end (not 0)")
  assertTrue(sp.endPos.offset == realEof.endPos.offset,
             "peek-past-EOF: span ends at real EOF end (not 0)")
  // The real EOF lives at offset 10 (`"package P\n"`); confirm the
  // synthetic span isn't the 0:0 placeholder the old code returned.
  assertTrue(sp.startPos.offset > 0,
             "peek-past-EOF: synthetic span is not 0:0")
}

// #425 item 5 / #1174: the bare literal `9223372036854775808` fires
// L0010 from the lexer (because the value only fits in Long as a bit
// pattern).  When the literal is the operand of unary minus, the
// parser cancels that L0010 — the wrapped pair represents
// Long.MinValue and is well-formed.  Verifies both the cancellation
// AND that an unrelated `9223372036854775808` in the same source
// keeps its diagnostic.
func testNegationCancelsMinValueAbsDiagnostic(): Unit {
  val src = "package P\nfunc f(): Long { -9223372036854775808 }\n"
  val pr = parse(src)
  var sawL0010 = false
  var i = 0
  while i < pr.diagnostics.count {
    if pr.diagnostics[i].code == "L0010" { sawL0010 = true }
    i = i + 1
  }
  assertTrue(not sawL0010,
             "-9223372036854775808: L0010 cancelled by PreNeg wrapper")
}

func testBareMinValueAbsKeepsDiagnostic(): Unit {
  val src = "package P\nfunc f(): Long { 9223372036854775808 }\n"
  val pr = parse(src)
  var sawL0010 = false
  var i = 0
  while i < pr.diagnostics.count {
    if pr.diagnostics[i].code == "L0010" { sawL0010 = true }
    i = i + 1
  }
  assertTrue(sawL0010,
             "bare 9223372036854775808: L0010 preserved (no PreNeg wrapper)")
}

// `///` (item/outer doc) before `package` is left in the stream by
// `parseModuleDocComments` (which only harvests `//!`) — `parsePackageDecl`
// then surfaces a targeted P0020 pointing at `//!` instead of the bare
// "expected 'package'" message.  Without this assertion, a future refactor
// renaming `TDocComment` could silently revert the improved message.
func testDocCommentBeforePackageDiagnostic(): Unit {
  val src = "/// stray doc\npackage Foo\n"
  val pr = parse(src)
  var sawTargeted = false
  var i = 0
  while i < pr.diagnostics.count {
    val d = pr.diagnostics[i]
    if d.code == "P0020" and d.message.contains("//!") { sawTargeted = true }
    i = i + 1
  }
  assertTrue(sawTargeted,
             "P0020 for '///' before package mentions '//!' module-doc form")
}

func testPeekAtNegativeReturnsSyntheticEof(): Unit {
  // `peekAt(st, k)` with k that places `pos + k` outside the token
  // window must also return the source-end-anchored synthetic EOF
  // rather than a 0:0 span.
  val src = "package P\n"
  val lr = lex(src)
  val st = makeParseState(lr.tokens, lr.diagnostics)
  val sp = peekAt(st, -1).span
  val realEof = lr.tokens[lr.tokens.count - 1].span
  assertTrue(sp.startPos.offset == realEof.endPos.offset,
             "peekAt(-1): span anchored at real EOF, not 0")
}

func main(): Unit {
  testEmptySource()
  testPackageDecl()
  testImport()
  testFuncDecl()
  testIfStmtDoesNotGlueOperator()
  testMatchStmtDoesNotGlueOperator()
  testValueIfStillSingleExpr()
  testRecordDecl()
  testMutableRecordField()
  testImmutableRecordField()
  testPubMutableRecordField()
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
  testConfigBlock()
  testConfigBlockMultipleFields()
  testConfigAsParamName()
  testAspectBlock()
  testAspectAsParamName()
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
  testPeekPastEofUsesSourceEnd()
  testPeekAtNegativeReturnsSyntheticEof()
  testNegationCancelsMinValueAbsDiagnostic()
  testBareMinValueAbsKeepsDiagnostic()
  testDocCommentBeforePackageDiagnostic()
  println("parser self-test: ok")
}
