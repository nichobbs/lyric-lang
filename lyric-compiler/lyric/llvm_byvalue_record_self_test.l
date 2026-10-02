//! llvm_byvalue_record_self_test.l — end-to-end self-test for by-value records
//! on `--target native` (docs/67 §4.2, G1 #7940).
//!
//! A record with no `var` field whose fields are all by-value (scalars, enums,
//! distinct types, other by-value records) lowers to a plain LLVM struct VALUE:
//! no ARC header, no heap allocation, no retain/release, no destructor.  A
//! record with a `var` field keeps the shared heap form (D157), and so do
//! opaque types and the target of an `impl I for R`.  The language is
//! unchanged; these cases pin the codegen policy.
//!
//! Every runtime case compiles with `-fsanitize=address` (LeakSanitizer is on
//! by default on Linux): a leaked slot box, a premature release, or a double
//! release exits non-zero, so `exit 0` is a real end-to-end ARC check.  The IR
//! cases inspect the emitted `.ll` for the absence of `lyric_alloc` where the
//! design says there is no allocation.
//!
//! Requires `clang` on PATH and a built runtime (`make -C lyric-rt`).
//! Run via native `lyric test` with LYRIC_LOAD_COMPILER=1:
//!   make -C lyric-rt && LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/llvm_byvalue_record_self_test.l
@test_module
package Lyric.LlvmByValueRecordSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.File as File
import Std.Path as Path
import Std.Process as Process
import Std.Environment as Environment
import Std.String as Str
import Std.Uuid as Uuid
import Lyric.Parser
import Lyric.LlvmTypes
import Lyric.LlvmIr
import Lyric.LlvmCodegen
import Lyric.LlvmLowering
import Lyric.Emitter
import Lyric.LlvmBridge

// ─────────────────────────────────────────────────────────────────────────────
// Harness (mirrors llvm_heap_self_test.l).
// ─────────────────────────────────────────────────────────────────────────────
func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", "/tmp")
}

func findLyricRt(): String {
  var dir = Environment.currentDirectory()
  var hop = 0
  while hop < 32 {
    val candidate = Path.join(Path.join(Path.join(dir, "lyric-rt"), "build"), "lyric_rt.a")
    if File.fileExists(candidate) {
      return candidate
    }
    val parent = Path.dirname(dir)
    if parent.length == 0 or parent == dir {
      return ""
    }
    dir = parent
    hop = hop + 1
  }
  ""
}

record RunOutcome {
  exitCode: Int
  stdout: String
}

func parseOrPanic(source: in String): SourceFile {
  val pr = parse(source)
  if pr.diagnostics.count > 0 {
    var msg = "test source has parse diagnostics:"
    var i = 0
    while i < pr.diagnostics.count {
      msg = msg + " " + pr.diagnostics[i].code
      i = i + 1
    }
    panic(msg)
  }
  pr.file
}

/// The `.ll` text a program lowers to.
func lowerToLl(source: in String): String {
  val pkg = codegenNativePackage(parseOrPanic(source), "")
  lowerNativePackage(pkg)
}

func compileAndRunWith(source: in String, sanitize: in Bool): RunOutcome {
  val ll = lowerToLl(source)
  val rt = findLyricRt()
  if rt.length == 0 {
    panic("lyric_rt.a not found; run `make -C lyric-rt` first")
  }
  val dir = Path.join(tempBase(), "lyric-llvm-byvalue-selftest")
  val _ = File.createDir(dir)
  val stem = Path.join(dir, "t_" + Uuid.uuidToString(Uuid.newUuid()))
  val llPath = stem + ".ll"
  match File.writeText(llPath, ll) {
    case Ok(_) -> {
    }
    case Err(_) -> panic("cannot write " + llPath)
  }
  val clangArgs: List[String] = newList()
  clangArgs.add("-O0")
  if sanitize {
    clangArgs.add("-fsanitize=address")
  }
  clangArgs.add(llPath)
  clangArgs.add(rt)
  clangArgs.add("-lm")
  clangArgs.add("-lpthread")
  clangArgs.add("-o")
  clangArgs.add(stem)
  match Process.runCapture("clang", clangArgs, 120000) {
    case Ok(res) -> {
      if res.exitCode != 0 {
        panic("clang failed on " + llPath + ": " + res.stderr)
      }
    }
    case Err(e) -> panic("clang could not be started: " + e)
  }
  val noArgs: List[String] = newList()
  match Process.runCapture(stem, noArgs, 60000) {
    case Ok(res) -> RunOutcome(exitCode = res.exitCode, stdout = res.stdout)
    case Err(e) -> panic("binary could not be started: " + e)
  }
}

func compileAndRunAsan(source: in String): RunOutcome {
  compileAndRunWith(source, true)
}

func printlnShim(): String {
  "extern func consoleWriteFd(fd: Int, s: String): Unit = \"lyric_console_write\"\n" +
    "extern func consoleNewlineFd(fd: Int): Unit = \"lyric_console_write_newline\"\n" +
    "func println(s: in String): Unit {\n" +
    "  consoleWriteFd(1, s)\n" +
    "  consoleNewlineFd(1)\n" +
    "}\n"
}

/// The `.ll` text a multi-package bundle lowers to (`sources[0]` is the entry package).
func lowerBundleToLl(sources: in List[String]): String {
  val units: List[CodegenUnit] = newList()
  for src in sources {
    val file = parseOrPanic(src)
    units.add(unitOfFile(dottedPkgName(file), file))
  }
  lowerNativePackage(codegenNativeBundle(units, ""))
}

func runLl(ll: in String): RunOutcome {
  val rt = findLyricRt()
  if rt.length == 0 {
    panic("lyric_rt.a not found; run `make -C lyric-rt` first")
  }
  val dir = Path.join(tempBase(), "lyric-llvm-byvalue-selftest")
  val _ = File.createDir(dir)
  val stem = Path.join(dir, "b_" + Uuid.uuidToString(Uuid.newUuid()))
  val llPath = stem + ".ll"
  match File.writeText(llPath, ll) {
    case Ok(_) -> {
    }
    case Err(_) -> panic("cannot write " + llPath)
  }
  val clangArgs: List[String] = newList()
  clangArgs.add("-O0")
  clangArgs.add("-fsanitize=address")
  clangArgs.add(llPath)
  clangArgs.add(rt)
  clangArgs.add("-lm")
  clangArgs.add("-lpthread")
  clangArgs.add("-o")
  clangArgs.add(stem)
  match Process.runCapture("clang", clangArgs, 120000) {
    case Ok(res) -> {
      if res.exitCode != 0 {
        panic("clang failed on " + llPath + ": " + res.stderr)
      }
    }
    case Err(e) -> panic("clang could not be started: " + e)
  }
  val noArgs: List[String] = newList()
  match Process.runCapture(stem, noArgs, 60000) {
    case Ok(res) -> RunOutcome(exitCode = res.exitCode, stdout = res.stdout)
    case Err(e) -> panic("binary could not be started: " + e)
  }
}

/// The text of the function `@name` in `ll`: from its `define` line to the
/// closing brace.
func functionBody(ll: in String, name: in String): String {
  val marker = " @" + name + "("
  val at = match Str.indexOf(ll, marker) {
    case Some(i) -> i
    case None -> panic("function " + name + " not found in the emitted IR")
  }
  val tail = Str.substring(ll, at, ll.length - at)
  match Str.indexOf(tail, "\n}") {
    case Some(i) -> Str.substring(tail, 0, i)
    case None -> tail
  }
}

val vec3Decl: String = "record Vec3 {\n  x: Float\n  y: Float\n  z: Float\n}\n" + "func addV(a: in Vec3, b: in Vec3): Vec3 {\n  Vec3(x = a.x + b.x, y = a.y + b.y, z = a.z + b.z)\n}\n" + "func subV(a: in Vec3, b: in Vec3): Vec3 {\n  Vec3(x = a.x - b.x, y = a.y - b.y, z = a.z - b.z)\n}\n" + "func dot(a: in Vec3, b: in Vec3): Float {\n  a.x * b.x + a.y * b.y + a.z * b.z\n}\n"

// ─────────────────────────────────────────────────────────────────────────────
// IR shape: no allocation, no header, no ARC.
// ─────────────────────────────────────────────────────────────────────────────
test "a by-value record is a header-less struct and its arithmetic never allocates" {
  val src = "package T\n" + vec3Decl + "func main(): Int {\n" + "  val a = Vec3(x = 1.0f32, y = 2.0f32, z = 3.0f32)\n" +
    "  val b = addV(a, a)\n" +
    "  dot(b, subV(b, a)).toInt()\n" +
    "}\n"
  val ll = lowerToLl(src)
  assertTrue(Str.contains(ll, "%T.Vec3 = type { float, float, float }"), "the struct has no ARC header")
  val addBody = functionBody(ll, "T.addV")
  assertTrue(not Str.contains(addBody, "lyric_alloc"), "addV allocates nothing")
  assertTrue(not Str.contains(addBody, "lyric_retain"), "addV retains nothing")
  assertTrue(not Str.contains(addBody, "lyric_release"), "addV releases nothing")
  assertTrue(Str.contains(addBody, "insertvalue %T.Vec3"), "addV builds the result with insertvalue")
  assertTrue(Str.contains(addBody, "extractvalue %T.Vec3"), "addV reads fields with extractvalue")
  val mainBody = functionBody(ll, "T.main")
  assertTrue(not Str.contains(mainBody, "lyric_alloc"), "main allocates nothing for Vec3 values")
  assertTrue(not Str.contains(ll, "T.Vec3.dtor"), "a by-value record has no destructor")
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 28, "dot((2,4,6), (1,2,3)) = 2 + 8 + 18")
}

test "a record with a var field keeps the heap form (D157)" {
  val src = "package T\n" + "record Counter {\n  var n: Int\n}\n" + "func make(): Counter {\n  Counter(n = 1)\n}\n" +
    "func main(): Int {\n  make().n\n}\n"
  val ll = lowerToLl(src)
  assertTrue(Str.contains(ll, "%T.Counter = type { i32, i32, i8*, i32 }"), "the heap struct keeps its ARC header")
  assertTrue(Str.contains(functionBody(ll, "T.make"), "lyric_alloc"), "the constructor allocates")
}

test "a record that implements an interface keeps the heap form" {
  val src = "package T\n" + "interface Area {\n  func area(): Int\n}\n" + "record Square {\n  s: Int\n}\n" +
    "impl Area for Square {\n  func area(): Int {\n    self.s * self.s\n  }\n}\n" +
    "func total(a: in Area): Int {\n  a.area()\n}\n" +
    "func main(): Int {\n  total(Square(s = 6))\n}\n"
  val ll = lowerToLl(src)
  assertTrue(Str.contains(ll, "%T.Square = type { i32, i32, i8*, i32 }"), "the implementer is a heap object")
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 36, "interface dispatch over the heap record")
}

test "an opaque type keeps the heap form" {
  val src = "package T\n" + "opaque type Handle {\n  id: Int\n}\n" +
    "func main(): Int {\n  val h = Handle(id = 4)\n  h.id\n}\n"
  val ll = lowerToLl(src)
  assertTrue(Str.contains(ll, "%T.Handle = type { i32, i32, i8*, i32 }"), "the opaque type is a heap object")
}

test "a record with a reference field keeps the heap form" {
  val src = "package T\n" + "record Named {\n  name: String\n  n: Int\n}\n" +
    "func main(): Int {\n  val x = Named(name = \"ab\", n = 2)\n  x.n + x.name.length\n}\n"
  val ll = lowerToLl(src)
  assertTrue(
    Str.contains(ll, "%T.Named = type { i32, i32, i8*, "),
    "a String field is a reference, so the record is heap"
  )
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 4, "heap record with a String field")
}

// ─────────────────────────────────────────────────────────────────────────────
// Construction, field reads, parameters and returns.
// ─────────────────────────────────────────────────────────────────────────────
test "construction, named and default arguments, field reads" {
  val src = "package T\n" + "record Rect {\n  w: Int\n  h: Int = 5\n  tag: Byte = 3\n  on: Bool = true\n}\n" +
    "func main(): Int {\n" +
    "  val a = Rect(w = 4)\n" +
    "  val b = Rect(h = 2, w = 7, tag = 9, on = false)\n" +
    "  var r = a.w * a.h + a.tag.toInt()\n" +
    "  if b.on { r = r + 100 }\n" +
    "  r + b.w + b.h + b.tag.toInt()\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 41, "4*5 + 3 = 23, then + 7 + 2 + 9; the off flag adds nothing")
}

test "records pass to and return from functions, including recursion" {
  val src = "package T\n" + "record Pair {\n  a: Int\n  b: Int\n}\n" +
    "func swap(p: in Pair): Pair {\n  Pair(a = p.b, b = p.a)\n}\n" +
    "func fold(p: in Pair, n: in Int): Pair {\n  if n == 0 { p } else { fold(Pair(a = p.a + p.b, b = p.a), n - 1) }\n}\n" +
    "func main(): Int {\n" +
    "  val s = swap(Pair(a = 3, b = 9))\n" +
    "  val f = fold(Pair(a = 1, b = 0), 10)\n" +
    "  s.a * 10 + s.b + f.a\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 182, "9*10 + 3 + 89")
}

test "a var local holding a by-value record can be reassigned" {
  val src = "package T\n" + "record P {\n  x: Int\n  y: Int\n}\n" + "func main(): Int {\n" +
    "  var p = P(x = 1, y = 2)\n" +
    "  val q = p\n" +
    "  p = P(x = p.x + 10, y = p.y + 20)\n" +
    "  q.x + q.y + p.x + p.y\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 36, "q keeps its value: 1 + 2 + 11 + 22")
}

test "if and match produce by-value records" {
  val src = "package T\n" + "record P {\n  x: Int\n  y: Int\n}\n" + "enum Dir {\n  case Up\n  case Down\n}\n" +
    "func step(d: in Dir, p: in P): P {\n" +
    "  match d {\n" +
    "    case Up -> P(x = p.x, y = p.y + 1)\n" +
    "    case Down -> P(x = p.x, y = p.y - 1)\n" +
    "  }\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val a = step(Up, P(x = 5, y = 5))\n" +
    "  val b = if a.y > 5 { P(x = 100, y = a.y) } else { a }\n" +
    "  b.x + b.y\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 106, "100 + 6")
}

test "fields of enum and distinct type stay by-value" {
  val src = "package T\n" + "enum Color {\n  case Red\n  case Green\n}\n" + "type Meters = Long\n" +
    "record Mark {\n  c: Color\n  d: Meters\n}\n" +
    "func main(): Int {\n" +
    "  val m = Mark(c = Green, d = Meters(7))\n" +
    "  val g = match m.c {\n    case Red -> 0\n    case Green -> 1\n  }\n" +
    "  g + m.d.value.toInt()\n" +
    "}\n"
  val ll = lowerToLl(src)
  assertTrue(Str.contains(ll, "%T.Mark = type { i32, i64 }"), "the enum and distinct fields are plain scalars")
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 8, "1 + 7")
}

// ─────────────────────────────────────────────────────────────────────────────
// Nesting and containment.
// ─────────────────────────────────────────────────────────────────────────────
test "a by-value record nests inside another and reads through the chain" {
  val src = "package T\n" + "record Vec2 {\n  x: Int\n  y: Int\n}\n" +
    "record Seg {\n  a: Vec2\n  b: Vec2\n  w: Byte\n}\n" +
    "func len1(s: in Seg): Int {\n  s.b.x - s.a.x + s.b.y - s.a.y\n}\n" +
    "func main(): Int {\n" +
    "  val s = Seg(a = Vec2(x = 1, y = 2), b = Vec2(x = 10, y = 20), w = 1)\n" +
    "  len1(s) + s.w.toInt()\n" +
    "}\n"
  val ll = lowerToLl(src)
  assertTrue(Str.contains(ll, "%T.Seg = type { %T.Vec2, %T.Vec2, i8 }"), "Seg embeds Vec2 inline")
  assertTrue(not Str.contains(functionBody(ll, "T.main"), "lyric_alloc"), "nesting allocates nothing")
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 28, "9 + 18 + 1")
}

test "a by-value record declared after its use in another record" {
  val src = "package T\n" + "record Outer {\n  inner: Inner\n  k: Int\n}\n" + "record Inner {\n  v: Long\n}\n" +
    "func main(): Int {\n  val o = Outer(inner = Inner(v = 40), k = 2)\n  o.inner.v.toInt() + o.k\n}\n"
  val ll = lowerToLl(src)
  assertTrue(Str.contains(ll, "%T.Outer = type { %T.Inner, i32 }"), "Outer embeds Inner")
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 42, "forward reference between by-value records")
}

test "a by-value record lives in a heap record's field and is replaced through it" {
  val src = "package T\n" + "record Vec2 {\n  x: Int\n  y: Int\n}\n" +
    "record Body {\n  var pos: Vec2\n  var label: String\n}\n" +
    "func main(): Int {\n" +
    "  val b = Body(pos = Vec2(x = 1, y = 2), label = \"b\")\n" +
    "  b.pos = Vec2(x = b.pos.x + 10, y = b.pos.y + 20)\n" +
    "  b.label = b.label + \"c\"\n" +
    "  val alias = b\n" +
    "  alias.pos = Vec2(x = alias.pos.x * 2, y = alias.pos.y)\n" +
    "  b.pos.x + b.pos.y + b.label.length\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 46, "the var-field record is shared (D157): pos (22, 22) and label \"bc\"")
}

test "a by-value record is a union payload and matches bind it" {
  val src = "package T\n" + "record Vec2 {\n  x: Int\n  y: Int\n}\n" +
    "union Shape {\n  case Dot(p: Vec2)\n  case Line(a: Vec2, b: Vec2)\n  case Empty\n}\n" +
    "func weight(s: in Shape): Int {\n" +
    "  match s {\n" +
    "    case Dot(p) -> p.x + p.y\n" +
    "    case Line(a, b) -> (b.x - a.x) + (b.y - a.y)\n" +
    "    case Empty -> 0\n" +
    "  }\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val d = Dot(p = Vec2(x = 3, y = 4))\n" +
    "  val l = Line(a = Vec2(x = 1, y = 1), b = Vec2(x = 11, y = 21))\n" +
    "  weight(d) + weight(l) + weight(Empty)\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 37, "7 + 30 + 0")
}

test "unions with by-value payloads compare structurally" {
  val src = "package T\n" + "record Vec2 {\n  x: Float\n  y: Float\n}\n" +
    "union Shape {\n  case Dot(p: Vec2)\n  case Empty\n}\n" +
    "func main(): Int {\n" +
    "  val a = Dot(p = Vec2(x = 1.5f32, y = 2.0f32))\n" +
    "  val b = Dot(p = Vec2(x = 1.5f32, y = 2.0f32))\n" +
    "  val c = Dot(p = Vec2(x = 1.5f32, y = 3.0f32))\n" +
    "  var r = 0\n" +
    "  if a == b { r = r + 1 }\n" +
    "  if a != c { r = r + 10 }\n" +
    "  if a == c { r = r + 100 }\n" +
    "  r\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 11, "equal payload fields compare equal; a differing field does not")
}

test "== on by-value records compares field by field, nested and with floats" {
  val src = "package T\n" + "record Vec2 {\n  x: Float\n  y: Float\n}\n" + "record Seg {\n  a: Vec2\n  b: Vec2\n}\n" +
    "func main(): Int {\n" +
    "  val s = Seg(a = Vec2(x = 1.0f32, y = 2.0f32), b = Vec2(x = 3.0f32, y = 4.0f32))\n" +
    "  val t = Seg(a = Vec2(x = 1.0f32, y = 2.0f32), b = Vec2(x = 3.0f32, y = 4.0f32))\n" +
    "  val u = Seg(a = Vec2(x = 1.0f32, y = 2.0f32), b = Vec2(x = 3.0f32, y = 5.0f32))\n" +
    "  var r = 0\n" +
    "  if s == t { r = r + 1 }\n" +
    "  if s == u { r = r + 10 }\n" +
    "  if s != u { r = r + 100 }\n" +
    "  r\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 101, "== is structural over nested records")
}

// ─────────────────────────────────────────────────────────────────────────────
// Collections, closures, generics, async.
// ─────────────────────────────────────────────────────────────────────────────
test "by-value records in a List: add, index, set, for, count (ASan)" {
  val src = "package T\n" + "import Std.Collections\n" + "record Pt {\n  x: Int\n  y: Int\n}\n" + "func main(): Int {\n" +
    "  val xs: List[Pt] = newList()\n" +
    "  var i = 0\n" +
    "  while i < 20 {\n" +
    "    xs.add(Pt(x = i, y = i * 2))\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  xs[3] = Pt(x = 100, y = 200)\n" +
    "  var sum = 0\n" +
    "  for p in xs {\n" +
    "    sum = sum + p.x + p.y\n" +
    "  }\n" +
    "  val last = xs[19]\n" +
    "  sum - 570 + last.y + xs.count\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 349 % 256, "291 (the sum moves by 300 - 9) + 38 + 20")
}

test "by-value records as Map values (ASan)" {
  val src = "package T\n" + "import Std.Collections\n" + "record Pt {\n  x: Int\n  y: Int\n}\n" + "func main(): Int {\n" +
    "  val m: Map[String, Pt] = newMap()\n" +
    "  m.add(\"a\", Pt(x = 1, y = 2))\n" +
    "  m.add(\"b\", Pt(x = 10, y = 20))\n" +
    "  m[\"a\"] = Pt(x = 5, y = 6)\n" +
    "  val a = m[\"a\"]\n" +
    "  val b = m[\"b\"]\n" +
    "  a.x + a.y + b.x + b.y + m.count\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 43, "11 + 30 + 2")
}

test "closures capture and return by-value records (ASan)" {
  val src = "package T\n" + "record Pt {\n  x: Int\n  y: Int\n}\n" +
    "func make(base: in Pt): (Int) -> Pt {\n  { k -> Pt(x = base.x + k, y = base.y * k) }\n}\n" +
    "func main(): Int {\n" +
    "  val f = make(Pt(x = 10, y = 3))\n" +
    "  val p = f(4)\n" +
    "  p.x + p.y\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 26, "14 + 12")
}

test "generic by-value record instantiations: Box[Int], Box[Vec2], and a generic function" {
  val src = "package T\n" + "record Vec2 {\n  x: Int\n  y: Int\n}\n" + "record Box[T] {\n  v: T\n  n: Int\n}\n" +
    "func unbox[T](b: in Box[T]): T {\n  b.v\n}\n" +
    "func main(): Int {\n" +
    "  val a = Box(v = 7, n = 1)\n" +
    "  val b = Box(v = Vec2(x = 20, y = 30), n = 2)\n" +
    "  unbox(a) + unbox(b).x + unbox(b).y + a.n + b.n\n" +
    "}\n"
  val ll = lowerToLl(src)
  assertTrue(Str.contains(ll, "\"T.Box<i32>\" = type { i32, i32 }"), "Box[Int] is a plain struct")
  assertTrue(not Str.contains(functionBody(ll, "T.main"), "lyric_alloc"), "generic by-value records never allocate")
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 60, "7 + 20 + 30 + 1 + 2")
}

test "a generic record over a reference type stays a heap object" {
  val src = "package T\n" + "record Box[T] {\n  v: T\n}\n" +
    "func main(): Int {\n  val b = Box(v = \"abc\")\n  b.v.length\n}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 3, "Box[String] holds a reference")
}

test "a generic union holds a by-value payload" {
  val src = "package T\n" + "record Vec2 {\n  x: Int\n  y: Int\n}\n" +
    "union Opt[T] {\n  case Has(v: T)\n  case Nope\n}\n" +
    "func orZero(o: in Opt[Vec2]): Int {\n  match o {\n    case Has(v) -> v.x + v.y\n    case Nope -> 0\n  }\n}\n" +
    "func main(): Int {\n  orZero(Has(v = Vec2(x = 4, y = 5))) + orZero(Nope)\n}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 9, "4 + 5 + 0")
}

test "an async function returns a by-value record through the task slot (ASan)" {
  val src = "package T\n" + "record Pt {\n  x: Int\n  y: Int\n}\n" +
    "async func make(a: in Int): Pt {\n  Pt(x = a, y = a * 2)\n}\n" +
    "func main(): Int {\n  val p = await make(7)\n  p.x + p.y\n}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 21, "7 + 14")
}

test "a mixed-alignment by-value record is sized correctly inside a union payload (ASan)" {
  val src = "package T\n" + "record Mix {\n  a: Byte\n  b: Long\n  c: Bool\n}\n" +
    "record Pt {\n  x: Int\n  y: Int\n}\n" +
    "union U {\n  case A(m: Mix)\n  case B(p: Pt, m: Mix)\n  case C\n}\n" +
    "func total(u: in U): Int {\n" +
    "  match u {\n" +
    "    case A(m) -> m.b.toInt()\n" +
    "    case B(p, m) -> p.x + p.y + m.b.toInt() + m.a.toInt()\n" +
    "    case C -> 0\n" +
    "  }\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val u = B(p = Pt(x = 3, y = 4), m = Mix(a = 3, b = 100, c = true))\n" +
    "  total(u) + total(A(m = Mix(a = 1, b = 5, c = false))) + total(C)\n" +
    "}\n"
  val ll = lowerToLl(src)
  assertTrue(Str.contains(ll, "%T.Mix = type { i8, i64, i1 }"), "C layout is left to LLVM")
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 115, "110 + 5 + 0")
}

test "inout and out parameters of a by-value record type (ASan)" {
  val src = "package T\n" + "record Pt {\n  x: Int\n  y: Int\n}\n" +
    "func bump(p: inout Pt): Unit {\n  p = Pt(x = p.x + 1, y = p.y + 1)\n}\n" +
    "func fill(p: out Pt): Unit {\n  p = Pt(x = 40, y = 2)\n}\n" +
    "func main(): Int {\n" +
    "  var p = Pt(x = 1, y = 2)\n" +
    "  bump(p)\n" +
    "  bump(p)\n" +
    "  var q: Pt = Pt(x = 0, y = 0)\n" +
    "  fill(q)\n" +
    "  p.x + p.y + q.x + q.y\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 49, "(3 + 4) + (40 + 2)")
}

test "tuples hold by-value records (ASan)" {
  val src = "package T\n" + "record Pt {\n  x: Int\n  y: Int\n}\n" +
    "func pairUp(p: in Pt): (Pt, Int) {\n  (p, p.x)\n}\n" +
    "func main(): Int {\n" +
    "  val (q, n) = pairUp(Pt(x = 40, y = 2))\n" +
    "  q.y + n\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 42, "2 + 40")
}

test "a by-value record survives an await in an async body (ASan)" {
  val src = "package T\n" + "record Pt {\n  x: Int\n  y: Int\n}\n" + "async func one(n: in Int): Int {\n  n + 1\n}\n" +
    "async func work(p: in Pt): Pt {\n" +
    "  val q = Pt(x = p.x * 2, y = p.y * 2)\n" +
    "  val k = await one(1)\n" +
    "  Pt(x = q.x + k, y = q.y + k)\n" +
    "}\n" +
    "func main(): Int {\n  val r = await work(Pt(x = 3, y = 4))\n  r.x + r.y\n}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 18, "(6 + 2) + (8 + 2)")
}

test "a raw NativePtr to a by-value record is not an ARC reference (nativeAddrOf and libc round-trip, ASan)" {
  val src = "package T\n" + "record Pt {\n  x: Int\n  y: Int\n}\n" +
    "extern func cMalloc(n: Long): NativePtr[Pt] = \"malloc\"\n" +
    "extern func cFree(p: NativePtr[Pt]): Unit = \"free\"\n" +
    "extern func cCopy(dst: NativePtr[Pt], src: NativePtr[Pt], n: Long): NativePtr[Pt] = \"memcpy\"\n" +
    "@unsafe_ffi\n" +
    "func main(): Int {\n" +
    "  var a = Pt(x = 11, y = 31)\n" +
    "  var b = Pt(x = 0, y = 0)\n" +
    "  val pa = nativeAddrOf(a)\n" +
    "  val _ = cCopy(nativeAddrOf(b), pa, 8)\n" +
    "  val heap = cMalloc(8)\n" +
    "  val _ = cCopy(heap, pa, 8)\n" +
    "  cFree(heap)\n" +
    "  a.x + b.y\n" +
    "}\n"
  val ll = lowerToLl(src)
  assertTrue(not Str.contains(functionBody(ll, "T.main"), "lyric_retain"), "no retain of a stack slot or malloc result")
  assertTrue(
    not Str.contains(functionBody(ll, "T.main"), "lyric_release"),
    "no release of a stack slot or malloc result"
  )
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 42, "11 + 31 survive the address-of and the copies")
}

test "a var without an initializer starts as the zero record (ASan)" {
  val src = "package T\n" + "record Pt {\n  x: Int\n  y: Int\n}\n" +
    "func main(): Int {\n  var p: Pt\n  p.x + p.y + 7\n}\n"
  val ll = lowerToLl(src)
  assertTrue(Str.contains(ll, "zeroinitializer"), "the default is zeroinitializer, not undef")
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 7, "zero fields")
}

test "slice, concat, append, toList and Map overwrite and remove of boxed values (ASan)" {
  val src = "package T\n" + "import Std.Collections\n" + "record Pt {\n  x: Int\n  y: Int\n}\n" + "func main(): Int {\n" +
    "  val xs: slice[Pt] = [Pt(x = 1, y = 2), Pt(x = 3, y = 4), Pt(x = 5, y = 6)]\n" +
    "  val sub = xs.slice(1, 3)\n" +
    "  val merged = xs.concat(sub)\n" +
    "  val ext = xs.append(Pt(x = 7, y = 8))\n" +
    "  val copy = xs.toList()\n" +
    "  val m: Map[Int, Pt] = newMap()\n" +
    "  m.add(1, Pt(x = 10, y = 0))\n" +
    "  m.add(1, Pt(x = 20, y = 0))\n" +
    "  m.add(2, Pt(x = 30, y = 0))\n" +
    "  val gone = m.remove(2)\n" +
    "  var r = sub[0].x + merged[3].y + ext[3].x + copy[2].y + m[1].x + m.count\n" +
    "  if gone { r = r + 100 }\n" +
    "  r\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, (3 + 4 + 7 + 6 + 20 + 1 + 100) % 256, "every container copy owns its own box references")
}

test "a package-local union does not collide with another package's enum of the same name" {
  val lib = "package Lib\n" + "enum LogLevel {\n  case Info\n  case Warn\n}\n"
  val app = "package T\n" + "union LogLevel {\n  case Info(code: Int)\n  case Off\n}\n" +
    "record Rec {\n  lvl: LogLevel\n  n: Int\n}\n" +
    "func main(): Int {\n" +
    "  val r = Rec(lvl = Info(code = 40), n = 2)\n" +
    "  val c = match r.lvl {\n    case Info(code) -> code\n    case Off -> 0\n  }\n" +
    "  c + r.n\n" +
    "}\n"
  val sources: List[String] = newList()
  sources.add(app)
  sources.add(lib)
  val ll = lowerBundleToLl(sources)
  assertTrue(
    Str.contains(ll, "%T.Rec = type { %T.LogLevel, i32 }"),
    "Rec embeds the local union inline, not the other package's i32 enum"
  )
  val r = runLl(ll)
  assertEqualInt(r.exitCode, 42, "the union field is read as the union")
}

test "an impl target only keeps the heap form for its own package's record" {
  val lib = "package Lib\n" + "record Sq {\n  s: Int\n}\n"
  val app = "package T\n" + "interface Area {\n  func area(): Int\n}\n" + "record Sq {\n  s: Int\n}\n" +
    "impl Area for Sq {\n  func area(): Int {\n    self.s * self.s\n  }\n}\n" +
    "func total(a: in Area): Int {\n  a.area()\n}\n" +
    "func main(): Int {\n  total(Sq(s = 6))\n}\n"
  val sources: List[String] = newList()
  sources.add(app)
  sources.add(lib)
  val ll = lowerBundleToLl(sources)
  assertTrue(Str.contains(ll, "%T.Sq = type { i32, i32, i8*, i32 }"), "the implementer is a heap object")
  assertTrue(Str.contains(ll, "%Lib.Sq = type { i32 }"), "the unrelated same-named record stays by-value")
  val r = runLl(ll)
  assertEqualInt(r.exitCode, 36, "interface dispatch")
}

test "a module-level val holding a by-value record is rejected like any non-literal module val" {
  val src = "package T\n" + "record Pt {\n  x: Int\n  y: Int\n}\n" + "val origin: Pt = Pt(x = 1, y = 2)\n" +
    "func main(): Int {\n  origin.x\n}\n"
  val file = parseOrPanic(src)
  assertPanicsWith(
    "module val",
    "non-literal initializer",
    { -> val pkg = codegenNativePackage(file, ""); val _ = lowerNativePackage(pkg) }
  )
}

test "N0010 also covers callback types and return positions, and stops a real native build" {
  val cb = "package T\n" + "record Pt {\n  x: Int\n  y: Int\n}\n" +
    "extern func onEach(f: (Pt) -> Int): Int = \"on_each\"\n" +
    "func main(): Int {\n  0\n}\n"
  val ret = "package T\n" + "record Pt {\n  x: Int\n  y: Int\n}\n" + "extern func make(n: Int): Pt = \"make_pt\"\n" +
    "func main(): Int {\n  0\n}\n"
  for src in [cb, ret] {
    val units: List[CodegenUnit] = newList()
    units.add(unitOfFile("T", parseOrPanic(src)))
    val diags = nativeByValueExternDiagnostics(units)
    assertEqualInt(diags.count, 1, "one diagnostic")
    assertTrue(Str.contains(diags[0].message, "#8009"), "the message names the tracking issue")
  }
  val stdlib = findStdlibSourcesNative()
  val stem = Path.join(
    Path.join(tempBase(), "lyric-llvm-byvalue-selftest"),
    "n0009_" + Uuid.uuidToString(Uuid.newUuid())
  )
  val _ = File.createDir(Path.dirname(stem))
  val built = compileToNativeWithFlags(ret, stem, stdlib, "", "0", newList(), newList(), "", true)
  assertTrue(not built, "linkAndEmitNative reports N0010 and aborts the build")
  assertTrue(not File.fileExists(stem), "no binary is written")
}

// ─────────────────────────────────────────────────────────────────────────────
// D157 semantics are unchanged, and the extern boundary rejects by-value records.
// ─────────────────────────────────────────────────────────────────────────────
test "a record with a var field still shares one instance (D157)" {
  val src = "package T\n" + "record Counter {\n  var n: Int\n}\n" + "record Pt {\n  x: Int\n  y: Int\n}\n" +
    "func bump(c: in Counter): Unit {\n  c.n = c.n + 1\n}\n" +
    "func main(): Int {\n" +
    "  val c = Counter(n = 0)\n" +
    "  val d = c\n" +
    "  bump(c)\n" +
    "  bump(d)\n" +
    "  val p = Pt(x = 1, y = 2)\n" +
    "  val q = p\n" +
    "  c.n * 10 + d.n + q.x + p.y\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 25, "2*10 + 2 + 1 + 2")
}

test "a Vec3 arithmetic loop runs allocation-free in main (ASan)" {
  val src = "package T\n" + vec3Decl + "func main(): Int {\n" + "  var acc = Vec3(x = 0.0f32, y = 0.0f32, z = 0.0f32)\n" +
    "  val step = Vec3(x = 1.0f32, y = 2.0f32, z = 3.0f32)\n" +
    "  var i = 0\n" +
    "  while i < 1000 {\n" +
    "    acc = addV(acc, step)\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  val d = subV(acc, step)\n" +
    "  (d.x + d.y + d.z).toInt() % 256\n" +
    "}\n"
  val ll = lowerToLl(src)
  assertTrue(not Str.contains(functionBody(ll, "T.main"), "lyric_alloc"), "the loop allocates nothing")
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 5994 % 256, "(999 + 1998 + 2997) = 5994")
}

test "an extern func passing a by-value record is rejected with N0010" {
  val src = "package T\n" + "record Pt {\n  x: Int\n  y: Int\n}\n" + "extern func takesPt(p: Pt): Int = \"take_pt\"\n" +
    "extern func fine(n: Int): Int = \"fine_fn\"\n" +
    "func main(): Int {\n  0\n}\n"
  val unit = unitOfFile("T", parseOrPanic(src))
  val units: List[CodegenUnit] = newList()
  units.add(unit)
  val diags = nativeByValueExternDiagnostics(units)
  assertEqualInt(diags.count, 1, "only the by-value signature is reported")
  assertEqual(diags[0].code, "N0010", "the diagnostic code")
  assertTrue(Str.contains(diags[0].message, "by-value record 'T.Pt'"), "the message names the record")
}

test "an extern func over a record with a var field is not rejected" {
  val src = "package T\n" + "record Box {\n  var n: Int\n}\n" + "extern func takesBox(b: Box): Int = \"take_box\"\n" +
    "func main(): Int {\n  0\n}\n"
  val units: List[CodegenUnit] = newList()
  units.add(unitOfFile("T", parseOrPanic(src)))
  assertEqualInt(nativeByValueExternDiagnostics(units).count, 0, "a heap record crosses as a pointer")
}
