//! llvm_wasm32_self_test.l — end-to-end self-test for the `wasm32-wasi` native
//! target (docs/35 phase W2): Lyric programs compile through the full bridge
//! pipeline (`Lyric.LlvmBridge.compileToNativeWithFlags` with the
//! `_kernel_native/` twins loaded, exactly like `lyric build --target native
//! --triple wasm32-wasi`), link with a wasi-sdk clang against the wasm32
//! `lyric_rt` archive, and run under wasmtime with their behaviour asserted.
//!
//! Requires, from the environment, the tools `scripts/ci/wasm32-wasi-rt-tests.sh`
//! provisions: `WASI_SDK_PATH` (a wasi-sdk install), the wasm32 runtime
//! (`make -C lyric-rt wasm32-wasi WASI_SDK=...`) and `WASMTIME` (default
//! `wasmtime` on PATH).  Run via native `lyric test` with LYRIC_LOAD_COMPILER=1:
//!   LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/llvm_wasm32_self_test.l
@test_module
package Lyric.LlvmWasm32SelfTest

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

// ─────────────────────────────────────────────────────────────────────────────
// Harness.
// ─────────────────────────────────────────────────────────────────────────────
func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", "/tmp")
}

record WasmRun {
  exitCode: Int
  stdout: String
  stderr: String
  dir: String
}

/// Compile `source` for wasm32-wasi and run it under wasmtime with `dir`
/// preopened as `/work` and `progArgs` passed after the program name.
func compileAndRunWasm(source: in String, progArgs: in List[String]): WasmRun {
  if Environment.getVarOrDefault("WASI_SDK_PATH", "").length == 0 {
    panic("WASI_SDK_PATH is not set: run scripts/ci/wasm32-wasi-rt-tests.sh or point it at a wasi-sdk install")
  }
  val stdlib = findStdlibSourcesNative()
  if stdlib.count == 0 {
    panic("native stdlib sources not found (run from the repo root or set LYRIC_STD_PATH)")
  }
  val dir = Path.join(tempBase(), "lyric-wasm32-selftest-" + Uuid.uuidToString(Uuid.newUuid()))
  val _ = File.createDir(dir)
  val wasmPath = Path.join(dir, "prog.wasm")
  val flags: List[String] = newList()
  if not compileToNativeWithFlags(source, wasmPath, stdlib, "wasm32-wasi", "2", flags, newList(), "", true) {
    panic("wasm32-wasi compilation failed for a self-test program")
  }
  val wasmtime = Environment.getVarOrDefault("WASMTIME", "wasmtime")
  val args: List[String] = newList()
  args.add("run")
  args.add("--dir=" + dir + "::/work")
  args.add(wasmPath)
  if progArgs.count > 0 {
    var i = 0
    while i < progArgs.count {
      args.add(progArgs[i])
      i = i + 1
    }
  }
  match Process.runCapture(wasmtime, args, 120000) {
    case Ok(res) -> WasmRun(exitCode = res.exitCode, stdout = res.stdout, stderr = res.stderr, dir = dir)
    case Err(e) -> panic("wasmtime could not be started (set WASMTIME): " + e)
  }
}

func runWasm(source: in String): WasmRun {
  val noArgs: List[String] = newList()
  compileAndRunWasm(source, noArgs)
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────
test "wasm32: exit code and stdout through the wasi-libc entry point" {
  val r = runWasm(
    "package T\n" + "import Std.Console\n" + "func main(): Int {\n" + "  println(\"hello from wasm\")\n" +
      "  7\n" +
      "}\n"
  )
  assertEqualInt(r.exitCode, 7, "main's result is the process exit code (via __main_argc_argv)")
  assertEqual(r.stdout, "hello from wasm\n", "stdout")
}

test "wasm32: every header-bearing heap shape (record, union, tuple, closure, list, string)" {
  val r = runWasm(
    "package T\n" + "import Std.Collections\n" + "record Node {\n" + "  name: String\n" + "  n: Int\n" + "}\n" +
      "union Shape {\n" +
      "  case Circle(r: Int)\n" +
      "  case Tag(label: String, n: Int)\n" +
      "  case Empty\n" +
      "}\n" +
      "func size(s: in Shape): Int {\n" +
      "  match s {\n" +
      "    case Circle(r) -> r\n" +
      "    case Tag(label, n) -> label.length + n\n" +
      "    case Empty -> 0\n" +
      "  }\n" +
      "}\n" +
      "func main(): Int {\n" +
      "  val node = Node(name = \"abc\", n = 4)\n" +
      "  val (a, b) = (node.n, node.name.length)\n" +
      "  val base = 10\n" +
      "  val add: (Int) -> Int = { x -> x + base }\n" +
      "  val xs: List[Int] = [1, 2, 3]\n" +
      "  size(Circle(r = a)) + size(Tag(label = \"zz\", n = b)) + add(1) + xs.count\n" +
      "}\n"
  )
  assertEqualInt(r.exitCode, 23, "4 + 5 + 11 + 3")
}

test "wasm32: Float is binary32 and renders with .NET's shortest round-trip rules" {
  val r = runWasm(
    "package T\n" + "import Std.Console\n" + "func main(): Int {\n" + "  val a: Float = 0.1\n" +
      "  val b: Float = 0.2\n" +
      "  println((a + b).toString())\n" +
      "  val c: Float = 1.0\n" +
      "  val d: Float = 3.0\n" +
      "  println((c / d).toString())\n" +
      "  0\n" +
      "}\n"
  )
  assertEqualInt(r.exitCode, 0, "exit")
  assertEqual(r.stdout, "0.3\n0.33333334\n", "binary32 arithmetic and rendering")
}

test "wasm32: Std.Environment.args receives argc/argv from the WASI host" {
  val progArgs: List[String] = newList()
  progArgs.add("one")
  progArgs.add("two")
  val r = compileAndRunWasm(
    "package T\n" + "import Std.Environment\n" + "func main(): Int {\n" + "  val argv = args()\n" +
      "  argv.length\n" +
      "}\n",
    progArgs
  )
  assertEqualInt(r.exitCode, 3, "program name plus two arguments")
}

test "wasm32: Std.File round-trips through a preopened directory" {
  val r = runWasm(
    "package T\n" + "import Std.Core\n" + "import Std.File\n" + "func main(): Int {\n" +
      "  match writeText(\"/work/probe.txt\", \"wasm-io\") {\n" +
      "    case Ok(_) -> {\n" +
      "    }\n" +
      "    case Err(_) -> {\n" +
      "      return 1\n" +
      "    }\n" +
      "  }\n" +
      "  match readText(\"/work/probe.txt\") {\n" +
      "    case Ok(t) -> {\n" +
      "      if t != \"wasm-io\" {\n" +
      "        return 2\n" +
      "      }\n" +
      "    }\n" +
      "    case Err(_) -> {\n" +
      "      return 3\n" +
      "    }\n" +
      "  }\n" +
      "  match readText(\"/work/missing.txt\") {\n" +
      "    case Ok(_) -> {\n" +
      "      return 4\n" +
      "    }\n" +
      "    case Err(_) -> {\n" +
      "    }\n" +
      "  }\n" +
      "  42\n" +
      "}\n"
  )
  assertEqualInt(r.exitCode, 42, "write, read back, missing file is an Err")
  match File.readText(Path.join(r.dir, "probe.txt")) {
    case Ok(t) -> assertEqual(t, "wasm-io", "the host sees the guest's file")
    case Err(_) -> panic("the guest's file is missing on the host")
  }
}

test "wasm32: time and uuid seams (clock_nanosleep, getentropy)" {
  val r = runWasm(
    "package T\n" + "import Std.Time\n" + "import Std.Uuid\n" + "func main(): Int {\n" +
      "  val t0 = nowEpochMillis()\n" +
      "  if t0 < 1500000000000i64 {\n" +
      "    return 1\n" +
      "  }\n" +
      "  val m0 = monotonicNanos()\n" +
      "  sleepMillis(15)\n" +
      "  val m1 = monotonicNanos()\n" +
      "  if m1 - m0 < 10000000i64 {\n" +
      "    return 2\n" +
      "  }\n" +
      "  val u = uuidToString(newUuid())\n" +
      "  if u.length != 36 {\n" +
      "    return 3\n" +
      "  }\n" +
      "  42\n" +
      "}\n"
  )
  assertEqualInt(r.exitCode, 42, "clock, sleep and a v4 uuid")
}

test "wasm32: capabilities WASI lacks fail with a typed Err, not a link error or trap" {
  val r = runWasm(
    "package T\n" + "import Std.Core\n" + "import Std.Collections\n" + "import Std.Process\n" +
      "func main(): Int {\n" +
      "  val noArgs: List[String] = newList()\n" +
      "  match run(\"/bin/true\", noArgs) {\n" +
      "    case Ok(_) -> {\n" +
      "      return 1\n" +
      "    }\n" +
      "    case Err(_) -> {\n" +
      "    }\n" +
      "  }\n" +
      "  match runCapture(\"/bin/echo\", noArgs, 1000) {\n" +
      "    case Ok(_) -> {\n" +
      "      return 2\n" +
      "    }\n" +
      "    case Err(_) -> {\n" +
      "    }\n" +
      "  }\n" +
      "  42\n" +
      "}\n"
  )
  assertEqualInt(r.exitCode, 42, "spawning a process reports Err on wasm32-wasi")
}

test "wasm32: Std.Process.spawnPiped reports a typed Err" {
  val r = runWasm(
    "package T\n" + "import Std.Core\n" + "import Std.Collections\n" + "import Std.Process\n" +
      "func main(): Int {\n" +
      "  val noArgs: List[String] = newList()\n" +
      "  match spawnPiped(\"/bin/cat\", noArgs) {\n" +
      "    case Ok(_) -> {\n" +
      "      return 1\n" +
      "    }\n" +
      "    case Err(_) -> {\n" +
      "    }\n" +
      "  }\n" +
      "  42\n" +
      "}\n"
  )
  assertEqualInt(r.exitCode, 42, "the piped-process kernel links and reports Err on wasm32-wasi")
}

test "wasm32: the TCP and TLS client kernels link and report a typed Err" {
  val r = runWasm(
    "package T\n" + "import Std.Core\n" + "import Std.Tls\n" + "import Std.TcpHost\n" +
      "func main(): Int {\n" +
      "  match hostListen(\"127.0.0.1\", 0) {\n" +
      "    case Ok(_) -> {\n" +
      "      return 1\n" +
      "    }\n" +
      "    case Err(_) -> {\n" +
      "    }\n" +
      "  }\n" +
      "  match hostConnect(\"127.0.0.1\", 1) {\n" +
      "    case Ok(_) -> {\n" +
      "      return 2\n" +
      "    }\n" +
      "    case Err(_) -> {\n" +
      "    }\n" +
      "  }\n" +
      "  match hostConnectTls(\"127.0.0.1\", 1, TlsTrustExclusive(caPem = \"x\"), None, TlsVersion.Tls12, \"http/1.1\") {\n" +
      "    case Ok(_) -> {\n" +
      "      return 3\n" +
      "    }\n" +
      "    case Err(_) -> {\n" +
      "    }\n" +
      "  }\n" +
      "  42\n" +
      "}\n"
  )
  assertEqualInt(r.exitCode, 42, "TCP and TLS dials report Err on wasm32-wasi")
}

test "wasm32: Std.HttpServer links and its bind failure panics with the TCP diagnostic" {
  val r = runWasm(
    "package T\n" + "import Std.HttpServer\n" + "func main(): Int {\n" +
      "  val l = startListener(\"http://127.0.0.1:0/\")\n" +
      "  stopListener(l)\n" +
      "  0\n" +
      "}\n"
  )
  assertTrue(r.exitCode != 0, "a failed bind aborts")
  assertTrue(r.stderr.contains("TCP sockets are unavailable"), "the panic carries the runtime's diagnostic")
}

test "wasm32: a panic aborts with a nonzero exit and its message" {
  val r = runWasm("package T\n" + "func main(): Int {\n" + "  panic(\"boom-wasm\")\n" + "}\n")
  assertTrue(r.exitCode != 0, "a panic must not exit 0")
  assertTrue(Str.contains(r.stderr, "boom-wasm"), "the panic message reaches stderr: " + r.stderr)
}
