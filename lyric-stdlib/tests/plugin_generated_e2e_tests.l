//! tests/plugin_generated_e2e_tests.l — a plugin and its host written only
//! with the D207 annotations, end to end over a real plugin process.
//!
//! The plugin is `plugin_fixtures/notes_plugin.l`; this suite declares the
//! same API package (`PluginGen.Notes`) and drives it through the host side
//! `Lyric.PluginExpand` generates from it: `noteToolPointInfo`,
//! `storeProvider`/`logProvider` (the `<C>Server`s, which decode the grant
//! and check the guard moved from `Store.load`), `noteToolRemotes` and
//! `noteToolContributions`.  The plugin side is generated too, so a point
//! call here exercises both directions of every generated encoder.
//!
//! Run by `scripts/ci/plugin-generated-e2e.sh <host-target> <plugin-target>`,
//! which builds the fixture and sets `LYRIC_PLUGIN_FIXTURE_{DIR,RUNTIME,FILE}`.
@test_module
package PluginGen.Notes

import Std.Core
import Std.Collections
import Std.Testing
import Std.Environment
import Std.File
import Std.Path
import Std.Process
import Std.JsonValue
import Std.Plugin

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
}

// ── Fixture location (as plugin_e2e_tests.l) ───────────────────────────────
func fixtureVar(name: in String): String {
  match getVar(name) {
    case Ok(v) -> v
    case Err(_) -> panic(name + " is not set; run this suite through scripts/ci/plugin-generated-e2e.sh")
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
  } else {
    val p = currentPluginPlatform()
    NativePayload(os = p.os, arch = p.arch, command = [file])
  }
}

func probedManifest(): PluginManifest {
  val argv = match pluginLaunchCommand(fixturePayload(), fixtureDir(), None, 1i64) {
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
    case Err(issue) -> panic(
      "the generated manifest is invalid: " + pluginLoadIssueMessage(issue) + "\n" + probe.stdout
    )
  }
}

// ── Host-side implementations of the capabilities ─────────────────────────
pub record NoteStore {
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

pub record LineLog {
  var lines: List[String]
}

impl Log for LineLog {
  func log(level: in Level, line: in String): Result[Unit, String] {
    self.lines.add(line)
    Ok(value = ())
  }
}

// Grants Store narrowed to "notes/" and Log in full.
pub record NotesPolicy {
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
    GrantDecision(allow = true, reason = "", grants = grants)
  }
}

func discoveredHost(store: in NoteStore, log: in LineLog): PluginHost {
  match writeText(join(fixtureDir(), "plugin.json"), writeValue(pluginManifestToJson(probedManifest()))) {
    case Ok(_) -> ()
    case Err(e) -> panic("could not write plugin.json: " + IOError.message(e))
  }
  val providers: List[CapabilityProvider] = newList()
  providers.add(storeProvider(store))
  providers.add(logProvider(log))
  val host = newPluginHost(
    PluginHostConfig(
      points = [noteToolPointInfo()],
      providers = providers,
      policy = NotesPolicy(),
      callTimeoutMs = 60000,
      startTimeoutMs = 60000
    )
  )
  val issues = discoverPlugins(host, [dirname(fixtureDir())])
  for issue in issues {
    assertTrue(false, "load issue: " + pluginLoadIssueMessage(issue))
  }
  host
}

func remote(host: in PluginHost): NoteToolRemote {
  val rs = noteToolRemotes(host)
  assertEqualInt(rs.count, 1, "one plugin implements NoteTool")
  rs[0]
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

func boundaryText(e: in CallError[String]): String {
  match e {
    case CallError.App(m) -> "app error: " + m
    case CallError.Boundary(b) -> "boundary error: " + boundaryErrorMessage(b)
  }
}

// ── The suite ───────────────────────────────────────────────────────────────
test "the generated manifest carries the point, its contributions and the capability requests" {
  val m = probedManifest()
  assertEqual(m.id, "lyric.test.notes", "id")
  assertEqual(m.version, "1.2.0", "version")
  val host = discoveredHost(NoteStore(loads = 0), LineLog(lines = newList()))
  val cs = noteToolContributions(host)
  assertEqualInt(cs.count, 1, "one contribution")
  assertEqual(cs[0].pluginId, "lyric.test.notes", "contribution plugin id")
  assertEqualInt(cs[0].value.commands.count, 2, "decoded contributions")
  assertEqual(cs[0].value.commands[1], "notes.fetch", "contribution content")
  stopAllPlugins(host)
}

test "a point call round-trips a record through the generated codecs" {
  val host = discoveredHost(NoteStore(loads = 0), LineLog(lines = newList()))
  match remote(host).summarize(sample("draft")) {
    case Ok(s) -> assertEqual(s, "draft:3:2", "summary")
    case Err(CallError.App(l)) -> assertTrue(false, "unexpected app error")
    case Err(CallError.Boundary(b)) -> assertTrue(false, "boundary: " + boundaryErrorMessage(b))
  }
  stopAllPlugins(host)
}

test "an application error arrives as CallError.App" {
  val host = discoveredHost(NoteStore(loads = 0), LineLog(lines = newList()))
  match remote(host).summarize(sample("")) {
    case Err(CallError.App(l)) -> assertTrue(l == Level.High, "the plugin's error value")
    case _ -> assertTrue(false, "expected CallError.App(Level.High)")
  }
  stopAllPlugins(host)
}

test "a capability call back into the host, within the grant" {
  val store = NoteStore(loads = 0)
  val host = discoveredHost(store, LineLog(lines = newList()))
  match remote(host).fetch("notes/today") {
    case Ok(Change.Added(n)) -> {
      assertEqual(n.title, "notes/today", "the host's note")
      assertEqualInt(n.body.count, 2, "its body")
      assertTrue(n.pinned == Some(value = true), "its option")
    }
    case Ok(_) -> assertTrue(false, "expected Change.Added")
    case Err(e) -> assertTrue(false, boundaryText(e))
  }
  assertEqualInt(store.loads, 1, "the provider ran once")
  stopAllPlugins(host)
}

test "the capability's application error reaches the plugin as CallError.App" {
  val host = discoveredHost(NoteStore(loads = 0), LineLog(lines = newList()))
  match remote(host).fetch("notes/missing") {
    case Err(CallError.App(m)) -> assertEqual(m, "app: no note notes/missing", "relayed app error")
    case _ -> assertTrue(false, "expected the plugin to report the app error")
  }
  stopAllPlugins(host)
}

test "the guard moved from Store.load denies a call outside the grant" {
  val store = NoteStore(loads = 0)
  val host = discoveredHost(store, LineLog(lines = newList()))
  match remote(host).fetch("shared/x") {
    case Err(CallError.App(m)) -> {
      val text: String = m
      assertTrue(text.startsWith("boundary: "), "a boundary error in the plugin: " + text)
      assertTrue(text.contains("denied"), "Denied: " + text)
    }
    case _ -> assertTrue(false, "expected the guard to deny shared/x")
  }
  assertEqualInt(store.loads, 0, "the provider never ran")
  stopAllPlugins(host)
}

test "an optional capability that is granted reaches the host" {
  val log = LineLog(lines = newList())
  val host = discoveredHost(NoteStore(loads = 0), log)
  match remote(host).logged("hello") {
    case Ok(b) -> assertTrue(b, "the plugin had a Log client")
    case Err(e) -> assertTrue(false, boundaryText(e))
  }
  assertEqualInt(log.lines.count, 1, "one line logged")
  assertEqual(log.lines[0], "hello", "the logged line")
  stopAllPlugins(host)
}
