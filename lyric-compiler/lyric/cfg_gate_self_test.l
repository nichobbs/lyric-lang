// cfg_gate_self_test.l — exercises Lyric.CfgGate via the native
// `@test_module` test runner.
//
// Covers #1123 (comment-aware detection) and #1124 (single stub for
// multi-file directory packages where some or all files are gated out).
//
// Runs in CI via:
//
//   LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/cfg_gate_self_test.l
//
// (#1436 / CLAUDE.md no-new-F#-code policy: no `SelfHostedCfgGateTests.fs`
// runner — discovery is the native Lyric path mirroring `weaver_self_test.l`.)

@test_module
package Lyric.CfgGateSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.CfgGate

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func emptyFeatures(): List[String] { newList() }

func features1(a: in String): List[String] {
  val xs: List[String] = newList()
  xs.add(a)
  xs
}

func features2(a: in String, b: in String): List[String] {
  val xs: List[String] = newList()
  xs.add(a)
  xs.add(b)
  xs
}

// Concatenate sources the same way the test runner does (no separator —
// each file already ends with its own newline run).
func concatAll(xs: in List[String]): String {
  var s = ""
  var i = 0
  while i < xs.count {
    s = s + xs[i]
    i += 1
  }
  s
}

// Count the number of `package <name>` declarations anchored at the
// start of a physical line in a concatenated source.  Used to verify
// #1124's "exactly one declaration" invariant after the assembly step.
func countPackageDecls(src: in String, pkgName: in String): Int {
  val needle = "package " + pkgName
  var count = 0
  // Leading occurrence at offset 0.
  if src.length >= needle.length and src.substring(0, needle.length) == needle {
    count = count + 1
  }
  // Internal occurrences anchored at \n.
  var i = 0
  while i + needle.length < src.length {
    if src[i] == '\n' {
      val chunk = src.substring(i + 1, needle.length)
      if chunk == needle { count = count + 1 }
    }
    i = i + 1
  }
  count
}

func mkFile(p: in String, txt: in String): CfgGateFile {
  val f = CfgGateFile(path = p, contents = txt)
  f
}

// ---------------------------------------------------------------------------
// isCfgGatedOut — basic cases
// ---------------------------------------------------------------------------

test "isCfgGatedOut: no @cfg → not gated" {
  val src = "package Foo\n\nfunc main(): Unit {}\n"
  assertTrue(not isCfgGatedOut(src, emptyFeatures()),
    "no @cfg → not gated")
}

test "isCfgGatedOut: no `package` declaration → not gated" {
  // Not a top-level Lyric file we can gate.
  val src = "@cfg(feature = \"x\")\nfunc foo(): Unit {}\n"
  assertTrue(not isCfgGatedOut(src, emptyFeatures()),
    "no `package` declaration → not gated")
}

test "isCfgGatedOut: inactive feature → gated" {
  val src = "@cfg(feature = \"redis\")\npackage Foo\n\nfunc main(): Unit {}\n"
  assertTrue(isCfgGatedOut(src, emptyFeatures()),
    "inactive feature → gated")
}

test "isCfgGatedOut: active feature → not gated" {
  val src = "@cfg(feature = \"redis\")\npackage Foo\n\nfunc main(): Unit {}\n"
  assertTrue(not isCfgGatedOut(src, features1("redis")),
    "active feature → not gated")
}

test "isCfgGatedOut: @cfg after package → not whole-file gated" {
  // An @cfg annotation that appears AFTER the `package` declaration
  // gates only the item it precedes, not the whole file.
  val src = "package Foo\n\n@cfg(feature = \"redis\")\nfunc only(): Unit {}\n"
  assertTrue(not isCfgGatedOut(src, emptyFeatures()),
    "@cfg after package → not whole-file gated")
}

// ---------------------------------------------------------------------------
// #1123 — line comments containing @cfg must NOT trip the detector
// ---------------------------------------------------------------------------

test "isCfgGatedOut: @cfg in // line comment → not gated (#1123)" {
  // Reproduces the #1123 false positive: a line comment that mentions
  // `@cfg(feature = "x")` must not gate the package out.
  val src = "// this was @cfg(feature = \"x\") before we removed it\n" +
            "package Foo\n\nfunc main(): Unit {}\n"
  assertTrue(not isCfgGatedOut(src, emptyFeatures()),
    "@cfg in // line comment → not gated (#1123)")
}

test "isCfgGatedOut: @cfg in /// doc comment → not gated" {
  // Doc comments use `///` which still starts with `//`.
  val src = "/// example: @cfg(feature = \"x\") used to wrap this file\n" +
            "package Foo\n\nfunc main(): Unit {}\n"
  assertTrue(not isCfgGatedOut(src, emptyFeatures()),
    "@cfg in /// doc comment → not gated")
}

test "isCfgGatedOut: commented @cfg + real inactive @cfg → still gated" {
  // A commented-out @cfg followed by a real inactive @cfg: the real one
  // should still gate the file.
  val src = "// removed: @cfg(feature = \"old\")\n" +
            "@cfg(feature = \"new\")\n" +
            "package Foo\n"
  assertTrue(isCfgGatedOut(src, emptyFeatures()),
    "commented @cfg + real inactive @cfg → still gated by real one")
}

test "isCfgGatedOut: commented @cfg + real active @cfg → not gated" {
  val src = "// removed: @cfg(feature = \"old\")\n" +
            "@cfg(feature = \"redis\")\n" +
            "package Foo\n"
  assertTrue(not isCfgGatedOut(src, features1("redis")),
    "commented @cfg + real active @cfg → not gated")
}

test "isCfgGatedOut: active @cfgs followed by inactive @cfg → gated" {
  // Two active @cfgs first, then an inactive one. The scanner must keep
  // walking past the actives to find the inactive that actually gates.
  val src = "@cfg(feature = \"a\")\n" +
            "@cfg(feature = \"b\")\n" +
            "@cfg(feature = \"missing\")\n" +
            "package Foo\n"
  assertTrue(isCfgGatedOut(src, features2("a", "b")),
    "active @cfgs followed by inactive @cfg → gated")
}

// ---------------------------------------------------------------------------
// #1124 — directory assembly produces at most one `package` declaration
// ---------------------------------------------------------------------------

test "assembleDirectoryPackageSources: no gating → both sources kept" {
  val files: List[CfgGateFile] = newList()
  files.add(mkFile("a.l", "package Foo\nfunc a(): Unit {}\n"))
  files.add(mkFile("b.l", "package Foo\nfunc b(): Unit {}\n"))
  val asm = assembleDirectoryPackageSources(files, "Foo", emptyFeatures())
  assertEqualInt(asm.sources.count, 2, "no gating → both sources kept")
  assertEqualInt(asm.gatedFiles.count, 0, "no gating → no gated files reported")
  val merged = concatAll(asm.sources)
  assertEqualInt(countPackageDecls(merged, "Foo"), 2,
    "merged sources should carry both real `package Foo` declarations")
}

test "assembleDirectoryPackageSources: all-gated → exactly one stub" {
  // Both files in the directory are gated by the same inactive feature.
  // Old behaviour: emitted two `package Foo` stubs (the #1124 bug).
  // New behaviour: emits exactly ONE stub.
  val gated = "@cfg(feature = \"redis\")\npackage Foo\nfunc a(): Unit {}\n"
  val files: List[CfgGateFile] = newList()
  files.add(mkFile("a.l", gated))
  files.add(mkFile("b.l", gated))
  val asm = assembleDirectoryPackageSources(files, "Foo", emptyFeatures())
  assertEqualInt(asm.sources.count, 1, "all-gated → exactly one stub source")
  assertEqualInt(asm.gatedFiles.count, 2, "both files reported as gated")
  val merged = concatAll(asm.sources)
  assertEqualInt(countPackageDecls(merged, "Foo"), 1,
    "all-gated → exactly one `package Foo` declaration in the stub (#1124)")
}

test "assembleDirectoryPackageSources: partial-gated → no stub added" {
  // One gated, one kept: the kept file already carries its own
  // `package Foo` declaration, so no stub is needed.  Old behaviour
  // added a stub for the gated file producing TWO `package Foo`
  // declarations.  New behaviour skips the gated file entirely.
  val gated = "@cfg(feature = \"redis\")\npackage Foo\nfunc a(): Unit {}\n"
  val live  = "package Foo\nfunc b(): Unit {}\n"
  val files: List[CfgGateFile] = newList()
  files.add(mkFile("a.l", gated))
  files.add(mkFile("b.l", live))
  val asm = assembleDirectoryPackageSources(files, "Foo", emptyFeatures())
  assertEqualInt(asm.sources.count, 1, "partial-gated → only live source kept")
  assertEqualInt(asm.gatedFiles.count, 1, "one file reported as gated")
  assertEqual(asm.gatedFiles[0], "a.l", "gated file path is reported")
  val merged = concatAll(asm.sources)
  assertEqualInt(countPackageDecls(merged, "Foo"), 1,
    "partial-gated → exactly one `package Foo` declaration (#1124)")
}

test "assembleDirectoryPackageSources: 2 live + 1 gated → 2 decls" {
  // Three files: two live, one gated.  Both live files carry their own
  // `package Foo`; the assembler must produce two sources containing
  // two declarations total, never adding a stub for the gated entry.
  val gated = "@cfg(feature = \"redis\")\npackage Foo\nfunc a(): Unit {}\n"
  val liveB = "package Foo\nfunc b(): Unit {}\n"
  val liveC = "package Foo\nfunc c(): Unit {}\n"
  val files: List[CfgGateFile] = newList()
  files.add(mkFile("a.l", gated))
  files.add(mkFile("b.l", liveB))
  files.add(mkFile("c.l", liveC))
  val asm = assembleDirectoryPackageSources(files, "Foo", emptyFeatures())
  assertEqualInt(asm.sources.count, 2,
    "partial-gated (1 of 3) → two live sources kept, no stub")
  assertEqualInt(asm.gatedFiles.count, 1, "one file reported as gated")
  val merged = concatAll(asm.sources)
  assertEqualInt(countPackageDecls(merged, "Foo"), 2,
    "partial-gated → exactly the live `package Foo` declarations")
}

test "assembleDirectoryPackageSources: active feature → both files kept" {
  // A file gated by `redis` is kept when `redis` is active.
  val gated = "@cfg(feature = \"redis\")\npackage Foo\nfunc a(): Unit {}\n"
  val live  = "package Foo\nfunc b(): Unit {}\n"
  val files: List[CfgGateFile] = newList()
  files.add(mkFile("a.l", gated))
  files.add(mkFile("b.l", live))
  val asm = assembleDirectoryPackageSources(files, "Foo", features1("redis"))
  assertEqualInt(asm.sources.count, 2, "active feature → both files kept")
  assertEqualInt(asm.gatedFiles.count, 0, "no files gated when feature active")
}

test "assembleDirectoryPackageSources: empty input → no sources, no stub" {
  val files: List[CfgGateFile] = newList()
  val asm = assembleDirectoryPackageSources(files, "Foo", emptyFeatures())
  assertEqualInt(asm.sources.count, 0,
    "no input files → no sources and no stub (caller is expected to error earlier)")
  assertEqualInt(asm.gatedFiles.count, 0, "no input → no gated files")
}
