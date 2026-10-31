//! package_merge_self_test.l — assembling a multi-file package from its
//! separately parsed files (`Lyric.PackageMerge.assemblePackageFiles`,
//! docs/19 §4, docs/70 §4.1, #8234).
//!
//! An assembled package is exactly the union of its files' own parses: every
//! position names its file (`Position.fileId`) and keeps that file's own line
//! and column, a comment in a file's header stays a comment, a file that does
//! not parse or that declares another package is reported against its own
//! path and line, and the files' file-level annotations are united (and must
//! agree).
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
import Lyric.Parser.{Item, IFunc, IRecord, SourceFile, modulePathJoin}
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

func asm(a: in String, b: in String): PM.PackageAssembly {
  asmFor(a, b, "dotnet")
}

func asmFor(a: in String, b: in String, target: in String): PM.PackageAssembly {
  PM.assemblePackageFiles("P", two(a, b), two("a.l", "b.l"), none(), none(), target)
}

func asmFiles(srcs: in List[String], paths: in List[String], target: in String): PM.PackageAssembly {
  PM.assemblePackageFiles("P", srcs, paths, none(), none(), target)
}

// Every diagnostic as `path:CODE:line`, comma-separated, for exact checks.
func diagSummary(r: in PM.PackageAssembly): String {
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

// Each item as `name@file:line`.
func itemPlaces(items: in List[Item]): String {
  val names: List[String] = newList()
  for it in items {
    val at = "@" + toString(it.span.startPos.fileId) + ":" + toString(it.span.startPos.line)
    match it.kind {
      case IFunc(fd) -> names.add(fd.name + at)
      case IRecord(rd) -> names.add(rd.name + at)
      case _ -> names.add("?" + at)
    }
  }
  Str.joinList(",", names)
}

// The package's imports as `path` or `path as alias`, comma-separated.
func importNames(file: in SourceFile): String {
  val names: List[String] = newList()
  for imp in file.imports {
    val p = modulePathJoin(imp.path.segments)
    names.add(match imp.asAlias { case Some(al) -> p + " as " + al; case None -> p })
  }
  Str.joinList(",", names)
}

// The package's file-level annotations by name, comma-separated.
func annotationNames(file: in SourceFile): String {
  val names: List[String] = newList()
  for a in file.fileAnnotations {
    names.add(modulePathJoin(a.name.segments))
  }
  Str.joinList(",", names)
}

test "two well-formed files assemble to their header union and their items, each at its own line" {
  val a = "//! A doc\n@runtime_checked\npackage P\n\nimport Std.Core\nimport Std.String as Str\n\n// helper\npub func a(): Int { 1 }\n"
  val b = "// B header comment\n@runtime_checked\npackage P\nimport Std.Core\n\npub func b(): Int { 2 }\n"
  val r = asm(a, b)
  assertEqual(diagSummary(r), "", "no diagnostics")
  assertEqual(itemPlaces(r.file.items), "a@0:9,b@1:6", "each item in its own file, at its own line")
  assertEqual(importNames(r.file), "Std.Core,Std.String as Str", "the imports, the one both write once")
  assertEqual(annotationNames(r.file), "runtime_checked", "the annotation both write once")
  assertEqualInt(r.file.fileAnnotations[0].span.startPos.fileId, 0, "the first file's annotation")
  assertEqualInt(r.file.moduleDoc.count, 1, "a's module doc")
  assertEqual(modulePathJoin(r.file.packageDecl.path.segments), "P", "the package")
  assertEqualInt(r.file.files.count, 2, "one header per file")
  assertEqual(r.file.files[1].path, "b.l", "file 1's path")
  assertEqualInt(r.file.files[1].imports.count, 1, "b.l's own import")
  assertEqual(Str.joinList("|", PM.packageFilePaths(r.file)), "a.l|b.l", "the file table")
}

test "every file's module docs reach the package, in file order" {
  val a = "//! First file.\n//!\n//! More of the first.\n@runtime_checked\npackage P\n\npub func a(): Int { 1 }\n"
  val b = "//! Second file.\n@runtime_checked\npackage P\n\npub func b(): Int { 2 }\n"
  val r = asm(a, b)
  assertEqual(diagSummary(r), "", "no diagnostics")
  assertEqualInt(r.file.moduleDoc.count, 4, "three lines of a's, one of b's")
  assertTrue(Str.contains(r.file.moduleDoc[3].text, "Second file."), r.file.moduleDoc[3].text)
  assertEqualInt(r.file.moduleDoc[3].span.startPos.fileId, 1, "b's doc names b")
  assertEqualInt(r.file.moduleDoc[3].span.startPos.line, 1, "at b's own line")
}

test "module docs keep non-ASCII text, and CRLF files get bases from their normalised length" {
  val a = "//! Résumé ✓ 😀 done\r\n//! after\r\n@runtime_checked\r\npackage P\r\n\r\npub func a(): Int { 1 }\r\n"
  val b = "//! Zweite Datei: ñ\r\npackage P\r\npub func b(): Int { 2 }\r\n"
  val r = asm(a, b)
  assertEqual(diagSummary(r), "", "no diagnostics")
  assertEqual(itemPlaces(r.file.items), "a@0:6,b@1:3", "both functions, at their own lines")
  assertEqualInt(r.file.moduleDoc.count, 3, "three doc lines")
  assertTrue(Str.contains(r.file.moduleDoc[0].text, "Résumé ✓ 😀 done"), r.file.moduleDoc[0].text)
  assertTrue(Str.contains(r.file.moduleDoc[2].text, "Zweite Datei: ñ"), r.file.moduleDoc[2].text)
  val normalisedA = a.replace("\r\n", "\n")
  assertEqualInt(r.file.files[1].offsetBase, normalisedA.length + 1, "b's base counts no \\r")
}

test "fileOffsetBases puts each file one past the normalised end of the one before" {
  val srcs = two("ab\r\nc", "x")
  srcs.add("")
  srcs.add("yz")
  val bases = Parser.fileOffsetBases(srcs)
  assertEqualInt(bases.count, 4, "one base per file")
  assertEqualInt(bases[0], 0, "the first file starts at 0")
  assertEqualInt(bases[1], 5, "\"ab\\nc\" is 4 long, plus the gap")
  assertEqualInt(bases[2], 7, "\"x\" is 1 long, plus the gap")
  assertEqualInt(bases[3], 8, "an empty file still takes the gap")
}

test "a file with no module doc adds none, and a gated-out file contributes no doc" {
  val a = "package P\n\npub func a(): Int { 1 }\n"
  val b = "//! Only b.\npackage P\n\npub func b(): Int { 2 }\n"
  val r = asm(a, b)
  assertEqualInt(r.file.moduleDoc.count, 1, "b's doc only")
  val g = "//! Gated.\n@cfg(target = \"jvm\")\npackage P\n\npub func g(): Int { 3 }\n"
  val r2 = asmFor(g, b, "dotnet")
  assertEqual(diagSummary(r2), "", "no diagnostics")
  assertEqualInt(r2.file.moduleDoc.count, 1, "a gated-out file's docs are not carried")
  assertTrue(Str.contains(r2.file.moduleDoc[0].text, "Only b."), r2.file.moduleDoc[0].text)
  assertEqual(itemNames(r2.file.items), "b", "nor its items")
  assertEqualInt(r2.file.files[0].moduleDoc.count, 1, "its own header keeps its doc")
}

test "a block comment that an annotation line opens and closes stays a comment" {
  // #8234's `trick_hid2`: both `@runtime_checked` lines carry a comment
  // delimiter; the declarations between them are commented out.
  val a = "@runtime_checked\npackage P\n\npub func f(): Bool { true }\n"
  val b = "@runtime_checked /*\npub union Option[T] {\n  case Some(value: T)\n  case Other\n}\n@runtime_checked */\npackage P\n\npub record Filler {\n  n: Int\n}\n"
  val r = asm(a, b)
  assertEqual(diagSummary(r), "", "no diagnostics")
  assertEqual(itemPlaces(r.file.items), "f@0:4,Filler@1:9", "only `f` and `Filler`: the union stays commented out")
}

test "files that disagree on the verification level are B0014" {
  val a = "@proof_required\npackage P\n\npub func f(): Bool { true }\n"
  val b = "@runtime_checked\npackage P\n\npub func g(): Bool { true }\n"
  val r = asm(a, b)
  assertEqual(diagSummary(r), "b.l:B0014:1", "B0014 on b.l's annotation")
  assertTrue(PM.assemblyHasErrors(r), "an error")
  assertTrue(Str.contains(r.diagnostics[0].diag.message, "a.l:1 is @proof_required"), r.diagnostics[0].diag.message)
  assertEqualInt(r.diagnostics[0].diag.span.startPos.fileId, 1, "the diagnostic's position names b.l")
}

test "a file that declares another package is B0013" {
  val a = "package P\n\npub func f(): Int { 1 }\n"
  val b = "//! elsewhere\n\npackage Elsewhere\n\npub func g(): Int { 2 }\n"
  val r = asm(a, b)
  assertEqual(diagSummary(r), "b.l:B0013:3", "B0013 at b.l's package line")
  assertTrue(Str.contains(r.diagnostics[0].diag.message, "declares package Elsewhere"), r.diagnostics[0].diag.message)
  assertEqualInt(r.diagnostics[0].diag.span.startPos.fileId, 1, "the diagnostic's position names b.l")
}

test "a file that does not parse is reported against its own path and line" {
  // #8234's `otherpkg`: a broken annotation, and another package.
  val a = "@proof_required\npackage P\n\npub func f(): Int { 1 }\n"
  val b = "@runtime_checked(((\npackage Elsewhere\n\npub func g(): Int { 2 }\n"
  val r = asm(a, b)
  assertTrue(PM.assemblyHasErrors(r), "an error")
  for d in r.diagnostics {
    assertEqual(d.path, "b.l", "every diagnostic is b.l's: " + diagSummary(r))
    assertEqualInt(d.diag.span.startPos.fileId, 1, "and its position names b.l: " + diagSummary(r))
  }
  assertTrue(Str.startsWith(r.diagnostics[0].diag.code, "P"), "a parse diagnostic first: " + diagSummary(r))
  assertTrue(Str.contains(diagSummary(r), "b.l:B0013:2"), "and the package it names is not P: " + diagSummary(r))
}

test "a file without a package declaration is P0020" {
  val a = "package P\n\npub func f(): Int { 1 }\n"
  val b = "// no header\npub func g(): Int { 2 }\n"
  val r = asm(a, b)
  assertEqual(diagSummary(r), "b.l:P0020:2", "P0020 where b.l's package declaration belongs")
}

test "a file of comments only adds no item" {
  val a = "package P\n\npub func f(): Int { 1 }\n"
  val b = "// notes for the package\n/* more */\n"
  val r = asm(a, b)
  assertEqual(diagSummary(r), "", "no diagnostics")
  assertEqual(itemNames(r.file.items), "f", "one item")
  assertEqualInt(r.file.files.count, 2, "both files have a header")
}

test "header text inside a comment is not header" {
  val a = "/* package Fake\nimport Not.Real\n@proof_required\n*/\npackage P\n// import Also.Not\nimport Std.Core // why\n\npub func f(): Int { 1 }\n"
  val b = "package P\n\npub func g(): Int { 2 }\n"
  val r = asm(a, b)
  assertEqual(diagSummary(r), "", "no diagnostics")
  assertEqual(itemPlaces(r.file.items), "f@0:9,g@1:3", "two items")
  assertEqual(importNames(r.file), "Std.Core", "only the real import")
  assertEqual(annotationNames(r.file), "", "and no annotation")
}

test "file-level annotations are united and kept once, from the file that first writes them" {
  val a = "package P\n\npub func f(): Int { 1 }\n"
  val b = "@runtime_checked @io\npackage P\n\npub func g(): Int { 2 }\n"
  val c = "@io\npackage P\n\npub func h(): Int { 3 }\n"
  val srcs = two(a, b)
  srcs.add(c)
  val paths = two("a.l", "b.l")
  paths.add("c.l")
  val r = asmFiles(srcs, paths, "dotnet")
  assertEqual(diagSummary(r), "", "no diagnostics")
  assertEqual(annotationNames(r.file), "runtime_checked,io", "b's annotations, c's @io once")
  assertEqualInt(r.file.fileAnnotations[1].span.startPos.fileId, 1, "the @io kept is b's")
  assertEqualInt(r.file.files[2].fileAnnotations.count, 1, "c's header keeps its own")
}

test "an annotation written two ways is B0014, @pure against @io is Y0009" {
  val a = "@proof_required\npackage P\n\npub func f(): Int { 1 }\n"
  val b = "@proof_required(unsafe_blocks_allowed)\npackage P\n\npub func g(): Int { 2 }\n"
  assertEqual(diagSummary(asm(a, b)), "b.l:B0014:1", "same annotation, other arguments")
  val c = "@pure\npackage P\n\npub func f(): Int { 1 }\n"
  val d = "@io\npackage P\n\npub func g(): Int { 2 }\n"
  assertEqual(diagSummary(asm(c, d)), "b.l:Y0009:1", "a package is @pure or @io")
}

test "a file whose file-level @cfg is off contributes no item or import" {
  val a = "package P\n\npub func pick(): Int { 1 }\n"
  val b = "@cfg(feature = \"extra\")\n@proof_required\npackage P\nimport Std.Math\n\npub func pick(): Int { 999 }\n"
  val declared: List[String] = newList()
  declared.add("extra")
  val off = PM.assemblePackageFiles("P", two(a, b), two("a.l", "b.l"), none(), declared, "dotnet")
  assertEqual(diagSummary(off), "", "no diagnostics")
  assertEqual(itemPlaces(off.file.items), "pick@0:3", "b's item is gone")
  assertEqual(importNames(off.file), "", "and so is its import")
  assertEqual(annotationNames(off.file), "proof_required", "its annotation still describes the package")
  val on = PM.assemblePackageFiles("P", two(a, b), two("a.l", "b.l"), declared, declared, "dotnet")
  assertEqual(itemPlaces(on.file.items), "pick@0:3,pick@1:6", "with the feature on, both items")
  assertEqual(importNames(on.file), "Std.Math", "and b's import")
  assertEqual(annotationNames(on.file), "proof_required", "a file-level @cfg is per file, never the package's")
}

test "a malformed or undeclared file-level @cfg is F0012 or F0013" {
  val a = "package P\n\npub func f(): Int { 1 }\n"
  val bad = "@cfg(feture = \"x\")\npackage P\n\npub func g(): Int { 2 }\n"
  val declared: List[String] = newList()
  declared.add("extra")
  val r1 = PM.assemblePackageFiles("P", two(a, bad), two("a.l", "b.l"), none(), declared, "dotnet")
  assertEqual(diagSummary(r1), "b.l:F0012:1", "malformed")
  val typo = "@cfg(feature = \"exrta\")\npackage P\n\npub func g(): Int { 2 }\n"
  val r2 = PM.assemblePackageFiles("P", two(a, typo), two("a.l", "b.l"), none(), declared, "dotnet")
  assertEqual(diagSummary(r2), "b.l:F0013:1", "undeclared feature")
  assertTrue(not PM.assemblyHasErrors(r2), "F0013 is a warning")
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
  val dn = asmFiles(srcs, paths, "dotnet")
  assertEqual(diagSummary(dn), "", "dotnet assembles")
  assertEqual(itemPlaces(dn.file.items), "main@0:3,which@2:3", "dotnet keeps c.l")
  assertEqual(itemPlaces(asmFiles(srcs, paths, "jvm").file.items), "main@0:3,which@1:3", "jvm keeps b.l")
  assertEqual(itemNames(asmFiles(srcs, paths, "native").file.items), "main", "native keeps neither")
}

test "every file of a package gated off leaves an empty package" {
  // #1124: the package still exists, with one `package` declaration.
  val a = "@cfg(feature = \"redis\")\npackage P\nimport Std.Core\npub func a(): Int { 1 }\n"
  val b = "@cfg(feature = \"redis\")\n@io\npackage P\npub func b(): Int { 2 }\n"
  val r = asm(a, b)
  assertEqual(diagSummary(r), "", "no diagnostics")
  assertEqualInt(r.file.items.count, 0, "no items")
  assertEqual(importNames(r.file), "", "no imports")
  assertEqual(modulePathJoin(r.file.packageDecl.path.segments), "P", "one package declaration")
  assertEqual(annotationNames(r.file), "io", "the package's annotation")
}

test "an import alias two files bind to different packages is B0012" {
  // Review repro r1: the files of a package share one import scope until
  // per-file scopes land (docs/70 §4.1).
  val a = "package P\nimport Std.String as X\n\nfunc main(): Unit { }\n"
  val b = "package P\nimport Std.Math as X\n\nfunc other(): Int { 1 }\n"
  val r = asm(a, b)
  assertEqual(diagSummary(r), "b.l:B0012:2", "B0012 on b.l's import")
  assertTrue(
    Str.contains(r.diagnostics[0].diag.message, "names Std.Math here but Std.String at a.l:2"),
    r.diagnostics[0].diag.message
  )
  assertEqualInt(r.diagnostics[0].diag.span.startPos.fileId, 1, "the diagnostic's position names b.l")
  assertEqual(itemPlaces(r.file.items), "main@0:4,other@1:4", "both files' items")
  assertEqual(importNames(r.file), "Std.String as X", "the package binds X once, to a.l's package")
  assertEqualInt(r.file.files.count, 2, "both headers")
  assertEqual(modulePathJoin(r.file.files[1].imports[0].path.segments), "Std.Math", "b.l's header keeps its own")
  val same = asm(a, "package P\nimport Std.String as X\n\nfunc other(): Int { 1 }\n")
  assertEqual(diagSummary(same), "", "the same alias for the same package is one import")
  assertEqual(importNames(same.file), "Std.String as X", "kept once")
}

test "a unit-mode annotation only some files carry is B0014" {
  // Review repro r5: `@contract_source` would make `{ 42 }` a block in b.l.
  val a = "@contract_source\npackage P\n\nfunc f(): Int { 1 }\n"
  val b = "package P\nfunc main(): Unit {\n  val g = { 42 }\n  println(toString(g()))\n}\n"
  val r = asm(a, b)
  assertEqual(diagSummary(r), "b.l:B0014:1", "b.l is not @contract_source")
  assertTrue(Str.contains(r.diagnostics[0].diag.message, "@contract_source"), r.diagnostics[0].diag.message)
  val t = asm("@test_module\npackage P\n", "package P\npub func h(): Int { 1 }\n")
  assertEqual(diagSummary(t), "b.l:B0014:1", "@test_module on one file only")
  val both = asm("@test_module\npackage P\n", "@test_module\npackage P\npub func h(): Int { 1 }\n")
  assertEqual(diagSummary(both), "", "on every file, it is the package's")
}

test "annotations or imports with no package declaration are P0020" {
  // Review repro r4.
  val a = "package P\n\nfunc main(): Unit { }\n"
  val annOnly = asm(a, "// stray\n@axiom\n")
  assertEqual(diagSummary(annOnly), "b.l:P0020:2", "annotation only")
  assertEqual(itemPlaces(annOnly.file.items), "main@0:3", "a.l's item")
  assertEqual(annotationNames(annOnly.file), "", "b.l's annotation is not the package's")
  assertEqualInt(annOnly.file.files.count, 2, "both headers")
  assertEqualInt(annOnly.file.files[1].packageDecl.path.segments.count, 0, "b.l declares no package")
  assertEqualInt(annOnly.file.files[1].fileAnnotations.count, 1, "b.l's header keeps its annotation")
  val impOnly = asm(a, "import Std.Core\n")
  assertEqual(diagSummary(impOnly), "b.l:P0020:1", "import only")
  assertEqual(importNames(impOnly.file), "", "b.l's import is not the package's")
  assertEqualInt(impOnly.file.files[1].imports.count, 1, "b.l's header keeps its import")
}

test "CRLF files and one-line headers keep their lines and columns" {
  val a = "@runtime_checked\r\npackage P\r\nimport Std.Core\r\n\r\nfunc main(): Unit {\r\n  println(toString(two()))\r\n}\r\n"
  val b = "package P; import Std.Core; func two(): Int { 2 }\n"
  val c = "/* hdr\n*/ @runtime_checked /* x\n y */ package P /*\n*/ import Std.Core /* q\n */ func three(): Int {\n\t3\n}\n"
  val srcs = two(a, b)
  srcs.add(c)
  val paths = two("a.l", "b.l")
  paths.add("c.l")
  val r = asmFiles(srcs, paths, "dotnet")
  assertEqual(diagSummary(r), "", "no diagnostics")
  assertEqual(itemPlaces(r.file.items), "main@0:5,two@1:1,three@2:5", "three items, at their own lines")
  assertEqualInt(r.file.items[1].span.startPos.column, 29, "b.l's item at its own column")
  assertEqual(importNames(r.file), "Std.Core", "one import")
}

test "a package of one file that declares another package is B0013" {
  // Review repro r9.
  val only: List[String] = newList()
  only.add("//! doc\npackage Elsewhere\nfunc main(): Unit { }\n")
  val paths: List[String] = newList()
  paths.add("a.l")
  val r = PM.assemblePackageFiles("P", only, paths, none(), none(), "dotnet")
  assertEqual(diagSummary(r), "a.l:B0013:2", "B0013 at the package name")
}

test "a package of one file is its own parse" {
  val src = "//! doc\n@io\npackage P\n\nimport Std.Core\n\npub func f(): Int { 1 }\nrecord R {\n  n: Int\n}\n"
  val only: List[String] = newList()
  only.add(src)
  val paths: List[String] = newList()
  paths.add("a.l")
  val r = PM.assemblePackageFiles("P", only, paths, none(), none(), "dotnet")
  val parsed = Parser.parse(src).file
  assertEqual(diagSummary(r), "", "no diagnostics")
  assertEqual(itemPlaces(r.file.items), itemPlaces(parsed.items), "the parse's items")
  assertEqual(importNames(r.file), importNames(parsed), "its imports")
  assertEqual(annotationNames(r.file), annotationNames(parsed), "its annotations")
  assertEqualInt(r.file.items[0].span.startPos.offset, parsed.items[0].span.startPos.offset, "at base 0")
  assertEqualInt(r.file.files[0].offsetBase, 0, "file 0's base")
}

test "a one-file package whose file-level @cfg is off keeps its annotations but no item or import" {
  val src = "@cfg(feature = \"extra\")\n@io\npackage P\nimport Std.Math\n\npub func f(): Int { 1 }\n"
  val only: List[String] = newList()
  only.add(src)
  val paths: List[String] = newList()
  paths.add("a.l")
  val declared: List[String] = newList()
  declared.add("extra")
  val off = PM.assemblePackageFiles("P", only, paths, none(), declared, "dotnet")
  assertEqual(diagSummary(off), "", "no diagnostics")
  assertEqual(itemPlaces(off.file.items), "", "no item")
  assertEqual(importNames(off.file), "", "no import, as for a gated-off file of a larger package")
  assertEqual(annotationNames(off.file), "io", "its annotation still describes the package")
  assertEqualInt(off.file.files.count, 1, "its header is kept")
  val on = PM.assemblePackageFiles("P", only, paths, declared, declared, "dotnet")
  assertEqual(importNames(on.file), "Std.Math", "with the feature on, its import")
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

test "a one-file package named from its own source is not held to a name" {
  // Review repro sf: a single-file build names its package from the source.
  val only: List[String] = newList()
  only.add("/*\npackage Old\n*/\npackage Mf\nfunc main(): Unit { }\n")
  val paths: List[String] = newList()
  paths.add("a.l")
  val r = PM.assemblePackageFiles("", only, paths, none(), none(), "dotnet")
  assertEqual(diagSummary(r), "", "no B0013")
  assertEqual(modulePathJoin(r.file.packageDecl.path.segments), "Mf", "the package it declares")
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

test "each file of an assembled package keeps its own header, lines and offsets" {
  val a = "package P\nimport Std.String as Str\n\npub func a(): Int { 1 }\n"
  val b = "package P\nimport Std.Math\n\n\npub func b(): Int { 2 }\n"
  val r = PM.assemblePackageFiles("P", two(a, b), two("a.l", "b.l"), none(), none(), "dotnet")
  assertEqual(diagSummary(r), "", "no diagnostics")
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
