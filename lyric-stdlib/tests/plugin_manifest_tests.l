//! tests/plugin_manifest_tests.l — Std.Plugin without child processes:
//! manifest parsing and validation (every rejection), the manifest round
//! trip, the Q-PLG-004 grant rule, payload selection and launch commands,
//! loading plugins into a host (`registerPlugin` and every load issue), the
//! BoundaryError <-> JSON-RPC error mapping, and trusted mode (docs/69 §10)
//! against an in-memory loader and server: trusted payloads, the policy's
//! `trusted` flag and the fallback to process mode, and the in-process call
//! path with its capability calls. The end-to-end suites with a real plugin
//! are `plugin_e2e_tests.l` and `plugin_trusted_e2e_tests.l`.
@test_module
package Std.Plugin.ManifestTests

import Std.Core
import Std.Collections
import Std.Testing
import Std.JsonValue
import Std.JsonRpc
import Std.Plugin
import Std.Environment as Env
import Std.File as File
import Std.Path as Path

// ── Fixtures ────────────────────────────────────────────────────────────────
val goodManifest: String = "{\"schema\":1,\"id\":\"acme.git-tools\",\"version\":\"0.4.1\",\"publisher\":\"acme\"," + "\"points\":[{\"point\":\"Editor.Api.EditorExtension\",\"version\":\"1.2\",\"contributions\":{\"commands\":[\"git.blame\"]}}]," + "\"capabilities\":{\"required\":[{\"name\":\"Editor.Api.WorkspaceRead\",\"grant\":{\"roots\":[\"/a\",\"/b\"],\"mode\":\"ro\"}}]," + "\"optional\":[{\"name\":\"Editor.Api.Notify\"}]}," + "\"payloads\":[{\"mode\":\"wasm\",\"module\":\"plugin.wasm\"}," + "{\"mode\":\"process\",\"os\":\"linux\",\"arch\":\"x86_64\",\"command\":[\"bin/git-tools\",\"--serve\"]}," + "{\"mode\":\"process\",\"runtime\":\"dotnet\",\"command\":[\"dotnet\",\"exec\",\"lib/GitTools.dll\"]}," + "{\"mode\":\"process\",\"runtime\":\"jvm\",\"command\":[\"java\",\"-jar\",\"lib/git-tools.jar\"]}]," + "\"future\":\"ignored\"}"

func parseGood(): PluginManifest {
  match parsePluginManifest(goodManifest) {
    case Ok(m) -> m
    case Err(issue) -> panic("the good manifest must parse: " + pluginLoadIssueMessage(issue))
  }
}

func json(text: in String): JsonValue {
  match parseValue(text) {
    case Ok(v) -> v
    case Err(e) -> panic("bad test JSON: " + e.message())
  }
}

// Replace `from` in the good manifest, which must contain it exactly once.
func variant(from: in String, to: in String): String {
  assertTrue(goodManifest.contains(from), "fixture contains " + from)
  goodManifest.replace(from, to)
}

func expectInvalid(text: in String, needle: in String, label: in String): Unit {
  match parsePluginManifest(text) {
    case Ok(_) -> assertTrue(false, label + ": expected a rejection")
    case Err(issue) -> {
      match issue.kind {
        case ManifestInvalid -> ()
        case ManifestUnreadable -> ()
        case _ -> assertTrue(false, label + ": unexpected issue kind")
      }
      assertTrue(issue.message.contains(needle), label + ": message '" + issue.message + "' mentions '" + needle + "'")
    }
  }
}

// ── Parsing: the good case ─────────────────────────────────────────────────
test "parse: a complete schema-1 manifest" {
  val m = parseGood()
  assertEqual(m.id, "acme.git-tools", "id")
  assertEqual(m.version, "0.4.1", "version")
  assertEqual(m.publisher, "acme", "publisher")
  assertEqualInt(m.points.count, 1, "one point")
  assertEqual(m.points[0].point, "Editor.Api.EditorExtension", "point id")
  assertEqual(m.points[0].version, "1.2", "point version")
  assertTrue(isSome(m.points[0].contributions), "contributions kept")
  assertEqualInt(m.required.count, 1, "one required capability")
  assertEqual(m.required[0].name, "Editor.Api.WorkspaceRead", "required name")
  assertTrue(isSome(m.required[0].grant), "required grant kept")
  assertEqualInt(m.optional.count, 1, "one optional capability")
  assertTrue(isNone(m.optional[0].grant), "optional capability without a grant")
  assertEqualInt(m.payloads.count, 4, "four payloads")
  match m.payloads[0] {
    case WasmPayload(file) -> assertEqual(file, "plugin.wasm", "wasm module")
    case _ -> assertTrue(false, "payload 0 is wasm")
  }
  match m.payloads[1] {
    case NativePayload(os, arch, command) -> {
      assertEqual(os, "linux", "native os")
      assertEqual(arch, "x86_64", "native arch")
      assertEqualInt(command.count, 2, "native command keeps its arguments")
    }
    case _ -> assertTrue(false, "payload 1 is native")
  }
  match m.payloads[2] {
    case ManagedPayload(runtime, command) -> {
      assertEqual(runtime, "dotnet", "dotnet runtime")
      assertEqual(command[2], "lib/GitTools.dll", "dll path")
    }
    case _ -> assertTrue(false, "payload 2 is dotnet")
  }
}

test "parse: capabilities and payloads may be absent (a probed manifest)" {
  val probed = "{\"schema\":1,\"id\":\"x.y\",\"version\":\"1.0.0\",\"publisher\":\"p\",\"points\":[{\"point\":\"A.P\",\"version\":\"1.0\"}]}"
  match parsePluginManifest(probed) {
    case Err(issue) -> assertTrue(false, "probed manifest: " + pluginLoadIssueMessage(issue))
    case Ok(m) -> {
      assertEqualInt(m.required.count, 0, "no required capabilities")
      assertEqualInt(m.optional.count, 0, "no optional capabilities")
      assertEqualInt(m.payloads.count, 0, "no payloads")
      assertTrue(isNone(m.points[0].contributions), "no contributions")
    }
  }
}

test "parse: pre-release and build versions" {
  assertTrue(isPluginVersion("1.2.3"), "plain")
  assertTrue(isPluginVersion("1.2.3-beta.1"), "pre-release")
  assertTrue(isPluginVersion("1.2.3+build.7"), "build")
  assertTrue(isPluginVersion("0.0.0-rc-1+x"), "both")
  assertFalse(isPluginVersion("1.2"), "two components")
  assertFalse(isPluginVersion("01.2.3"), "leading zero")
  assertFalse(isPluginVersion("1.2.3-"), "empty suffix")
  assertFalse(isPluginVersion("1.2.3-b@d"), "bad suffix character")
  assertTrue(isPointVersion("1.0"), "point version")
  assertTrue(isPointVersion("10.12"), "two-digit point version")
  assertFalse(isPointVersion("1"), "point version without minor")
  assertFalse(isPointVersion("1.0.0"), "point version with patch")
  assertFalse(isPointVersion("1.x"), "non-numeric minor")
}

test "parse: identifiers" {
  assertTrue(isPluginId("acme.git-tools"), "reverse DNS")
  assertTrue(isPluginId("single"), "one segment")
  assertFalse(isPluginId(""), "empty")
  assertFalse(isPluginId("a..b"), "empty segment")
  assertFalse(isPluginId("a b"), "space")
  assertTrue(isQualifiedName("Editor.Api.Notify"), "qualified")
  assertFalse(isQualifiedName("Notify"), "unqualified")
  assertFalse(isQualifiedName("Editor.9Api"), "segment starts with a digit")
  assertFalse(isQualifiedName("Editor.Api-x"), "dash")
}

// ── Parsing: every rejection ───────────────────────────────────────────────
test "reject: not JSON, not an object" {
  match parsePluginManifest("{not json") {
    case Ok(_) -> assertTrue(false, "not JSON must fail")
    case Err(issue) -> match issue.kind {
      case ManifestUnreadable -> ()
      case _ -> assertTrue(false, "not JSON is ManifestUnreadable")
    }
  }
  expectInvalid("[1,2]", "JSON object", "array root")
}

test "reject: schema" {
  expectInvalid(variant("\"schema\":1,", ""), "schema", "missing schema")
  expectInvalid(variant("\"schema\":1,", "\"schema\":2,"), "schema 2", "schema 2")
  expectInvalid(variant("\"schema\":1,", "\"schema\":\"1\","), "schema", "string schema")
}

test "reject: id, version, publisher" {
  expectInvalid(variant("\"id\":\"acme.git-tools\",", ""), "id", "missing id")
  expectInvalid(variant("\"id\":\"acme.git-tools\",", "\"id\":\"acme..x\","), "plugin id", "bad id")
  expectInvalid(variant("\"id\":\"acme.git-tools\",", "\"id\":7,"), "string", "numeric id")
  expectInvalid(variant("\"version\":\"0.4.1\",", ""), "version", "missing version")
  expectInvalid(variant("\"version\":\"0.4.1\",", "\"version\":\"0.4\","), "major.minor.patch", "bad version")
  expectInvalid(variant("\"publisher\":\"acme\",", ""), "publisher", "missing publisher")
  expectInvalid(variant("\"publisher\":\"acme\",", "\"publisher\":\"\","), "publisher", "empty publisher")
}

test "reject: points" {
  val noPoints = "{\"schema\":1,\"id\":\"x.y\",\"version\":\"1.0.0\",\"publisher\":\"p\"}"
  expectInvalid(noPoints, "points", "missing points")
  expectInvalid(noPoints.replace("}", ",\"points\":[]}"), "at least one", "empty points")
  expectInvalid(noPoints.replace("}", ",\"points\":{}}"), "array", "points not an array")
  expectInvalid(noPoints.replace("}", ",\"points\":[3]}"), "object", "point not an object")
  expectInvalid(
    variant("\"point\":\"Editor.Api.EditorExtension\"", "\"point\":\"Editor\""),
    "qualified",
    "unqualified point"
  )
  expectInvalid(variant("\"version\":\"1.2\"", "\"version\":\"1.2.0\""), "major.minor", "bad point version")
  expectInvalid(variant("\"version\":\"1.2\",", ""), "version", "missing point version")
  val twice = "{\"point\":\"Editor.Api.EditorExtension\",\"version\":\"1.2\"}"
  expectInvalid(variant("\"points\":[", "\"points\":[" + twice + ","), "twice", "duplicate point")
}

test "reject: capabilities" {
  expectInvalid(
    variant("\"capabilities\":{", "\"capabilities\":[],\"x\":{"),
    "capabilities",
    "capabilities not an object"
  )
  expectInvalid(variant("\"name\":\"Editor.Api.Notify\"", "\"name\":\"Notify\""), "qualified", "unqualified capability")
  expectInvalid(variant("{\"name\":\"Editor.Api.Notify\"}", "{\"grant\":{}}"), "name", "capability without a name")
  expectInvalid(
    variant("\"name\":\"Editor.Api.Notify\"", "\"name\":\"Editor.Api.WorkspaceRead\""),
    "twice",
    "capability requested twice"
  )
  expectInvalid(variant("\"optional\":[", "\"optional\":3,\"o\":["), "array", "optional not an array")
  expectInvalid(variant("\"optional\":[{", "\"optional\":[7,{"), "object", "capability not an object")
}

test "reject: payloads" {
  expectInvalid(variant("\"module\":\"plugin.wasm\"", "\"module\":\"plugin.wat\""), ".wasm", "wasm file extension")
  expectInvalid(
    variant("\"module\":\"plugin.wasm\"", "\"module\":\"../plugin.wasm\""),
    "relative path",
    "wasm path escapes"
  )
  expectInvalid(variant("{\"mode\":\"wasm\"", "{\"mode\":\"magic\""), "mode", "unknown mode")
  expectInvalid(variant("\"os\":\"linux\"", "\"os\":\"beos\""), "os", "unknown os")
  expectInvalid(variant("\"arch\":\"x86_64\"", "\"arch\":\"mips\""), "arch", "unknown arch")
  expectInvalid(variant("\"bin/git-tools\"", "\"/usr/bin/git-tools\""), "relative path", "absolute executable")
  expectInvalid(variant("\"bin/git-tools\"", "\"bin/./git-tools\""), "relative path", "dot segment")
  expectInvalid(variant("[\"bin/git-tools\",\"--serve\"]", "[]"), "empty", "empty command")
  expectInvalid(variant("\"runtime\":\"dotnet\"", "\"runtime\":\"python\""), "runtime", "unknown runtime")
  expectInvalid(
    variant("[\"dotnet\",\"exec\",\"lib/GitTools.dll\"]", "[\"dotnet\",\"lib/GitTools.dll\"]"),
    "dotnet",
    "dotnet command shape"
  )
  expectInvalid(
    variant("[\"java\",\"-jar\",\"lib/git-tools.jar\"]", "[\"java\",\"lib/git-tools.jar\",\"x\"]"),
    "jvm",
    "jvm command shape"
  )
  expectInvalid(variant("\"lib/GitTools.dll\"", "\"C:/GitTools.dll\""), "relative path", "drive letter")
  expectInvalid(variant("\"payloads\":[", "\"payloads\":{},\"p\":["), "array", "payloads not an array")
  expectInvalid(variant("[\"java\",\"-jar\",\"lib/git-tools.jar\"]", "[\"java\",3]"), "strings", "non-string command")
}

// ── Round trip ──────────────────────────────────────────────────────────────
test "round trip: pluginManifestToJson parses back to the same manifest" {
  val m = parseGood()
  match parsePluginManifestValue(pluginManifestToJson(m), "round trip") {
    case Err(issue) -> assertTrue(false, "round trip: " + pluginLoadIssueMessage(issue))
    case Ok(back) -> {
      assertEqual(back.id, m.id, "id")
      assertEqualInt(back.payloads.count, 4, "payloads")
      assertEqualInt(back.required.count, 1, "required")
      assertTrue(jsonValuesEqual(pluginManifestToJson(back), pluginManifestToJson(m)), "identical JSON")
    }
  }
}

test "addPluginPayload appends a payload" {
  val m = parseGood()
  val more = addPluginPayload(m, ManagedPayload(runtime = "dotnet", command = ["dotnet", "exec", "x.dll"]))
  assertEqualInt(more.payloads.count, 5, "five payloads")
  assertEqualInt(m.payloads.count, 4, "the original is unchanged")
}

// ── Grant rule (Q-PLG-004) ─────────────────────────────────────────────────
func grantOk(req: in String, gr: in String): Bool {
  match checkGrantWithinRequest(Some(value = json(req)), Some(value = json(gr))) {
    case Ok(_) -> true
    case Err(_) -> false
  }
}

test "grant: list fields may narrow, never widen" {
  val req = "{\"roots\":[\"/a\",\"/b\"],\"mode\":\"ro\"}"
  assertTrue(grantOk(req, req), "the request itself")
  assertTrue(grantOk(req, "{\"roots\":[\"/a\"],\"mode\":\"ro\"}"), "a subset")
  assertTrue(grantOk(req, "{\"mode\":\"ro\",\"roots\":[]}"), "the empty list, members reordered")
  assertFalse(grantOk(req, "{\"roots\":[\"/a\",\"/c\"],\"mode\":\"ro\"}"), "an element not requested")
  assertFalse(grantOk(req, "{\"roots\":[\"/a\"],\"mode\":\"rw\"}"), "a scalar field changed")
  assertFalse(grantOk(req, "{\"roots\":[\"/a\"]}"), "a field missing")
  assertFalse(grantOk(req, "{\"roots\":[\"/a\"],\"mode\":\"ro\",\"extra\":1}"), "an extra field")
  assertFalse(grantOk(req, "{\"roots\":\"/a\",\"mode\":\"ro\"}"), "a list replaced by a scalar")
  assertFalse(grantOk("{\"mode\":\"ro\"}", "{\"mode\":[\"ro\"]}"), "a scalar replaced by a list")
  assertTrue(
    grantOk("{\"hosts\":[{\"h\":\"a\",\"p\":1}]}", "{\"hosts\":[{\"p\":1,\"h\":\"a\"}]}"),
    "object elements compare structurally"
  )
  assertTrue(grantOk("[1,2]", "[1,2]"), "non-object values: equal")
  assertFalse(grantOk("[1,2]", "[1]"), "non-object values compare for equality, not subset")
}

test "grant: capabilities without a grant value" {
  match checkGrantWithinRequest(None, None) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "none/none: " + e)
  }
  match checkGrantWithinRequest(None, Some(value = JNull)) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "null is no grant: " + e)
  }
  match checkGrantWithinRequest(None, Some(value = json("{\"x\":1}"))) {
    case Ok(_) -> assertTrue(false, "a value where none was requested is wider")
    case Err(_) -> ()
  }
  match checkGrantWithinRequest(Some(value = json("{\"x\":[1]}")), None) {
    case Ok(_) -> assertTrue(false, "a missing grant value is refused")
    case Err(_) -> ()
  }
}

// ── Payload selection ──────────────────────────────────────────────────────
func linuxDotnet(): PluginPlatform {
  PluginPlatform(os = "linux", arch = "x86_64", runtime = "dotnet")
}

func describePayload(p: in Option[PluginPayload]): String {
  match p {
    case None -> "none"
    case Some(pl) -> match pl {
      case WasmPayload(_) -> "wasm"
      case ComponentPayload(_) -> "component"
      case NativePayload(os, arch, _) -> "native-" + os + "-" + arch
      case ManagedPayload(runtime, _) -> runtime
      case TrustedManagedPayload(runtime, _) -> "trusted-" + runtime
      case TrustedNativePayload(os, arch, _) -> "trusted-native-" + os + "-" + arch
    }
  }
}

test "payload selection order" {
  val all = parseGood().payloads
  assertEqual(
    describePayload(selectPluginPayload(all, linuxDotnet(), true, true, false)),
    "wasm",
    "wasm preferred and available"
  )
  assertEqual(
    describePayload(selectPluginPayload(all, linuxDotnet(), true, false, false)),
    "native-linux-x86_64",
    "no wasmtime: native"
  )
  assertEqual(
    describePayload(selectPluginPayload(all, linuxDotnet(), false, true, false)),
    "native-linux-x86_64",
    "wasm not preferred: native"
  )
  val mac = PluginPlatform(os = "macos", arch = "aarch64", runtime = "jvm")
  assertEqual(
    describePayload(selectPluginPayload(all, mac, false, false, false)),
    "jvm",
    "no native for the platform: own runtime first"
  )
  val macDotnet = PluginPlatform(os = "macos", arch = "aarch64", runtime = "dotnet")
  assertEqual(
    describePayload(selectPluginPayload(all, macDotnet, false, false, false)),
    "dotnet",
    "dotnet host: dotnet payload"
  )
  val nativeHost = PluginPlatform(os = "macos", arch = "aarch64", runtime = "native")
  assertEqual(
    describePayload(selectPluginPayload(all, nativeHost, false, false, false)),
    "dotnet",
    "native host: dotnet before jvm"
  )
  val wasmOnly: List[PluginPayload] = [WasmPayload(wasmModule = "p.wasm")]
  assertEqual(
    describePayload(selectPluginPayload(wasmOnly, linuxDotnet(), false, true, false)),
    "wasm",
    "wasm as a last resort"
  )
  assertEqual(
    describePayload(selectPluginPayload(wasmOnly, linuxDotnet(), true, false, false)),
    "none",
    "wasm only, no wasmtime"
  )
  val none: List[PluginPayload] = newList()
  assertEqual(describePayload(selectPluginPayload(none, linuxDotnet(), true, true, false)), "none", "no payloads")
}

test "payload selection with a component payload (docs/69 section 9.3)" {
  val all = parseGood().payloads
  all.add(ComponentPayload(component = "component/p.wasm"))
  assertEqual(
    describePayload(selectPluginPayload(all, linuxDotnet(), true, true, true)),
    "component",
    "in-process wasm and wasm preferred: the component before the wasm command"
  )
  assertEqual(
    describePayload(selectPluginPayload(all, linuxDotnet(), true, true, false)),
    "wasm",
    "no in-process wasm: the component is skipped"
  )
  assertEqual(
    describePayload(selectPluginPayload(all, linuxDotnet(), false, true, true)),
    "native-linux-x86_64",
    "wasm not preferred: native before the component"
  )
  val componentOnly: List[PluginPayload] = [ComponentPayload(component = "p.wasm")]
  assertEqual(
    describePayload(selectPluginPayload(componentOnly, linuxDotnet(), false, false, true)),
    "component",
    "a component as a last resort"
  )
  assertEqual(
    describePayload(selectPluginPayload(componentOnly, linuxDotnet(), true, true, false)),
    "none",
    "component only, no in-process wasm"
  )
  val both: List[PluginPayload] = [WasmPayload(wasmModule = "w.wasm"), ComponentPayload(component = "c.wasm")]
  assertEqual(
    describePayload(selectPluginPayload(both, linuxDotnet(), false, true, true)),
    "component",
    "last resort: the component before the wasm command"
  )
}

test "parse: a component payload, its checks and its round trip" {
  val text = variant(
    "{\"mode\":\"wasm\",\"module\":\"plugin.wasm\"}",
    "{\"mode\":\"component\",\"component\":\"component/plugin.wasm\"}"
  )
  match parsePluginManifest(text) {
    case Err(issue) -> assertTrue(false, "component payload: " + pluginLoadIssueMessage(issue))
    case Ok(m) -> {
      match m.payloads[0] {
        case ComponentPayload(file) -> assertEqual(file, "component/plugin.wasm", "component file")
        case _ -> assertTrue(false, "payload 0 is a component")
      }
      val again = writeValue(pluginManifestToJson(m))
      assertTrue(again.contains("{\"mode\":\"component\",\"component\":\"component/plugin.wasm\"}"), again)
      match parsePluginManifest(again) {
        case Ok(m2) -> assertEqualInt(m2.payloads.count, m.payloads.count, "round trip keeps the payloads")
        case Err(issue) -> assertTrue(false, "round trip: " + pluginLoadIssueMessage(issue))
      }
    }
  }
  expectInvalid(
    variant("{\"mode\":\"wasm\",\"module\":\"plugin.wasm\"}", "{\"mode\":\"component\",\"component\":\"p.so\"}"),
    "must be a .wasm file",
    "component not .wasm"
  )
  expectInvalid(
    variant("{\"mode\":\"wasm\",\"module\":\"plugin.wasm\"}", "{\"mode\":\"component\",\"component\":\"../p.wasm\"}"),
    "inside the plugin directory",
    "component outside the directory"
  )
  expectInvalid(
    variant("{\"mode\":\"wasm\",\"module\":\"plugin.wasm\"}", "{\"mode\":\"component\"}"),
    "component",
    "component without a file"
  )
  expectInvalid(
    variant("{\"mode\":\"wasm\",\"module\":\"plugin.wasm\"}", "{\"mode\":\"jit\"}"),
    "\"component\"",
    "unknown mode lists component"
  )
  match pluginLaunchCommand(ComponentPayload(component = "p.wasm"), "/plugins/p", Some(value = "/opt/wasmtime"), 1024i64) {
    case Ok(_) -> assertTrue(false, "a component payload has no command line")
    case Err(e) -> assertTrue(e.contains("in the host's process"), e)
  }
}

test "WIT names round-trip as the component shape writes them" {
  assertEqual(pluginWitName("noteToolSummarize"), "note-tool-summarize", "camel case")
  assertEqual(pluginWitName("Editor.Api.WorkspaceRead"), "editor-api-workspace-read", "a qualified capability")
  assertEqual(pluginWitName("IOError"), "io-error", "an acronym is one word")
  assertEqual(pluginWitName("list"), "%list", "a keyword is escaped")
  assertEqual(pluginCamelName("note-tool-summarize"), "noteToolSummarize", "back to camel case")
  assertEqual(pluginCamelName("%list"), "list", "the escape is dropped")
  assertEqual(pluginCamelName("read"), "read", "one word")
}

test "launch commands resolve paths inside the plugin directory" {
  match pluginLaunchCommand(ManagedPayload(runtime = "dotnet", command = ["dotnet", "exec", "lib/P.dll", "--x"]), "/plugins/p", None, 1024i64) {
    case Err(e) -> assertTrue(false, "dotnet: " + e)
    case Ok(argv) -> {
      assertEqualInt(argv.count, 4, "dotnet argv")
      assertEqual(argv[0], "dotnet", "dotnet exe")
      assertEqual(argv[1], "exec", "exec")
      assertTrue(argv[2].endsWith("lib/P.dll") and argv[2].startsWith("/plugins/p"), "dll resolved: " + argv[2])
      assertEqual(argv[3], "--x", "extra argument")
    }
  }
  match pluginLaunchCommand(NativePayload(os = "linux", arch = "x86_64", command = ["bin/p"]), "/plugins/p", None, 1024i64) {
    case Err(e) -> assertTrue(false, "native: " + e)
    case Ok(argv) -> assertTrue(
      argv[0].startsWith("/plugins/p") and argv[0].endsWith("bin/p"),
      "exe resolved: " + argv[0]
    )
  }
  match pluginLaunchCommand(WasmPayload(wasmModule = "p.wasm"), "/plugins/p", Some(value = "/opt/wasmtime"), 1048576i64) {
    case Err(e) -> assertTrue(false, "wasm: " + e)
    case Ok(argv) -> {
      assertEqual(argv[0], "/opt/wasmtime", "wasmtime")
      assertEqual(argv[1], "run", "run")
      assertEqual(argv[2], "-W", "-W")
      assertEqual(argv[3], "max-memory-size=1048576", "memory ceiling")
      assertEqualInt(argv.count, 5, "no --dir, --env or other grant of ambient access")
    }
  }
  match pluginLaunchCommand(WasmPayload(wasmModule = "p.wasm"), "/plugins/p", None, 1024i64) {
    case Ok(_) -> assertTrue(false, "a wasm payload needs wasmtime")
    case Err(_) -> ()
  }
}

test "a missing $LYRIC_WASMTIME override is named in the error" {
  val before = Env.getVarOrDefault("LYRIC_WASMTIME", "")
  Env.setVar("LYRIC_WASMTIME", "/nonexistent/wasmtime")
  match pluginLaunchCommand(WasmPayload(wasmModule = "p.wasm"), "/plugins/p", findWasmtime(), 1024i64) {
    case Ok(_) -> assertTrue(false, "a missing override is not used")
    case Err(e) -> assertTrue(e.contains("/nonexistent/wasmtime"), e)
  }
  Env.setVar("LYRIC_WASMTIME", before)
}

test "a payload command too short to launch is an error, not a panic" {
  match pluginLaunchCommand(ManagedPayload(runtime = "dotnet", command = ["dotnet", "exec"]), "/plugins/p", None, 1024i64) {
    case Ok(_) -> assertTrue(false, "a managed command without the payload file")
    case Err(e) -> assertTrue(e.contains("dotnet payload"), e)
  }
  match pluginLaunchCommand(ManagedPayload(runtime = "dotnet", command = ["/bin/sh", "-c", "evil"]), "/plugins/p", None, 1024i64) {
    case Ok(_) -> assertTrue(false, "a dotnet payload must launch with dotnet exec")
    case Err(e) -> assertTrue(e.contains("dotnet payload"), e)
  }
  match pluginLaunchCommand(ManagedPayload(runtime = "jvm", command = ["../java", "-jar", "p.jar"]), "/plugins/p", None, 1024i64) {
    case Ok(_) -> assertTrue(false, "a jvm payload must launch with java -jar")
    case Err(e) -> assertTrue(e.contains("jvm payload"), e)
  }
  match pluginLaunchCommand(NativePayload(os = "linux", arch = "x86_64", command = []), "/plugins/p", None, 1024i64) {
    case Ok(_) -> assertTrue(false, "an empty native command")
    case Err(e) -> assertTrue(e.contains("native payload"), e)
  }
}

test "the current platform uses the manifest vocabulary" {
  val p = currentPluginPlatform()
  assertTrue(p.os == "linux" or p.os == "macos" or p.os == "windows" or p.os == "other", "os: " + p.os)
  assertTrue(p.arch == "x86_64" or p.arch == "aarch64" or p.arch == "other", "arch: " + p.arch)
  assertTrue(p.runtime == "dotnet" or p.runtime == "jvm" or p.runtime == "native", "runtime: " + p.runtime)
}

// ── Loading into a host ─────────────────────────────────────────────────────
pub record FixedPolicy {
  decision: GrantDecision
}

impl GrantPolicy for FixedPolicy {
  func decide(manifest: in PluginManifest): GrantDecision {
    self.decision
  }
}

pub record NullProvider {
  id: String
}

impl CapabilityProvider for NullProvider {
  func info(): CapabilityInfo {
    CapabilityInfo(id = self.id, hasGrant = false)
  }

  func serve(method: in String, params: in Option[JsonValue], grant: in Option[JsonValue]): Result[JsonValue, RpcError] {
    Ok(value = JNull)
  }
}

func editorPoint(version: in String): PluginPointInfo {
  PluginPointInfo(
    id = "Editor.Api.EditorExtension",
    version = version,
    allows = ["Editor.Api.WorkspaceRead", "Editor.Api.Notify"],
    hasContributions = true,
    protocol = None
  )
}

func providers(): List[CapabilityProvider] {
  val ps: List[CapabilityProvider] = newList()
  ps.add(NullProvider(id = "Editor.Api.WorkspaceRead"))
  ps.add(NullProvider(id = "Editor.Api.Notify"))
  ps
}

func hostWith(points: in List[PluginPointInfo], decision: in GrantDecision): PluginHost {
  newPluginHost(PluginHostConfig(points = points, providers = providers(), policy = FixedPolicy(decision = decision)))
}

func readGrant(roots: in String): GrantedCapability {
  GrantedCapability(
    capability = "Editor.Api.WorkspaceRead",
    grant = Some(value = json("{\"roots\":" + roots + ",\"mode\":\"ro\"}"))
  )
}

func allow(grants: in List[GrantedCapability]): GrantDecision {
  GrantDecision(allow = true, reason = "", grants = grants)
}

func expectIssue(host: in PluginHost, m: in PluginManifest, code: in String, needle: in String, label: in String): Unit {
  match registerPlugin(host, m, "/plugins/acme") {
    case None -> assertTrue(false, label + ": expected a load issue")
    case Some(issue) -> {
      assertEqual(pluginIssueCode(issue.kind), code, label + ": code")
      assertEqual(issue.pluginId, "acme.git-tools", label + ": plugin id")
      assertTrue(issue.message.contains(needle), label + ": message '" + issue.message + "' mentions '" + needle + "'")
    }
  }
}

test "registerPlugin: a plugin within its request loads, and contributions are readable" {
  val host = hostWith([editorPoint("1.4")], allow([readGrant("[\"/a\"]")]))
  match registerPlugin(host, parseGood(), "/plugins/acme") {
    case Some(issue) -> assertTrue(false, "unexpected issue: " + pluginLoadIssueMessage(issue))
    case None -> ()
  }
  assertEqualInt(pluginManifests(host).count, 1, "one manifest")
  assertEqualInt(connectionsFor(host, "Editor.Api.EditorExtension").count, 1, "one connection")
  assertEqualInt(connectionsFor(host, "Editor.Api.Other").count, 0, "no connection for another point")
  val contributions = contributionsFor(host, "Editor.Api.EditorExtension")
  assertEqualInt(contributions.count, 1, "one contribution")
  assertEqual(contributions[0].pluginId, "acme.git-tools", "contribution plugin id")
  assertTrue(jsonValuesEqual(contributions[0].value, json("{\"commands\":[\"git.blame\"]}")), "contribution value")
  expectIssue(host, parseGood(), "", "already loaded", "duplicate id")
}

test "registerPlugin: GrantAllRequested grants exactly the request" {
  val host = newPluginHost(
    PluginHostConfig(points = [editorPoint("1.0")], providers = providers(), policy = GrantAllRequested())
  )
  match registerPlugin(host, parseGood(), "/plugins/acme") {
    case Some(issue) -> assertTrue(false, "unexpected issue: " + pluginLoadIssueMessage(issue))
    case None -> ()
  }
}

test "registerPlugin: every load issue" {
  val good = parseGood()
  expectIssue(
    hostWith([editorPoint("2.0")], allow([readGrant("[\"/a\"]")])),
    good,
    "K0103",
    "1.2",
    "major version mismatch"
  )
  val other = PluginPointInfo(
    id = "Other.Api.P",
    version = "1.0",
    allows = newList(),
    hasContributions = false,
    protocol = None
  )
  expectIssue(hostWith([other], allow(newList())), good, "", "none of the points", "no matching point")
  val narrow = PluginPointInfo(
    id = "Editor.Api.EditorExtension",
    version = "1.0",
    allows = ["Editor.Api.Notify"],
    hasContributions = true,
    protocol = None
  )
  expectIssue(hostWith([narrow], allow(newList())), good, "", "not allowed", "capability not allowed")
  val refused = GrantDecision(allow = false, reason = "user said no", grants = newList())
  expectIssue(hostWith([editorPoint("1.0")], refused), good, "", "user said no", "policy refused")
  expectIssue(hostWith([editorPoint("1.0")], allow([readGrant("[\"/a\",\"/z\"]")])), good, "K0102", "/z", "wider grant")
  val notRequested = GrantedCapability(capability = "Editor.Api.Other", grant = None)
  expectIssue(
    hostWith([editorPoint("1.0")], allow([readGrant("[]"), notRequested])),
    good,
    "",
    "not requested",
    "grant not requested"
  )
  expectIssue(
    hostWith([editorPoint("1.0")], allow([readGrant("[]"), readGrant("[]")])),
    good,
    "",
    "twice",
    "granted twice"
  )
  val notifyOnly = GrantedCapability(capability = "Editor.Api.Notify", grant = None)
  expectIssue(hostWith([editorPoint("1.0")], allow([notifyOnly])), good, "", "was not granted", "required not granted")
  val noProviders: List[CapabilityProvider] = newList()
  val bare = newPluginHost(
    PluginHostConfig(
      points = [editorPoint("1.0")],
      providers = noProviders,
      policy = FixedPolicy(decision = allow([readGrant("[]")]))
    )
  )
  expectIssue(bare, good, "", "no provider", "missing provider")
  val wasmOnly = PluginManifest(
    id = good.id,
    version = good.version,
    publisher = good.publisher,
    points = good.points,
    required = good.required,
    optional = good.optional,
    payloads = [
      WasmPayload(wasmModule = "p.wasm"),
      NativePayload(os = "windows", arch = "aarch64", command = ["p.exe"])
    ]
  )
  val wasmtime = findWasmtime()
  if isNone(wasmtime) {
    expectIssue(hostWith([editorPoint("1.0")], allow([readGrant("[]")])), wasmOnly, "", "no payload", "no usable payload")
  }
}

pub record PanickingPolicy {
}

impl GrantPolicy for PanickingPolicy {
  func decide(manifest: in PluginManifest): GrantDecision {
    panic("PanickingPolicy: deliberate")
  }
}

test "registerPlugin: a panicking policy refuses the plugin" {
  // A native host cannot contain a policy panic: native has no unwinding, so
  // a panic ends the process (D-N-003, `_kernel_native/panic_guard_host.l`).
  if currentPluginPlatform().runtime == "native" {
    return
  }
  val host = newPluginHost(
    PluginHostConfig(points = [editorPoint("1.0")], providers = providers(), policy = PanickingPolicy())
  )
  expectIssue(host, parseGood(), "", "policy failed", "panicking policy")
  assertEqualInt(pluginManifests(host).count, 0, "nothing loaded")
}

test "a host-side call without a running plugin's connection is a protocol error" {
  val conn = PluginConnection(pluginId = "x", peer = None, host = None)
  match callPlugin(conn, "A.P/m", JNull) {
    case Ok(_) -> assertTrue(false, "expected an error")
    case Err(b) -> match b {
      case Protocol(_) -> ()
      case _ -> assertTrue(false, "expected Protocol, got " + boundaryErrorMessage(b))
    }
  }
  match callHost(conn, "cap/A.C/m", JNull) {
    case Ok(_) -> assertTrue(false, "expected an error")
    case Err(b) -> match b {
      case Protocol(_) -> ()
      case _ -> assertTrue(false, "expected Protocol, got " + boundaryErrorMessage(b))
    }
  }
}

// ── BoundaryError <-> JSON-RPC ─────────────────────────────────────────────
func roundTrip(b: in BoundaryError): BoundaryError {
  boundaryErrorFromRpc(boundaryErrorToRpc(b), "Pkg.P/m")
}

test "boundary errors: wire codes" {
  assertEqualInt(boundaryErrorToRpc(Denied(reason = "r")).code, -32040, "Denied")
  assertEqualInt(boundaryErrorToRpc(NotGranted(capability = "c")).code, -32041, "NotGranted")
  assertEqualInt(boundaryErrorToRpc(Stale).code, -32042, "Stale")
  assertEqualInt(boundaryErrorToRpc(Unsupported(method = "m")).code, -32043, "Unsupported")
  assertEqualInt(boundaryErrorToRpc(Revoked(capability = "c")).code, -32044, "Revoked")
  assertEqualInt(boundaryErrorToRpc(ContractViolated(detail = "d")).code, -32045, "ContractViolated")
  assertEqualInt(boundaryErrorToRpc(Protocol(detail = "d")).code, -32046, "Protocol")
  assertEqualInt(boundaryErrorToRpc(Timeout(timeoutMs = 5)).code, -32001, "Timeout")
  assertEqualInt(boundaryErrorToRpc(Crashed(detail = "d")).code, -32603, "Crashed")
}

test "boundary errors: round trip through JSON-RPC" {
  match roundTrip(Denied(reason = "no")) {
    case Denied(r) -> assertEqual(r, "no", "Denied reason")
    case _ -> assertTrue(false, "Denied")
  }
  match roundTrip(NotGranted(capability = "A.C")) {
    case NotGranted(c) -> assertEqual(c, "A.C", "NotGranted capability")
    case _ -> assertTrue(false, "NotGranted")
  }
  match roundTrip(Stale) {
    case Stale -> ()
    case _ -> assertTrue(false, "Stale")
  }
  match roundTrip(Unsupported(method = "A.P/x")) {
    case Unsupported(m) -> assertEqual(m, "A.P/x", "Unsupported method")
    case _ -> assertTrue(false, "Unsupported")
  }
  match roundTrip(Revoked(capability = "A.C")) {
    case Revoked(c) -> assertEqual(c, "A.C", "Revoked capability")
    case _ -> assertTrue(false, "Revoked")
  }
  match roundTrip(ContractViolated(detail = "d")) {
    case ContractViolated(d) -> assertEqual(d, "d", "detail")
    case _ -> assertTrue(false, "ContractViolated")
  }
  match roundTrip(Protocol(detail = "p")) {
    case Protocol(d) -> assertEqual(d, "p", "detail")
    case _ -> assertTrue(false, "Protocol")
  }
  match roundTrip(Timeout(timeoutMs = 1234)) {
    case Timeout(ms) -> assertEqualInt(ms, 1234, "timeoutMs")
    case _ -> assertTrue(false, "Timeout")
  }
}

test "boundary errors: standard JSON-RPC codes" {
  val notFound = RpcError(code = methodNotFound, message = "nope", data = None)
  match boundaryErrorFromRpc(notFound, "A.P/m") {
    case Unsupported(m) -> assertEqual(m, "A.P/m", "-32601 names the called method")
    case _ -> assertTrue(false, "-32601 is Unsupported")
  }
  match boundaryErrorFromRpc(RpcError(code = invalidParams, message = "bad", data = None), "A.P/m") {
    case Protocol(_) -> ()
    case _ -> assertTrue(false, "-32602 is Protocol")
  }
  match boundaryErrorFromRpc(RpcError(code = internalError, message = "Internal error", data = None), "A.P/m") {
    case ContractViolated(_) -> ()
    case _ -> assertTrue(false, "-32603 is ContractViolated")
  }
  match boundaryErrorFromRpc(RpcError(code = 17, message = "app", data = None), "A.P/m") {
    case Protocol(d) -> assertTrue(d.contains("17"), "unknown code named")
    case _ -> assertTrue(false, "an unknown code is Protocol")
  }
  assertTrue(boundaryErrorMessage(Timeout(timeoutMs = 9)).contains("9 ms"), "message")
}

// ── Trusted mode (docs/69 §10) ──────────────────────────────────────────────
test "parse: trusted payloads, managed and native, round trip" {
  val text = goodManifest.replace(
    "{\"mode\":\"wasm\",\"module\":\"plugin.wasm\"},",
    "{\"mode\":\"wasm\",\"module\":\"plugin.wasm\"}," +
      "{\"mode\":\"trusted\",\"runtime\":\"dotnet\",\"library\":\"lib/GitTools.dll\"}," +
      "{\"mode\":\"trusted\",\"runtime\":\"jvm\",\"library\":\"lib/git-tools.jar\"}," +
      "{\"mode\":\"trusted\",\"os\":\"linux\",\"arch\":\"x86_64\",\"library\":\"native/libgit.so\"}," +
      "{\"mode\":\"trusted\",\"os\":\"macos\",\"arch\":\"aarch64\",\"library\":\"native/libgit.dylib\"},"
  )
  val m = match parsePluginManifest(text) {
    case Ok(pm) -> pm
    case Err(issue) -> panic("trusted payloads must parse: " + pluginLoadIssueMessage(issue))
  }
  assertEqualInt(m.payloads.count, 8, "eight payloads")
  assertEqual(describePayload(Some(value = m.payloads[1])), "trusted-dotnet", "trusted dotnet")
  assertEqual(describePayload(Some(value = m.payloads[2])), "trusted-jvm", "trusted jvm")
  assertEqual(describePayload(Some(value = m.payloads[3])), "trusted-native-linux-x86_64", "trusted linux")
  assertEqual(describePayload(Some(value = m.payloads[4])), "trusted-native-macos-aarch64", "trusted macos")
  match m.payloads[1] {
    case TrustedManagedPayload(_, library) -> assertEqual(library, "lib/GitTools.dll", "library path")
    case _ -> assertTrue(false, "payload 1 is a trusted managed payload")
  }
  match parsePluginManifestValue(pluginManifestToJson(m), "round trip") {
    case Ok(back) -> {
      assertEqualInt(back.payloads.count, 8, "the payloads survive a round trip")
      assertEqual(describePayload(Some(value = back.payloads[3])), "trusted-native-linux-x86_64", "native kept")
    }
    case Err(issue) -> assertTrue(false, "round trip: " + pluginLoadIssueMessage(issue))
  }
}

test "reject: malformed trusted payloads" {
  val wasm = "{\"mode\":\"wasm\",\"module\":\"plugin.wasm\"}"
  expectInvalid(
    variant(wasm, "{\"mode\":\"trusted\",\"runtime\":\"dotnet\"}"),
    "library",
    "a trusted payload needs a library"
  )
  expectInvalid(
    variant(wasm, "{\"mode\":\"trusted\",\"runtime\":\"dotnet\",\"library\":\"lib/GitTools.jar\"}"),
    ".dll",
    "a dotnet library is a .dll"
  )
  expectInvalid(
    variant(wasm, "{\"mode\":\"trusted\",\"runtime\":\"python\",\"library\":\"p.py\"}"),
    "python",
    "an unknown runtime"
  )
  expectInvalid(
    variant(wasm, "{\"mode\":\"trusted\",\"os\":\"linux\",\"arch\":\"x86_64\",\"library\":\"native/libgit.dylib\"}"),
    ".so",
    "a linux library is a .so"
  )
  expectInvalid(
    variant(wasm, "{\"mode\":\"trusted\",\"runtime\":\"jvm\",\"library\":\"../escape.jar\"}"),
    "inside the plugin directory",
    "a library outside the plugin directory"
  )
  expectInvalid(variant(wasm, "{\"mode\":\"inproc\",\"library\":\"x.dll\"}"), "trusted", "an unknown mode")
  assertEqual(trustedLibrarySuffix("dotnet"), ".dll", "dotnet suffix")
  assertEqual(trustedLibrarySuffix("jvm"), ".jar", "jvm suffix")
  assertEqual(trustedLibrarySuffix("linux"), ".so", "linux suffix")
  assertEqual(trustedLibrarySuffix("macos"), ".dylib", "macos suffix")
}

test "trusted payload selection: the host's own runtime, never chosen by selectPluginPayload" {
  val payloads: List[PluginPayload] = [
    ManagedPayload(runtime = "dotnet", command = ["dotnet", "exec", "lib/G.dll"]),
    TrustedManagedPayload(runtime = "jvm", library = "lib/g.jar"),
    TrustedManagedPayload(runtime = "dotnet", library = "lib/G.dll"),
    TrustedNativePayload(os = "linux", arch = "x86_64", library = "native/libg.so")
  ]
  assertEqual(describePayload(selectTrustedPayload(payloads, linuxDotnet())), "trusted-dotnet", "dotnet host")
  val jvmHost = PluginPlatform(os = "linux", arch = "x86_64", runtime = "jvm")
  assertEqual(describePayload(selectTrustedPayload(payloads, jvmHost)), "trusted-jvm", "jvm host")
  val nativeHost = PluginPlatform(os = "linux", arch = "x86_64", runtime = "native")
  assertEqual(describePayload(selectTrustedPayload(payloads, nativeHost)), "trusted-native-linux-x86_64", "native host")
  val macNative = PluginPlatform(os = "macos", arch = "aarch64", runtime = "native")
  assertEqual(describePayload(selectTrustedPayload(payloads, macNative)), "none", "no library for macos")
  assertEqual(
    describePayload(selectPluginPayload(payloads, linuxDotnet(), false, false, false)),
    "dotnet",
    "process selection"
  )
  val trustedOnly: List[PluginPayload] = [TrustedManagedPayload(runtime = "dotnet", library = "lib/G.dll")]
  assertEqual(
    describePayload(selectPluginPayload(trustedOnly, linuxDotnet(), true, true, true)),
    "none",
    "never trusted"
  )
  match pluginLaunchCommand(trustedOnly[0], "/plugins/p", None, 1024i64) {
    case Ok(_) -> assertTrue(false, "a trusted payload has no launch command")
    case Err(e) -> assertTrue(e.contains("not launched"), e)
  }
}

// An in-memory trusted plugin: the server a generated `<R>Server` would be,
// for point `Editor.Api.EditorExtension`, calling `WorkspaceRead` back.
pub ref record FakeServer {
  var conn: Option[PluginConnection]
  var attaches: Int
  var granted: List[String]
  var calls: Int
}

impl PluginServer for FakeServer {
  func describe(): JsonValue {
    json("{\"schema\":1,\"id\":\"acme.git-tools\"}")
  }

  func attach(conn: in PluginConnection, grants: in List[GrantedCapability]): Result[Unit, BoundaryError] {
    self.attaches = self.attaches + 1
    val names: List[String] = newList()
    for g in grants {
      names.add(g.capability)
    }
    self.granted = names
    self.conn = Some(value = conn)
    Ok(value = ())
  }

  func pointMethods(): List[PluginPointMethods] {
    [PluginPointMethods(point = "Editor.Api.EditorExtension", version = "1.2", methods = ["echo", "read", "count"])]
  }

  func dispatch(method: in String, params: in Option[JsonValue]): Result[JsonValue, RpcError] {
    val conn = match self.conn {
      case Some(c) -> c
      case None -> return Err(error = boundaryErrorToRpc(Protocol(detail = "not attached")))
    }
    if method == "Editor.Api.EditorExtension/echo" {
      return Ok(value = JObject(fields = [JsonField(name = "ok", value = unwrapOr(params, JNull))]))
    }
    if method == "Editor.Api.EditorExtension/count" {
      self.calls = self.calls + 1
      return Ok(value = JObject(fields = [JsonField(name = "ok", value = JInt(value = self.calls.toLong()))]))
    }
    if method == "Editor.Api.EditorExtension/read" {
      return match callHost(conn, "cap/Editor.Api.WorkspaceRead/readFile", json("{\"path\":\"/a/x\"}")) {
        case Ok(v) -> Ok(value = v)
        case Err(b) -> Err(error = boundaryErrorToRpc(b))
      }
    }
    Err(error = RpcError(code = methodNotFound, message = method, data = None))
  }
}

pub ref record FakeLibrary {
  var servers: Int
}

impl TrustedLibrary for FakeLibrary {
  func newServer(): Result[PluginServer, String] {
    self.servers = self.servers + 1
    val server: PluginServer = FakeServer(conn = None, attaches = 0, granted = newList(), calls = 0)
    Ok(value = server)
  }
}

pub record FakeLoader {
  library: FakeLibrary
  reason: String
  failOpen: Bool
}

impl TrustedLoader for FakeLoader {
  func runtime(): String {
    "dotnet"
  }

  func unavailableReason(): String {
    self.reason
  }

  func open(path: in String): Result[TrustedLibrary, String] {
    if self.failOpen {
      return Err(error = "no such image: " + path)
    }
    assertTrue(Path.isAbsolute(path), "the loader is given an absolute path: " + path)
    assertTrue(path.endsWith("lib/GitTools.dll"), "the library of the trusted payload: " + path)
    val library: TrustedLibrary = self.library
    Ok(value = library)
  }
}

pub ref record CountingRead {
  var reads: Int
}

impl CapabilityProvider for CountingRead {
  func info(): CapabilityInfo {
    CapabilityInfo(id = "Editor.Api.WorkspaceRead", hasGrant = true)
  }

  func serve(method: in String, params: in Option[JsonValue], grant: in Option[JsonValue]): Result[JsonValue, RpcError] {
    self.reads = self.reads + 1
    Ok(value = json("{\"ok\":\"contents\"}"))
  }
}

// A plugin directory holding the trusted library file the payloads name.
func trustedPluginDir(label: in String): String {
  val dir = Path.join(Env.getVarOrDefault("TMPDIR", "/tmp"), "lyric_plugin_trusted_" + label)
  val _ = File.createDir(Path.join(dir, "lib"))
  match File.writeText(Path.join(Path.join(dir, "lib"), "GitTools.dll"), "not an assembly") {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write the fixture library: " + IOError.message(e))
  }
  dir
}

func withTrusted(m: in PluginManifest): PluginManifest {
  addPluginPayload(m, TrustedManagedPayload(runtime = "dotnet", library = "lib/GitTools.dll"))
}

func trustedOnly(m: in PluginManifest): PluginManifest {
  PluginManifest(
    id = m.id,
    version = m.version,
    publisher = m.publisher,
    points = m.points,
    required = m.required,
    optional = m.optional,
    payloads = [TrustedManagedPayload(runtime = "dotnet", library = "lib/GitTools.dll")]
  )
}

func trustedHost(decision: in GrantDecision, loader: in Option[TrustedLoader], read: in CountingRead): PluginHost {
  val ps: List[CapabilityProvider] = newList()
  ps.add(read)
  ps.add(NullProvider(id = "Editor.Api.Notify"))
  newPluginHost(
    PluginHostConfig(
      points = [editorPoint("1.4")],
      providers = ps,
      policy = FixedPolicy(decision = decision),
      trustedLoader = loader
    )
  )
}

func trusting(grants: in List[GrantedCapability]): GrantDecision {
  GrantDecision(allow = true, reason = "", grants = grants, trusted = true)
}

func stateOf(host: in PluginHost): PluginProcessState {
  val conns = connectionsFor(host, "Editor.Api.EditorExtension")
  assertEqualInt(conns.count, 1, "one plugin")
  match conns[0].host {
    case Some(st) -> st
    case None -> panic("a host-side connection has its state")
  }
}

func okValue(r: in Result[JsonValue, BoundaryError], label: in String): JsonValue {
  match r {
    case Ok(v) -> match getField(v, "ok") {
      case Some(x) -> x
      case None -> panic(label + ": no ok member in " + writeValue(v))
    }
    case Err(b) -> panic(label + ": " + boundaryErrorMessage(b))
  }
}

func boundaryOf(r: in Result[JsonValue, BoundaryError], label: in String): BoundaryError {
  match r {
    case Ok(v) -> panic(label + ": expected a boundary error, got " + writeValue(v))
    case Err(b) -> b
  }
}

test "registerPlugin: a trusted decision loads the trusted payload in process" {
  val dir = trustedPluginDir("loads")
  val library = FakeLibrary(servers = 0)
  val loader: TrustedLoader = FakeLoader(library = library, reason = "", failOpen = false)
  val read = CountingRead(reads = 0)
  val host = trustedHost(trusting([readGrant("[\"/a\"]")]), Some(value = loader), read)
  match registerPlugin(host, withTrusted(parseGood()), dir) {
    case Some(issue) -> assertTrue(false, "unexpected issue: " + pluginLoadIssueMessage(issue))
    case None -> ()
  }
  assertTrue(isSome(stateOf(host).trusted), "the trusted library is open")
  assertEqualInt(library.servers, 0, "no plugin code ran at load time")
  val conn = connectionsFor(host, "Editor.Api.EditorExtension")[0]
  val echoed = okValue(callPlugin(conn, "Editor.Api.EditorExtension/echo", json("{\"x\":7}")), "echo")
  assertTrue(jsonValuesEqual(echoed, json("{\"x\":7}")), "the params reach the server unchanged")
  assertEqualInt(library.servers, 1, "the first call takes a server")
  val contents = okValue(callPlugin(conn, "Editor.Api.EditorExtension/read", JNull), "read")
  assertTrue(jsonValuesEqual(contents, JString(value = "contents")), "a capability call reaches the provider")
  assertEqualInt(read.reads, 1, "the provider ran once")
  val unreported = boundaryOf(callPlugin(conn, "Editor.Api.EditorExtension/other", JNull), "unreported method")
  match unreported {
    case Unsupported(_) -> ()
    case _ -> assertTrue(
      false,
      "a method the plugin did not report is Unsupported, got " + boundaryErrorMessage(unreported)
    )
  }
}

test "trusted: revocation, restarts and stopping take effect in process" {
  val dir = trustedPluginDir("revoke")
  val library = FakeLibrary(servers = 0)
  val loader: TrustedLoader = FakeLoader(library = library, reason = "", failOpen = false)
  val read = CountingRead(reads = 0)
  val host = trustedHost(trusting([readGrant("[\"/a\"]")]), Some(value = loader), read)
  match registerPlugin(host, withTrusted(parseGood()), dir) {
    case Some(issue) -> assertTrue(false, "unexpected issue: " + pluginLoadIssueMessage(issue))
    case None -> ()
  }
  val conn = connectionsFor(host, "Editor.Api.EditorExtension")[0]
  assertTrue(
    jsonValuesEqual(okValue(callPlugin(conn, "Editor.Api.EditorExtension/count", JNull), "count"), JInt(value = 1i64)),
    "count 1"
  )
  assertTrue(
    jsonValuesEqual(okValue(callPlugin(conn, "Editor.Api.EditorExtension/count", JNull), "count"), JInt(value = 2i64)),
    "count 2"
  )
  revokeCapability(host, "acme.git-tools", "Editor.Api.WorkspaceRead")
  match callPlugin(conn, "Editor.Api.EditorExtension/read", JNull) {
    case Ok(v) -> assertTrue(false, "a revoked capability must not be served: " + writeValue(v))
    case Err(b) -> match b {
      case Revoked(c) -> assertEqual(c, "Editor.Api.WorkspaceRead", "the revoked capability")
      case _ -> assertTrue(false, "expected Revoked, got " + boundaryErrorMessage(b))
    }
  }
  assertEqualInt(read.reads, 0, "the provider never ran")
  stopPlugin(host, "acme.git-tools")
  assertTrue(
    jsonValuesEqual(okValue(callPlugin(conn, "Editor.Api.EditorExtension/count", JNull), "count"), JInt(value = 1i64)),
    "a stopped plugin starts again with fresh state"
  )
  assertEqualInt(library.servers, 2, "the restart took a new server from the same library")
}

test "registerPlugin: an untrusted plugin, or a host that cannot load, falls back to its process payload" {
  val dir = trustedPluginDir("fallback")
  val library = FakeLibrary(servers = 0)
  val loader: TrustedLoader = FakeLoader(library = library, reason = "", failOpen = false)
  val untrusted = trustedHost(allow([readGrant("[\"/a\"]")]), Some(value = loader), CountingRead(reads = 0))
  match registerPlugin(untrusted, withTrusted(parseGood()), dir) {
    case Some(issue) -> assertTrue(false, "unexpected issue: " + pluginLoadIssueMessage(issue))
    case None -> ()
  }
  assertTrue(isNone(stateOf(untrusted).trusted), "not trusted: process mode")
  assertTrue(stateOf(untrusted).launch.count > 0, "with a launch command")
  val noLoader = trustedHost(trusting([readGrant("[\"/a\"]")]), None, CountingRead(reads = 0))
  match registerPlugin(noLoader, withTrusted(parseGood()), dir) {
    case Some(issue) -> assertTrue(false, "unexpected issue: " + pluginLoadIssueMessage(issue))
    case None -> ()
  }
  assertTrue(isNone(stateOf(noLoader).trusted), "no TrustedLoader: process mode")
  val aotLoader: TrustedLoader = FakeLoader(library = library, reason = "a Native AOT host", failOpen = false)
  val aot = trustedHost(trusting([readGrant("[\"/a\"]")]), Some(value = aotLoader), CountingRead(reads = 0))
  match registerPlugin(aot, withTrusted(parseGood()), dir) {
    case Some(issue) -> assertTrue(false, "unexpected issue: " + pluginLoadIssueMessage(issue))
    case None -> ()
  }
  assertTrue(isNone(stateOf(aot).trusted), "a loader that cannot load: process mode")
  assertEqualInt(library.servers, 0, "no in-process plugin ran")
}

test "registerPlugin: trusted-only payloads need a trusting policy and a working loader" {
  val dir = trustedPluginDir("only")
  val library = FakeLibrary(servers = 0)
  val loader: TrustedLoader = FakeLoader(library = library, reason = "", failOpen = false)
  val only = trustedOnly(parseGood())
  match registerPlugin(trustedHost(allow([readGrant("[\"/a\"]")]), Some(value = loader), CountingRead(reads = 0)), only, dir) {
    case None -> assertTrue(false, "an untrusted plugin with only a trusted payload has nothing to run")
    case Some(issue) -> {
      match issue.kind {
        case NoUsablePayload -> ()
        case _ -> assertTrue(false, "expected NoUsablePayload: " + pluginLoadIssueMessage(issue))
      }
      assertTrue(issue.message.contains("did not mark it trusted"), issue.message)
    }
  }
  match registerPlugin(trustedHost(trusting([readGrant("[\"/a\"]")]), None, CountingRead(reads = 0)), only, dir) {
    case None -> assertTrue(false, "a host without a loader has nothing to run")
    case Some(issue) -> match issue.kind {
      case NoUsablePayload -> ()
      case _ -> assertTrue(false, "expected NoUsablePayload: " + pluginLoadIssueMessage(issue))
    }
  }
  val failing: TrustedLoader = FakeLoader(library = library, reason = "", failOpen = true)
  match registerPlugin(trustedHost(trusting([readGrant("[\"/a\"]")]), Some(value = failing), CountingRead(reads = 0)), withTrusted(parseGood()), dir) {
    case None -> assertTrue(false, "a library that does not load is a load issue, never a silent fallback")
    case Some(issue) -> {
      match issue.kind {
        case TrustedLoadFailed -> ()
        case _ -> assertTrue(false, "expected TrustedLoadFailed: " + pluginLoadIssueMessage(issue))
      }
      assertTrue(issue.message.contains("no such image"), issue.message)
    }
  }
  val missingDir = Path.join(Env.getVarOrDefault("TMPDIR", "/tmp"), "lyric_plugin_trusted_missing_library")
  match registerPlugin(trustedHost(trusting([readGrant("[\"/a\"]")]), Some(value = loader), CountingRead(reads = 0)), withTrusted(parseGood()), missingDir) {
    case None -> assertTrue(false, "a missing library file is a load issue")
    case Some(issue) -> assertTrue(issue.message.contains("does not exist"), issue.message)
  }
}

test "registerPlugin: a protocol plugin is never loaded in process" {
  val dir = trustedPluginDir("protocol")
  val library = FakeLibrary(servers = 0)
  val loader: TrustedLoader = FakeLoader(library = library, reason = "", failOpen = false)
  val lsp = PluginPointInfo(
    id = "Editor.Api.EditorExtension",
    version = "1.4",
    allows = ["Editor.Api.WorkspaceRead", "Editor.Api.Notify"],
    hasContributions = true,
    protocol = Some(value = "lsp/3.17")
  )
  val ps: List[CapabilityProvider] = newList()
  ps.add(CountingRead(reads = 0))
  ps.add(NullProvider(id = "Editor.Api.Notify"))
  val host = newPluginHost(
    PluginHostConfig(
      points = [lsp],
      providers = ps,
      policy = FixedPolicy(decision = trusting([readGrant("[\"/a\"]")])),
      trustedLoader = Some(value = loader)
    )
  )
  match registerPlugin(host, withTrusted(parseGood()), dir) {
    case Some(issue) -> assertTrue(false, "unexpected issue: " + pluginLoadIssueMessage(issue))
    case None -> ()
  }
  assertTrue(isNone(stateOf(host).trusted), "a protocol plugin's stdio carries its protocol")
}
