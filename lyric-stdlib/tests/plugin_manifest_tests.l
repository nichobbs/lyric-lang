//! tests/plugin_manifest_tests.l — Std.Plugin without child processes:
//! manifest parsing and validation (every rejection), the manifest round
//! trip, the Q-PLG-004 grant rule, payload selection and launch commands,
//! loading plugins into a host (`registerPlugin` and every load issue), and
//! the BoundaryError <-> JSON-RPC error mapping. The end-to-end suite with
//! a real plugin process is `plugin_e2e_tests.l`.
@test_module
package Std.Plugin.ManifestTests

import Std.Core
import Std.Collections
import Std.Testing
import Std.JsonValue
import Std.JsonRpc
import Std.Plugin

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
      case NativePayload(os, arch, _) -> "native-" + os + "-" + arch
      case ManagedPayload(runtime, _) -> runtime
    }
  }
}

test "payload selection order" {
  val all = parseGood().payloads
  assertEqual(
    describePayload(selectPluginPayload(all, linuxDotnet(), true, true)),
    "wasm",
    "wasm preferred and available"
  )
  assertEqual(
    describePayload(selectPluginPayload(all, linuxDotnet(), true, false)),
    "native-linux-x86_64",
    "no wasmtime: native"
  )
  assertEqual(
    describePayload(selectPluginPayload(all, linuxDotnet(), false, true)),
    "native-linux-x86_64",
    "wasm not preferred: native"
  )
  val mac = PluginPlatform(os = "macos", arch = "aarch64", runtime = "jvm")
  assertEqual(
    describePayload(selectPluginPayload(all, mac, false, false)),
    "jvm",
    "no native for the platform: own runtime first"
  )
  val macDotnet = PluginPlatform(os = "macos", arch = "aarch64", runtime = "dotnet")
  assertEqual(
    describePayload(selectPluginPayload(all, macDotnet, false, false)),
    "dotnet",
    "dotnet host: dotnet payload"
  )
  val nativeHost = PluginPlatform(os = "macos", arch = "aarch64", runtime = "native")
  assertEqual(
    describePayload(selectPluginPayload(all, nativeHost, false, false)),
    "dotnet",
    "native host: dotnet before jvm"
  )
  val wasmOnly: List[PluginPayload] = [WasmPayload(wasmModule = "p.wasm")]
  assertEqual(
    describePayload(selectPluginPayload(wasmOnly, linuxDotnet(), false, true)),
    "wasm",
    "wasm as a last resort"
  )
  assertEqual(
    describePayload(selectPluginPayload(wasmOnly, linuxDotnet(), true, false)),
    "none",
    "wasm only, no wasmtime"
  )
  val none: List[PluginPayload] = newList()
  assertEqual(describePayload(selectPluginPayload(none, linuxDotnet(), true, true)), "none", "no payloads")
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
