//! llvm_heap_self_test.l — end-to-end self-test for Phase N2 of
//! `Lyric.LlvmCodegen` (records, unions, enums, distinct types, pattern
//! matching, ARC): parses small Lyric programs, lowers them to `.ll`,
//! compiles with clang against `lyric-rt/build/lyric_rt.a`, runs the
//! produced binary, and asserts its exit code and stdout.
//!
//! The ARC cases compile with `-fsanitize=address` (LeakSanitizer is on
//! by default on Linux): a missed release (leak), premature release
//! (use-after-free), or double release all make the binary exit
//! non-zero, so `exit 0` is a real end-to-end ARC correctness check.
//!
//! Requires `clang` on PATH and a built runtime (`make -C lyric-rt`).
//! Run via native `lyric test` with LYRIC_LOAD_COMPILER=1:
//!   make -C lyric-rt && LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/llvm_heap_self_test.l
@test_module
package Lyric.LlvmHeapSelfTest

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

// ─────────────────────────────────────────────────────────────────────────────
// Harness (mirrors llvm_codegen_self_test.l, plus an ASan variant).
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

func compileAndRunWith(source: in String, sanitize: in Bool): RunOutcome {
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
  val pkg = codegenNativePackage(pr.file, "")
  val ll = lowerNativePackage(pkg)
  val rt = findLyricRt()
  if rt.length == 0 {
    panic("lyric_rt.a not found; run `make -C lyric-rt` first")
  }
  val dir = Path.join(tempBase(), "lyric-llvm-heap-selftest")
  val _ = File.createDir(dir)
  val stem = Path.join(dir, "t_" + uuidToString(newUuid()))
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

func compileAndRun(source: in String): RunOutcome {
  compileAndRunWith(source, false)
}

/// ASan+LSan build: leaks, use-after-free, and double-free all exit
/// non-zero, so `exitCode == 0` verifies the emitted ARC protocol.
func compileAndRunAsan(source: in String): RunOutcome {
  compileAndRunWith(source, true)
}

/// Same-package console shim: `codegenNativePackage` compiles a single
/// file with no bundled stdlib, so tests that print supply their own
/// `println` over the lyric-rt console externs (mirrors
/// llvm_codegen_self_test.l).
func printlnShim(): String {
  "extern func consoleWriteFd(fd: Int, s: String): Unit = \"lyric_console_write\"\n" +
    "extern func consoleNewlineFd(fd: Int): Unit = \"lyric_console_write_newline\"\n" +
    "func println(s: in String): Unit {\n" +
    "  consoleWriteFd(1, s)\n" +
    "  consoleNewlineFd(1)\n" +
    "}\n"
}

// ─────────────────────────────────────────────────────────────────────────────
// Records.
// ─────────────────────────────────────────────────────────────────────────────
test "record construction and scalar field access" {
  val src = "package T\n" + "record Point {\n" + "  x: Int\n" + "  y: Int\n" + "}\n" + "func main(): Int {\n" +
    "  val p = Point(x = 11, y = 31)\n" +
    "  p.x + p.y\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 42, "record fields")
}

test "record with string field prints" {
  val src = "package T\n" + printlnShim() + "record User {\n" + "  name: String\n" + "  age: Int\n" + "}\n" +
    "func main(): Unit {\n" +
    "  val u = User(name = \"lyric\", age = 3)\n" +
    "  println(u.name + \":\" + u.age.toString())\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 0, "string field exit")
  assertEqual(r.stdout, "lyric:3\n", "string field stdout")
}

test "nested record field chain" {
  val src = "package T\n" + "record Inner {\n" + "  v: Int\n" + "}\n" + "record Outer {\n" + "  inner: Inner\n" +
    "  tag: String\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val o = Outer(inner = Inner(v = 7), tag = \"t\")\n" +
    "  o.inner.v\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 7, "nested record")
}

test "record field defaults" {
  val src = "package T\n" + "record Config {\n" + "  host: String\n" + "  port: Int = 8080\n" + "}\n" +
    "func main(): Int {\n" +
    "  val c = Config(host = \"localhost\")\n" +
    "  c.port / 100\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 80, "field default")
}

test "mutable record field assignment" {
  val src = "package T\n" + "record Counter {\n" + "  var n: Int\n" + "  var label: String\n" + "}\n" +
    "func main(): Int {\n" +
    "  val c = Counter(n = 0, label = \"a\")\n" +
    "  c.n = 5\n" +
    "  c.n += 3\n" +
    "  c.label = c.label + \"b\"\n" +
    "  c.n + c.label.length\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 10, "field assignment")
}

test "record method with self receiver" {
  val src = "package T\n" + "record Point {\n" + "  x: Int\n" + "  y: Int\n" + "  func dist2(): Int {\n" +
    "    self.x * self.x + self.y * self.y\n" +
    "  }\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val p = Point(x = 3, y = 4)\n" +
    "  p.dist2()\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 25, "record method")
}

test "ufcs call on record" {
  val src = "package T\n" + "record Pair {\n" + "  a: Int\n" + "  b: Int\n" + "}\n" +
    "func total(p: in Pair, extra: in Int): Int {\n" +
    "  p.a + p.b + extra\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val p = Pair(a = 10, b = 20)\n" +
    "  p.total(12)\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 42, "ufcs")
}

// ─────────────────────────────────────────────────────────────────────────────
// Unions and pattern matching.
// ─────────────────────────────────────────────────────────────────────────────
test "union construction and match with payload binds" {
  val src = "package T\n" + "union Shape {\n" + "  case Circle(r: Int)\n" + "  case Rect(w: Int, h: Int)\n" +
    "  case Empty\n" +
    "}\n" +
    "func area(s: in Shape): Int {\n" +
    "  match s {\n" +
    "    case Circle(r) -> r * r * 3\n" +
    "    case Rect(w, h) -> w * h\n" +
    "    case Empty -> 0\n" +
    "  }\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val c = Circle(r = 4)\n" +
    "  val rc = Rect(w = 3, h = 5)\n" +
    "  val e = Empty\n" +
    "  area(c) + area(rc) + area(e)\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 63, "union match")
}

test "union with string payload and nullary case path" {
  val src = "package T\n" + printlnShim() + "union MaybeStr {\n" + "  case Just(s: String)\n" + "  case Nothing\n" +
    "}\n" +
    "func show(m: in MaybeStr): String {\n" +
    "  match m {\n" +
    "    case Just(s) -> s\n" +
    "    case Nothing -> \"none\"\n" +
    "  }\n" +
    "}\n" +
    "func main(): Unit {\n" +
    "  println(show(Just(s = \"yes\")) + \"/\" + show(Nothing))\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 0, "string union exit")
  assertEqual(r.stdout, "yes/none\n", "string union stdout")
}

test "positional union fields bind positionally" {
  val src = "package T\n" + "union P {\n" + "  case Pair(Int, Int)\n" + "  case One(Int)\n" + "}\n" +
    "func main(): Int {\n" +
    "  val p = Pair(6, 7)\n" +
    "  match p {\n" +
    "    case Pair(a, b) -> a * b\n" +
    "    case One(x) -> x\n" +
    "  }\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 42, "positional fields")
}

test "match guards, literals, wildcard, binding" {
  val src = "package T\n" + "func classify(n: in Int): Int {\n" + "  match n {\n" + "    case 0 -> 100\n" +
    "    case x if x < 0 -> 200\n" +
    "    case 7 -> 300\n" +
    "    case _ -> 400\n" +
    "  }\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  (classify(0) / 100) + (classify(-5) / 100) * 10 + (classify(7) / 100) * 100 - 321 + classify(9) / 100\n" +
    "}\n"
  val r = compileAndRun(src)
  // 1 + 20 + 300 - 321 + 4 = 4
  assertEqualInt(r.exitCode, 4, "guards and literals")
}

test "match on string literals" {
  val src = "package T\n" + "func code(s: in String): Int {\n" + "  match s {\n" + "    case \"alpha\" -> 1\n" +
    "    case \"beta\" -> 2\n" +
    "    case _ -> 9\n" +
    "  }\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  code(\"alpha\") * 100 + code(\"beta\") * 10 + code(\"other\")\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 129, "string match")
}

test "match arms produce string values" {
  val src = "package T\n" + printlnShim() + "func pick(n: in Int): String {\n" + "  val base = \"pre-\"\n" +
    "  match n {\n" +
    "    case 1 -> base + \"one\"\n" +
    "    case _ -> \"other\"\n" +
    "  }\n" +
    "}\n" +
    "func main(): Unit {\n" +
    "  println(pick(1) + \"/\" + pick(2))\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqual(r.stdout, "pre-one/other\n", "match value stdout")
}

test "non-exhaustive match panics" {
  val src = "package T\n" + "func main(): Int {\n" + "  val n = 5\n" + "  match n {\n" + "    case 1 -> 10\n" + "  }\n" +
    "}\n"
  val r = compileAndRun(src)
  assertTrue(r.exitCode != 0, "non-exhaustive match must abort")
}

// ─────────────────────────────────────────────────────────────────────────────
// Enums and distinct types.
// ─────────────────────────────────────────────────────────────────────────────
test "enum cases and match" {
  val src = "package T\n" + "enum Color {\n" + "  case Red\n" + "  case Green\n" + "  case Blue\n" + "}\n" +
    "func toCode(c: in Color): Int {\n" +
    "  match c {\n" +
    "    case Color.Red -> 1\n" +
    "    case Color.Green -> 2\n" +
    "    case Color.Blue -> 3\n" +
    "  }\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  toCode(Color.Red) * 100 + toCode(Color.Green) * 10 + toCode(Color.Blue)\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 123, "enum match")
}

test "distinct type with range check passes in range" {
  val src = "package T\n" + "type Age = Int range 0 ..= 150\n" + "func main(): Int {\n" + "  val a = Age(42)\n" +
    "  a.value\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 42, "distinct in range")
}

test "distinct type range violation panics" {
  val src = "package T\n" + "type Age = Int range 0 ..= 150\n" + "func main(): Int {\n" + "  val a = Age(200)\n" +
    "  a.value\n" +
    "}\n"
  val r = compileAndRun(src)
  assertTrue(r.exitCode != 0, "range violation must abort")
}

// ─────────────────────────────────────────────────────────────────────────────
// ARC: leak/UAF/double-free checks under AddressSanitizer.
// ─────────────────────────────────────────────────────────────────────────────
test "arc: allocation loop with match and continue is leak-free" {
  val src = "package T\n" + "record Node {\n" + "  name: String\n" + "  next: Int\n" + "}\n" + "union MaybeStr {\n" +
    "  case Just(s: String)\n" +
    "  case Nothing\n" +
    "}\n" +
    "func makeName(i: in Int): String {\n" +
    "  \"node-\" + i.toString()\n" +
    "}\n" +
    "func pick(i: in Int): MaybeStr {\n" +
    "  if i % 3 == 0 {\n" +
    "    Nothing\n" +
    "  } else {\n" +
    "    Just(s = makeName(i))\n" +
    "  }\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  var total = 0\n" +
    "  var i = 0\n" +
    "  while i < 2000 {\n" +
    "    val n = Node(name = makeName(i), next = i + 1)\n" +
    "    val m = pick(i)\n" +
    "    val label = match m {\n" +
    "      case Just(s) -> s\n" +
    "      case Nothing -> \"none\"\n" +
    "    }\n" +
    "    if label.length > 4 {\n" +
    "      total = total + n.next\n" +
    "    }\n" +
    "    if i % 7 == 0 {\n" +
    "      i = i + 2\n" +
    "      continue\n" +
    "    }\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  if total > 0 {\n" +
    "    0\n" +
    "  } else {\n" +
    "    1\n" +
    "  }\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 0, "allocation loop leak-free (ASan)")
}

test "arc: mutable ref-field overwrite churn is leak-free" {
  val src = "package T\n" + "record Box {\n" + "  var content: String\n" + "}\n" + "func main(): Int {\n" +
    "  val b = Box(content = \"start\")\n" +
    "  var i = 0\n" +
    "  while i < 1000 {\n" +
    "    b.content = \"value-\" + i.toString()\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  if b.content.length > 5 {\n" +
    "    0\n" +
    "  } else {\n" +
    "    1\n" +
    "  }\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 0, "field overwrite leak-free (ASan)")
}

test "arc: returned strings and var rebinding are leak-free" {
  val src = "package T\n" + "func greet(name: in String): String {\n" + "  \"hello, \" + name\n" + "}\n" +
    "func main(): Int {\n" +
    "  var acc = 0\n" +
    "  var last = \"\"\n" +
    "  var i = 0\n" +
    "  while i < 500 {\n" +
    "    val g = greet(\"world-\" + i.toString())\n" +
    "    last = g\n" +
    "    acc = acc + g.length\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  if acc > 0 and last.length > 0 {\n" +
    "    0\n" +
    "  } else {\n" +
    "    1\n" +
    "  }\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 0, "returned strings leak-free (ASan)")
}

test "arc: nested record graphs destruct fully" {
  val src = "package T\n" + "record Inner {\n" + "  data: String\n" + "}\n" + "record Outer {\n" + "  inner: Inner\n" +
    "  tag: String\n" +
    "}\n" +
    "func build(i: in Int): Outer {\n" +
    "  Outer(inner = Inner(data = \"payload-\" + i.toString()), tag = \"tag-\" + i.toString())\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  var n = 0\n" +
    "  var i = 0\n" +
    "  while i < 800 {\n" +
    "    val o = build(i)\n" +
    "    n = n + o.inner.data.length + o.tag.length\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  if n > 0 {\n" +
    "    0\n" +
    "  } else {\n" +
    "    1\n" +
    "  }\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 0, "nested destructors leak-free (ASan)")
}

test "arc: early return and break unwind scopes" {
  val src = "package T\n" + "func firstLong(limit: in Int): String {\n" + "  var i = 0\n" + "  while i < limit {\n" +
    "    val s = \"item-\" + i.toString()\n" +
    "    if s.length > 7 {\n" +
    "      return s\n" +
    "    }\n" +
    "    if i > 500 {\n" +
    "      break\n" +
    "    }\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  \"none\"\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  var i = 0\n" +
    "  var acc = 0\n" +
    "  while i < 300 {\n" +
    "    val s = firstLong(1000)\n" +
    "    acc = acc + s.length\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  if acc > 0 {\n" +
    "    0\n" +
    "  } else {\n" +
    "    1\n" +
    "  }\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 0, "early-exit unwinding leak-free (ASan)")
}

// ─────────────────────────────────────────────────────────────────────────────
// Generic type monomorphization (N3.1).
// ─────────────────────────────────────────────────────────────────────────────
test "generic union and record instantiate from arguments" {
  val src = "package T\n" + "union Maybe[T] {\n" + "  case Just(v: T)\n" + "  case Nada\n" + "}\n" + "record Box[T] {\n" +
    "  item: T\n" +
    "  tag: Int\n" +
    "}\n" +
    "func unwrapOr(m: in Maybe[Int], dflt: in Int): Int {\n" +
    "  match m {\n" +
    "    case Just(v) -> v\n" +
    "    case Nada -> dflt\n" +
    "  }\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val a = Just(40)\n" +
    "  val b: Maybe[Int] = Nada\n" +
    "  val box = Box(item = \"hi\", tag = 2)\n" +
    "  unwrapOr(a, 0) + unwrapOr(b, 1) + box.item.length + box.tag - 3\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 42, "generic instantiation")
}

test "two-param generic union constructs via expected types" {
  val src = "package T\n" + "union Res[T, E] {\n" + "  case Good(v: T)\n" + "  case Bad(err: E)\n" + "}\n" +
    "func parse(n: in Int): Res[Int, String] {\n" +
    "  if n >= 0 {\n" +
    "    Good(n * 2)\n" +
    "  } else {\n" +
    "    Bad(\"negative\")\n" +
    "  }\n" +
    "}\n" +
    "func score(r: in Res[Int, String]): Int {\n" +
    "  match r {\n" +
    "    case Good(v) -> v\n" +
    "    case Bad(err) -> err.length\n" +
    "  }\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  score(parse(20)) + score(parse(-1))\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 48, "expected-type construction")
}

test "arc: nested generic instantiations with string payloads are leak-free" {
  val src = "package T\n" + "union Maybe[T] {\n" + "  case Just(v: T)\n" + "  case Nada\n" + "}\n" +
    "func describe(m: in Maybe[String]): Int {\n" +
    "  match m {\n" +
    "    case Just(s) -> s.length\n" +
    "    case Nada -> 0\n" +
    "  }\n" +
    "}\n" +
    "func wrapTwice(n: in Int): Maybe[Maybe[Int]] {\n" +
    "  Just(Just(n))\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  var total = 0\n" +
    "  var i = 0\n" +
    "  while i < 500 {\n" +
    "    val m = Just(\"payload-\" + i.toString())\n" +
    "    total = total + describe(m)\n" +
    "    val nested = wrapTwice(i)\n" +
    "    match nested {\n" +
    "      case Just(inner) -> {\n" +
    "        match inner {\n" +
    "          case Just(v) -> {\n" +
    "            if v == 7 {\n" +
    "              total = total + 1000\n" +
    "            }\n" +
    "          }\n" +
    "          case Nada -> {\n" +
    "          }\n" +
    "        }\n" +
    "      }\n" +
    "      case Nada -> {\n" +
    "      }\n" +
    "    }\n" +
    "    val empty: Maybe[String] = Nada\n" +
    "    total = total + describe(empty)\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  if total > 1000 {\n" +
    "    0\n" +
    "  } else {\n" +
    "    1\n" +
    "  }\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 0, "generic ARC leak-free (ASan)")
}

test "nullary generic case via annotated binding and returns" {
  val src = "package T\n" + "union Maybe[T] {\n" + "  case Just(v: T)\n" + "  case Nada\n" + "}\n" +
    "func none(): Maybe[String] {\n" +
    "  Nada\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val a = none()\n" +
    "  match a {\n" +
    "    case Just(s) -> s.length\n" +
    "    case Nada -> 5\n" +
    "  }\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 5, "nullary via return type")
}

test "generic functions instantiate per call site with ufcs" {
  val src = "package T\n" + "union Maybe[T] {\n" + "  case Just(v: T)\n" + "  case Nada\n" + "}\n" +
    "func unwrapOr[T](m: in Maybe[T], dflt: in T): T {\n" +
    "  match m {\n" +
    "    case Just(v) -> v\n" +
    "    case Nada -> dflt\n" +
    "  }\n" +
    "}\n" +
    "func identity[T](x: in T): T {\n" +
    "  x\n" +
    "}\n" +
    "func wrap[T](x: in T): Maybe[T] {\n" +
    "  Just(x)\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val a = wrap(40)\n" +
    "  val s = wrap(\"hello\")\n" +
    "  val n: Maybe[Int] = Nada\n" +
    "  a.unwrapOr(0) + unwrapOr(n, 2) + unwrapOr(s, \"x\").length - identity(5)\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 42, "generic functions")
}

test "arc: closures capture by value and release captures" {
  val src = "package T\n" + "func apply(f: in (Int) -> Int, x: in Int): Int {\n" + "  f(x)\n" + "}\n" +
    "func compose(f: in (Int) -> Int, g: in (Int) -> Int): Int {\n" +
    "  f(g(3))\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val base = 10\n" +
    "  val label = \"adder\"\n" +
    "  val addBase: (Int) -> Int = { n -> n + base + label.length }\n" +
    "  val double: (Int) -> Int = { n -> n * 2 }\n" +
    "  var total = 0\n" +
    "  var i = 0\n" +
    "  while i < 100 {\n" +
    "    total = total + apply(addBase, i) - i - base - 5\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  total + apply(double, 10) + compose(double, addBase)\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 56, "closures (ASan)")
}

test "arc: NativeWeak upgrade returns Some while alive and None after release" {
  // makeDeadWeak's `gone` is a function-local strong ref that is not
  // returned (only the weak handle is), so it is released at the
  // callee's scope exit (Rule 4/6, native/plan/04-arc-design.md);
  // upgrade() on the returned handle must therefore observe refcount 0.
  val src = "package T\n" + "union Option[T] {\n" + "  case Some(value: T)\n" + "  case None\n" + "}\n" +
    "record Node {\n" +
    "  name: String\n" +
    "}\n" +
    "func check(w: in NativeWeak[Node]): Int {\n" +
    "  match w.upgrade() {\n" +
    "    case Some(n) -> n.name.length\n" +
    "    case None -> 0\n" +
    "  }\n" +
    "}\n" +
    "func makeDeadWeak(): NativeWeak[Node] {\n" +
    "  val gone = Node(name = \"gone\")\n" +
    "  NativeWeak(gone)\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val strong = Node(name = \"alive\")\n" +
    "  val w = NativeWeak(strong)\n" +
    "  val before = check(w)\n" +
    "  var score = 0\n" +
    "  if before == 5 {\n" +
    "    score = score + 10\n" +
    "  }\n" +
    "  var i = 0\n" +
    "  while i < 200 {\n" +
    "    val tmp = Node(name = \"temp-\" + i.toString())\n" +
    "    val wt = NativeWeak(tmp)\n" +
    "    val hit = check(wt)\n" +
    "    if hit > 0 {\n" +
    "      score = score + 0\n" +
    "    }\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  val deadWeak = makeDeadWeak()\n" +
    "  val afterRelease = check(deadWeak)\n" +
    "  if afterRelease == 0 {\n" +
    "    score = score + 5\n" +
    "  }\n" +
    "  score + check(w)\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 20, "weak upgrade Some-then-None (ASan)")
}

test "arc: tuples construct, destructure, and release elements" {
  val src = "package T\n" + "func minMax(a: in Int, b: in Int): (Int, Int) {\n" + "  if a < b {\n" + "    (a, b)\n" +
    "  } else {\n" +
    "    (b, a)\n" +
    "  }\n" +
    "}\n" +
    "func labeled(n: in Int): (String, Int) {\n" +
    "  (\"item-\" + n.toString(), n * 2)\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val (lo, hi) = minMax(9, 4)\n" +
    "  val pair: (String, Int) = labeled(5)\n" +
    "  val (name, doubled) = pair\n" +
    "  var acc = 0\n" +
    "  var i = 0\n" +
    "  while i < 300 {\n" +
    "    val (s, d) = labeled(i)\n" +
    "    acc = acc + s.length - s.length + d - i * 2\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  lo * 10 + hi + name.length + doubled + acc - 20\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 45, "tuples (ASan)")
}

test "nativeAddrOf passes a local's address to C out-params" {
  val src = "package T\n" + "extern func secureRandom(buf: NativePtr[Byte], n: Long): Int = \"lyric_secure_random\"\n" +
    "func main(): Int {\n" +
    "  var b: Byte = 0.toByte()\n" +
    "  val rc = secureRandom(nativeAddrOf(b), 1)\n" +
    "  if rc == 0 {\n" +
    "    0\n" +
    "  } else {\n" +
    "    1\n" +
    "  }\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 0, "nativeAddrOf (ASan)")
}
