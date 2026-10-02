//! llvm_wasm32_component_self_test.l — end-to-end self-test for the wasm32
//! `component` shape (docs/35 phase W4): a Lyric package compiles through the
//! native bridge with `shape = "component"` into a WebAssembly component (WIT
//! generated from the exports, canonical-ABI wrappers linked in, componentized
//! by `wasm-tools`), which is validated, has its WIT printed back, and is
//! transpiled by `jco` and called from node.
//!
//! Requires everything `llvm_wasm32_module_self_test.l` does, plus
//! `$WASM_TOOLS` (a wasm-tools binary), `$LYRIC_WASI_ADAPTER` (the preview1
//! reactor adapter), `$JCO` (the jco binary) and `$LYRIC_JCO_NODE_MODULES` (a
//! node_modules directory holding `@bytecodealliance/preview2-shim`).
@test_module
package Lyric.LlvmWasm32ComponentSelfTest

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

val program: String = r#"package Probe

pub func add(a: Int, b: Int): Int {
  a + b
}

pub func big(x: Long): Long {
  x * 3000000000i64
}

pub func negate(flag: Bool): Bool {
  not flag
}

pub func half(x: Double): Double {
  x / 2.0
}

pub func shout(name: String): String {
  "hello, " + name + "!"
}

pub func echo(s: String): String {
  s
}

pub func byteEcho(b: Byte): Byte {
  b
}

pub func third(x: Float): Float {
  x / 3.0
}

pub func nothing(): Unit {
}
"#

func buildComponent(): String {
  val _w = envOrPanic("WASI_SDK_PATH")
  val _t = envOrPanic("WASM_TOOLS")
  val _a = envOrPanic("LYRIC_WASI_ADAPTER")
  val stdlib = findStdlibSourcesNative()
  if stdlib.count == 0 {
    panic("native stdlib sources not found (run from the repo root or set LYRIC_STD_PATH)")
  }
  val dir = Path.join(
    Environment.getVarOrDefault("TMPDIR", "/tmp"),
    "lyric-wasm32-component-" + Uuid.uuidToString(Uuid.newUuid())
  )
  val _d = File.createDir(dir)
  val flags: List[String] = newList()
  val ok = compileToNativeWithShape(
    program,
    Path.join(dir, "prog.wasm"),
    stdlib,
    "wasm32-wasi",
    "2",
    flags,
    newList(),
    "",
    true,
    "component"
  )
  if not ok {
    panic("wasm32 component compilation failed")
  }
  dir
}

test "wasm32 component: validates, prints the generated WIT, and runs through jco under node" {
  val dir = buildComponent()
  val wasm = Path.join(dir, "prog.wasm")
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
  assertTrue(w.exitCode == 0, "component wit: " + w.stderr)
  assertTrue(Str.contains(w.stdout, "add: func(a: s32, b: s32) -> s32"), "WIT has add: " + w.stdout)
  assertTrue(Str.contains(w.stdout, "shout: func(name: string) -> string"), "WIT has shout: " + w.stdout)
  assertTrue(Str.contains(w.stdout, "big: func(x: s64) -> s64"), "WIT has big: " + w.stdout)

  assertTrue(Str.contains(w.stdout, "byte-echo: func(b: u8) -> u8"), "WIT has byte-echo: " + w.stdout)
  assertTrue(Str.contains(w.stdout, "third: func(x: f32) -> f32"), "WIT has third: " + w.stdout)
  assertTrue(Str.contains(w.stdout, "nothing: func()"), "WIT has nothing: " + w.stdout)

  val outDir = Path.join(dir, "js")
  val jargs: List[String] = newList()
  jargs.add("transpile")
  jargs.add(wasm)
  jargs.add("-o")
  jargs.add(outDir)
  val j = run(envOrPanic("JCO"), jargs)
  assertTrue(j.exitCode == 0, "jco transpile: " + j.stderr)

  val lnargs: List[String] = newList()
  lnargs.add("-s")
  lnargs.add(envOrPanic("LYRIC_JCO_NODE_MODULES"))
  lnargs.add(Path.join(dir, "node_modules"))
  val ln = run("ln", lnargs)
  assertTrue(ln.exitCode == 0, "ln node_modules: " + ln.stderr)

  val script = r"import * as m from './js/prog.js';
const p = m.probe;
console.log('add=' + p.add(2, 40));
console.log('big=' + p.big(2n));
console.log('negate=' + p.negate(true));
console.log('half=' + p.half(5));
console.log('shout=' + p.shout('wörld ☃'));
console.log('echo=' + p.echo(''));
console.log('byte=' + p.byteEcho(200));
console.log('third=' + p.third(3));
console.log('nothing=' + p.nothing());
console.log('loop=' + [1, 2, 3].map((i) => p.echo('x'.repeat(i * 1000)).length).join(','));
"
  val scriptPath = Path.join(dir, "run.mjs")
  val _s = File.writeText(scriptPath, script)
  val nargs: List[String] = newList()
  nargs.add(scriptPath)
  val n = run(Environment.getVarOrDefault("NODE", "node"), nargs)
  assertTrue(n.exitCode == 0, "node: " + n.stderr)
  assertTrue(Str.contains(n.stdout, "add=42"), "add: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "big=6000000000"), "big: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "negate=false"), "negate: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "half=2.5"), "half: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "shout=hello, wörld ☃!"), "shout: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "echo=\n"), "echo empty: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "byte=200"), "byte: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "third=1\n"), "third: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "nothing=undefined"), "nothing: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "loop=1000,2000,3000"), "loop: " + n.stdout)
}

test "wasm32 component: a missing adapter is N0016, not a crash" {
  val stdlib = findStdlibSourcesNative()
  val dir = Path.join(
    Environment.getVarOrDefault("TMPDIR", "/tmp"),
    "lyric-wasm32-component-noadapter-" + Uuid.uuidToString(Uuid.newUuid())
  )
  val _d = File.createDir(dir)
  val flags: List[String] = newList()
  val saved = Environment.getVarOrDefault("LYRIC_WASI_ADAPTER", "")
  val _e = Environment.setVar("LYRIC_WASI_ADAPTER", "")
  val ok = compileToNativeWithShape(
    program,
    Path.join(dir, "prog.wasm"),
    stdlib,
    "wasm32-wasi",
    "2",
    flags,
    newList(),
    "",
    true,
    "component"
  )
  val _r = Environment.setVar("LYRIC_WASI_ADAPTER", saved)
  assertFalse(ok, "component build without an adapter must fail")
}

test "wasm32 component: @wasmImport is refused with N0017" {
  val _w = envOrPanic("WASI_SDK_PATH")
  val stdlib = findStdlibSourcesNative()
  val dir = Path.join(
    Environment.getVarOrDefault("TMPDIR", "/tmp"),
    "lyric-wasm32-component-import-" + Uuid.uuidToString(Uuid.newUuid())
  )
  val _d = File.createDir(dir)
  val flags: List[String] = newList()
  val ok = compileToNativeWithShape(
    r#"package Probe

@wasmImport("ui")
extern func hostLog(msg: String): Unit = "log"

pub func go(): Unit {
  hostLog("x")
}
"#,
    Path.join(dir, "prog.wasm"),
    stdlib,
    "wasm32-wasi",
    "2",
    flags,
    newList(),
    "",
    true,
    "component"
  )
  assertFalse(ok, "a component build cannot carry a host import yet (N0017)")
}
