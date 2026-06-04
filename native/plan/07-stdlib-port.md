# 07 — Stdlib Port Analysis

For each module in `lyric-stdlib/std/_kernel/`, this document classifies:

- **Pure Lyric** — depends on no BCL externs; should work on native automatically
  once the type system and collections are implemented.
- **Needs `_kernel_native/`** — has BCL externs that need POSIX/libm replacements.
- **Deferred** — depends on features not in Phase 1 scope (async, HTTP server, etc.).
- **N/A** — JVM-specific; does not apply to native.

---

## Classification table

| `_kernel/` file | Classification | Native equivalent | Notes |
|---|---|---|---|
| `console_host.l` | Needs `_kernel_native/` | `write(STDOUT_FILENO, ...)` | `Std.Console` |
| `file_host.l` | Needs `_kernel_native/` | `open/read/write/close/stat/mkdir` | `Std.File`, `Std.Directory` |
| `math_host.l` | Needs `_kernel_native/` | `libm`: `sin/cos/sqrt/pow/...` | `Std.Math` |
| `time_host.l` | Needs `_kernel_native/` | `clock_gettime(CLOCK_REALTIME)` | `Std.Time` |
| `uuid_host.l` | Needs `_kernel_native/` | `getrandom` (Linux) / `CCRandomGenerateBytes` (macOS) | `Std.Uuid` |
| `environment_host.l` | Needs `_kernel_native/` | `getenv/setenv/unsetenv` | `Std.Environment` |
| `process_host.l` | Needs `_kernel_native/` | `fork/execvp/posix_spawn/waitpid` | `Std.Process` |
| `process_capture_host.l` | Needs `_kernel_native/` | `pipe/dup2` + process.l | `Std.ProcessCapture` |
| `path_host.l` | Mostly pure Lyric | Detect `/` vs `\` from triple | `Std.Path` |
| `format_host.l` | Pure Lyric | No BCL calls; pure string ops | `Std.Format` |
| `parse_host.l` | Needs check | BCL `int.Parse` etc. → pure Lyric impl | `Std.Parse` |
| `hash_host.l` | Pure Lyric | SipHash/FNV — no BCL needed | `Std.Hash` |
| `random_host.l` | Mostly pure | xoshiro256++ seed from `getrandom` | `Std.Random` |
| `secure_random_host.l` | Needs `_kernel_native/` | `getrandom` / `/dev/urandom` | `Std.SecureRandom` |
| `encoding_host.l` | Pure Lyric | base64 is pure math | `Std.Encoding` |
| `char_host.l` | Needs check | BCL `Char.IsLetter` etc. → Unicode tables | `Std.Char` |
| `unicode_host.l` | Needs check | NFC/NFD normalization → Unicode tables | `Std.Unicode` |
| `collections_host.l` | Needs `_kernel_native/` | Native List/Map implementation | `Std.Collections` |
| `log_host.l` | Pure Lyric | Writes to stderr/stdout — wraps console | `Std.Log` |
| `io.l` | Needs `_kernel_native/` | POSIX fd-based I/O | `Std.Io` |
| `task.l` | Deferred (Phase 2) | `lyric-rt` async scheduler | `Std.Task` |
| `http_host.l` | Deferred (Phase 2) | libcurl or socket-based | `Std.Http` |
| `http_server.l` | Deferred (Phase 2) | Major: needs async + I/O | `Std.HttpServer` |
| `assembly_resources_host.l` | N/A | .NET-only; no native equivalent | — |
| `jvm.l` | N/A | JVM-specific | — |
| `jvm_exception.l` | N/A | JVM-specific | — |
| `verifier_env_host.l` | Needs `_kernel_native/` | Uses `process.l` for Z3 subprocess | `Std.VerifierEnv` |
| `testing_mocking.l` | Pure Lyric | No BCL calls; test infrastructure | `Std.Testing` |
| `regex_host.l` | Deferred | Needs a regex library | `Std.Regex` |

---

## Modules the native target gets "for free"

These modules have no BCL externs. Once the basic type system (records, unions,
strings, collections) works for native, these modules compile and run without
modification:

- `Std.Core` (Option, Result, Bool ops)
- `Std.Json` (pure-Lyric JSON 1.0 parser)
- `Std.Xml` (pure-Lyric XML 1.0 parser, D065)
- `Std.Yaml` (pure-Lyric YAML 1.2 parser, D065)
- `Std.Format` (string formatting combinators)
- `Std.Encoding` (base64 encode/decode)
- `Std.Testing` (assertion helpers, mock infrastructure)
- `Std.Log` (structured logging — wraps `Std.Console` for output)
- `Std.Hash` (SipHash 2-4, FNV-1a — pure integer ops)

---

## Phase 1 `_kernel_native/` implementations

### `console_native.l`

```lyric
@nativeLib("libc")
package Std.ConsoleNativeHost

extern func write_fd(fd: Int, buf: NativePtr[Byte], n: Long): Long = "write"

pub val STDOUT: Int = 1
pub val STDERR: Int = 2

pub func consoleWriteln(s: String): Unit {
  withCString(s, func(cs: NativePtr[Byte]): Unit {
    write_fd(STDOUT, cs, strlen(cs))
    write_fd(STDOUT, newlinePtr, 1)
  })
}
```

### `math_native.l`

```lyric
@nativeLib("m")
package Std.MathNativeHost

extern func sin(x: Double): Double = "sin"
extern func cos(x: Double): Double = "cos"
extern func sqrt(x: Double): Double = "sqrt"
extern func pow(base_: Double, exp: Double): Double = "pow"
extern func fabs(x: Double): Double = "fabs"
extern func floor(x: Double): Double = "floor"
extern func ceil(x: Double): Double = "ceil"
extern func log(x: Double): Double = "log"
extern func log2(x: Double): Double = "log2"
extern func exp(x: Double): Double = "exp"
```

### `time_native.l`

```lyric
package Std.TimeNativeHost

// struct timespec { time_t tv_sec; long tv_nsec; }
// On 64-bit: both fields are i64
extern func clock_gettime(clockId: Int, ts: NativePtr[Long]): Int = "clock_gettime"

pub val CLOCK_REALTIME: Int = 0
pub val CLOCK_MONOTONIC: Int = 1

pub func epochMillis(): Long {
  var ts: slice[Long] = newSlice(2)
  clock_gettime(CLOCK_REALTIME, ts.ptr)
  ts[0] * 1000 + ts[1] / 1000000
}
```

### `file_native.l`

```lyric
@nativeLib("libc")
package Std.FileNativeHost

// Open flags: values are platform-specific (e.g. O_CREAT is 0x40 on Linux x86-64
// but 0x200 on macOS). lyric-rt exposes them via C helper functions defined in
// lyric-rt/src/lyric_posix.c so the Lyric layer never hardcodes platform constants.
extern func lyric_o_rdonly(): Int = "lyric_o_rdonly"
extern func lyric_o_wronly(): Int = "lyric_o_wronly"
extern func lyric_o_rdwr():   Int = "lyric_o_rdwr"
extern func lyric_o_creat():  Int = "lyric_o_creat"
extern func lyric_o_trunc():  Int = "lyric_o_trunc"

pub val O_RDONLY: Int = lyric_o_rdonly()
pub val O_WRONLY: Int = lyric_o_wronly()
pub val O_RDWR:   Int = lyric_o_rdwr()
pub val O_CREAT:  Int = lyric_o_creat()
pub val O_TRUNC:  Int = lyric_o_trunc()

extern func open(path: NativePtr[Byte], flags: Int, mode: Int): Int = "open"
extern func close(fd: Int): Int = "close"
extern func read(fd: Int, buf: NativePtr[Byte], n: Long): Long = "read"
extern func write(fd: Int, buf: NativePtr[Byte], n: Long): Long = "write"
extern func unlink(path: NativePtr[Byte]): Int = "unlink"
extern func mkdir(path: NativePtr[Byte], mode: Int): Int = "mkdir"
extern func rmdir(path: NativePtr[Byte]): Int = "rmdir"

// stat64 layout is architecture-specific; use a helper for st_size
extern func lyric_file_size(path: NativePtr[Byte]): Long = "lyric_file_size"
```

The `lyric_o_*` and `lyric_file_size` helpers are C wrappers in
`lyric-rt/src/lyric_posix.c` that return the correct platform constants and
abstract platform-specific struct layouts. This pattern is required for all
values that differ between Linux x86-64 and macOS AArch64 (Phase 1 targets).

### `uuid_native.l`

```lyric
package Std.UuidNativeHost

// getrandom(2) fills a buffer with cryptographically secure random bytes
extern func getrandom(buf: NativePtr[Byte], buflen: Long, flags: Int): Long = "getrandom"

pub func fillRandomBytes(buf: slice[Byte]): Bool {
  val n = getrandom(buf.ptr, buf.length.toLong(), 0)
  n == buf.length.toLong()
}
```

On macOS, `getrandom` was added in macOS 10.12 (Sierra). The fallback is
`/dev/urandom`. Phase 1 targets macOS 12+, so `getrandom` is always present.

### `collections_native.l`

The most complex kernel port. Provides:

- `lyric_list_new() → List*`
- `lyric_list_push(list: List*, val: i8*)` — retains val
- `lyric_list_get(list: List*, idx: Long) → i8*` — returns retained value
- `lyric_list_len(list: List*) → Long`
- `lyric_list_dtor(obj: i8*) → void` — releases all elements, frees data array

- `lyric_map_new() → Map*`
- `lyric_map_set(map: Map*, key: i8*, val: i8*)` — retains both
- `lyric_map_get(map: Map*, key: i8*) → Option[i8*]`
- `lyric_map_remove(map: Map*, key: i8*) → Bool`
- `lyric_map_len(map: Map*) → Long`

These are implemented in `lyric-rt/src/lyric_collections.c` in C (for correctness
and to bootstrap before `Std.Collections` itself is compilable from Lyric source).

The `Map` hash function for `LyricString*` keys: SipHash-2-4 over the UTF-8 data.
For integer keys: multiplication by a Fibonacci hash constant.

---

## Target-conditional imports: `@cfg(target = ...)`

`Std.Console`, `Std.Math`, `Std.File`, etc. must import different kernel modules
depending on `--target`. The `Cfg.applyCfgErasure` pass needs to be extended
to support a `target` predicate:

```lyric
@cfg(target = "dotnet")
import Std.ConsoleHost as ConsoleImpl

@cfg(target = "jvm")
import Std.ConsoleJvmHost as ConsoleImpl

@cfg(target = "native")
import Std.ConsoleNativeHost as ConsoleImpl
```

**Implementation:** The `ActiveFeatures` set in `CfgErasureInput` is extended
to include the current target as a pseudo-feature named `target.<name>`:

- `--target dotnet` → `"target.dotnet"` in active set
- `--target jvm`    → `"target.jvm"` in active set
- `--target native` → `"target.native"` in active set

The `@cfg(target = "native")` predicate is parsed as a feature predicate with
key `"target"` and value `"native"`, which resolves to the pseudo-feature
`"target.native"`. This requires a minor update to `lyric-compiler/lyric/cfg.l` (`Lyric.Cfg`).
The F# bootstrap `Cfg.fs` does **not** need updating — the native target is
only reachable through the self-hosted Lyric CLI (see N4.6).

---

## Phase 1 stdlib gate

Not all stdlib modules need to work for Phase 1. The gate:

**Phase 1 (must work):**
- `Std.Core`, `Std.Collections`, `Std.String`, `Std.Char`
- `Std.Console`, `Std.File`, `Std.Path`, `Std.Environment`
- `Std.Math`, `Std.Time`, `Std.Uuid`
- `Std.Process`, `Std.Format`, `Std.Encoding`
- `Std.Json`, `Std.Xml`, `Std.Yaml` (pure Lyric, free)
- `Std.Hash`, `Std.Random`
- `Std.Testing` (for running `lyric test --target native`)

**Phase 2:**
- `Std.Http`, `Std.HttpServer` (async + I/O)
- `Std.Async`, `Std.Task`
- `Std.Regex` (needs a regex library)
- `Std.Io` (POSIX I/O streams, buffered)

**Not applicable:**
- `Std.AssemblyResources` (.NET-specific)
- `Std.Jvm` (JVM-specific)
