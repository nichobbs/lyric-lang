//! llvm_buffer_self_test.l -- end-to-end self-test for `buffer[T]` on
//! `--target native` (D185, docs/67 §4.4, G2 #7941).
//!
//! A buffer is a reference-counted block `{ header, len, elem_size, [0 x T] }`
//! whose `Plain` elements are packed by value after the header: no per-element
//! allocation, boxing or ownership.  Copy on write: a store shares the block
//! (the binding retains it) and a write to a place whose block has other
//! references first takes a private copy (`lyric_buffer_unique`), so a write
//! through an unshared buffer never allocates.
//!
//! The runtime cases compile the whole pipeline with `-fsanitize=address`
//! (LeakSanitizer is on by default on Linux), so a leaked block, a premature
//! release or a double release exits non-zero and `exit 0` is a real ARC check.
//! The semantic cases of `buffer_self_test.l` also run on this target:
//!   lyric test --target native lyric-compiler/lyric/buffer_self_test.l
//!
//! Requires `clang` on PATH and a built runtime (`make -C lyric-rt`).
//! Run via native `lyric test` with LYRIC_LOAD_COMPILER=1:
//!   make -C lyric-rt && LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/llvm_buffer_self_test.l
@test_module
package Lyric.LlvmBufferSelfTest

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
  stderr: String
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
  val dir = Path.join(tempBase(), "lyric-llvm-buffer-selftest")
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
    case Ok(res) -> RunOutcome(exitCode = res.exitCode, stdout = res.stdout, stderr = res.stderr)
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
  val dir = Path.join(tempBase(), "lyric-llvm-buffer-selftest")
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
    case Ok(res) -> RunOutcome(exitCode = res.exitCode, stdout = res.stdout, stderr = res.stderr)
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

/// Builds `source` through the whole pipeline (type check, `lowerArrays`, ...)
/// with AddressSanitizer and runs it.
func compileFullAndRunAsan(source: in String): RunOutcome {
  val stdlib = findStdlibSourcesNative()
  val dir = Path.join(tempBase(), "lyric-llvm-buffer-selftest")
  val _ = File.createDir(dir)
  val stem = Path.join(dir, "f_" + Uuid.uuidToString(Uuid.newUuid()))
  val flags: List[String] = newList()
  flags.add("-fsanitize=address")
  val built = compileToNativeWithFlags(source, stem, stdlib, "", "0", flags, newList(), "", true)
  if not built {
    panic("the whole-pipeline build failed for:\n" + source)
  }
  val noArgs: List[String] = newList()
  match Process.runCapture(stem, noArgs, 60000) {
    case Ok(res) -> RunOutcome(exitCode = res.exitCode, stdout = res.stdout, stderr = res.stderr)
    case Err(e) -> panic("binary could not be started: " + e)
  }
}

/// The `.ll` the whole pipeline lowers `source` to.  The bridge deletes it
/// after a successful clang run and keeps it after a failed one, so the build
/// is given a clang argument that cannot succeed.
func fullPipelineLl(source: in String): String {
  val stdlib = findStdlibSourcesNative()
  val dir = Path.join(tempBase(), "lyric-llvm-buffer-selftest")
  val _ = File.createDir(dir)
  val stem = Path.join(dir, "ir_" + Uuid.uuidToString(Uuid.newUuid()))
  val flags: List[String] = newList()
  flags.add("/lyric-nonexistent-ir-capture.c")
  val built = compileToNativeWithFlags(source, stem, stdlib, "", "0", flags, newList(), "", true)
  assertTrue(not built, "the capture build is meant to fail after writing the IR")
  match File.readText(stem + ".ll") {
    case Ok(text) -> text
    case Err(_) -> panic("the IR was not kept at " + stem + ".ll")
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Whole-pipeline programs (every one returns 0 on success).
// ─────────────────────────────────────────────────────────────────────────────
func prog(body: in String): String {
  "package T\nimport Std.Core\nimport Std.Collections\nimport Std.Buffer\nimport Std.Bench\n" + body
}

func runClean(body: in String, label: in String): Unit {
  val r = compileFullAndRunAsan(prog(body))
  assertEqualInt(r.exitCode, 0, label + " (stderr: " + r.stderr + ")")
}

test "elements are packed by value: no per-element allocation, no list kernel" {
  val src = prog(
    "func main(): Int {\n" + "  var b = filled(8, 1.5f32)\n" + "  b[3] = 2.5f32\n" +
      "  if b[3] == 2.5f32 and b[0] == 1.5f32 { 0 } else { 1 }\n" +
      "}\n"
  )
  val ll = fullPipelineLl(src)
  assertTrue(Str.contains(ll, "lyric_buffer_new"), "the buffer is allocated by the buffer kernel")
  assertTrue(Str.contains(ll, "[0 x float]"), "its elements are a trailing packed float array")
  val r = compileFullAndRunAsan(src)
  assertEqualInt(r.exitCode, 0, "runs clean (stderr: " + r.stderr + ")")
}

test "a write to an unshared buffer never allocates" {
  runClean(
    "func main(): Int {\n" + "  var b = filled(1000, 0)\n" + "  val before = allocatedBytes()\n" + "  var i = 0\n" +
      "  while i < 1000 {\n" +
      "    b[i] = i\n" +
      "    i = i + 1\n" +
      "  }\n" +
      "  val after = allocatedBytes()\n" +
      "  if after == before and b[999] == 999 { 0 } else { 1 }\n" +
      "}\n",
    "1000 in-place writes"
  )
}

test "a write to a shared buffer copies it once and leaves the other binding alone" {
  runClean(
    "func main(): Int {\n" + "  var a = filled(100, 7)\n" + "  var b = a\n" + "  val before = allocatedBytes()\n" +
      "  b[0] = 1\n" +
      "  val mid = allocatedBytes()\n" +
      "  b[1] = 2\n" +
      "  b[2] = 3\n" +
      "  val after = allocatedBytes()\n" +
      "  if mid == before { return 10 }\n" +
      "  if after != mid { return 11 }\n" +
      "  if a[0] != 7 or a[1] != 7 { return 12 }\n" +
      "  if b[0] != 1 or b[1] != 2 or b[2] != 3 or b[3] != 7 { return 13 }\n" +
      "  0\n" +
      "}\n",
    "copy on first write only"
  )
}

test "the last reference writes in place again after a copy was released" {
  runClean(
    "func main(): Int {\n" + "  var a = filled(50, 1)\n" + "  var snap = a\n" + "  a[0] = 2\n" +
      "  snap = filled(1, 0)\n" +
      "  val before = allocatedBytes()\n" +
      "  a[1] = 3\n" +
      "  if allocatedBytes() != before { return 1 }\n" +
      "  if a[0] != 2 or a[1] != 3 { return 2 }\n" +
      "  0\n" +
      "}\n",
    "a sole owner again"
  )
}

test "passing, returning, record fields and inout keep reference counts balanced" {
  runClean(
    "record Mesh {\n  var verts: buffer[Int]\n  var tag: Int\n}\n" +
      "func sum(b: in buffer[Int]): Int {\n  var t = 0\n  for x in b {\n    t = t + x\n  }\n  t\n}\n" +
      "func bump(b: inout buffer[Int], i: in Int) {\n  b[i] = b[i] + 10\n}\n" +
      "func makeIt(n: in Int): buffer[Int] {\n  var b = filled(n, 2)\n  b[0] = 5\n  b\n}\n" +
      "func keep(b: in buffer[Int]): buffer[Int] {\n  var c = b\n  c[0] = 99\n  c\n}\n" +
      "func main(): Int {\n" +
      "  var m = makeIt(4)\n" +
      "  val k = keep(m)\n" +
      "  if m[0] != 5 or k[0] != 99 { return 1 }\n" +
      "  bump(m, 1)\n" +
      "  if m[1] != 12 or k[1] != 2 { return 2 }\n" +
      "  if sum(m) != 5 + 12 + 2 + 2 { return 3 }\n" +
      "  var mesh = Mesh(verts = m, tag = 1)\n" +
      "  m[2] = 40\n" +
      "  if mesh.verts[2] != 2 or m[2] != 40 { return 4 }\n" +
      "  mesh.verts[3] = 60\n" +
      "  if mesh.verts[3] != 60 or m[3] != 2 { return 5 }\n" +
      "  var other = Mesh(verts = mesh.verts, tag = 2)\n" +
      "  other.verts[0] = -1\n" +
      "  if mesh.verts[0] != 5 or other.verts[0] != -1 { return 6 }\n" +
      "  0\n" +
      "}\n",
    "reference counts"
  )
}

test "a for loop iterates the buffer it started with while the body writes" {
  runClean(
    "func main(): Int {\n" + "  var b = filled(4, 3)\n" + "  var t = 0\n" +
      "  for x in b {\n    b[0] = 100\n    t = t + x\n  }\n" +
      "  if t != 12 or b[0] != 100 { 1 } else { 0 }\n" +
      "}\n",
    "snapshot iteration"
  )
}

test "a buffer of by-value records, and view, grow, truncate, fromSlice" {
  runClean(
    "record Vec3 {\n  x: Float\n  y: Float\n  z: Float\n}\n" + "func main(): Int {\n" +
      "  var vs = filled(3, Vec3(x = 0.0f32, y = 0.0f32, z = 0.0f32))\n" +
      "  vs[1] = vs[1].copy(y = 4.0f32)\n" +
      "  if vs[1].y != 4.0f32 or vs[0].y != 0.0f32 { return 1 }\n" +
      "  val g = grow(vs, 5, Vec3(x = 1.0f32, y = 1.0f32, z = 1.0f32))\n" +
      "  if g.length != 5 or g[1].y != 4.0f32 or g[4].x != 1.0f32 { return 2 }\n" +
      "  val t = truncate(g, 2)\n" +
      "  if t.length != 2 or t[1].y != 4.0f32 { return 3 }\n" +
      "  val s: slice[Int] = [4, 5, 6]\n" +
      "  var b = fromSlice(s)\n" +
      "  b[0] = 0\n" +
      "  val v = view(b, 1, 3)\n" +
      "  b[1] = 500\n" +
      "  if v.length != 2 or v[0] != 5 or s[0] != 4 { return 4 }\n" +
      "  0\n" +
      "}\n",
    "records and the Std.Buffer functions"
  )
}

test "an out-of-range index aborts with the buffer's message" {
  val bad = prog(
    "func get(b: in buffer[Int], i: in Int): Int {\n  b[i]\n}\n" +
      "func main(): Int {\n  get(filled(3, 1), 3)\n}\n"
  )
  val r = compileFullAndRunAsan(bad)
  assertTrue(r.exitCode != 0, "an index past the end aborts")
  assertTrue(
    Str.contains(r.stderr, "index 3 out of range for buffer of length 3"),
    "the shared bounds check message (" + r.stderr + ")"
  )
}
