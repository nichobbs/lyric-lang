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
#   - child processes: captured runs with stdin and a deadline, an
#     inherited run, a piped child, quoted and non-ASCII arguments;
#   - TCP sockets, and HTTPS through Schannel with a pinned CA (and refused
#     under system trust);
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
# The programs build in a scratch directory outside the checkout, so the
# compiler's walk up from the working directory cannot find the stdlib
# sources; name them (the documented override for installers and CI).
if [ -z "${LYRIC_STD_PATH:-}" ]; then
  LYRIC_STD_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lyric-stdlib/std"
  if command -v cygpath >/dev/null 2>&1; then
    LYRIC_STD_PATH="$(cygpath -m "$LYRIC_STD_PATH")"
  fi
  export LYRIC_STD_PATH
fi
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

# ── Child processes ─────────────────────────────────────────────────────
# The program runs itself as the child (`--child <mode>`), so the test needs
# no shell or POSIX tools.
cat > "$work/procs.l" <<'LYR'
package Procs

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.Environment as Environment
import Std.Process
import Std.Time as Time

func childMain(args: in slice[String]): Int {
  val mode = args[2]
  if mode == "echo" {
    var line = ""
    var i = 3
    while i < args.length {
      if i > 3 {
        line = line + "|"
      }
      line = line + args[i]
      i = i + 1
    }
    Console.println(line)
    return 0
  }
  if mode == "exit" {
    return 5
  }
  if mode == "cat" {
    // Streams stdin back as it arrives (Console.readLine is not available on
    // the native target yet, #7968).
    val r = Console.openStdinReader()
    var going = true
    while going {
      match Console.readStdin(r) {
        case Ok(chunk) -> match chunk {
          case Some(bytes) -> Console.writeStdoutBytes(bytes)
          case None -> {
            going = false
          }
        }
        case Err(_) -> return 1
      }
    }
    return 0
  }
  if mode == "sleep" {
    Console.println("pre")
    Time.sleepMillis(30000)
    return 0
  }
  9
}

func listOf(items: in slice[String]): List[String] {
  val l: List[String] = []
  for s in items {
    l.add(s)
  }
  l
}

func main(): Int {
  val args = Environment.args()
  if args.length > 2 and args[1] == "--child" {
    return childMain(args)
  }
  val exe = Environment.appBaseDirectory() + "\\procs.exe"

  match runCapture(exe, listOf(["--child", "echo", "a b", "c\"d", "tr\\", "", "\u{3bb} \u{2713}"]), 10000) {
    case Ok(r) -> if r.stdout != "a b|c\"d|tr\\||\u{3bb} \u{2713}\n" or r.exitCode != 0 or r.timedOut {
      Console.println("echo: [" + r.stdout + "]")
      return 1
    }
    case Err(e) -> {
      Console.println("echo: " + e)
      return 1
    }
  }
  match runCapture(exe, listOf(["--child", "exit"]), 10000) {
    case Ok(r) -> if r.exitCode != 5 {
      return 2
    }
    case Err(_) -> return 2
  }
  match runCaptureWithInput(exe, listOf(["--child", "cat"]), "one\ntwo \u{e9}\n", 10000) {
    case Ok(r) -> if r.stdout != "one\ntwo \u{e9}\n" {
      return 3
    }
    case Err(_) -> return 3
  }
  match runCapture(exe, listOf(["--child", "sleep"]), 300) {
    case Ok(r) -> if not r.timedOut or r.exitCode != 0 - 2 or r.stdout != "pre\n" {
      Console.println("timeout: " + toString(r.exitCode) + " [" + r.stdout + "]")
      return 4
    }
    case Err(_) -> return 4
  }
  match runCapture(Environment.appBaseDirectory() + "\\no-such-program.exe", listOf([]), 10000) {
    case Ok(_) -> return 5
    case Err(_) -> ()
  }
  match run(exe, listOf(["--child", "exit"])) {
    case Ok(code) -> if code != 5 {
      return 6
    }
    case Err(_) -> return 6
  }
  match spawnPiped(exe, listOf(["--child", "cat"])) {
    case Ok(p) -> {
      match pipedWriteLine(p, "ping") {
        case Ok(_) -> ()
        case Err(_) -> return 7
      }
      match pipedReadLine(p) {
        case Ok(line) -> if line != Some(value = "ping") {
          return 8
        }
        case Err(_) -> return 8
      }
      match pipedReadLineWithin(p, 100) {
        case Ok(outcome) -> match outcome {
          case PipedTimedOut -> ()
          case _ -> return 9
        }
        case Err(_) -> return 9
      }
      pipedCloseStdin(p)
      if not pipedWaitExit(p, 10000) or pipedExitCode(p) != 0 {
        return 10
      }
      pipedClose(p)
    }
    case Err(_) -> return 7
  }
  match spawnPiped(exe, listOf(["--child", "sleep"])) {
    case Ok(p) -> {
      pipedKill(p)
      if pipedIsAlive(p) {
        return 11
      }
      pipedClose(p)
    }
    case Err(_) -> return 11
  }
  0
}
LYR
echo "--- child processes"
(cd "$work" && "$lyric_bin" build procs.l --target native --triple "$triple")
[ -f "$work/procs.exe" ] || fail "the native build did not write procs.exe"
set +e
run_exe "$work/procs.exe"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "procs.exe exited $rc (the code names the first process check that failed)"

# ── Sockets and TLS ─────────────────────────────────────────────────────
# A plain TCP round trip, then an HTTPS request to a Std.HttpServer TLS
# listener from a client thread trusting only the test CA (the PKI of
# lyric-rt/test/lyric_tls_test.c), and the same server refused under system
# trust, since the test CA is not a Windows root.  The server imports its key
# for Schannel, so this needs a real Windows host, not wine.
cat > "$work/ca.pem" <<'PEM'
-----BEGIN CERTIFICATE-----
MIIBiDCCAS2gAwIBAgIUa+UpO+C7R20rI5EBFHE/liAYeiswCgYIKoZIzj0EAwIw
GDEWMBQGA1UEAwwNTHlyaWMgVGVzdCBDQTAgFw0yNjA3MTgxOTQ2MjRaGA8yMTI2
MDYyNDE5NDYyNFowGDEWMBQGA1UEAwwNTHlyaWMgVGVzdCBDQTBZMBMGByqGSM49
AgEGCCqGSM49AwEHA0IABOsG7U338C1RcPt/OL4O3ounT3ygztqag26oIgpLYCA5
HVYYjOlEEKjUGJhBGcXzw0jpRQDMFCJGHtOMVcJ/enCjUzBRMB0GA1UdDgQWBBSU
EMVcBV+x/jMMGEnxGJYtMHl6yTAfBgNVHSMEGDAWgBSUEMVcBV+x/jMMGEnxGJYt
MHl6yTAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0kAMEYCIQCCOWeAOliu
Xj1/18e9zSHEUq+gjgwtWl5N/aGfwUIsqAIhAJ50wTwnR+83mTgInxVGy7Jbua7a
bc4iHgt6W2u9CR9k
-----END CERTIFICATE-----
PEM
cat > "$work/server.pem" <<'PEM'
-----BEGIN CERTIFICATE-----
MIIBjjCCATSgAwIBAgIUdUB+lVYMzv9aImIC8blgtl9VikEwCgYIKoZIzj0EAwIw
GDEWMBQGA1UEAwwNTHlyaWMgVGVzdCBDQTAgFw0yNjA3MTgxOTQ2MjRaGA8yMTI2
MDYyNDE5NDYyNFowFDESMBAGA1UEAwwJbG9jYWxob3N0MFkwEwYHKoZIzj0CAQYI
KoZIzj0DAQcDQgAEMo21Zj5ZUUrALT8gSA1nupzAxi9RYgD41XgYmknmSNxY5hpa
02KW7RjFrZYho3FjQwjhf+QssXdneFf+uIJiY6NeMFwwGgYDVR0RBBMwEYIJbG9j
YWxob3N0hwR/AAABMB0GA1UdDgQWBBTv8kqnlNk2k2rm+6j+DL471IR2/jAfBgNV
HSMEGDAWgBSUEMVcBV+x/jMMGEnxGJYtMHl6yTAKBggqhkjOPQQDAgNIADBFAiEA
wQM23cqOw7M0G8ThjJ8aDDzfAJmgHM2/T4mfv0c1c9MCIHUelTrjNTDDiDCXjI3F
LXnijJTPgm/DrWzfDHoMzD2l
-----END CERTIFICATE-----
PEM
cat > "$work/server-key.pem" <<'PEM'
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgiqxrZ6ywX4KddmSt
rmk/qY9bMTRjkRmANXEUmf9UUiGhRANCAAQyjbVmPllRSsAtPyBIDWe6nMDGL1Fi
APjVeBiaSeZI3FjmGlrTYpbtGMWtliGjcWNDCOF/5Cyxd2d4V/64gmJj
-----END PRIVATE KEY-----
PEM
cat > "$work/net.l" <<'LYR'
package Net

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.Encoding
import Std.File as File
import Std.Tls
import Std.TcpHost
import Std.HttpServer

extern func threadCreate(tid: NativePtr[Long], start: (NativePtr[Byte]) -> NativePtr[Byte], arg: NativePtr[Byte]): Int = "lyric_thread_create"
extern func threadJoin(tid: Long, retval: NativePtr[NativePtr[Byte]]): Int = "lyric_thread_join"
extern func toC(s: String): NativePtr[Byte] = "lyric_string_to_cstring"
extern func cStrlen(p: NativePtr[Byte]): Long = "lyric_cstr_len"
extern func fromBytes(p: NativePtr[Byte], n: Long): String = "lyric_string_from_literal"
extern func freeC(p: NativePtr[Byte]): Unit = "lyric_cstring_free"

func readText(path: in String): String {
  match File.readText(path) {
    case Ok(t) -> t
    case Err(_) -> ""
  }
}

func plainRoundTrip(): Int {
  val listener = match hostListen("127.0.0.1", 0) {
    case Ok(l) -> l
    case Err(_) -> return 1
  }
  val port = hostLocalPort(listener)
  val client = match hostConnect("localhost", port) {
    case Ok(c) -> c
    case Err(_) -> return 2
  }
  val server = match hostAccept(listener) {
    case Ok(c) -> c
    case Err(_) -> return 3
  }
  match hostWrite(client, encodeUtf8("ping \u{e9}")) {
    case Ok(_) -> ()
    case Err(_) -> return 4
  }
  var got = ""
  match hostRead(server, 64) {
    case Ok(bytes) -> match tryDecodeUtf8(bytes) {
      case Some(t) -> {
        got = t
      }
      case None -> ()
    }
    case Err(_) -> ()
  }
  hostClose(client)
  hostClose(server)
  hostCloseListener(listener)
  if got != "ping \u{e9}" {
    return 5
  }
  0
}

@unsafe_ffi
func httpsClient(port: in Int, caPem: in String): NativePtr[Byte] {
  val conn = match hostConnectTls("localhost", port, TlsTrustExclusive(caPem = caPem), None, TlsVersion.Tls12, "http/1.1") {
    case Ok(c) -> c
    case Err(e) -> return toC("handshake: " + e.message())
  }
  if hostAlpn(conn) != "http/1.1" {
    hostClose(conn)
    return toC("alpn: " + hostAlpn(conn))
  }
  val req = "POST /submit HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\nConnection: close\r\n\r\nabcd"
  match hostWrite(conn, encodeUtf8(req)) {
    case Ok(_) -> ()
    case Err(_) -> {
      hostClose(conn)
      return toC("write")
    }
  }
  var acc = ""
  var tries = 0
  var done = false
  while tries < 400 and not done {
    match hostRead(conn, 4096) {
      case Ok(b) -> {
        if b.length == 0 {
          done = true
        }
        match tryDecodeUtf8(b) {
          case Some(s) -> {
            acc = acc + s
          }
          case None -> ()
        }
      }
      case Err(e) -> {
        acc = acc + "[read failed after " + tries.toString() + " read(s): " + e.message() + "]"
        done = true
      }
    }
    if acc.contains("true") {
      done = true
    }
    tries = tries + 1
  }
  hostClose(conn)
  if acc.startsWith("HTTP/1.1 201") and acc.contains("true") {
    toC("PASS")
  } else {
    toC("response: " + acc)
  }
}

@unsafe_ffi
func httpsRoundTrip(port: in Int, caPem: in String, certPem: in String, keyPem: in String): Int {
  val identity = match Identity.fromPem(certPem, keyPem) {
    case Ok(id) -> id
    case Err(_) -> return 10
  }
  val cfg = TlsServerConfig(identity = identity, minVersion = TlsVersion.Tls12)
  val listener = match startListenerTls("127.0.0.1", port, cfg) {
    case Ok(l) -> l
    case Err(e) -> {
      Console.error("listen: " + e.message())
      return 11
    }
  }
  var tid: Long = 0
  val worker: () -> NativePtr[Byte] = { -> httpsClient(port, caPem) }
  if threadCreate(nativeAddrOf(tid), worker, worker) != 0 {
    stopListener(listener)
    return 12
  }
  val ctx = nextContext(listener)
  var code = 0
  if requestMethod(ctx) != "POST" or requestPath(ctx) != "/submit" or requestBody(ctx) != "abcd" {
    Console.error(
      "server: got " + requestMethod(ctx) + " " + requestPath(ctx) + " with body '" + requestBody(ctx) + "'"
    )
    code = 13
  }
  respondJson(ctx, 201, "{\"ok\":true}")
  var reply: NativePtr[Byte] = nativeNullPtr()
  if threadJoin(tid, nativeAddrOf(reply)) != 0 {
    return 14
  }
  val result = fromBytes(reply, cStrlen(reply))
  freeC(reply)
  // The same server, trusted only through the system store, is refused:
  // its root is not one the system trusts.
  match hostConnectTls("localhost", port, TlsTrustSystemDefault, None, TlsVersion.Tls12, "") {
    case Ok(c) -> {
      hostClose(c)
      code = 16
    }
    case Err(_) -> ()
  }
  stopListener(listener)
  if result != "PASS" {
    Console.error("client: " + result)
    return 15
  }
  code
}

func main(): Int {
  val caPem = readText("ca.pem")
  val certPem = readText("server.pem")
  val keyPem = readText("server-key.pem")
  val p = plainRoundTrip()
  if p != 0 {
    return p
  }
  httpsRoundTrip(19731, caPem, certPem, keyPem)
}
LYR
echo "--- sockets and TLS"
(cd "$work" && "$lyric_bin" build net.l --target native --triple "$triple")
[ -f "$work/net.exe" ] || fail "the native build did not write net.exe"
set +e
(cd "$work" && run_exe ./net.exe)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "net.exe exited $rc (1-5: plain TCP, 10-16: HTTPS)"

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
