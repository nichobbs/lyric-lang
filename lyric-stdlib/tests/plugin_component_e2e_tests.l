//! tests/plugin_component_e2e_tests.l — Std.Plugin's component mode end to
//! end (docs/69 §9.3, D247): the `@plugin` package
//! `plugin_fixtures/greeter_component.l`, packed by `lyric plugin pack
//! --targets component` (so its exports, imports and type hints are generated
//! by `Lyric.PluginExpand`), hosted in this process by `Std.PluginWasm`'s
//! wasmtime runtime.
//!
//! Run by `scripts/ci/plugin-component-e2e.sh <host-target>`, which packs
//! the fixture, builds the embedding's library and fetches the wasmtime C
//! API, and points this suite at them through the environment:
//!
//!   - `LYRIC_PLUGIN_COMPONENT_DIR`: the packed artifact directory;
//!   - `LYRIC_PLUGIN_COMPONENT_FILE`: the component, relative to it;
//!   - `LYRIC_PLUGIN_COMPONENT_EXPECT`: `available` (the default), or
//!     `unavailable` for the run in which libwasmtime is deliberately absent
//!     and only the fallback is checked.
//!
//! It covers the runtime itself, discovery and payload selection, point calls
//! (union and Map results named by the component's type hints, a Map
//! argument), capability imports (granted, narrowed by the grant, a `Unit`
//! error, union and Map arguments, an optional capability not granted,
//! revoked), an unlisted method, a trap with restart and the restart limit, a
//! CPU loop stopped at the call timeout, the memory limit, and shutdown.
@test_module
package Std.Plugin.ComponentE2eTests

import Std.Core
import Std.Collections
import Std.Testing
import Std.Environment
import Std.Path
import Std.Time
import Std.JsonValue
import Std.JsonRpc
import Std.Plugin
import Std.PluginWasm

val greet: String = "Fixture.Api.Greeter/greet"

val pluginId: String = "lyric.test.greeter-component"

// ── Fixture location ───────────────────────────────────────────────────────
func fixtureVar(name: in String): String {
  match getVar(name) {
    case Ok(v) -> v
    case Err(_) -> panic(name + " is not set; run this suite through scripts/ci/plugin-component-e2e.sh")
  }
}

func fixtureDir(): String {
  fixtureVar("LYRIC_PLUGIN_COMPONENT_DIR")
}

func fixtureFile(): String {
  fixtureVar("LYRIC_PLUGIN_COMPONENT_FILE")
}

func expectAvailable(): Bool {
  getVarOrDefault("LYRIC_PLUGIN_COMPONENT_EXPECT", "available") != "unavailable"
}

record NoImports {
}

impl ComponentImports for NoImports {
  func serve(instance: in String, function: in String, paramsJson: in String): String {
    "{\"err\":{\"case\":\"Denied\",\"reason\":\"no imports while probing\"}}"
  }
}

// The text of export `name`, called straight through the runtime.
func probeExport(name: in String): String {
  val rt = inProcessWasmRuntime()
  val component = match rt.load(join(fixtureDir(), fixtureFile())) {
    case Ok(id) -> id
    case Err(e) -> panic("the runtime could not load the fixture: " + e)
  }
  val instance = match rt.instantiate(component, 67108864i64, 30000, NoImports()) {
    case Ok(id) -> id
    case Err(f) -> panic("the runtime could not start the fixture")
  }
  val envelope = rt.callExport(instance, name, "{}", 30000)
  rt.close(instance)
  rt.unload(component)
  match parseValue(envelope) {
    case Ok(v) -> match getString(v, "ok") {
      case Some(text) -> text
      case None -> panic(name + " did not answer a string: " + envelope)
    }
    case Err(_) -> panic(name + " answered no JSON envelope: " + envelope)
  }
}

// ── Host-side capabilities and policy ──────────────────────────────────────
func one(name: in String, v: in JsonValue): JsonValue {
  val fields: List[JsonField] = newList()
  fields.add(JsonField(name = name, value = v))
  JObject(fields = fields)
}

pub ref record ServeCount {
  var served: Int
}

pub record SecretsProvider {
  count: ServeCount
}

impl CapabilityProvider for SecretsProvider {
  func info(): CapabilityInfo {
    CapabilityInfo(id = "Fixture.Api.Secrets", hasGrant = true)
  }

  func serve(method: in String, params: in Option[JsonValue], grant: in Option[JsonValue]): Result[JsonValue, RpcError] {
    self.count.served = self.count.served + 1
    if method == "describe" {
      val text = match params { case Some(p) -> writeValue(p); case None -> "" }
      return Ok(value = one("ok", JString(value = text)))
    }
    if method != "read" and method != "peek" {
      return Err(error = boundaryErrorToRpc(Unsupported(method = method)))
    }
    val key = match params { case Some(p) -> unwrapOr(getString(p, "key"), ""); case None -> "" }
    if key == "boom" {
      panic("SecretsProvider: deliberate panic")
    }
    val keys = match grant { case Some(g) -> unwrapOr(getArray(g, "keys"), newList()); case None -> newList() }
    var allowed = false
    var i = 0
    while i < keys.count {
      match keys[i] {
        case JString(k) -> if k == key { allowed = true }
        case _ -> ()
      }
      i = i + 1
    }
    if method == "peek" {
      if allowed {
        Ok(value = one("ok", JBool(value = true)))
      } else {
        Ok(value = one("err", JNull))
      }
    } else if allowed {
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
    val keys: List[JsonValue] = newList()
    keys.add(JString(value = "alpha"))
    val grants: List[GrantedCapability] = newList()
    grants.add(
      GrantedCapability(capability = "Fixture.Api.Secrets", grant = Some(value = one("keys", JArray(items = keys))))
    )
    GrantDecision(allow = true, reason = "", grants = grants)
  }
}

func greeterPoint(): PluginPointInfo {
  PluginPointInfo(
    id = "Fixture.Api.Greeter",
    version = "1.0",
    allows = ["Fixture.Api.Secrets", "Fixture.Api.Net"],
    hasContributions = true,
    protocol = None
  )
}

func providers(count: in ServeCount): List[CapabilityProvider] {
  val ps: List[CapabilityProvider] = newList()
  ps.add(SecretsProvider(count = count))
  ps.add(NetProvider())
  ps
}

func newHost(count: in ServeCount, callTimeoutMs: in Int, maxRestarts: in Int): PluginHost {
  newPluginHost(
    PluginHostConfig(
      points = [greeterPoint()],
      providers = providers(count),
      policy = AlphaOnlyPolicy(),
      callTimeoutMs = callTimeoutMs,
      startTimeoutMs = 60000,
      maxRestarts = maxRestarts,
      restartBackoffMs = 50,
      wasmMaxMemoryBytes = 67108864i64,
      componentRuntime = Some(value = inProcessWasmRuntime())
    )
  )
}

// A host with the packed fixture discovered from its catalogue directory.
func discoveredHost(count: in ServeCount, callTimeoutMs: in Int, maxRestarts: in Int): PluginHost {
  val host = newHost(count, callTimeoutMs, maxRestarts)
  val issues = discoverPlugins(host, [dirname(fixtureDir())])
  var i = 0
  while i < issues.count {
    assertTrue(false, "load issue: " + pluginLoadIssueMessage(issues[i]))
    i = i + 1
  }
  assertEqualInt(pluginManifests(host).count, 1, "the fixture is catalogued")
  host
}

func conn(host: in PluginHost): PluginConnection {
  val conns = connectionsFor(host, "Fixture.Api.Greeter")
  assertEqualInt(conns.count, 1, "one connection to the greeter")
  conns[0]
}

func params(name: in String, v: in JsonValue): JsonValue {
  one(name, v)
}

func okValue(r: in Result[JsonValue, BoundaryError], label: in String): JsonValue {
  match r {
    case Err(b) -> {
      assertTrue(false, label + ": " + boundaryErrorMessage(b))
      JNull
    }
    case Ok(v) -> match getField(v, "ok") {
      case Some(ok) -> ok
      case None -> {
        assertTrue(false, label + ": expected {\"ok\": ...}, got " + writeValue(v))
        JNull
      }
    }
  }
}

func intField(v: in JsonValue, name: in String): Int {
  match getField(v, name) {
    case Some(f) -> match f { case JInt(n) -> n.toInt(); case _ -> -1 }
    case None -> -1
  }
}

func okText(r: in Result[JsonValue, BoundaryError], label: in String): String {
  match r {
    case Err(b) -> {
      assertTrue(false, label + ": " + boundaryErrorMessage(b))
      ""
    }
    case Ok(v) -> match getField(v, "ok") {
      case Some(ok) -> match ok {
        case JString(s) -> s
        case JInt(n) -> n.toString()
        case _ -> writeValue(ok)
      }
      case None -> {
        assertTrue(false, label + ": expected {\"ok\": ...}, got " + writeValue(v))
        ""
      }
    }
  }
}

func errText(r: in Result[JsonValue, BoundaryError], label: in String): String {
  match r {
    case Err(b) -> {
      assertTrue(false, label + ": " + boundaryErrorMessage(b))
      ""
    }
    case Ok(v) -> match getString(v, "err") {
      case Some(s) -> s
      case None -> {
        assertTrue(false, label + ": expected {\"err\": ...}, got " + writeValue(v))
        ""
      }
    }
  }
}

func expectCrashed(r: in Result[JsonValue, BoundaryError], label: in String): String {
  match r {
    case Ok(v) -> {
      assertTrue(false, label + ": expected Crashed, got " + writeValue(v))
      ""
    }
    case Err(b) -> match b {
      case Crashed(d) -> d
      case _ -> {
        assertTrue(false, label + ": expected Crashed, got " + boundaryErrorMessage(b))
        ""
      }
    }
  }
}

// ── Availability and fallback ───────────────────────────────────────────────
test "the in-process runtime reports whether it can run here" {
  if expectAvailable() {
    assertTrue(hasInProcessWasm(), "the embedding loads: " + inProcessWasmUnavailableReason())
    assertEqual(inProcessWasmUnavailableReason(), "", "no reason when available")
  } else {
    assertFalse(hasInProcessWasm(), "libwasmtime is absent in this run")
    assertTrue(inProcessWasmUnavailableReason().length > 0, "the reason is reported")
  }
}

test "a component-only plugin needs an available runtime, and says why it cannot load" {
  val payloads: List[PluginPayload] = [ComponentPayload(component = fixtureFile())]
  val m = PluginManifest(
    id = pluginId,
    version = "1.0.0",
    publisher = "lyric",
    points = [PluginPointDecl(point = "Fixture.Api.Greeter", version = "1.1", contributions = None)],
    required = newList(),
    optional = newList(),
    payloads = payloads
  )
  val bare = newPluginHost(
    PluginHostConfig(points = [greeterPoint()], providers = newList(), policy = GrantAllRequested())
  )
  match registerPlugin(bare, m, fixtureDir()) {
    case None -> assertTrue(false, "a host without a component runtime cannot run a component")
    case Some(issue) -> assertTrue(
      pluginLoadIssueMessage(issue).contains("componentRuntime"),
      "the issue names the missing runtime: " + pluginLoadIssueMessage(issue)
    )
  }
  if expectAvailable() {
    return
  }
  val host = newHost(ServeCount(served = 0), 30000, 3)
  match registerPlugin(host, m, fixtureDir()) {
    case None -> assertTrue(false, "an unavailable runtime cannot run a component")
    case Some(issue) -> assertTrue(
      pluginLoadIssueMessage(issue).contains("cannot run"),
      "the issue carries the runtime's reason: " + pluginLoadIssueMessage(issue)
    )
  }
}

// ── Hosting (skipped in the unavailable run) ────────────────────────────────
test "the packed component describes itself and carries its generated type hints" {
  if not expectAvailable() {
    return
  }
  match parsePluginManifest(probeExport("plugin-describe")) {
    case Ok(m) -> {
      assertEqual(m.id, pluginId, "the described id")
      assertEqualInt(m.required.count, 1, "Secrets is required")
      assertEqualInt(m.optional.count, 1, "Net is optional")
    }
    case Err(issue) -> assertTrue(false, "the described manifest is invalid: " + pluginLoadIssueMessage(issue))
  }
  val hints = match parseValue(probeExport("plugin-type-hints")) { case Ok(v) -> v; case Err(_) -> JNull }
  val exports = unwrapOr(getField(hints, "exports"), JNull)
  val shape = writeValue(unwrapOr(getField(exports, "greeter-shape"), JNull))
  assertTrue(shape.contains("\"circle\":{\"field\":\"radius\""), "the union case field is named: " + shape)
  val tally = writeValue(unwrapOr(getField(exports, "greeter-tally"), JNull))
  assertTrue(tally.contains("\"map\""), "a Map result is marked: " + tally)
  val imports = unwrapOr(getField(hints, "imports"), JNull)
  val describe = writeValue(unwrapOr(getField(imports, "fixture-api-secrets#describe"), JNull))
  assertTrue(describe.contains("\"named\":{\"field\":\"label\""), "an import's union argument: " + describe)
  assertTrue(describe.contains("\"not-granted\":{\"field\":\"capability\""), "the wire variant: " + describe)
  val peek = writeValue(unwrapOr(getField(imports, "fixture-api-secrets#peek"), JNull))
  assertFalse(peek.contains("\"app\""), "a Unit error's app case carries nothing: " + peek)
}

test "discovery selects the component payload and reads contributions without starting it" {
  if not expectAvailable() {
    return
  }
  val host = discoveredHost(ServeCount(served = 0), 30000, 3)
  val contributions = contributionsFor(host, "Fixture.Api.Greeter")
  assertEqualInt(contributions.count, 1, "one contribution")
  assertEqual(unwrapOr(getString(contributions[0].value, "greeting"), ""), "hello", "the contribution value")
  stopAllPlugins(host)
}

test "point calls run the component's exports, with union results named by its type hints" {
  if not expectAvailable() {
    return
  }
  val host = discoveredHost(ServeCount(served = 0), 30000, 3)
  val c = conn(host)
  assertEqual(okText(callPlugin(c, greet, params("name", JString(value = "Ada"))), "greet"), "hello, Ada", "greet")
  assertEqual(
    okText(callPlugin(c, greet, params("name", JString(value = "Grace"))), "greet again"),
    "hello, Grace",
    "the same instance answers again"
  )
  assertEqual(
    okText(callPlugin(c, "Fixture.Api.Greeter/shape", params("round", JBool(value = true))), "shape"),
    "{\"case\":\"Circle\",\"radius\":2.5}",
    "a union case with its Lyric field name"
  )
  assertEqual(
    okText(callPlugin(c, "Fixture.Api.Greeter/shape", params("round", JBool(value = false))), "shape"),
    "{\"case\":\"Named\",\"label\":\"square\"}",
    "the other case"
  )
  val words: List[JsonValue] = [JString(value = "a"), JString(value = "b"), JString(value = "a")]
  val tally = okValue(callPlugin(c, "Fixture.Api.Greeter/tally", params("words", JArray(items = words))), "tally")
  // Map key order is not carried (docs/69 §9.3): read the members by name.
  assertEqualInt(intField(tally, "a"), 2, "a Map result is a JSON object: " + writeValue(tally))
  assertEqualInt(intField(tally, "b"), 1, "its other member")
  val scores: List[JsonField] = newList()
  scores.add(JsonField(name = "x", value = JInt(value = 2i64)))
  scores.add(JsonField(name = "y", value = JInt(value = 3i64)))
  assertEqual(
    okText(callPlugin(c, "Fixture.Api.Greeter/total", params("scores", JObject(fields = scores))), "total"),
    "5",
    "a Map argument from a JSON object"
  )
  match callPlugin(c, greet, JObject(fields = newList())) {
    case Ok(v) -> assertTrue(false, "a missing parameter is a protocol error, got " + writeValue(v))
    case Err(b) -> match b {
      case Protocol(d) -> assertTrue(
        d.contains("missing parameter 'name'"),
        "the parameter is named: " + d
      )
      case _ -> assertTrue(false, "expected Protocol, got " + boundaryErrorMessage(b))
    }
  }
  stopAllPlugins(host)
}

test "capability imports are served from the grant: granted, narrowed, not granted and revoked" {
  if not expectAvailable() {
    return
  }
  val count = ServeCount(served = 0)
  val host = discoveredHost(count, 30000, 3)
  val c = conn(host)
  val alpha = callPlugin(c, "Fixture.Api.Greeter/secret", params("key", JString(value = "alpha")))
  assertEqual(okText(alpha, "secret alpha"), "secret-of-alpha", "a granted key")
  val beta = callPlugin(c, "Fixture.Api.Greeter/secret", params("key", JString(value = "beta")))
  assertTrue(errText(beta, "secret beta").contains("not granted"), "the grant narrowed the request to alpha")
  assertEqualInt(count.served, 2, "the provider served both calls")
  assertEqual(
    okText(callPlugin(c, "Fixture.Api.Greeter/peek", params("key", JString(value = "alpha"))), "peek alpha"),
    "visible",
    "a second method of the capability, with its own error variant"
  )
  assertEqual(
    errText(callPlugin(c, "Fixture.Api.Greeter/peek", params("key", JString(value = "gamma"))), "peek gamma"),
    "app: no such key",
    "a Unit error crosses as the bare app case"
  )
  val round = okText(callPlugin(c, "Fixture.Api.Greeter/describe", params("round", JBool(value = true))), "describe")
  assertTrue(round.contains("{\"case\":\"Circle\",\"radius\":1.5}"), "a union argument, named: " + round)
  assertTrue(round.contains("\"tags\":{\"sides\":0}"), "a Map argument as a JSON object: " + round)
  val fetch = errText(callPlugin(c, "Fixture.Api.Greeter/fetch", JObject(fields = newList())), "fetch")
  assertEqual(fetch, "net is not granted", "the optional Net was not granted, so the plugin holds no client")
  // A native host cannot contain a provider panic: native has no unwinding.
  if currentPluginPlatform().runtime != "native" {
    val boom = errText(callPlugin(c, "Fixture.Api.Greeter/secret", params("key", JString(value = "boom"))), "boom")
    assertTrue(boom.contains("contract violated"), "a provider panic fails only that import: " + boom)
  }
  revokeCapability(host, pluginId, "Fixture.Api.Secrets")
  val before = count.served
  val revoked = errText(
    callPlugin(c, "Fixture.Api.Greeter/secret", params("key", JString(value = "alpha"))),
    "revoked secret"
  )
  assertTrue(revoked.contains("revoked"), "Secrets was revoked: " + revoked)
  assertEqualInt(count.served, before, "the provider never saw the revoked call")
  stopAllPlugins(host)
}

test "a method the component did not list is Unsupported" {
  if not expectAvailable() {
    return
  }
  val host = discoveredHost(ServeCount(served = 0), 30000, 3)
  val c = conn(host)
  match callPlugin(c, "Fixture.Api.Greeter/missing", JObject(fields = newList())) {
    case Ok(v) -> assertTrue(false, "expected Unsupported, got " + writeValue(v))
    case Err(b) -> match b {
      case Unsupported(m) -> assertEqual(m, "Fixture.Api.Greeter/missing", "the method")
      case _ -> assertTrue(false, "expected Unsupported, got " + boundaryErrorMessage(b))
    }
  }
  stopAllPlugins(host)
}

test "a trap is Crashed, the next call re-instantiates, up to maxRestarts" {
  if not expectAvailable() {
    return
  }
  val host = discoveredHost(ServeCount(served = 0), 30000, 1)
  val c = conn(host)
  assertEqual(okText(callPlugin(c, "Fixture.Api.Greeter/count", JNull), "count 1"), "1", "first count")
  assertEqual(okText(callPlugin(c, "Fixture.Api.Greeter/count", JNull), "count 2"), "2", "the same instance")
  val trap = expectCrashed(callPlugin(c, "Fixture.Api.Greeter/crash", JNull), "crash")
  assertTrue(trap.contains("trapped"), "the trap is reported: " + trap)
  assertEqual(
    okText(callPlugin(c, "Fixture.Api.Greeter/count", JNull), "count after restart"),
    "1",
    "a fresh instance after the restart"
  )
  val _ = expectCrashed(callPlugin(c, "Fixture.Api.Greeter/crash", JNull), "second crash")
  val limit = expectCrashed(callPlugin(c, "Fixture.Api.Greeter/count", JNull), "after the limit")
  assertTrue(limit.contains("restarts allowed"), "the limit is named: " + limit)
  stopAllPlugins(host)
}

test "a CPU loop is stopped at the call timeout, and the next call gets a fresh instance" {
  if not expectAvailable() {
    return
  }
  val host = discoveredHost(ServeCount(served = 0), 1500, 0)
  val c = conn(host)
  assertEqual(okText(callPlugin(c, "Fixture.Api.Greeter/count", JNull), "count"), "1", "started")
  val start = monotonicNanos()
  match callPlugin(c, "Fixture.Api.Greeter/spin", JNull) {
    case Ok(v) -> assertTrue(false, "expected a timeout, got " + writeValue(v))
    case Err(b) -> match b {
      case Timeout(ms) -> assertEqualInt(ms, 1500, "the host's call timeout")
      case _ -> assertTrue(false, "expected Timeout, got " + boundaryErrorMessage(b))
    }
  }
  val waited = (monotonicNanos() - start) / 1000000i64
  println("# timeout: a 1500 ms call timeout stopped the component's loop after " + waited.toString() + " ms")
  assertTrue(waited >= 1400i64 and waited < 3500i64, "the loop stopped at its deadline (" + waited.toString() + " ms)")
  // The guest ran on this thread, so the call returning is the loop having
  // stopped; the next call needs a new instance (count starts again), and a
  // timeout is not a crash, so maxRestarts = 0 does not end the plugin.
  val after = monotonicNanos()
  assertEqual(okText(callPlugin(c, "Fixture.Api.Greeter/count", JNull), "count after"), "1", "a fresh instance")
  val restartMs = (monotonicNanos() - after) / 1000000i64
  assertTrue(restartMs < 1400i64, "the new instance answers at once (" + restartMs.toString() + " ms)")
  stopAllPlugins(host)
}

test "linear memory is capped at wasmMaxMemoryBytes" {
  if not expectAvailable() {
    return
  }
  val host = discoveredHost(ServeCount(served = 0), 30000, 3)
  val c = conn(host)
  assertEqual(
    okText(callPlugin(c, "Fixture.Api.Greeter/hog", params("megabytes", JInt(value = 8i64))), "hog 8"),
    "8",
    "8 MiB fits"
  )
  val oom = expectCrashed(
    callPlugin(c, "Fixture.Api.Greeter/hog", params("megabytes", JInt(value = 256i64))),
    "hog 256"
  )
  println("# memory: growing to 256 MiB under a 64 MiB cap ended the call: " + oom)
  assertEqual(okText(callPlugin(c, "Fixture.Api.Greeter/count", JNull), "count"), "1", "a fresh instance after it")
  stopAllPlugins(host)
}

test "stopPlugin unloads the component, and the next call starts it again" {
  if not expectAvailable() {
    return
  }
  val host = discoveredHost(ServeCount(served = 0), 30000, 3)
  val c = conn(host)
  assertEqual(okText(callPlugin(c, "Fixture.Api.Greeter/count", JNull), "count"), "1", "first count")
  assertEqual(okText(callPlugin(c, "Fixture.Api.Greeter/count", JNull), "count"), "2", "second count")
  stopPlugin(host, pluginId)
  assertEqual(okText(callPlugin(c, "Fixture.Api.Greeter/count", JNull), "count after stop"), "1", "a new instance")
  stopAllPlugins(host)
}
