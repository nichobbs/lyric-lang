//! llvm_inline_union_self_test.l — end-to-end self-test for inline unions on
//! `--target native` (docs/67 §4.2, G1 #7940).
//!
//! A union whose every case payload field is by-value (scalars, enums,
//! distinct types, by-value records, other inline unions; nullary cases are
//! free) lowers to a tagged struct VALUE `{ i32 disc, i32 pad, [W x i64] }`:
//! no heap allocation, no ARC header, no destructor.  A union with any
//! reference payload and a recursive union keep the heap form (native has no
//! `impl` for unions, so there is no interface-boxing case to cover).  The language is unchanged; these cases pin the codegen
//! policy.  Runtime cases compile with `-fsanitize=address`, so a leaked slot
//! box or a double release exits non-zero; the IR cases inspect the `.ll`.
//!
//! Requires `clang` on PATH and a built runtime (`make -C lyric-rt`).
//! Run via native `lyric test` with LYRIC_LOAD_COMPILER=1:
//!   make -C lyric-rt && LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/llvm_inline_union_self_test.l
@test_module
package Lyric.LlvmInlineUnionSelfTest

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

val optDecl: String = "union Opt[T] {\n  case Has(v: T)\n  case Nope\n}\n"

val shapeDecl: String = "union Shape {\n  case Circle(r: Double)\n  case Rect(w: Int, h: Int)\n  case Dot\n}\n" + "func area(s: in Shape): Int {\n  match s {\n    case Circle(r) -> r.toInt()\n    case Rect(w, h) -> w * h\n    case Dot -> 0\n  }\n}\n"

// ─────────────────────────────────────────────────────────────────────────────
// IR shape: inline form, no allocation, heap form kept where required.
// ─────────────────────────────────────────────────────────────────────────────
test "a union of scalars is a header-less struct and never allocates, nullary cases included" {
  val src = "package T\n" + shapeDecl + "func make(n: in Int): Shape {\n" +
    "  if n > 0 { Rect(w = n, h = 2) } else if n == 0 { Dot } else { Circle(r = 9.5) }\n}\n" +
    "func main(): Int {\n  area(make(4)) + area(make(0)) + area(make(0 - 1))\n}\n"
  val ll = lowerToLl(src)
  assertTrue(Str.contains(ll, "%T.Shape = type { i32, i32, [1 x i64] }"), "discriminant, pad, one payload word")
  assertTrue(not Str.contains(functionBody(ll, "T.make"), "lyric_alloc"), "constructing allocates nothing")
  assertTrue(not Str.contains(functionBody(ll, "T.area"), "lyric_alloc"), "matching allocates nothing")
  assertTrue(not Str.contains(functionBody(ll, "T.main"), "lyric_alloc"), "main allocates nothing")
  assertTrue(not Str.contains(ll, "T.Shape.dtor"), "no destructor")
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 17, "8 + 0 + 9")
}

test "generic unions over scalars and by-value records are inline per instantiation" {
  val src = "package T\n" + optDecl + "record Pt {\n  x: Int\n  y: Int\n}\n" +
    "func pick(n: in Int): Opt[Pt] {\n  if n > 0 { Has(v = Pt(x = n, y = n * 2)) } else { Nope }\n}\n" +
    "func orZero(o: in Opt[Int]): Int {\n  match o {\n    case Has(v) -> v\n    case Nope -> 0\n  }\n}\n" +
    "func main(): Int {\n" +
    "  val a = pick(5)\n" +
    "  val x = match a {\n    case Has(p) -> p.x + p.y\n    case Nope -> 0\n  }\n" +
    "  x + orZero(Has(v = 7)) + orZero(Nope)\n" +
    "}\n"
  val ll = lowerToLl(src)
  assertTrue(not Str.contains(functionBody(ll, "T.main"), "lyric_alloc"), "Opt[Pt] and Opt[Int] never allocate")
  assertTrue(not Str.contains(functionBody(ll, "T.pick"), "lyric_alloc"), "pick allocates nothing")
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 22, "15 + 7 + 0")
}

test "unions with a reference payload, generic instantiations over references, and recursive unions stay heap" {
  val src = "package T\n" + optDecl + "union Named {\n  case Tag(name: String)\n  case Num(n: Int)\n}\n" +
    "union Tree {\n  case Leaf\n  case Node(l: Tree, r: Tree)\n}\n" +
    "func depth(t: in Tree): Int {\n  match t {\n    case Leaf -> 0\n    case Node(l, r) -> 1 + depth(l) + depth(r)\n  }\n}\n" +
    "func main(): Int {\n" +
    "  val a = Tag(name = \"abc\")\n" +
    "  val o = Has(v = \"xy\")\n" +
    "  val n = match a {\n    case Tag(s) -> s.length\n    case Num(k) -> k\n  }\n" +
    "  val m = match o {\n    case Has(s) -> s.length\n    case Nope -> 0\n  }\n" +
    "  n + m + depth(Node(l = Leaf, r = Node(l = Leaf, r = Leaf)))\n" +
    "}\n"
  val ll = lowerToLl(src)
  assertTrue(Str.contains(ll, "%T.Named = type { i32, i32, i8*, i32, i32, ["), "a String payload is a heap object")
  assertTrue(Str.contains(ll, "%T.Tree = type { i32, i32, i8*, i32, i32, ["), "a recursive union is a heap object")
  assertTrue(Str.contains(functionBody(ll, "T.main"), "lyric_alloc"), "heap unions allocate")
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 7, "3 + 2 + 2")
}

test "a union holding an enum and a distinct type is inline; an all-nullary union has no payload" {
  val src = "package T\n" + "enum Color {\n  case Red\n  case Green\n}\n" + "type Meters = Long\n" +
    "union Mark {\n  case Tinted(c: Color, d: Meters)\n  case Plain\n}\n" +
    "union Flag {\n  case On\n  case Off\n}\n" +
    "func main(): Int {\n" +
    "  val m = Tinted(c = Green, d = Meters(40))\n" +
    "  val f = On\n" +
    "  val a = match m {\n    case Tinted(c, d) -> d.value.toInt() + 2\n    case Plain -> 0\n  }\n" +
    "  val b = match f {\n    case On -> 1\n    case Off -> 0\n  }\n" +
    "  a + b\n" +
    "}\n"
  val ll = lowerToLl(src)
  assertTrue(
    Str.contains(ll, "%T.Mark = type { i32, i32, [2 x i64] }") or
      Str.contains(ll, "%T.Mark = type { i32, i32, [1 x i64] }"),
    "enum + Long payload"
  )
  assertTrue(Str.contains(ll, "%T.Flag = type { i32, i32, [0 x i64] }"), "a union of nullary cases carries no payload")
  assertTrue(not Str.contains(functionBody(ll, "T.main"), "lyric_alloc"), "no allocation")
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 43, "42 + 1")
}

test "payload alignment: Double, Long and a Byte-Long record share one union" {
  val src = "package T\n" + "record Mix {\n  a: Byte\n  b: Long\n  c: Bool\n}\n" +
    "union U {\n  case D(d: Double)\n  case L(l: Long, b: Byte)\n  case M(m: Mix)\n  case Z\n}\n" +
    "func score(u: in U): Int {\n" +
    "  match u {\n" +
    "    case D(d) -> d.toInt()\n" +
    "    case L(l, b) -> l.toInt() + b.toInt()\n" +
    "    case M(m) -> m.b.toInt() + m.a.toInt()\n" +
    "    case Z -> 0\n" +
    "  }\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  score(D(d = 2.5)) + score(L(l = 100, b = 3)) + score(M(m = Mix(a = 4, b = 20, c = true))) + score(Z)\n" +
    "}\n"
  val ll = lowerToLl(src)
  assertTrue(Str.contains(ll, "%T.U = type { i32, i32, [3 x i64] }"), "the Byte-Long-Bool record needs three words")
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 2 + 103 + 24, "every case reads back its own payload")
}

// ─────────────────────────────────────────────────────────────────────────────
// Nesting and containment.
// ─────────────────────────────────────────────────────────────────────────────
test "inline unions nest in unions, in records, and hold records (ASan)" {
  val src = "package T\n" + "record Pt {\n  x: Int\n  y: Int\n}\n" + "union Inner {\n  case A(p: Pt)\n  case B\n}\n" +
    "union Outer {\n  case W(i: Inner, k: Int)\n  case E\n}\n" +
    "record Holder {\n  o: Outer\n  n: Int\n}\n" +
    "func sum(h: in Holder): Int {\n" +
    "  val a = match h.o {\n" +
    "    case W(i, k) -> match i {\n      case A(p) -> p.x + p.y + k\n      case B -> k\n    }\n" +
    "    case E -> 0\n" +
    "  }\n" +
    "  a + h.n\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val h1 = Holder(o = W(i = A(p = Pt(x = 1, y = 2)), k = 10), n = 100)\n" +
    "  val h2 = Holder(o = W(i = B, k = 5), n = 1)\n" +
    "  val h3 = Holder(o = E, n = 2)\n" +
    "  sum(h1) + sum(h2) + sum(h3)\n" +
    "}\n"
  val ll = lowerToLl(src)
  assertTrue(Str.contains(ll, "%T.Holder = type { %T.Outer, i32 }"), "the record embeds the union inline")
  assertTrue(not Str.contains(functionBody(ll, "T.main"), "lyric_alloc"), "no allocation")
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 121, "113 + 6 + 2")
}

test "a heap record and a heap union hold inline unions as plain fields (ASan)" {
  val src = "package T\n" + optDecl + "record Cell {\n  var v: Opt[Int]\n  var name: String\n}\n" +
    "union Wrap {\n  case Box(o: Opt[Int], s: String)\n  case Empty\n}\n" +
    "func main(): Int {\n" +
    "  val c = Cell(v = Has(v = 3), name = \"c\")\n" +
    "  val alias = c\n" +
    "  alias.v = Has(v = 40)\n" +
    "  val w = Box(o = c.v, s = \"w\")\n" +
    "  val inner = match w {\n    case Box(o, s) -> match o {\n      case Has(x) -> x + s.length\n      case Nope -> 0\n    }\n    case Empty -> 0\n  }\n" +
    "  inner + c.name.length\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 42, "40 + 1 + 1")
}

// ─────────────────────────────────────────────────────────────────────────────
// Equality, collections, closures, async, raw pointers.
// ─────────────────────────────────────────────────────────────────────────────
test "inline unions compare by case and payload, nested and as record fields" {
  val src = "package T\n" + optDecl + "record Pt {\n  x: Int\n  y: Int\n}\n" +
    "union Maybe {\n  case Yes(v: Int)\n  case No\n}\n" +
    "record Slot {\n  o: Maybe\n  p: Pt\n}\n" +
    "func main(): Int {\n" +
    "  val a: Opt[Int] = Has(v = 3)\n" +
    "  val b: Opt[Int] = Has(v = 3)\n" +
    "  val c: Opt[Int] = Has(v = 4)\n" +
    "  val n: Opt[Int] = Nope\n" +
    "  val s1 = Slot(o = Yes(v = 3), p = Pt(x = 1, y = 2))\n" +
    "  val s2 = Slot(o = Yes(v = 3), p = Pt(x = 1, y = 2))\n" +
    "  val s3 = Slot(o = Yes(v = 4), p = Pt(x = 1, y = 2))\n" +
    "  var r = 0\n" +
    "  if a == b { r = r + 1 }\n" +
    "  if a != c { r = r + 10 }\n" +
    "  if a == n { r = r + 100 }\n" +
    "  if n == n { r = r + 1000 }\n" +
    "  if s1 == s2 { r = r + 10000 }\n" +
    "  if s1 == s3 { r = r + 100000 }\n" +
    "  r\n" +
    "}\n"
  val ll = lowerToLl(src)
  assertTrue(
    Str.contains(ll, "%T.Slot = type { %T.Maybe, %T.Pt }"),
    "the record embeds the union and the record inline"
  )
  assertTrue(not Str.contains(functionBody(ll, "T.main"), "lyric_alloc"), "no allocation")
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 11011 % 256, "equal cases and payloads only")
}

test "inline unions in a List, a Map, and through toList and slice (ASan)" {
  val src = "package T\n" + "import Std.Collections\n" + optDecl +
    "func unv(o: in Opt[Int]): Int {\n  match o {\n    case Has(v) -> v\n    case Nope -> 1000\n  }\n}\n" +
    "func main(): Int {\n" +
    "  val xs: List[Opt[Int]] = newList()\n" +
    "  xs.add(Has(v = 4))\n" +
    "  xs.add(Nope)\n" +
    "  xs.add(Has(v = 8))\n" +
    "  xs[1] = Has(v = 16)\n" +
    "  val copy = xs.toList()\n" +
    "  val m: Map[Int, Opt[Int]] = newMap()\n" +
    "  m.add(1, Has(v = 1))\n" +
    "  m.add(1, Nope)\n" +
    "  m.add(2, Has(v = 2))\n" +
    "  val gone = m.remove(2)\n" +
    "  var t = 0\n" +
    "  for x in xs {\n    t = t + unv(x)\n  }\n" +
    "  t + unv(copy[2]) + unv(m[1]) + m.count\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, (28 + 8 + 1000 + 1) % 256, "boxes are retained and released with their containers")
}

test "closures capture and return inline unions; if and match produce them (ASan)" {
  val src = "package T\n" + optDecl +
    "func make(base: in Opt[Int]): (Int) -> Opt[Int] {\n  { k -> match base {\n    case Has(v) -> Has(v = v + k)\n    case Nope -> Nope\n  } }\n}\n" +
    "func unv(o: in Opt[Int]): Int {\n  match o {\n    case Has(v) -> v\n    case Nope -> 100\n  }\n}\n" +
    "func main(): Int {\n" +
    "  val f = make(Has(v = 10))\n" +
    "  val g = make(Nope)\n" +
    "  val picked = if unv(f(1)) > 5 { f(2) } else { g(3) }\n" +
    "  unv2(picked) + unv(g(1))\n" +
    "}\n" +
    "func unv2(o: in Opt[Int]): Int {\n  unv(o)\n}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 112, "12 + 100")
}

test "an async function returns an inline union through the task slot (ASan)" {
  val src = "package T\n" + optDecl +
    "async func look(a: in Int): Opt[Int] {\n  if a > 0 { Has(v = a * 2) } else { Nope }\n}\n" +
    "func main(): Int {\n" +
    "  val o = await look(21)\n" +
    "  match o {\n    case Has(v) -> v\n    case Nope -> 0\n  }\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 42, "21 * 2")
}

test "a raw NativePtr to an inline union is not an ARC reference (ASan)" {
  val src = "package T\n" + optDecl +
    "extern func cCopy(dst: NativePtr[Opt[Int]], src: NativePtr[Opt[Int]], n: Long): NativePtr[Opt[Int]] = \"memcpy\"\n" +
    "@unsafe_ffi\n" +
    "func main(): Int {\n" +
    "  var a: Opt[Int] = Has(v = 42)\n" +
    "  var b: Opt[Int] = Nope\n" +
    "  val _ = cCopy(nativeAddrOf(b), nativeAddrOf(a), 16)\n" +
    "  match b {\n    case Has(v) -> v\n    case Nope -> 0\n  }\n" +
    "}\n"
  val ll = lowerToLl(src)
  assertTrue(not Str.contains(functionBody(ll, "T.main"), "lyric_retain"), "no retain of a stack slot")
  assertTrue(not Str.contains(functionBody(ll, "T.main"), "lyric_release"), "no release of a stack slot")
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 42, "the copied value reads back")
}

test "an extern func passing an inline union is rejected with N0010" {
  val src = "package T\n" + "union Shape {\n  case Sq(s: Int)\n  case Dot\n}\n" +
    "extern func takes(s: Shape): Int = \"take_shape\"\n" +
    "func main(): Int {\n  0\n}\n"
  val units: List[CodegenUnit] = newList()
  units.add(unitOfFile("T", parseOrPanic(src)))
  val diags = nativeByValueExternDiagnostics(units)
  assertEqualInt(diags.count, 1, "one diagnostic")
  assertEqual(diags[0].code, "N0010", "the diagnostic code")
  assertTrue(Str.contains(diags[0].message, "#8009"), "the message names the tracking issue")
}

test "a package-local inline union is not shadowed by another package's enum of the same name" {
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
  assertTrue(Str.contains(ll, "%T.Rec = type { %T.LogLevel, i32 }"), "Rec embeds the local union, not an i32 enum")
  val r = runLl(ll)
  assertEqualInt(r.exitCode, 42, "the union field is read as the union")
}

// ─────────────────────────────────────────────────────────────────────────────
// Generic applications in field types, extern signatures, construction order,
// payload widths, wasm32, NaN equality, bundles.
// ─────────────────────────────────────────────────────────────────────────────
test "a record and a union holding generic inline unions embed them inline (ASan)" {
  val src = "package T\n" + optDecl + "record Pt {\n  x: Int\n  y: Int\n}\n" +
    "record Holder {\n  o: Opt[Pt]\n  n: Int\n}\n" +
    "union Msg {\n  case Got(o: Opt[Int])\n  case Quiet\n}\n" +
    "func read(h: in Holder): Int {\n  match h.o {\n    case Has(p) -> p.x + p.y + h.n\n    case Nope -> h.n\n  }\n}\n" +
    "func code(m: in Msg): Int {\n  match m {\n    case Got(o) -> match o {\n      case Has(v) -> v\n      case Nope -> 0 - 1\n    }\n    case Quiet -> 0\n  }\n}\n" +
    "func main(): Int {\n" +
    "  val a = Holder(o = Has(v = Pt(x = 1, y = 2)), n = 10)\n" +
    "  val b = Holder(o = Nope, n = 20)\n" +
    "  read(a) + read(b) + code(Got(o = Has(v = 7))) + code(Got(o = Nope)) + code(Quiet)\n" +
    "}\n"
  val ll = lowerToLl(src)
  assertTrue(Str.contains(ll, "%T.Holder = type { %\"T.Opt<T.Pt>\", i32 }"), "Holder embeds Opt[Pt] inline")
  assertTrue(
    Str.contains(ll, "%T.Msg = type { i32, i32, [2 x i64] }"),
    "Msg holds the 16-byte Opt[Int] in its payload words"
  )
  assertTrue(not Str.contains(functionBody(ll, "T.main"), "lyric_alloc"), "no allocation")
  assertTrue(not Str.contains(ll, "T.Holder.dtor"), "no destructor")
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 13 + 20 + 7 - 1 + 0, "13 + 20 + 7 - 1 + 0")
}

test "equality on a record holding a generic inline union is structural" {
  val src = "package T\n" + optDecl + "record Holder {\n  o: Opt[Int]\n  n: Int\n}\n" + "func main(): Int {\n" +
    "  val a = Holder(o = Has(v = 3), n = 1)\n" +
    "  val b = Holder(o = Has(v = 3), n = 1)\n" +
    "  val c = Holder(o = Has(v = 4), n = 1)\n" +
    "  val d = Holder(o = Nope, n = 1)\n" +
    "  var r = 0\n" +
    "  if a == b { r = r + 1 }\n" +
    "  if a == c { r = r + 10 }\n" +
    "  if a == d { r = r + 100 }\n" +
    "  if d == d { r = r + 1000 }\n" +
    "  r\n" +
    "}\n"
  val ll = lowerToLl(src)
  assertTrue(Str.contains(ll, "%T.Holder = type { %\"T.Opt<i32>\", i32 }"), "inline field")
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 1001 % 256, "equal case and payload only")
}

test "a generic inline union in an extern signature is N0010, through the real build" {
  val src = "package T\n" + optDecl + "extern func take(o: Opt[Int]): Int = \"take_opt\"\n" +
    "func main(): Int {\n  0\n}\n"
  val units: List[CodegenUnit] = newList()
  units.add(unitOfFile("T", parseOrPanic(src)))
  val diags = nativeByValueExternDiagnostics(units)
  assertEqualInt(diags.count, 1, "one diagnostic")
  assertEqual(diags[0].code, "N0010", "the code")
  assertTrue(Str.contains(diags[0].message, "union 'T.Opt<i32>'"), "names the union instantiation")
  assertTrue(Str.contains(diags[0].message, "reference payload"), "a union's own remedy")
  assertTrue(not Str.contains(diags[0].message, "`var` field"), "no record remedy")
  val stdlib = findStdlibSourcesNative()
  val stem = Path.join(Path.join(tempBase(), "lyric-llvm-byvalue-selftest"), "iu_" + Uuid.uuidToString(Uuid.newUuid()))
  val _ = File.createDir(Path.dirname(stem))
  val built = compileToNativeWithFlags(src, stem, stdlib, "", "0", newList(), newList(), "", true)
  assertTrue(not built, "linkAndEmitNative stops the build")
  assertTrue(not File.fileExists(stem), "no binary is written")
}

test "two constructions of one union in a single call, and values kept across a loop (ASan)" {
  val src = "package T\n" + "import Std.Collections\n" + optDecl + "func pair(a: in Opt[Int], b: in Opt[Int]): Int {\n" +
    "  val x = match a {\n    case Has(v) -> v\n    case Nope -> 100\n  }\n" +
    "  val y = match b {\n    case Has(v) -> v\n    case Nope -> 200\n  }\n" +
    "  x * 3 + y\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val kept: List[Opt[Int]] = newList()\n" +
    "  var i = 0\n" +
    "  while i < 50 {\n" +
    "    kept.add(if i % 2 == 0 { Has(v = i) } else { Nope })\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  var t = 0\n" +
    "  for k in kept {\n    t = t + match k {\n      case Has(v) -> v\n      case Nope -> 1\n    }\n  }\n" +
    "  pair(Has(v = 4), Has(v = 5)) + pair(Nope, Has(v = 1)) + t\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, (17 + 301 + 600 + 25) % 256, "each construction owns its slot")
}

test "Option through Map get is inline (user Option, mapGet path, ASan)" {
  val src = "package T\n" + "import Std.Collections\n" + "union Option[T] {\n  case Some(v: T)\n  case None\n}\n" +
    "func main(): Int {\n" +
    "  val m: Map[Int, Int] = newMap()\n" +
    "  m.add(1, 40)\n" +
    "  val hit = match mapGet(m, 1) {\n    case Some(v) -> v\n    case None -> 0\n  }\n" +
    "  val miss = match mapGet(m, 2) {\n    case Some(v) -> v\n    case None -> 2\n  }\n" +
    "  hit + miss\n" +
    "}\n"
  val ll = lowerToLl(src)
  assertTrue(not Str.contains(functionBody(ll, "T.main"), "lyric_alloc"), "the Option result is not allocated")
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 42, "40 + 2")
}

test "a Float payload and a Double payload share one inline union" {
  val src = "package T\n" + "union N {\n  case F(f: Float)\n  case D(d: Double)\n  case Z\n}\n" +
    "func score(n: in N): Int {\n  match n {\n    case F(f) -> f.toInt()\n    case D(d) -> d.toInt()\n    case Z -> 0\n  }\n}\n" +
    "func main(): Int {\n  score(F(f = 2.5f32)) + score(D(d = 40.75)) + score(Z)\n}\n"
  val ll = lowerToLl(src)
  assertTrue(Str.contains(ll, "%T.N = type { i32, i32, [1 x i64] }"), "one payload word for either width")
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 42, "2 + 40")
}

test "the wasm32 layout of an inline union and a record holding one" {
  val src = "package T\n" + optDecl + "record Holder {\n  o: Opt[Long]\n  n: Int\n}\n" +
    "func main(): Int {\n  val h = Holder(o = Has(v = 5), n = 1)\n  h.n\n}\n"
  val pkg = codegenNativePackage(parseOrPanic(src), "wasm32-unknown-wasi")
  val ll = lowerNativePackage(pkg)
  assertTrue(Str.contains(ll, "target triple = \"wasm32-unknown-wasi\""), "wasm32 triple")
  assertTrue(
    Str.contains(ll, "\"T.Opt<i64>\" = type { i32, i32, [1 x i64] }"),
    "payload words do not depend on pointer width"
  )
  assertTrue(Str.contains(ll, "%T.Holder = type { %\"T.Opt<i64>\", i32 }"), "the holder embeds it")
}

test "NaN payloads compare unequal under x == x for heap and inline unions alike" {
  val src = "package T\n" + "union Inl {\n  case V(d: Double)\n  case Z\n}\n" +
    "union Hp {\n  case V(d: Double, s: String)\n  case Z\n}\n" +
    "func main(): Int {\n" +
    "  val zero = 0.0\n" +
    "  val nan = zero / zero\n" +
    "  val i = V(d = nan)\n" +
    "  val h = Hp.V(d = nan, s = \"s\")\n" +
    "  var r = 0\n" +
    "  if i == i { r = r + 1 }\n" +
    "  if h == h { r = r + 10 }\n" +
    "  if V(d = 1.0) == V(d = 1.0) { r = r + 100 }\n" +
    "  r\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 100, "only the non-NaN comparison is equal")
}

test "classification is the same in a multi-package bundle" {
  val lib = "package Lib\n" + "union Opt[T] {\n  case Has(v: T)\n  case Nope\n}\n" +
    "record Slot {\n  o: Opt[Int]\n  k: Int\n}\n" +
    "func mk(): Slot {\n  Slot(o = Has(v = 41), k = 1)\n}\n"
  val app = "package T\n" + "func main(): Int {\n  val s = Lib.mk()\n  s.k\n}\n"
  val sources: List[String] = newList()
  sources.add(app)
  sources.add(lib)
  val ll = lowerBundleToLl(sources)
  assertTrue(
    Str.contains(ll, "%Lib.Slot = type { %\"Lib.Opt<i32>\", i32 }"),
    "the library record embeds the instantiation inline"
  )
  assertTrue(Str.contains(ll, "\"Lib.Opt<i32>\" = type { i32, i32, [1 x i64] }"), "the instantiation is inline")
}
