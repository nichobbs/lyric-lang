//! llvm_opaque_self_test.l — end-to-end self-test for `opaque type`
//! codegen on `--target native` (#6234 part 1): parses small Lyric
//! programs declaring `opaque type`, lowers them to `.ll`, compiles with
//! clang against `lyric-rt/build/lyric_rt.a`, runs the produced binary,
//! and asserts its exit code and stdout.
//!
//! Before this fix, `Lyric.LlvmCodegen.unitOfFile`/`unitOf`'s item-kind
//! dispatch had no `IOpaque` case and fell to the wildcard panic ("this
//! item form is not yet supported for --target native") for the
//! single-file path, or silently dropped the item for the bundled path
//! — every case here previously panicked the compile (single-file) or
//! left the type unregistered so a use panicked at resolution time
//! (bundled). `opaqueToRecordDecl` reshapes an `OpaqueTypeDecl` into the
//! equivalent `RecordDecl` so opaque types share every existing record
//! code path (layout, construction, field access, ARC destructor
//! synthesis) — mirroring how `Std.Tls`'s `Certificate`/`Identity`
//! (`lyric-stdlib/std/tls.l`) are just `opaque type`s with a single
//! heap-managed field.
//!
//! The ARC case compiles with `-fsanitize=address` (LeakSanitizer is on
//! by default on Linux): a missed release (leak), premature release
//! (use-after-free), or double release all make the binary exit
//! non-zero, so `exit 0` is a real end-to-end ARC correctness check for
//! an opaque type's destructor, exactly like `llvm_heap_self_test.l`'s
//! record ARC cases.
//!
//! A custom-destructor hook for an opaque type wrapping a raw resource
//! (e.g. a `NativePtr` OS handle) is a separate, unimplemented gap
//! (#6234 part 2) — deliberately not exercised here; every field in
//! these cases is either scalar or ARC-managed (String), so the
//! synthesised record-style destructor releases it correctly with no
//! custom cleanup hook needed.
//!
//! Requires `clang` on PATH and a built runtime (`make -C lyric-rt`).
//! Run via native `lyric test` with LYRIC_LOAD_COMPILER=1:
//!   make -C lyric-rt && LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/llvm_opaque_self_test.l
@test_module
package Lyric.LlvmOpaqueSelfTest

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
  val dir = Path.join(tempBase(), "lyric-llvm-opaque-selftest")
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
/// llvm_heap_self_test.l).
func printlnShim(): String {
  "extern func consoleWriteFd(fd: Int, s: String): Unit = \"lyric_console_write\"\n" +
    "extern func consoleNewlineFd(fd: Int): Unit = \"lyric_console_write_newline\"\n" +
    "func println(s: in String): Unit {\n" +
    "  consoleWriteFd(1, s)\n" +
    "  consoleNewlineFd(1)\n" +
    "}\n"
}

// ─────────────────────────────────────────────────────────────────────────────
// Opaque types.
// ─────────────────────────────────────────────────────────────────────────────
test "opaque type construction and scalar field access" {
  val src = "package T\n" + "opaque type Meters {\n" + "  value: Int\n" + "}\n" + "func main(): Int {\n" +
    "  val m = Meters(value = 42)\n" +
    "  m.value\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 42, "opaque scalar field")
}

test "opaque type with string field prints" {
  val src = "package T\n" + printlnShim() + "opaque type Handle {\n" + "  name: String\n" + "  id: Int\n" + "}\n" +
    "func main(): Unit {\n" +
    "  val h = Handle(name = \"cert\", id = 7)\n" +
    "  println(h.name + \":\" + h.id.toString())\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 0, "opaque string field exit")
  assertEqual(r.stdout, "cert:7\n", "opaque string field stdout")
}

test "mutable opaque field assignment" {
  val src = "package T\n" + "opaque type Counter {\n" + "  var n: Int\n" + "  var label: String\n" + "}\n" +
    "func main(): Int {\n" +
    "  val c = Counter(n = 0, label = \"a\")\n" +
    "  c.n = 5\n" +
    "  c.n += 3\n" +
    "  c.label = c.label + \"b\"\n" +
    "  c.n + c.label.length\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 10, "opaque field assignment")
}

test "ufcs call on opaque type" {
  val src = "package T\n" + "opaque type Wrapped {\n" + "  n: Int\n" + "}\n" + "func doubled(w: in Wrapped): Int {\n" +
    "  w.n * 2\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val w = Wrapped(n = 21)\n" +
    "  w.doubled()\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 42, "opaque ufcs")
}

test "record field of opaque type resolves and reads through" {
  val src = "package T\n" + "opaque type Token {\n" + "  value: String\n" + "}\n" + "record Config {\n" +
    "  token: Token\n" +
    "  retries: Int = 3\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val c = Config(token = Token(value = \"abc\"))\n" +
    "  c.token.value.length + c.retries\n" +
    "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 6, "opaque field of record")
}

test "body-less opaque forward declaration compiles without lowering" {
  val src = "package T\n" + "opaque type Marker\n" + "func main(): Int {\n" + "  0\n" + "}\n"
  val r = compileAndRun(src)
  assertEqualInt(r.exitCode, 0, "body-less opaque")
}

// #6239 (review follow-up to #6234 part 1): `opaqueToRecordDecl` reshapes an
// `OpaqueTypeDecl` into a `RecordDecl`, which has no `annotations` field —
// so `@projectable` (a real, both-targets-shipped feature, D015, that
// synthesises a `<Name>View` exposed-record twin plus `toView()`/`tryInto()`
// on `--target dotnet`/`--target jvm`) must NOT silently vanish when the
// same declaration compiles for `--target native`. This drives codegen
// directly (a rejected program never reaches clang) and asserts the panic
// carries both the diagnostic code and a mention of `@projectable`, so the
// guard can't vacuously pass.
test "@projectable opaque type is rejected at native codegen with N0101, not silently compiled" {
  val src = "package T\n" + "opaque type Widget @projectable {\n" + "  label: String\n" + "}\n" + "func main(): Int {\n" +
    "  0\n" +
    "}\n"
  val pr = parse(src)
  assertEqualInt(pr.diagnostics.count, 0, "the source itself parses")
  var rejected = false
  var msg = ""
  try {
    val pkg = codegenNativePackage(pr.file, "")
    val _ = lowerNativePackage(pkg)
  } catch Bug as b {
    rejected = true
    msg = b.message
  }
  assertTrue(
    rejected,
    "a @projectable opaque type must be rejected at native codegen, not silently compiled with lost semantics"
  )
  assertTrue(Str.contains(msg, "N0101"), "the rejection names the N0101 diagnostic code (got: " + msg + ")")
  assertTrue(Str.contains(msg, "projectable"), "the rejection mentions @projectable (got: " + msg + ")")
}

// The shape mirrors `Std.Tls`'s `Certificate { handle: Host.CertHandle }`
// (lyric-stdlib/std/tls.l): a single heap-managed field, constructed
// repeatedly and dropped. Every construction/release pair must balance
// under ASan+LSan or the run exits non-zero.
test "arc: opaque type instances with a string field construct and release in a loop without leaking" {
  val src = "package T\n" + "opaque type Certificate {\n" + "  pem: String\n" + "}\n" +
    "func loadPem(i: in Int): String {\n" +
    "  \"-----BEGIN CERT-----\" + i.toString()\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  var total = 0\n" +
    "  var i = 0\n" +
    "  while i < 2000 {\n" +
    "    val cert = Certificate(pem = loadPem(i))\n" +
    "    if cert.pem.length > 10 {\n" +
    "      total = total + 1\n" +
    "    }\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  if total == 2000 {\n" +
    "    0\n" +
    "  } else {\n" +
    "    1\n" +
    "  }\n" +
    "}\n"
  val r = compileAndRunAsan(src)
  assertEqualInt(r.exitCode, 0, "opaque allocation loop leak-free (ASan)")
}
