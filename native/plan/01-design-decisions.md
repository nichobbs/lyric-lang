# 01 — Design Decisions

All architectural decisions for the native backend. Every implementation agent
must read this document before beginning work. Do not override a decision without
updating this file and the decision log (`docs/03-decision-log.md`).

---

## D-N-001: LLVM integration strategy

**Decision: Emit `.ll` textual IR, shell out to `clang` as a universal driver.**

The Lyric compiler writes one `.ll` file per compilation unit to a temp directory.
Then it shells out:

```sh
clang -O2 -o <output> <input.ll> lyric_rt.a -lm -lpthread
```

For cross-compilation:

```sh
clang --target=aarch64-unknown-linux-gnu -O2 -o <output> <input.ll> lyric_rt.a
```

**Rationale:**

- `clang` is the most widely available LLVM tool. On macOS it ships with Xcode
  CLI tools (zero install). On Linux it is a single `apt install clang`. `llc`
  and `lld` are NOT bundled with clang and require a separate full LLVM install.
- The Lyric compiler has **zero runtime dependency on LLVM headers or libraries**.
  LLVM version upgrades do not require recompiling the Lyric compiler.
- `clang` handles optimization, object emission, linking, ABI, startup code, and
  platform detection automatically. A single tool call replaces three steps.
- The `.ll` format is stable across LLVM major versions (IR changes are additive
  and the `target datalayout` + `target triple` headers handle the differences).

**What clang does for us:**

1. Parses the `.ll` IR.
2. Runs LLVM optimization passes at the requested `-O` level.
3. Emits target-specific machine code.
4. Invokes the platform linker (ld/LLD on Linux, ld64 on macOS, link.exe on Windows).
5. Links `lyric_rt.a`, `libm`, `libpthread`, and any native dependencies.

**When `clang` is not found:** The compiler emits a diagnostic naming the missing
tool and links to installation instructions. Emission of the `.ll` file still
succeeds; the user can feed it to clang manually.

---

## D-N-002: Union/tagged-union memory layout

**Decision: In-place tagged struct — discriminant integer field + inline max-sized payload.**

```
// Union Option[Int] → after monomorphization:
%Lyric.Option_Int = type {
  i32,      ; ARC rc (in LyricObjectHeader)
  i8*,      ; destructor pointer (in LyricObjectHeader)
  i32,      ; discriminant: 0=None, 1=Some
  [4 x i8]  ; payload: max(sizeof(None payload=0), sizeof(Some payload=Int=4)) = 4
}
```

Every union value is heap-allocated (because it contains an ARC header). The
payload slot is large enough for the largest case. At runtime, the actual case
bytes occupy only the leading `sizeof(case_payload)` bytes of the payload slot;
the rest is padding.

**Pattern matching:** Load the discriminant, emit an LLVM `switch`, bitcast the
payload pointer to the concrete case type.

**Recursive union types (e.g., linked list):** The recursive field must be a
pointer (`NativePtr[Node]` or `Node` where `Node` is a record/union). The inner
allocation has its own ARC header. No special handling needed.

**Rationale:**

- No extra heap allocation for the union container beyond the value itself.
- Can eventually be stack-allocated (escape analysis pass, Phase 3).
- Matches Rust's `enum`, C's tagged union, and Swift's `enum with associated values`.
- The monomorphizer knows payload sizes at compile time.

---

## D-N-003: Panic / exception model

**Decision: Panics call `lyric_panic_msg()` which writes to stderr and calls `abort()`. No stack unwinding. No `defer` in Phase 1.**

The following conditions trigger a panic:

- Contract `requires` clause violation
- Contract `ensures` clause violation
- Explicit `panic(msg)` call
- Slice/array bounds check failure (when bounds checks are enabled)
- Arithmetic overflow (Int/Long overflow, if enabled via `@checked_arithmetic`)
- `lyric_alloc` returning null (OOM)

All panics produce:

```
lyric panic at <file>:<line>: <message>
```

then `abort()`. The OS cleans up all resources (file handles, sockets, memory).

**Why not LLVM landingpad / C++ ABI:**

Landingpads require DWARF unwind tables in every function, a personality function,
and `libunwind`. This adds ~20% binary size, measurable compile-time overhead,
and a hard platform dependency. `abort()` is literally one instruction after the
diagnostic write.

**Phase 2: `defer` and cleanup landingpads.** If `defer` is added to the language,
a cleanup-only personality function (`__lyric_cleanup_personality`) can be added.
`defer` blocks would use `invoke`/`landingpad cleanup` to run on unwind. The
architecture is compatible — cleanup landingpads do not expose `catch` to user
code.

---

## D-N-004: Async / await strategy

**Decision: LLVM coro.* intrinsics (stackless coroutines). Implementation is Phase 2; mechanism is fully specified in `06-async-design.md`.**

All implementation decisions for async are resolved and documented in
`06-async-design.md`. Phase 1 agents must emit a clear compiler error for
`async func` targeting `--target native`:

```
N0099: async functions are not yet supported for --target native.
       Use --target dotnet or --target jvm for async programs.
       Native async is tracked in [issue link].
```

The front-end identifies async functions (already done in parser/type checker).
The codegen check is: if `isAsync` on a `FunctionDecl` and `target == Native`,
emit `N0099` and abort the compilation. Do not attempt to lower it.

---

## D-N-005: ARC cycle collection policy

**Decision: `NativeWeak[T]` is the only cycle-breaking mechanism. No background cycle detector in Phase 1.**

A strong reference to T increments RC. A `NativeWeak[T]` does not increment RC.
`NativeWeak[T].upgrade()` returns `Option[T]`: `None` if the object was freed
(RC reached zero via strong refs), `Some` if still alive.

**Future static prevention:** The mode checker can be extended to detect when a
type graph can reach itself through strong reference fields and require `NativeWeak`
annotations. This analysis is purely additive — it does not change runtime
behaviour, only adds compile-time enforcement. `NativeWeak[T]` remains the fix
regardless of how it is detected.

---

## D-N-006: String representation

**Decision: RC-managed heap object with inline UTF-8 data.**

```c
// C layout (lyric-rt/lyric_rt.h):
typedef struct {
    atomic_int rc;        // reference count
    void (*dtor)(void*);  // always lyric_string_dtor
    int64_t len;          // byte count (not char count)
    int64_t cap;          // allocated bytes (excluding header)
    // UTF-8 bytes follow immediately (flexible array member)
} LyricString;
```

```llvm
; LLVM IR type:
%LyricString = type { i32, i8*, i64, i64 }
; (data follows immediately after this struct in the allocation)
```

**String literals:** Emitted as `[N x i8]` constants in static storage. At
compile time, the emitter synthesises a static `LyricString` header wrapping each
literal, with `rc = INT32_MAX` (saturated — never freed) and `len = N`.

**String slice (borrowed view):** Not a separate Lyric type in Phase 1. The
underlying `LyricString*` is passed directly. Phase 2 can add a `StringSlice`
borrowed view type.

**Concatenation:** `a ++ b` calls `lyric_string_concat(a, b)` in `lyric-rt`,
which allocates a new string, copies, releases neither (caller retains ownership
of inputs).

---

## D-N-007: FFI / extern func syntax

**Decision: New `extern func name(args): Ret = "symbol"` declaration form. Used only in `_kernel_native/` files.**

```lyric
// lyric-stdlib/std/_kernel_native/libc.l
@nativeLib("libc")
package Std.LibcHost

extern func write(fd: Int, buf: NativePtr[Byte], n: Long): Long = "write"
extern func read(fd: Int, buf: NativePtr[Byte], n: Long): Long = "read"
extern func open(path: NativePtr[Byte], flags: Int, mode: Int): Int = "open"
extern func close(fd: Int): Int = "close"
```

**Emitted LLVM IR:**

```llvm
declare i64 @write(i32 %fd, i8* %buf, i64 %n)
declare i64 @read(i32 %fd, i8* %buf, i64 %n)
```

**`@nativeLib("name")` annotation** on the package declaration is informational
for tooling and documentation. In Phase 1, clang's default library search resolves
the symbols. In Phase 2, the linker invocation can be extended to pass explicit
`-l<name>` flags derived from `@nativeLib` annotations in the active packages.

**Parser change required:** The parser must recognise `extern func` as a new item
kind (`IExternFunc` in the AST), parallel to the existing `IExternType`. The
existing `@externTarget` annotation machinery is NOT reused — it is BCL-specific
and confuses BCL member-qualified names with bare C symbol names. The two
annotation systems coexist:

| Annotation | Backend | Symbol form |
|---|---|---|
| `@externTarget("System.IO.File.ReadAllText")` | .NET only | Type-qualified BCL member |
| `extern func name(...) = "symbol"` | native only | Bare C symbol name |

**Safety boundary:** `NativePtr[T]` arguments may only appear in `extern func`
declarations and in functions annotated `@unsafe_ffi`. The mode checker enforces
this. The `_kernel_native/` public Lyric API wraps each extern in a safe Lyric
function that does not expose `NativePtr[T]` to callers.

---

## D-N-008: Platform Phase 1 scope

**Decision: Linux x86-64, Linux AArch64, macOS AArch64. Windows deferred to Phase 2.**

LLVM target triples:

```
x86_64-unknown-linux-gnu
aarch64-unknown-linux-gnu
aarch64-apple-darwin
```

All three share:
- POSIX syscall interface in `_kernel_native/`
- ELF (Linux) or Mach-O (macOS) object format handled automatically by clang
- System V AMD64 ABI (x86-64 Linux) or AAPCS64 (AArch64)
- clang toolchain for compilation and linking

**Windows:** Uses PE/COFF, Win32 API (different system calls), MSVC or MinGW
toolchain variants. The `_kernel_native/POSIX` layer would need a Windows
counterpart. Deferred — tracked as a Phase 2 item.

**CI matrix:** Three runners (ubuntu-latest x86-64, ubuntu-latest ARM, macos-14
AArch64). Cross-compilation is supported via `--triple` CLI flag + clang's
`--target` flag but not required for Phase 1 CI.

---

## D-N-009: Linking strategy

**Decision: clang as universal driver.** See D-N-001.

The compiler invokes:

```
clang [-O0|-O2|-O3] [--target=<triple>] <input.ll> lyric_rt.a [extra_libs] -o <output>
```

The `lyric_rt.a` path is computed from the same base-directory resolution used for
`Lyric.Stdlib.dll` on .NET. It lives at:

```
<compiler_bin>/../lib/lyric_rt.a       (installed layout)
<repo_root>/lyric-rt/build/lyric_rt.a  (dev layout)
```

---

## D-N-010: Generic strategy

**Decision: Full monomorphization via existing `Lyric.Mono`.**

The `Lyric.Mono.monoFile` pass already runs before the MSIL and JVM backends.
It produces specialized copies of generic functions (e.g., `mapList__Int__String`)
and rewrites all call sites. The native backend consumes the already-monomorphized
AST — no new generics work is needed in the codegen layer.

---

## D-N-011: ARC runtime intrinsics

**Decision: External C symbols in `lyric-rt` static library.**

The LLVM IR `declare`s these functions; `lyric_rt.a` defines them:

```
lyric_retain(i8* obj)         — atomic increment of rc
lyric_release(i8* obj)        — atomic decrement; if 0, call dtor + free
lyric_alloc(i64 size) → i8*   — malloc + OOM abort
lyric_panic_msg(i8* msg, i8* file, i32 line) — stderr + abort
```

These are the only four cross-cutting runtime functions. Everything else
(string operations, collection operations) is in Lyric-compiled code.

**Why not LLVM ObjC ARC intrinsics:** The ObjC ARC intrinsics
(`@llvm.objc.retain`, etc.) are tied to the Objective-C runtime metadata format
and require `libobjc` on non-Apple platforms. Custom symbols have no optimizer
support out-of-the-box, but LLVM function attributes (`nounwind`, `willreturn`,
`memory(argmem: readwrite)` on retain/release) let LLVM reason about them in
Phase 2 via a custom optimization pass.

---

## D-N-012: Collection and slice representation

**Decision:**

- `slice[T]`: borrowed fat pointer — `{ data: T*, len: i64 }` — no ARC header, no ownership.
- `List[T]` (Lyric's mutable sequence): RC heap object — `{ header, data: T*, len: i64, cap: i64 }`.
- `Map[K,V]` (Lyric's hash map): RC heap object with open-addressing hash table implementation.

`slice[T]` cannot outlive the object it borrows from. In Phase 1 this is enforced
by convention (kernel layer only borrows slices from live locals or static data).
Phase 2 can add lifetime annotations to enforce this statically.

---

## D-N-013: `@cfg(target = "X")` via pseudo-feature injection

**Decision:** The `@cfg(target = "X")` predicate is implemented by injecting a
pseudo-feature `"target.<name>"` into `CfgErasureInput.activeFeatures` at the
start of compilation. The existing feature-erasure loop in `Lyric.Cfg` then
handles `@cfg(target = "X")` identically to `@cfg(feature = "X")` without any
new predicate grammar or erasure logic.

- `--target dotnet` → `"target.dotnet"` in active set
- `--target jvm`    → `"target.jvm"` in active set
- `--target native` → `"target.native"` in active set

Only `lyric-compiler/lyric/cfg.l` is modified. `Cfg.fs` is **not** touched.

Full detail: `docs/03-decision-log.md` §D-N-013 and
`native/plan/07-stdlib-port.md` §target-conditional imports.
