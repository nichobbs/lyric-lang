//! resolve_self_test.l - Lyric.Resolve (docs/70 §4.2-§4.4, D313).
//!
//! Covers the DefPaths the resolver gives every declaration kind and the §4.3
//! lookup: a package's own names, whole, selective, renamed and aliased
//! imports, re-exports, the direct-over-reexport tier (#8709), the prelude,
//! per-file scopes, and the T0010/T0020/T0097/T0123 outcomes.
@test_module
package Lyric.ResolveSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.PackageMerge as PM
import Lyric.Lexer
import Lyric.Parser
import Lyric.Symbols
import Lyric.Resolve

func depOf(src: in String): DepPackage {
  val pr = parse(src)
  DepPackage(
    name = modulePathJoin(pr.file.packageDecl.path.segments),
    items = pr.file.items,
    reexports = reexportsOf(pr.file.imports)
  )
}

func ctxOf(deps: in List[String], src: in String): ResolverContext {
  val ds: List[DepPackage] = newList()
  for d in deps {
    ds.add(depOf(d))
  }
  val pr = parse(src)
  buildResolverContext(ds, pr.file, newDefPathInterner())
}

func bare(ctx: in ResolverContext, name: in String): Resolution {
  resolveBare(ctx.tbl, scopeOfFile(ctx, 0), name, UseValue)
}

func bareType(ctx: in ResolverContext, name: in String): Resolution {
  resolveBare(ctx.tbl, scopeOfFile(ctx, 0), name, UseType)
}

func pathKeyOf(ctx: in ResolverContext, r: in Resolution): String {
  match r {
    case RSymbol(id) -> match defPathKeyOf(ctx.tbl.interner, id) { case Some(k) -> k; case None -> "<no path>" }
    case ROverloads(ids) -> "overloads:" + toString(ids.count)
    case RPackage(p) -> "package:" + p
    case RDeferred -> "deferred"
    case RUnresolved(code, _) -> code
  }
}

func codeOf(r: in Resolution): String {
  match r {
    case RUnresolved(code, _) -> code
    case _ -> ""
  }
}

func messageOf(r: in Resolution): String {
  match r {
    case RUnresolved(_, m) -> m
    case _ -> ""
  }
}

func assembled(srcs: in List[String]): SourceFile {
  val paths: List[String] = newList()
  var i = 0
  while i < srcs.count {
    paths.add("f" + toString(i) + ".l")
    i = i + 1
  }
  val none: List[String] = newList()
  PM.assemblePackageFiles("P", srcs, paths, none, none, "dotnet").file
}

func pathResolve(ctx: in ResolverContext, segs: in List[String]): PathResolution {
  resolvePath(ctx.tbl, scopeOfFile(ctx, 0), segs, UseValue)
}

func segs2(a: in String, b: in String): List[String] {
  val l: List[String] = newList()
  l.add(a)
  l.add(b)
  l
}

val money: String = "package Money\npub record Amount { cents: Long }\npub func make(c: in Long): Amount = Amount(cents = c)\npub func secret(): Int = 1\nfunc hidden(): Int = 2\n"

val shapes: String = "package Shapes\npub union Shape {\n  case Circle(r: Int)\n  case Square(n: Int)\n}\npub enum Color {\n  case Red\n  case Blue\n}\n"

// ─────────────────────────────────────────────────────────────────────────────
// DefPaths.
// ─────────────────────────────────────────────────────────────────────────────
test "a type, a union case and a function have stable DefPaths" {
  val src = "package P\nimport Shapes\npub record Point { x: Int }\npub func norm(p: in Point, k: in Int): Int = 0\npub func norm(p: in Point): Int = 0\n"
  val ctx = ctxOf(newList(), src)
  assertEqual(pathKeyOf(ctx, bare(ctx, "Point")), "P::Point", "type")
  val norms = bare(ctx, "norm")
  assertEqual(pathKeyOf(ctx, norms), "overloads:2", "two overloads")
  match norms {
    case ROverloads(ids) -> {
      assertEqual(
        match defPathKeyOf(ctx.tbl.interner, ids[0]) { case Some(k) -> k; case None -> "" },
        "P::norm(Point,Int)",
        "first overload carries its parameter types"
      )
      assertEqual(
        match defPathKeyOf(ctx.tbl.interner, ids[1]) { case Some(k) -> k; case None -> "" },
        "P::norm(Point)",
        "second overload"
      )
    }
    case _ -> assertTrue(false, "an overload set")
  }
}

test "union and enum cases nest under their type" {
  val ctx = ctxOf(newList(), shapes)
  assertEqual(pathKeyOf(ctx, bare(ctx, "Circle")), "Shapes::Shape::Circle", "union case")
  assertEqual(pathKeyOf(ctx, bare(ctx, "Red")), "Shapes::Color::Red", "enum case")
}

test "record methods and impl methods have DefPaths under their owner" {
  val src = "package P\npub record Money {\n  cents: Long\n  func add(self: in Money, o: in Money): Money = self\n}\npub interface Show { func show(self: in Money): String }\nimpl Show for Money {\n  func show(self: in Money): String = \"\"\n}\n"
  val ctx = ctxOf(newList(), src)
  var seenAdd = false
  var seenShow = false
  for d in ctx.tbl.decls {
    val key = defPathKey(d.path)
    if key == "P::Money::add(Money,Money)" {
      seenAdd = true
    }
    if key == "P::Money::$impl(Show)::show(Money)" {
      seenShow = true
    }
  }
  assertTrue(seenAdd, "record method path")
  assertTrue(seenShow, "impl method path")
}

test "a package registered twice interns each declaration once" {
  val a = depOf(money)
  val ds: List[DepPackage] = newList()
  ds.add(a)
  ds.add(a)
  val pr = parse("package P\nimport Money\n")
  val ctx = buildResolverContext(ds, pr.file, newDefPathInterner())
  match bare(ctx, "Amount") {
    case RSymbol(id) -> assertTrue(id.id > 0, "one candidate, not two")
    case r -> assertTrue(false, "Amount resolves once: " + pathKeyOf(ctx, r))
  }
}

test "a record method named like a package-level function is not a bare name" {
  val src = "package P\npub record R {\n  v: Int\n  func twice(self: in R): Int = 0\n}\n"
  val ctx = ctxOf(newList(), src)
  assertEqual(codeOf(bare(ctx, "twice")), "T0020", "a method is reached through its receiver")
}

// ─────────────────────────────────────────────────────────────────────────────
// Bare names.
// ─────────────────────────────────────────────────────────────────────────────
test "a package's own declaration wins over an import" {
  val deps: List[String] = newList()
  deps.add(money)
  val ctx = ctxOf(deps, "package P\nimport Money\nrecord Amount { x: Int }\n")
  assertEqual(pathKeyOf(ctx, bare(ctx, "Amount")), "P::Amount", "own package first")
}

test "a whole import makes a package's public names visible bare" {
  val deps: List[String] = newList()
  deps.add(money)
  val ctx = ctxOf(deps, "package P\nimport Money\n")
  assertEqual(pathKeyOf(ctx, bare(ctx, "Amount")), "Money::Amount", "type")
  assertEqual(pathKeyOf(ctx, bare(ctx, "make")), "Money::make(Long)", "function")
}

test "a private name of another package is T0097 and a missing one is T0020" {
  val deps: List[String] = newList()
  deps.add(money)
  val ctx = ctxOf(deps, "package P\nimport Money\n")
  assertEqual(codeOf(bare(ctx, "hidden")), "T0097", "private")
  assertEqual(codeOf(bare(ctx, "nope")), "T0020", "unknown")
  assertEqual(codeOf(bareType(ctx, "nope")), "T0010", "unknown in type position")
}

test "an unimported package's name is T0020 with a hint naming the import" {
  val deps: List[String] = newList()
  deps.add(money)
  val ctx = ctxOf(deps, "package P\n")
  val r = bare(ctx, "Amount")
  assertEqual(codeOf(r), "T0020", "not visible")
  assertTrue(messageOf(r).contains("declared in Money; add import Money"), "hint: " + messageOf(r))
}

test "a selective import makes only the listed names visible" {
  val deps: List[String] = newList()
  deps.add(money)
  val ctx = ctxOf(deps, "package P\nimport Money.{Amount}\n")
  assertEqual(pathKeyOf(ctx, bare(ctx, "Amount")), "Money::Amount", "listed")
  assertEqual(codeOf(bare(ctx, "make")), "T0020", "not listed")
}

test "a listed union brings its cases, a renamed one does not" {
  val deps: List[String] = newList()
  deps.add(shapes)
  val listed = ctxOf(deps, "package P\nimport Shapes.{Shape}\n")
  assertEqual(pathKeyOf(listed, bare(listed, "Circle")), "Shapes::Shape::Circle", "case of a listed union")
  val renamed = ctxOf(deps, "package P\nimport Shapes.{Shape as Shp}\n")
  assertEqual(pathKeyOf(renamed, bare(renamed, "Shp")), "Shapes::Shape", "the rename is the bare name")
  assertEqual(codeOf(bare(renamed, "Shape")), "T0020", "the original name is not visible")
  assertEqual(codeOf(bare(renamed, "Circle")), "T0020", "a renamed union's cases are not bare")
}

test "an aliased import makes no name visible bare" {
  val deps: List[String] = newList()
  deps.add(money)
  val ctx = ctxOf(deps, "package P\nimport Money as M\n")
  val r = bare(ctx, "Amount")
  assertEqual(codeOf(r), "T0020", "alias hides bare names")
  assertTrue(messageOf(r).contains("imported as M; write M.Amount"), "hint: " + messageOf(r))
  assertEqual(
    pathKeyOf(ctx, pathResolve(ctx, segs2("M", "Amount")).res),
    "Money::Amount",
    "qualified through the alias"
  )
}

test "two packages that declare a name are T0123 when both are imported" {
  val other = "package Other\npub record Amount { n: Int }\n"
  val deps: List[String] = newList()
  deps.add(money)
  deps.add(other)
  val ctx = ctxOf(deps, "package P\nimport Money\nimport Other\n")
  val r = bare(ctx, "Amount")
  assertEqual(codeOf(r), "T0123", "ambiguous")
  assertTrue(messageOf(r).contains("'Money', 'Other'"), "names both: " + messageOf(r))
}

test "an alias hides a package from the ambiguity check" {
  val other = "package Other\npub record Amount { n: Int }\n"
  val deps: List[String] = newList()
  deps.add(money)
  deps.add(other)
  val ctx = ctxOf(deps, "package P\nimport Money as QM\nimport Other\n")
  assertEqual(pathKeyOf(ctx, bare(ctx, "Amount")), "Other::Amount", "the aliased package takes no part")
}

test "overloads of one package are one overload set, not T0123" {
  val m = "package Fmt\npub func show(x: in Int): String = \"\"\npub func show(x: in Bool): String = \"\"\n"
  val deps: List[String] = newList()
  deps.add(m)
  val ctx = ctxOf(deps, "package P\nimport Fmt\n")
  assertEqual(pathKeyOf(ctx, bare(ctx, "show")), "overloads:2", "one set")
}

test "the same function name in two packages is T0123" {
  val a = "package A\npub func show(x: in Int): String = \"\"\n"
  val b = "package B\npub func show(x: in Int): String = \"\"\n"
  val deps: List[String] = newList()
  deps.add(a)
  deps.add(b)
  val ctx = ctxOf(deps, "package P\nimport A\nimport B\n")
  assertEqual(codeOf(bare(ctx, "show")), "T0123", "two packages")
}

// ─────────────────────────────────────────────────────────────────────────────
// Re-exports and tiers.
// ─────────────────────────────────────────────────────────────────────────────
test "a whole import reaches what the package re-exports, not what it imports" {
  val host = "package Host\npub record Cell { v: Int }\n"
  val facade = "package Facade\nimport Host\npub use Host\npub func make(): Int = 0\n"
  val plain = "package Plain\nimport Host\npub func make2(): Int = 0\n"
  val deps: List[String] = newList()
  deps.add(host)
  deps.add(facade)
  deps.add(plain)
  val viaFacade = ctxOf(deps, "package P\nimport Facade\n")
  assertEqual(pathKeyOf(viaFacade, bare(viaFacade, "Cell")), "Host::Cell", "re-exported")
  val viaPlain = ctxOf(deps, "package P\nimport Plain\n")
  assertEqual(codeOf(bare(viaPlain, "Cell")), "T0020", "only imported")
}

test "a name the file imports directly shadows the same name seen through a re-export" {
  val host = "package Host\npub record Cell { v: Int }\n"
  val facade = "package Facade\nimport Host\npub use Host\n"
  val mine = "package Mine\npub record Cell { w: Int }\n"
  val deps: List[String] = newList()
  deps.add(host)
  deps.add(facade)
  deps.add(mine)
  val ctx = ctxOf(deps, "package P\nimport Facade\nimport Mine\n")
  assertEqual(pathKeyOf(ctx, bare(ctx, "Cell")), "Mine::Cell", "direct beats re-export")
}

test "a selective import of one name does not make the package's other names direct (#8709)" {
  val host = "package Host\npub record Row { v: Int }\n"
  val facade = "package Facade\npub record Cell { w: Int }\npub record Row { w: Int }\n"
  val deps: List[String] = newList()
  deps.add(host)
  deps.add(facade)
  val ctx = ctxOf(deps, "package P\nimport Facade.{Cell}\nimport Host\n")
  assertEqual(pathKeyOf(ctx, bare(ctx, "Cell")), "Facade::Cell", "the listed name")
  assertEqual(pathKeyOf(ctx, bare(ctx, "Row")), "Host::Row", "Facade's unlisted Row is not a candidate")
}

test "a qualified name through a re-exporting package finds the re-exported declaration" {
  val host = "package Host\npub func newThing(): Int = 0\n"
  val facade = "package Facade\nimport Host\npub use Host\n"
  val deps: List[String] = newList()
  deps.add(host)
  deps.add(facade)
  val ctx = ctxOf(deps, "package P\nimport Facade as F\n")
  assertEqual(pathKeyOf(ctx, pathResolve(ctx, segs2("F", "newThing")).res), "Host::newThing()", "re-exported")
}

test "a package the file does not import cannot be named" {
  val a = "package A\nimport B\npub func f(): Int = 0\n"
  val b = "package B\npub func g(): Int = 0\n"
  val deps: List[String] = newList()
  deps.add(a)
  deps.add(b)
  val ctx = ctxOf(deps, "package P\nimport A\n")
  val r = pathResolve(ctx, segs2("B", "g")).res
  assertEqual(codeOf(r), "T0020", "B is imported by A, not by this file")
  assertTrue(messageOf(r).contains("package B is not imported"), "message: " + messageOf(r))
}

test "the prelude is visible without an import" {
  val core = "package Std.Core\npub union Option[T] {\n  case Some(value: T)\n  case None\n}\n"
  val deps: List[String] = newList()
  deps.add(core)
  val ctx = ctxOf(deps, "package P\n")
  assertEqual(pathKeyOf(ctx, bare(ctx, "Option")), "Std.Core::Option", "type")
  assertEqual(pathKeyOf(ctx, bare(ctx, "Some")), "Std.Core::Option::Some", "case")
}

// ─────────────────────────────────────────────────────────────────────────────
// Per-file scopes (docs/70 §4.1).
// ─────────────────────────────────────────────────────────────────────────────
test "each file of a package has its own imports" {
  val srcs: List[String] = newList()
  srcs.add("package P\nimport Money\n")
  srcs.add("package P\nfunc g(): Int = 0\n")
  val merged = assembled(srcs)
  val ds: List[DepPackage] = newList()
  ds.add(depOf(money))
  val ctx = buildResolverContext(ds, merged, newDefPathInterner())
  assertEqualInt(ctx.scopes.count, 2, "one scope per file")
  assertEqual(
    pathKeyOf(ctx, resolveBare(ctx.tbl, scopeOfFile(ctx, 0), "Amount", UseValue)),
    "Money::Amount",
    "the file that imports it"
  )
  assertEqual(
    codeOf(resolveBare(ctx.tbl, scopeOfFile(ctx, 1), "Amount", UseValue)),
    "T0020",
    "the sibling that does not"
  )
}

test "two files may import different packages for one bare name" {
  val other = "package Other\npub record Amount { n: Int }\n"
  val srcs: List[String] = newList()
  srcs.add("package P\nimport Money\n")
  srcs.add("package P\nimport Other\n")
  val merged = assembled(srcs)
  val ds: List[DepPackage] = newList()
  ds.add(depOf(money))
  ds.add(depOf(other))
  val ctx = buildResolverContext(ds, merged, newDefPathInterner())
  assertEqual(pathKeyOf(ctx, resolveBare(ctx.tbl, scopeOfFile(ctx, 0), "Amount", UseValue)), "Money::Amount", "file 0")
  assertEqual(pathKeyOf(ctx, resolveBare(ctx.tbl, scopeOfFile(ctx, 1), "Amount", UseValue)), "Other::Amount", "file 1")
}

test "an alias is per file" {
  val other = "package Other\npub record Amount { n: Int }\n"
  val srcs: List[String] = newList()
  srcs.add("package P\nimport Money as M\n")
  srcs.add("package P\nimport Other as M\n")
  val merged = assembled(srcs)
  val ds: List[DepPackage] = newList()
  ds.add(depOf(money))
  ds.add(depOf(other))
  val ctx = buildResolverContext(ds, merged, newDefPathInterner())
  assertEqual(
    pathKeyOf(ctx, resolvePath(ctx.tbl, scopeOfFile(ctx, 0), segs2("M", "Amount"), UseValue).res),
    "Money::Amount",
    "file 0's M"
  )
  assertEqual(
    pathKeyOf(ctx, resolvePath(ctx.tbl, scopeOfFile(ctx, 1), segs2("M", "Amount"), UseValue).res),
    "Other::Amount",
    "file 1's M"
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// import extern.
// ─────────────────────────────────────────────────────────────────────────────
test "an import extern binds the host type under its DefPath" {
  val ctx = ctxOf(newList(), "package P\nimport extern System.Text.{StringBuilder as SB}\n")
  assertEqual(pathKeyOf(ctx, bareType(ctx, "SB")), "extern::System.Text.StringBuilder", "extern type")
}

test "an extern type declared in source and imported by name is one declaration" {
  val src = "package P\nextern type Builder = \"System.Text.StringBuilder\"\nimport extern System.Text.StringBuilder\n"
  val ctx = ctxOf(newList(), src)
  val a = bareType(ctx, "Builder")
  val b = bareType(ctx, "StringBuilder")
  assertEqual(pathKeyOf(ctx, a), "extern::System.Text.StringBuilder", "declared")
  assertEqual(pathKeyOf(ctx, b), "extern::System.Text.StringBuilder", "imported")
}
