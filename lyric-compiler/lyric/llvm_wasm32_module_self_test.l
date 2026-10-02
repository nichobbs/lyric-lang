//! llvm_wasm32_module_self_test.l — end-to-end self-test for the wasm32 `module`
//! shape (docs/35 phase W3): a Lyric package compiles through the full native
//! bridge with `shape = "module"`, producing a reactor `.wasm` plus the generated
//! JS glue and TypeScript declarations, and a node script instantiates it
//! through that glue and calls its exports.
//!
//! Requires `WASI_SDK_PATH` and the wasm32 runtime archive, as
//! `llvm_wasm32_self_test.l` does, plus `node` (or `$NODE`) on PATH.  Run via
//! native `lyric test` with LYRIC_LOAD_COMPILER=1:
//!   LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/llvm_wasm32_module_self_test.l
@test_module
package Lyric.LlvmWasm32ModuleSelfTest

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

func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", "/tmp")
}

record ModuleBuild {
  ok: Bool
  dir: String
}

func buildModule(source: in String, triple: in String): ModuleBuild {
  if Environment.getVarOrDefault("WASI_SDK_PATH", "").length == 0 {
    panic("WASI_SDK_PATH is not set: run scripts/ci/wasm32-wasi-rt-tests.sh or point it at a wasi-sdk install")
  }
  val stdlib = findStdlibSourcesNative()
  if stdlib.count == 0 {
    panic("native stdlib sources not found (run from the repo root or set LYRIC_STD_PATH)")
  }
  val dir = Path.join(tempBase(), "lyric-wasm32-module-" + Uuid.uuidToString(Uuid.newUuid()))
  val _ = File.createDir(dir)
  val flags: List[String] = newList()
  val ok = compileToNativeWithFlags(source, Path.join(dir, "prog.wasm"), stdlib, triple, "2", flags, newList(), "", true, "module")
  ModuleBuild(ok = ok, dir = dir)
}

/// Build `source` as a module, write `script` (an ES module that may import
/// `./prog.js`) next to it and run it under node; returns the node run.
func runNode(source: in String, script: in String): Process.ProcessResult {
  val b = buildModule(source, "wasm32-wasi")
  if not b.ok {
    panic("wasm32 module compilation failed for a self-test program")
  }
  val scriptPath = Path.join(b.dir, "run.mjs")
  val _ = File.writeText(scriptPath, script)
  val node = Environment.getVarOrDefault("NODE", "node")
  val args: List[String] = newList()
  args.add(scriptPath)
  match Process.runCapture(node, args, 120000) {
    case Ok(res) -> res
    case Err(e) -> panic("node could not be started (set NODE): " + e)
  }
}

func readGenerated(dir: in String, name: in String): String {
  match File.readText(Path.join(dir, name)) {
    case Ok(t) -> t
    case Err(_) -> ""
  }
}

val scalarProgram: String = r#"package Probe

import Std.Console

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

pub func third(x: Float): Float {
  x / 3.0
}

pub func shout(name: String): String {
  "hello, " + name + "!"
}

pub func nothing(): Unit {
  println("nothing ran")
}

pub func bad(a: Int): Int {
  panic("probe-panic")
}

func main(): Int {
  println("main ran")
  7
}
"#

test "wasm32 module: scalar, Long, Bool, Float, Double, String and Unit exports round-trip through the glue" {
  val r = runNode(
    scalarProgram,
    r#"import { instantiate } from './prog.js';
const out = [];
const m = await instantiate(undefined, { stdout: (t) => out.push(t) });
const lines = [];
lines.push('add=' + m.add(2, 40));
lines.push('add-big=' + m.add(2147483646, 1));
lines.push('big=' + m.big(5n) + ' ' + typeof m.big(5n));
lines.push('negate=' + m.negate(true) + ',' + m.negate(false));
lines.push('half=' + m.half(5));
lines.push('third=' + m.third(1));
lines.push('shout=' + m.shout('wörld ☃'));
lines.push('shout-empty=' + m.shout(''));
m.nothing();
lines.push('stdout=' + JSON.stringify(out));
console.log(lines.join('\n'));
"#
  )
  assertEqualInt(r.exitCode, 0, "node exits cleanly: " + r.stderr)
  val lines = r.stdout
  assertTrue(Str.contains(lines, "add=42\n"), "Int add: " + lines)
  assertTrue(Str.contains(lines, "add-big=2147483647\n"), "Int at the top of its range: " + lines)
  assertTrue(Str.contains(lines, "big=15000000000 bigint\n"), "Long crosses as bigint: " + lines)
  assertTrue(Str.contains(lines, "negate=false,true\n"), "Bool: " + lines)
  assertTrue(Str.contains(lines, "half=2.5\n"), "Double: " + lines)
  assertTrue(Str.contains(lines, "third=0.3333333432674408\n"), "Float is binary32: " + lines)
  assertTrue(Str.contains(lines, "shout=hello, wörld ☃!\n"), "String with non-ASCII: " + lines)
  assertTrue(Str.contains(lines, "shout-empty=hello, !\n"), "empty String: " + lines)
  assertTrue(Str.contains(lines, "stdout=[\"nothing ran\",\"\\n\"]\n"), "Unit export prints through the stdout hook: " + lines)
}

test "wasm32 module: run() calls main with argv and returns its exit code" {
  val r = runNode(
    r#"package Probe

import Std.Console
import Std.Environment

func main(): Int {
  val argv = args()
  println("argc=" + argv.length.toString())
  var i = 0
  while i < argv.length {
    println("arg " + argv[i])
    i = i + 1
  }
  5
}
"#,
    r#"import { instantiate } from './prog.js';
const out = [];
const m = await instantiate(undefined, { stdout: (t) => out.push(t) });
const code = m.run(['x', 'y z']);
m.flush();
console.log('code=' + code);
console.log('out=' + out.join(''));
"#
  )
  assertEqualInt(r.exitCode, 0, "node exits cleanly: " + r.stderr)
  assertTrue(Str.contains(r.stdout, "code=5\n"), "exit code from main: " + r.stdout)
  assertTrue(Str.contains(r.stdout, "argc=3\narg program\narg x\narg y z\n"), "program name plus two args: " + r.stdout)
}

test "wasm32 module: repeated String calls do not grow linear memory" {
  val r = runNode(
    r#"package Probe

pub func echo(s: String): String {
  s + s
}
"#,
    r#"import { instantiate } from './prog.js';
const m = await instantiate();
const text = 'abcdefghij'.repeat(20);
for (let i = 0; i < 200; i++) m.echo(text);
const before = m.memory.buffer.byteLength;
for (let i = 0; i < 20000; i++) {
  if (m.echo(text).length !== 400) throw new Error('bad echo');
}
const after = m.memory.buffer.byteLength;
console.log('grew=' + (after - before));
"#
  )
  assertEqualInt(r.exitCode, 0, "node exits cleanly: " + r.stderr)
  assertTrue(Str.contains(r.stdout, "grew=0\n"), "argument and result Strings are released: " + r.stdout)
}

test "wasm32 module: a panic in an export traps, with its message on the stderr hook" {
  val r = runNode(
    scalarProgram,
    r#"import { instantiate } from './prog.js';
const err = [];
const m = await instantiate(undefined, { stderr: (t) => err.push(t) });
let trapped = false;
try { m.bad(1); } catch (e) { trapped = e instanceof WebAssembly.RuntimeError; }
console.log('trapped=' + trapped);
console.log('stderr=' + err.join(''));
"#
  )
  assertEqualInt(r.exitCode, 0, "node exits cleanly: " + r.stderr)
  assertTrue(Str.contains(r.stdout, "trapped=true\n"), "the abort surfaces as a wasm trap: " + r.stdout)
  assertTrue(Str.contains(r.stdout, "probe-panic"), "the panic message reaches the stderr hook: " + r.stdout)
}

test "wasm32 module: unsupported pub funcs are left out of the glue, the rest are exported" {
  val b = buildModule(
    r#"package Probe

pub record Point {
  x: Int
  y: Int
}

pub func origin(): Point {
  Point(x = 0, y = 0)
}

pub func ident[T](x: T): T {
  x
}

pub func keep(x: Int): Int {
  x
}
"#,
    "wasm32-wasi"
  )
  assertTrue(b.ok, "the module builds")
  val js = readGenerated(b.dir, "prog.js")
  val dts = readGenerated(b.dir, "prog.d.ts")
  assertTrue(Str.contains(js, "wasm: \"Probe.keep\""), "keep is in the export table: " + js)
  assertFalse(Str.contains(js, "Probe.origin"), "origin (record result) is not exported")
  assertFalse(Str.contains(js, "Probe.ident"), "ident is not exported")
  assertTrue(Str.contains(dts, "keep(x: number): number;"), "the .d.ts declares keep: " + dts)
  assertFalse(Str.contains(dts, "origin"), "the .d.ts does not declare origin")
  assertFalse(Str.contains(dts, "run("), "no main, so no run()")
}

test "wasm32 module: a host triple is rejected with N0011" {
  val b = buildModule("package Probe\n" + "func main(): Int {\n" + "  0\n" + "}\n", "x86_64-unknown-linux-gnu")
  assertFalse(b.ok, "--shape module needs a wasm32 triple")
}

test "wasm32 module: a library with no main instantiates and exports its functions" {
  val r = runNode(
    r#"package Probe

pub func one(): Int {
  1
}
"#,
    r#"import { instantiate } from './prog.js';
const m = await instantiate();
console.log('one=' + m.one());
console.log('keys=' + Object.keys(m).sort().join(','));
"#
  )
  assertEqualInt(r.exitCode, 0, "node exits cleanly: " + r.stderr)
  assertTrue(Str.contains(r.stdout, "one=1\n"), "a library with no main instantiates and calls: " + r.stdout)
  assertFalse(Str.contains(r.stdout, "run"), "no main, so no run: " + r.stdout)
}
