//! llvm_self_test_n34.l — end-to-end self-test for N3.4 protected types on
//! the native (LLVM) backend.  Parses small programs with `protected type`
//! declarations, lowers them via `codegenNativePackage` + `lowerNativePackage`,
//! clang-compiles against `lyric-rt/build/lyric_rt.a`, runs the binary, and
//! asserts its exit code.  The ASan case proves the destructor releases a
//! ref-typed user field and frees the runtime-sized mutex buffer with no
//! leak or double-free (D-N-017).
//!
//! Requires `clang` on PATH and a built runtime (`make -C lyric-rt`).
//! Run via native `lyric test` with LYRIC_LOAD_COMPILER=1:
//!   make -C lyric-rt && LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/llvm_self_test_n34.l
@test_module
package Lyric.LlvmSelfTestN34

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
// Harness (mirrors llvm_self_test_n3.l): compile source to a native binary
// (optionally under ASan) and run it.
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
  val dir = Path.join(tempBase(), "lyric-llvm-n34-selftest")
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
// Cases.
// ─────────────────────────────────────────────────────────────────────────────
test "protected type: entries mutate and read state through the lock/unlock wrapper" {
  val src = "package T\n" +
    "protected type Counter {\n  var count: Int\n  entry increment() {\n    count = count + 1\n  }\n  entry add(n: in Int) {\n    count = count + n\n  }\n  entry get(): Int {\n    return count\n  }\n}\n" +
    "func main(): Int {\n  val c = Counter(count = 0)\n  c.increment()\n  c.increment()\n  c.increment()\n  c.add(10)\n  c.get()\n}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 13, "three increments (3) + add(10) == 13")
}

// `func` members are exclusive too (language reference §7.5) — native has no
// built-in monitor primitive, so a `func` gets the same lock/unlock wrapper
// as an `entry` (unlike MSIL, which only locks `entry`; see D-N-017).
test "protected type: func members lock/unlock same as entries" {
  val src = "package T\n" +
    "protected type Tally {\n  var n: Int\n  entry bump() {\n    n = n + 1\n  }\n  func doubled(): Int {\n    n * 2\n  }\n}\n" +
    "func main(): Int {\n  val t = Tally(n = 5)\n  t.bump()\n  t.bump()\n  t.doubled()\n}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 14, "(5 + 1 + 1) * 2 == 14 via a func member")
}

test "protected type: no-arg constructor uses field defaults" {
  val src = "package T\n" +
    "protected type Flag {\n  var on: Int = 0\n  entry toggle() {\n    on = 1 - on\n  }\n  entry state(): Int {\n    return on\n  }\n}\n" +
    "func main(): Int {\n  val f = Flag()\n  f.toggle()\n  f.toggle()\n  f.toggle()\n  f.state()\n}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 1, "default on=0, toggled 3 times -> 1")
}

// ASan: proves the synthesised destructor both releases the ref-typed
// `label` field and frees the runtime-sized mutex buffer (lyric_mutex_destroy
// + lyric_free, D-N-017) with no leak or double-free across many
// constructions.
test "protected type ARC: ref field + mutex buffer are torn down cleanly under ASan" {
  val src = "package T\n" +
    "protected type Named {\n  var label: String\n  var count: Int\n  entry setCount(n: in Int) {\n    count = n\n  }\n  entry get(): Int {\n    return count\n  }\n}\n" +
    "func main(): Int {\n" +
    "  var sum = 0\n  var i = 0\n" +
    "  while i < 30 {\n    val n = Named(label = \"x\", count = 0)\n    n.setCount(i)\n    sum = sum + n.get()\n    i = i + 1\n  }\n" +
    "  sum - 435\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 0, "30 constructions leak-free; sum 0..29 == 435")
}
