//! llvm_fixed_array_self_test.l -- end-to-end self-test for `array[N, T]` on
//! `--target native` (D167, docs/67 §4.3, G1 #7940).
//!
//! An array of by-value elements (scalars, enums, by-value records, other such
//! arrays) lowers to the inline LLVM array `[N x T]`: no allocation, no ARC
//! header, no retain/release, and a by-value record may hold one.  An array of
//! any other element type is a reference-counted heap array (the `List`
//! representation), copied where it is stored.  Bounds checks are explicit code
//! the shared lowering emits (`Lyric.ContractElaborator.lowerArrays`), elided
//! behind the `__lyric_unchecked` marker where the index's range proves the
//! access; the backend checks only an access nothing has settled.
//!
//! The IR cases lower source directly (no shared lowering) and inspect the
//! emitted `.ll`; the runtime cases compile with `-fsanitize=address`
//! (LeakSanitizer is on by default on Linux), so a leaked slot or element, a
//! premature release, or a double release exits non-zero and `exit 0` is a real
//! ARC check.  The full-pipeline cases go through `compileToNativeWithFlags`.
//!
//! Requires `clang` on PATH and a built runtime (`make -C lyric-rt`).
//! Run via native `lyric test` with LYRIC_LOAD_COMPILER=1:
//!   make -C lyric-rt && LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/llvm_fixed_array_self_test.l
@test_module
package Lyric.LlvmFixedArraySelfTest

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
  val dir = Path.join(tempBase(), "lyric-llvm-fixedarray-selftest")
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
  val dir = Path.join(tempBase(), "lyric-llvm-fixedarray-selftest")
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
  val dir = Path.join(tempBase(), "lyric-llvm-fixedarray-selftest")
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
  val dir = Path.join(tempBase(), "lyric-llvm-fixedarray-selftest")
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
// IR shape: an inline array, no allocation, no ARC.
// ─────────────────────────────────────────────────────────────────────────────
test "an array of Floats is the inline LLVM array [N x float] and never allocates" {
  val src = "package T\n" + "func main(): Int {\n" + "  var a: array[4, Float] = [1.0f32, 2.0f32, 3.0f32, 4.0f32]\n" +
    "  a[__lyric_unchecked(2)] = 10.0f32\n" +
    "  a[__lyric_unchecked(1)] += 5.0f32\n" +
    "  (a[__lyric_unchecked(0)] + a[__lyric_unchecked(1)] + a[__lyric_unchecked(2)] + a[__lyric_unchecked(3)]).toInt()\n" +
    "}\n"
  val ll = lowerToLl(src)
  val body = functionBody(ll, "T.main")
  assertTrue(Str.contains(body, "[4 x float]"), "the array is [4 x float]")
  assertTrue(Str.contains(body, "insertvalue [4 x float]"), "the literal is an insertvalue chain")
  assertTrue(Str.contains(body, "getelementptr inbounds [4 x float]"), "an element is addressed with a GEP")
  assertTrue(not Str.contains(body, "lyric_alloc"), "main allocates nothing")
  assertTrue(not Str.contains(body, "lyric_retain"), "main retains nothing")
  assertTrue(not Str.contains(body, "lyric_release"), "main releases nothing")
  assertTrue(not Str.contains(body, "lyric_panic_msg"), "a settled access has no bounds check")
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 22, "1 + (2 + 5) + 10 + 4")
}

test "an access nothing has settled is bounds checked by the backend" {
  val checked = "package T\n" + "func get(a: in array[3, Int], i: in Int): Int {\n  a[i]\n}\n" +
    "func main(): Int {\n  get([5, 6, 7], 2)\n}\n"
  val ll = lowerToLl(checked)
  assertTrue(Str.contains(functionBody(ll, "T.get"), "lyric_panic_msg"), "get carries the bounds check")
  val r = compileAndRunAsan(checked)
  assertEqualInt(r.exitCode, 7, "in range")
  val bad = "package T\n" + "func get(a: in array[3, Int], i: in Int): Int {\n  a[i]\n}\n" +
    "func main(): Int {\n  get([5, 6, 7], 3)\n}\n"
  val rb = compileAndRunWith(bad, false)
  assertTrue(rb.exitCode != 0, "an index past the end aborts")
  assertTrue(
    Str.contains(rb.stderr, "index 3 out of range for array[3]"),
    "the backend's own check gives the shared message (" + rb.stderr + ")"
  )
}

test "the whole pipeline: a compound assignment through an impure index writes the array itself" {
  val src = "package T\n" + "record Tally {\n  var hits: array[4, Int]\n}\n" +
    "func nextIdx(n: inout Int): Int {\n  n = n + 1\n  1\n}\n" +
    "func main(): Int {\n" +
    "  var a: array[4, Int] = [1, 2, 3, 4]\n" +
    "  val i = 1\n" +
    "  a[i + 1] += 10\n" +
    "  var n = 0\n" +
    "  a[nextIdx(n)] += 5\n" +
    "  val t = Tally()\n" +
    "  val k = 1\n" +
    "  t.hits[k * 2] += 1\n" +
    "  var g: array[2, array[3, Int]]\n" +
    "  g[i][i + 1] += 4\n" +
    "  a[2] + a[1] + n + t.hits[2] + g[1][2]\n" +
    "}\n"
  val r = compileFullAndRunAsan(src)
  assertEqualInt(r.exitCode, 13 + 7 + 1 + 1 + 4, "a[2], a[1], one call, a field element, a nested element")
}

test "a by-value record can hold an array and stays by-value" {
  val src = "package T\n" + "record Mesh {\n  cells: array[3, Float]\n  n: Int\n}\n" + "func total(m: in Mesh): Int {\n" +
    "  (m.cells[__lyric_unchecked(0)] + m.cells[__lyric_unchecked(1)] + m.cells[__lyric_unchecked(2)]).toInt() + m.n\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val m = Mesh(cells = [1.0f32, 2.0f32, 3.0f32], n = 4)\n" +
    "  val c = m\n" +
    "  total(c)\n" +
    "}\n"
  val ll = lowerToLl(src)
  assertTrue(Str.contains(ll, "%T.Mesh = type { [3 x float], i32 }"), "the array is a field of the struct")
  assertTrue(not Str.contains(functionBody(ll, "T.total"), "lyric_alloc"), "total allocates nothing")
  assertTrue(not Str.contains(functionBody(ll, "T.main"), "lyric_alloc"), "main allocates nothing")
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 10, "6 + 4")
}

test "an array of by-value records is inline" {
  val src = "package T\n" + "record Vec3 {\n  x: Float\n  y: Float\n  z: Float\n}\n" + "func main(): Int {\n" +
    "  var vs: array[2, Vec3] = [Vec3(x = 1.0f32, y = 2.0f32, z = 3.0f32), Vec3(x = 4.0f32, y = 5.0f32, z = 6.0f32)]\n" +
    "  vs[__lyric_unchecked(1)] = Vec3(x = 7.0f32, y = 8.0f32, z = 9.0f32)\n" +
    "  (vs[__lyric_unchecked(0)].y + vs[__lyric_unchecked(1)].z).toInt()\n" +
    "}\n"
  val ll = lowerToLl(src)
  assertTrue(Str.contains(functionBody(ll, "T.main"), "[2 x %T.Vec3]"), "the array of structs is inline")
  assertTrue(not Str.contains(functionBody(ll, "T.main"), "lyric_alloc"), "main allocates nothing")
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 11, "2 + 9")
}

test "an array var field of a heap record is written in place" {
  val src = "package T\n" + "record Counter {\n  var hits: array[3, Int]\n  var name: Int\n}\n" + "func main(): Int {\n" +
    "  val c = Counter(hits = [0, 0, 0], name = 1)\n" +
    "  c.hits[__lyric_unchecked(1)] = 5\n" +
    "  c.hits[__lyric_unchecked(1)] += 2\n" +
    "  c.hits[__lyric_unchecked(2)] = 9\n" +
    "  c.hits[__lyric_unchecked(1)] + c.hits[__lyric_unchecked(2)] + c.hits[__lyric_unchecked(0)]\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 16, "7 + 9 + 0")
}

test "an array of arrays is inline and nested element writes address in place" {
  val src = "package T\n" + "func main(): Int {\n" + "  var g: array[2, array[3, Int]] = [[1, 2, 3], [4, 5, 6]]\n" +
    "  g[__lyric_unchecked(1)][__lyric_unchecked(0)] = 40\n" +
    "  g[__lyric_unchecked(0)][__lyric_unchecked(2)] += 7\n" +
    "  g[__lyric_unchecked(1)][__lyric_unchecked(0)] + g[__lyric_unchecked(0)][__lyric_unchecked(2)]\n" +
    "}\n"
  val ll = lowerToLl(src)
  assertTrue(Str.contains(functionBody(ll, "T.main"), "[2 x [3 x i32]]"), "an inline array of inline arrays")
  assertTrue(not Str.contains(functionBody(ll, "T.main"), "lyric_alloc"), "main allocates nothing")
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 50, "40 + 10")
}

// ─────────────────────────────────────────────────────────────────────────────
// Heap arrays: any element type that is not by-value.
// ─────────────────────────────────────────────────────────────────────────────
test "an array of Strings is a heap array, copied on store, and ASan finds no leak" {
  val src = "package T\n" + "func main(): Int {\n" + "  var a: array[2, String] = [\"ab\", \"cde\"]\n" + "  var b = a\n" +
    "  b[0] = \"xyz\"\n" +
    "  val c = b\n" +
    "  a[1] = \"q\"\n" +
    "  a[0].length + a[1].length + b[0].length + b[1].length + c[0].length\n" +
    "}\n"
  val r = compileFullAndRunAsan(src)
  assertEqualInt(r.exitCode, 12, "2 + 1 + 3 + 3 + 3: the copies are independent")
}

test "a zero-filled array of mutable records holds distinct instances" {
  val src = "package T\n" + "record Cell {\n  var n: Int\n}\n" + "func main(): Int {\n" + "  var cs: array[3, Cell]\n" +
    "  cs[0].n = 5\n" +
    "  cs[1].n = cs[1].n + 1\n" +
    "  cs[0].n * 10 + cs[1].n + cs[2].n\n" +
    "}\n"
  val r = compileFullAndRunAsan(src)
  assertEqualInt(r.exitCode, 51, "5 * 10 + 1 + 0: no two elements are the same object")
}

test "an array of arrays of Strings is copied deeply" {
  val src = "package T\n" + "func main(): Int {\n" +
    "  var g: array[2, array[2, String]] = [[\"a\", \"bb\"], [\"ccc\", \"dddd\"]]\n" +
    "  var h = g\n" +
    "  h[1][0] = \"z\"\n" +
    "  g[1][0].length * 10 + h[1][0].length + g[0][1].length\n" +
    "}\n"
  val r = compileFullAndRunAsan(src)
  assertEqualInt(r.exitCode, 33, "3 * 10 + 1 + 2: the inner arrays are not shared")
}

// ─────────────────────────────────────────────────────────────────────────────
// Whole pipeline: copies, zero fill and equality on inline arrays.
// ─────────────────────────────────────────────────────────────────────────────
test "the whole pipeline: copy on store, zero fill, length, for and equality on an inline array" {
  val src = "package T\n" + "func sum(a: in array[4, Int]): Int {\n" +
    "  var t = 0\n  for x in a {\n    t = t + x\n  }\n  t\n}\n" +
    "func main(): Int {\n" +
    "  var a: array[4, Int]\n" +
    "  a[1] = 5\n" +
    "  var b = a\n" +
    "  b[2] = 7\n" +
    "  var r = sum(a) + sum(b) * 10\n" +
    "  if a != b { r = r + 100 }\n" +
    "  r + a.length\n" +
    "}\n"
  val r = compileFullAndRunAsan(src)
  assertEqualInt(r.exitCode, (5 + 12 * 10 + 100 + 4) % 256, "a = [0,5,0,0], b = [0,5,7,0]")
}

test "the whole pipeline: a range-subtype index emits no bounds check, an Int index does" {
  val src = "package T\n" + "type Slot = Int range 0 ..= 3\n" +
    "func proven(a: in array[4, Int], s: in Slot): Int {\n  a[s]\n}\n" +
    "func checked(a: in array[4, Int], i: in Int): Int {\n  a[i]\n}\n" +
    "func literal(a: in array[4, Int]): Int {\n  a[3]\n}\n" +
    "func main(): Int {\n  proven([5, 6, 7, 8], Slot.from(2)) + checked([5, 6, 7, 8], 1) + literal([5, 6, 7, 8])\n}\n"
  val ll = fullPipelineLl(src)
  val provenBody = functionBody(ll, "T.proven")
  assertTrue(not Str.contains(provenBody, "lyric_panic_msg"), "a range-subtype index has no panic path")
  assertTrue(not Str.contains(provenBody, "br i1"), "and no branch")
  assertTrue(Str.contains(provenBody, "getelementptr inbounds [4 x i32]"), "it is a plain element access")
  assertTrue(
    not Str.contains(functionBody(ll, "T.literal"), "lyric_panic_msg"),
    "a literal index in range has no panic path"
  )
  assertTrue(Str.contains(functionBody(ll, "T.checked"), "lyric_panic_msg"), "an Int index is checked")
  val r = compileFullAndRunAsan(src)
  assertEqualInt(r.exitCode, 7 + 6 + 8, "the elements at the proven, checked and literal indices")
}

test "an extern func passing an inline array is rejected with N0010" {
  val src = "package T\n" + "extern func takes(a: array[4, Float]): Int = \"takes_arr\"\n" +
    "extern func fine(n: Int): Int = \"fine_fn\"\n" +
    "func main(): Int {\n  0\n}\n"
  val units: List[CodegenUnit] = newList()
  units.add(unitOfFile("T", parseOrPanic(src)))
  val diags = nativeByValueExternDiagnostics(units)
  assertEqualInt(diags.count, 1, "only the array signature is reported")
  assertEqual(diags[0].code, "N0010", "the diagnostic code")
  assertTrue(Str.contains(diags[0].message, "inline `array[N, T]`"), "the message names the array")
}
