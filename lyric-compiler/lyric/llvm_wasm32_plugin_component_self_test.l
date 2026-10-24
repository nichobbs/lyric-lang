//! llvm_wasm32_plugin_component_self_test.l — the plugin side of component
//! mode (docs/69 §9.3): `lyric-stdlib/tests/plugin_fixtures/notes_plugin.l`
//! compiles through the native bridge with `shape = "component"`, and the
//! component's WIT is checked against the contract (the plugin exports, one
//! imported interface per capability, the `<c>-call-error-wire` variants).  The
//! component then runs: under `wasmtime run --invoke` for `plugin-describe`,
//! and transpiled by `jco` under node with a JavaScript host that attaches it,
//! calls each point method and answers its capability imports.
//!
//! Requires what `llvm_wasm32_component_self_test.l` does: `$WASI_SDK_PATH`,
//! `$LYRIC_RT_WASM32_PATH`, `$WASM_TOOLS`, `$LYRIC_WASI_ADAPTER`, `$WASMTIME`,
//! `$JCO`, `$LYRIC_JCO_NODE_MODULES` (holding `@bytecodealliance/preview2-shim`)
//! and node (`$NODE`, else `node`).  Run from the repository root.
@test_module
package Lyric.LlvmWasm32PluginComponentSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.File as File
import Std.Path as Path
import Std.Process as Process
import Std.String as Str
import Std.Environment as Environment
import Std.Uuid as Uuid
import Lyric.Emitter
import Lyric.LlvmBridge

func envOrPanic(name: in String): String {
  val v = Environment.getVarOrDefault(name, "")
  if v.length == 0 {
    panic(name + " is not set: run scripts/ci/wasm32-wasi-rt-tests.sh")
  }
  v
}

func run(exe: in String, argv: in List[String]): Process.ProcessResult {
  match Process.runCapture(exe, argv, 180000) {
    case Ok(res) -> res
    case Err(e) -> panic("could not start " + exe + ": " + e)
  }
}

val fixturePath: String = "lyric-stdlib/tests/plugin_fixtures/notes_plugin.l"

/// The notes fixture built as a component into a fresh directory, once per test.
func buildNotesComponent(): String {
  val _w = envOrPanic("WASI_SDK_PATH")
  val _t = envOrPanic("WASM_TOOLS")
  val _a = envOrPanic("LYRIC_WASI_ADAPTER")
  val source = match File.readText(fixturePath) {
    case Ok(t) -> t
    case Err(_) -> panic("cannot read " + fixturePath + " (run from the repository root)")
  }
  val stdlib = findStdlibSourcesNative()
  if stdlib.count == 0 {
    panic("native stdlib sources not found (run from the repo root or set LYRIC_STD_PATH)")
  }
  val dir = Path.join(
    Environment.getVarOrDefault("TMPDIR", "/tmp"),
    "lyric-plugin-component-" + Uuid.uuidToString(Uuid.newUuid())
  )
  val _d = File.createDir(dir)
  val flags: List[String] = newList()
  val ok = compileToNativeWithShape(
    source,
    Path.join(dir, "notes.wasm"),
    stdlib,
    "wasm32-wasi",
    "2",
    flags,
    newList(),
    fixturePath,
    true,
    "component"
  )
  if not ok {
    panic("the notes plugin did not build as a component")
  }
  dir
}

func expectLine(wit: in String, line: in String): Unit {
  assertTrue(Str.contains(wit, line), "the WIT has `" + line + "`:\n" + wit)
}

test "plugin component: the WIT matches the contract" {
  val dir = buildNotesComponent()
  val wasm = Path.join(dir, "notes.wasm")
  val tools = envOrPanic("WASM_TOOLS")
  val vargs: List[String] = newList()
  vargs.add("validate")
  vargs.add(wasm)
  val v = run(tools, vargs)
  assertTrue(v.exitCode == 0, "wasm-tools validate: " + v.stderr)
  val wargs: List[String] = newList()
  wargs.add("component")
  wargs.add("wit")
  wargs.add(wasm)
  val w = run(tools, wargs)
  assertTrue(w.exitCode == 0, "wasm-tools component wit: " + w.stderr)
  val wit = w.stdout
  // The exported interface lyric:plugin-gen-notes/plugin-gen-notes.
  expectLine(wit, "export lyric:plugin-gen-notes/plugin-gen-notes@0.1.0;")
  expectLine(wit, "plugin-describe: func() -> string;")
  expectLine(wit, "plugin-attach: func(grants: string) -> result<_, string>;")
  expectLine(wit, "plugin-methods: func() -> list<string>;")
  expectLine(wit, "note-tool-summarize: func(note: note) -> result<string, level>;")
  expectLine(wit, "note-tool-fetch: func(title: string) -> result<change, string>;")
  expectLine(wit, "note-tool-logged: func(line: string) -> result<bool, string>;")
  expectLine(wit, "tags: list<tuple<string, s32>>,")
  expectLine(wit, "body: list<u8>,")
  expectLine(wit, "pinned: option<bool>,")
  expectLine(wit, "added(note),")
  // One imported interface per capability: lyric:<p>/<a>-<c>.
  expectLine(wit, "import lyric:plugin-gen-notes/plugin-gen-notes-store@0.1.0;")
  expectLine(wit, "import lyric:plugin-gen-notes/plugin-gen-notes-log@0.1.0;")
  expectLine(wit, "load: func(title: string) -> result<note, store-call-error-wire>;")
  expectLine(wit, "log: func(level: level, line: string) -> result<_, log-call-error-wire>;")
  expectLine(wit, "variant store-call-error-wire {")
  for c in ["app(string)", "denied(string)", "not-granted(string)", "revoked(string)", "unsupported(string)", "contract-violated(string)", "timeout(s32)", "crashed(string)", "protocol(string)", "stale"] {
    expectLine(wit, c)
  }
  // The variant's cases are in the contract's order.
  val at = Str.indexOfRaw(wit, "variant store-call-error-wire {")
  val body = Str.substring(wit, at)
  assertTrue(
    Str.indexOfRaw(body, "app(string)") < Str.indexOfRaw(body, "denied(string)") and
      Str.indexOfRaw(body, "protocol(string)") < Str.indexOfRaw(body, "stale"),
    "case order: " + body
  )
}

test "plugin component: plugin-describe under wasmtime is the plugin's manifest" {
  val dir = buildNotesComponent()
  val args: List[String] = newList()
  args.add("run")
  args.add("-W")
  args.add("unknown-imports-trap=y")
  args.add("-S")
  args.add("cli=n")
  args.add("--invoke")
  args.add("plugin-describe()")
  args.add(Path.join(dir, "notes.wasm"))
  val r = run(envOrPanic("WASMTIME"), args)
  assertTrue(r.exitCode == 0, "wasmtime: " + r.stderr)
  assertTrue(
    Str.contains(r.stdout, "\\\"id\\\":\\\"lyric.test.notes\\\""),
    "the manifest names the plugin: " + r.stdout
  )
  assertTrue(Str.contains(r.stdout, "PluginGen.Notes.NoteTool"), "the manifest names the point: " + r.stdout)
  assertTrue(Str.contains(r.stdout, "notes.summarize"), "the manifest carries the contributions: " + r.stdout)
}

test "plugin component: a JavaScript host attaches it, calls its points and serves its capabilities" {
  val dir = buildNotesComponent()
  val wasm = Path.join(dir, "notes.wasm")
  val jargs: List[String] = newList()
  jargs.add("transpile")
  jargs.add(wasm)
  jargs.add("-o")
  jargs.add(Path.join(dir, "js"))
  jargs.add("--map")
  jargs.add("lyric:plugin-gen-notes/plugin-gen-notes-store@0.1.0=../store.js")
  jargs.add("--map")
  jargs.add("lyric:plugin-gen-notes/plugin-gen-notes-log@0.1.0=../log.js")
  val j = run(envOrPanic("JCO"), jargs)
  assertTrue(j.exitCode == 0, "jco transpile: " + j.stderr)
  val lnargs: List[String] = newList()
  lnargs.add("-s")
  lnargs.add(envOrPanic("LYRIC_JCO_NODE_MODULES"))
  lnargs.add(Path.join(dir, "node_modules"))
  val _ln = run("ln", lnargs)
  // The Store capability: a note for `notes/...`, the capability's own error
  // for `missing`, and a boundary error for anything else.
  val _st = File.writeText(
    Path.join(dir, "store.js"),
    r"export const load = (title) => {
  if (title === 'missing') {
    throw { payload: { tag: 'app', val: 'no such note' } };
  }
  if (!title.startsWith('notes/')) {
    throw { payload: { tag: 'denied', val: 'outside the granted prefixes' } };
  }
  return { title, body: new Uint8Array([1, 2, 3, 4]), tags: [['a', 1], ['b', 2]], pinned: true };
};
"
  )
  val _lg = File.writeText(
    Path.join(dir, "log.js"),
    r"export const log = (level, line) => { globalThis.__logged = level + ':' + line; };
"
  )
  val script = r#"import * as m from './js/notes.js';
const p = m.pluginGenNotes;
const show = (f) => { try { return 'ok:' + JSON.stringify(f()); } catch (e) { return 'err:' + JSON.stringify(e.payload ?? String(e)); } };
console.log('manifest-id=' + JSON.parse(p.pluginDescribe()).id);
console.log('methods=' + p.pluginMethods().join(','));
console.log('attach-none=' + show(() => p.pluginAttach('[]')));
console.log('attach-bad=' + show(() => p.pluginAttach('{')));
console.log('attach=' + show(() => p.pluginAttach('[{"capability":"PluginGen.Notes.Store","grant":{"prefixes":["notes/"]}}]')));
const note = { title: 'n', body: new Uint8Array([9, 9]), tags: [['x', 7]], pinned: undefined };
console.log('summarize=' + show(() => p.noteToolSummarize(note)));
console.log('summarize-empty=' + show(() => p.noteToolSummarize({ ...note, title: '' })));
console.log('fetch=' + show(() => p.noteToolFetch('notes/a')));
console.log('fetch-app=' + show(() => p.noteToolFetch('missing')));
console.log('fetch-denied=' + show(() => p.noteToolFetch('secret')));
console.log('logged-ungranted=' + show(() => p.noteToolLogged('hi')));
p.pluginAttach('[{"capability":"PluginGen.Notes.Store","grant":null},{"capability":"PluginGen.Notes.Log","grant":null}]');
console.log('logged=' + show(() => p.noteToolLogged('hi')) + ' host=' + globalThis.__logged);
"#
  val scriptPath = Path.join(dir, "run.mjs")
  val _s = File.writeText(scriptPath, script)
  val nargs: List[String] = newList()
  nargs.add(scriptPath)
  val n = run(Environment.getVarOrDefault("NODE", "node"), nargs)
  assertTrue(n.exitCode == 0, "node: " + n.stderr + n.stdout)
  val stdout = n.stdout
  assertTrue(Str.contains(stdout, "manifest-id=lyric.test.notes"), "describe: " + stdout)
  assertTrue(
    Str.contains(
      stdout,
      "methods=PluginGen.Notes.NoteTool/summarize,PluginGen.Notes.NoteTool/fetch,PluginGen.Notes.NoteTool/logged"
    ),
    "methods: " + stdout
  )
  assertTrue(
    Str.contains(stdout, "attach-none=err:\"capability 'PluginGen.Notes.Store' is not granted\""),
    "a missing required grant: " + stdout
  )
  assertTrue(
    Str.contains(stdout, "attach-bad=err:\"pluginAttach: the grants are not JSON"),
    "malformed grants: " + stdout
  )
  assertTrue(Str.contains(stdout, "attach=ok:"), "attach: " + stdout)
  assertTrue(Str.contains(stdout, "summarize=ok:\"n:2:1\""), "a record argument with a list and a map: " + stdout)
  assertTrue(Str.contains(stdout, "summarize-empty=err:\"high\""), "an enum error: " + stdout)
  assertTrue(
    Str.contains(stdout, "fetch=ok:{\"tag\":\"added\",\"val\":{\"title\":\"notes/a\""),
    "a capability call: " + stdout
  )
  assertTrue(
    Str.contains(stdout, "[\"a\",1]") and Str.contains(stdout, "[\"b\",2]") and
      Str.contains(stdout, "\"body\":{\"0\":1,\"1\":2,\"2\":3,\"3\":4}"),
    "a map and a byte list from the host: " + stdout
  )
  assertTrue(Str.contains(stdout, "fetch-app=err:\"app: no such note\""), "the capability's own error: " + stdout)
  assertTrue(
    Str.contains(stdout, "fetch-denied=err:\"boundary: denied: outside the granted prefixes\""),
    "a boundary error from the host: " + stdout
  )
  assertTrue(Str.contains(stdout, "logged-ungranted=ok:false"), "an optional capability not granted: " + stdout)
  assertTrue(
    Str.contains(stdout, "logged=ok:true host=low:hi"),
    "an optional capability granted on re-attach: " + stdout
  )
}
