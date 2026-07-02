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
