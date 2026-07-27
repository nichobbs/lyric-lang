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

func listContains(xs: in List[String], needle: in String): Bool {
  var i = 0
  while i < xs.count {
    if xs[i] == needle {
      return true
    }
    i += 1
  }
  false
}

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

// ── GraalVM native-image (JVM release target) ────────────────────────────────
test "classpathSeparator: ';' on Windows, ':' elsewhere" {
  assertEqual(Release.classpathSeparator("windows"), ";", "windows")
  assertEqual(Release.classpathSeparator("linux"), ":", "linux")
  assertEqual(Release.classpathSeparator("osx"), ":", "osx")
}

test "joinClasspath: joins with the host separator, empty for no entries" {
  val none: List[String] = newList()
  assertEqual(Release.joinClasspath(none, "linux"), "", "no entries yields no -cp value")
  val two: List[String] = newList()
  two.add("/deps/a.jar")
  two.add("/deps/b.jar")
  assertEqual(Release.joinClasspath(two, "linux"), "/deps/a.jar:/deps/b.jar", "posix separator")
  assertEqual(Release.joinClasspath(two, "windows"), "/deps/a.jar;/deps/b.jar", "windows separator")
}

// `--no-fallback` is the property that makes `--release` meaningful on the JVM:
// without it native-image silently emits a launcher that still needs a JVM.
test "buildNativeImageArgs: always passes --no-fallback, the config dir, the jar and -o" {
  val noJars: List[String] = newList()
  val args = Release.buildNativeImageArgs("/stage/App.jar", noJars, "/stage/ni-config", "/out/app", "linux")
  assertTrue(listContains(args, "--no-fallback"), "--no-fallback present")
  assertTrue(listContains(args, "-H:ConfigurationFileDirectories=/stage/ni-config"), "config dir passed")
  assertTrue(listContains(args, "-jar"), "-jar flag present")
  assertTrue(listContains(args, "/stage/App.jar"), "jar path present")
  assertTrue(listContains(args, "-o"), "-o flag present")
  assertTrue(listContains(args, "/out/app"), "output path present")
}

test "buildNativeImageArgs: omits -cp entirely when there are no extra jars" {
  val noJars: List[String] = newList()
  val args = Release.buildNativeImageArgs("/stage/App.jar", noJars, "/stage/cfg", "/out/app", "linux")
  assertTrue(not listContains(args, "-cp"), "no -cp when no extra jars")
}

test "buildNativeImageArgs: passes restored Maven jars as a single -cp value" {
  val jars: List[String] = newList()
  jars.add("/m2/guava.jar")
  jars.add("/m2/gson.jar")
  val args = Release.buildNativeImageArgs("/stage/App.jar", jars, "/stage/cfg", "/out/app", "linux")
  assertTrue(listContains(args, "-cp"), "-cp present")
  assertTrue(listContains(args, "/m2/guava.jar:/m2/gson.jar"), "both jars in one -cp value")
}

test "nativeImageNotFoundMessage: lists every probed location and how to install" {
  val probed: List[String] = newList()
  probed.add("$GRAALVM_HOME (not set)")
  probed.add("$JAVA_HOME/bin/native-image -> /usr/lib/jvm/j21/bin/native-image")
  probed.add("native-image on PATH")
  val m = Release.nativeImageNotFoundMessage(probed)
  assertTrue(Str.contains(m, "$GRAALVM_HOME (not set)"), "first probe listed")
  assertTrue(Str.contains(m, "/usr/lib/jvm/j21/bin/native-image"), "second probe listed")
  assertTrue(Str.contains(m, "native-image on PATH"), "third probe listed")
  assertTrue(Str.contains(m, "GRAALVM_HOME"), "names the env var to set")
  assertTrue(Str.contains(m, "zlib"), "names the native toolchain prerequisite")
}

test "jvmCrossCompileMessage: names both platforms and says why" {
  val m = Release.jvmCrossCompileMessage("linux-arm64", "linux-x64")
  assertTrue(Str.contains(m, "linux-arm64"), "requested RID present")
  assertTrue(Str.contains(m, "linux-x64"), "host RID present")
  assertTrue(Str.contains(m, "cannot cross-compile"), "states the limitation")
}

// `findOnPath` replaces a spawn-based probe: `Std.ProcessCapture` reports a
// failed *launch* by throwing, so probing an absent tool by running it aborted
// the build with a raw host stack trace instead of an install hint.
test "findOnPath: returns None for an empty PATH" {
  assertTrue(
    match Release.findOnPath("native-image", "", "linux") { case None -> true; case Some(_) -> false },
    "empty PATH finds nothing"
  )
}

test "findOnPath: returns None when no PATH entry holds the tool" {
  assertTrue(
    match Release.findOnPath("definitely-not-a-real-tool-xyz", "/usr/bin:/bin", "linux") {
      case None -> true
      case Some(_) -> false
    },
    "absent tool"
  )
}

test "findOnPath: skips blank PATH segments without probing them" {
  // A trailing ':' yields an empty segment; joining it would probe "/<name>".
  assertTrue(
    match Release.findOnPath("definitely-not-a-real-tool-xyz", "/usr/bin::", "linux") {
      case None -> true
      case Some(_) -> false
    },
    "empty segments ignored"
  )
}

test "findOnPath: finds a tool that exists on the host PATH" {
  // `sh` is required by POSIX to live in /bin.
  assertTrue(
    match Release.findOnPath("sh", "/nonexistent-dir:/bin", "linux") { case Some(_) -> true; case None -> false },
    "resolves /bin/sh, skipping the earlier miss"
  )
}

// ── ridFlavor / ridMatchesHost (musl vs glibc) ───────────────────────────────
// ridOs/ridArch alone cannot separate linux-musl-x64 from linux-x64 (both yield
// linux/x64), which would let a musl RID through on a glibc host — the exact
// mislabelling the JVM `--rid` check exists to prevent.
test "ridFlavor: extracts the libc/distro qualifier between OS and arch" {
  assertEqual(Release.ridFlavor("linux-musl-x64"), "musl", "linux-musl-x64")
  assertEqual(Release.ridFlavor("linux-musl-arm64"), "musl", "linux-musl-arm64")
  assertEqual(Release.ridFlavor("linux-x64"), "", "plain glibc RID has no flavor")
  assertEqual(Release.ridFlavor("osx-arm64"), "", "osx-arm64")
  assertEqual(Release.ridFlavor("linux"), "", "single-segment RID")
}

test "ridMatchesHost: musl and glibc on the same OS/arch are NOT the same host" {
  assertTrue(not Release.ridMatchesHost("linux-musl-x64", "linux-x64"), "musl RID on a glibc host is a mismatch")
  assertTrue(not Release.ridMatchesHost("linux-x64", "linux-musl-x64"), "glibc RID on a musl host is a mismatch")
}

test "ridMatchesHost: identical platforms match, differing OS or arch do not" {
  assertTrue(Release.ridMatchesHost("linux-x64", "linux-x64"), "same RID")
  assertTrue(Release.ridMatchesHost("linux-musl-x64", "linux-musl-x64"), "same musl RID")
  assertTrue(not Release.ridMatchesHost("linux-arm64", "linux-x64"), "arch differs")
  assertTrue(not Release.ridMatchesHost("osx-x64", "linux-x64"), "os differs")
}

// ── jvmReleasePreflightError ─────────────────────────────────────────────────
// Runs before the managed build so a bad --rid costs no compile.
test "jvmReleasePreflightError: accepts no --rid on a supported host" {
  assertTrue(
    match Release.jvmReleasePreflightError(None, "linux-x64") { case None -> true; case Some(_) -> false },
    "host-targeting build is buildable"
  )
}

test "jvmReleasePreflightError: accepts a --rid naming the host" {
  assertTrue(
    match Release.jvmReleasePreflightError(Some(value = "linux-x64"), "linux-x64") {
      case None -> true
      case Some(_) -> false
    },
    "explicit host RID is fine"
  )
}

test "jvmReleasePreflightError: rejects a cross-target --rid" {
  val msg = unwrapOr(Release.jvmReleasePreflightError(Some(value = "osx-arm64"), "linux-x64"), "")
  assertTrue(Str.contains(msg, "cannot cross-compile"), "cross-compile rejected before any build")
}

test "jvmReleasePreflightError: rejects a musl --rid on a glibc host" {
  val msg = unwrapOr(Release.jvmReleasePreflightError(Some(value = "linux-musl-x64"), "linux-x64"), "")
  assertTrue(Str.contains(msg, "cannot cross-compile"), "musl/glibc mismatch rejected")
}

test "jvmReleasePreflightError: rejects a malformed --rid" {
  val msg = unwrapOr(Release.jvmReleasePreflightError(Some(value = "Linux X64!"), "linux-x64"), "")
  assertTrue(Str.contains(msg, "invalid RID"), "malformed RID rejected")
}

test "jvmReleasePreflightError: rejects an unsupported host platform" {
  val msg = unwrapOr(Release.jvmReleasePreflightError(None, "win-x64"), "")
  assertTrue(Str.contains(msg, "Linux and macOS only"), "Windows host rejected with the tracked-issue note")
}

test "jvmReleasePreflightError: rejects an undeterminable host" {
  val msg = unwrapOr(Release.jvmReleasePreflightError(None, ""), "")
  assertTrue(Str.contains(msg, "could not determine the host platform"), "empty host RID")
}
