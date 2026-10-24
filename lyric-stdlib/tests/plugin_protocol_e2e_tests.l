//! tests/plugin_protocol_e2e_tests.l — Std.Plugin protocol points end to
//! end (docs/69 §4.3): a supervised `ProtocolSession` with a real plugin
//! process, `plugin_fixtures/echo_protocol_plugin.l`, which speaks a line
//! protocol of its own.
//!
//! Run by `scripts/ci/plugin-protocol-e2e.sh <host-target> <plugin-target>`,
//! which builds the fixture and points this suite at it through
//! `LYRIC_PLUGIN_FIXTURE_DIR`, `LYRIC_PLUGIN_FIXTURE_RUNTIME` and
//! `LYRIC_PLUGIN_FIXTURE_FILE`, as `plugin_e2e_tests.l` does.
//!
//! Covered: opening a session and speaking the protocol, the generation
//! counter, a crash and its restart, the restart limit, a deliberate close
//! that is not counted, `stopPlugin`, refusing `callPlugin` and a second
//! session, the one-point rule for protocol plugins, and `callCapabilityAs`
//! (granted, narrowed by the grant, not granted, revoked, unknown plugin).
@test_module
package Std.Plugin.ProtocolE2eTests

import Std.Core
import Std.Collections
import Std.Testing
import Std.Environment
import Std.Process
import Std.JsonValue
import Std.JsonRpc
import Std.Plugin

val echoPoint: String = "Fixture.Api.Echo"

val pluginId: String = "fixture.echo"

// ── Fixture location ───────────────────────────────────────────────────────
func fixtureVar(name: in String): String {
  match getVar(name) {
    case Ok(v) -> v
    case Err(_) -> panic(name + " is not set; run this suite through scripts/ci/plugin-protocol-e2e.sh")
  }
}

func fixtureDir(): String {
  fixtureVar("LYRIC_PLUGIN_FIXTURE_DIR")
}

func fixturePayload(): PluginPayload {
  val runtime = fixtureVar("LYRIC_PLUGIN_FIXTURE_RUNTIME")
  val file = fixtureVar("LYRIC_PLUGIN_FIXTURE_FILE")
  if runtime == "dotnet" {
    ManagedPayload(runtime = "dotnet", command = ["dotnet", "exec", file])
  } else if runtime == "jvm" {
    ManagedPayload(runtime = "jvm", command = ["java", "-jar", file])
  } else if runtime == "wasm" {
    WasmPayload(wasmModule = file)
  } else {
    val p = currentPluginPlatform()
    NativePayload(os = p.os, arch = p.arch, command = [file])
  }
}

// ── Host-side capabilities and policy ──────────────────────────────────────
func one(name: in String, v: in JsonValue): JsonValue {
  val fields: List[JsonField] = newList()
  fields.add(JsonField(name = name, value = v))
  JObject(fields = fields)
}

func keys(names: in List[String]): JsonValue {
  val items: List[JsonValue] = newList()
  for n in names {
    items.add(JString(value = n))
  }
  one("keys", JArray(items = items))
}

pub record SecretsProvider {
}

impl CapabilityProvider for SecretsProvider {
  func info(): CapabilityInfo {
    CapabilityInfo(id = "Fixture.Api.Secrets", hasGrant = true)
  }

  func serve(method: in String, params: in Option[JsonValue], grant: in Option[JsonValue]): Result[JsonValue, RpcError] {
    if method != "read" {
      return Err(error = boundaryErrorToRpc(Unsupported(method = method)))
    }
    val key = match params { case Some(p) -> unwrapOr(getString(p, "key"), ""); case None -> "" }
    val granted = match grant { case Some(g) -> unwrapOr(getArray(g, "keys"), newList()); case None -> newList() }
    var allowed = false
    for k in granted {
      match k {
        case JString(s) -> if s == key { allowed = true }
        case _ -> ()
      }
    }
    if allowed {
      Ok(value = one("ok", JString(value = "secret-of-" + key)))
    } else {
      Ok(value = one("err", JString(value = "key '" + key + "' is not granted")))
    }
  }
}

pub record NetProvider {
}

impl CapabilityProvider for NetProvider {
  func info(): CapabilityInfo {
    CapabilityInfo(id = "Fixture.Api.Net", hasGrant = false)
  }

  func serve(method: in String, params: in Option[JsonValue], grant: in Option[JsonValue]): Result[JsonValue, RpcError] {
    Ok(value = one("ok", JString(value = "fetched")))
  }
}

// Grants Secrets narrowed to key "alpha"; does not grant Net.
pub record AlphaOnlyPolicy {
}

impl GrantPolicy for AlphaOnlyPolicy {
  func decide(manifest: in PluginManifest): GrantDecision {
    val grants: List[GrantedCapability] = newList()
    grants.add(GrantedCapability(capability = "Fixture.Api.Secrets", grant = Some(value = keys(["alpha"]))))
    GrantDecision(allow = true, reason = "", grants = grants)
  }
}

func echoPointInfo(): PluginPointInfo {
  PluginPointInfo(
    id = echoPoint,
    version = "1.0",
    allows = ["Fixture.Api.Secrets", "Fixture.Api.Net"],
    hasContributions = false,
    protocol = Some(value = "echo/1")
  )
}

func otherPointInfo(): PluginPointInfo {
  PluginPointInfo(id = "Fixture.Api.Other", version = "1.0", allows = [], hasContributions = false, protocol = None)
}

func newHost(maxRestarts: in Int): PluginHost {
  val ps: List[CapabilityProvider] = newList()
  ps.add(SecretsProvider())
  ps.add(NetProvider())
  newPluginHost(
    PluginHostConfig(
      points = [echoPointInfo(), otherPointInfo()],
      providers = ps,
      policy = AlphaOnlyPolicy(),
      callTimeoutMs = 60000,
      startTimeoutMs = 60000,
      maxRestarts = maxRestarts,
      restartBackoffMs = 50,
      shutdownGraceMs = 10000
    )
  )
}

func echoManifest(points: in List[PluginPointDecl]): PluginManifest {
  PluginManifest(
    id = pluginId,
    version = "1.0.0",
    publisher = "fixture",
    points = points,
    required = [CapabilityRequest(name = "Fixture.Api.Secrets", grant = Some(value = keys(["alpha", "beta"])))],
    optional = [CapabilityRequest(name = "Fixture.Api.Net", grant = None)],
    payloads = [fixturePayload()]
  )
}

func echoDecl(): PluginPointDecl {
  PluginPointDecl(point = echoPoint, version = "1.0", contributions = None)
}

func registeredHost(maxRestarts: in Int): PluginHost {
  val host = newHost(maxRestarts)
  match registerPlugin(host, echoManifest([echoDecl()]), fixtureDir()) {
    case Some(issue) -> assertTrue(false, "load issue: " + pluginLoadIssueMessage(issue))
    case None -> ()
  }
  host
}

func open(host: in PluginHost): ProtocolSession {
  match openProtocolSession(host, echoPoint, pluginId) {
    case Ok(s) -> s
    case Err(b) -> panic("openProtocolSession: " + boundaryErrorMessage(b))
  }
}

func process(session: in ProtocolSession): PipedProcess {
  match protocolProcess(session) {
    case Ok(p) -> p
    case Err(b) -> panic("protocolProcess: " + boundaryErrorMessage(b))
  }
}

// Send `ping <text>` and return the answer line.
func ping(session: in ProtocolSession, text: in String): String {
  val proc = process(session)
  match pipedWriteLine(proc, "ping " + text) {
    case Ok(_) -> ()
    case Err(e) -> panic("write: " + e)
  }
  match pipedReadLineWithin(proc, 60000) {
    case Ok(o) -> match o {
      case PipedLine(l) -> l
      case PipedEndOfStream -> "<end of stream>"
      case PipedTimedOut -> "<timed out>"
    }
    case Err(e) -> "<read failed: " + e + ">"
  }
}

// Ask the plugin to crash and wait until its process has gone.
func crash(session: in ProtocolSession): Unit {
  val proc = process(session)
  val _ = pipedWriteLine(proc, "crash")
  assertTrue(pipedWaitExit(proc, 60000), "the plugin exits after crash")
}

func isProtocolError(r: in Result[JsonValue, BoundaryError]): Bool {
  match r {
    case Err(b) -> match b { case Protocol(_) -> true; case _ -> false }
    case Ok(_) -> false
  }
}

// ── Sessions ───────────────────────────────────────────────────────────────
test "a session starts the plugin and carries its protocol" {
  val host = registeredHost(3)
  val session = open(host)
  assertEqualInt(session.generation, 1, "the first start is generation 1")
  assertEqual(ping(session, "one"), "pong one", "first exchange")
  assertEqual(ping(session, "two"), "pong two", "second exchange on the same process")
  assertEqualInt(session.generation, 1, "no restart while the process runs")
  closeProtocolSession(session)
}

test "a crashed protocol plugin restarts with a new generation" {
  val host = registeredHost(3)
  val session = open(host)
  crash(session)
  assertEqual(ping(session, "after"), "pong after", "the restarted process answers")
  assertEqualInt(session.generation, 2, "the restart is generation 2")
  closeProtocolSession(session)
}

test "a protocol plugin that keeps crashing stops at the restart limit" {
  val host = registeredHost(1)
  val session = open(host)
  crash(session)
  assertEqual(ping(session, "x"), "pong x", "one restart is allowed")
  crash(session)
  match protocolProcess(session) {
    case Ok(_) -> assertTrue(false, "a second crash exceeds maxRestarts = 1")
    case Err(b) -> match b {
      case Crashed(detail) -> assertTrue(detail.length > 0, "the error says why")
      case _ -> assertTrue(false, "expected Crashed, got " + boundaryErrorMessage(b))
    }
  }
  match openProtocolSession(host, echoPoint, pluginId) {
    case Ok(_) -> assertTrue(false, "a plugin past its restart limit stays stopped")
    case Err(_) -> ()
  }
}

test "closing a session is not a crash" {
  val host = registeredHost(0)
  val session = open(host)
  var i = 0
  while i < 3 {
    closeProtocolSession(session)
    assertEqual(ping(session, i.toString()), "pong " + i.toString(), "the plugin starts again after close")
    i = i + 1
  }
  assertEqualInt(session.generation, 4, "each start after a close is a new generation")
  closeProtocolSession(session)
}

test "stopPlugin stops a session's process" {
  val host = registeredHost(3)
  val session = open(host)
  assertEqual(ping(session, "before"), "pong before", "the plugin runs")
  stopPlugin(host, pluginId)
  assertEqual(ping(session, "back"), "pong back", "the session starts it again")
  assertEqualInt(session.generation, 2, "the start after stopPlugin is a new process")
  closeProtocolSession(session)
}

test "a protocol point refuses callPlugin and a second session" {
  val host = registeredHost(3)
  val conns = connectionsFor(host, echoPoint)
  assertEqualInt(conns.count, 1, "the protocol plugin is catalogued")
  assertTrue(isProtocolError(callPlugin(conns[0], echoPoint + "/ping", JNull)), "callPlugin on a protocol point")
  val session = open(host)
  match openProtocolSession(host, echoPoint, pluginId) {
    case Ok(_) -> assertTrue(false, "a second session on a running plugin")
    case Err(b) -> match b {
      case Protocol(_) -> ()
      case _ -> assertTrue(false, "expected Protocol, got " + boundaryErrorMessage(b))
    }
  }
  closeProtocolSession(session)
}

test "a protocol plugin implements its protocol point only" {
  val host = newHost(3)
  val other = PluginPointDecl(point = "Fixture.Api.Other", version = "1.0", contributions = None)
  match registerPlugin(host, echoManifest([echoDecl(), other]), fixtureDir()) {
    case None -> assertTrue(false, "a protocol plugin with a second point loads")
    case Some(issue) -> assertEqual(
      pluginIssueCode(issue.kind),
      pluginIssueCode(ManifestInvalid),
      "rejected as an invalid manifest"
    )
  }
}

// ── Capability routing ─────────────────────────────────────────────────────
test "callCapabilityAs applies the plugin's grant" {
  val host = registeredHost(3)
  match callCapabilityAs(host, pluginId, "Fixture.Api.Secrets/read", one("key", JString(value = "alpha"))) {
    case Ok(v) -> assertEqual(unwrapOr(getString(v, "ok"), "<none>"), "secret-of-alpha", "a granted key")
    case Err(b) -> assertTrue(false, "granted call: " + boundaryErrorMessage(b))
  }
  match callCapabilityAs(host, pluginId, "cap/Fixture.Api.Secrets/read", one("key", JString(value = "beta"))) {
    case Ok(v) -> assertTrue(isSome(getString(v, "err")), "a key outside the grant is the provider's error")
    case Err(b) -> assertTrue(false, "narrowed call: " + boundaryErrorMessage(b))
  }
}

test "callCapabilityAs refuses what the plugin was not granted" {
  val host = registeredHost(3)
  match callCapabilityAs(host, pluginId, "Fixture.Api.Net/fetch", JObject(fields = [])) {
    case Ok(v) -> assertTrue(false, "Net is not granted, got " + writeValue(v))
    case Err(b) -> match b {
      case Denied(_) -> ()
      case _ -> assertTrue(false, "expected Denied, got " + boundaryErrorMessage(b))
    }
  }
  revokeCapability(host, pluginId, "Fixture.Api.Secrets")
  match callCapabilityAs(host, pluginId, "Fixture.Api.Secrets/read", one("key", JString(value = "alpha"))) {
    case Ok(v) -> assertTrue(false, "a revoked capability answered " + writeValue(v))
    case Err(b) -> match b {
      case Revoked(c) -> assertEqual(c, "Fixture.Api.Secrets", "the revoked capability is named")
      case _ -> assertTrue(false, "expected Revoked, got " + boundaryErrorMessage(b))
    }
  }
  match callCapabilityAs(host, "no.such-plugin", "Fixture.Api.Secrets/read", JObject(fields = [])) {
    case Ok(_) -> assertTrue(false, "an unknown plugin")
    case Err(b) -> match b {
      case Unsupported(_) -> ()
      case _ -> assertTrue(false, "expected Unsupported, got " + boundaryErrorMessage(b))
    }
  }
}
