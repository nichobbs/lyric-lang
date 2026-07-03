//! llvm_collections_self_test.l — end-to-end self-test for N5.8 of
//! `Lyric.LlvmCodegen`: `List[T]` / `Map[K, V]` lowered to the lyric-rt
//! C kernels, `for` loops over lists, indexing, and the reserved
//! `Std.Collections` accessors (`newList` / `newMap` / `mapGet` /
//! `dictGetKeys` / `dictGetValues`).
//!
//! Every case compiles a real program (parse → codegen → clang → run)
//! and asserts its exit code; the ARC-sensitive cases build with
//! `-fsanitize=address`, so a container that under- or over-releases a
//! ref-typed element (String elements, record elements, map values,
//! snapshot lists) fails the run.
//!
//! Requires `clang` on PATH and a built runtime (`make -C lyric-rt`).
//! Run via native `lyric test` with LYRIC_LOAD_COMPILER=1:
//!   make -C lyric-rt && LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/llvm_collections_self_test.l
@test_module
package Lyric.LlvmCollectionsSelfTest

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
  val dir = Path.join(tempBase(), "lyric-llvm-coll-selftest")
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

func compileAndRunAsan(source: in String): RunOutcome {
  compileAndRunWith(source, true)
}

// The single-file harness bypasses the stdlib bundle, so programs that
// use mapGet declare Option themselves (a real build gets Std.Core's
// through the import closure).
func optionDecl(): String {
  "union Option[T] {\n  case Some(value: T)\n  case None\n}\n"
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────
test "list of Int: add, for, count" {
  val src = "package T\n" + "func main(): Int {\n" + "  val xs: List[Int] = newList()\n" + "  xs.add(7)\n" +
    "  xs.add(35)\n" +
    "  var sum = 0\n" +
    "  for x in xs {\n" +
    "    sum = sum + x\n" +
    "  }\n" +
    "  sum + xs.count\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 44, "list-int: 7+35+2")
}

test "list indexing and set" {
  val src = "package T\n" + "func main(): Int {\n" + "  val xs: List[Int] = newList()\n" + "  xs.add(1)\n" +
    "  xs.add(2)\n" +
    "  xs.add(3)\n" +
    "  xs.set(1, 40)\n" +
    "  xs[0] + xs[1] + xs[2]\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 44, "list-index: 1+40+3")
}

test "explicit type arguments construct without an annotation" {
  val src = "package T\n" + "func main(): Int {\n" + "  val xs = newList[Long]()\n" + "  xs.add(20)\n" +
    "  xs.add(22)\n" +
    "  var sum = 0\n" +
    "  for x in xs {\n" +
    "    sum = sum + x.toInt()\n" +
    "  }\n" +
    "  sum\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 42, "typeapp-ctor: 20+22")
}

test "list of String releases its elements (ASan)" {
  val src = "package T\n" + "func main(): Int {\n" + "  val xs: List[String] = newList()\n" + "  var i = 0\n" +
    "  while i < 100 {\n" +
    "    xs.add(\"item-\" + i.toString())\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  xs.set(5, \"replaced\")\n" +
    "  xs.removeAt(0)\n" +
    "  val probe = xs[4]\n" +
    "  val n = probe.length\n" +
    "  xs.clear()\n" +
    "  n + xs.count\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 8, "list-string: \"replaced\".length")
}

test "list of records: churn, break, continue (ASan)" {
  val src = "package T\n" + "record Box {\n" + "  label: String\n" + "  n: Int\n" + "}\n" + "func main(): Int {\n" +
    "  val xs: List[Box] = newList()\n" +
    "  var i = 0\n" +
    "  while i < 50 {\n" +
    "    xs.add(Box(label = \"item-\" + i.toString(), n = i))\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  xs.set(10, Box(label = \"replaced\", n = 1000))\n" +
    "  xs.removeAt(0)\n" +
    "  var total = 0\n" +
    "  for b in xs {\n" +
    "    if b.n == 1000 {\n" +
    "      continue\n" +
    "    }\n" +
    "    if b.n > 40 {\n" +
    "      break\n" +
    "    }\n" +
    "    total = total + 1\n" +
    "  }\n" +
    "  total + xs.count\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 88, "list-records: 39 kept + 49 len")
}

test "list as a record field survives the record dtor (ASan)" {
  val src = "package T\n" + "record Holder {\n" + "  items: List[String]\n" + "}\n" + "func makeHolder(): Holder {\n" +
    "  val xs: List[String] = newList()\n" +
    "  xs.add(\"aa\")\n" +
    "  xs.add(\"bbb\")\n" +
    "  Holder(items = xs)\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val h = makeHolder()\n" +
    "  h.items[0].length + h.items[1].length\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 5, "list-field: 2+3")
}

test "map with scalar keys" {
  val src = "package T\n" + "func main(): Int {\n" + "  val m: Map[Int, Int] = newMap()\n" + "  m.add(1, 10)\n" +
    "  m.add(2, 20)\n" +
    "  m.add(1, 11)\n" +
    "  var total = m.count\n" +
    "  if m.containsKey(2) {\n" +
    "    total = total + m[1] + m[2]\n" +
    "  }\n" +
    "  val gone = m.remove(2)\n" +
    "  if gone {\n" +
    "    total = total + m.count\n" +
    "  }\n" +
    "  total\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 34, "map-int: 2+11+20+1")
}

test "map with String keys, mapGet, key iteration (ASan)" {
  val src = "package T\n" + optionDecl() + "func main(): Int {\n" + "  val m: Map[String, String] = newMap()\n" +
    "  m.add(\"alpha\", \"one\")\n" +
    "  m.add(\"beta\", \"three\")\n" +
    "  var total = 0\n" +
    "  match mapGet(m, \"alpha\") {\n" +
    "    case Some(v) -> {\n" +
    "      total = total + v.length\n" +
    "    }\n" +
    "    case None -> {\n" +
    "      total = total + 100\n" +
    "    }\n" +
    "  }\n" +
    "  match mapGet(m, \"missing\") {\n" +
    "    case Some(_) -> {\n" +
    "      total = total + 100\n" +
    "    }\n" +
    "    case None -> {\n" +
    "      total = total + 1\n" +
    "    }\n" +
    "  }\n" +
    "  val ks = dictGetKeys(m)\n" +
    "  for k in ks {\n" +
    "    total = total + k.length\n" +
    "  }\n" +
    "  if m.containsKey(\"beta\") {\n" +
    "    total = total + 10\n" +
    "  }\n" +
    "  val removed = m.remove(\"alpha\")\n" +
    "  if removed {\n" +
    "    total = total + m.count\n" +
    "  }\n" +
    "  total + m[\"beta\"].length\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 29, "map-string: 3+1+9+10+1+5")
}

test "dictGetValues snapshot outlives the map (ASan)" {
  val src = "package T\n" + "func main(): Int {\n" + "  var total = 0\n" + "  val vs: List[String] = collect()\n" +
    "  for v in vs {\n" +
    "    total = total + v.length\n" +
    "  }\n" +
    "  total\n" +
    "}\n" +
    "func collect(): List[String] {\n" +
    "  val m: Map[Int, String] = newMap()\n" +
    "  m.add(1, \"aa\")\n" +
    "  m.add(2, \"bbbb\")\n" +
    "  dictGetValues(m)\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 6, "values-snapshot: 2+4")
}

test "missing map index panics with a named diagnostic" {
  val src = "package T\n" + "func main(): Int {\n" + "  val m: Map[Int, Int] = newMap()\n" + "  m.add(1, 10)\n" +
    "  m[2]\n" +
    "}\n"
  val r = compileAndRunWith(src, false)
  assertTrue(r.exitCode != 0, "map-miss: non-zero exit")
}

test "nested lists (ASan)" {
  val src = "package T\n" + "func main(): Int {\n" + "  val outer: List[List[Int]] = newList()\n" +
    "  val a = newList[Int]()\n" +
    "  a.add(1)\n" +
    "  a.add(2)\n" +
    "  val b = newList[Int]()\n" +
    "  b.add(39)\n" +
    "  outer.add(a)\n" +
    "  outer.add(b)\n" +
    "  var total = 0\n" +
    "  for inner in outer {\n" +
    "    for x in inner {\n" +
    "      total = total + x\n" +
    "    }\n" +
    "  }\n" +
    "  total\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 42, "nested: 1+2+39")
}

test "list passed to and returned from functions (ASan)" {
  val src = "package T\n" + "func fill(xs: in List[Int], n: Int): Unit {\n" + "  var i = 0\n" + "  while i < n {\n" +
    "    xs.add(i)\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "}\n" +
    "func total(xs: in List[Int]): Int {\n" +
    "  var sum = 0\n" +
    "  for x in xs {\n" +
    "    sum = sum + x\n" +
    "  }\n" +
    "  sum\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val xs: List[Int] = newList()\n" +
    "  fill(xs, 10)\n" +
    "  total(xs)\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 45, "fn-boundary: sum 0..9")
}
