//! plugin_manifest_self_test.l - `Lyric.PluginManifest`, the plugin manifest
//! reader behind `lyric plugin check` and `lyric plugin pack` (D207 Decision 5):
//! the version and id spellings, probe and artifact validation, payload forms,
//! and the text helpers that keep a plugin's manifest bytes exact.
//!
//!   lyric test lyric-compiler/lyric/plugin_manifest_self_test.l
@test_module
package Lyric.PluginManifestSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.File as File
import Std.Path as Path
import Std.Environment as Environment
import Std.String as Str
import Std.Uuid as Uuid
import Std.JsonValue as Jv
import Lyric.PluginManifest

func probeText(): String {
  "{\"schema\":1,\"id\":\"acme.git-tools\",\"version\":\"0.4.1\",\"publisher\":\"acme\"," +
    "\"points\":[{\"point\":\"Editor.Api.EditorExtension\",\"version\":\"1.2\",\"contributions\":{\"n\":18446744073709551615}}]," +
    "\"capabilities\":{\"required\":[{\"name\":\"Editor.Api.WorkspaceRead\",\"grant\":{\"roots\":[\"a\"]}}],\"optional\":[]}}"
}

func problems(text: in String): List[ManifestProblem] = checkManifestText(text, ProbeCheck)

func hasProblem(ps: in List[ManifestProblem], location: in String, fragment: in String): Bool {
  for p in ps {
    if p.location == location and Str.contains(p.message, fragment) {
      return true
    }
  }
  false
}

func describe(ps: in List[ManifestProblem]): String {
  val parts: List[String] = newList()
  for p in ps {
    parts.add(problemText(p))
  }
  Str.joinList("; ", parts)
}

func tempArtifact(name: in String): String {
  val base = Environment.getVarOrDefault("TMPDIR", "/tmp")
  val dir = Path.join(Path.join(base, "lyric-plugin-manifest-" + Uuid.uuidToString(Uuid.newUuid())), name)
  match File.createDir(dir) {
    case Ok(_) -> ()
    case Err(_) -> panic("cannot create " + dir)
  }
  dir
}

func writeFile(dir: in String, rel: in String, text: in String): Unit {
  val p = Path.join(dir, rel)
  val _ = File.createDir(Path.dirname(p))
  match File.writeText(p, text) {
    case Ok(_) -> ()
    case Err(_) -> panic("cannot write " + p)
  }
}

test "major.minor versions" {
  assertTrue(isMajorMinor("1.2"), "1.2")
  assertTrue(isMajorMinor("0.0"), "0.0")
  assertTrue(isMajorMinor("10.20"), "10.20")
  assertFalse(isMajorMinor("1"), "one part")
  assertFalse(isMajorMinor("1.2.3"), "three parts")
  assertFalse(isMajorMinor("01.2"), "leading zero")
  assertFalse(isMajorMinor("1.x"), "not a number")
  assertFalse(isMajorMinor(""), "empty")
}

test "plugin versions" {
  assertTrue(isPluginVersion("0.4.1"), "major.minor.patch")
  assertFalse(isPluginVersion("1.0"), "major.minor is a point version, not a plugin version")
  assertTrue(isPluginVersion("1.0.0-beta.2"), "prerelease")
  assertTrue(isPluginVersion("1.0.0+build.7"), "build metadata")
  assertFalse(isPluginVersion("1"), "one part")
  assertFalse(isPluginVersion("1.0.0.0"), "four parts")
  assertFalse(isPluginVersion("1.0.0-"), "empty prerelease")
  assertFalse(isPluginVersion("v1.0"), "prefix")
}

test "plugin ids and qualified names" {
  assertTrue(isPluginId("acme.git-tools"), "reverse DNS")
  assertTrue(isPluginId("a_b.c9"), "underscore and digits")
  assertFalse(isPluginId(""), "empty")
  assertFalse(isPluginId(".acme"), "leading dot")
  assertTrue(isPluginId("-acme._x"), "segments may start with - or _ as in Std.Plugin")
  assertFalse(isPluginId("acme..tools"), "empty segment")
  assertFalse(isPluginId("acme/tools"), "path separator")
  assertTrue(isQualifiedName("Editor.Api.EditorExtension"), "qualified")
  assertFalse(isQualifiedName("EditorExtension"), "unqualified")
  assertFalse(isQualifiedName("Editor..X"), "empty segment")
  assertFalse(isQualifiedName("Editor.9X"), "segment starting with a digit")
}

test "artifact-relative paths" {
  assertTrue(isArtifactRelativePath("dotnet/Plugin.dll"), "nested")
  assertFalse(isArtifactRelativePath("/abs/x.dll"), "absolute")
  assertFalse(isArtifactRelativePath("C:/x.dll"), "drive")
  assertFalse(isArtifactRelativePath("../x.dll"), "parent")
  assertFalse(isArtifactRelativePath("a\\b.dll"), "backslash")
  assertFalse(isArtifactRelativePath("a//b.dll"), "empty segment")
}

test "a valid probe manifest has no problems" {
  val ps = problems(probeText())
  assertEqualInt(ps.count, 0, "problems: " + describe(ps))
}

test "probe manifest problems are reported with their location" {
  assertTrue(hasProblem(problems("[1]"), "", "expected a JSON object"), "not an object")
  assertTrue(hasProblem(problems("{"), "", "not valid JSON"), "malformed")
  val missing = problems("{\"schema\":1}")
  assertTrue(hasProblem(missing, "", "\"id\""), "missing id")
  assertTrue(hasProblem(missing, "", "\"points\""), "missing points")
  assertFalse(hasProblem(missing, "", "\"capabilities\""), "capabilities may be absent, as Std.Plugin reads it")
  val bad = problems(Str.replace(Str.replace(probeText(), "\"schema\":1", "\"schema\":2"), "\"1.2\"", "\"1.2.0\""))
  assertTrue(hasProblem(bad, "schema", "unsupported schema 2"), "schema 2")
  assertTrue(hasProblem(bad, "points[0].version", "major.minor"), "point version")
  val withPayloadsText = withPayloads(probeText(), newList())
  assertTrue(hasProblem(problems(withPayloadsText), "payloads", "must not list payloads"), "payloads in a probe")
}

test "duplicate points and capabilities are problems" {
  val dupPoint = Str.replace(
    probeText(),
    "\"points\":[",
    "\"points\":[{\"point\":\"Editor.Api.EditorExtension\",\"version\":\"1.0\",\"contributions\":null},"
  )
  assertTrue(hasProblem(problems(dupPoint), "points[1].point", "listed twice"), "duplicate point")
  val dupCap = Str.replace(
    probeText(),
    "\"optional\":[]",
    "\"optional\":[{\"name\":\"Editor.Api.WorkspaceRead\",\"grant\":null}]"
  )
  assertTrue(hasProblem(problems(dupCap), "capabilities.optional[0].name", "requested twice"), "duplicate capability")
}

test "payload JSON forms" {
  assertEqual(
    dotnetPayload("dotnet/P.dll"),
    "{\"mode\":\"process\",\"runtime\":\"dotnet\",\"command\":[\"dotnet\",\"exec\",\"dotnet/P.dll\"]}",
    "dotnet"
  )
  assertEqual(
    jvmPayload("jvm/P.jar"),
    "{\"mode\":\"process\",\"runtime\":\"jvm\",\"command\":[\"java\",\"-jar\",\"jvm/P.jar\"]}",
    "jvm"
  )
  assertEqual(
    nativePayload("linux", "x86_64", "native/P"),
    "{\"mode\":\"process\",\"os\":\"linux\",\"arch\":\"x86_64\",\"command\":[\"native/P\"]}",
    "native"
  )
  assertEqual(wasmPayload("wasm/P.wasm"), "{\"mode\":\"wasm\",\"module\":\"wasm/P.wasm\"}", "wasm")
}

test "triples map to payload os and arch" {
  match osArchOfTriple("x86_64-unknown-linux-gnu") {
    case Ok(oa) -> {
      assertEqual(oa.os, "linux", "linux")
      assertEqual(oa.arch, "x86_64", "x86_64")
    }
    case Err(e) -> panic(e)
  }
  match osArchOfTriple("arm64-apple-darwin23") {
    case Ok(oa) -> {
      assertEqual(oa.os, "macos", "macos")
      assertEqual(oa.arch, "aarch64", "aarch64")
    }
    case Err(e) -> panic(e)
  }
  match osArchOfTriple("x86_64-pc-windows-msvc") {
    case Ok(oa) -> assertEqual(oa.os, "windows", "windows")
    case Err(e) -> panic(e)
  }
  match osArchOfTriple("riscv64-unknown-linux-gnu") {
    case Ok(_) -> panic("riscv64 has no payload arch")
    case Err(e) -> assertTrue(Str.contains(e, "x86_64 and aarch64"), "the error names the supported arches")
  }
}

test "withPayloads keeps the manifest's text exactly" {
  val payloads: List[String] = newList()
  payloads.add(dotnetPayload("dotnet/P.dll"))
  val joined = withPayloads(probeText(), payloads)
  assertTrue(Str.contains(joined, "18446744073709551615"), "a ULong above i64 is kept as written")
  assertTrue(Str.endsWith(joined, ",\"payloads\":[" + dotnetPayload("dotnet/P.dll") + "]}"), "payloads appended last")
  assertEqual(withPayloads("{}", newList()), "{\"payloads\":[]}", "an empty object takes no comma")
}

test "prettyJson re-indents without changing values" {
  val pretty = prettyJson("{\"a\":[1,2.50,{}],\"s\":\"x, {y}: [z]\",\"e\":[],\"n\":18446744073709551615}")
  assertTrue(Str.contains(pretty, "\"s\": \"x, {y}: [z]\""), "strings are copied as they are")
  assertTrue(Str.contains(pretty, "2.50"), "number text is kept")
  assertTrue(Str.contains(pretty, "\"e\": []"), "an empty array stays on one line")
  assertTrue(Str.contains(pretty, "\n  \"a\": [\n    1,"), "nested indentation")
  match Jv.parseValue(pretty) {
    case Ok(_) -> ()
    case Err(_) -> panic("prettyJson output does not parse")
  }
}

test "an artifact directory with its payload files is valid" {
  val dir = tempArtifact("acme.git-tools-0.4.1")
  writeFile(dir, "dotnet/P.dll", "x")
  writeFile(dir, "wasm/P.wasm", "x")
  writeFile(dir, "native/p", "x")
  val payloads: List[String] = newList()
  payloads.add(wasmPayload("wasm/P.wasm"))
  payloads.add(nativePayload("linux", "x86_64", "native/p"))
  payloads.add(dotnetPayload("dotnet/P.dll"))
  writeFile(dir, "plugin.json", prettyJson(withPayloads(probeText(), payloads)))
  val ps = checkArtifactDir(dir)
  assertEqualInt(ps.count, 0, "problems: " + describe(ps))
}

test "artifact problems: missing files, bad commands, duplicates, directory name" {
  val dir = tempArtifact("wrong-name")
  writeFile(dir, "dotnet/P.dll", "x")
  val payloads: List[String] = newList()
  payloads.add(dotnetPayload("dotnet/P.dll"))
  payloads.add(dotnetPayload("dotnet/P.dll"))
  payloads.add(jvmPayload("jvm/Missing.jar"))
  payloads.add(nativePayload("plan9", "x86_64", "native/p"))
  payloads.add("{\"mode\":\"process\",\"runtime\":\"dotnet\",\"command\":[\"dotnet\",\"run\",\"x.dll\"]}")
  payloads.add("{\"mode\":\"wasm\",\"module\":\"../escape.wasm\"}")
  payloads.add("{\"mode\":\"thread\"}")
  writeFile(dir, "plugin.json", withPayloads(probeText(), payloads))
  val ps = checkArtifactDir(dir)
  assertTrue(hasProblem(ps, "payloads[1]", "a second dotnet payload"), "duplicate dotnet: " + describe(ps))
  assertTrue(hasProblem(ps, "payloads[2].command[2]", "does not exist"), "missing jar")
  assertTrue(hasProblem(ps, "payloads[3].os", "unknown os"), "bad os")
  assertTrue(hasProblem(ps, "payloads[4].command", "must start with"), "bad dotnet command")
  assertTrue(hasProblem(ps, "payloads[5].module", "relative path inside"), "escaping path")
  assertTrue(hasProblem(ps, "payloads[6].mode", "unknown payload mode"), "bad mode")
  assertTrue(hasProblem(ps, "", "<id>-<version>"), "directory name")
  val noJson = checkArtifactDir(tempArtifact("empty"))
  assertTrue(hasProblem(noJson, "", "no plugin.json"), "no plugin.json")
  val noPayloads = tempArtifact("acme.git-tools-0.4.1")
  writeFile(noPayloads, "plugin.json", probeText())
  assertTrue(hasProblem(checkArtifactDir(noPayloads), "", "\"payloads\""), "payloads required")
}
