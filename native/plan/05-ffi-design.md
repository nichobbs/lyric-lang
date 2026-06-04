# 05 — FFI Design

This document specifies `extern func`, `NativePtr[T]`, `NativeWeak[T]`, the C ABI
calling convention rules, callback trampolines, and the `_kernel_native/` boundary.

---

## `extern func` declaration syntax

`extern func` is a new top-level item (parallel to `extern type` in the parser AST).

```lyric
// lyric-stdlib/std/_kernel_native/libc.l

@nativeLib("libc")
package Std.LibcHost

// Simple C functions:
extern func strlen(s: NativePtr[Byte]): Long = "strlen"
extern func write(fd: Int, buf: NativePtr[Byte], n: Long): Long = "write"
extern func read(fd: Int, buf: NativePtr[Byte], n: Long): Long = "read"
extern func open(path: NativePtr[Byte], flags: Int, mode: Int): Int = "open"
extern func close(fd: Int): Int = "close"
extern func malloc(n: Long): NativePtr[Byte] = "malloc"
extern func free(ptr: NativePtr[Byte]): Unit = "free"
extern func exit(code: Int): Unit = "exit"  // noreturn — tagged in Phase 2

// Variadic C functions (Phase 2 — see below):
// extern func printf(fmt: NativePtr[Byte], ...): Int = "printf"
```

### Parser change: `IExternFunc` AST node

The parser gains a new item kind:

```
IExternFunc(decl: ExternFuncDecl)

ExternFuncDecl {
  name:       String
  params:     List[Param]     // (name: String, ty: TypeExpr)
  ret:        Option[TypeExpr]
  symbol:     String          // the "symbol" string after '='
  annotations: List[Annotation]
}
```

Parsing rule:
```
extern func <name> ( <params> ) : <ret> = "<symbol>"
```

The `= "<symbol>"` is mandatory. If omitted, the parser emits a diagnostic.
The symbol is a bare C identifier (no spaces, no dots). If the symbol equals the
function name, it may be written as `= _` as shorthand (optional convenience).

### LLVM IR emission for `extern func`

Each `extern func` declaration in an imported `_kernel_native/` package produces
a `declare` in the LLVM IR module:

```llvm
declare i64 @write(i32 %fd, i8* %buf, i64 %n)
declare i64 @read(i32 %fd, i8* %buf, i64 %n)
declare i32 @open(i8* %path, i32 %flags, i32 %mode)
```

The symbol name in the `declare` is exactly the string from `= "symbol"`. The
parameter names are taken from the Lyric declaration. The types are mapped via
the type mapping in `03-type-mapping.md`.

---

## `NativePtr[T]`

A raw, unmanaged pointer. No ARC header. Not retained, not released.

```llvm
; NativePtr[Byte]  → i8*
; NativePtr[Int]   → i32*
; NativePtr[NativePtr[Byte]] → i8**
; NativePtr[LyricString]     → %LyricString*   (but avoid: prefer managed refs)
```

`NativePtr[T]` is **only valid in**:
1. `_kernel_native/` package files.
2. Functions annotated `@unsafe_ffi`.
3. The `extern func` parameter/return type lists.

The mode checker enforces this. Attempting to use `NativePtr[T]` outside these
contexts is a compile error.

**Conversions:**
- `NativePtr[Byte]` ← from a `String`: `lyric_string_data_ptr(s)` returns the raw
  UTF-8 data pointer (valid only while `s` is alive).
- `NativePtr[Byte]` ← from a `slice[Byte]`: access the `.ptr` field.
- `NativePtr[T]` arithmetic (pointer add/sub): only in `@unsafe_ffi` functions.

---

## C ABI calling convention

The C calling convention (`ccc` in LLVM IR) maps Lyric parameter types to
platform ABI registers/stack slots as follows.

### System V AMD64 ABI (Linux x86-64)

Integer/pointer arguments: first 6 in `rdi, rsi, rdx, rcx, r8, r9` (in order),
remaining on stack.
Float arguments: first 8 in `xmm0..xmm7`.
Return value: integer/pointer in `rax` (or `rdx:rax` for 128-bit).

### AAPCS64 (Linux AArch64, macOS AArch64)

Integer/pointer arguments: first 8 in `x0..x7`.
Float arguments: first 8 in `v0..v7`.
Return value: integer/pointer in `x0`.

**LLVM handles all of this automatically.** The native backend emits LLVM IR with
`ccc` calling convention and the correct LLVM types; clang/LLVM's backend
generates the correct register allocation. The codegen agent does not need to
know the specific register names — just use `ccc` and the right LLVM types.

### Struct passing rules

Small structs (≤ 2 integer/pointer fields, total size ≤ 16 bytes on x86-64 or
AArch64) may be passed in registers by the platform ABI. LLVM handles this via
the `byval` and `sret` attributes.

For `extern func` declarations, the codegen always passes struct arguments by
pointer (`NativePtr[T]`). If a C API accepts a struct by value, the `_kernel_native/`
author is responsible for writing the correct wrapper.

---

## `@unsafe_ffi` annotation

A function annotated `@unsafe_ffi` opts out of the mode checker's normal type
safety rules for its body. It may:
- Accept `NativePtr[T]` parameters.
- Call `extern func` symbols directly.
- Perform raw pointer arithmetic.
- Cast between `NativePtr` types.

```lyric
@unsafe_ffi
func openFile(path: String): Int {
  // withCString returns a NativePtr[Byte] valid for the duration of the call
  withCString(path, func(cpath: NativePtr[Byte]): Int {
    LibcHost.open(cpath, O_RDONLY, 0)
  })
}
```

Functions NOT annotated `@unsafe_ffi` cannot directly call `extern func` symbols.
They must go through the `_kernel_native/` safe wrappers.

---

## `_kernel_native/` boundary structure

```
lyric-stdlib/std/_kernel_native/
  libc.l        — write, read, open, close, malloc, free, exit, errno, strerror
  libm.l        — sin, cos, tan, sqrt, pow, log, exp, fabs, floor, ceil, round
  time.l        — clock_gettime, CLOCK_REALTIME, CLOCK_MONOTONIC definitions
  uuid.l        — getrandom (Linux), CCRandomGenerateBytes (macOS)
  env.l         — getenv, setenv, unsetenv
  process.l     — fork, execvp, posix_spawn, waitpid, pipe, dup2, WEXITSTATUS
  net.l         — socket, connect, bind, listen, accept, send, recv (Phase 2)
  mutex.l       — pthread_mutex_init, lock, unlock, destroy (for protected types)
```

Each file declares:
1. `extern func` symbols for the underlying C API.
2. A thin safe Lyric wrapper that maps the C API to Lyric types (e.g., returns
   `Result[T, String]` instead of `-1` + errno).

Example (safe-wrapper pattern, from `process.l`):

```lyric
@nativeLib("libc")
package Std.ProcessNativeHost

extern func waitpid(pid: Int, status: NativePtr[Int], options: Int): Int = "waitpid"

// Safe wrapper (not extern — pure Lyric):
pub func waitForProcess(pid: Int): Result[Int, String] {
  var status: Int = 0
  val ret = waitpid(pid, nativeAddrOf(status), 0)
  if ret < 0 { Err("waitpid failed") } else { Ok(exitCodeFrom(status)) }
}
```

The public `Std.File`, `Std.Console`, etc. modules import from `_kernel_native/`
when `--target native`, and from `_kernel/` when `--target dotnet`.

**Target-specific import selection:**

The same `Std.Console` source file cannot have two different implementations
of `println`. The solution is a `@cfg(target = "native")`-gated import:

```lyric
// Std.Console:
@cfg(target = "dotnet")
import Std.ConsoleHost as Host        // BCL-backed

@cfg(target = "native")
import Std.ConsoleNativeHost as Host  // kernel_native/-backed
```

This requires extending `Cfg.applyCfgErasure` with a `target` predicate alongside
the existing `feature` predicate. The erasure runs before typechecking, so only
the relevant import survives.

---

## Callback trampolines

When a Lyric closure is passed to a C function as a function pointer, a trampoline
is synthesised. The trampoline is a C-ABI function that unpacks the closure
environment and calls the Lyric closure body.

### Problem

C APIs accept `void (*callback)(void* userdata)`. A Lyric closure is a heap struct
with a function pointer and captured variables. You cannot pass the closure struct
pointer directly as the callback.

### Solution

The compiler synthesises a `@ccc`-convention wrapper for each unique call site
where a Lyric closure is passed as a C callback:

```lyric
// Lyric call:
setTimer(1000, func(): Unit { doSomething() }, null)
// ^ passing a closure where C expects: void (*)(void* userdata)
```

Synthesised LLVM IR:

```llvm
; Trampoline (generated per call site):
define ccc void @__lyric_cb_tramp_0(i8* %userdata) {
entry:
  %closure = bitcast i8* %userdata to %Lyric.Closure_0*
  ; Call the closure's fn_ptr with env_ptr = closure:
  %fn_slot  = getelementptr inbounds %Lyric.Closure_0, %Lyric.Closure_0* %closure, i32 0, i32 2
  %fn_ptr   = load i8*, i8** %fn_slot
  %typed_fn = bitcast i8* %fn_ptr to void (i8*)*
  call void %typed_fn(i8* %userdata)
  ret void
}

; At the call site:
%tramp_ptr = bitcast void (i8*)* @__lyric_cb_tramp_0 to i8*
call void @setTimer(i64 1000, i8* %tramp_ptr, i8* bitcast(%Lyric.Closure_0* %cl to i8*))
```

The trampoline's `userdata` parameter receives the closure struct pointer (which
the kernel layer passes as the `userdata` argument).

**ARC for trampolines:** If the C function holds the callback across multiple
calls (not just for the duration of the original call), the closure must be
retained before passing and released when the C API signals it is done (e.g., a
`free_callback` parameter). The `_kernel_native/` wrapper is responsible for this.

**Variadic C functions** (Phase 2): `printf`, `fprintf`, etc. require varargs
support in LLVM IR (`...` in `declare`). These are not needed for Phase 1 since
`Std.Console.println` uses `write()` directly.

---

## `withCString` helper

Many C functions accept `const char*` (null-terminated, not fat pointer). Lyric
strings are fat pointers with inline data that may or may not be null-terminated.

The `lyric-rt` library provides:

```c
// lyric-rt/src/lyric_string.c
// Returns a temporary NUL-terminated copy of the string data.
// The returned pointer is valid until lyric_cstring_free is called.
const char* lyric_string_to_cstring(LyricString* s) {
    char* buf = (char*)malloc(s->len + 1);
    if (!buf) lyric_panic_msg("OOM in lyric_string_to_cstring", __FILE__, __LINE__);
    memcpy(buf, LYRIC_STRING_DATA(s), s->len);
    buf[s->len] = '\0';
    return buf;
}
void lyric_cstring_free(const char* p) { free((void*)p); }
```

The Lyric `withCString` helper (in `_kernel_native/libc.l`):

```lyric
pub func withCString[T](s: String, f: func(NativePtr[Byte]): T): T {
  val cstr = LibcHost.stringToCString(s)
  val result = f(cstr)
  LibcHost.cstringFree(cstr)
  result
}
```

This ensures the C string is freed even if `f` panics (once `defer` lands in
Phase 2, this can be rewritten with `defer LibcHost.cstringFree(cstr)`).
