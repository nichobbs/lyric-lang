#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# windows-native-e2e.sh — end-to-end programs for the Windows x86-64 native
# target (docs/67 G9): each is built with `lyric build --target native
# --triple x86_64-pc-windows-msvc` and run, and its output and exit status
# are checked.
#
#   - the output is named `<stem>.exe`;
#   - by-value records cross to and from C under the Microsoft x64
#     convention (1/2/4/8-byte records in a register, others by reference
#     and through sret), including from a C callback into a Lyric closure;
#   - UTF-8 text reaches stdout unchanged, arguments arrive as UTF-8, a
#     file with a non-ASCII name round-trips, the environment, sleeping,
#     the parallel worker pool and threads work;
#   - a panic exits with status 3 and prints its message, with no dialog.
#
# On a Windows host the programs run directly.  On Linux the same build
# cross-compiles (clang and lld-link, with the MSVC CRT and Windows SDK named
# by the INCLUDE and LIB environment variables) and WINE names the runner.
#
# Needs LYRIC_RT_WINDOWS_PATH (or a lyric-rt/build-x86_64-pc-windows-msvc
# archive) for the Windows runtime.
#
# Usage: [WINE=wine] bash scripts/ci/windows-native-e2e.sh <lyric> <workdir>
# ---------------------------------------------------------------------------
set -euo pipefail

lyric_bin="${1:?usage: windows-native-e2e.sh <lyric> <workdir>}"
work="${2:?usage: windows-native-e2e.sh <lyric> <workdir>}"
runner="${WINE:-}"
triple="x86_64-pc-windows-msvc"
mkdir -p "$work"

fail() {
  echo "::error::$*"
  exit 1
}

run_exe() {
  if [ -n "$runner" ]; then
    "$runner" "$@"
  else
    "$@"
  fi
}

# ── By-value records across the C boundary ──────────────────────────────
cat > "$work/cabi_helper.c" <<'C'
typedef struct { float x, y, z; } Vec3;
typedef struct { double d; int i; } DI;
typedef struct { double a, b, c, d; } Big;
typedef struct { float x, y; } V2;
typedef struct { unsigned char a, b; } B2;
typedef struct { unsigned char a, b, c; } B3;
typedef struct { int a; } I1;
Vec3 vec3_scale(Vec3 v, float k) { Vec3 r = { v.x * k, v.y * k, v.z * k }; return r; }
DI di_make(double d, int i) { DI r = { d, i }; return r; }
double di_sum(DI v) { return v.d + v.i; }
Big big_make(double s) { Big r = { s, s * 2, s * 3, s * 4 }; return r; }
double big_sum(Big v) { return v.a + v.b + v.c + v.d; }
V2 v2_add(V2 a, V2 b) { V2 r = { a.x + b.x, a.y + b.y }; return r; }
B2 b2_swap(B2 v) { B2 r = { v.b, v.a }; return r; }
B3 b3_rot(B3 v) { B3 r = { v.b, v.c, v.a }; return r; }
I1 i1_neg(I1 v) { I1 r = { -v.a }; return r; }
double di_seven(DI a, DI b, DI c, DI d, DI e, DI f, DI g) {
  return a.d + b.d + c.d + d.d + e.d + f.d + g.d + a.i + b.i + c.i + d.i + e.i + f.i + g.i;
}
/* The callee may write to a by-reference record: the caller's copy must
 * not change. */
double big_clobber(Big v) { double s = v.a; v.a = 99; return s + v.a; }
int each_v2(int (*f)(V2, void*), void* ud) { V2 p = { 1.5f, 2.5f }; return f(p, ud); }
B3 each_b3(B3 (*f)(B3, void*), void* ud) { B3 p = { 1, 2, 3 }; return f(p, ud); }
C
clang --target="$triple" -O1 -c "$work/cabi_helper.c" -o "$work/cabi_helper.obj"
mkdir -p "$work/cabi-lib"
llvm-ar rcs "$work/cabi-lib/cabi_helper.lib" "$work/cabi_helper.obj"

cat > "$work/cabi.l" <<'LYR'
package CAbi

record Vec3 {
  x: Float
  y: Float
  z: Float
}
record DI {
  d: Double
  i: Int
}
record Big {
  a: Double
  b: Double
  c: Double
  d: Double
}
record V2 {
  x: Float
  y: Float
}
record B2 {
  a: Byte
  b: Byte
}
record B3 {
  a: Byte
  b: Byte
  c: Byte
}
record I1 {
  a: Int
}

extern func vec3_scale(v: Vec3, k: Float): Vec3 = "vec3_scale"
extern func di_make(d: Double, i: Int): DI = "di_make"
extern func di_sum(v: DI): Double = "di_sum"
extern func big_make(s: Double): Big = "big_make"
extern func big_sum(v: Big): Double = "big_sum"
extern func v2_add(a: V2, b: V2): V2 = "v2_add"
extern func b2_swap(v: B2): B2 = "b2_swap"
extern func b3_rot(v: B3): B3 = "b3_rot"
extern func i1_neg(v: I1): I1 = "i1_neg"
extern func di_seven(a: DI, b: DI, c: DI, d: DI, e: DI, f: DI, g: DI): Double = "di_seven"
extern func big_clobber(v: Big): Double = "big_clobber"
extern func each_v2(f: (V2, NativePtr[Byte]) -> Int, ud: NativePtr[Byte]): Int = "each_v2"
extern func each_b3(f: (B3, NativePtr[Byte]) -> B3, ud: NativePtr[Byte]): B3 = "each_b3"

@unsafe_ffi
func main(): Int {
  val v = vec3_scale(Vec3(x = 1.0f32, y = 2.0f32, z = 3.0f32), 2.0f32)
  if v.x != 2.0f32 or v.y != 4.0f32 or v.z != 6.0f32 {
    return 1
  }
  val di = di_make(1.5, 7)
  if di.d != 1.5 or di.i != 7 or di_sum(di) != 8.5 {
    return 2
  }
  val b = big_make(1.0)
  if b.a != 1.0 or b.b != 2.0 or b.c != 3.0 or b.d != 4.0 or big_sum(b) != 10.0 {
    return 3
  }
  val w = v2_add(V2(x = 1.0f32, y = 2.0f32), V2(x = 0.5f32, y = 0.25f32))
  if w.x != 1.5f32 or w.y != 2.25f32 {
    return 4
  }
  val s = b2_swap(B2(a = 1u8, b = 200u8))
  if s.a != 200u8 or s.b != 1u8 {
    return 5
  }
  val r = b3_rot(B3(a = 7u8, b = 8u8, c = 9u8))
  if r.a != 8u8 or r.b != 9u8 or r.c != 7u8 {
    return 6
  }
  if i1_neg(I1(a = 41)).a != -41 {
    return 7
  }
  val one = DI(d = 1.0, i = 1)
  if di_seven(one, one, one, one, one, one, DI(d = 2.0, i = 3)) != 17.0 {
    return 8
  }
  if big_clobber(b) != 100.0 or b.a != 1.0 {
    return 9
  }
  val scale = 2
  val f: (V2) -> Int = { p: V2 -> ((p.x + p.y) * 10.0f32).toInt() * scale }
  if each_v2(f, f) != 80 {
    return 10
  }
  val g: (B3) -> B3 = { p: B3 -> B3(a = p.c, b = p.a, c = p.b) }
  val back = each_b3(g, g)
  if back.a != 3u8 or back.b != 1u8 or back.c != 2u8 {
    return 11
  }
  0
}
LYR
cat > "$work/lyric.toml" <<'TOML'
[package]
name = "cabi"
version = "0.1.0"

[native.libs.cabi_helper]
dir = "cabi-lib"
TOML
echo "--- by-value records across the C boundary"
(cd "$work" && "$lyric_bin" build cabi.l --target native --triple "$triple" --manifest lyric.toml)
[ -f "$work/cabi.exe" ] || fail "the native build did not write cabi.exe"
set +e
run_exe "$work/cabi.exe"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "cabi.exe exited $rc (the code names the first record that did not cross intact)"

# ── Console, arguments, files, environment, time, threads ───────────────
cat > "$work/platform.l" <<'LYR'
package Platform

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.Environment as Environment
import Std.File as File
import Std.Time as Time
import Std.Parallel as Parallel

protected type Counter {
  var n: Int = 0
  entry add(k: Int): Unit {
    n = n + k
  }
  func value(): Int {
    n
  }
}

func main(): Int {
  Console.println("h\u{e9}llo \u{2603} \u{65e5}\u{672c}")
  val args = Environment.args()
  if args.length != 3 or args[1] != "\u{3bb}-\u{2713}" or args[2] != "two words" {
    Console.println("args: " + toString(args.length))
    return 1
  }
  if not Environment.isWindows() {
    return 2
  }
  val dir = Environment.currentDirectory() + "\\\u{fc}nicode \u{2603}"
  match File.createDir(dir) {
    case Ok(_) -> ()
    case Err(_) -> return 3
  }
  match File.createDir(dir + "\\nested") {
    case Ok(_) -> ()
    case Err(_) -> return 3
  }
  val file = dir + "\\nested\\\u{65e5}\u{672c}.txt"
  match File.writeText(file, "line one\nline two\n") {
    case Ok(_) -> ()
    case Err(_) -> return 4
  }
  match File.readText(file) {
    case Ok(text) -> if text != "line one\nline two\n" {
      return 5
    }
    case Err(_) -> return 6
  }
  match File.listFiles(dir + "\\nested") {
    case Ok(names) -> if names.count != 1 or not File.fileExists(names[0]) {
      return 7
    }
    case Err(_) -> return 8
  }
  match File.deleteDirRecursive(dir) {
    case Ok(_) -> ()
    case Err(_) -> return 9
  }
  if File.dirExists(dir) {
    return 10
  }
  Environment.setVar("LYRIC_E2E_VAR", "\u{3b1}\u{3b2}")
  if Environment.getVarOrDefault("LYRIC_E2E_VAR", "") != "\u{3b1}\u{3b2}" {
    return 11
  }
  val t0 = Time.monotonicNanos()
  Time.sleepMillis(20)
  if Time.monotonicNanos() - t0 < 20000000i64 {
    return 12
  }
  val c = Counter()
  Parallel.forRange(1000, { i: Int -> c.add(i) })
  if c.value() != 499500 {
    return 13
  }
  0
}
LYR
echo "--- console, arguments, files, environment, time, threads"
(cd "$work" && "$lyric_bin" build platform.l --target native --triple "$triple")
[ -f "$work/platform.exe" ] || fail "the native build did not write platform.exe"
set +e
(cd "$work" && run_exe ./platform.exe "λ-✓" "two words") > "$work/platform.out"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "platform.exe exited $rc"
printf 'h\xc3\xa9llo \xe2\x98\x83 \xe6\x97\xa5\xe6\x9c\xac\n' > "$work/platform.want"
cmp "$work/platform.out" "$work/platform.want" || fail "stdout was not the UTF-8 text the program wrote (no CRLF)"

# ── A panic exits with status 3 ─────────────────────────────────────────
cat > "$work/boom.l" <<'LYR'
package Boom

func main(): Int {
  panic("deliberate panic")
}
LYR
echo "--- a panic's exit status"
(cd "$work" && "$lyric_bin" build boom.l --target native --triple "$triple" -o boom-out)
[ -f "$work/boom-out.exe" ] || fail "-o boom-out did not write boom-out.exe"
set +e
run_exe "$work/boom-out.exe" 2> "$work/boom.err"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "a panic exited $rc, not 3"
grep -q "deliberate panic" "$work/boom.err" || fail "the panic message was not printed"

echo "Windows native end-to-end programs passed"
