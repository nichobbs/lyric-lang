//! bindgen_self_test.l - `lyric bindgen` (docs/67 §5.3, D190): runs clang over a small
//! C header, generates the bindings, checks the text, then compiles them with a C
//! implementation of the header and runs the result under AddressSanitizer.
//!
//! Requires `clang` on PATH and a built runtime (`make -C lyric-rt`).
//!   make -C lyric-rt && LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/bindgen_self_test.l
@test_module
package Lyric.BindgenSelfTest

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
import Lyric.Bindgen
import Lyric.LlvmCodegen
import Lyric.LlvmLowering

func header(): String {
  "#include <stdint.h>\n" + "#include <stddef.h>\n" + "typedef struct Window Window;\n" +
    "typedef enum { MODE_A = 0, MODE_B = 2, MODE_C } Mode;\n" +
    "typedef struct { int w, h; float scale; uint8_t flags[4]; void* user; Window* win; } Desc;\n" +
    "typedef int (*EventFilter)(void* userdata, const Desc* ev);\n" +
    "Window* win_create(const char* title, const Desc* d);\n" +
    "void win_destroy(Window* w);\n" +
    "int win_set_filter(Window* w, EventFilter f, void* userdata);\n" +
    "uint32_t win_id(const Window* w);\n" +
    "size_t win_count(void);\n" +
    "double win_scale(Desc d);\n" +
    "int win_pair(short s);\n" +
    "int win_log(const char* fmt, ...);\n" +
    "typedef union { int i; float f; } Bits;\n" +
    "int win_bits(Bits b);\n" +
    "static inline int win_inline(void) { return 1; }\n"
}

func tempDir(): String {
  val base = Environment.getVarOrDefault("TMPDIR", "/tmp")
  val dir = Path.join(base, "lyric-bindgen-selftest")
  val _ = File.createDir(dir)
  dir
}

func astOf(src: in String): String {
  val path = Path.join(tempDir(), "h_" + Uuid.uuidToString(Uuid.newUuid()) + ".h")
  match File.writeText(path, src) {
    case Ok(_) -> ()
    case Err(_) -> panic("cannot write " + path)
  }
  val args: List[String] = newList()
  args.add("-Xclang")
  args.add("-ast-dump=json")
  args.add("-fsyntax-only")
  args.add(path)
  match Process.runCapture("clang", args, 120000) {
    case Ok(res) -> if res.exitCode != 0 { panic("clang failed: " + res.stderr) } else { res.stdout }
    case Err(e) -> panic("clang could not be started: " + e)
  }
}

func configWith(allow: in List[String], library: in String): BindgenConfig {
  BindgenConfig(packageName = "Win.Kernel", library = library, allow = allow, userdata = newMap(), longBits = 64)
}

func configOf(allow: in List[String]): BindgenConfig = configWith(allow, "win")

func allowOf(names: in slice[String]): List[String] {
  val chunks: List[String] = newList()
  for n in names {
    chunks.add(n)
  }
  chunks
}

test "functions, records, enum constants and callbacks are generated" {
  val ast = astOf(header())
  val cfg = configOf(
    allowOf(["win_create", "win_destroy", "win_set_filter", "win_id", "win_count", "win_scale", "MODE_*"])
  )
  val r = generateBindings(ast, cfg)
  assertEqualInt(r.errors.count, 0, "no errors: " + Str.joinList("; ", r.errors))
  val chunks = r.source
  assertTrue(Str.contains(chunks, "package Win.Kernel"), "package")
  assertTrue(Str.contains(chunks, "pub val MODE_A: Int = 0"), "MODE_A")
  assertTrue(Str.contains(chunks, "pub val MODE_B: Int = 2"), "MODE_B")
  assertTrue(Str.contains(chunks, "pub val MODE_C: Int = 3"), "implicit MODE_C")
  assertTrue(Str.contains(chunks, "pub foreign record Desc {"), "Desc is a foreign record")
  assertTrue(Str.contains(chunks, "  flags: array[4, Byte]"), "array field")
  assertTrue(Str.contains(chunks, "  user: NativePtr[Byte]"), "void* field")
  assertTrue(Str.contains(chunks, "  win: NativePtr[Byte]"), "opaque handle field")
  assertTrue(
    Str.contains(
      chunks,
      "pub extern func win_create(title: NativePtr[Byte], d: NativePtr[Desc]): NativePtr[Byte] = \"win_create\""
    ),
    "win_create"
  )
  assertTrue(Str.contains(chunks, "@library(\"win\")"), "library annotation")
  assertTrue(
    Str.contains(chunks, "f: (NativeUserdata, NativePtr[Desc]) -> Int"),
    "callback parameter marks the userdata slot: " + chunks
  )
  assertTrue(Str.contains(chunks, "pub extern func win_id(w: NativePtr[Byte]): Int"), "uint32_t is an Int")
  assertTrue(Str.contains(chunks, "pub extern func win_count(): Long"), "size_t is a Long")
  assertTrue(Str.contains(chunks, "pub extern func win_scale(d: Desc): Double"), "record by value")
}

test "what the native backend cannot pass is reported and skipped" {
  val ast = astOf(header())
  val cfg = configOf(allowOf(["win_*"]))
  val r = generateBindings(ast, cfg)
  assertEqualInt(r.errors.count, 0, "wildcard skips are notes, not errors: " + Str.joinList("; ", r.errors))
  assertTrue(not Str.contains(r.source, "win_pair"), "a 16-bit parameter is skipped")
  assertTrue(not Str.contains(r.source, "win_log"), "a variadic function is skipped")
  assertTrue(not Str.contains(r.source, "win_bits"), "a union by value is skipped")
  assertTrue(not Str.contains(r.source, "win_inline"), "a static inline function has no symbol")
  assertTrue(Str.joinList("\n", r.notes).length > 0, "the skips are reported")
}

test "a named symbol that cannot be bound is an error" {
  val ast = astOf(header())
  val missing = generateBindings(ast, configOf(allowOf(["no_such_function"])))
  assertTrue(missing.errors.count > 0, "an undeclared name")
  val skipped = generateBindings(ast, configOf(allowOf(["win_pair"])))
  assertTrue(skipped.errors.count > 0, "a named symbol that is skipped")
}

test "an ambiguous callback needs a userdata directive" {
  val src = "typedef void (*Cb)(void* a, void* b);\nvoid reg(Cb cb);\n"
  val ast = astOf(src)
  val bad = generateBindings(ast, configOf(allowOf(["reg"])))
  assertTrue(bad.errors.count > 0, "two void* parameters")
  val cfg = configOf(allowOf(["reg"]))
  cfg.userdata.add("Cb", 1)
  val ok = generateBindings(ast, cfg)
  assertEqualInt(ok.errors.count, 0, "with the directive: " + Str.joinList("; ", ok.errors))
  assertTrue(Str.contains(ok.source, "(NativePtr[Byte], NativeUserdata) -> Unit"), "index 1 is the userdata slot")
}

test "the allow-list file format" {
  val cfg = configOf(newList())
  val problems = parseAllowList("# comment\nwin_*  # trailing\n\nuserdata Cb 1\nMODE_A\n", cfg)
  assertEqualInt(problems.count, 0, "parses")
  assertEqualInt(cfg.allow.count, 2, "two patterns")
  assertEqualInt(cfg.userdata["Cb"], 1, "userdata index")
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

func hostTriple(): String {
  val args: List[String] = newList()
  args.add("-print-effective-triple")
  match Process.runCapture("clang", args, 30000) {
    case Ok(res) -> if res.exitCode == 0 { Str.trim(res.stdout) } else { "x86_64-unknown-linux-gnu" }
    case Err(_) -> "x86_64-unknown-linux-gnu"
  }
}

func runWithC(source: in String, cSource: in String): Int {
  val pr = parse(source)
  if pr.diagnostics.count > 0 {
    panic("generated source has parse diagnostics: " + pr.diagnostics[0].code + " " + pr.diagnostics[0].message)
  }
  val ll = lowerNativePackage(codegenNativePackage(pr.file, hostTriple()))
  val rt = findLyricRt()
  if rt.length == 0 {
    panic("lyric_rt.a not found; run `make -C lyric-rt` first")
  }
  val stem = Path.join(tempDir(), "t_" + Uuid.uuidToString(Uuid.newUuid()))
  match File.writeText(stem + ".ll", ll) {
    case Ok(_) -> ()
    case Err(_) -> panic("cannot write " + stem + ".ll")
  }
  match File.writeText(stem + ".c", cSource) {
    case Ok(_) -> ()
    case Err(_) -> panic("cannot write " + stem + ".c")
  }
  val clangArgs: List[String] = newList()
  clangArgs.add("-O0")
  clangArgs.add("-fsanitize=address")
  clangArgs.add(stem + ".ll")
  clangArgs.add(stem + ".c")
  clangArgs.add(rt)
  clangArgs.add("-lm")
  clangArgs.add("-lpthread")
  clangArgs.add("-o")
  clangArgs.add(stem)
  match Process.runCapture("clang", clangArgs, 120000) {
    case Ok(res) -> if res.exitCode != 0 { panic("clang failed on " + stem + ".ll: " + res.stderr) }
    case Err(e) -> panic("clang could not be started: " + e)
  }
  val noArgs: List[String] = newList()
  match Process.runCapture(stem, noArgs, 60000) {
    case Ok(res) -> res.exitCode
    case Err(e) -> panic("binary could not be started: " + e)
  }
}

test "the generated bindings drive a C library under ASan" {
  val ast = astOf(header())
  val cfg = configWith(allowOf(["win_create", "win_destroy", "win_set_filter", "win_scale", "MODE_*"]), "")
  val r = generateBindings(ast, cfg)
  assertEqualInt(r.errors.count, 0, "no errors: " + Str.joinList("; ", r.errors))
  val body = Str.replace(
    Str.replace(
      r.source,
      "@axiom(\"Win.Kernel bindings conform to the C header they were generated from\")\n",
      ""
    ),
    "@io\n",
    ""
  )
  val program = Str.replace(body, "package Win.Kernel", "package T") + "@unsafe_ffi\nfunc main(): Int {\n" +
    "  var d = Desc(w = 3, h = 4, scale = 2.5f32, flags = [0u8, 0u8, 0u8, 0u8], user = nativeNullPtr(), win = nativeNullPtr())\n" +
    "  val w = win_create(nativeNullPtr(), nativeAddrOf(d))\n" +
    "  if win_scale(d) != 30.0 {\n    return 1\n  }\n" +
    "  val cb: (NativePtr[Desc]) -> Int = { e: NativePtr[Desc] -> 7 }\n" +
    "  if win_set_filter(w, cb, cb) != 7 {\n    return 2\n  }\n" +
    "  win_destroy(w)\n" +
    "  if MODE_C != 3 {\n    return 3\n  }\n" +
    "  0\n}\n"
  val c = header() + "#include <stdlib.h>\nstruct Window { int id; };\n" +
    "Window* win_create(const char* t, const Desc* d) { Window* w = malloc(sizeof(Window)); w->id = d->w; return w; }\n" +
    "void win_destroy(Window* w) { free(w); }\n" +
    "int win_set_filter(Window* w, EventFilter f, void* ud) { Desc d = { 0 }; return f(ud, &d); }\n" +
    "double win_scale(Desc d) { return d.w * d.h * d.scale; }\n"
  assertEqualInt(runWithC(program, c), 0, "every value crosses the generated bindings intact")
}
