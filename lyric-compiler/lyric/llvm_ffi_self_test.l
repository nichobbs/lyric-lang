//! llvm_ffi_self_test.l — end-to-end self-test for the N4 FFI surface of
//! `Lyric.LlvmCodegen`: `extern func` calls into libc/libm/lyric-rt,
//! String ↔ C-string bridging, `nativeAddrOf` / `nativeNullPtr`, and the
//! N4.5 callback trampolines (a Lyric closure passed to an extern func
//! parameter of function type, with the closure pointer riding the
//! callback's trailing `NativePtr[Byte]` userdata slot).
//!
//! The trampoline case runs a real second thread: pthread_create takes
//! the synthesised trampoline as its start routine and the closure as
//! `arg`; the closure (capturing a Lyric String by value) allocates a C
//! string on that thread and returns it through pthread_join's retval
//! out-parameter.  Compiled with `-fsanitize=address`, so a missed or
//! doubled release of the capture, or a leak of the returned buffer,
//! fails the run.
//!
//! Requires `clang` on PATH and a built runtime (`make -C lyric-rt`).
//! Run via native `lyric test` with LYRIC_LOAD_COMPILER=1:
//!   make -C lyric-rt && LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/llvm_ffi_self_test.l
@test_module
package Lyric.LlvmFfiSelfTest

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
  val dir = Path.join(tempBase(), "lyric-llvm-ffi-selftest")
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

func compileAndRunAsan(source: in String): RunOutcome {
  compileAndRunWith(source, true)
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────
test "extern write sends bytes to stdout" {
  val src = "package T\n" + "extern func cWrite(fd: Int, buf: NativePtr[Byte], n: Long): Long = \"write\"\n" +
    "extern func toC(s: String): NativePtr[Byte] = \"lyric_string_to_cstring\"\n" +
    "extern func freeC(p: NativePtr[Byte]): Unit = \"lyric_cstring_free\"\n" +
    "@unsafe_ffi\n" +
    "func main(): Int {\n" +
    "  val p = toC(\"ffi\\n\")\n" +
    "  val n = cWrite(1, p, 4)\n" +
    "  freeC(p)\n" +
    "  if n == 4 {\n" +
    "    0\n" +
    "  } else {\n" +
    "    1\n" +
    "  }\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 0, "write: exit")
  assertEqual(r.stdout, "ffi\n", "write: stdout")
}

test "libm sin and sqrt externs" {
  val src = "package T\n" + "extern func cSqrt(x: Double): Double = \"sqrt\"\n" +
    "extern func cSin(x: Double): Double = \"sin\"\n" +
    "func main(): Int {\n" +
    "  val v = cSqrt(81.0) + cSin(0.0)\n" +
    "  v.toInt()\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 9, "libm: sqrt(81)+sin(0)")
}

test "cstring bridge strlen round-trip" {
  val src = "package T\n" + "extern func cStrlen(s: NativePtr[Byte]): Long = \"strlen\"\n" +
    "extern func toC(s: String): NativePtr[Byte] = \"lyric_string_to_cstring\"\n" +
    "extern func freeC(p: NativePtr[Byte]): Unit = \"lyric_cstring_free\"\n" +
    "@unsafe_ffi\n" +
    "func main(): Int {\n" +
    "  val p = toC(\"hello\")\n" +
    "  val n = cStrlen(p)\n" +
    "  freeC(p)\n" +
    "  n.toInt()\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 5, "strlen: exit is the length")
}

test "nativeNullPtr is a NULL argument" {
  // free(NULL) is defined as a no-op; under ASan a bad pointer would
  // abort instead.
  val src = "package T\n" + "extern func cFree(p: NativePtr[Byte]): Unit = \"free\"\n" + "@unsafe_ffi\n" +
    "func main(): Int {\n" +
    "  cFree(nativeNullPtr())\n" +
    "  0\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 0, "nativeNullPtr: free(NULL) no-op")
}

test "closure trampoline runs on a pthread" {
  // The full N4.5 loop: pthread_create's start routine is the
  // synthesised trampoline; `worker` rides along as the userdata (the
  // closure pointer in the NativePtr[Byte] argument position); the
  // closure captures a Lyric String by value, allocates a C string from
  // it ON THE SECOND THREAD, and returns it; main collects it through
  // pthread_join's retval out-param, measures it, and frees it.
  val src = "package T\n" +
    "extern func pthreadCreate(tid: NativePtr[Long], attr: NativePtr[Byte], start: (NativePtr[Byte]) -> NativePtr[Byte], arg: NativePtr[Byte]): Int = \"pthread_create\"\n" +
    "extern func pthreadJoin(tid: Long, retval: NativePtr[NativePtr[Byte]]): Int = \"pthread_join\"\n" +
    "extern func cStrlen(s: NativePtr[Byte]): Long = \"strlen\"\n" +
    "extern func toC(s: String): NativePtr[Byte] = \"lyric_string_to_cstring\"\n" +
    "extern func freeC(p: NativePtr[Byte]): Unit = \"lyric_cstring_free\"\n" +
    "@unsafe_ffi\n" +
    "func main(): Int {\n" +
    "  val msg = \"hello-from-thread\"\n" +
    "  val worker: () -> NativePtr[Byte] = { -> toC(msg) }\n" +
    "  var tid: Long = 0\n" +
    "  val rc = pthreadCreate(nativeAddrOf(tid), nativeNullPtr(), worker, worker)\n" +
    "  if rc != 0 {\n" +
    "    return 1\n" +
    "  }\n" +
    "  var outp: NativePtr[Byte] = nativeNullPtr()\n" +
    "  val rj = pthreadJoin(tid, nativeAddrOf(outp))\n" +
    "  if rj != 0 {\n" +
    "    return 2\n" +
    "  }\n" +
    "  val n = cStrlen(outp)\n" +
    "  freeC(outp)\n" +
    "  if n == 17 {\n" +
    "    0\n" +
    "  } else {\n" +
    "    3\n" +
    "  }\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 0, "trampoline: pthread round-trip")
}

test "trampolines dedup by callback signature" {
  // Two calls with distinct closures but the same callback C signature
  // share one trampoline; the emitted module must define it exactly
  // once (a duplicate define would fail clang).
  val src = "package T\n" +
    "extern func pthreadCreate(tid: NativePtr[Long], attr: NativePtr[Byte], start: (NativePtr[Byte]) -> NativePtr[Byte], arg: NativePtr[Byte]): Int = \"pthread_create\"\n" +
    "extern func pthreadJoin(tid: Long, retval: NativePtr[NativePtr[Byte]]): Int = \"pthread_join\"\n" +
    "extern func cStrlen(s: NativePtr[Byte]): Long = \"strlen\"\n" +
    "extern func toC(s: String): NativePtr[Byte] = \"lyric_string_to_cstring\"\n" +
    "extern func freeC(p: NativePtr[Byte]): Unit = \"lyric_cstring_free\"\n" +
    "@unsafe_ffi\n" +
    "func runOne(w: in () -> NativePtr[Byte]): Long {\n" +
    "  var tid: Long = 0\n" +
    "  val rc = pthreadCreate(nativeAddrOf(tid), nativeNullPtr(), w, w)\n" +
    "  if rc != 0 {\n" +
    "    return -1\n" +
    "  }\n" +
    "  var outp: NativePtr[Byte] = nativeNullPtr()\n" +
    "  val rj = pthreadJoin(tid, nativeAddrOf(outp))\n" +
    "  if rj != 0 {\n" +
    "    return -2\n" +
    "  }\n" +
    "  val n = cStrlen(outp)\n" +
    "  freeC(outp)\n" +
    "  n\n" +
    "}\n" +
    "@unsafe_ffi\n" +
    "func main(): Int {\n" +
    "  val a = \"aa\"\n" +
    "  val b = \"bbbb\"\n" +
    "  val wa: () -> NativePtr[Byte] = { -> toC(a) }\n" +
    "  val wb: () -> NativePtr[Byte] = { -> toC(b) }\n" +
    "  val na = runOne(wa)\n" +
    "  val nb = runOne(wb)\n" +
    "  val total = na + nb\n" +
    "  total.toInt()\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 6, "trampoline dedup: 2 + 4")
}
