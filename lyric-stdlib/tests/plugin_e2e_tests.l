//! tests/plugin_e2e_tests.l — Std.Plugin end to end, with a real plugin
//! process: the hand-written `plugin_fixtures/greeter_plugin.l`.
//!
//! Run by `scripts/ci/plugin-e2e.sh <host-target> <plugin-target>`, which
//! builds the fixture into its own plugin directory and points this suite at
//! it through the environment:
//!
//!   - `LYRIC_PLUGIN_FIXTURE_DIR`: the plugin directory;
//!   - `LYRIC_PLUGIN_FIXTURE_RUNTIME`: `dotnet`, `jvm`, `native` or `wasm`
//!     (a wasm32-wasi module run under `wasmtime`, found on PATH or at
//!     `$LYRIC_WASMTIME`);
//!   - `LYRIC_PLUGIN_FIXTURE_FILE`: the payload, relative to the directory.
//!
//! The suite probes the payload with `--lyric-plugin-manifest`, adds the
//! payload, writes `plugin.json`, and then drives the protocol: discovery,
//! the handshake, point calls, capability calls back into the host (granted,
//! narrowed by the grant, not granted, revoked), an unlisted method, a
//! plugin refusing the handshake, a timeout, a crash with restart and the
//! restart limit, and shutdown.
@test_module
package Std.Plugin.E2eTests

import Std.Core
import Std.Collections
import Std.Testing
import Std.Environment
import Std.File
import Std.Path
import Std.Process
import Std.Time
import Std.JsonValue
import Std.JsonRpc
import Std.Plugin

val greet: String = "Fixture.Api.Greeter/greet"

// ── Fixture location ───────────────────────────────────────────────────────
func fixtureVar(name: in String): String {
  match getVar(name) {
    case Ok(v) -> v
    case Err(_) -> panic(name + " is not set; run this suite through scripts/ci/plugin-e2e.sh")
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

// The fixture's manifest: what the plugin prints for `--lyric-plugin-manifest`,
// plus the payload under test.
func probedManifest(): PluginManifest {
  val argv = match pluginLaunchCommand(fixturePayload(), fixtureDir(), findWasmtime(), 268435456i64) {
    case Ok(a) -> a
    case Err(e) -> panic("launch command: " + e)
  }
  val args: List[String] = newList()
  var i = 1
  while i < argv.count {
    args.add(argv[i])
    i = i + 1
  }
  args.add("--lyric-plugin-manifest")
  val probe = match runCapture(argv[0], args, 60000) {
    case Ok(r) -> r
    case Err(e) -> panic("could not run the manifest probe: " + e)
  }
  assertEqualInt(probe.exitCode, 0, "the manifest probe exits 0")
  match parsePluginManifest(probe.stdout) {
    case Ok(m) -> addPluginPayload(m, fixturePayload())
    case Err(issue) -> panic("the probed manifest is invalid: " + pluginLoadIssueMessage(issue))
  }
}

func writeManifest(): Unit {
  match writeText(join(fixtureDir(), "plugin.json"), writeValue(pluginManifestToJson(probedManifest()))) {
    case Ok(_) -> ()
    case Err(e) -> panic("could not write plugin.json: " + IOError.message(e))
  }
}

// ── Host-side capabilities and policy ──────────────────────────────────────
func one(name: in String, v: in JsonValue): JsonValue {
  val fields: List[JsonField] = newList()
  fields.add(JsonField(name = name, value = v))
  JObject(fields = fields)
}

pub record SecretsProvider {
  var served: Int
}

impl CapabilityProvider for SecretsProvider {
  func info(): CapabilityInfo {
    CapabilityInfo(id = "Fixture.Api.Secrets", hasGrant = true)
  }

  func serve(method: in String, params: in Option[JsonValue], grant: in Option[JsonValue]): Result[JsonValue, RpcError] {
    self.served = self.served + 1
    if method != "read" {
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

func providers(secrets: in SecretsProvider): List[CapabilityProvider] {
  val ps: List[CapabilityProvider] = newList()
  ps.add(secrets)
  ps.add(NetProvider())
  ps
}

func newHost(secrets: in SecretsProvider, callTimeoutMs: in Int, maxRestarts: in Int): PluginHost {
  newPluginHost(
    PluginHostConfig(
      points = [greeterPoint()],
      providers = providers(secrets),
      policy = AlphaOnlyPolicy(),
      callTimeoutMs = callTimeoutMs,
      startTimeoutMs = 60000,
      maxRestarts = maxRestarts,
      restartBackoffMs = 50,
      shutdownGraceMs = 10000
    )
  )
}

// A host with the fixture discovered from its catalogue directory.
func discoveredHost(secrets: in SecretsProvider, callTimeoutMs: in Int, maxRestarts: in Int): PluginHost {
  writeManifest()
  val host = newHost(secrets, callTimeoutMs, maxRestarts)
  val issues = discoverPlugins(host, [dirname(fixtureDir()), join(fixtureDir(), "no-such-directory")])
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

// The `ok` member of a successful call's result, as a string.
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

// ── The suite ───────────────────────────────────────────────────────────────
test "discovery reads the catalogue and contributions without starting anything" {
  val host = discoveredHost(SecretsProvider(served = 0), 30000, 3)
  val contributions = contributionsFor(host, "Fixture.Api.Greeter")
  assertEqualInt(contributions.count, 1, "one contribution")
  assertEqual(unwrapOr(getString(contributions[0].value, "greeting"), ""), "hello", "the contribution value")
  stopAllPlugins(host)
}

test "discovery reports a broken manifest, skips a directory without one, and loads the rest" {
  writeManifest()
  val root = dirname(fixtureDir())
  val broken = join(root, "broken")
  val empty = join(root, "empty")
  match createDir(broken) {
    case Ok(_) -> ()
    case Err(e) -> panic("createDir: " + IOError.message(e))
  }
  match createDir(empty) {
    case Ok(_) -> ()
    case Err(e) -> panic("createDir: " + IOError.message(e))
  }
  match writeText(join(broken, "plugin.json"), "{\"schema\":1,\"id\":\"x.broken\"}") {
    case Ok(_) -> ()
    case Err(e) -> panic("writeText: " + IOError.message(e))
  }
  val host = newHost(SecretsProvider(served = 0), 30000, 3)
  val issues = discoverPlugins(host, [root])
  val _ = deleteDirRecursive(broken)
  val _ = deleteDirRecursive(empty)
  assertEqualInt(issues.count, 1, "one issue, for the broken manifest")
  match issues[0].kind {
    case ManifestInvalid -> ()
    case _ -> assertTrue(false, "a broken manifest is ManifestInvalid: " + pluginLoadIssueMessage(issues[0]))
  }
  assertEqual(issues[0].location, broken, "the issue names the directory")
  assertEqual(issues[0].pluginId, "x.broken", "the issue names the plugin id it read")
  assertEqualInt(pluginManifests(host).count, 1, "the greeter still loads")
  stopAllPlugins(host)
}

test "handshake and a point call" {
  val host = discoveredHost(SecretsProvider(served = 0), 30000, 3)
  val c = conn(host)
  assertEqual(okText(callPlugin(c, greet, params("name", JString(value = "Ada"))), "greet"), "hello, Ada", "greet")
  assertEqual(
    okText(callPlugin(c, greet, params("name", JString(value = "Grace"))), "greet again"),
    "hello, Grace",
    "the same process answers again"
  )
  stopAllPlugins(host)
}

test "capability calls back into the host, within the narrowed grant" {
  val secrets = SecretsProvider(served = 0)
  val host = discoveredHost(secrets, 30000, 3)
  val c = conn(host)
  val alpha = callPlugin(c, "Fixture.Api.Greeter/secret", params("key", JString(value = "alpha")))
  assertEqual(okText(alpha, "secret alpha"), "secret-of-alpha", "a granted key")
  val beta = callPlugin(c, "Fixture.Api.Greeter/secret", params("key", JString(value = "beta")))
  assertTrue(errText(beta, "secret beta").contains("not granted"), "the grant narrowed the request to alpha")
  assertEqualInt(secrets.served, 2, "the provider served both calls")
  // A native host cannot contain a provider panic: native has no unwinding,
  // so a panic ends the process (D-N-003, `_kernel_native/panic_guard_host.l`).
  if currentPluginPlatform().runtime == "native" {
    stopAllPlugins(host)
    return
  }
  val boom = errText(callPlugin(c, "Fixture.Api.Greeter/secret", params("key", JString(value = "boom"))), "secret boom")
  assertTrue(boom.contains("contract violated"), "a provider panic fails only that capability call: " + boom)
  assertEqual(
    okText(callPlugin(c, "Fixture.Api.Greeter/secret", params("key", JString(value = "alpha"))), "after boom"),
    "secret-of-alpha",
    "the host keeps serving"
  )
  stopAllPlugins(host)
}

test "a capability that is not granted is denied, and a revoked one is revoked" {
  val secrets = SecretsProvider(served = 0)
  val host = discoveredHost(secrets, 30000, 3)
  val c = conn(host)
  val fetch = errText(callPlugin(c, "Fixture.Api.Greeter/fetch", JObject(fields = newList())), "fetch")
  assertTrue(fetch.contains("denied"), "Net is not granted: " + fetch)
  revokeCapability(host, "lyric.test.greeter", "Fixture.Api.Secrets")
  val revoked = errText(
    callPlugin(c, "Fixture.Api.Greeter/secret", params("key", JString(value = "alpha"))),
    "revoked secret"
  )
  assertTrue(revoked.contains("revoked"), "Secrets was revoked: " + revoked)
  assertEqualInt(secrets.served, 0, "the provider never saw a call")
  stopAllPlugins(host)
}

test "a method the plugin did not list is Unsupported" {
  val host = discoveredHost(SecretsProvider(served = 0), 30000, 3)
  val c = conn(host)
  match callPlugin(c, "Fixture.Api.Greeter/missing", JObject(fields = newList())) {
    case Ok(v) -> assertTrue(false, "expected Unsupported, got " + writeValue(v))
    case Err(b) -> match b {
      case Unsupported(m) -> assertEqual(m, "Fixture.Api.Greeter/missing", "the method")
      case _ -> assertTrue(false, "expected Unsupported, got " + boundaryErrorMessage(b))
    }
  }
  match callPlugin(c, "Other.Api.Point/greet", JObject(fields = newList())) {
    case Ok(_) -> assertTrue(false, "a point the plugin does not implement here")
    case Err(b) -> match b {
      case Unsupported(_) -> ()
      case _ -> assertTrue(false, "expected Unsupported, got " + boundaryErrorMessage(b))
    }
  }
  stopAllPlugins(host)
}

test "a plugin registered outside a catalogue, which refuses the handshake without its capability" {
  val m = probedManifest()
  // Drop the required capability from the manifest the host reads: the host
  // grants nothing, and the plugin refuses plugin/hello with NotGranted.
  val stripped = PluginManifest(
    id = m.id,
    version = m.version,
    publisher = m.publisher,
    points = m.points,
    required = newList(),
    optional = m.optional,
    payloads = m.payloads
  )
  val host = newPluginHost(
    PluginHostConfig(
      points = [greeterPoint()],
      providers = providers(SecretsProvider(served = 0)),
      policy = GrantAllRequested()
    )
  )
  match registerPlugin(host, stripped, fixtureDir()) {
    case Some(issue) -> assertTrue(false, "unexpected issue: " + pluginLoadIssueMessage(issue))
    case None -> ()
  }
  val c = conn(host)
  match callPlugin(c, greet, params("name", JString(value = "Ada"))) {
    case Ok(v) -> assertTrue(false, "expected NotGranted, got " + writeValue(v))
    case Err(b) -> match b {
      case NotGranted(cap) -> assertEqual(cap, "Fixture.Api.Secrets", "the missing capability")
      case _ -> assertTrue(false, "expected NotGranted, got " + boundaryErrorMessage(b))
    }
  }
  match callPlugin(c, greet, params("name", JString(value = "Ada"))) {
    case Ok(_) -> assertTrue(false, "a refused handshake is final")
    case Err(b) -> match b {
      case NotGranted(_) -> ()
      case _ -> assertTrue(false, "expected NotGranted again, got " + boundaryErrorMessage(b))
    }
  }
  stopAllPlugins(host)

  val full = newPluginHost(
    PluginHostConfig(
      points = [greeterPoint()],
      providers = providers(SecretsProvider(served = 0)),
      policy = GrantAllRequested()
    )
  )
  match registerPlugin(full, m, fixtureDir()) {
    case Some(issue) -> assertTrue(false, "unexpected issue: " + pluginLoadIssueMessage(issue))
    case None -> ()
  }
  assertEqual(
    okText(callPlugin(conn(full), greet, params("name", JString(value = "Lin"))), "registered greet"),
    "hello, Lin",
    "registered plugin"
  )
  stopAllPlugins(full)
}

test "a call that outlives the call timeout times out, and the plugin keeps serving" {
  val host = discoveredHost(SecretsProvider(served = 0), 1500, 3)
  val c = conn(host)
  assertEqual(
    okText(callPlugin(c, greet, params("name", JString(value = "warm"))), "warm up"),
    "hello, warm",
    "started"
  )
  val start = monotonicNanos()
  match callPlugin(c, "Fixture.Api.Greeter/slow", params("ms", JInt(value = 4000i64))) {
    case Ok(v) -> assertTrue(false, "expected a timeout, got " + writeValue(v))
    case Err(b) -> match b {
      case Timeout(ms) -> assertEqualInt(ms, 1500, "the host's call timeout")
      case _ -> assertTrue(false, "expected Timeout, got " + boundaryErrorMessage(b))
    }
  }
  val waited = (monotonicNanos() - start) / 1000000i64
  assertTrue(waited >= 1400i64 and waited < 3500i64, "the call ended at its deadline (" + waited.toString() + " ms)")
  sleepMillis(3500)
  assertEqual(
    okText(callPlugin(c, greet, params("name", JString(value = "later"))), "after timeout"),
    "hello, later",
    "the late answer was dropped"
  )
  stopAllPlugins(host)
}

test "a crashed plugin restarts on the next call, up to maxRestarts" {
  val host = discoveredHost(SecretsProvider(served = 0), 30000, 1)
  val c = conn(host)
  assertEqual(okText(callPlugin(c, "Fixture.Api.Greeter/count", JNull), "count 1"), "1", "first count")
  assertEqual(okText(callPlugin(c, "Fixture.Api.Greeter/count", JNull), "count 2"), "2", "the same process")
  match callPlugin(c, "Fixture.Api.Greeter/crash", JNull) {
    case Ok(v) -> assertTrue(false, "expected Crashed, got " + writeValue(v))
    case Err(b) -> match b {
      case Crashed(_) -> ()
      case _ -> assertTrue(false, "expected Crashed, got " + boundaryErrorMessage(b))
    }
  }
  assertEqual(
    okText(callPlugin(c, "Fixture.Api.Greeter/count", JNull), "count after restart"),
    "1",
    "a fresh process after the restart"
  )
  match callPlugin(c, "Fixture.Api.Greeter/crash", JNull) {
    case Ok(v) -> assertTrue(false, "expected Crashed, got " + writeValue(v))
    case Err(b) -> match b {
      case Crashed(_) -> ()
      case _ -> assertTrue(false, "expected Crashed, got " + boundaryErrorMessage(b))
    }
  }
  match callPlugin(c, "Fixture.Api.Greeter/count", JNull) {
    case Ok(v) -> assertTrue(false, "the restart limit is reached, got " + writeValue(v))
    case Err(b) -> match b {
      case Crashed(d) -> assertTrue(d.contains("restarts allowed"), "the limit is named: " + d)
      case _ -> assertTrue(false, "expected Crashed, got " + boundaryErrorMessage(b))
    }
  }
  stopAllPlugins(host)
}

test "stopPlugin shuts the plugin down gracefully, and the next call starts it again" {
  val host = discoveredHost(SecretsProvider(served = 0), 30000, 3)
  val c = conn(host)
  assertEqual(okText(callPlugin(c, "Fixture.Api.Greeter/count", JNull), "count"), "1", "first count")
  val start = monotonicNanos()
  stopPlugin(host, "lyric.test.greeter")
  val took = (monotonicNanos() - start) / 1000000i64
  assertTrue(took < 8000i64, "the plugin exited on its own, well inside the 10 s grace (" + took.toString() + " ms)")
  assertEqual(okText(callPlugin(c, "Fixture.Api.Greeter/count", JNull), "count after stop"), "1", "a new process")
  stopAllPlugins(host)
}
