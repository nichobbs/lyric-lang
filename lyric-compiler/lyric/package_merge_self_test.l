//! package_merge_self_test.l — the multi-file package merge
//! (`Lyric.PackageMerge`, docs/19, #8234).
//!
//! A merged package is exactly the union of its files' own parses: a comment
//! in a file's header stays a comment, a file that does not parse or that
//! declares another package is reported against its own path and line, the
//! files' file-level annotations are united (and must agree), and every merged
//! line maps back to its file and line.
//!
//!   lyric test lyric-compiler/lyric/package_merge_self_test.l
@test_module
package Lyric.PackageMergeSelfTest

import Std.Core
import Std.Collections
import Std.String as Str
import Std.Testing
import Lyric.Lexer
import Lyric.Parser as Parser
import Lyric.Parser.{Item, IFunc, IRecord, modulePathJoin}
import Lyric.PackageMerge as PM
import Std.Errors
import Std.File as File
import Std.Path as Path
import Std.Environment as Environment
import Std.Uuid
import Lyric.Manifest as Mf
import Lyric.Discovery as Disc

func two(a: in String, b: in String): List[String] {
  val xs: List[String] = newList()
  xs.add(a)
  xs.add(b)
  xs
}

func none(): List[String] {
  newList()
}

func merge(a: in String, b: in String): PM.PackageMergeResult {
  mergeFor(a, b, "dotnet")
}

func mergeFor(a: in String, b: in String, target: in String): PM.PackageMergeResult {
  PM.mergePackageFiles("P", two(a, b), two("a.l", "b.l"), none(), none(), target, true)
}

// Every diagnostic as `path:CODE:line`, comma-separated, for exact checks.
func diagSummary(r: in PM.PackageMergeResult): String {
  val parts: List[String] = newList()
  for d in r.diagnostics {
    parts.add(d.path + ":" + d.diag.code + ":" + toString(d.diag.span.startPos.line))
  }
  Str.joinList(",", parts)
}

func itemCount(source: in String): Int {
  Parser.parse(source).file.items.count
}

func parsesCleanly(source: in String): Bool {
  Parser.parse(source).diagnostics.count == 0
}

test "two well-formed files merge to their header union and their items, line for line" {
  val a = "//! A doc\n@runtime_checked\npackage P\n\nimport Std.Core\nimport Std.String as Str\n\n// helper\npub func a(): Int { 1 }\n"
  val b = "// B header comment\n@runtime_checked\npackage P\nimport Std.Core\n\npub func b(): Int { 2 }\n"
  val r = merge(a, b)
  assertEqual(diagSummary(r), "", "no diagnostics")
  val expected = "//! A doc\n@runtime_checked\npackage P\nimport Std.Core\nimport Std.String as Str\n" +
    "\n\n// helper\npub func a(): Int { 1 }\n" +
    "\n" +
    "// B header comment\n\npub func b(): Int { 2 }\n"
  assertEqual(r.source, expected, "merged unit")
  assertEqualInt(r.origins.count, Str.split(r.source, "\n").length, "one origin per merged line")
  // `pub func a` is line 9 of a.l; `// B header comment` line 1 of b.l.
  val lines = Str.split(r.source, "\n")
  var li = 0
  while li < lines.length {
    if lines[li] == "pub func a(): Int { 1 }" {
      assertEqual(r.origins[li].path, "a.l", "a's item file")
      assertEqualInt(r.origins[li].originalLine, 9, "a's item line")
    }
    if lines[li] == "// B header comment" {
      assertEqual(r.origins[li].path, "b.l", "b's comment file")
      assertEqualInt(r.origins[li].originalLine, 1, "b's comment line")
    }
    if lines[li] == "@runtime_checked" {
      assertEqual(r.origins[li].path, "a.l", "annotation file")
      assertEqualInt(r.origins[li].originalLine, 2, "annotation line")
    }
    li = li + 1
  }
}

test "every file's module docs reach the merged unit, in file order, one empty doc line apart" {
  val a = "//! First file.\n//!\n//! More of the first.\n@runtime_checked\npackage P\n\npub func a(): Int { 1 }\n"
  val b = "//! Second file.\n@runtime_checked\npackage P\n\npub func b(): Int { 2 }\n"
  val r = merge(a, b)
  assertEqual(diagSummary(r), "", "no diagnostics")
  assertTrue(
    Str.startsWith(
      r.source,
      "//! First file.\n//!\n//! More of the first.\n//!\n//! Second file.\n@runtime_checked\npackage P\n"
    ),
    r.source
  )
  val parsed = Parser.parse(r.source)
  assertEqualInt(parsed.diagnostics.count, 0, "the merged unit parses")
  assertEqualInt(parsed.file.moduleDoc.count, 5, "five module doc lines")
  assertEqualInt(r.origins.count, Str.split(r.source, "\n").length, "one origin per merged line")
  assertEqual(r.origins[4].path, "b.l", "b's doc line file")
  assertEqualInt(r.origins[4].originalLine, 1, "b's doc line")
  assertEqual(r.origins[3].path, "", "the separator belongs to no file")
}

test "module docs keep non-ASCII text, including after it, and CRLF files" {
  val a = "//! Résumé ✓ 😀 done\r\n//! after\r\n@runtime_checked\r\npackage P\r\n\r\npub func a(): Int { 1 }\r\n"
  val b = "//! Zweite Datei: ñ\r\npackage P\r\npub func b(): Int { 2 }\r\n"
  val r = merge(a, b)
  assertEqual(diagSummary(r), "", "no diagnostics")
  assertTrue(
    Str.startsWith(r.source, "//! Résumé ✓ 😀 done\n//! after\n//!\n//! Zweite Datei: ñ\n@runtime_checked\npackage P\n"),
    r.source
  )
  assertTrue(not Str.contains(r.source, "\r"), "newlines are normalised")
  val parsed = Parser.parse(r.source)
  assertEqualInt(parsed.diagnostics.count, 0, "the merged unit parses")
  assertEqualInt(parsed.file.items.count, 2, "both functions survive")
}

test "a file with no module doc adds no separator, and a gated-out file contributes no doc" {
  val a = "package P\n\npub func a(): Int { 1 }\n"
  val b = "//! Only b.\npackage P\n\npub func b(): Int { 2 }\n"
  val r = merge(a, b)
  assertTrue(Str.startsWith(r.source, "//! Only b.\npackage P\n"), r.source)
  val g = "//! Gated.\n@cfg(target = \"jvm\")\npackage P\n\npub func g(): Int { 3 }\n"
  val r2 = mergeFor(g, b, "dotnet")
  assertEqual(diagSummary(r2), "", "no diagnostics")
  assertTrue(not Str.contains(r2.source, "Gated."), "a gated-out file's docs are not carried: " + r2.source)
  assertTrue(Str.startsWith(r2.source, "//! Only b.\n"), r2.source)
}

test "a block comment that an annotation line opens and closes stays a comment" {
  // #8234's `trick_hid2`: both `@runtime_checked` lines carry a comment
  // delimiter; the declarations between them are commented out.
  val a = "@runtime_checked\npackage P\n\npub func f(): Bool { true }\n"
  val b = "@runtime_checked /*\npub union Option[T] {\n  case Some(value: T)\n  case Other\n}\n@runtime_checked */\npackage P\n\npub record Filler {\n  n: Int\n}\n"
  val r = merge(a, b)
  assertEqual(diagSummary(r), "", "no diagnostics")
  assertTrue(parsesCleanly(r.source), "the merged unit parses: " + r.source)
  assertEqualInt(itemCount(r.source), 2, "only `f` and `Filler`: the union stays commented out")
  assertTrue(Str.contains(r.source, "/*\npub union Option[T]"), "the comment opener is kept")
  assertTrue(Str.contains(r.source, "@runtime_checked */"), "the comment's own text is kept, closer included")
}

test "files that disagree on the verification level are B0014" {
  val a = "@proof_required\npackage P\n\npub func f(): Bool { true }\n"
  val b = "@runtime_checked\npackage P\n\npub func g(): Bool { true }\n"
  val r = merge(a, b)
  assertEqual(diagSummary(r), "b.l:B0014:1", "B0014 on b.l's annotation")
  assertTrue(PM.mergeHasErrors(r), "an error")
  assertTrue(Str.contains(r.diagnostics[0].diag.message, "a.l:1 is @proof_required"), r.diagnostics[0].diag.message)
}

test "a file that declares another package is B0013" {
  val a = "package P\n\npub func f(): Int { 1 }\n"
  val b = "//! elsewhere\n\npackage Elsewhere\n\npub func g(): Int { 2 }\n"
  val r = merge(a, b)
  assertEqual(diagSummary(r), "b.l:B0013:3", "B0013 at b.l's package line")
  assertTrue(Str.contains(r.diagnostics[0].diag.message, "declares package Elsewhere"), r.diagnostics[0].diag.message)
}

test "a file that does not parse is reported against its own path and line" {
  // #8234's `otherpkg`: a broken annotation, and another package.
  val a = "@proof_required\npackage P\n\npub func f(): Int { 1 }\n"
  val b = "@runtime_checked(((\npackage Elsewhere\n\npub func g(): Int { 2 }\n"
  val r = merge(a, b)
  assertTrue(PM.mergeHasErrors(r), "an error")
  for d in r.diagnostics {
    assertEqual(d.path, "b.l", "every diagnostic is b.l's: " + diagSummary(r))
  }
  assertTrue(Str.startsWith(r.diagnostics[0].diag.code, "P"), "a parse diagnostic first: " + diagSummary(r))
  assertTrue(Str.contains(diagSummary(r), "b.l:B0013:2"), "and the package it names is not P: " + diagSummary(r))
}

test "a file without a package declaration is P0020" {
  val a = "package P\n\npub func f(): Int { 1 }\n"
  val b = "// no header\npub func g(): Int { 2 }\n"
  val r = merge(a, b)
  assertEqual(diagSummary(r), "b.l:P0020:2", "P0020 where b.l's package declaration belongs")
}

test "a file of comments only adds its comments and nothing else" {
  val a = "package P\n\npub func f(): Int { 1 }\n"
  val b = "// notes for the package\n/* more */\n"
  val r = merge(a, b)
  assertEqual(diagSummary(r), "", "no diagnostics")
  assertTrue(parsesCleanly(r.source), "parses")
  assertEqualInt(itemCount(r.source), 1, "one item")
  assertTrue(Str.contains(r.source, "// notes for the package"), "the comment is kept")
}

test "header text inside a comment is not header" {
  val a = "/* package Fake\nimport Not.Real\n@proof_required\n*/\npackage P\n// import Also.Not\nimport Std.Core // why\n\npub func f(): Int { 1 }\n"
  val b = "package P\n\npub func g(): Int { 2 }\n"
  val r = merge(a, b)
  assertEqual(diagSummary(r), "", "no diagnostics")
  assertTrue(parsesCleanly(r.source), "parses: " + r.source)
  assertEqualInt(itemCount(r.source), 2, "two items")
  val preamble = Str.substring(r.source, 0, Str.indexOfRaw(r.source, "/* package Fake"))
  assertEqual(preamble, "package P\nimport Std.Core\n", "only the real import, and no annotation")
  assertTrue(not Str.contains(r.source, "// why"), "the import's own line goes with it")
  assertTrue(Str.contains(r.source, "// import Also.Not"), "a comment line between imports stays")
}

test "file-level annotations are united, kept once, and keep their line" {
  val a = "package P\n\npub func f(): Int { 1 }\n"
  val b = "@runtime_checked @io\npackage P\n\npub func g(): Int { 2 }\n"
  val c = "@io\npackage P\n\npub func h(): Int { 3 }\n"
  val srcs = two(a, b)
  srcs.add(c)
  val paths = two("a.l", "b.l")
  paths.add("c.l")
  val r = PM.mergePackageFiles("P", srcs, paths, none(), none(), "dotnet", true)
  assertEqual(diagSummary(r), "", "no diagnostics")
  assertTrue(Str.startsWith(r.source, "@runtime_checked @io\npackage P\n"), "b's annotations, as written: " + r.source)
  assertEqual(r.origins[0].path, "b.l", "annotation origin")
}

test "an annotation written two ways is B0014, @pure against @io is Y0009" {
  val a = "@proof_required\npackage P\n\npub func f(): Int { 1 }\n"
  val b = "@proof_required(unsafe_blocks_allowed)\npackage P\n\npub func g(): Int { 2 }\n"
  assertEqual(diagSummary(merge(a, b)), "b.l:B0014:1", "same annotation, other arguments")
  val c = "@pure\npackage P\n\npub func f(): Int { 1 }\n"
  val d = "@io\npackage P\n\npub func g(): Int { 2 }\n"
  assertEqual(diagSummary(merge(c, d)), "b.l:Y0009:1", "a package is @pure or @io")
}

test "a file whose file-level @cfg is off contributes no item or import" {
  val a = "package P\n\npub func pick(): Int { 1 }\n"
  val b = "@cfg(feature = \"extra\")\n@proof_required\npackage P\nimport Std.Math\n\npub func pick(): Int { 999 }\n"
  val declared: List[String] = newList()
  declared.add("extra")
  val off = PM.mergePackageFiles("P", two(a, b), two("a.l", "b.l"), none(), declared, "dotnet", true)
  assertEqual(diagSummary(off), "", "no diagnostics")
  assertEqualInt(itemCount(off.source), 1, "b's item is gone")
  assertTrue(not Str.contains(off.source, "Std.Math"), "and so is its import")
  assertTrue(Str.startsWith(off.source, "@proof_required\npackage P\n"), "its annotation still describes the package")
  val on = PM.mergePackageFiles("P", two(a, b), two("a.l", "b.l"), declared, declared, "dotnet", true)
  assertEqualInt(itemCount(on.source), 2, "with the feature on, both items")
  assertTrue(not Str.contains(on.source, "@cfg"), "a file-level @cfg is per file, never the package's")
}

test "a malformed or undeclared file-level @cfg is F0012 or F0013" {
  val a = "package P\n\npub func f(): Int { 1 }\n"
  val bad = "@cfg(feture = \"x\")\npackage P\n\npub func g(): Int { 2 }\n"
  val declared: List[String] = newList()
  declared.add("extra")
  val r1 = PM.mergePackageFiles("P", two(a, bad), two("a.l", "b.l"), none(), declared, "dotnet", true)
  assertEqual(diagSummary(r1), "b.l:F0012:1", "malformed")
  val typo = "@cfg(feature = \"exrta\")\npackage P\n\npub func g(): Int { 2 }\n"
  val r2 = PM.mergePackageFiles("P", two(a, typo), two("a.l", "b.l"), none(), declared, "dotnet", true)
  assertEqual(diagSummary(r2), "b.l:F0013:1", "undeclared feature")
  assertTrue(not PM.mergeHasErrors(r2), "F0013 is a warning")
}

test "a file-level @cfg(target) is decided against the build's target" {
  // Review repro r3: each target sees exactly one `which`.
  val main = "package P\n\nfunc main(): Unit {\n  println(toString(which()))\n}\n"
  val onJvm = "@cfg(target = \"jvm\")\npackage P\nfunc which(): Int { 1 }\n"
  val onDotnet = "@cfg(target = \"dotnet\")\npackage P\nfunc which(): Int { 2 }\n"
  val srcs = two(main, onJvm)
  srcs.add(onDotnet)
  val paths = two("a.l", "b.l")
  paths.add("c.l")
  val dn = PM.mergePackageFiles("P", srcs, paths, none(), none(), "dotnet", true)
  assertEqual(diagSummary(dn), "", "dotnet merges")
  assertEqualInt(itemCount(dn.source), 2, "dotnet: main and one which")
  assertTrue(Str.contains(dn.source, "{ 2 }") and not Str.contains(dn.source, "{ 1 }"), "dotnet keeps c.l")
  val jv = PM.mergePackageFiles("P", srcs, paths, none(), none(), "jvm", true)
  assertTrue(Str.contains(jv.source, "{ 1 }") and not Str.contains(jv.source, "{ 2 }"), "jvm keeps b.l")
  val nt = PM.mergePackageFiles("P", srcs, paths, none(), none(), "native", true)
  assertEqualInt(itemCount(nt.source), 1, "native keeps neither")
}

test "every file of a package gated off leaves an empty package" {
  // #1124: the package still exists, with one `package` declaration.
  val a = "@cfg(feature = \"redis\")\npackage P\nimport Std.Core\npub func a(): Int { 1 }\n"
  val b = "@cfg(feature = \"redis\")\n@io\npackage P\npub func b(): Int { 2 }\n"
  val r = merge(a, b)
  assertEqual(diagSummary(r), "", "no diagnostics")
  assertTrue(parsesCleanly(r.source), "parses: " + r.source)
  assertEqualInt(itemCount(r.source), 0, "no items")
  assertEqual(r.source, "@io\npackage P\n\n", "one package declaration, the package's annotation")
}

test "an import alias two files bind to different packages is B0012" {
  // Review repro r1.
  val a = "package P\nimport Std.String as X\n\nfunc main(): Unit { }\n"
  val b = "package P\nimport Std.Math as X\n\nfunc other(): Int { 1 }\n"
  val r = merge(a, b)
  assertEqual(diagSummary(r), "b.l:B0012:2", "B0012 on b.l's import")
  assertTrue(
    Str.contains(r.diagnostics[0].diag.message, "names Std.Math here but Std.String at a.l:2"),
    r.diagnostics[0].diag.message
  )
  val same = merge(a, "package P\nimport Std.String as X\n\nfunc other(): Int { 1 }\n")
  assertEqual(diagSummary(same), "", "the same alias for the same package is one import")
}

test "a unit-mode annotation only some files carry is B0014" {
  // Review repro r5: `@contract_source` would make `{ 42 }` a block in b.l.
  val a = "@contract_source\npackage P\n\nfunc f(): Int { 1 }\n"
  val b = "package P\nfunc main(): Unit {\n  val g = { 42 }\n  println(toString(g()))\n}\n"
  val r = merge(a, b)
  assertEqual(diagSummary(r), "b.l:B0014:1", "b.l is not @contract_source")
  assertTrue(Str.contains(r.diagnostics[0].diag.message, "@contract_source"), r.diagnostics[0].diag.message)
  val t = merge("@test_module\npackage P\n", "package P\npub func h(): Int { 1 }\n")
  assertEqual(diagSummary(t), "b.l:B0014:1", "@test_module on one file only")
  val both = merge("@test_module\npackage P\n", "@test_module\npackage P\npub func h(): Int { 1 }\n")
  assertEqual(diagSummary(both), "", "on every file, it is the package's")
}

test "annotations or imports with no package declaration are P0020" {
  // Review repro r4.
  val a = "package P\n\nfunc main(): Unit { }\n"
  assertEqual(diagSummary(merge(a, "// stray\n@axiom\n")), "b.l:P0020:2", "annotation only")
  assertEqual(diagSummary(merge(a, "import Std.Core\n")), "b.l:P0020:1", "import only")
}

test "CRLF files and one-line headers merge with their lines" {
  val a = "@runtime_checked\r\npackage P\r\nimport Std.Core\r\n\r\nfunc main(): Unit {\r\n  println(toString(two()))\r\n}\r\n"
  val b = "package P; import Std.Core; func two(): Int { 2 }\n"
  val c = "/* hdr\n*/ @runtime_checked /* x\n y */ package P /*\n*/ import Std.Core /* q\n */ func three(): Int {\n\t3\n}\n"
  val srcs = two(a, b)
  srcs.add(c)
  val paths = two("a.l", "b.l")
  paths.add("c.l")
  val r = PM.mergePackageFiles("P", srcs, paths, none(), none(), "dotnet", true)
  assertEqual(diagSummary(r), "", "no diagnostics")
  assertTrue(parsesCleanly(r.source), "parses: " + r.source)
  assertEqualInt(itemCount(r.source), 3, "three items")
  assertTrue(not Str.contains(r.source, "\r"), "newlines normalised")
  val lines = Str.split(r.source, "\n")
  assertEqualInt(r.origins.count, lines.length, "one origin per line")
  var li = 0
  while li < lines.length {
    if Str.contains(lines[li], "func two()") {
      assertEqual(r.origins[li].path, "b.l", "two's file")
      assertEqualInt(r.origins[li].originalLine, 1, "two's line")
      assertEqualInt(Str.indexOfRaw(lines[li], "func two()"), 28, "b.l's header blanked in place: " + lines[li])
    }
    if Str.contains(lines[li], "func three()") {
      assertEqual(r.origins[li].path, "c.l", "three's file")
      assertEqualInt(r.origins[li].originalLine, 5, "three's line")
    }
    li = li + 1
  }
}

test "a package of one file that declares another package is B0013" {
  // Review repro r9.
  val only: List[String] = newList()
  only.add("//! doc\npackage Elsewhere\nfunc main(): Unit { }\n")
  val paths: List[String] = newList()
  paths.add("a.l")
  val r = PM.mergePackageFiles("P", only, paths, none(), none(), "dotnet", true)
  assertEqual(diagSummary(r), "a.l:B0013:2", "B0013 at the package name")
}

test "a package of one file is returned as written" {
  val only: List[String] = newList()
  only.add("// as written\npackage P\nimport Std.Core\n")
  val paths: List[String] = newList()
  paths.add("a.l")
  val r = PM.mergePackageFiles("P", only, paths, none(), none(), "dotnet", true)
  assertEqual(r.source, "// as written\npackage P\nimport Std.Core\n", "verbatim")
  assertEqualInt(r.origins.count, 0, "no origins")
}

test "a discovered package of one file is rebuilt in the merged shape" {
  val only: List[String] = newList()
  only.add("//! doc\n@io\npackage Std.X\n\nimport Std.Core\n\npub func f(): Int { 1 }\n")
  val paths: List[String] = newList()
  paths.add("x.l")
  val r = PM.mergeDiscoveredPackage("Std.X", only, paths, "dotnet")
  assertEqual(r.source, "//! doc\n@io\npackage Std.X\nimport Std.Core\n\n\npub func f(): Int { 1 }\n", "rebuilt")
}

test "scanHeader reads the package and imports past comments and annotation strings" {
  val src = "//! doc\n/* package Fake\n /* nested */ import Not.Real */\n@cfg(feature = \"a)b\")\n@io\npackage A.B\n" +
    "// c\nimport Std.Core\nimport Std.String as Str\nimport extern System.{Math as M}\n\nfunc f(): Int { 1 }\n"
  val h = PM.scanHeader(src)
  assertEqual(h.packageName, "A.B", "package")
  assertEqual(
    Str.joinList("|", h.imports),
    "import Std.Core|import Std.String as Str|import extern System.{Math as M}",
    "imports"
  )
  assertEqual(PM.scanHeader("func f(): Int { 1 }\n").packageName, "", "no header")
  assertEqual(PM.scanHeader("/* never closed\npackage A\n").packageName, "", "unterminated comment")
}

test "a one-file package named from its own source is not held to the name" {
  // Review repro sf: a single-file build names its package from the source.
  val only: List[String] = newList()
  only.add("/*\npackage Old\n*/\npackage Mf\nfunc main(): Unit { }\n")
  val paths: List[String] = newList()
  paths.add("a.l")
  val r = PM.mergePackageFiles("Old", only, paths, none(), none(), "dotnet", false)
  assertEqual(diagSummary(r), "", "no B0013")
  assertEqual(PM.scanHeader(only[0]).packageName, "Mf", "the commented-out package line is not the declaration")
  assertEqual(PM.scanHeader("package Mf; func main(): Unit { }\n").packageName, "Mf", "one-line header")
  assertEqual(
    PM.headerThroughPackage("/* package X */\n@io\npackage A.B // c\nimport Std.Core\n"),
    "/* package X */\n@io\npackage A.B\n",
    "header text"
  )
}

func writeFile(path: in String, text: in String): Unit {
  match File.writeText(path, text) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write " + path + ": " + IOError.message(e))
  }
}

func makeDir(path: in String): Unit {
  match File.createDir(path) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create " + path + ": " + IOError.message(e))
  }
}

test "a directory entry leaves out a sub-package entry nested in it" {
  // Review repro sub: `Account.Internal` lives in `src/account/internal`.
  val tmp = Environment.getVarOrDefault("TMPDIR", "/tmp")
  val root = Path.join(tmp, "lyric-pkgmerge-sub-" + uuidToString(newUuid()))
  makeDir(root)
  makeDir(Path.join(root, "src"))
  makeDir(Path.join(root, "src/account"))
  makeDir(Path.join(root, "src/account/internal"))
  makeDir(Path.join(root, "src/account/more"))
  writeFile(Path.join(root, "src/account/a.l"), "package Account\n")
  writeFile(Path.join(root, "src/account/internal/k.l"), "package Account.Internal\n")
  writeFile(Path.join(root, "src/account/more/c.l"), "package Account\n")
  val mfText = "[package]\nname = \"Acc\"\nversion = \"0.1.0\"\n\n[project]\nname = \"Acc\"\n\n" +
    "[project.packages]\n\"Account\" = \"src/account\"\n\"Account.Internal\" = \"src/account/internal\"\n"
  val mfPath = Path.join(root, "lyric.toml")
  writeFile(mfPath, mfText)
  val proj = match Mf.parseManifest(mfText, mfPath) {
    case Ok(m) -> match m.project { case Some(p) -> p; case None -> panic("no [project]") }
    case Err(_) -> panic("manifest does not parse")
  }
  val account = Disc.projectEntryFiles(proj.packages[0], root, proj)
  val names: List[String] = newList()
  for f in account.paths.toArray() {
    names.add(Path.basename(f))
  }
  assertEqual(
    Str.joinList(",", names),
    "a.l,c.l",
    "Account: its files and a plain subdirectory's, not Account.Internal's"
  )
  val internalFiles = Disc.projectEntryFiles(proj.packages[1], root, proj)
  assertEqualInt(internalFiles.paths.count, 1, "Account.Internal: its own file")
  match File.deleteDirRecursive(root) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// docs/70 §4.1: a package assembled from its separately parsed files has the
// diagnostics, items and header the merge gives the same files.
// ─────────────────────────────────────────────────────────────────────────────
func assembleSummary(r: in PM.PackageAssembly): String {
  val parts: List[String] = newList()
  for d in r.diagnostics {
    parts.add(d.path + ":" + d.diag.code + ":" + toString(d.diag.span.startPos.line))
  }
  Str.joinList(",", parts)
}

func itemNames(items: in List[Item]): String {
  val names: List[String] = newList()
  for it in items {
    match it.kind {
      case IFunc(fd) -> names.add(fd.name)
      case IRecord(rd) -> names.add(rd.name)
      case _ -> names.add("?")
    }
  }
  Str.joinList(",", names)
}

// The assembly of `srcs` agrees with their merge: the same diagnostics and,
// when those leave the package usable, the same items, imports, file-level
// annotations and module-doc lines.
func assertAssemblyMatchesMerge(srcs: in List[String], paths: in List[String], active: in List[String], declared: in List[String], target: in String, what: in String): Unit {
  val merged = PM.mergePackageFiles("P", srcs, paths, active, declared, target, true)
  val assembled = PM.assemblePackageFiles("P", srcs, paths, active, declared, target)
  assertEqual(assembleSummary(assembled), diagSummary(merged), what + ": diagnostics")
  if not PM.mergeHasErrors(merged) {
    val mf = Parser.parse(merged.source).file
    assertEqual(itemNames(assembled.file.items), itemNames(mf.items), what + ": items")
    assertEqualInt(assembled.file.imports.count, mf.imports.count, what + ": imports")
    assertEqualInt(assembled.file.fileAnnotations.count, mf.fileAnnotations.count, what + ": file-level annotations")
    assertEqualInt(assembled.file.files.count, srcs.count, what + ": one header per file")
  }
}

test "an assembled package matches the merge of the same files" {
  val a = "//! A doc\n@runtime_checked\npackage P\n\nimport Std.Core\nimport Std.String as Str\n\npub func a(): Int { 1 }\n"
  val b = "@runtime_checked\npackage P\nimport Std.Core\n\npub func b(): Int { 2 }\nrecord R {\n  n: Int\n}\n"
  assertAssemblyMatchesMerge(two(a, b), two("a.l", "b.l"), none(), none(), "dotnet", "two files")
  val declared: List[String] = newList()
  declared.add("extra")
  val gated = "@cfg(feature = \"extra\")\n@proof_required\npackage P\nimport Std.Math\n\npub func pick(): Int { 999 }\n"
  assertAssemblyMatchesMerge(two(a, gated), two("a.l", "b.l"), none(), declared, "dotnet", "a gated-off file")
  assertAssemblyMatchesMerge(two(a, gated), two("a.l", "b.l"), declared, declared, "dotnet", "a gated-on file")
  val levels = "@proof_required\npackage P\npub func c(): Int { 3 }\n"
  assertAssemblyMatchesMerge(two(a, levels), two("a.l", "b.l"), none(), none(), "dotnet", "B0014")
  assertAssemblyMatchesMerge(two(a, "package Q\npub func c(): Int { 3 }\n"), two("a.l", "b.l"), none(), none(), "dotnet", "B0013")
  assertAssemblyMatchesMerge(two(a, "// stray\n@axiom\n"), two("a.l", "b.l"), none(), none(), "dotnet", "P0020")
  val aliasA = "package P\nimport Std.String as X\n\nfunc main(): Unit { }\n"
  val aliasB = "package P\nimport Std.Math as X\n\nfunc other(): Int { 1 }\n"
  assertAssemblyMatchesMerge(two(aliasA, aliasB), two("a.l", "b.l"), none(), none(), "dotnet", "B0012")
  assertAssemblyMatchesMerge(two("@test_module\npackage P\n", "package P\npub func h(): Int { 1 }\n"), two("a.l", "b.l"), none(), none(), "dotnet", "unit mode")
  assertAssemblyMatchesMerge(two(a, "package P\npub func broken( {\n"), two("a.l", "b.l"), none(), none(), "dotnet", "a file that does not parse")
}

test "each file of an assembled package keeps its own header, lines and offsets" {
  val a = "package P\nimport Std.String as Str\n\npub func a(): Int { 1 }\n"
  val b = "package P\nimport Std.Math\n\n\npub func b(): Int { 2 }\n"
  val r = PM.assemblePackageFiles("P", two(a, b), two("a.l", "b.l"), none(), none(), "dotnet")
  assertEqual(assembleSummary(r), "", "no diagnostics")
  assertEqualInt(r.file.items.count, 2, "both items")
  val ia = r.file.items[0].span.startPos
  val ib = r.file.items[1].span.startPos
  assertEqualInt(ia.fileId, 0, "a's item is file 0")
  assertEqualInt(ib.fileId, 1, "b's item is file 1")
  assertEqualInt(ia.line, 4, "a's item on a.l line 4")
  assertEqualInt(ib.line, 5, "b's item on b.l line 5")
  assertTrue(ib.offset >= a.length, "b's offsets follow a's")
  assertEqualInt(r.file.files[1].offsetBase, a.length + 1, "b's base")
  assertEqual(r.file.files[0].path, "a.l", "file 0's path")
  assertEqualInt(r.file.files[0].imports.count, 1, "a.l's own imports")
  assertEqual(modulePathJoin(r.file.files[1].imports[0].path.segments), "Std.Math", "b.l's own import")
  assertEqualInt(r.file.imports.count, 2, "the union of both")
}
