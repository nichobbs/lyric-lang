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
  println("parser self-test: ok")
}
