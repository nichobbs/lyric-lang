//! cli_restore_self_test.l — exercises the pure Maven-restore helper
//! functions in `Lyric.Cli` (cli/cli_restore.l): `jsonEscape`,
//! `buildMavenResolverRequest`, and `extractMavenJarPaths`.  These are
//! structural string/JSON builders with implicit format assumptions
//! (issue #3549) — none of them do I/O, so they can be exercised without
//! `lyric-resolver.jar` or a network connection.
//!
//! Run in CI via:
//!
//!   lyric test lyric-compiler/lyric/cli_restore_self_test.l
@test_module
package Lyric.CliRestoreSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.String as Str
import Std.File as File
import Std.Path as Path
import Std.Errors
import Std.Environment as Environment
import Std.Uuid
import Lyric.Cli as Cli
import Lyric.Manifest as Mf

// ─── jsonEscape ───────────────────────────────────────────────────────────
test "jsonEscape: plain string is unchanged" {
  assertEqual(Cli.jsonEscape("hello"), "hello", "jsonEscape: no special chars")
}

test "jsonEscape: escapes a double-quote" {
  assertEqual(Cli.jsonEscape("a\"b"), "a\\\"b", "jsonEscape: double-quote")
}

test "jsonEscape: escapes a backslash" {
  assertEqual(Cli.jsonEscape("a\\b"), "a\\\\b", "jsonEscape: backslash")
}

test "jsonEscape: backslash before quote is escaped in the right order" {
  // A literal `\"` in the input must become `\\\"` — the backslash escape
  // must run first so the quote escape doesn't re-touch it.
  assertEqual(Cli.jsonEscape("a\\\"b"), "a\\\\\\\"b", "jsonEscape: backslash-quote ordering")
}

// ─── buildMavenResolverRequest ──────────────────────────────────────────
test "buildMavenResolverRequest: single coordinate, default repo, no java version" {
  val entries: List[Mf.MavenEntry] = newList()
  entries.add(Mf.MavenEntry(group = "com.example", artifact = "widget", version = "1.2.3"))
  val repos: List[String] = newList()
  repos.add("central")
  val maven = Mf.MavenSection(entries = entries, repositories = repos, javaVersion = None)
  val json = Cli.buildMavenResolverRequest(maven, "/home/u/.m2/repository", "/proj/target/restore")
  assertEqual(
    json,
    "{\"coordinates\":[{\"group\":\"com.example\",\"artifact\":\"widget\",\"version\":\"1.2.3\"}]," +
      "\"repositories\":[\"central\"],\"javaVersion\":null,\"cacheDir\":\"/home/u/.m2/repository\"," +
      "\"outputDir\":\"/proj/target/restore\"}",
    "buildMavenResolverRequest: single coordinate JSON shape"
  )
}

test "buildMavenResolverRequest: multiple coordinates and repos with java version" {
  val entries: List[Mf.MavenEntry] = newList()
  entries.add(Mf.MavenEntry(group = "com.example", artifact = "a", version = "1.0.0"))
  entries.add(Mf.MavenEntry(group = "com.example", artifact = "b", version = "2.0.0"))
  val repos: List[String] = newList()
  repos.add("central")
  repos.add("https://example.com/repo")
  val maven = Mf.MavenSection(entries = entries, repositories = repos, javaVersion = Some(value = "17"))
  val json = Cli.buildMavenResolverRequest(maven, "/cache", "/out")
  assertEqual(
    json,
    "{\"coordinates\":[{\"group\":\"com.example\",\"artifact\":\"a\",\"version\":\"1.0.0\"}," +
      "{\"group\":\"com.example\",\"artifact\":\"b\",\"version\":\"2.0.0\"}]," +
      "\"repositories\":[\"central\",\"https://example.com/repo\"],\"javaVersion\":\"17\"," +
      "\"cacheDir\":\"/cache\",\"outputDir\":\"/out\"}",
    "buildMavenResolverRequest: multi-coordinate/multi-repo JSON shape"
  )
}

test "buildMavenResolverRequest: no coordinates yields an empty array" {
  val entries: List[Mf.MavenEntry] = newList()
  val repos: List[String] = newList()
  val maven = Mf.MavenSection(entries = entries, repositories = repos, javaVersion = None)
  val json = Cli.buildMavenResolverRequest(maven, "/cache", "/out")
  assertEqual(
    json,
    "{\"coordinates\":[],\"repositories\":[],\"javaVersion\":null,\"cacheDir\":\"/cache\",\"outputDir\":\"/out\"}",
    "buildMavenResolverRequest: empty coordinates/repos"
  )
}

// ─── extractMavenJarPaths ────────────────────────────────────────────────
test "extractMavenJarPaths: single-entry compact response" {
  val json = "[{\"group\":\"com.example\",\"artifact\":\"widget\",\"version\":\"1.2.3\"," +
    "\"jarPath\":\"/home/u/.m2/repository/com/example/widget/1.2.3/widget-1.2.3.jar\"}]"
  val paths = Cli.extractMavenJarPaths(json)
  assertEqualInt(paths.count, 1, "extractMavenJarPaths: single entry count")
  assertEqual(
    paths[0],
    "/home/u/.m2/repository/com/example/widget/1.2.3/widget-1.2.3.jar",
    "extractMavenJarPaths: single entry path"
  )
}

test "extractMavenJarPaths: multi-entry compact response" {
  val json = "[{\"jarPath\":\"/a/one.jar\"},{\"jarPath\":\"/b/two.jar\"},{\"jarPath\":\"/c/three.jar\"}]"
  val paths = Cli.extractMavenJarPaths(json)
  assertEqualInt(paths.count, 3, "extractMavenJarPaths: multi entry count")
  assertEqual(paths[0], "/a/one.jar", "extractMavenJarPaths: entry 0")
  assertEqual(paths[1], "/b/two.jar", "extractMavenJarPaths: entry 1")
  assertEqual(paths[2], "/c/three.jar", "extractMavenJarPaths: entry 2")
}

test "extractMavenJarPaths: empty array response yields no paths" {
  val paths = Cli.extractMavenJarPaths("[]")
  assertEqualInt(paths.count, 0, "extractMavenJarPaths: empty response")
}

test "extractMavenJarPaths: pretty-printed (single space) response is parsed (#4723)" {
  // #4723 fixed the whitespace-intolerance pinned by #3546: a single space
  // after `"jarPath":` (the most common pretty-printer shape) now resolves,
  // via a manual whitespace-skipping scan rather than `Yaml.parseJson` (see
  // the CONTRACT comment removed from extractMavenJarPaths — that approach
  // hit a cross-package `Yaml.YSequence` field-resolution crash tracked in
  // #4726 and was reverted).
  val json = "[{\"jarPath\": \"/a/one.jar\"}]"
  val paths = Cli.extractMavenJarPaths(json)
  assertEqualInt(paths.count, 1, "extractMavenJarPaths: single-space pretty-printed input is matched")
  assertEqual(paths[0], "/a/one.jar", "extractMavenJarPaths: pretty-printed entry path")
}

test "extractMavenJarPaths: fully pretty-printed (multi-line, indented) response is parsed" {
  val json = "[\n  {\n    \"group\": \"com.example\",\n    \"jarPath\": \"/a/one.jar\"\n  },\n" +
    "  {\n    \"jarPath\":   \"/b/two.jar\"\n  }\n]\n"
  val paths = Cli.extractMavenJarPaths(json)
  assertEqualInt(paths.count, 2, "extractMavenJarPaths: multi-line indented entries both matched")
  assertEqual(paths[0], "/a/one.jar", "extractMavenJarPaths: first multi-line entry")
  assertEqual(paths[1], "/b/two.jar", "extractMavenJarPaths: second multi-line entry (multiple spaces after colon)")
}

test "extractMavenJarPaths: 'jarPath' occurring as a string VALUE (not a key) is not misparsed" {
  // Guards the false-positive-split skip: splitting on the literal
  // `"jarPath"` token also matches an occurrence where "jarPath" is used as
  // a VALUE rather than a key (e.g. `"note": "jarPath"`) — that split piece
  // does not start with `:`, so it must be skipped rather than misread as
  // the start of a real `jarPath` key's value.
  val json = "[{\"note\":\"jarPath\"},{\"jarPath\":\"/real/one.jar\"}]"
  val paths = Cli.extractMavenJarPaths(json)
  assertEqualInt(paths.count, 1, "extractMavenJarPaths: only the genuine jarPath key is matched")
  assertEqual(paths[0], "/real/one.jar", "extractMavenJarPaths: the real entry's path")
}

// ─── NPM restore (docs/35 section 9) ────────────────────────────────────
func npmEntry(name: in String, version: in String): Mf.NpmEntry {
  Mf.NpmEntry(name = name, version = version, ident = Mf.npmPackageIdent(name))
}

func npmSection(entries: in List[Mf.NpmEntry], registry: in String): Mf.NpmSection {
  Mf.NpmSection(entries = entries, registry = registry)
}

test "buildNpmPackageJson: one dependency row per entry, escaped" {
  val es: List[Mf.NpmEntry] = newList()
  es.add(npmEntry("node-fetch", "^3"))
  es.add(npmEntry("@aws-sdk/client-s3", "^3.600"))
  val json = Cli.buildNpmPackageJson(npmSection(es, ""))
  assertTrue(Str.contains(json, "\"private\": true"), "package.json is private")
  assertTrue(Str.contains(json, "\"node-fetch\": \"^3\",\n"), "first row with trailing comma")
  assertTrue(Str.contains(json, "\"@aws-sdk/client-s3\": \"^3.600\"\n"), "last row without a comma")
}

test "npmInstallArgs: scripts off, registry only when set" {
  val plain = Cli.npmInstallArgs("/x/npm", "")
  assertEqualInt(plain.count, 6, "no registry flag by default")
  assertEqual(plain[1], "--prefix", "prefix flag")
  assertEqual(plain[2], "/x/npm", "install dir")
  assertEqual(plain[3], "--ignore-scripts", "install hooks never run during restore")
  val custom = Cli.npmInstallArgs("/x/npm", "https://npm.example.com/")
  assertEqualInt(custom.count, 8, "registry adds two arguments")
  assertEqual(custom[7], "https://npm.example.com/", "registry value")
}

test "npmShimFileName: scope folded into the name, no path separators" {
  assertEqual(Mf.npmShimFileName("node-fetch"), "node-fetch.l", "plain name")
  assertEqual(Mf.npmShimFileName("@aws-sdk/client-s3"), "aws-sdk__client-s3.l", "scoped name")
}

test "npmShimStub / npmShimProblem: scaffold satisfies its own check, stripped header is B0063" {
  val e = npmEntry("node-fetch", "^3")
  val stub = Cli.npmShimStub(e)
  assertEqual(stub, "@axiom(\"from npm node-fetch ^3\")\npackage NodeFetch\n", "stub text")
  assertEqual(Cli.npmShimProblem(stub, e), "", "the scaffold is accepted")
  assertEqual(Cli.npmShimProblem(stub + "// edited\n", e), "", "later edits are fine")
  assertTrue(
    Str.startsWith(Cli.npmShimProblem("package NodeFetch\n// @axiom(\"from npm node-fetch ^3\")\n", e), "B0063"),
    "a header moved into a comment is B0063"
  )
  val stripped = Cli.npmShimProblem("package NodeFetch\n", e)
  assertTrue(Str.startsWith(stripped, "B0063"), "a shim without the header is B0063")
  assertTrue(
    Str.startsWith(Cli.npmShimProblem("@axiom(\"from npm other 1\")\npackage NodeFetch\n", e), "B0063"),
    "a header naming a different package is B0063"
  )
}

func npmTempDir(): String {
  val base = Environment.getVarOrDefault(
    "TMPDIR",
    Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp"))
  )
  val root = Path.join(base, "lyric-npmrestore-" + uuidToString(newUuid()))
  match File.createDir(root) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create temp dir " + root + ": " + IOError.message(e))
  }
  root
}

func putFile(path: in String, text: in String): Unit {
  match File.writeText(path, text) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write " + path + ": " + IOError.message(e))
  }
}

func npmManifest(dir: in String, deps: in String): Mf.Manifest {
  val text = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[npm]\n" + deps
  match Mf.parseManifest(text, Path.join(dir, "lyric.toml")) {
    case Ok(m) -> m
    case Err(e) -> panic("manifest: " + Mf.ManifestError.message(e))
  }
}

test "restoreNpmPackages: installs a package, scaffolds its shim, refuses a stripped shim, reports B0060" {
  val dir = npmTempDir()
  val pkgDir = Path.join(dir, "fakepkg")
  match File.createDir(pkgDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create " + pkgDir + ": " + IOError.message(e))
  }
  putFile(
    Path.join(pkgDir, "package.json"),
    "{ \"name\": \"fakepkg\", \"version\": \"1.0.0\", \"main\": \"index.js\" }\n"
  )
  putFile(Path.join(pkgDir, "index.js"), "module.exports = {}\n")

  val m = npmManifest(dir, "\"fakepkg\" = \"file:" + pkgDir + "\"\n")
  assertEqualInt(Cli.restoreNpmPackages(m, dir), 0, "first restore succeeds")
  val installed = Path.join(Path.join(Path.join(Path.join(dir, "target"), "npm"), "node_modules"), "fakepkg")
  assertTrue(File.fileExists(Path.join(installed, "package.json")), "package is in node_modules")
  val shim = Path.join(Path.join(dir, "_extern_npm"), "fakepkg.l")
  assertTrue(File.fileExists(shim), "shim scaffold written")
  match File.readText(shim) {
    case Ok(text) -> assertTrue(Str.contains(text, "package Fakepkg"), "scaffold names the package")
    case Err(_) -> assertTrue(false, "cannot read the shim")
  }

  putFile(shim, "@axiom(\"from npm fakepkg file:" + pkgDir + "\")\npackage Fakepkg\n// hand-authored\n")
  assertEqualInt(Cli.restoreNpmPackages(m, dir), 0, "a hand-authored shim is kept")
  match File.readText(shim) {
    case Ok(text) -> assertTrue(Str.contains(text, "// hand-authored"), "the edit survived a second restore")
    case Err(_) -> assertTrue(false, "cannot read the shim")
  }

  putFile(shim, "package Fakepkg\n")
  assertTrue(Cli.restoreNpmPackages(m, dir) != 0, "B0063: a shim without its @axiom header is refused")

  val missing = npmManifest(dir, "\"nosuchpkg\" = \"file:" + Path.join(dir, "absent") + "\"\n")
  assertTrue(Cli.restoreNpmPackages(missing, dir) != 0, "B0060: a package npm cannot install fails the restore")

  match File.deleteDirRecursive(dir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
}
