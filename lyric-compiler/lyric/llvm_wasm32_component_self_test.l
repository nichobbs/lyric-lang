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
import Std.Parse as Parse
import Lyric.Emitter
import Lyric.LlvmBridge
import Lyric.DiagnosticUtil as DiagUtil

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
  buildComponentOf(program)
}

func buildComponentOf(source: in String): String {
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
    source,
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

val richProgram: String = r#"package Probe

record Point {
  x: Int
  y: Int
}

record Person {
  name: String
  age: Int
  tags: List[String]
  home: Option[Point]
}

enum Color {
  case Red
  case Green
  case Blue
}

union Shape {
  case Square(side: Double)
  case Circle(radius: Double)
  case Label(text: String)
  case Empty
}

pub func mkPoint(x: Int, y: Int): Point {
  Point(x = x, y = y)
}

pub func swap(p: Point): Point {
  Point(x = p.y, y = p.x)
}

pub func makePerson(name: String, age: Int): Person {
  Person(name = name, age = age, tags = [name, "tag"], home = Some(value = Point(x = age, y = 2)))
}

pub func older(p: Person): Person {
  Person(name = p.name, age = p.age + 1, tags = p.tags, home = p.home)
}

pub func firstTag(p: Person): Option[String] {
  if p.tags.count > 0 {
    Some(value = p.tags[0])
  } else {
    None
  }
}

pub func optInt(b: Bool): Option[Int] {
  if b {
    Some(value = 42)
  } else {
    None
  }
}

pub func safeDiv(a: Int, b: Int): Result[Int, String] {
  if b == 0 {
    Err(error = "divide by zero")
  } else {
    Ok(value = a / b)
  }
}

pub func sumAll(xs: List[Int]): Int {
  var t = 0
  for x in xs {
    t = t + x
  }
  t
}

pub func names(ps: List[Person]): List[String] {
  val acc: List[String] = newList()
  for p in ps {
    acc.add(p.name)
  }
  acc
}

pub func evens(n: Int): List[Int] {
  val acc: List[Int] = newList()
  var i = 0
  while i < n {
    acc.add(i * 2)
    i = i + 1
  }
  acc
}

pub func nextColor(c: Color): Color {
  match c {
    case Color.Red -> Color.Green
    case Color.Green -> Color.Blue
    case Color.Blue -> Color.Red
  }
}

pub func mkShape(k: Int): Shape {
  if k == 0 {
    Square(side = 2.0)
  } else if k == 1 {
    Circle(radius = 1.5)
  } else if k == 2 {
    Label(text = "hi")
  } else {
    Empty
  }
}

pub func describe(s: Shape): String {
  match s {
    case Square(side) -> "square"
    case Circle(radius) -> "circle"
    case Label(text) -> text
    case Empty -> "empty"
  }
}

pub func many(a: Int, b: Int, c: Int, d: Int, e: Int, f: Int, g: Int, h: Int, i: Int, j: Int, k: Int, l: Int, m: Int, n: Int, o: Int, p: Int, q: Int, r: Int): Int {
  a + b + c + d + e + f + g + h + i + j + k + l + m + n + o + p + q + r
}
"#

test "wasm32 component: a missing adapter is N0016, not a crash" {
  val _w = envOrPanic("WASI_SDK_PATH")
  val _t = envOrPanic("WASM_TOOLS")
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

val importProgram: String = r#"package Probe

import Std.Console

@wasmImport("ui")
extern func hostLog(msg: String): Unit = "log"

@wasmImport("ui")
extern func hostAdd(a: Int, b: Int): Int = "add"

@wasmImport("ui")
extern func hostGreet(name: String): String = "greet"

@wasmImport("math")
extern func hostHalf(x: Double): Double = "half"

@wasmImport("math")
extern func hostNot(b: Bool): Bool = "not"

@wasmImport("math")
extern func hostNext(b: Byte): Byte = "next"

pub func flip(b: Bool): Bool {
  hostNot(b)
}

pub func bump(b: Byte): Byte {
  hostNext(b)
}

pub func go(n: Int): Int {
  hostLog("go called")
  hostAdd(n, 40)
}

pub func hello(name: String): String {
  hostGreet(name) + "!"
}

pub func halve(x: Double): Double {
  hostHalf(x)
}
"#

test "wasm32 component: @wasmImport lowers to WIT imports the host satisfies" {
  val dir = buildComponentOf(importProgram)
  val wasm = Path.join(dir, "prog.wasm")
  val wit = match File.readText(Path.join(dir, "prog.wit")) { case Ok(t) -> t; case Err(_) -> "" }
  assertTrue(
    Str.contains(wit, "interface ui") and Str.contains(wit, "interface math"),
    "an interface per import module: " + wit
  )
  assertTrue(
    Str.contains(wit, "import ui;") and Str.contains(wit, "greet: func(name: string) -> string"),
    "world imports and signatures: " + wit
  )
  val vargs: List[String] = newList()
  vargs.add("validate")
  vargs.add(wasm)
  val v = run(envOrPanic("WASM_TOOLS"), vargs)
  assertTrue(v.exitCode == 0, "wasm-tools validate: " + v.stderr)
  val outDir = Path.join(dir, "js")
  val jargs: List[String] = newList()
  jargs.add("transpile")
  jargs.add(wasm)
  jargs.add("-o")
  jargs.add(outDir)
  jargs.add("--map")
  jargs.add("lyric:probe/ui@0.1.0=../ui.js")
  jargs.add("--map")
  jargs.add("lyric:probe/math@0.1.0=../math.js")
  val j = run(envOrPanic("JCO"), jargs)
  assertTrue(j.exitCode == 0, "jco transpile: " + j.stderr)
  val lnargs: List[String] = newList()
  lnargs.add("-s")
  lnargs.add(envOrPanic("LYRIC_JCO_NODE_MODULES"))
  lnargs.add(Path.join(dir, "node_modules"))
  val _ln = run("ln", lnargs)
  val _u = File.writeText(
    Path.join(dir, "ui.js"),
    r"export const log = (m) => { globalThis.__logged = m; };
export const add = (a, b) => a + b;
export const greet = (n) => 'hi ' + n;
"
  )
  val _m = File.writeText(
    Path.join(dir, "math.js"),
    r"export const half = (x) => x / 2;
export const not = (b) => !b;
export const next = (b) => (b + 1) & 255;
"
  )
  val script = r"import * as m from './js/prog.js';
const p = m.probe;
console.log('go=' + p.go(2) + ' logged=' + globalThis.__logged);
console.log('hello=' + p.hello('wörld ☃'));
console.log('halve=' + p.halve(5));
console.log('flip=' + p.flip(true) + ',' + p.flip(false) + ' bump=' + p.bump(41) + ',' + p.bump(255));
"
  val scriptPath = Path.join(dir, "run.mjs")
  val _s = File.writeText(scriptPath, script)
  val nargs: List[String] = newList()
  nargs.add(scriptPath)
  val n = run(Environment.getVarOrDefault("NODE", "node"), nargs)
  assertTrue(n.exitCode == 0, "node: " + n.stderr + n.stdout)
  assertTrue(Str.contains(n.stdout, "flip=false,true bump=42,0"), "Bool and Byte through an import: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "go=42 logged=go called"), "host call and Unit import: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "hello=hi wörld ☃!"), "string in and out through an import: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "halve=2.5"), "Double through a second import module: " + n.stdout)
}

test "wasm32 component: records, options, results, lists, enums and variants cross the boundary" {
  val dir = buildComponentOf(richProgram)
  val wasm = Path.join(dir, "prog.wasm")
  val vargs: List[String] = newList()
  vargs.add("validate")
  vargs.add(wasm)
  val v = run(envOrPanic("WASM_TOOLS"), vargs)
  assertTrue(v.exitCode == 0, "wasm-tools validate: " + v.stderr)
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
  val _ln = run("ln", lnargs)
  val script = r"import * as m from './js/prog.js';
const p = m.probe;
const show = (v) => JSON.stringify(v, (k, x) => typeof x === 'bigint' ? Number(x) : x);
console.log('mkPoint=' + show(p.mkPoint(3, 4)));
console.log('swap=' + show(p.swap({ x: 1, y: 2 })));
const per = p.makePerson('ann', 30);
console.log('person=' + show(per));
console.log('older=' + show(p.older(per)));
console.log('firstTag=' + show(p.firstTag(per)));
console.log('optSome=' + show(p.optInt(true)) + ' optNone=' + show(p.optInt(false)));
console.log('divOk=' + show(p.safeDiv(10, 2)));
try { p.safeDiv(1, 0); console.log('divErr=none'); } catch (e) { console.log('divErr=' + show(e.payload ?? e)); }
console.log('sumAll=' + p.sumAll(new Int32Array([1, 2, 3, 4])));
console.log('names=' + show(p.names([p.makePerson('a', 1), p.makePerson('bb', 2)])));
console.log('evens=' + show(Array.from(p.evens(5))));
console.log('empty=' + show(Array.from(p.evens(0))));
console.log('color=' + p.nextColor('red') + ',' + p.nextColor('blue'));
console.log('shapes=' + [0, 1, 2, 3].map((k) => show(p.mkShape(k))).join(';'));
console.log('describe=' + p.describe({ tag: 'label', val: 'xyz' }) + ',' + p.describe({ tag: 'empty' }));
console.log('many=' + p.many(1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18));
"
  val scriptPath = Path.join(dir, "run.mjs")
  val _s = File.writeText(scriptPath, script)
  val nargs: List[String] = newList()
  nargs.add(scriptPath)
  val n = run(Environment.getVarOrDefault("NODE", "node"), nargs)
  assertTrue(n.exitCode == 0, "node: " + n.stderr + n.stdout)
  assertTrue(Str.contains(n.stdout, "mkPoint={\"x\":3,\"y\":4}"), "mkPoint: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "swap={\"x\":2,\"y\":1}"), "swap: " + n.stdout)
  assertTrue(
    Str.contains(
      n.stdout,
      "person={\"name\":\"ann\",\"age\":30,\"tags\":[\"ann\",\"tag\"],\"home\":{\"x\":30,\"y\":2}}"
    ),
    "person: " + n.stdout
  )
  assertTrue(Str.contains(n.stdout, "\"age\":31"), "older: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "firstTag=\"ann\""), "firstTag: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "optSome=42 optNone=undefined"), "options: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "divOk=5"), "divOk: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "divErr=\"divide by zero\""), "divErr: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "sumAll=10"), "sumAll: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "names=[\"a\",\"bb\"]"), "names: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "evens=[0,2,4,6,8]"), "evens: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "empty=[]"), "empty list: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "color=green,red"), "enum: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "{\"tag\":\"square\",\"val\":2}"), "variant: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "describe=xyz,empty"), "describe: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "many=171"), "spilled params: " + n.stdout)
}

test "wasm32 component: colliding WIT names are left out with the interface still valid" {
  val dir = buildComponentOf(
    r"package Probe

record Item {
  n: Int
}

pub func Item(n: Int): Int {
  n
}

pub func fooBar(n: Int): Int {
  n + 1
}

pub func foo_bar(n: Int): Int {
  n + 2
}

pub func keep(n: Int): Int {
  n
}
"
  )
  val wit = match File.readText(Path.join(dir, "prog.wit")) { case Ok(t) -> t; case Err(_) -> "" }
  assertTrue(Str.contains(wit, "foo-bar: func"), "the first of two colliding names is kept: " + wit)
  assertTrue(Str.contains(wit, "keep: func"), "keep is exported: " + wit)
  assertFalse(Str.contains(wit, "item: func"), "a function named like a record is left out: " + wit)
  val vargs: List[String] = newList()
  vargs.add("validate")
  vargs.add(Path.join(dir, "prog.wasm"))
  val v = run(envOrPanic("WASM_TOOLS"), vargs)
  assertTrue(v.exitCode == 0, "the component validates: " + v.stderr)
}

test "wasm32 component: two exporting packages in one project each get an interface" {
  val _w = envOrPanic("WASI_SDK_PATH")
  val stdlib = findStdlibSourcesNative()
  val dir = Path.join(
    Environment.getVarOrDefault("TMPDIR", "/tmp"),
    "lyric-wasm32-component-proj-" + Uuid.uuidToString(Uuid.newUuid())
  )
  val _d = File.createDir(dir)
  val pkgs: List[NativeSourcePackage] = newList()
  pkgs.add(
    NativeSourcePackage(
      name = "Proj.Math",
      path = "",
      source = "package Proj.Math\npub func add(a: Int, b: Int): Int {\n  a + b\n}\n"
    )
  )
  pkgs.add(
    NativeSourcePackage(
      name = "Proj.Text",
      path = "",
      source = "package Proj.Text\npub func shout(s: String): String {\n  s + \"!\"\n}\n"
    )
  )
  val flags: List[String] = newList()
  val noFeatures: List[String] = newList()
  val noOrigins: List[DiagUtil.PackageLineOrigins] = newList()
  val ok = compileProjectToNativeWithShape(
    pkgs,
    Path.join(dir, "prog.wasm"),
    stdlib,
    "wasm32-wasi",
    "2",
    flags,
    newList(),
    noFeatures,
    noFeatures,
    "",
    noOrigins,
    true,
    "component"
  )
  assertTrue(ok, "the two-package component builds")
  val wit = match File.readText(Path.join(dir, "prog.wit")) { case Ok(t) -> t; case Err(_) -> "" }
  assertTrue(
    Str.contains(wit, "interface proj-math") and Str.contains(wit, "interface proj-text"),
    "an interface per package: " + wit
  )
  val vargs: List[String] = newList()
  vargs.add("validate")
  vargs.add(Path.join(dir, "prog.wasm"))
  val v = run(envOrPanic("WASM_TOOLS"), vargs)
  assertTrue(v.exitCode == 0, "the component validates: " + v.stderr)
}

func componentBuildOk(source: in String): Bool {
  val stdlib = findStdlibSourcesNative()
  val dir = Path.join(
    Environment.getVarOrDefault("TMPDIR", "/tmp"),
    "lyric-wasm32-component-neg-" + Uuid.uuidToString(Uuid.newUuid())
  )
  val _d = File.createDir(dir)
  val flags: List[String] = newList()
  compileToNativeWithShape(
    source,
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
}

test "wasm32 component: host imports with unsupported shapes are rejected" {
  val _w = envOrPanic("WASI_SDK_PATH")
  val _t = envOrPanic("WASM_TOOLS")
  val _a = envOrPanic("LYRIC_WASI_ADAPTER")
  assertFalse(
    componentBuildOk(
      r#"package Probe

record Box[T] {
  value: T
}

@wasmImport("ui")
extern func flag(b: Box[Int]): Unit = "flag"

pub func go(): Unit {
  flag(Box(value = 1))
}
"#
    ),
    "a generic record has no WIT equivalent, so it is not carried across a host import"
  )
  assertFalse(
    componentBuildOk(
      r#"package Probe

@wasmImport("")
extern func bad(n: Int): Unit = "bad"

pub func go(): Unit {
  bad(1)
}
"#
    ),
    "an empty module name is malformed"
  )
  assertFalse(
    componentBuildOk(
      r#"package Probe

record Point {
  x: Int
  y: Int
}

@wasmImport("ui")
extern func point(p: Point): Point = "point"

pub func go(): Int {
  point(Point(x = 1, y = 2)).x
}
"#
    ),
    "a host function named like a type of its own interface is a WIT name clash"
  )
}

test "wasm32 component: externs binding one host function share a single import" {
  val dir = buildComponentOf(
    r#"package Probe

@wasmImport("ui")
extern func hostAdd(a: Int, b: Int): Int = "add"

@wasmImport("ui")
extern func hostAddAgain(a: Int, b: Int): Int = "add"

pub func go(n: Int): Int {
  hostAdd(n, 1) + hostAddAgain(n, 2)
}
"#
  )
  val wit = match File.readText(Path.join(dir, "prog.wit")) { case Ok(t) -> t; case Err(_) -> "" }
  assertTrue(Str.contains(wit, "add: func(a: s32, b: s32) -> s32;"), "the function is declared: " + wit)
  val first = Str.indexOfRaw(wit, "add: func")
  val rest = Str.substring(wit, first + 9, wit.length - first - 9)
  assertFalse(Str.contains(rest, "add: func"), "and declared once: " + wit)
  val vargs: List[String] = newList()
  vargs.add("validate")
  vargs.add(Path.join(dir, "prog.wasm"))
  val v = run(envOrPanic("WASM_TOOLS"), vargs)
  assertTrue(v.exitCode == 0, "the component validates: " + v.stderr)
}

test "wasm32 component: one host function declared with two signatures is an error" {
  val _w = envOrPanic("WASI_SDK_PATH")
  val _t = envOrPanic("WASM_TOOLS")
  val _a = envOrPanic("LYRIC_WASI_ADAPTER")
  assertFalse(
    componentBuildOk(
      r#"package Probe

@wasmImport("ui")
extern func hostAdd(a: Int, b: Int): Int = "add"

@wasmImport("ui")
extern func hostAddLong(a: Long, b: Long): Long = "add"

pub func go(n: Int): Int {
  hostAdd(n, 1)
}
"#
    ),
    "the same host function with different signatures cannot be one WIT function"
  )
}

test "wasm32 component: host imports whose names sanitize alike stay distinct" {
  val dir = buildComponentOf(
    r#"package Probe

@wasmImport("ui.log")
extern func a(n: Int): Int = "x"

@wasmImport("ui")
extern func b(n: Int): Int = "log.x"

pub func go(n: Int): Int {
  a(n) + b(n)
}
"#
  )
  val wit = match File.readText(Path.join(dir, "prog.wit")) { case Ok(t) -> t; case Err(_) -> "" }
  assertTrue(Str.contains(wit, "interface ui-log") and Str.contains(wit, "interface ui {"), "two interfaces: " + wit)
  val vargs: List[String] = newList()
  vargs.add("validate")
  vargs.add(Path.join(dir, "prog.wasm"))
  val v = run(envOrPanic("WASM_TOOLS"), vargs)
  assertTrue(v.exitCode == 0, "the component validates: " + v.stderr)
}

test "wasm32 component: host import names that fold to one WIT name are an error" {
  val _w = envOrPanic("WASI_SDK_PATH")
  val _t = envOrPanic("WASM_TOOLS")
  val _a = envOrPanic("LYRIC_WASI_ADAPTER")
  assertFalse(
    componentBuildOk(
      r#"package Probe

@wasmImport("ui.log")
extern func a(n: Int): Int = "x"

@wasmImport("ui-log")
extern func b(n: Int): Int = "x"

pub func go(n: Int): Int {
  a(n) + b(n)
}
"#
    ),
    "two modules that fold to one WIT interface name"
  )
  assertFalse(
    componentBuildOk(
      r#"package Probe

@wasmImport("ui")
extern func a(n: Int): Int = "log.x"

@wasmImport("ui")
extern func b(n: Int): Int = "log-x"

pub func go(n: Int): Int {
  a(n) + b(n)
}
"#
    ),
    "two functions of one module that fold to one WIT function name"
  )
  assertFalse(
    componentBuildOk(
      r#"package Probe

@wasmImport("probe")
extern func a(n: Int): Int = "x"

pub func go(n: Int): Int {
  a(n)
}
"#
    ),
    "a module named like the exported package"
  )
}

test "wasm32 component: host import names must be WIT-safe identifiers" {
  val _w = envOrPanic("WASI_SDK_PATH")
  val _t = envOrPanic("WASM_TOOLS")
  val _a = envOrPanic("LYRIC_WASI_ADAPTER")
  assertFalse(
    componentBuildOk(
      r#"package Probe

@wasmImport("ui log")
extern func a(n: Int): Int = "x"

pub func go(n: Int): Int {
  a(n)
}
"#
    ),
    "a module name with a space is not a WIT identifier"
  )
  assertFalse(
    componentBuildOk(
      r#"package Probe

@wasmImport("ui")
extern func a(n: Int): Int = "9lives"

pub func go(n: Int): Int {
  a(n)
}
"#
    ),
    "an import name starting with a digit is not a WIT identifier"
  )
}

func componentBuildDir(source: in String, shape: in String): String {
  val _w = envOrPanic("WASI_SDK_PATH")
  val stdlib = findStdlibSourcesNative()
  val dir = Path.join(
    Environment.getVarOrDefault("TMPDIR", "/tmp"),
    "lyric-wasm32-component-opt-" + Uuid.uuidToString(Uuid.newUuid())
  )
  val _d = File.createDir(dir)
  val flags: List[String] = newList()
  val ok = compileToNativeWithShape(
    source,
    Path.join(dir, "prog.wasm"),
    stdlib,
    "wasm32-wasi",
    "2",
    flags,
    newList(),
    "",
    true,
    shape
  )
  if not ok {
    panic("wasm32 component compilation failed for shape " + shape)
  }
  dir
}

test "wasm32 component: the shape options set the WIT version, world and stack size" {
  val dir = componentBuildDir(program, "component;version=2.3.4;world=my-world;stack=131072")
  val wit = match File.readText(Path.join(dir, "prog.wit")) { case Ok(t) -> t; case Err(_) -> "" }
  assertTrue(Str.contains(wit, "package lyric:probe@2.3.4;"), "version: " + wit)
  assertTrue(Str.contains(wit, "world my-world {"), "world: " + wit)
  val vargs: List[String] = newList()
  vargs.add("validate")
  vargs.add(Path.join(dir, "prog.wasm"))
  val v = run(envOrPanic("WASM_TOOLS"), vargs)
  assertTrue(v.exitCode == 0, "the component validates: " + v.stderr)
}

// The initial value of the core module's `__stack_pointer` global: the top of
// the stack region, so two builds of one program differ by exactly the
// difference of their stack sizes.
func stackPointerInit(wasmPath: in String): Int {
  val pargs: List[String] = newList()
  pargs.add("print")
  pargs.add(wasmPath)
  val printed = run(envOrPanic("WASM_TOOLS"), pargs)
  val marker = "$__stack_pointer (;0;) (mut i32) i32.const "
  match Str.indexOf(printed.stdout, marker) {
    case None -> panic("no __stack_pointer global in " + wasmPath)
    case Some(at) -> {
      val rest = Str.substring(printed.stdout, at + marker.length)
      val parts = Str.split(rest, ")")
      match Parse.parseOptInt(parts[0]) {
        case Some(n) -> n
        case None -> panic("unreadable __stack_pointer initializer: " + parts[0])
      }
    }
  }
}

test "wasm32 component: the stack option moves the stack pointer by the size difference" {
  val small = componentBuildDir(program, "component;stack=65536")
  val large = componentBuildDir(program, "component;stack=131072")
  val delta = stackPointerInit(Path.join(large, "prog.wasm")) - stackPointerInit(Path.join(small, "prog.wasm"))
  assertTrue(delta == 65536, "a 64 KiB larger stack raises the stack pointer by 65536, got " + delta.toString())
}

test "wasm32 component: a package that only imports host functions builds" {
  val dir = componentBuildDir(
    r#"package Probe

@wasmImport("ui")
extern func hostAdd(a: Int, b: Int): Int = "add"

func unused(): Int {
  hostAdd(1, 2)
}
"#,
    "component"
  )
  val wit = match File.readText(Path.join(dir, "prog.wit")) { case Ok(t) -> t; case Err(_) -> "" }
  assertTrue(Str.contains(wit, "interface ui") and Str.contains(wit, "import ui;"), "the import is declared: " + wit)
  val vargs: List[String] = newList()
  vargs.add("validate")
  vargs.add(Path.join(dir, "prog.wasm"))
  val v = run(envOrPanic("WASM_TOOLS"), vargs)
  assertTrue(v.exitCode == 0, "the component validates: " + v.stderr)
}

val npmImportProgram: String = r#"package Probe

@wasmImport("npm:@scope/fake.pkg")
extern func npmAdd(a: Int, b: Int): Int = "add"

@wasmImport("npm:@scope/fake.pkg")
extern func npmShout(s: String): String = "shout"

pub func viaNpm(x: Int): Int {
  npmAdd(x, 1)
}

pub func shoutNpm(s: String): String {
  npmShout(s)
}
"#

test "wasm32 component: an npm: host import is a WIT import jco satisfies with the package" {
  val dir = buildComponentOf(npmImportProgram)
  val wasm = Path.join(dir, "prog.wasm")
  val wit = match File.readText(Path.join(dir, "prog.wit")) { case Ok(t) -> t; case Err(_) -> "" }
  assertTrue(Str.contains(wit, "interface npm-scope-fake-pkg"), "the package is a WIT interface: " + wit)
  assertTrue(Str.contains(wit, "import npm-scope-fake-pkg;"), "the world imports it: " + wit)
  val vargs: List[String] = newList()
  vargs.add("validate")
  vargs.add(wasm)
  val v = run(envOrPanic("WASM_TOOLS"), vargs)
  assertTrue(v.exitCode == 0, "wasm-tools validate: " + v.stderr)
  val outDir = Path.join(dir, "js")
  val jargs: List[String] = newList()
  jargs.add("transpile")
  jargs.add(wasm)
  jargs.add("-o")
  jargs.add(outDir)
  jargs.add("--map")
  jargs.add("lyric:probe/npm-scope-fake-pkg@0.1.0=@scope/fake.pkg")
  val j = run(envOrPanic("JCO"), jargs)
  assertTrue(j.exitCode == 0, "jco transpile: " + j.stderr)
  val lnargs: List[String] = newList()
  lnargs.add("-s")
  lnargs.add(envOrPanic("LYRIC_JCO_NODE_MODULES"))
  lnargs.add(Path.join(dir, "node_modules"))
  val _ln = run("ln", lnargs)
  val pkgDir = Path.join(Path.join(Path.join(outDir, "node_modules"), "@scope"), "fake.pkg")
  val _pd = File.createDir(pkgDir)
  val _pj = File.writeText(
    Path.join(pkgDir, "package.json"),
    "{ \"name\": \"@scope/fake.pkg\", \"version\": \"1.0.0\", \"type\": \"module\", \"main\": \"index.js\" }\n"
  )
  val _ix = File.writeText(
    Path.join(pkgDir, "index.js"),
    "export function add(a, b) { return a + b + 1000; }\nexport function shout(s) { return s.toUpperCase() + '!'; }\n"
  )
  val scriptPath = Path.join(dir, "run.mjs")
  val _s = File.writeText(
    scriptPath,
    r"import * as m from './js/prog.js';
console.log('add=' + m.probe.viaNpm(5));
console.log('shout=' + m.probe.shoutNpm('hi'));
"
  )
  val nargs: List[String] = newList()
  nargs.add(scriptPath)
  val n = run(Environment.getVarOrDefault("NODE", "node"), nargs)
  assertTrue(n.exitCode == 0, "node: " + n.stderr + n.stdout)
  assertTrue(Str.contains(n.stdout, "add=1006"), "the package function ran: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "shout=HI!"), "String through the package: " + n.stdout)
}

test "wasm32 component: an npm: module with no package name is rejected" {
  assertFalse(
    componentBuildOk(
      "package Probe\n\n@wasmImport(\"npm:\")\nextern func f(a: Int): Int = \"f\"\n\npub func g(a: Int): Int {\n  f(a)\n}\n"
    ),
    "npm: alone names no package"
  )
}

val bindingsProgram: String = r#"package Probe

@wasmImport("ui")
extern func shout(s: String): String = "shout"

@wasmImport("npm:@scope/fake.pkg")
extern func npmAdd(a: Int, b: Int): Int = "add"

pub func viaUi(s: String): String {
  shout(s)
}

pub func viaNpm(x: Int): Int {
  npmAdd(x, 1)
}
"#

func buildWithOptions(source: in String, shape: in String, label: in String): String {
  val _w = envOrPanic("WASI_SDK_PATH")
  val stdlib = findStdlibSourcesNative()
  val dir = Path.join(
    Environment.getVarOrDefault("TMPDIR", "/tmp"),
    "lyric-wasm32-component-" + label + "-" + Uuid.uuidToString(Uuid.newUuid())
  )
  val _d = File.createDir(dir)
  val flags: List[String] = newList()
  val ok = compileToNativeWithShape(
    source,
    Path.join(dir, "prog.wasm"),
    stdlib,
    "wasm32-wasi",
    "2",
    flags,
    newList(),
    "",
    true,
    shape
  )
  if not ok {
    panic("wasm32 component compilation failed for shape " + shape)
  }
  dir
}

test "wasm32 component: --wit-out writes the WIT where asked" {
  val dir = Path.join(
    Environment.getVarOrDefault("TMPDIR", "/tmp"),
    "lyric-wasm32-component-witout-" + Uuid.uuidToString(Uuid.newUuid())
  )
  val witPath = Path.join(Path.join(dir, "wit"), "api.wit")
  val built = buildWithOptions(program, "component;wit=" + witPath, "witout")
  assertTrue(File.fileExists(Path.join(built, "prog.wasm")), "the component is written")
  assertFalse(File.fileExists(Path.join(built, "prog.wit")), "the WIT is not also written beside it")
  val wit = match File.readText(witPath) { case Ok(t) -> t; case Err(_) -> "" }
  assertTrue(Str.contains(wit, "package lyric:probe@0.1.0;"), "the WIT is at the requested path: " + wit)
}

test "wasm32 component: --js-bindings runs jco with the host imports mapped" {
  val dir = buildWithOptions(bindingsProgram, "component;js", "jsbind")
  val jsDir = Path.join(dir, "prog-js")
  assertTrue(File.fileExists(Path.join(jsDir, "prog.js")), "jco wrote the bindings beside the component")
  val lnargs: List[String] = newList()
  lnargs.add("-s")
  lnargs.add(envOrPanic("LYRIC_JCO_NODE_MODULES"))
  lnargs.add(Path.join(dir, "node_modules"))
  val _ln = run("ln", lnargs)
  val _u = File.writeText(Path.join(dir, "ui.js"), "export const shout = (s) => s.toUpperCase() + '!';\n")
  val pkgDir = Path.join(Path.join(Path.join(jsDir, "node_modules"), "@scope"), "fake.pkg")
  val _pd = File.createDir(pkgDir)
  val _pj = File.writeText(
    Path.join(pkgDir, "package.json"),
    "{ \"name\": \"@scope/fake.pkg\", \"version\": \"1.0.0\", \"type\": \"module\", \"main\": \"index.js\" }\n"
  )
  val _ix = File.writeText(Path.join(pkgDir, "index.js"), "export function add(a, b) { return a + b + 1000; }\n")
  val scriptPath = Path.join(dir, "run.mjs")
  val _s = File.writeText(
    scriptPath,
    r"import * as m from './prog-js/prog.js';
console.log('ui=' + m.probe.viaUi('hi'));
console.log('npm=' + m.probe.viaNpm(5));
"
  )
  val nargs: List[String] = newList()
  nargs.add(scriptPath)
  val n = run(Environment.getVarOrDefault("NODE", "node"), nargs)
  assertTrue(n.exitCode == 0, "node: " + n.stderr + n.stdout)
  assertTrue(Str.contains(n.stdout, "ui=HI!"), "the plain host module is ../ui.js: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "npm=1006"), "the npm: module is the package: " + n.stdout)
}

test "wasm32 component: --js-bindings without jco is N0022, not a crash" {
  val _w = envOrPanic("WASI_SDK_PATH")
  val stdlib = findStdlibSourcesNative()
  val dir = Path.join(
    Environment.getVarOrDefault("TMPDIR", "/tmp"),
    "lyric-wasm32-component-nojco-" + Uuid.uuidToString(Uuid.newUuid())
  )
  val _d = File.createDir(dir)
  val flags: List[String] = newList()
  val saved = Environment.getVarOrDefault("JCO", "")
  val _e = Environment.setVar("JCO", Path.join(dir, "no-such-jco"))
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
    "component;js"
  )
  val _r = Environment.setVar("JCO", saved)
  assertFalse(ok, "a build that cannot run jco must fail")
  assertTrue(File.fileExists(Path.join(dir, "prog.wasm")), "the component itself was still produced")
}

val asyncComponentProgram: String = r#"package Probe

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

pub async func pair(n: Int): Option[Int] {
  Time.sleepMillis(5)
  if n > 0 {
    Some(value = n * 2)
  } else {
    None
  }
}

pub func plain(x: Int): Int {
  x + 100
}
"#

test "wasm32 component: an async export runs to completion inside the call, sleeping out its timers" {
  val dir = buildComponentOf(asyncComponentProgram)
  val wasm = Path.join(dir, "prog.wasm")
  val wit = match File.readText(Path.join(dir, "prog.wit")) { case Ok(t) -> t; case Err(_) -> "" }
  assertTrue(
    Str.contains(wit, "later: func(x: s32, ms: s32) -> s32"),
    "an async export is an ordinary WIT function: " + wit
  )
  val vargs: List[String] = newList()
  vargs.add("validate")
  vargs.add(wasm)
  val v = run(envOrPanic("WASM_TOOLS"), vargs)
  assertTrue(v.exitCode == 0, "wasm-tools validate: " + v.stderr)
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
  val _ln = run("ln", lnargs)
  val script = r"import * as m from './js/prog.js';
const p = m.probe;
const t0 = performance.now();
const v = p.later(41, 60);
const dt = performance.now() - t0;
console.log('later=' + v + ' waited=' + (dt >= 50));
console.log('tag=' + p.tag('wörld', 10));
console.log('immediate=' + p.immediate());
console.log('wide=' + p.wide(3000000000n));
console.log('pair=' + p.pair(4) + ',' + p.pair(0));
console.log('plain=' + p.plain(1));
"
  val scriptPath = Path.join(dir, "run.mjs")
  val _s = File.writeText(scriptPath, script)
  val nargs: List[String] = newList()
  nargs.add(scriptPath)
  val n = run(Environment.getVarOrDefault("NODE", "node"), nargs)
  assertTrue(n.exitCode == 0, "node: " + n.stderr + n.stdout)
  assertTrue(
    Str.contains(n.stdout, "later=42 waited=true"),
    "the call blocked for its sleep and returned the value: " + n.stdout
  )
  assertTrue(Str.contains(n.stdout, "tag=wörld!"), "String argument and result through a task: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "immediate=41"), "an async func that never suspends: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "wide=6000000000"), "Long result: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "pair=8,undefined"), "an Option result through a task: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "plain=101"), "a sync export beside the async ones: " + n.stdout)
}

val tupleProgram: String = r#"package Probe

import Std.Collections

record Box {
  pair: (Int, String)
  span: Option[(Int, Int)]
}

pub func swapPair(p: (Int, String)): (String, Int) {
  val (a, b) = p
  (b, a)
}

pub func triple(x: Int): (Int, Long, Double) {
  (x, 3000000000i64, 0.5)
}

pub func pairs(n: Int): List[(Int, Int)] {
  val acc: List[(Int, Int)] = newList()
  var i = 0
  while i < n {
    acc.add((i, i * i))
    i = i + 1
  }
  acc
}

pub func mkBox(n: Int): Box {
  Box(pair = (n, "box"), span = Some(value = (n, n + 1)))
}

pub func boxSum(b: Box): Int {
  val (n, _) = b.pair
  match b.span {
    case Some((lo, hi)) -> n + lo + hi
    case None -> n
  }
}

pub func divmod(a: Int, b: Int): Result[(Int, Int), String] {
  if b == 0 {
    Err(error = "divide by zero")
  } else {
    Ok(value = (a / b, a % b))
  }
}
"#

val imageImportProgram: String = r#"package Probe

record Point {
  x: Int
  y: Int
}

record Person {
  name: String
  age: Int
  tags: List[String]
  home: Option[Point]
}

enum Color {
  case Red
  case Green
  case Blue
}

union Shape {
  case Square(side: Double)
  case Big(count: Long)
  case Label(text: String)
  case Small(amount: Float)
  case Empty
}

@wasmImport("geo")
extern func hostSwap(p: Point): Point = "swap"

@wasmImport("geo")
extern func hostOlder(p: Person): Person = "older"

@wasmImport("geo")
extern func hostFirst(xs: List[String]): Option[String] = "first"

@wasmImport("geo")
extern func hostSafeDiv(a: Int, b: Int): Result[Int, String] = "safe-div"

@wasmImport("geo")
extern func hostNext(c: Color): Color = "next-color"

@wasmImport("geo")
extern func hostGrow(s: Shape): Shape = "grow"

@wasmImport("geo")
extern func hostNote(p: Point): Unit = "note"

@wasmImport("geo")
extern func hostTag(s: String, p: Point): String = "tag"

@wasmImport("geo")
extern func hostPair(n: Int): (Int, String) = "pair"

@wasmImport("geo")
extern func hostMany(a: Int, b: Int, c: Int, d: Int, e: Int, f: Int, g: Int, h: Int, i: Int, j: Int, k: Int, l: Int, m: Int, n: Int, o: Int, p: Int, q: Int, r: Int): Int = "many"

@wasmImport("geo")
extern func hostLast(): String = "last-note"

pub func swapIt(p: Point): Point {
  hostSwap(p)
}

pub func olderIt(p: Person): Person {
  hostOlder(p)
}

pub func firstIt(xs: List[String]): Option[String] {
  hostFirst(xs)
}

pub func divIt(a: Int, b: Int): Result[Int, String] {
  hostSafeDiv(a, b)
}

pub func nextIt(c: Color): Color {
  hostNext(c)
}

pub func growIt(s: Shape): Shape {
  hostGrow(s)
}

pub func noteIt(p: Point): String {
  hostNote(p)
  hostLast()
}

pub func tagIt(s: String, p: Point): String {
  hostTag(s, p)
}

pub func pairIt(n: Int): (Int, String) {
  hostPair(n)
}

pub func manyIt(): Int {
  hostMany(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18)
}
"#

test "wasm32 component: records, options, results, lists, enums, variants and tuples cross a host import" {
  val dir = buildComponentOf(imageImportProgram)
  val wasm = Path.join(dir, "prog.wasm")
  val wit = match File.readText(Path.join(dir, "prog.wit")) { case Ok(t) -> t; case Err(_) -> "" }
  assertTrue(
    Str.contains(wit, "interface geo {") and Str.contains(wit, "record point {"),
    "the import interface declares the types its signatures use: " + wit
  )
  assertTrue(Str.contains(wit, "swap: func(p: point) -> point"), "a record parameter and result in the import: " + wit)
  val vargs: List[String] = newList()
  vargs.add("validate")
  vargs.add(wasm)
  val v = run(envOrPanic("WASM_TOOLS"), vargs)
  assertTrue(v.exitCode == 0, "wasm-tools validate: " + v.stderr)
  val outDir = Path.join(dir, "js")
  val jargs: List[String] = newList()
  jargs.add("transpile")
  jargs.add(wasm)
  jargs.add("-o")
  jargs.add(outDir)
  jargs.add("--map")
  jargs.add("lyric:probe/geo@0.1.0=../geo.js")
  val j = run(envOrPanic("JCO"), jargs)
  assertTrue(j.exitCode == 0, "jco transpile: " + j.stderr)
  val lnargs: List[String] = newList()
  lnargs.add("-s")
  lnargs.add(envOrPanic("LYRIC_JCO_NODE_MODULES"))
  lnargs.add(Path.join(dir, "node_modules"))
  val _ln = run("ln", lnargs)
  val _g = File.writeText(
    Path.join(dir, "geo.js"),
    r"let last = '';
export const swap = (p) => ({ x: p.y, y: p.x });
export const older = (p) => ({ name: p.name, age: p.age + 1, tags: [...p.tags, 'host'], home: p.home ? { x: p.home.x + 1, y: p.home.y } : undefined });
export const first = (xs) => (xs.length > 0 ? xs[0] : undefined);
export const safeDiv = (a, b) => { if (b === 0) { throw { payload: 'divide by zero' }; } return Math.trunc(a / b); };
export const nextColor = (c) => ({ red: 'green', green: 'blue', blue: 'red' })[c];
export const grow = (s) => {
  switch (s.tag) {
    case 'square': return { tag: 'square', val: s.val * 2 };
    case 'big': return { tag: 'big', val: s.val + 1n };
    case 'label': return { tag: 'label', val: s.val + '!' };
    case 'small': return { tag: 'small', val: s.val / 2 };
    default: return { tag: 'empty' };
  }
};
export const note = (p) => { last = 'noted ' + p.x + ',' + p.y; };
export const lastNote = () => last;
export const tag = (s, p) => s + '@' + p.x + ',' + p.y;
export const pair = (n) => [n, 'n' + n];
export const many = (...xs) => xs.reduce((a, b) => a + b, 0);
"
  )
  val script = r"import * as m from './js/prog.js';
const p = m.probe;
const show = (v) => JSON.stringify(v, (k, x) => typeof x === 'bigint' ? Number(x) : x);
console.log('swap=' + show(p.swapIt({ x: 1, y: 2 })));
const per = { name: 'ann', age: 30, tags: ['a', 'b'], home: { x: 5, y: 6 } };
console.log('older=' + show(p.olderIt(per)));
console.log('olderNoHome=' + show(p.olderIt({ name: 'bo', age: 1, tags: [], home: undefined })));
console.log('first=' + show(p.firstIt(['x', 'y'])) + ' none=' + show(p.firstIt([])));
console.log('div=' + show(p.divIt(10, 3)));
try { p.divIt(1, 0); console.log('divErr=none'); } catch (e) { console.log('divErr=' + show(e.payload ?? e)); }
console.log('color=' + p.nextIt('red') + ',' + p.nextIt('blue'));
console.log('grow=' + [{ tag: 'square', val: 1.5 }, { tag: 'big', val: 7n }, { tag: 'label', val: 'hi' }, { tag: 'small', val: 3 }, { tag: 'empty' }].map((s) => show(p.growIt(s))).join(';'));
console.log('note=' + p.noteIt({ x: 3, y: 4 }));
console.log('tag=' + p.tagIt('wörld ☃', { x: 9, y: 8 }));
console.log('pair=' + show(p.pairIt(7)));
console.log('many=' + p.manyIt());
console.log('loop=' + [1, 2, 3].map((i) => p.firstIt(['x'.repeat(i * 1000)]).length).join(','));
"
  val scriptPath = Path.join(dir, "run.mjs")
  val _s = File.writeText(scriptPath, script)
  val nargs: List[String] = newList()
  nargs.add(scriptPath)
  val n = run(Environment.getVarOrDefault("NODE", "node"), nargs)
  assertTrue(n.exitCode == 0, "node: " + n.stderr + n.stdout)
  assertTrue(Str.contains(n.stdout, "swap={\"x\":2,\"y\":1}"), "a record both ways: " + n.stdout)
  assertTrue(
    Str.contains(
      n.stdout,
      "older={\"name\":\"ann\",\"age\":31,\"tags\":[\"a\",\"b\",\"host\"],\"home\":{\"x\":6,\"y\":6}}"
    ),
    "a record holding a string, a list and an option of a record: " + n.stdout
  )
  assertTrue(
    Str.contains(n.stdout, "olderNoHome={\"name\":\"bo\",\"age\":2,\"tags\":[\"host\"]}"),
    "the none side of an option: " + n.stdout
  )
  assertTrue(Str.contains(n.stdout, "first=\"x\" none=undefined"), "a list in, an option out: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "div=3"), "the ok side of a result: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "divErr=\"divide by zero\""), "the error side of a result: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "color=green,red"), "an enum both ways: " + n.stdout)
  assertTrue(
    Str.contains(
      n.stdout,
      "grow={\"tag\":\"square\",\"val\":3};{\"tag\":\"big\",\"val\":8};{\"tag\":\"label\",\"val\":\"hi!\"};{\"tag\":\"small\",\"val\":1.5};{\"tag\":\"empty\"}"
    ),
    "a variant whose payloads join f64, i64, i32 and f32 slots: " + n.stdout
  )
  assertTrue(Str.contains(n.stdout, "note=noted 3,4"), "a record into a Unit import: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "tag=wörld ☃@9,8"), "a string and a record together: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "pair=[7,\"n7\"]"), "a tuple result: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "many=171"), "parameters spilled into memory: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "loop=1000,2000,3000"), "repeated calls free what they allocate: " + n.stdout)
}

func projectComponent(pkgs: in List[NativeSourcePackage]): String {
  val _w = envOrPanic("WASI_SDK_PATH")
  val stdlib = findStdlibSourcesNative()
  val dir = Path.join(
    Environment.getVarOrDefault("TMPDIR", "/tmp"),
    "lyric-wasm32-component-xpkg-" + Uuid.uuidToString(Uuid.newUuid())
  )
  val _d = File.createDir(dir)
  val flags: List[String] = newList()
  val noFeatures: List[String] = newList()
  val noOrigins: List[DiagUtil.PackageLineOrigins] = newList()
  val ok = compileProjectToNativeWithShape(
    pkgs,
    Path.join(dir, "prog.wasm"),
    stdlib,
    "wasm32-wasi",
    "2",
    flags,
    newList(),
    noFeatures,
    noFeatures,
    "",
    noOrigins,
    true,
    "component"
  )
  if not ok {
    panic("wasm32 component project compilation failed")
  }
  dir
}

test "wasm32 component: an export may name a type another package of the project declares" {
  val pkgs: List[NativeSourcePackage] = newList()
  pkgs.add(
    NativeSourcePackage(
      name = "Proj.Model",
      path = "",
      source = r"package Proj.Model

import Std.Collections

pub record Line {
  sku: String
  qty: Int
}

pub enum Currency {
  case Usd
  case Eur
}

pub union Status {
  case Open
  case Paid(amount: Long)
  case Failed(reason: String)
}

pub record Invoice {
  id: Int
  lines: List[Line]
  currency: Currency
  status: Status
}
"
    )
  )
  pkgs.add(
    NativeSourcePackage(
      name = "Proj.Api",
      path = "",
      source = r#"package Proj.Api

import Std.Collections

import Proj.Model

pub func mk(id: Int): Invoice {
  val ls: List[Line] = newList()
  ls.add(Line(sku = "a", qty = 2))
  ls.add(Line(sku = "b", qty = 3))
  Invoice(id = id, lines = ls, currency = Usd, status = Open)
}

pub func total(i: Invoice): Int {
  var t = 0
  for l in i.lines {
    t = t + l.qty
  }
  t
}

pub func pay(i: Invoice, amount: Long): Invoice {
  Invoice(id = i.id, lines = i.lines, currency = i.currency, status = Paid(amount = amount))
}

pub func flip(c: Currency): Currency {
  match c {
    case Usd -> Eur
    case Eur -> Usd
  }
}
"#
    )
  )
  pkgs.add(
    NativeSourcePackage(
      name = "Proj.Reports",
      path = "",
      source = r#"package Proj.Reports

import Std.Collections

import Proj.Model as M

pub func describe(i: M.Invoice): String {
  match i.status {
    case M.Status.Open -> "open"
    case M.Status.Paid(a) -> "paid"
    case M.Status.Failed(r) -> r
  }
}

pub func failed(reason: String): M.Status {
  M.Status.Failed(reason = reason)
}

pub func currencies(): List[M.Currency] {
  val acc: List[M.Currency] = newList()
  acc.add(M.Currency.Usd)
  acc.add(M.Currency.Eur)
  acc
}
"#
    )
  )
  pkgs.add(
    NativeSourcePackage(
      name = "Proj.Lines",
      path = "",
      source = r"package Proj.Lines

import Std.Collections

import Proj.Model.{Line as L}

pub func count(ls: List[L]): Int {
  ls.count
}

pub func first(ls: List[L]): Option[L] {
  if ls.count > 0 {
    Some(value = ls[0])
  } else {
    None
  }
}
"
    )
  )
  val dir = projectComponent(pkgs)
  val wasm = Path.join(dir, "prog.wasm")
  val wit = match File.readText(Path.join(dir, "prog.wit")) { case Ok(t) -> t; case Err(_) -> "" }
  assertTrue(
    Str.contains(wit, "interface proj-api {") and Str.contains(wit, "interface proj-reports {") and
      Str.contains(wit, "interface proj-lines {"),
    "an interface per exporting package: " + wit
  )
  assertTrue(
    Str.contains(wit, "total: func(i: invoice) -> s32"),
    "a type of another package appears under its own name: " + wit
  )
  assertFalse(Str.contains(wit, "proj-model"), "the declaring package is not an interface of its own: " + wit)
  val vargs: List[String] = newList()
  vargs.add("validate")
  vargs.add(wasm)
  val v = run(envOrPanic("WASM_TOOLS"), vargs)
  assertTrue(v.exitCode == 0, "wasm-tools validate: " + v.stderr)
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
  val _ln = run("ln", lnargs)
  val script = r"import * as m from './js/prog.js';
const show = (v) => JSON.stringify(v, (k, x) => typeof x === 'bigint' ? Number(x) : x);
const api = m.projApi;
const inv = api.mk(7);
console.log('mk=' + show(inv));
console.log('total=' + api.total(inv));
const paid = api.pay(inv, 99n);
console.log('pay=' + show(paid.status));
console.log('flip=' + api.flip('usd') + ',' + api.flip('eur'));
console.log('describe=' + m.projReports.describe(inv) + ',' + m.projReports.describe(paid) + ',' + m.projReports.describe({ ...inv, status: m.projReports.failed('nope') }));
console.log('currencies=' + show(m.projReports.currencies()));
console.log('count=' + m.projLines.count(inv.lines) + ' first=' + show(m.projLines.first(inv.lines)) + ' none=' + show(m.projLines.first([])));
"
  val scriptPath = Path.join(dir, "run.mjs")
  val _s = File.writeText(scriptPath, script)
  val nargs: List[String] = newList()
  nargs.add(scriptPath)
  val n = run(Environment.getVarOrDefault("NODE", "node"), nargs)
  assertTrue(n.exitCode == 0, "node: " + n.stderr + n.stdout)
  assertTrue(
    Str.contains(
      n.stdout,
      "mk={\"id\":7,\"lines\":[{\"sku\":\"a\",\"qty\":2},{\"sku\":\"b\",\"qty\":3}],\"currency\":\"usd\",\"status\":{\"tag\":\"open\"}}"
    ),
    "a record of another package, with its nested record, enum and union: " + n.stdout
  )
  assertTrue(Str.contains(n.stdout, "total=5"), "a record of another package as a parameter: " + n.stdout)
  assertTrue(
    Str.contains(n.stdout, "pay={\"tag\":\"paid\",\"val\":99}"),
    "a union case built from a bare name: " + n.stdout
  )
  assertTrue(Str.contains(n.stdout, "flip=eur,usd"), "an enum of another package: " + n.stdout)
  assertTrue(
    Str.contains(n.stdout, "describe=open,paid,nope"),
    "types named through an alias and matched with qualified cases: " + n.stdout
  )
  assertTrue(Str.contains(n.stdout, "currencies=[\"usd\",\"eur\"]"), "a list of another package's enum: " + n.stdout)
  assertTrue(
    Str.contains(n.stdout, "count=2 first={\"sku\":\"a\",\"qty\":2} none=undefined"),
    "a renamed selective import: " + n.stdout
  )
}

test "wasm32 component: tuples cross the boundary as WIT tuples, nested in lists, options, records and results" {
  val dir = buildComponentOf(tupleProgram)
  val wasm = Path.join(dir, "prog.wasm")
  val wit = match File.readText(Path.join(dir, "prog.wit")) { case Ok(t) -> t; case Err(_) -> "" }
  assertTrue(
    Str.contains(wit, "swap-pair: func(p: tuple<s32, string>) -> tuple<string, s32>"),
    "tuple<...> in the WIT: " + wit
  )
  assertTrue(Str.contains(wit, "span: option<tuple<s32, s32>>"), "a tuple inside a record field: " + wit)
  val vargs: List[String] = newList()
  vargs.add("validate")
  vargs.add(wasm)
  val v = run(envOrPanic("WASM_TOOLS"), vargs)
  assertTrue(v.exitCode == 0, "wasm-tools validate: " + v.stderr)
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
  val _ln = run("ln", lnargs)
  val script = r"import * as m from './js/prog.js';
const p = m.probe;
const show = (v) => JSON.stringify(v, (k, x) => typeof x === 'bigint' ? Number(x) : x);
console.log('swap=' + show(p.swapPair([7, 'seven'])));
console.log('triple=' + show(p.triple(4)));
console.log('pairs=' + show(p.pairs(4)));
console.log('box=' + show(p.mkBox(3)));
console.log('boxSum=' + p.boxSum({ pair: [10, 'x'], span: [1, 2] }) + ',' + p.boxSum({ pair: [10, 'x'], span: undefined }));
console.log('divmod=' + show(p.divmod(17, 5)));
try { p.divmod(1, 0); console.log('divmodErr=none'); } catch (e) { console.log('divmodErr=' + show(e.payload ?? e)); }
"
  val scriptPath = Path.join(dir, "run.mjs")
  val _s = File.writeText(scriptPath, script)
  val nargs: List[String] = newList()
  nargs.add(scriptPath)
  val n = run(Environment.getVarOrDefault("NODE", "node"), nargs)
  assertTrue(n.exitCode == 0, "node: " + n.stderr + n.stdout)
  assertTrue(Str.contains(n.stdout, "swap=[\"seven\",7]"), "swapPair: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "triple=[4,3000000000,0.5]"), "a three-tuple: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "pairs=[[0,0],[1,1],[2,4],[3,9]]"), "a list of tuples: " + n.stdout)
  assertTrue(
    Str.contains(n.stdout, "box={\"pair\":[3,\"box\"],\"span\":[3,4]}"),
    "a record holding tuples: " + n.stdout
  )
  assertTrue(Str.contains(n.stdout, "boxSum=13,10"), "a tuple read back from the host: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "divmod=[3,2]"), "a tuple in a result: " + n.stdout)
  assertTrue(Str.contains(n.stdout, "divmodErr=\"divide by zero\""), "the error side: " + n.stdout)
}
