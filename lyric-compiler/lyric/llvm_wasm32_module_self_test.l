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
  val ok = compileToNativeWithShape(
    source,
    Path.join(dir, "prog.wasm"),
    stdlib,
    triple,
    "2",
    flags,
    newList(),
    "",
    true,
    "module"
  )
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

/// Write `text` to `dir/rel`, creating the directories on the way.
func writeIn(dir: in String, rel: in String, text: in String): Unit {
  val full = Path.join(dir, rel)
  val _ = File.createDir(Path.dirname(full))
  val _w = File.writeText(full, text)
}

/// Build `source` as a module, install a fake NPM package `fakenpm` beside it,
/// and run `script` under node.
func runNodeWithFakeNpm(source: in String, script: in String): Process.ProcessResult {
  val b = buildModule(source, "wasm32-wasi")
  if not b.ok {
    panic("wasm32 module compilation failed for a self-test program")
  }
  writeIn(
    b.dir,
    "node_modules/fakenpm/package.json",
    "{ \"name\": \"fakenpm\", \"version\": \"1.0.0\", \"type\": \"module\", \"main\": \"index.js\" }\n"
  )
  writeIn(
    b.dir,
    "node_modules/fakenpm/index.js",
    "export function add(a, b) { return a + b + 1000; }\nexport function shout(s) { return s.toUpperCase() + '!'; }\nexport async function slowAdd(a, b) { return a + b + 2000; }\n"
  )
  writeIn(b.dir, "run.mjs", script)
  val node = Environment.getVarOrDefault("NODE", "node")
  val args: List[String] = newList()
  args.add(Path.join(b.dir, "run.mjs"))
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

pub func byteEcho(b: Byte): Byte {
  b
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
    r"import { instantiate } from './prog.js';
const out = [];
const m = await instantiate(undefined, { stdout: (t) => out.push(t) });
const lines = [];
lines.push('add=' + m.add(2, 40));
lines.push('add-big=' + m.add(2147483646, 1));
lines.push('big=' + m.big(5n) + ' ' + typeof m.big(5n));
lines.push('negate=' + m.negate(true) + ',' + m.negate(false));
lines.push('byte=' + m.byteEcho(200) + ',' + m.byteEcho(255));
lines.push('half=' + m.half(5));
lines.push('third=' + m.third(1));
lines.push('shout=' + m.shout('wörld ☃'));
lines.push('shout-empty=' + m.shout(''));
m.nothing();
lines.push('stdout=' + JSON.stringify(out));
console.log(lines.join('\n'));
"
  )
  assertEqualInt(r.exitCode, 0, "node exits cleanly: " + r.stderr)
  val lines = r.stdout
  assertTrue(Str.contains(lines, "add=42\n"), "Int add: " + lines)
  assertTrue(Str.contains(lines, "add-big=2147483647\n"), "Int at the top of its range: " + lines)
  assertTrue(Str.contains(lines, "big=15000000000 bigint\n"), "Long crosses as bigint: " + lines)
  assertTrue(Str.contains(lines, "negate=false,true\n"), "Bool: " + lines)
  assertTrue(Str.contains(lines, "byte=200,255\n"), "Byte stays unsigned: " + lines)
  assertTrue(Str.contains(lines, "half=2.5\n"), "Double: " + lines)
  assertTrue(Str.contains(lines, "third=0.3333333432674408\n"), "Float is binary32: " + lines)
  assertTrue(Str.contains(lines, "shout=hello, wörld ☃!\n"), "String with non-ASCII: " + lines)
  assertTrue(Str.contains(lines, "shout-empty=hello, !\n"), "empty String: " + lines)
  assertTrue(
    Str.contains(lines, "stdout=[\"nothing ran\",\"\\n\"]\n"),
    "Unit export prints through the stdout hook: " + lines
  )
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
    r"import { instantiate } from './prog.js';
const out = [];
const m = await instantiate(undefined, { stdout: (t) => out.push(t) });
const code = m.run(['x', 'y z']);
m.flush();
console.log('code=' + code);
console.log('out=' + out.join(''));
"
  )
  assertEqualInt(r.exitCode, 0, "node exits cleanly: " + r.stderr)
  assertTrue(Str.contains(r.stdout, "code=5\n"), "exit code from main: " + r.stdout)
  assertTrue(Str.contains(r.stdout, "argc=3\narg program\narg x\narg y z\n"), "program name plus two args: " + r.stdout)
}

test "wasm32 module: repeated String calls do not grow linear memory" {
  val r = runNode(
    r"package Probe

pub func echo(s: String): String {
  s + s
}
",
    r"import { instantiate } from './prog.js';
const m = await instantiate();
const text = 'abcdefghij'.repeat(20);
for (let i = 0; i < 200; i++) m.echo(text);
const before = m.memory.buffer.byteLength;
for (let i = 0; i < 20000; i++) {
  if (m.echo(text).length !== 400) throw new Error('bad echo');
}
const after = m.memory.buffer.byteLength;
console.log('grew=' + (after - before));
"
  )
  assertEqualInt(r.exitCode, 0, "node exits cleanly: " + r.stderr)
  assertTrue(Str.contains(r.stdout, "grew=0\n"), "argument and result Strings are released: " + r.stdout)
}

test "wasm32 module: a panic in an export traps, with its message on the stderr hook" {
  val r = runNode(
    scalarProgram,
    r"import { instantiate } from './prog.js';
const err = [];
const m = await instantiate(undefined, { stderr: (t) => err.push(t) });
let trapped = false;
try { m.bad(1); } catch (e) { trapped = e instanceof WebAssembly.RuntimeError; }
console.log('trapped=' + trapped);
console.log('stderr=' + err.join(''));
"
  )
  assertEqualInt(r.exitCode, 0, "node exits cleanly: " + r.stderr)
  assertTrue(Str.contains(r.stdout, "trapped=true\n"), "the abort surfaces as a wasm trap: " + r.stdout)
  assertTrue(Str.contains(r.stdout, "probe-panic"), "the panic message reaches the stderr hook: " + r.stdout)
}

test "wasm32 module: unsupported pub funcs are left out of the glue, the rest are exported" {
  val b = buildModule(
    r"package Probe

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
",
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
    r"package Probe

pub func one(): Int {
  1
}
",
    r"import { instantiate } from './prog.js';
const m = await instantiate();
console.log('one=' + m.one());
console.log('keys=' + Object.keys(m).sort().join(','));
"
  )
  assertEqualInt(r.exitCode, 0, "node exits cleanly: " + r.stderr)
  assertTrue(Str.contains(r.stdout, "one=1\n"), "a library with no main instantiates and calls: " + r.stdout)
  assertFalse(Str.contains(r.stdout, "run"), "no main, so no run: " + r.stdout)
}

val asyncProgram: String = r#"package Probe

import Std.Time

pub async func later(x: Int, ms: Int): Int {
  Time.sleepMillis(ms)
  x + 1
}

pub async func tag(s: String, ms: Int): String {
  Time.sleepMillis(ms)
  s + "!"
}

pub async func immediate(): Int {
  41
}

pub async func wide(x: Long): Long {
  Time.sleepMillis(5)
  x * 2i64
}

pub async func shrink(x: Double): Double {
  Time.sleepMillis(5)
  x / 4.0
}

func main(): Int {
  Time.sleepMillis(40)
  3
}
"#

test "wasm32 module: async exports return Promises driven by host timers" {
  val r = runNode(
    asyncProgram,
    r"import { instantiate } from './prog.js';
const m = await instantiate();
const t0 = performance.now();
const v = await m.later(41, 60);
const dt = performance.now() - t0;
console.log('later=' + v + ' waited=' + (dt >= 50));
console.log('tag=' + await m.tag('wörld', 10));
console.log('immediate=' + await m.immediate());
console.log('wide=' + await m.wide(3000000000n) + ' ' + typeof (await m.wide(1n)));
console.log('shrink=' + await m.shrink(10));
"
  )
  assertEqualInt(r.exitCode, 0, "node exits cleanly: " + r.stderr)
  assertTrue(Str.contains(r.stdout, "later=42 waited=true\n"), "an async export resolves after its sleep: " + r.stdout)
  assertTrue(Str.contains(r.stdout, "tag=wörld!\n"), "String argument and result through a task: " + r.stdout)
  assertTrue(Str.contains(r.stdout, "immediate=41\n"), "an async func that never suspends: " + r.stdout)
  assertTrue(Str.contains(r.stdout, "wide=6000000000 bigint\n"), "Long result: " + r.stdout)
  assertTrue(Str.contains(r.stdout, "shrink=2.5\n"), "Double result decoded from the slot bits: " + r.stdout)
}

test "wasm32 module: concurrent async exports interleave on one scheduler" {
  val r = runNode(
    asyncProgram,
    r"import { instantiate } from './prog.js';
const m = await instantiate();
const order = [];
const slow = m.later(1, 80).then((v) => order.push('slow' + v));
const fast = m.later(2, 10).then((v) => order.push('fast' + v));
await Promise.all([slow, fast]);
console.log('order=' + order.join(','));
"
  )
  assertEqualInt(r.exitCode, 0, "node exits cleanly: " + r.stderr)
  assertTrue(Str.contains(r.stdout, "order=fast3,slow2\n"), "the shorter sleep finishes first: " + r.stdout)
}

test "wasm32 module: a blocking sleep in run() waits through poll_oneoff" {
  val r = runNode(
    asyncProgram,
    r"import { instantiate } from './prog.js';
const m = await instantiate();
const t0 = performance.now();
const code = m.run([]);
const dt = performance.now() - t0;
console.log('code=' + code + ' waited=' + (dt >= 35));
"
  )
  assertEqualInt(r.exitCode, 0, "node exits cleanly: " + r.stderr)
  assertTrue(Str.contains(r.stdout, "code=3 waited=true\n"), "main sleeps 40ms then returns 3: " + r.stdout)
}

val hostImportProgram: String = r#"package Probe

@wasmImport("host")
extern func hostAdd(a: Int, b: Int): Int = "add"

@wasmImport("host")
extern func hostShout(s: String): String = "shout"

@wasmImport("host")
extern func hostBig(x: Long): Long = "big"

@wasmImport("host")
extern func hostFlag(b: Bool): Bool = "flag"

@wasmImport("ui")
extern func hostLog(msg: String): Unit = "log"

pub func viaHost(x: Int): Int {
  hostAdd(x, 100)
}

pub func shoutIt(s: String): String {
  hostShout(s) + "?"
}

pub func bigIt(x: Long): Long {
  hostBig(x)
}

pub func flagIt(b: Bool): Bool {
  hostFlag(b)
}

pub func logIt(m: String): Unit {
  hostLog(m)
}
"#

test "wasm32 module: @wasmImport externs call the JS the host passes to instantiate" {
  val r = runNode(
    hostImportProgram,
    r"import { instantiate } from './prog.js';
const log = [];
const m = await instantiate(undefined, { imports: {
  host: { add: (a, b) => a + b, shout: (s) => s.toUpperCase() + '!', big: (x) => x * 2n, flag: (b) => !b },
  ui: { log: (t) => log.push(t) },
} });
console.log('via=' + m.viaHost(5));
console.log('shout=' + m.shoutIt('wörld'));
console.log('big=' + m.bigIt(21n) + ' ' + typeof m.bigIt(1n));
console.log('flag=' + m.flagIt(true) + ',' + m.flagIt(false));
m.logIt('one'); m.logIt('two');
console.log('log=' + log.join('|'));
"
  )
  assertEqualInt(r.exitCode, 0, "node exits cleanly: " + r.stderr)
  assertTrue(Str.contains(r.stdout, "via=105\n"), "Int import: " + r.stdout)
  assertTrue(Str.contains(r.stdout, "shout=WÖRLD!?\n"), "String in and out of a host import: " + r.stdout)
  assertTrue(Str.contains(r.stdout, "big=42 bigint\n"), "Long import as bigint: " + r.stdout)
  assertTrue(Str.contains(r.stdout, "flag=false,true\n"), "Bool import: " + r.stdout)
  assertTrue(Str.contains(r.stdout, "log=one|two\n"), "Unit import in another module: " + r.stdout)
}

val asyncImportProgram: String = r#"package Probe

@wasmImport("net", promise)
extern func fetchText(url: String): String = "fetch-text"

@wasmImport("net", promise)
extern func slowAdd(a: Int, b: Int): Int = "slow-add"

@wasmImport("net", promise)
extern func slowBig(x: Long): Long = "slow-big"

@wasmImport("net", promise)
extern func slowHalf(x: Double): Double = "slow-half"

@wasmImport("net", promise)
extern func slowThird(x: Float): Float = "slow-third"

@wasmImport("net", promise)
extern func slowNot(b: Bool): Bool = "slow-not"

@wasmImport("net", promise)
extern func slowNext(b: Byte): Byte = "slow-next"

@wasmImport("net", promise)
extern func ping(): Unit = "ping"

@wasmImport("net", promise)
extern func boom(): Int = "boom"

pub async func load(url: String): String {
  fetchText(url) + "!"
}

pub async func sum(a: Int, b: Int): Int {
  val x = slowAdd(a, b)
  slowAdd(x, 10)
}

pub async func both(): Int {
  var total = 0
  scope {
    val a = spawn slowAdd(1, 1)
    val b = spawn slowAdd(2, 2)
    total = (await a) + (await b)
  }
  total
}

pub async func kinds(): String {
  val big = slowBig(21i64)
  val half = slowHalf(5.0)
  val third = slowThird(3.0)
  val flag = slowNot(true)
  val next = slowNext(255)
  ping()
  big.toString() + "," + half.toString() + "," + third.toString() + "," + flag.toString() + "," + next.toString()
}

pub async func failing(): Int {
  boom()
}

pub func syncCall(): Int {
  slowAdd(1, 2)
}
"#

val asyncImportHost: String = r"{
  'fetch-text': (u) => new Promise((r) => setTimeout(() => r('body of ' + u), 20)),
  'slow-add': (a, b) => new Promise((r) => setTimeout(() => r(a + b), 10)),
  'slow-big': async (x) => x * 2n,
  'slow-half': (x) => Promise.resolve(x / 2),
  'slow-third': async (x) => x / 3,
  'slow-not': (b) => Promise.resolve(!b),
  'slow-next': async (b) => (b + 1) & 255,
  'ping': async () => { globalThis.pinged = true; },
  'boom': () => Promise.reject(new Error('nope')),
}"

test "wasm32 module: a host import returning a Task is awaited by async Lyric code and finished by the promise" {
  val r = runNode(
    asyncImportProgram,
    r"import { instantiate } from './prog.js';
const m = await instantiate(undefined, { imports: { net: " +
      asyncImportHost +
      r" } });
console.log('load=' + await m.load('u'));
console.log('sum=' + await m.sum(1, 2));
console.log('both=' + await m.both());
console.log('kinds=' + await m.kinds() + ' pinged=' + globalThis.pinged);
const started = Date.now();
const results = await Promise.all([m.sum(1, 1), m.sum(2, 2), m.load('v'), m.both()]);
console.log('concurrent=' + results.join('|'));
console.log('overlapped=' + (Date.now() - started < 120));
"
  )
  assertEqualInt(r.exitCode, 0, "node exits cleanly: " + r.stderr)
  assertTrue(Str.contains(r.stdout, "load=body of u!\n"), "a String result through a promise: " + r.stdout)
  assertTrue(Str.contains(r.stdout, "sum=13\n"), "two awaits in a row: " + r.stdout)
  assertTrue(Str.contains(r.stdout, "both=6\n"), "two operations outstanding at once: " + r.stdout)
  assertTrue(
    Str.contains(r.stdout, "kinds=42,2.5,1,false,0 pinged=true\n"),
    "Long, Double, Float, Bool, Byte and Unit results: " + r.stdout
  )
  assertTrue(
    Str.contains(r.stdout, "concurrent=12|14|body of v!|6\n"),
    "calls interleave on one scheduler: " + r.stdout
  )
  assertTrue(
    Str.contains(r.stdout, "overlapped=true\n"),
    "the host operations overlap rather than run in turn: " + r.stdout
  )
}

test "wasm32 module: a rejected host promise panics the awaiting code with its message" {
  val r = runNode(
    asyncImportProgram,
    r"import { instantiate } from './prog.js';
const errs = [];
const m = await instantiate(undefined, { stderr: (t) => errs.push(t), imports: { net: " +
      asyncImportHost +
      r" } });
try { await m.failing(); console.log('failing=resolved'); } catch (e) { console.log('failing=rejected'); }
console.log('stderr=' + errs.join(''));
"
  )
  assertEqualInt(r.exitCode, 0, "node exits cleanly: " + r.stderr)
  assertTrue(Str.contains(r.stdout, "failing=rejected\n"), "the export's promise rejects: " + r.stdout)
  assertTrue(
    Str.contains(r.stdout, "host import failed: nope"),
    "the host's message reaches the stderr hook: " + r.stdout
  )
}

test "wasm32 module: calling a promise host import from a synchronous export says to make the caller async" {
  val r = runNode(
    asyncImportProgram,
    r"import { instantiate } from './prog.js';
const errs = [];
const m = await instantiate(undefined, { stderr: (t) => errs.push(t), imports: { net: " +
      asyncImportHost +
      r" } });
try { m.syncCall(); console.log('sync=returned'); } catch (e) { console.log('sync=trapped'); }
console.log('stderr=' + errs.join(''));
"
  )
  assertEqualInt(r.exitCode, 0, "node exits cleanly: " + r.stderr)
  assertTrue(Str.contains(r.stdout, "sync=trapped\n"), "the synchronous call traps: " + r.stdout)
  assertTrue(Str.contains(r.stdout, "make the caller an async func"), "with a message that names the fix: " + r.stdout)
}

test "wasm32 module: the .d.ts types an async host import as a promise or a value" {
  val b = buildModule(asyncImportProgram, "wasm32-wasi")
  assertTrue(b.ok, "the module builds")
  val dts = readGenerated(b.dir, "prog.d.ts")
  assertTrue(Str.contains(dts, "\"fetch-text\"(url: string): Promise<string> | string;"), "String task: " + dts)
  assertTrue(Str.contains(dts, "\"slow-big\"(x: bigint): Promise<bigint> | bigint;"), "Long task: " + dts)
  assertTrue(Str.contains(dts, "ping(): Promise<void> | void;"), "Unit task: " + dts)
}

test "wasm32 module: a missing host import is reported by name at instantiate" {
  val r = runNode(
    hostImportProgram,
    r"import { instantiate } from './prog.js';
try {
  await instantiate(undefined, { imports: { host: { add: (a, b) => a + b } } });
  console.log('instantiated');
} catch (e) {
  console.log('error=' + e.message);
}
"
  )
  assertEqualInt(r.exitCode, 0, "node exits cleanly: " + r.stderr)
  assertTrue(Str.contains(r.stdout, "missing host imports"), "names the problem: " + r.stdout)
  assertTrue(
    Str.contains(r.stdout, "ui.log") and Str.contains(r.stdout, "host.shout"),
    "lists the missing imports: " + r.stdout
  )
}

test "wasm32 module: the .d.ts types the host imports" {
  val b = buildModule(hostImportProgram, "wasm32-wasi")
  assertTrue(b.ok, "the module builds")
  val dts = readGenerated(b.dir, "prog.d.ts")
  assertTrue(Str.contains(dts, "export interface LyricHostImports"), "an imports interface: " + dts)
  assertTrue(Str.contains(dts, "add(a: number, b: number): number;"), "host.add is typed: " + dts)
  assertTrue(Str.contains(dts, "shout(s: string): string;"), "host.shout is typed: " + dts)
  assertTrue(Str.contains(dts, "log(msg: string): void;"), "ui.log is typed: " + dts)
}

test "wasm32 module: @wasmImport without the module shape is N0015" {
  if Environment.getVarOrDefault("WASI_SDK_PATH", "").length == 0 {
    panic("WASI_SDK_PATH is not set")
  }
  val stdlib = findStdlibSourcesNative()
  val dir = Path.join(tempBase(), "lyric-wasm32-module-" + Uuid.uuidToString(Uuid.newUuid()))
  val _ = File.createDir(dir)
  val flags: List[String] = newList()
  val ok = compileToNativeWithShape(
    hostImportProgram,
    Path.join(dir, "prog.wasm"),
    stdlib,
    "wasm32-wasi",
    "2",
    flags,
    newList(),
    "",
    true,
    ""
  )
  assertFalse(ok, "a plain wasm32 build cannot satisfy a host import")
}

test "wasm32 module: pub funcs named like glue members (run, memory) are left out, not clobbered" {
  val b = buildModule(
    r"package Probe

pub func run(x: Int): Int {
  x
}

pub func memory(x: Int): Int {
  x
}

pub func keep(x: Int): Int {
  x
}
",
    "wasm32-wasi"
  )
  assertTrue(b.ok, "the module builds")
  val js = readGenerated(b.dir, "prog.js")
  assertTrue(Str.contains(js, "wasm: \"Probe.keep\""), "keep is exported: " + js)
  assertFalse(Str.contains(js, "wasm: \"Probe.run\""), "run is the glue's entry point")
  assertFalse(Str.contains(js, "wasm: \"Probe.memory\""), "memory is the glue's memory export")
}

test "wasm32 module: a malformed @wasmImport is an error, not an ordinary extern" {
  val stdlib = findStdlibSourcesNative()
  val dir = Path.join(tempBase(), "lyric-wasm32-module-" + Uuid.uuidToString(Uuid.newUuid()))
  val _ = File.createDir(dir)
  val flags: List[String] = newList()
  val ok = compileToNativeWithShape(
    r#"package Probe

@wasmImport("")
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
    "module"
  )
  assertFalse(ok, "an empty module name must fail the build (N0014)")
}

val npmImportProgram: String = r#"package Probe

@wasmImport("npm:fakenpm")
extern func npmAdd(a: Int, b: Int): Int = "add"

@wasmImport("npm:fakenpm")
extern func npmShout(s: String): String = "shout"

pub func viaNpm(x: Int): Int {
  npmAdd(x, 1)
}

pub func shoutNpm(s: String): String {
  npmShout(s)
}
"#

test "wasm32 module: an npm: host import is satisfied by importing the package" {
  val r = runNodeWithFakeNpm(
    npmImportProgram,
    r"import { instantiate } from './prog.js';
const m = await instantiate();
console.log('add=' + m.viaNpm(5));
console.log('shout=' + m.shoutNpm('hi'));
"
  )
  assertEqualInt(r.exitCode, 0, "node exits cleanly: " + r.stderr)
  assertTrue(Str.contains(r.stdout, "add=1006\n"), "the package function ran: " + r.stdout)
  assertTrue(Str.contains(r.stdout, "shout=HI!\n"), "String through the package: " + r.stdout)
}

val npmPromiseProgram: String = r#"package Probe

@wasmImport("npm:fakenpm", promise)
extern func npmSlowAdd(a: Int, b: Int): Int = "slowAdd"

pub async func viaNpmAsync(x: Int): Int {
  npmSlowAdd(x, 1)
}
"#

test "wasm32 module: an npm: promise import awaits the package's async function" {
  val r = runNodeWithFakeNpm(
    npmPromiseProgram,
    r"import { instantiate } from './prog.js';
const m = await instantiate();
console.log('slow=' + await m.viaNpmAsync(5));
"
  )
  assertEqualInt(r.exitCode, 0, "node exits cleanly: " + r.stderr)
  assertTrue(Str.contains(r.stdout, "slow=2006\n"), "the package's promise settled into the waiting task: " + r.stdout)
}

test "wasm32 module: options.imports overrides an npm: package" {
  val r = runNodeWithFakeNpm(
    npmImportProgram,
    r"import { instantiate } from './prog.js';
const m = await instantiate(undefined, { imports: { 'npm:fakenpm': { add: (a, b) => a * b, shout: (s) => s + s } } });
console.log('add=' + m.viaNpm(5));
console.log('shout=' + m.shoutNpm('ab'));
"
  )
  assertEqualInt(r.exitCode, 0, "node exits cleanly: " + r.stderr)
  assertTrue(Str.contains(r.stdout, "add=5\n"), "the override ran: " + r.stdout)
  assertTrue(Str.contains(r.stdout, "shout=abab\n"), "the String override ran: " + r.stdout)
}

test "wasm32 module: a missing npm: package names the import and the remedy" {
  val b = buildModule(npmImportProgram, "wasm32-wasi")
  assertTrue(b.ok, "the module builds")
  writeIn(
    b.dir,
    "run.mjs",
    "import { instantiate } from './prog.js';\ntry { await instantiate(); console.log('instantiated'); } catch (e) { console.log('error=' + e.message); }\n"
  )
  val args: List[String] = newList()
  args.add(Path.join(b.dir, "run.mjs"))
  match Process.runCapture(Environment.getVarOrDefault("NODE", "node"), args, 120000) {
    case Err(e) -> panic("node could not be started: " + e)
    case Ok(r) -> {
      assertTrue(Str.contains(r.stdout, "npm:fakenpm"), "names the import: " + r.stdout)
      assertTrue(Str.contains(r.stdout, "lyric restore"), "names the remedy: " + r.stdout)
    }
  }
}

test "wasm32 module: the .d.ts makes npm: imports optional" {
  val b = buildModule(npmImportProgram, "wasm32-wasi")
  assertTrue(b.ok, "the module builds")
  val dts = readGenerated(b.dir, "prog.d.ts")
  assertTrue(Str.contains(dts, "\"npm:fakenpm\"?: {"), "the module is optional: " + dts)
  assertTrue(Str.contains(dts, "add(a: number, b: number): number;"), "the function is typed: " + dts)
  assertTrue(Str.contains(dts, "options?: LyricInstantiateOptions"), "instantiate needs no options: " + dts)
}

test "wasm32 module: an npm: package's CommonJS exports that Node cannot scan statically still resolve" {
  val b = buildModule(npmImportProgram, "wasm32-wasi")
  assertTrue(b.ok, "the module builds")
  writeIn(
    b.dir,
    "node_modules/fakenpm/package.json",
    "{ \"name\": \"fakenpm\", \"version\": \"1.0.0\", \"main\": \"index.js\" }\n"
  )
  writeIn(
    b.dir,
    "node_modules/fakenpm/index.js",
    "const o = {};\no['ad' + 'd'] = (a, b) => a + b + 2000;\no['sh' + 'out'] = function (s) { return this.mark(s.toUpperCase()); };\no.mark = (s) => s + '?';\nmodule.exports = o;\n"
  )
  writeIn(
    b.dir,
    "run.mjs",
    "import { instantiate } from './prog.js';\nconst m = await instantiate();\nconsole.log('add=' + m.viaNpm(5));\nconsole.log('shout=' + m.shoutNpm('hi'));\n"
  )
  val args: List[String] = newList()
  args.add(Path.join(b.dir, "run.mjs"))
  match Process.runCapture(Environment.getVarOrDefault("NODE", "node"), args, 120000) {
    case Err(e) -> panic("node could not be started: " + e)
    case Ok(r) -> {
      assertEqualInt(r.exitCode, 0, "node exits cleanly: " + r.stderr)
      assertTrue(Str.contains(r.stdout, "add=2006\n"), "a dynamically assigned CJS export ran: " + r.stdout)
      assertTrue(Str.contains(r.stdout, "shout=HI?\n"), "a second one ran: " + r.stdout)
    }
  }
}
