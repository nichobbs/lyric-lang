//! release_self_test.l — exercises the pure helpers of Lyric.Release
//! (entry-point/package detection) via the native `@test_module` runner.
//!
//! These cover the source-introspection used to detect entry packages and
//! validate release builds.  The toolchain-driving parts of Lyric.Release
//! (ilc + clang invocation, ILC probe restore, file staging) are
//! integration-tested by the "release e2e" CI step against the real binary —
//! they can't run through `lyric test` (host-backed stdlib at runtime, #2001).
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

// ── ridOs / ridArch ──────────────────────────────────────────────────────────
test "ridOs: extracts OS component from standard RIDs" {
  assertEqual(Release.ridOs("linux-x64"), "linux", "linux-x64")
  assertEqual(Release.ridOs("linux-arm64"), "linux", "linux-arm64")
  assertEqual(Release.ridOs("osx-arm64"), "osx", "osx-arm64 stays 'osx'")
  assertEqual(Release.ridOs("win-x64"), "windows", "win-x64 maps to 'windows'")
}

test "ridArch: extracts arch component from standard RIDs" {
  assertEqual(Release.ridArch("linux-x64"), "x64", "linux-x64")
  assertEqual(Release.ridArch("linux-arm64"), "arm64", "linux-arm64")
  assertEqual(Release.ridArch("osx-x64"), "x64", "osx-x64")
  assertEqual(Release.ridArch("linux-musl-x64"), "x64", "linux-musl-x64 (Alpine) uses last segment")
  assertEqual(Release.ridArch("linux-musl-arm64"), "arm64", "linux-musl-arm64 uses last segment")
}

// ── semverMajor ──────────────────────────────────────────────────────────────
test "semverMajor: extracts the leading integer from a version string" {
  assertTrue(Release.semverMajor("10.0.7") == 10, "10.0.7 → 10")
  assertTrue(Release.semverMajor("8.0.0") == 8, "8.0.0 → 8")
  assertTrue(Release.semverMajor("9.0.3-preview.1") == 9, "9.0.3-preview.1 → 9")
  assertTrue(Release.semverMajor("nope") == 0, "non-numeric returns 0")
}

// ── isValidRid ───────────────────────────────────────────────────────────────
test "isValidRid: accepts well-formed .NET RIDs" {
  assertTrue(Release.isValidRid("linux-x64"), "linux-x64")
  assertTrue(Release.isValidRid("linux-arm64"), "linux-arm64")
  assertTrue(Release.isValidRid("osx-x64"), "osx-x64")
  assertTrue(Release.isValidRid("win-x64"), "win-x64")
  assertTrue(Release.isValidRid("linux-musl-x64"), "linux-musl-x64 (Alpine)")
}

test "isValidRid: rejects invalid or dangerous RID strings" {
  assertTrue(not Release.isValidRid(""), "empty string")
  assertTrue(not Release.isValidRid("Linux-X64"), "uppercase letters rejected")
  assertTrue(not Release.isValidRid("linux-x64<"), "XML < metacharacter rejected")
  assertTrue(not Release.isValidRid("linux-x64>tag"), "XML > metacharacter rejected")
  assertTrue(not Release.isValidRid("linux-x64&amp;"), "XML & metacharacter rejected")
  assertTrue(not Release.isValidRid("linux x64"), "space rejected")
}

// ── jsonStringField ──────────────────────────────────────────────────────────
test "jsonStringField: extracts a root-level string value" {
  val json = "{\"packagesPath\": \"/home/user/.nuget/packages\", \"version\": 3}"
  assertEqual(
    unwrapOr(Release.jsonStringField(json, "packagesPath"), ""),
    "/home/user/.nuget/packages",
    "root-level key"
  )
}

test "jsonStringField: returns None when key is absent" {
  val json = "{\"other\": \"value\"}"
  assertTrue(
    match Release.jsonStringField(json, "packagesPath") { case None -> true; case Some(_) -> false },
    "missing key"
  )
}

test "jsonStringField: finds key nested inside an object (project.assets.json shape)" {
  val json = "{\n  \"version\": 3,\n  \"project\": {\n    \"restore\": {\n      \"packagesPath\": \"/root/.nuget/packages\"\n    }\n  }\n}"
  assertEqual(
    unwrapOr(Release.jsonStringField(json, "packagesPath"), ""),
    "/root/.nuget/packages",
    "nested packagesPath"
  )
}

test "jsonStringField: handles backslash-escaped backslashes in Windows paths" {
  val json = "{\"packagesPath\": \"C:\\\\Users\\\\user\\\\.nuget\\\\packages\"}"
  assertEqual(
    unwrapOr(Release.jsonStringField(json, "packagesPath"), ""),
    "C:\\Users\\user\\.nuget\\packages",
    "backslash-escaped Windows path unescaped"
  )
}

// ── parseIlcVersion ──────────────────────────────────────────────────────────
test "parseIlcVersion: extracts the ILC version from a libraries entry" {
  val json = "\"libraries\": {\"runtime.linux-x64.Microsoft.DotNet.ILCompiler/10.0.7\": {\"type\": \"package\"}}"
  assertEqual(unwrapOr(Release.parseIlcVersion(json, "linux-x64"), ""), "10.0.7", "linux-x64 10.0.7")
}

test "parseIlcVersion: returns None when the RID has no matching entry" {
  val json = "\"libraries\": {\"runtime.linux-x64.Microsoft.DotNet.ILCompiler/10.0.7\": {}}"
  assertTrue(match Release.parseIlcVersion(json, "win-x64") { case None -> true; case Some(_) -> false }, "wrong RID")
}

test "parseIlcVersion: returns None when libraries section is absent" {
  val json = "{\"version\": 3}"
  assertTrue(
    match Release.parseIlcVersion(json, "linux-x64") { case None -> true; case Some(_) -> false },
    "no libraries key"
  )
}

// ── localDepNotBuiltMessage (#3216) ──────────────────────────────────────────
test "localDepNotBuiltMessage names the probed DLL path and the --out caveat (#3216)" {
  val m = Release.localDepNotBuiltMessage("util", "/proj/util/bin/Util.dll", "/proj/util/lyric.toml")
  assertTrue(Str.contains(m, "'util'"), "dep name present")
  assertTrue(Str.contains(m, "/proj/util/bin/Util.dll"), "probed DLL path present")
  assertTrue(Str.contains(m, "lyric build --manifest /proj/util/lyric.toml"), "rebuild command present")
  assertTrue(Str.contains(m, "--out"), "custom --out caveat present")
}
