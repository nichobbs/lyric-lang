# 02 — Architecture

## Overview

The native backend is a third compilation target alongside `--target dotnet`
(MSIL/PE) and `--target jvm` (JVM bytecode). It follows the same structural
pattern as both existing backends:

```
Lyric source
    │
    ▼
[Lyric.Lexer] → [Lyric.Parser] → [Lyric.TypeChecker] → [Lyric.ModeChecker]
    │
    ▼
[Lyric.ContractElaborator] → [Lyric.Mono] → [Lyric.Derives] → [Lyric.Weaver]
    │
    ▼
    ├─ target=dotnet ─→ [Msil.Codegen] → [Msil.Lowering] → .ll + PE bytes
    ├─ target=jvm    ─→ [Jvm.Codegen]  → [Jvm.Lowering]  → .class + JAR
    └─ target=native ─→ [Llvm.Codegen] → [Llvm.Lowering] → .ll text → clang → ELF/Mach-O
```

The front-end pipeline (Lexer through Weaver) is shared and target-agnostic.
The native backend begins at `Llvm.Codegen`, which consumes the same
monomorphized `SourceFile` that MSIL and JVM consume.

---

## New directories

### `lyric-compiler/llvm/`

The native backend. All files are Lyric source (`.l`). Mirrors the structure of
`lyric-compiler/msil/` and `lyric-compiler/jvm/`.

```
lyric-compiler/llvm/
  bridge.l                 — Llvm.Bridge public entry point (compileToNative)
  codegen.l                — Llvm.Codegen: SourceFile → NPackage
  lowering.l               — Llvm.Lowering: NPackage → .ll text
  ir.l                     — Llvm.Ir: .ll text serialization primitives
  types.l                  — Llvm.Types: NType union, type-to-IR-string mapping
  arc.l                    — Llvm.Arc: ARC retain/release insertion logic
  ffi.l                    — Llvm.Ffi: extern func declaration handling
  async.l                  — Llvm.Async: coro.* intrinsic emission (Phase 2)
  _kernel/
    kernel.l               — ByteWriter (reused from msil/_kernel/kernel.l pattern)
  llvm_self_test_n*.l      — self-tests (one file per phase)
```

### `lyric-rt/`

The native runtime C library. Compiled to `lyric_rt.a`.

```
lyric-rt/
  include/
    lyric_rt.h             — public header (LyricObjectHeader, LyricString, etc.)
  src/
    lyric_rt.c             — lyric_alloc, lyric_retain, lyric_release, lyric_panic_msg
    lyric_string.c         — string operations (from_literal, concat, len, etc.)
    lyric_weak.c           — NativeWeak implementation
    lyric_async.c          — scheduler (Phase 2, stub in Phase 1)
  CMakeLists.txt           — builds lyric_rt.a
  Makefile                 — thin wrapper: make -C lyric-rt
```

### `lyric-stdlib/std/_kernel_native/`

Native-target stdlib kernel. Each file declares `extern func` symbols backed
by POSIX/libm/libc. Only these files may contain `extern func` declarations.

```
lyric-stdlib/std/_kernel_native/
  libc.l                   — write, read, open, close, malloc, free, exit
  libm.l                   — sin, cos, sqrt, pow, floor, ceil, fabs, ...
  time.l                   — clock_gettime, CLOCK_REALTIME/MONOTONIC
  uuid.l                   — getrandom or /dev/urandom
  env.l                    — getenv, setenv, unsetenv, environ
  process.l                — fork, execvp, posix_spawn, waitpid, pipe, dup2
  net.l                    — socket, connect, bind, listen, accept, send, recv (Phase 2)
```

The public `Std.*` modules import from `_kernel_native/` when building for the
native target, exactly as they import from `_kernel/` for the .NET target.

---

## The bridge pattern

The native backend follows the same bridge pattern as MSIL and JVM:

**Lyric side** (`lyric-compiler/llvm/bridge.l`):

```lyric
package Llvm.Bridge

pub func compileToNative(
  source:        in String,
  outputPath:    in String,
  stdlibSources: in List[String],
  triple:        in String,       // e.g. "x86_64-unknown-linux-gnu" or ""
  optLevel:      in String        // "0", "1", "2", "3", or "s"
): Bool
```

The pipeline inside `compileToNative`:

```
parse(source)
  → typecheck(stdlibSources)
  → modecheck
  → elaborate
  → mono
  → derives
  → weave
  → Llvm.Codegen.codegenPackage   → NPackage
  → Llvm.Lowering.lowerPackage    → String (.ll text)
  → write .ll to tmp file
  → invoke clang
  → return success/failure
```

**No F# shim.** Unlike the test-infrastructure shims `SelfHostedMsil.fs` /
`SelfHostedJvm.fs` (which drive those backends from the F# test harness during
bootstrap), the native target requires no F# bridge. `--target native` is a
user-facing flag dispatched entirely through the self-hosted Lyric CLI
(`lyric-compiler/lyric/cli.l`), which calls `Llvm.Bridge.compileToNative`
directly. The AOT entry point (`Lyric.Cli.Aot`) trampolines into
`Lyric.Cli.Program.main`, so the native case is automatically available with
no F# changes.

---

## CLI integration

**New CompileTarget case:**

In `lyric-compiler/lyric/cli.l` (line 33 comment):

```lyric
pub union CompileTarget { case Dotnet | case Jvm | case Native }
```

**Parsing `--target native`** in the existing `--target` argument handler.

**New `--triple` flag** accepted when `--target native`:

```
lyric build hello.l --target native --triple aarch64-unknown-linux-gnu
```

If `--triple` is omitted, the compiler asks clang for the host triple:

```sh
clang -print-effective-triple    # returns e.g. "x86_64-unknown-linux-gnu"
```

**New `--opt` flag** (optional, default `2`):

```
lyric build hello.l --target native --opt 0   # debug build
lyric build hello.l --target native --opt 2   # release
```

---

## The intermediate IR: NPackage / NFunc / NType / NInsn

The native backend defines its own intermediate representation, parallel to
`MPackage`/`MFunc`/`MsilType`/`MInsn` (MSIL) and `LRecord`/`LFunc`/`JvmType`/`LInsn` (JVM).

### NType (in `llvm/types.l`)

```lyric
pub union NType {
  case NVoid
  case NI1          // bool
  case NI8          // byte / char byte
  case NI32         // Int (Lyric's default integer)
  case NI64         // Long
  case NDouble      // Float (f64)
  case NPtr(pointee: NType)   // T* (raw pointer)
  case NStruct(name: String, fields: List[NType])  // named struct type
  case NFunc(params: List[NType], ret: NType)      // function pointer type
  case NArray(elem: NType, size: Int)              // [N x T] (fixed array, for headers)
}
```

### NValue (SSA values)

```lyric
pub union NValue {
  case NLocal(name: String)          // %name
  case NGlobal(name: String)         // @name
  case NLitInt(v: Long, ty: NType)   // e.g. i32 42
  case NLitFloat(v: Double)          // double 3.14
  case NLitNull(ty: NType)           // null pointer
  case NUndef(ty: NType)             // undef
}
```

### NInsn (in `llvm/lowering.l`)

```lyric
pub union NInsn {
  // Terminators
  case NRet(val: Option[NValue])
  case NBr(label: String)
  case NCondBr(cond: NValue, thenLabel: String, elseLabel: String)
  case NSwitch(val: NValue, default_: String, cases: List[(Long, String)])
  case NUnreachable

  // Memory
  case NAlloca(result: String, ty: NType)
  case NLoad(result: String, ty: NType, ptr: NValue)
  case NStore(val: NValue, ptr: NValue)
  case NGEP(result: String, ty: NType, ptr: NValue, indices: List[NValue])  // getelementptr

  // Arithmetic (integer)
  case NAdd(result: String, ty: NType, a: NValue, b: NValue)
  case NSub(result: String, ty: NType, a: NValue, b: NValue)
  case NMul(result: String, ty: NType, a: NValue, b: NValue)
  case NSDiv(result: String, ty: NType, a: NValue, b: NValue)  // signed
  case NSRem(result: String, ty: NType, a: NValue, b: NValue)

  // Arithmetic (float)
  case NFAdd(result: String, a: NValue, b: NValue)
  case NFSub(result: String, a: NValue, b: NValue)
  case NFMul(result: String, a: NValue, b: NValue)
  case NFDiv(result: String, a: NValue, b: NValue)

  // Bitwise
  case NShl(result: String, ty: NType, a: NValue, b: NValue)
  case NAShr(result: String, ty: NType, a: NValue, b: NValue)   // arithmetic shift right
  case NAnd(result: String, ty: NType, a: NValue, b: NValue)
  case NOr(result: String, ty: NType, a: NValue, b: NValue)
  case NXor(result: String, ty: NType, a: NValue, b: NValue)

  // Comparison
  case NICmp(result: String, pred: ICmpPred, ty: NType, a: NValue, b: NValue)
  case NFCmp(result: String, pred: FCmpPred, a: NValue, b: NValue)

  // Conversion
  case NSExt(result: String, fromTy: NType, val: NValue, toTy: NType)  // sign extend
  case NZExt(result: String, fromTy: NType, val: NValue, toTy: NType)  // zero extend
  case NTrunc(result: String, fromTy: NType, val: NValue, toTy: NType)
  case NBitcast(result: String, fromTy: NType, val: NValue, toTy: NType)
  case NSIToFP(result: String, fromTy: NType, val: NValue, toTy: NType)
  case NFPToSI(result: String, fromTy: NType, val: NValue, toTy: NType)
  case NPtrToInt(result: String, val: NValue, toTy: NType)
  case NIntToPtr(result: String, val: NValue, toTy: NType)

  // Function call
  case NCall(result: Option[String], retTy: NType, fn: NValue, args: List[(NType, NValue)])
  case NCallVoid(fn: NValue, args: List[(NType, NValue)])

  // Phi (for SSA; used by control flow)
  case NPhi(result: String, ty: NType, incoming: List[(NValue, String)])

  // Label (basic block marker)
  case NLabel(name: String)

  // Coro intrinsics (Phase 2 only)
  case NCoroBegin(result: String, token: NValue, mem: NValue)
  case NCoroSuspend(result: String, token: NValue, isFinal: Bool)
  case NCoroEnd(hdl: NValue, isFinal: Bool)
  case NCoroFree(result: String, token: NValue, hdl: NValue)
}
```

### NFunc

```lyric
pub record NFunc {
  name:       String
  params:     List[(String, NType)]   // (param_name, param_type)
  retTy:      NType
  isPublic:   Bool
  isExtern:   Bool                    // extern func declaration (no body)
  body:       List[NInsn]             // empty if isExtern
  attributes: List[String]            // "nounwind", "noinline", etc.
}
```

### NPackage

```lyric
pub record NPackage {
  name:        String
  triple:      String                  // e.g. "x86_64-unknown-linux-gnu"
  types:       List[(String, NType)]   // named struct type definitions
  globals:     List[NGlobal]           // string literals, vtables, static data
  functions:   List[NFunc]
  externDecls: List[NFunc]            // extern func (declare only)
}
```

---

## Example: Hello World

Lyric source:

```lyric
package Hello
import Std.Console as Console

func main(): Unit {
  Console.println("Hello, world!")
}
```

Expected `.ll` output:

```llvm
; ModuleID = 'Hello'
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%LyricString = type { i32, i8*, i64, i64 }

@.strobj.0 = private unnamed_addr constant { i32, i8*, i64, i64, [13 x i8] } {
  i32 2147483647,           ; rc = INT32_MAX (static, never freed)
  i8* null,                 ; dtor = null (static strings have no destructor)
  i64 12,                   ; len (byte count, excluding null)
  i64 13,                   ; cap (allocated, including null terminator)
  [13 x i8] c"Hello, world\00"
}, align 8

declare void @lyric_retain(i8* %obj)
declare void @lyric_release(i8* %obj)
declare void @Std.Console.println(%LyricString* %str)

define void @Hello.main() {
entry:
  %str = bitcast { i32, i8*, i64, i64, [13 x i8] }* @.strobj.0 to %LyricString*
  call void @Std.Console.println(%LyricString* %str)
  ret void
}

define i32 @main(i32 %argc, i8** %argv) {
entry:
  call void @Hello.main()
  ret i32 0
}
```

---

## Build system integration

`Makefile` additions:

```makefile
native-rt:          ## Build lyric-rt static library
	$(MAKE) -C lyric-rt

stage1-native:      ## Build self-hosted LLVM backend packages
	SKIP_CLI_BUNDLE=0 INCLUDE_LLVM_BRIDGE=1 ./scripts/bootstrap.sh --stage 1

lyric-native:       ## Full native-capable lyric binary
	$(MAKE) native-rt
	$(MAKE) stage1-native
	dotnet build bootstrap/src/Lyric.Cli.Aot

test-native:        ## Run native backend self-tests
	./bin/lyric test lyric-compiler/llvm/llvm_self_test_n1.l --target native
```

`scripts/bootstrap.sh` additions:

When `INCLUDE_LLVM_BRIDGE=1`, add `lyric-compiler/llvm/` to the `COMPILER_SOURCES`
list (after `msil/` and `jvm/`, which it imports nothing from, so order is flexible).

---

## Dependency of native backend on existing packages

The native backend imports:

```lyric
import Lyric.Lexer
import Lyric.Parser
import Lyric.TypeChecker
import Lyric.ModeChecker
import Lyric.ContractElaborator
import Lyric.Mono
import Lyric.Derives
import Lyric.Weaver
import Lyric.DiagnosticUtil
import Lyric.RestoredPackages
import Std.Core
import Std.Collections
import Std.String
import Std.File
import Std.Process
```

It does NOT import `Msil.*` or `Jvm.*` — the backends are independent.
