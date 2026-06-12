//! release_self_test.l — exercises the pure helpers of Lyric.Release
//! (entry-point/package detection) via the native `@test_module` runner.
//!
//! These cover the source-introspection that picks the AOT trampoline's entry
//! type.  The toolchain-driving parts of Lyric.Release (dotnet publish, file
//! staging) are integration-tested by the "release e2e" CI step against the
//! real binary — they can't run through `lyric test` (host-backed stdlib at
//! runtime, #2001).
//!
//! Runs in CI via:
//!
//!   lyric test lyric-compiler/lyric/release_self_test.l
@test_module
package Lyric.ReleaseSelfTest

import Std.Core
import Std.Collections
import Std.String as Str
import Std.Testing
import Lyric.Release as Release

// ── packageNameOf ────────────────────────────────────────────────────────────
test "packageNameOf: simple package declaration" {
  assertEqual(Release.packageNameOf("package Demo\nimport Std.Core\n"), "Demo", "first package line")
}

test "packageNameOf: dotted package name" {
  assertEqual(
    Release.packageNameOf("// header\npackage My.App.Server\n"),
    "My.App.Server",
    "dotted name, after a comment line"
  )
}

test "packageNameOf: no package declaration → empty" {
  assertEqual(Release.packageNameOf("import Std.Core\nfunc main(): Int { 0 }\n"), "", "no package line")
}

// ── declaresEntryMain ────────────────────────────────────────────────────────
test "declaresEntryMain: zero-arg main is an entry" {
  assertTrue(Release.declaresEntryMain("package P\npub func main(): Int { 0 }\n"), "pub func main()")
  assertTrue(Release.declaresEntryMain("func main(): Int { 0 }\n"), "func main()")
}

test "declaresEntryMain: main with parameters is not an entry" {
  assertTrue(
    not Release.declaresEntryMain("func main(argv: in slice[String]): Int { 0 }\n"),
    "main(argv) is not the emitter's entry form"
  )
}

test "declaresEntryMain: no main → false" {
  assertTrue(not Release.declaresEntryMain("func helper(): Int { 0 }\n"), "no main")
}

test "declaresEntryMain: function whose name starts with 'main' but is not main()" {
  assertTrue(not Release.declaresEntryMain("func mainHelper(): Int { 0 }\n"), "mainHelper is not the entry form")
  assertTrue(
    not Release.declaresEntryMain("func maintaining(x: in Int): Int { x }\n"),
    "maintaining is not the entry form"
  )
}

test "packageNameOf: inline comment stripped from package line" {
  assertEqual(Release.packageNameOf("package Demo // entry point\n"), "Demo", "inline comment stripped")
}

test "declaresEntryMain: func main() inside a triple-quoted string is not an entry (#3215)" {
  val src = "package P\nval readme = \"\"\"\nfunc main()\n\"\"\"\n"
  assertTrue(not Release.declaresEntryMain(src), "func main() inside a triple-quoted literal is documentation")
}

test "declaresEntryMain: real main after a closed triple-quoted string is an entry (#3215)" {
  val src = "package P\nval readme = \"\"\"\ndocs only\n\"\"\"\nfunc main(): Int { 0 }\n"
  assertTrue(Release.declaresEntryMain(src), "real func main() after a closed triple-quoted literal")
}

test "declaresEntryMain: single-line triple-quoted literal does not flip state (#3215)" {
  val src = "package P\nval s = \"\"\"func main()\"\"\"\nfunc main(): Int { 0 }\n"
  assertTrue(Release.declaresEntryMain(src), "balanced same-line triple quotes leave the scan in code")
}

test "declaresEntryMain: triple-quotes inside a line comment do not flip state (#3248)" {
  val src = "package P\n// example: \"\"\"\nfunc main(): Int { 0 }\n"
  assertTrue(Release.declaresEntryMain(src), "func main() after a comment containing triple quotes is still detected")
}

test "declaresEntryMain: comment markers inside a triple-quoted string stay literal (#3248)" {
  val src = "package P\nval s = \"\"\"\n// not a comment: \"\"\"\nfunc main(): Int { 0 }\n"
  assertTrue(Release.declaresEntryMain(src), "a // inside a triple-quoted literal does not stop the close scan")
}

// ── localDepNotBuiltMessage (#3216) ──────────────────────────────────────────
test "localDepNotBuiltMessage names the probed DLL path and the --out caveat (#3216)" {
  val m = Release.localDepNotBuiltMessage("util", "/proj/util/bin/Util.dll", "/proj/util/lyric.toml")
  assertTrue(Str.contains(m, "'util'"), "dep name present")
  assertTrue(Str.contains(m, "/proj/util/bin/Util.dll"), "probed DLL path present")
  assertTrue(Str.contains(m, "lyric build --manifest /proj/util/lyric.toml"), "rebuild command present")
  assertTrue(Str.contains(m, "--out"), "custom --out caveat present")
}
