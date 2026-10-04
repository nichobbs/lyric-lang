//! llvm_c_abi_self_test.l — by-value records crossing the C boundary on
//! `--target native` (#8009).  A record with only by-value fields is an LLVM
//! struct value; an `extern func` taking or returning one is declared and
//! called the way clang lowers the matching C prototype for the target
//! (System V AMD64, AAPCS64, the wasm32 basic C ABI).
//!
//! The runtime cases compile a C helper with clang, link it with the
//! program, and check every value that crosses: a three-float vector, a
//! `{double, int}`, a 32-byte record (memory class, `sret`), a four-float
//! homogeneous aggregate, a padded `{byte, int, byte}`, and a call whose
//! seventh record no longer fits the argument registers.  They run on the
//! host's own triple (x86-64 in CI).  The AArch64 and wasm32 cases check the
//! declarations against what clang 18 emits for the same prototypes.
//!
//! Requires `clang` on PATH and a built runtime (`make -C lyric-rt`).
//!   make -C lyric-rt && LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/llvm_c_abi_self_test.l
@test_module
package Lyric.LlvmCAbiSelfTest

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

func hostTriple(): String {
  val args: List[String] = newList()
  args.add("-print-effective-triple")
  match Process.runCapture("clang", args, 30000) {
    case Ok(res) -> Str.trim(res.stdout)
    case Err(e) -> panic("clang could not be started: " + e)
  }
}

func lowerFor(source: in String, triple: in String): String {
  val pr = parse(source)
  if pr.diagnostics.count > 0 {
    panic("test source has parse diagnostics: " + pr.diagnostics[0].code + " " + pr.diagnostics[0].message)
  }
  lowerNativePackage(codegenNativePackage(pr.file, triple))
}

// Builds `source` for the host with the C helper `cSource` linked in, runs
// it, and returns its exit code.
func runWithC(source: in String, cSource: in String, sanitize: in Bool): Int {
  val ll = lowerFor(source, hostTriple())
  val rt = findLyricRt()
  if rt.length == 0 {
    panic("lyric_rt.a not found; run `make -C lyric-rt` first")
  }
  val dir = Path.join(tempBase(), "lyric-llvm-cabi-selftest")
  val _ = File.createDir(dir)
  val stem = Path.join(dir, "t_" + Uuid.uuidToString(Uuid.newUuid()))
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
  if sanitize {
    clangArgs.add("-fsanitize=address")
  }
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

func cHelper(): String {
  "typedef struct { float x, y, z; } Vec3;\n" + "typedef struct { double d; int i; } DI;\n" +
    "typedef struct { double a, b, c, d; } Big;\n" +
    "typedef struct { float r, g, b, a; } Color;\n" +
    "typedef struct { unsigned char a; int b; unsigned char c; } Mixed;\n" +
    "Vec3 vec3_scale(Vec3 v, float k) { Vec3 r = { v.x * k, v.y * k, v.z * k }; return r; }\n" +
    "float vec3_sum(Vec3 v) { return v.x + v.y + v.z; }\n" +
    "DI di_make(double d, int i) { DI r = { d, i }; return r; }\n" +
    "double di_sum(DI v) { return v.d + v.i; }\n" +
    "Big big_make(double s) { Big r = { s, s * 2, s * 3, s * 4 }; return r; }\n" +
    "double big_sum(Big v) { return v.a + v.b + v.c + v.d; }\n" +
    "Color color_mix(Color p, Color q) { Color r = { (p.r + q.r) / 2, (p.g + q.g) / 2, (p.b + q.b) / 2, (p.a + q.a) / 2 }; return r; }\n" +
    "Mixed mixed_bump(Mixed m) { Mixed r = { m.a + 1, m.b + 1, m.c + 1 }; return r; }\n" +
    "double di_seven(DI a, DI b, DI c, DI d, DI e, DI f, DI g) { return a.d + b.d + c.d + d.d + e.d + f.d + g.d + a.i + b.i + c.i + d.i + e.i + f.i + g.i; }\n"
}

func lyricDecls(): String {
  "package T\n" + "record Vec3 {\n  x: Float\n  y: Float\n  z: Float\n}\n" + "record DI {\n  d: Double\n  i: Int\n}\n" +
    "record Big {\n  a: Double\n  b: Double\n  c: Double\n  d: Double\n}\n" +
    "record Color {\n  r: Float\n  g: Float\n  b: Float\n  a: Float\n}\n" +
    "record Mixed {\n  a: Byte\n  b: Int\n  c: Byte\n}\n" +
    "extern func vec3_scale(v: Vec3, k: Float): Vec3 = \"vec3_scale\"\n" +
    "extern func vec3_sum(v: Vec3): Float = \"vec3_sum\"\n" +
    "extern func di_make(d: Double, i: Int): DI = \"di_make\"\n" +
    "extern func di_sum(v: DI): Double = \"di_sum\"\n" +
    "extern func big_make(s: Double): Big = \"big_make\"\n" +
    "extern func big_sum(v: Big): Double = \"big_sum\"\n" +
    "extern func color_mix(p: Color, q: Color): Color = \"color_mix\"\n" +
    "extern func mixed_bump(m: Mixed): Mixed = \"mixed_bump\"\n" +
    "extern func di_seven(a: DI, b: DI, c: DI, d: DI, e: DI, f: DI, g: DI): Double = \"di_seven\"\n"
}

test "by-value records cross to and from C on the host" {
  val src = lyricDecls() + "func main(): Int {\n" +
    "  val v = vec3_scale(Vec3(x = 1.0f32, y = 2.0f32, z = 3.0f32), 2.0f32)\n" +
    "  if v.x != 2.0f32 or v.y != 4.0f32 or v.z != 6.0f32 {\n    return 1\n  }\n" +
    "  if vec3_sum(v) != 12.0f32 {\n    return 2\n  }\n" +
    "  val di = di_make(1.5, 7)\n" +
    "  if di.d != 1.5 or di.i != 7 {\n    return 3\n  }\n" +
    "  if di_sum(di) != 8.5 {\n    return 4\n  }\n" +
    "  val b = big_make(1.0)\n" +
    "  if b.a != 1.0 or b.b != 2.0 or b.c != 3.0 or b.d != 4.0 {\n    return 5\n  }\n" +
    "  if big_sum(b) != 10.0 {\n    return 6\n  }\n" +
    "  val c = color_mix(Color(r = 0.0f32, g = 1.0f32, b = 0.5f32, a = 1.0f32), Color(r = 1.0f32, g = 0.0f32, b = 0.5f32, a = 0.0f32))\n" +
    "  if c.r != 0.5f32 or c.g != 0.5f32 or c.b != 0.5f32 or c.a != 0.5f32 {\n    return 7\n  }\n" +
    "  val m = mixed_bump(Mixed(a = 1u8, b = 41, c = 9u8))\n" +
    "  if m.a != 2u8 or m.b != 42 or m.c != 10u8 {\n    return 8\n  }\n" +
    "  val one = DI(d = 1.0, i = 1)\n" +
    "  if di_seven(one, one, one, one, one, one, DI(d = 2.0, i = 3)) != 17.0 {\n    return 9\n  }\n" +
    "  0\n" +
    "}\n"
  assertEqualInt(
    runWithC(src, cHelper(), false),
    0,
    "every value crosses intact (a non-zero code names the first that did not)"
  )
}

test "calls in a loop keep their stack buffers in the entry block under ASan" {
  val src = lyricDecls() + "func main(): Int {\n" + "  var acc: Float = 0.0f32\n" + "  var i = 0\n" +
    "  while i < 1000 {\n" +
    "    val v = vec3_scale(Vec3(x = 1.0f32, y = 0.0f32, z = 0.0f32), 1.0f32)\n" +
    "    acc = acc + vec3_sum(v)\n" +
    "    val b = big_make(0.0)\n" +
    "    acc = acc + big_sum(b).toFloat()\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  if acc == 1000.0f32 {\n    0\n  } else {\n    1\n  }\n" +
    "}\n"
  assertEqualInt(runWithC(src, cHelper(), true), 0, "1000 round trips")
}

// C calling back into Lyric with records by value: the trampoline takes the
// C-ABI form, rebuilds the record, and returns the result as C expects it.
test "a Lyric closure takes and returns records when C calls it, under ASan" {
  val c = cHelper() +
    "Vec3 apply_vec(Vec3 (*f)(Vec3, float, void*), void* ud) { Vec3 v = { 1, 2, 3 }; return f(v, 2.0f, ud); }\n" +
    "double apply_big(Big (*f)(Big, void*), void* ud) { Big b = { 1, 2, 3, 4 }; Big r = f(b, ud); return r.a + r.b + r.c + r.d; }\n" +
    "double apply_mixed(Mixed (*f)(Mixed, void*), void* ud) { Mixed m = { 1, 40, 2 }; Mixed r = f(m, ud); return r.a + r.b + r.c; }\n"
  val src = lyricDecls() +
    "extern func apply_vec(f: (Vec3, Float, NativePtr[Byte]) -> Vec3, ud: NativePtr[Byte]): Vec3 = \"apply_vec\"\n" +
    "extern func apply_big(f: (Big, NativePtr[Byte]) -> Big, ud: NativePtr[Byte]): Double = \"apply_big\"\n" +
    "extern func apply_mixed(f: (Mixed, NativePtr[Byte]) -> Mixed, ud: NativePtr[Byte]): Double = \"apply_mixed\"\n" +
    "@unsafe_ffi\n" +
    "func main(): Int {\n" +
    "  val scale: (Vec3, Float) -> Vec3 = { v: Vec3, k: Float -> Vec3(x = v.x * k, y = v.y * k, z = v.z * k) }\n" +
    "  val r = apply_vec(scale, scale)\n" +
    "  if r.x != 2.0f32 or r.y != 4.0f32 or r.z != 6.0f32 {\n    return 1\n  }\n" +
    "  val twice: (Big) -> Big = { b: Big -> Big(a = b.a * 2.0, b = b.b * 2.0, c = b.c * 2.0, d = b.d * 2.0) }\n" +
    "  if apply_big(twice, twice) != 20.0 {\n    return 2\n  }\n" +
    "  val bump: (Mixed) -> Mixed = { m: Mixed -> Mixed(a = m.a + 1u8, b = m.b + 1, c = m.c + 1u8) }\n" +
    "  if apply_mixed(bump, bump) != 46.0 {\n    return 3\n  }\n" +
    "  0\n" +
    "}\n"
  assertEqualInt(runWithC(src, c, true), 0, "every callback crosses intact")
}

func mainStub(): String = "func main(): Int {\n  0\n}\n"

test "AArch64 declarations match clang's AAPCS64 lowering" {
  val ll = lowerFor(lyricDecls() + mainStub(), "aarch64-unknown-linux-gnu")
  assertTrue(Str.contains(ll, "@vec3_scale([3 x float] alignstack(8), float)"), "a float HFA in FP registers")
  assertTrue(Str.contains(ll, "declare %T.Vec3 @vec3_scale"), "an HFA result is the record")
  assertTrue(Str.contains(ll, "declare [2 x i64] @di_make(double, i32)"), "a 16-byte record result in x0/x1")
  assertTrue(Str.contains(ll, "@di_sum([2 x i64])"), "a 16-byte record in two general registers")
  assertTrue(Str.contains(ll, "@big_sum([4 x double] alignstack(8))"), "a four-double HFA")
  assertTrue(Str.contains(ll, "declare %T.Big @big_make(double)"), "a four-double HFA result")
  assertTrue(Str.contains(ll, "@mixed_bump([2 x i64])"), "a padded 12-byte record")
}

test "wasm32 declarations match clang's basic C ABI lowering" {
  val ll = lowerFor(lyricDecls() + mainStub(), "wasm32-unknown-wasi")
  assertTrue(
    Str.contains(ll, "@vec3_scale(%T.Vec3* sret(%T.Vec3) align 4, %T.Vec3* byval(%T.Vec3) align 4, float)"),
    "a multi-field record by value in memory, returned through sret"
  )
  assertTrue(Str.contains(ll, "@di_sum(%T.DI* byval(%T.DI) align 8)"), "a {double, int} in memory")
}

test "x86-64 declarations match clang's System V lowering" {
  val ll = lowerFor(lyricDecls() + mainStub(), "x86_64-unknown-linux-gnu")
  assertTrue(Str.contains(ll, "declare { double, double } @vec3_scale(double, double, float)"), "two SSE eightbytes")
  assertTrue(Str.contains(ll, "declare { double, i64 } @di_make(double, i32)"), "an SSE and an INTEGER eightbyte")
  assertTrue(Str.contains(ll, "@big_make(%T.Big* sret(%T.Big) align 8, double)"), "a 32-byte result through sret")
  assertTrue(Str.contains(ll, "@big_sum(%T.Big* byval(%T.Big) align 8)"), "a 32-byte record in memory")
  assertTrue(
    Str.contains(ll, "i64, double, i64, %T.DI* byval(%T.DI) align 8)"),
    "the seventh {double, int} no longer fits the six general registers"
  )
}

test "N0010 keeps only what the C ABI lowering does not cover" {
  val callback = "package T\n" + "record Pt {\n  x: Int\n  y: Int\n}\n" +
    "extern func onEach(f: (Pt) -> Int): Int = \"on_each\"\n" +
    mainStub()
  val pr = parse(callback)
  val units: List[CodegenUnit] = newList()
  units.add(unitOfFile("T", pr.file))
  assertEqualInt(
    nativeByValueExternDiagnostics(units, "x86_64-unknown-linux-gnu").count,
    0,
    "a by-value record in a callback type crosses"
  )
  val uni = "package T\n" + "union Pick {\n  case A(x: Int)\n  case B\n}\n" +
    "extern func take(p: Pick): Int = \"take\"\n" +
    mainStub()
  val units3: List[CodegenUnit] = newList()
  units3.add(unitOfFile("T", parse(uni).file))
  assertEqualInt(
    nativeByValueExternDiagnostics(units3, "x86_64-unknown-linux-gnu").count,
    1,
    "an inline union never crosses"
  )
  val direct = "package T\n" + "record Pt {\n  x: Int\n  y: Int\n}\n" + "extern func take(p: Pt): Int = \"take\"\n" +
    mainStub()
  val units2: List[CodegenUnit] = newList()
  units2.add(unitOfFile("T", parse(direct).file))
  assertEqualInt(
    nativeByValueExternDiagnostics(units2, "x86_64-unknown-linux-gnu").count,
    0,
    "a direct record parameter crosses"
  )
  assertEqualInt(
    nativeByValueExternDiagnostics(units2, "riscv64-unknown-linux-gnu").count,
    1,
    "a target without the lowering"
  )
  assertEqualInt(nativeByValueExternDiagnostics(units2).count, 1, "no target named")
}
