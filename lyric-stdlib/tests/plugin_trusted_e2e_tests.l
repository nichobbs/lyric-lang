//! tests/plugin_trusted_e2e_tests.l — trusted (in-process) plugins end to end
//! (docs/69 §10, D231).
//!
//! The plugin is `plugin_fixtures/trusted_notes/` (packages
//! `PluginTrusted.Api` and `PluginTrusted.Notes`), built for the host's own
//! target: its process payload, and its trusted payload (the same dotnet
//! assembly or JVM jar, or a `--shape plugin` shared library on native).
//! This suite declares the same API package and hosts the plugin through the
//! host side `Lyric.PluginExpand` generates, with `Std.Plugin.Trusted`'s
//! loader:
//!
//! - a policy that marks the plugin trusted runs it in the host's own process
//!   (it sees an environment variable the host sets after it started), and
//!   one that does not runs the same artifact in its own process;
//! - point calls, application errors, capability calls back into the host
//!   (granted, narrowed by the grant, denied by the moved guard, revoked),
//!   an optional capability, contributions, and stopping and starting the
//!   plugin, all in process;
//! - the cost of a point call in process and over a pipe, printed.
//!
//! Run by `scripts/ci/plugin-trusted-e2e.sh <target>`, which builds the
//! fixture and sets `LYRIC_PLUGIN_FIXTURE_{DIR,RUNTIME,FILE,LIBRARY}`.
@test_module
package PluginTrusted.Api

import Std.Core
import Std.Collections
import Std.Testing
import Std.Environment
import Std.File
import Std.Path
import Std.Process
import Std.Time
import Std.JsonValue
import Std.Plugin
import Std.Plugin.Trusted

pub record Note {
  title: String
  body: List[Byte]
  tags: Map[String, Int]
  pinned: Option[Bool]
}

pub union Change {
  case Added(note: Note)
  case Removed(title: String)
}

pub enum Level {
  case Low
  case High
}

pub exposed record StoreGrant {
  prefixes: List[String]
}

pub func grantAllows(prefixes: in List[String], title: in String): Bool {
  for p in prefixes {
    if title.startsWith(p) {
      return true
    }
  }
  false
}

@capability(grant = StoreGrant)
pub interface Store {
  func load(title: in String): Result[Note, String]
    requires: grantAllows(grant.prefixes, title)
}

@capability
pub interface Log {
  func log(level: in Level, line: in String): Result[Unit, String]
}

pub record NotesContributions {
  commands: List[String]
}

@plugin_point(version = "1.0", contributions = NotesContributions, allows(Store, Log))
pub interface NoteTool {
  func summarize(note: in Note): Result[String, Level]
  func fetch(title: in String): Result[Change, String]
  func logged(line: in String): Result[Bool, String]
  func readEnv(name: in String): Result[String, String]
  func count(): Result[Int, String]
}

// ── Fixture location ────────────────────────────────────────────────────────
func fixtureVar(name: in String): String {
  match getVar(name) {
    case Ok(v) -> v
    case Err(_) -> panic(name + " is not set; run this suite through scripts/ci/plugin-trusted-e2e.sh")
  }
}

func fixtureDir(): String {
  fixtureVar("LYRIC_PLUGIN_FIXTURE_DIR")
}

func runtimeName(): String {
  fixtureVar("LYRIC_PLUGIN_FIXTURE_RUNTIME")
}

func processPayload(): PluginPayload {
  val file = fixtureVar("LYRIC_PLUGIN_FIXTURE_FILE")
  val runtime = runtimeName()
  if runtime == "dotnet" {
    ManagedPayload(runtime = "dotnet", command = ["dotnet", "exec", file])
  } else if runtime == "jvm" {
    ManagedPayload(runtime = "jvm", command = ["java", "-jar", file])
  } else {
    val p = currentPluginPlatform()
    NativePayload(os = p.os, arch = p.arch, command = [file])
  }
}

func trustedPayload(): PluginPayload {
  val library = fixtureVar("LYRIC_PLUGIN_FIXTURE_LIBRARY")
  val runtime = runtimeName()
  if runtime == "native" {
    val p = currentPluginPlatform()
    TrustedNativePayload(os = p.os, arch = p.arch, library = library)
  } else {
    TrustedManagedPayload(runtime = runtime, library = library)
  }
}

func probedManifest(): PluginManifest {
  val argv = match pluginLaunchCommand(processPayload(), fixtureDir(), None, 1i64) {
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
    case Ok(m) -> addPluginPayload(addPluginPayload(m, processPayload()), trustedPayload())
    case Err(issue) -> panic("the generated manifest is invalid: " + pluginLoadIssueMessage(issue))
  }
}

// ── Host-side implementations of the capabilities ─────────────────────────
pub ref record NoteStore {
  var loads: Int
}

impl Store for NoteStore {
  func load(title: in String): Result[Note, String] {
    self.loads = self.loads + 1
    if title == "notes/missing" {
      return Err(error = "no note " + title)
    }
    val body: List[Byte] = newList()
    body.add(1u8)
    body.add(2u8)
    val tags: Map[String, Int] = newMap()
    tags["k"] = 7
    Ok(value = Note(title = title, body = body, tags = tags, pinned = Some(value = true)))
  }
}

pub ref record LineLog {
  var lines: List[String]
}

impl Log for LineLog {
  func log(level: in Level, line: in String): Result[Unit, String] {
    self.lines.add(line)
    Ok(value = ())
  }
}

// Grants Store narrowed from the requested "notes/" and "shared/" to
// "notes/", and Log in full; `trusted` is the policy's in-process decision.
pub record NotesPolicy {
  trusted: Bool
}

impl GrantPolicy for NotesPolicy {
  func decide(manifest: in PluginManifest): GrantDecision {
    val prefixes: List[String] = newList()
    prefixes.add("notes/")
    val grants: List[GrantedCapability] = newList()
    grants.add(
      GrantedCapability(
        capability = storeCapabilityInfo().id,
        grant = Some(value = pluginEncodeStoreGrant(StoreGrant(prefixes = prefixes)))
      )
    )
    grants.add(GrantedCapability(capability = logCapabilityInfo().id, grant = None))
    GrantDecision(allow = true, reason = "", grants = grants, trusted = self.trusted)
  }
}

func newHost(store: in NoteStore, log: in LineLog, trusted: in Bool): PluginHost {
  match writeText(Std.Path.join(fixtureDir(), "plugin.json"), writeValue(pluginManifestToJson(probedManifest()))) {
    case Ok(_) -> ()
    case Err(e) -> panic("could not write plugin.json: " + IOError.message(e))
  }
  val providers: List[CapabilityProvider] = newList()
  providers.add(storeProvider(store))
  providers.add(logProvider(log))
  val loader = trustedPluginLoader()
  assertEqual(loader.unavailableReason(), "", "this host can load plugins in process")
  val host = newPluginHost(
    PluginHostConfig(
      points = [noteToolPointInfo()],
      providers = providers,
      policy = NotesPolicy(trusted = trusted),
      callTimeoutMs = 60000,
      startTimeoutMs = 60000,
      trustedLoader = Some(value = loader)
    )
  )
  val issues = discoverPlugins(host, [dirname(fixtureDir())])
  for issue in issues {
    assertTrue(false, "load issue: " + pluginLoadIssueMessage(issue))
  }
  host
}

func trustedHost(store: in NoteStore, log: in LineLog): PluginHost {
  newHost(store, log, true)
}

func remote(host: in PluginHost): NoteToolRemote {
  val rs = noteToolRemotes(host)
  assertEqualInt(rs.count, 1, "one plugin implements NoteTool")
  rs[0]
}

func isInProcess(host: in PluginHost): Bool {
  val conns = connectionsFor(host, noteToolPointInfo().id)
  assertEqualInt(conns.count, 1, "one plugin")
  match conns[0].host {
    case Some(st) -> isSome(st.trusted)
    case None -> false
  }
}

func sample(title: in String): Note {
  val body: List[Byte] = newList()
  body.add(9u8)
  body.add(8u8)
  body.add(7u8)
  val tags: Map[String, Int] = newMap()
  tags["a"] = 1
  tags["b"] = 2
  Note(title = title, body = body, tags = tags, pinned = None)
}

func textOf(e: in CallError[String]): String {
  match e {
    case CallError.App(m) -> "app error: " + m
    case CallError.Boundary(b) -> "boundary error: " + boundaryErrorMessage(b)
  }
}

func envOf(host: in PluginHost, name: in String): String {
  match remote(host).readEnv(name) {
    case Ok(v) -> v
    case Err(e) -> panic("readEnv: " + textOf(e))
  }
}

// ── The suite ───────────────────────────────────────────────────────────────
test "a plugin the policy trusts runs in the host's own process" {
  val host = trustedHost(NoteStore(loads = 0), LineLog(lines = newList()))
  assertTrue(isInProcess(host), "the trusted payload was chosen")
  setVar("LYRIC_TRUSTED_E2E_PROBE", "before")
  assertEqual(envOf(host, "LYRIC_TRUSTED_E2E_PROBE"), "before", "the first call starts the plugin")
  setVar("LYRIC_TRUSTED_E2E_PROBE", "after")
  assertEqual(envOf(host, "LYRIC_TRUSTED_E2E_PROBE"), "after", "the plugin shares the host's environment")
  stopAllPlugins(host)
}

test "a plugin the policy does not trust runs the same artifact in its own process" {
  val host = newHost(NoteStore(loads = 0), LineLog(lines = newList()), false)
  assertTrue(not isInProcess(host), "the process payload was chosen")
  setVar("LYRIC_TRUSTED_E2E_PROBE", "before")
  assertEqual(envOf(host, "LYRIC_TRUSTED_E2E_PROBE"), "before", "the first call starts the plugin process")
  setVar("LYRIC_TRUSTED_E2E_PROBE", "after")
  assertEqual(envOf(host, "LYRIC_TRUSTED_E2E_PROBE"), "before", "the plugin process kept its own environment")
  stopAllPlugins(host)
}

test "contributions are read from the manifest without loading the plugin" {
  val host = trustedHost(NoteStore(loads = 0), LineLog(lines = newList()))
  val cs = noteToolContributions(host)
  assertEqualInt(cs.count, 1, "one contribution")
  assertEqual(cs[0].pluginId, "lyric.test.trusted-notes", "contribution plugin id")
  assertEqualInt(cs[0].value.commands.count, 2, "decoded contributions")
  assertEqual(cs[0].value.commands[1], "notes.fetch", "contribution content")
  stopAllPlugins(host)
}

test "a point call round-trips a record in process" {
  val host = trustedHost(NoteStore(loads = 0), LineLog(lines = newList()))
  match remote(host).summarize(sample("draft")) {
    case Ok(s) -> assertEqual(s, "draft:3:2", "summary")
    case Err(CallError.App(_)) -> assertTrue(false, "unexpected app error")
    case Err(CallError.Boundary(b)) -> assertTrue(false, "boundary: " + boundaryErrorMessage(b))
  }
  stopAllPlugins(host)
}

test "an application error arrives as CallError.App in process" {
  val host = trustedHost(NoteStore(loads = 0), LineLog(lines = newList()))
  match remote(host).summarize(sample("")) {
    case Err(CallError.App(l)) -> assertTrue(l == Level.High, "the plugin's error value")
    case _ -> assertTrue(false, "expected CallError.App(Level.High)")
  }
  stopAllPlugins(host)
}

test "a capability call back into the host, within the grant" {
  val store = NoteStore(loads = 0)
  val host = trustedHost(store, LineLog(lines = newList()))
  match remote(host).fetch("notes/today") {
    case Ok(Change.Added(n)) -> {
      assertEqual(n.title, "notes/today", "the host's note")
      assertEqualInt(n.body.count, 2, "its body")
      assertTrue(n.pinned == Some(value = true), "its option")
    }
    case Ok(_) -> assertTrue(false, "expected Change.Added")
    case Err(e) -> assertTrue(false, textOf(e))
  }
  assertEqualInt(store.loads, 1, "the provider ran once")
  stopAllPlugins(host)
}

test "the capability's application error reaches the plugin as CallError.App" {
  val host = trustedHost(NoteStore(loads = 0), LineLog(lines = newList()))
  match remote(host).fetch("notes/missing") {
    case Err(CallError.App(m)) -> assertEqual(m, "app: no note notes/missing", "relayed app error")
    case _ -> assertTrue(false, "expected the plugin to report the app error")
  }
  stopAllPlugins(host)
}

test "a request outside the narrowed grant is denied by the guard, in process" {
  val store = NoteStore(loads = 0)
  val host = trustedHost(store, LineLog(lines = newList()))
  match remote(host).fetch("shared/x") {
    case Err(CallError.App(m)) -> {
      val text: String = m
      assertTrue(text.startsWith("boundary: "), "a boundary error in the plugin: " + text)
      assertTrue(text.contains("denied"), "Denied: " + text)
    }
    case _ -> assertTrue(false, "expected the guard to deny shared/x, which the grant narrowed away")
  }
  assertEqualInt(store.loads, 0, "the provider never ran")
  stopAllPlugins(host)
}

test "a revoked capability fails at once, in process" {
  val store = NoteStore(loads = 0)
  val host = trustedHost(store, LineLog(lines = newList()))
  match remote(host).fetch("notes/a") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "before the revocation: " + textOf(e))
  }
  revokeCapability(host, "lyric.test.trusted-notes", storeCapabilityInfo().id)
  match remote(host).fetch("notes/b") {
    case Err(CallError.App(m)) -> {
      val text: String = m
      assertTrue(text.contains("revoked"), "Revoked: " + text)
    }
    case _ -> assertTrue(false, "expected the revoked capability to fail")
  }
  assertEqualInt(store.loads, 1, "the provider ran only before the revocation")
  stopAllPlugins(host)
}

test "an optional capability that is granted reaches the host" {
  val log = LineLog(lines = newList())
  val host = trustedHost(NoteStore(loads = 0), log)
  match remote(host).logged("hello") {
    case Ok(b) -> assertTrue(b, "the plugin had a Log client")
    case Err(e) -> assertTrue(false, textOf(e))
  }
  assertEqualInt(log.lines.count, 1, "one line logged")
  assertEqual(log.lines[0], "hello", "the logged line")
  stopAllPlugins(host)
}

test "stopping a trusted plugin discards its state; the next call attaches a fresh one" {
  val host = trustedHost(NoteStore(loads = 0), LineLog(lines = newList()))
  val r = remote(host)
  assertEqualInt(countOf(r), 1, "first count")
  assertEqualInt(countOf(r), 2, "second count")
  stopPlugin(host, "lyric.test.trusted-notes")
  assertEqualInt(countOf(r), 1, "a fresh plugin after the stop")
  stopAllPlugins(host)
}

func levelText(e: in CallError[Level]): String {
  match e {
    case CallError.App(_) -> "app error"
    case CallError.Boundary(b) -> "boundary error: " + boundaryErrorMessage(b)
  }
}

func countOf(r: in NoteToolRemote): Int {
  match r.count() {
    case Ok(n) -> n
    case Err(e) -> panic("count: " + textOf(e))
  }
}

func microsPerCall(host: in PluginHost, calls: in Int): Long {
  val r = remote(host)
  val note = sample("bench")
  match r.summarize(note) {
    case Ok(_) -> ()
    case Err(e) -> panic("warm-up: " + levelText(e))
  }
  val start = monotonicNanos()
  var i = 0
  while i < calls {
    match r.summarize(note) {
      case Ok(_) -> ()
      case Err(e) -> panic("call " + i.toString() + ": " + levelText(e))
    }
    i = i + 1
  };
  (monotonicNanos() - start) / (calls.toLong() * 1000i64)
}

test "the cost of a point call in process and over a pipe" {
  val calls = 500
  val trusted = trustedHost(NoteStore(loads = 0), LineLog(lines = newList()))
  val inProcess = microsPerCall(trusted, calls)
  stopAllPlugins(trusted)
  val untrusted = newHost(NoteStore(loads = 0), LineLog(lines = newList()), false)
  val overPipe = microsPerCall(untrusted, calls)
  stopAllPlugins(untrusted)
  println(
    "trusted-mode timing (" + runtimeName() + ", " + calls.toString() + " summarize calls): in process " +
      inProcess.toString() +
      " us/call, process mode " +
      overPipe.toString() +
      " us/call"
  )
  assertTrue(inProcess <= overPipe, "a call in process costs no more than one over a pipe")
}
