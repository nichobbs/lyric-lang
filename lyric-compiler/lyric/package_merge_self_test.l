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
import Lyric.PackageMerge as PM

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
  PM.mergePackageFiles("P", two(a, b), two("a.l", "b.l"), none(), none())
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
  val expected = "@runtime_checked\npackage P\nimport Std.Core\nimport Std.String as Str\n" +
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
  val r = PM.mergePackageFiles("P", srcs, paths, none(), none())
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
  val off = PM.mergePackageFiles("P", two(a, b), two("a.l", "b.l"), none(), declared)
  assertEqual(diagSummary(off), "", "no diagnostics")
  assertEqualInt(itemCount(off.source), 1, "b's item is gone")
  assertTrue(not Str.contains(off.source, "Std.Math"), "and so is its import")
  assertTrue(Str.startsWith(off.source, "@proof_required\npackage P\n"), "its annotation still describes the package")
  val on = PM.mergePackageFiles("P", two(a, b), two("a.l", "b.l"), declared, declared)
  assertEqualInt(itemCount(on.source), 2, "with the feature on, both items")
  assertTrue(not Str.contains(on.source, "@cfg"), "a file-level @cfg is per file, never the package's")
}

test "a malformed or undeclared file-level @cfg is F0012 or F0013" {
  val a = "package P\n\npub func f(): Int { 1 }\n"
  val bad = "@cfg(feture = \"x\")\npackage P\n\npub func g(): Int { 2 }\n"
  val declared: List[String] = newList()
  declared.add("extra")
  val r1 = PM.mergePackageFiles("P", two(a, bad), two("a.l", "b.l"), none(), declared)
  assertEqual(diagSummary(r1), "b.l:F0012:1", "malformed")
  val typo = "@cfg(feature = \"exrta\")\npackage P\n\npub func g(): Int { 2 }\n"
  val r2 = PM.mergePackageFiles("P", two(a, typo), two("a.l", "b.l"), none(), declared)
  assertEqual(diagSummary(r2), "b.l:F0013:1", "undeclared feature")
  assertTrue(not PM.mergeHasErrors(r2), "F0013 is a warning")
}

test "a package of one file is returned as written" {
  val only: List[String] = newList()
  only.add("// as written\npackage P\nimport Std.Core\n")
  val paths: List[String] = newList()
  paths.add("a.l")
  val r = PM.mergePackageFiles("P", only, paths, none(), none())
  assertEqual(r.source, "// as written\npackage P\nimport Std.Core\n", "verbatim")
  assertEqualInt(r.origins.count, 0, "no origins")
}

test "a discovered package of one file is rebuilt in the merged shape" {
  val only: List[String] = newList()
  only.add("//! doc\n@io\npackage Std.X\n\nimport Std.Core\n\npub func f(): Int { 1 }\n")
  val paths: List[String] = newList()
  paths.add("x.l")
  val r = PM.mergeDiscoveredPackage("Std.X", only, paths)
  assertEqual(r.source, "@io\npackage Std.X\nimport Std.Core\n\n\npub func f(): Int { 1 }\n", "rebuilt")
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
