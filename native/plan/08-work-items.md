# 08 — Work Items

Ordered task list for implementing the native backend. Each item is self-contained
enough for an agent to execute without design decisions to make. All decisions are
resolved in `01-design-decisions.md`. Read that document before starting any item.

Items are grouped into phases. Within a phase, items may be executed in parallel
unless the "Depends on" list says otherwise.

---

## Phase N0: Foundation

### N0.1 — `lyric-compiler/llvm/` skeleton

**Depends on:** Nothing — first item.

**Files to create:**

```
lyric-compiler/llvm/
  bridge.l              (placeholder package declaration + one-line stub)
  codegen.l             (placeholder)
  lowering.l            (placeholder)
  ir.l                  (placeholder)
  types.l               (placeholder)
  arc.l                 (placeholder)
  ffi.l                 (placeholder)
  _kernel/
    kernel.l            (copy from msil/_kernel/kernel.l — ByteWriter is identical)
```

Also create:

```
lyric-rt/
  include/
    lyric_rt.h
  src/
    lyric_rt.c
    lyric_string.c
    lyric_weak.c
    lyric_posix.c       (lyric_file_size and other platform-specific helpers)
    lyric_collections.c (List and Map implementations)
    lyric_async.c       (Phase 2 stub — empty file, compiles to nothing)
  CMakeLists.txt
  Makefile
```

**Acceptance criteria:**
- `cd lyric-rt && make` compiles `lyric_rt.a` with zero warnings on x86-64 Linux.
- `lyric-compiler/llvm/bridge.l` compiles to a Lyric DLL (even if it only declares
  `package Llvm.Bridge` and exports a stub `compileToNative` that returns false).

---

### N0.2 — `NType` and `NValue` type definitions (`llvm/types.l`)

**Depends on:** N0.1

**Files to create:** `lyric-compiler/llvm/types.l` (new file, `package Llvm.Types`)

**What to implement:**
Exactly the `NType`, `NValue`, `ICmpPred`, `FCmpPred` union types specified in
`02-architecture.md`. Also implement:

- `nTypeToIrString(t: NType): String` — converts NType to LLVM IR type string
  (`"i32"`, `"i64"`, `"double"`, `"i1"`, `"void"`, `"i8*"`, `"%Foo*"`, etc.)
- `nValueToIrString(v: NValue): String` — renders an NValue operand
  (`"%x"`, `"@foo"`, `"i32 42"`, etc.)

**Acceptance criteria:**
- `nTypeToIrString(NI32) == "i32"`
- `nTypeToIrString(NPtr(NI8)) == "i8*"`
- `nTypeToIrString(NStruct("Lyric.Point", [NI32; NI32])) == "%Lyric.Point"`
  (note: struct definitions are emitted separately; the reference is just the name)
- `nValueToIrString(NLitInt(42L, NI32)) == "i32 42"`
- `nValueToIrString(NLocal("x")) == "%x"`
- `nValueToIrString(NGlobal("foo")) == "@foo"`

---

### N0.3 — LLVM IR text serialiser (`llvm/ir.l`)

**Depends on:** N0.2

**Files to create:** `lyric-compiler/llvm/ir.l` (new, `package Llvm.Ir`)

**What to implement:**

The IR serialiser takes an `NPackage` and produces a valid `.ll` text file as a
`String`. Implement these functions:

```lyric
pub func emitModule(pkg: NPackage): String
// Top-level: emits header (ModuleID, target datalayout, target triple),
// type definitions, global constants, extern declarations, and function definitions.

pub func emitTypeDefn(name: String, fields: List[NType]): String
// Emits: %Name = type { i32, i8*, i64 }

pub func emitGlobal(g: NGlobal): String
// Emits: @name = <linkage> <addr_space> constant <ty> <init>, align N

pub func emitFuncDecl(f: NFunc): String
// Emits: declare <retTy> @name(<params>)   (for extern funcs)

pub func emitFuncDefn(f: NFunc): String
// Emits: define [pub] <retTy> @name(<params>) { <body> }

pub func emitInsn(i: NInsn): String
// Dispatches to the appropriate emitter for each NInsn variant.
// Terminator instructions have no leading spaces.
// Non-terminator instructions are indented two spaces.
// Labels emit as "name:\n" with no indent.
```

**LLVM IR formatting rules:**
- Each function body starts with a `entry:` block (the first basic block).
- Instructions within a block are indented two spaces.
- Labels appear at column 0.
- Blank line between function definitions.
- `target datalayout` and `target triple` appear at the top.

Standard target layouts for Phase 1:
- x86-64 Linux: `"e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128"`
- AArch64: `"e-m:e-i8:8:32-i16:16:32-i64:64-i128:128-n32:64-S128"`
- x86-64 macOS: same as Linux but `target triple = "x86_64-apple-macosx12.0.0"`
- AArch64 macOS: `"e-m:o-i64:64-i128:128-n32:64-S128"`

The `emitModule` function takes the triple as a parameter and selects the
appropriate datalayout from a lookup table.

**Acceptance criteria:**
- `emitInsn(NRet(Some(NLitInt(0L, NI32)))) == "  ret i32 0"`
- `emitInsn(NAdd("r", NI32, NLocal("a"), NLitInt(1L, NI32))) == "  %r = add i32 %a, i32 1"`
- `emitInsn(NLabel("entry")) == "entry:"`
- A minimal `NPackage` with a single `func main() → i32 { ret i32 0 }` produces
  valid IR that `clang -O0 -o /dev/null <file.ll>` accepts without errors.

---

### N0.4 — `lyric-rt.c` ARC implementation

**Depends on:** N0.1

**Files:** `lyric-rt/src/lyric_rt.c`, `lyric-rt/include/lyric_rt.h`

**What to implement:**
Exactly the functions specified in `04-arc-design.md`:
- `lyric_alloc`, `lyric_retain`, `lyric_release`, `lyric_panic_msg`
- The `INT32_MAX` static sentinel check in retain/release

Also implement `lyric_string.c`:
- `lyric_string_from_literal`, `lyric_string_concat`, `lyric_string_len`,
  `lyric_string_byte_at`, `lyric_string_dtor`

Also implement `lyric_collections.c`:
- The List[T] implementation (dynamic array of `void*`, each element retained
  on push, released on remove/dtor)
- The Map[K,V] hash map (open addressing, SipHash-2-4 for string keys)

Also implement `lyric_posix.c`:
- `lyric_file_size(const char* path) → int64_t`
- `lyric_mutex_size() → int32_t` (returns sizeof(pthread_mutex_t) — needed so
  Lyric codegen can allocate the right size for protected types without
  hardcoding platform-specific struct sizes)

**Acceptance criteria:**
- `lyric_alloc(16)` returns a non-null pointer.
- `lyric_retain` on a null pointer is a no-op (no crash).
- `lyric_retain` on a pointer with `rc = INT32_MAX` is a no-op.
- `lyric_release` decrements rc; at 0, calls the destructor then `free`.
- `lyric_panic_msg` writes to stderr and calls `abort()`.
- All tests in a new `lyric-rt/test/lyric_rt_test.c` (simple C tests) pass.

---

## Phase N1: Scalar codegen

Depends on: All of Phase N0.

### N1.1 — `NPackage`, `NFunc`, `NBasicBlock` IR types (`llvm/lowering.l`)

**Depends on:** N0.2, N0.3

**Files:** `lyric-compiler/llvm/lowering.l` (new, `package Llvm.Lowering`)

**What to implement:**
The `NFunc`, `NBasicBlock`, `NPackage`, `NGlobal` record types from
`02-architecture.md`. Also implement:

- `lowerFunc(f: NFunc): String` — calls `emitFuncDefn` or `emitFuncDecl`
- `lowerPackage(pkg: NPackage): String` — calls `emitModule`

This is a thin delegation layer; most of the work is already in `Llvm.Ir`.

---

### N1.2 — Codegen context and scalar type lowering (`llvm/codegen.l`)

**Depends on:** N1.1

**Files:** `lyric-compiler/llvm/codegen.l` (new, `package Llvm.Codegen`)

**What to implement:**

The `CodegenCtx` record holding all pre-computed tokens (function names for
`lyric_retain`, `lyric_release`, `lyric_alloc`, `lyric_panic_msg`, and all
stdlib `declare`s the codegen needs).

The `lyricTypeToNType(ty: TypeExpr): NType` function — maps Lyric AST type
expressions to `NType`:

```
Int    → NI32
Long   → NI64
Float  → NDouble
Bool   → NI1
Unit   → NVoid
Byte   → NI8
Char   → NI32
String → NPtr(NStruct("LyricString", ...))
```

For user-defined types, a lookup into a `typeMap: Map[String, NType]` built
during codegen.

---

### N1.3 — Integer arithmetic and comparison

**Depends on:** N1.2

**What to implement in `Llvm.Codegen`:**

Emit `NInsn` values for all Lyric integer operations:

- `a + b` → `NAdd`; `a - b` → `NSub`; `a * b` → `NMul`
- `a / b` → `NSDiv`; `a % b` → `NSRem`
- `a == b` → `NICmp(result, IEq, ...)` ; result is `i1`
- `a != b` → `NICmp(result, INe, ...)`
- `a < b` → `NICmp(result, ISlt, ...)` (signed less than)
- `a > b`, `a <= b`, `a >= b` → analogous
- `a and b` (Bool) → `NAnd(result, NI1, a, b)`
- `a or b` (Bool) → `NOr(result, NI1, a, b)`
- `not a` (Bool) → `NXor(result, NI1, a, NLitInt(1, NI1))`
- Bitwise `.and`, `.or`, `.xor`, `.shl`, `.shr` on Int/Long → `NAnd`, `NOr`, `NXor`, `NShl`, `NAShr`
- `a.toFloat()` (Int→Float) → `NSIToFP(result, NI32, a, NDouble)`
- `a.toLong()` (Int→Long) → `NSExt(result, NI32, a, NI64)`
- Float arithmetic: `NFAdd`, `NFSub`, `NFMul`, `NFDiv`
- Float comparison: `NFCmp` with `OEq`, `One`, `Olt`, `Ogt`, `Ole`, `Oge`

---

### N1.4 — Local variables and parameters

**Depends on:** N1.2

**What to implement:**

- `val` binding: `NAlloca` for the slot, then `NStore` the initializer value.
- `var` binding: same as `val` but the slot is mutable.
- Parameter access: parameters are LLVM IR parameters, accessed as `NLocal(name)`.
  No alloca needed for scalar parameters; `NAlloca` + `NStore` needed for
  mutable `var` parameters.
- `NLoad` to read a local variable.
- SSA naming: use a counter to produce unique names (`%x.0`, `%x.1`, etc.)
  if a name is reused in inner scopes.

---

### N1.5 — Control flow: if/else, while

**Depends on:** N1.3, N1.4

**What to implement:**

`if cond { then } else { else_ }`:
```llvm
%cond = ...
br i1 %cond, label %if.then, label %if.else
if.then:
  <then body>
  br label %if.merge
if.else:
  <else body>
  br label %if.merge
if.merge:
  ; optional phi if if-expr produces a value
```

`while cond { body }`:
```llvm
br label %while.cond
while.cond:
  %c = ...
  br i1 %c, label %while.body, label %while.exit
while.body:
  <body>
  br label %while.cond
while.exit:
```

For if/else as an expression (producing a value), use a `NPhi` node at the merge block.

---

### N1.6 — Function definitions and calls

**Depends on:** N1.4, N1.5

**What to implement:**

- Top-level function lowering: `IFunc` → `NFunc` with parameter list and body.
- Static function calls: `NCall` or `NCallVoid`.
- `return` statement: `NRet(Some(val))` or `NRet(None)` for Unit.
- The `func main(): Int` entry point synthesis: if the package has `func main(): Int`,
  emit the C-ABI `define i32 @main(i32, i8**)` wrapper that calls `@Package.main()`.
  If `func main(): Unit`, the wrapper calls it and returns 0.

---

### N1.7 — String literals and basic string ops

**Depends on:** N1.2

**What to implement:**

- String literal emission: add an `NGlobal` for the raw bytes and another for
  the static `LyricString` header wrapper. See `03-type-mapping.md` for the
  exact layout.
- String concatenation `a ++ b`: emit `NCall` to `@lyric_string_concat`.
- String length `.length`: emit `NCall` to `@lyric_string_len`.
- `Std.Console.println(s)`: emit `NCall` to `@Std.ConsoleNativeHost.consoleWriteln`.
  (This requires `_kernel_native/console_native.l` — do that work item in parallel.)

---

### N1.8 — Self-test: scalars, control flow, functions (`llvm_self_test_n1.l`)

**Depends on:** N1.1 through N1.7, N0.4 (`lyric_rt.a` built)

**Files to create:** `lyric-compiler/llvm/llvm_self_test_n1.l`

**What to test:**
- Integer arithmetic (all ops)
- Boolean logic
- Comparison operators
- if/else expression and statement forms
- while loop
- Nested functions calling each other
- String literal printing via `Std.Console.println`
- `func main(): Int` returning an exit code

**Format:** `@test_module` so it runs via `lyric test --target native`.

**Acceptance criteria:**
- `lyric test lyric-compiler/llvm/llvm_self_test_n1.l --target native` exits 0.
- All test cases pass on x86-64 Linux.

---

## Phase N2: ARC and heap types

Depends on: All of Phase N1.

### N2.1 — Record type lowering

**Depends on:** N1.6

**Files:** `llvm/codegen.l` additions

**What to implement:**

For each `IRecord` in the source:
1. Define the LLVM struct type: header (i32 + i8*) followed by fields in
   declaration order.
2. Synthesise the destructor function: release each reference-typed field,
   return void (do NOT free self).
3. Emit the constructor: `lyric_alloc`, set `rc=1`, set `dtor` ptr, store each
   field (retain reference-typed args before storing — Rule 2 in `04-arc-design.md`).
4. Emit field accessors (GEP + load).
5. Insert ARC releases at end-of-scope for local record variables (Rule 4).

---

### N2.2 — Union type lowering

**Depends on:** N2.1 (uses same header/dtor/alloc pattern)

**What to implement:**

For each `IUnion`:
1. Compute `max_payload_bytes = max(sizeof(caseN_payload))`.
2. Define the LLVM struct: `{ i32, i8*, i32, [max_payload x i8] }`.
3. For each case: define a payload struct type with the case's fields.
4. Synthesise the union destructor: load discriminant, switch, release any
   reference-typed fields in the active case.
5. Emit constructor functions for each case (one per case): alloc the union,
   write header + discriminant + payload.
6. For pattern matching on a union value, emit a `switch` on the discriminant
   and GEP + bitcast to access case payload fields.

---

### N2.3 — Distinct type lowering

**Depends on:** N1.2

**What to implement:**

For each `IDistinctType`:
- If the wrapped type is a scalar (Int, Long, Float, Bool, Byte, Char):
  define as `%Name = type { underlying_type }` (no ARC header, stack-allocated).
  Constructor: `{ val }`.
- If the wrapped type is a reference (String, record, union):
  define with ARC header. Constructor retains the argument.

Emit `From(x)` (with optional range check) and `.value` accessor.

---

### N2.4 — Pattern matching

**Depends on:** N2.2

**What to implement:**

- Matching on union discriminant: `switch i32 %disc, default %no_match [...]`.
- Binding case fields: GEP into payload, load fields into locals.
- Matching on scalar literals: `switch i32 %val, default %no_match [...]`.
- String matching: call `@lyric_string_eq` for each branch.
- Wildcard `_`: no check needed.
- Exhaustiveness: if the match is exhaustive (type checker ensures this),
  the `default` label points to `unreachable`.

---

### N2.5 — NativeWeak[T]

**Depends on:** N2.1

**What to implement:**

- `NativeWeak[T]` type: `%LyricWeak_T = type { i8* }` (non-owned raw pointer).
- Construction from T: store raw pointer without calling retain.
- `upgrade()`: emit the `cmpxchg` loop from `04-arc-design.md`.
- ARC: NativeWeak instances are themselves stack-allocated or embedded in records
  without an ARC header. The `i8*` they contain is NOT released in any destructor.

---

### N2.6 — Closures

**Depends on:** N2.1, N1.6

**What to implement:**

- For each closure literal in the AST, synthesise a closure struct type:
  `{ i32, i8*, i8*, capture0_type, capture1_type, ... }`.
- Synthesise the closure body function: `define ccc <retTy> @closure_N(i8* %env, <args>)`.
  Inside: bitcast `%env` to the concrete closure type, load captures.
- Emit the constructor: alloc the closure struct, set rc=1, set dtor, set fn_ptr,
  retain and store each captured reference-typed variable.
- Closures that capture nothing: a single static `@closure_N_static` constant
  (with rc=INT32_MAX) may be used instead of a heap allocation.
- First-class function references (`&foo`): synthesise a zero-capture wrapper closure.

---

### N2.7 — Self-test: records, unions, ARC, pattern matching (`llvm_self_test_n2.l`)

**Depends on:** N2.1–N2.6

**What to test:**
- Record construction and field access.
- Record fields with reference types (strings, nested records).
- ARC: verify that objects are freed when their rc reaches 0 (via a destructor
  that calls `Console.println` as a side effect — this is a standard RC test).
- Union construction and pattern matching.
- Closures capturing variables of both scalar and reference types.
- `NativeWeak[T]`: upgrade returns Some when object is alive, None after release.

---

## Phase N3: Type system completeness

Depends on: All of Phase N2.

### N3.1 — Generic monomorphization integration

**Depends on:** N2.1, N2.2

**What to implement:**

`Lyric.Mono.monoFile` already runs before the codegen. Ensure the codegen
correctly handles monomorphized type names (e.g., `Lyric.Option__Int`) and maps
them to their concrete LLVM struct types. The codegen's `typeMap` must be
populated from the monomorphizer's output type table.

No new mono pass is needed — just verify the codegen correctly consumes the
already-monomorphized AST.

---

### N3.2 — Interface dispatch (vtable)

**SHIPPED** (D-progress-568, D-N-016): non-generic interfaces + `impl I for
Record`, implicit upcast at argument/return/binding positions, and vtable
dispatch on interface-typed receivers, verified ASan-clean by
`llvm_self_test_n3.l`. The shipped representation is a **heap-boxed** fat
pointer `{ i32 rc, i8* dtor, i8* obj, vtable* }` (not the by-value pair below)
because the IR layer has no by-value-aggregate ABI — see D-N-016; ARC then
falls out of the existing owned-temp/destructor machinery. Vtable slots hold
the concrete method pointer directly (bitcast to `i8*` and back at the call
site — no wrapper), and `obj` (as `i8*`) is passed as the receiver.
Deferred: generic/default/`Self`/async interface methods, associated types,
multiple inheritance, `impl` for non-record targets.

**Depends on:** N2.1, N2.6

**What was implemented (original plan):**

For each interface `I` with method `m`:
1. Define `%Lyric.I.vtable = type { <m return type>(<args>)* }` — one slot per method.
2. For each `impl I for Record`:
   a. Define the concrete vtable constant `@Lyric.Record.I.vtable`.
   b. Implement the vtable slot as a wrapper that casts `i8* obj` to `%Lyric.Record*`
      and calls the concrete method.
3. When a value is upcast to the interface type `I`:
   emit a fat pointer `%Lyric.I = { i8* obj, %Lyric.I.vtable* vtable }`.
4. Interface method call: load vtable ptr from fat pointer, load method slot,
   bitcast, call with `obj` as first arg.

---

### N3.3 — Tuple types

**Depends on:** N2.1

**What to implement:**

Anonymous tuples `(T0, T1, ...)` lower as anonymous record types (named by
mangled type list). Tuple construction, field access (`.0`, `.1`), and pattern
destructuring. ARC follows the same rules as records.

---

### N3.4 — Protected types

**SHIPPED** (D-progress-573, D-N-017): non-generic protected types, `entry`
and `func` members both locking via a codegen-synthesised lock/unlock
wrapper around a desugared inner body, field-args and no-arg (defaults)
construction, verified ASan-clean by `llvm_self_test_n34.l`. The mutex is a
**pointer to a separately heap-allocated buffer**, not an embedded
`pthread_mutex_t` field (below) — `lyric_mutex_size()` is a runtime C call
the self-hosted (.NET/JVM-hosted) compiler cannot invoke at its own codegen
time, and LLVM struct types are fixed-size, so there is no way to reserve a
runtime-determined number of inline bytes; see D-N-017. This still honours
the "do not hardcode a table" directive below. `func` members are locked
too (the language reference makes both `entry` and `func` exclusive),
unlike MSIL (`entry`-only) or JVM (no locking, #855/#1833) — native has no
try/finally-equivalent epilogue, hence the wrapper/inner split rather than
one lock/unlock pair per return site. Deferred: `when:` barriers,
invariant re-checking, generic protected types.

**Depends on:** N2.1, `lyric_mutex_size()` from N0.4

**What was implemented (original plan):**

`protected type Counter { val: Int; ... }` lowers as a record type with an
embedded `pthread_mutex_t`. The mutex size is obtained at codegen time by calling
`lyric_mutex_size()` (already implemented in N0.4) — do **not** hardcode a table.
The correct platform values for reference only: 40 bytes on Linux x86-64/AArch64,
64 bytes on macOS AArch64/x86-64 (not 56 — that is wrong and causes memory
corruption).

- Constructor: call `lyric_mutex_init` after allocation.
- Each `protected` method call: `lyric_mutex_lock`, call the body, `lyric_mutex_unlock`.
- Destructor: `lyric_mutex_destroy` before the standard record dtor.

---

### N3.5 — Self-test: generics, interfaces, tuples (`llvm_self_test_n3.l`)

**Depends on:** N3.1–N3.4

**What to test:**
- `List[Int]`, `List[String]`, `Map[String, Int]`.
- Interface method dispatch.
- Tuple construction and destructuring.
- Protected type with two concurrent simulated accesses (in a single thread,
  verify mutex prevents double-entry via a re-entrant access attempt).

**Protected-type coverage shipped differently than planned:** a genuine
re-entrant/concurrent access attempt would deadlock the test process (the
lock really is exclusive), so `llvm_self_test_n34.l` (not `llvm_self_test_n3.l`)
instead asserts sequential correctness through the lock/unlock wrapper —
`entry` mutation, a `func` member locking identically, no-arg construction
from defaults, and an ASan case proving the mutex buffer and a ref-typed
field are both torn down cleanly (D-progress-573).

---

## Phase N4: FFI and `_kernel_native/`

Can begin in parallel with Phase N3.

### N4.1 — Parser: `IExternFunc` AST node

**Depends on:** Nothing from native (parser change in core).

**Files to modify:** `lyric-compiler/lyric/parser/parser_items.l`

**What to implement:**
Parse `extern func <name>(<params>): <ret> = "<symbol>"` as a new item kind.
Add `IExternFunc(decl: ExternFuncDecl)` to the `ItemKind` union in
`lyric-compiler/lyric/parser/parser_ast.l`.

Ensure the type checker recognises `IExternFunc` items and registers them
in the symbol table with their type signature.

---

### N4.2 — `NativePtr[T]` type support

**Depends on:** N1.2

**What to implement:**

Add `NativePtr[T]` as a recognised type in `lyricTypeToNType`: maps to `NPtr(innerType)`.
Add mode checker enforcement: `NativePtr[T]` may only appear in `_kernel_native/`
files or `@unsafe_ffi`-annotated functions. The mode checker emits a new diagnostic:
```
N0100: NativePtr[T] is only allowed in @unsafe_ffi functions and _kernel_native/ packages.
```

---

### N4.3 — `extern func` IR emission

**Depends on:** N4.1, N4.2

**Files:** `lyric-compiler/llvm/ffi.l` (new, `package Llvm.Ffi`)

**What to implement:**

For each `IExternFunc` encountered during codegen:
1. Emit a `declare` in the module: `declare <retTy> @<symbol>(<paramTypes>)`.
2. At call sites for the declared function, emit `NCall` to `@<symbol>` directly
   (not the Lyric function name — the symbol name is the C function).
3. The `@nativeLib("name")` annotation is preserved on the `NPackage.nativeLibs`
   list for the linker invocation (Phase N7.1).

---

### N4.4 — `_kernel_native/` basic implementation

**Depends on:** N4.3

**Files to create:**
- `lyric-stdlib/std/_kernel_native/libc.l`
- `lyric-stdlib/std/_kernel_native/libm.l`
- `lyric-stdlib/std/_kernel_native/time.l`
- `lyric-stdlib/std/_kernel_native/uuid.l`
- `lyric-stdlib/std/_kernel_native/env.l`
- `lyric-stdlib/std/_kernel_native/process.l`

All implementations are specified in `07-stdlib-port.md`.

---

### N4.5 — Callback trampolines

**Depends on:** N4.3, N2.6 (closures)

**What to implement in `Llvm.Ffi`:**

When a Lyric closure value is passed as an argument to an `extern func`
parameter of type `func(A): B` (a function type in that position), emit:
1. A `define ccc` trampoline function (see `05-ffi-design.md`).
2. Pass the trampoline pointer + the closure pointer (cast to `i8*`) as the
   `userdata` to the C function.

Trampoline signatures must match the `extern func` parameter types exactly.

---

### N4.6 — Target-conditional `@cfg(target = ...)` in Cfg

**Depends on:** Nothing from native.

**Files to modify:** `lyric-compiler/lyric/cfg.l`, `lyric-compiler/lyric/cli.l`

**What to implement (D-N-013 — pseudo-feature injection):**

Do **not** add a `target: String` field to `CfgErasureInput` and do **not** add
a new predicate branch to the erasure loop. D-N-013 explicitly rejects that
approach. Instead:

1. In `cli.l`, when building the `CfgErasureInput` for any compilation, inject
   a pseudo-feature `"target.<name>"` into the existing `activeFeatures` set:
   - `--target dotnet` → add `"target.dotnet"`
   - `--target jvm`    → add `"target.jvm"`
   - `--target native` → add `"target.native"`

2. No changes to the erasure loop or predicate grammar in `cfg.l` are needed.
   The existing `@cfg(feature = "X")` evaluation already handles the
   `@cfg(target = "native")` predicate by treating `target` as the key and
   `"native"` as the value, resolving to the pseudo-feature `"target.native"`.

The F# bootstrap `Cfg.fs` does **not** need to be updated. The native target is
only reachable through the self-hosted Lyric CLI; the F# bootstrap emitter does
not emit native code and never evaluates `@cfg(target = "native")`.

---

### N4.7 — Self-test: FFI and `_kernel_native/` (`llvm_self_test_n4.l`)

**Depends on:** N4.3–N4.6

**What to test:**
- Direct `extern func` call to `write` (from `_kernel_native/libc.l`).
- `extern func` call to `sin` and `sqrt` (from `_kernel_native/libm.l`).
- `withCString` helper.
- A closure passed as a callback to a C function (use `qsort` as the test target —
  it accepts a comparator function pointer and `void* userdata`).

---

## Phase N5: Stdlib port

Depends on: Phase N4 complete.

### N5.1 — Update `Std.Console` for native

**Depends on:** N4.4 (`console_native.l` exists), N4.6 (`@cfg(target = ...)` works)

**Files to modify:** `lyric-stdlib/std/console.l`

Add `@cfg(target = "native") import Std.ConsoleNativeHost as ConsoleImpl`
alongside the existing `@cfg(target = "dotnet") import Std.ConsoleHost as ConsoleImpl`.

Verify that `Std.Console.println("hello")` compiles and runs on `--target native`.

---

### N5.2 — Update `Std.Math` for native

**Depends on:** N4.4 (`libm.l` exists), N4.6

**Files to modify:** `lyric-stdlib/std/math.l`

Same pattern as N5.1. Verify transcendental functions return correct values.

---

### N5.3 — Update `Std.File` and `Std.Directory` for native

**Depends on:** N4.4 (`file_native.l` exists)

**Files to modify:** `lyric-stdlib/std/file.l`

Add native import conditional. Implement `readAllText`, `writeAllText`, `exists`,
`createDirectory`, `deleteFile` by calling the `_kernel_native/file_native.l` externs.

---

### N5.4 — Update `Std.Time` for native

**Depends on:** N4.4 (`time.l` kernel exists)

Implement `Instant.now()` returning milliseconds since epoch via `clock_gettime`.

**SHIPPED (D-N-027, superseding the sketch above):** the full calendar
surface, not just `now()`.  `Instant`/`Duration`/`DateTimeOffset` are
nanosecond-count records (years ~1678..2262, the JVM `toNanos()`
window) over a new `lyric_epoch_nanos`; calendar decomposition is
Hinnant's proleptic-Gregorian civil math in pure Lyric; `addMonths`
clamps day-of-month like both managed twins; ISO-8601 output is
java.time-style and the parser is strict ISO with field validation;
fractional duration constructors round via `llround(3)`.
`parseOptInstant` routes through a `hostParseInstantOpt` Option seam
all three twins implement (the D-N-026 idiom).  Verified by a native
ASan self-test with string goldens and target-neutral `time_tests.l`
calendar coverage.

---

### N5.5 — Update `Std.Uuid` for native

**Depends on:** N4.4 (`uuid.l` kernel exists)

Generate 16 random bytes via `getrandom`, format as UUID string.

**SHIPPED (D-N-026):** `lyric_uuid_v4` draws from `lyric_secure_random`
and formats the canonical lowercase hyphenated string in C; the native
twin represents `Uuid` as that string, and `Std.Uuid.parseUuidOpt`
canonicalizes the four cross-target formats in shared pure Lyric so
all three kernel twins parse through one exception-free Option seam
(the Bool+out TryParse shape is gone from the shared surface — native
has no out params). Verified by an ASan `llvm_stdlib_self_test.l`
case and extended managed `uuid_tests.l` coverage.

---

### N5.6 — Update `Std.Environment` for native

**Depends on:** N4.4 (`env.l` kernel exists)

Implement `get(name)`, `set(name, val)`, `all()` using `getenv`/`setenv`/`environ`.

---

### N5.7 — Update `Std.Process` for native

**Depends on:** N4.4 (`process.l` kernel exists), N5.3 (for subprocess I/O)

Implement `run(cmd, args)`, `capture(cmd, args)` using `posix_spawn`/`waitpid`/`pipe`.

---

### N5.8 — `Std.Collections` native verification

**Depends on:** N0.4 (`lyric_collections.c`), N2.1 (record lowering works)

Verify that `List[T]` and `Map[K,V]` operations compile and run correctly
with `--target native`. The underlying C implementation is already in `lyric_rt.a`.
This item is about ensuring the Lyric type system correctly maps to the C layout.

---

### N5.9 — Self-test: stdlib port (`llvm_self_test_n5.l`)

**Depends on:** N5.1–N5.8

**What to test:**
- `Std.Console.println`
- `Std.Math.sqrt`, `Std.Math.sin`
- `Std.File.readAllText` / `writeAllText`
- `Std.Time.Instant.now()`
- `Std.Uuid.newUuid()`
- `Std.Environment.get("HOME")`
- `Std.Process.run("echo", ["hello"])`
- `Std.Collections.List` push/get/len
- `Std.Collections.Map` set/get
- `Std.Json.parse` (pure Lyric — should work automatically)

---

## Phase N6: Bridge and CLI integration

Depends on: Phase N5 complete.

### N6.1 — `Llvm.Bridge` (complete implementation)

**Depends on:** All prior phases.

**Files:** `lyric-compiler/llvm/bridge.l` (replace placeholder with full impl)

Implement `compileToNative` as specified in `02-architecture.md`:
parse → typecheck → modecheck → elaborate → mono → derives → weave →
`Llvm.Codegen.codegenPackage` → `Llvm.Lowering.lowerPackage` → write `.ll` →
invoke clang → return success.

Clang invocation:

```lyric
val clangArgs = [
  "-O" ++ optLevel,
  inputLlPath,
  lyricRtPath,     // path to lyric_rt.a
  "-lm",
  "-lpthread",
] ++ extraLibs     // from @nativeLib annotations
val result = Process.run("clang", clangArgs ++ ["--target=" ++ triple, "-o", outputPath])
```

---

### N6.2 — Verify `Llvm.Bridge` is discoverable from the Lyric CLI

**Depends on:** N6.1

**No new files.** The native target is a user-facing compilation target invoked
exclusively through the self-hosted Lyric CLI (`lyric-compiler/lyric/cli.l`),
which dispatches into `Llvm.Bridge.compileToNative` directly — the same pattern
used for MSIL and JVM bridges within the Lyric CLI package.

No F# shim (analogous to `SelfHostedMsil.fs`) is needed or permitted. The
`SelfHostedMsil.fs` / `SelfHostedJvm.fs` F# shims exist solely to drive the
self-hosted MSIL and JVM pipelines **from the F# test harness** during bootstrap.
The native target does not participate in the bootstrap pipeline; it is compiled
and run end-to-end through the AOT Lyric CLI binary.

**What to verify:**

- The `Llvm` package is listed in the `Lyric.Cli` import closure so that
  `lyric-compiler/llvm/bridge.l` is compiled into the stage-1 DLL bundle when
  `INCLUDE_LLVM_BRIDGE=1` is set in `scripts/bootstrap.sh`.
- `lyric build hello.l --target native` routes to `Llvm.Bridge.compileToNative`
  and produces a runnable ELF / Mach-O binary.

**Acceptance criteria:**

- `./bin/lyric build examples/hello.l --target native -o hello` exits 0 and
  `./hello` prints "Hello, world!".
- No new F# files are created.

---

### N6.3 — CLI `--target native` dispatch

**Depends on:** N6.2

**Files to modify:**
- `lyric-compiler/lyric/cli.l` — add `case Native` to `CompileTarget`, parse
  `--target native`, parse `--triple`, parse `--opt`, route to `Llvm.Bridge`.

The F# bootstrap files (`Emitter.fs`, `Program.fs`) do **not** need changes.
The F# `CompileTarget` type is an internal bootstrap implementation detail used
only for the `.NET` and `.jvm` bootstrap paths; `--target native` is exclusively
a user-facing flag dispatched through the self-hosted Lyric CLI. Adding `| Native`
to the F# type would create dead code and violate the no-new-F# policy.

The AOT entry point (`Lyric.Cli.Aot`) already trampolines into
`Lyric.Cli.Program.main`, so any new `--target` case added to `cli.l` is
automatically available to the user without F# changes.

---

### N6.4 — Manifest `[native]` section

**SHIPPED (D-progress-564):** `NativeConfig` record + `assembleNative` in
`manifest.l`; `cli_build.l`/`emitter.l` read `[native]`, merge with the
CLI `--triple`/`--opt` (which override), and thread `extra_libs` into the
clang link via the existing `compileToNativeWithFlags` extra-flags slot.

**Depends on:** N6.3

**Files to modify:** `lyric-compiler/lyric/manifest.l`

Add a new optional `[native]` table to `lyric.toml`:

```toml
[native]
triple    = "x86_64-unknown-linux-gnu"   # default: auto-detect
opt_level = "2"                          # default: "2"
extra_libs = ["ssl", "crypto"]           # additional -l flags for clang
```

Parse into a new `NativeConfig` record in `manifest.l`.

---

### N6.5 — `scripts/bootstrap.sh` and `Makefile` additions

**Depends on:** N6.1

Add `lyric-compiler/llvm/` to the stage-1 build when `INCLUDE_LLVM_BRIDGE=1`.
Add Makefile targets `native-rt`, `stage1-native`, `lyric-native`, `test-native`
as specified in `02-architecture.md`.

---

## Phase N7: Testing and CI

Depends on: Phase N6 complete.

### N7.1 — CI workflow for native targets

**PARTIALLY SHIPPED** (D-progress-576): a single-OS (`ubuntu-latest`) native
backend CI job already runs on every PR in `.github/workflows/ci.yml` — the
dedicated `native-backend-self-tests` job ("Native backend self-tests" + the
`lyric test --target native` smoke-test step below N7.2) — it builds
`lyric-rt.a` under both clang and gcc, runs the full `llvm_self_test_n*.l`
suite, and now also compiles+runs a real `--target native` test module (pass
and fail cases). It was split out of `compiler-self-tests-dotnet-a` into its
own job so its ~124 sequential `clang`/ASan-linked subprocess invocations get
a dedicated runner instead of competing for CPU with that job's other
concurrent self-test steps. The originally envisioned dedicated
`native-ci.yml` workflow and 3-OS matrix (`ubuntu-24.04-arm`, `macos-14`) are
**not** shipped — deferred as a follow-up; the single-OS job is the
production gate today.

**Files to create:** `.github/workflows/native-ci.yml`

Matrix:
```yaml
strategy:
  matrix:
    os: [ubuntu-latest, ubuntu-24.04-arm, macos-14]
    include:
      - os: ubuntu-latest
        triple: x86_64-unknown-linux-gnu
      - os: ubuntu-24.04-arm
        triple: aarch64-unknown-linux-gnu
      - os: macos-14
        triple: aarch64-apple-darwin
```

Steps:
1. Install clang (Linux: `apt install clang`; macOS: already available via Xcode).
2. Build `lyric-rt.a` (`make native-rt`).
3. Build stage-1 with LLVM bridge (`make stage1-native`).
4. Build AOT entry point (`make lyric-native`).
5. Run all `llvm_self_test_n*.l` files via `lyric test --target native`.
6. Run the stdlib self-test (`llvm_self_test_n5.l`).

---

### N7.2 — Native self-test discovery via `lyric test`

**SHIPPED** (D-progress-576, D-N-018): `--target native` is a real
`lyric test` target (`cli_test.l`), compiling through `Emitter.emitNative`
and running the produced binary directly. The gap the plan anticipated
("`--target` does not yet accept native") was real — fixed in `cli_test.l`,
plus a new `Lyric.TestSynth.synthesizeNative` entry point (native has no
try/catch, D-N-003, so per-test isolation can't work the way the existing
`synthesize` does it — see D-N-018 for the straight-through execution
model) and a native-codegen fix for the bare `toString(x)` prelude call
(`llvm_codegen.l`'s `lowerConstructCall`, needed because
`Std.Testing.assertEqualInt`/`assertEqualLong` use it internally). No F#
anywhere, as directed.

Single-file only: manifest (multi-package) native test suites are rejected
with a diagnostic, matching `lyric build --target native`'s existing
restriction. The **existing** `llvm_self_test_n*.l` files are not run
through this path — they import `Lyric.*` compiler packages (to drive
`codegenNativePackage` on ad-hoc program strings and shell out to `clang`
themselves), which single-file native compilation does not resolve; they
continue running via `LYRIC_LOAD_COMPILER=1 lyric test` on the dotnet
target, unchanged. `--target native` is for ordinary user `@test_module`
files with no compiler-package imports.

**Files modified:** `lyric-compiler/lyric/cli/cli_test.l`,
`lyric-compiler/lyric/test_synth/test_synth.l`,
`lyric-compiler/lyric/llvm_codegen.l`.

**Acceptance criteria:**

- `lyric test <ordinary-test-module.l> --target native` exits 0 on an
  all-passing suite and prints normal TAP output. ✅ (verified manually and
  via the new CI smoke-test step)
- A failing assertion under `--target native` exits nonzero (no per-test
  isolation — the whole process aborts). ✅
- No modifications to any file under `bootstrap/tests/`. ✅ (no F# touched
  at all)

---

### N7.3 — Documentation updates

Per the CLAUDE.md convention, update all three of:

1. `docs/01-language-reference.md` — add `--target native` to the CLI section,
   document `extern func` syntax, `NativePtr[T]`, `NativeWeak[T]`, `@unsafe_ffi`,
   `@nativeLib`, and `@cfg(target = ...)`.
2. `book/chapters/appendix-b-quick-reference.md` — add `--target native` to the
   CLI reference table.
3. `docs/10-bootstrap-progress.md` — update the native backend milestone status.

---

## Phase N8: Async (Phase 2)

Work items A-1 through A-7 are specified in `06-async-design.md`. They depend
on Phases N0–N7 being complete. They were not in scope for Phase 1.

**First slice SHIPPED (D-N-019):** `async func` (non-generator) and `await`
compile and run correctly on `--target native`. Contrary to A-1 through A-5's
original coroutine-based design, the shipped mechanism needs none of it:
`Task[T]` is not a real type anywhere in the self-hosted front end, and with
`spawn`/`scope` out of scope there is no Lyric program that can hold an
async call's result unawaited, so a non-generator `async func` body compiles
through the *exact same codegen path as a plain `func`* and `await expr`
lowers as a pure passthrough (`lowerExpr` on the inner expression, no
suspend point emitted). No `lyric-rt` runtime changes were needed. Verified
end-to-end via both the in-process self-test harness
(`llvm_self_test_async.l`: basic/chained/nested awaits, await inside a loop
and inside a branch, ASan-clean String captures/returns) and the real CLI
(`lyric build --target native`).

**Deferred, each with its own tracked follow-up (D-N-019):**
- Async generators (`yield` inside `async func`) — rejected with a
  dedicated diagnostic distinct from plain unsupported-async.
- The implicit `cancellation` parameter / cooperative cancellation.
- `spawn` / `scope { }` structured concurrency — originally framed here
  as "the point at which real LLVM-coroutine suspension (A-1 through
  A-5's original design) becomes necessary". **SHIPPED (D-N-021)** as
  the same passthrough model the MSIL emitter itself uses, which
  refined that framing: the true coroutine trigger is the first **async
  leaf primitive** (async sleep/timer, then async I/O) — a .NET task
  only stays incomplete if it awaits such a leaf, native's stdlib has
  none, and .NET semantics restricted to the native surface therefore
  also degenerate to sequential execution. The coroutine lowering
  pipeline itself was hand-verified against `clang` 18 before the
  D-N-019 slice began (a `presplitcoroutine`-attributed `.ll`
  round-trip compiles and runs correctly via plain `clang file.ll -o
  binary` at every `-O` level, no separate `opt` invocation needed) —
  see D-N-019 for the verified sequence and the final-suspend subtlety
  it surfaced, preserved there for the async-leaf follow-up.

## Phase N8 (cont'd): `defer` (Phase 2, D-N-020)

`defer` was explicitly out of scope for Phase 1 (D-N-003: "no `defer` in
Phase 1"). **First slice SHIPPED (D-N-020):** normal-exit paths only —
fall-off, `return`, `break`, `continue`. Rather than the landingpad-based
mechanism D-N-003 originally sketched for a *panic-triggered* `defer`
(unimplemented; still needed for that case), this slice extends the
existing ARC scope-exit mechanism (`Ctx.scopeRefs`) with a parallel
per-scope stack of pending deferred `Block`s (`Ctx.deferStack`), pushed/
popped at the same two call sites (`pushVarScope`/`popVarScope`) and run
in reverse declaration order at every one of the three existing
scope-exit sites (`popVarScope`, `releaseAllForReturn`,
`releaseForLoopExit`) before that scope's ARC releases — no new IR shape,
no new `lyric-rt` runtime support. A `defer` registered before a `panic`
does not run (D-N-003: no unwinding, so no scope-exit event ever fires).
Verified by `llvm_self_test_defer.l` (8 cases, including a direct
negative check for the panic-bypass gap) and end-to-end via `lyric build
--target native`.

## Phase N8 (cont'd): `spawn`/`scope` (Phase 2, D-N-021)

**SHIPPED (D-N-021):** `ESpawn(inner)` lowers as a passthrough
(`lowerExpr(inner)`, mirroring both MSIL's own `ESpawn` lowering and
native's `EAwait`); `SScope(_, body)` lowers via `lowerBlockStmts`, so
`scope { }` is a real lexical scope whose ARC releases and pending
`defer` blocks (D-N-020) run at scope exit — which is MSIL's plain-block
treatment plus native's existing scope discipline. §7.4's guarantees
hold degenerately (every spawned call completes at the spawn site; a
failing task aborts the process per D-N-003; nothing can leak past the
scope). Genuine concurrent progress is gated on the first async leaf
primitive — see D-N-021 and the refined deferral note in the D-N-019
section above. Verified by five new `llvm_self_test_async.l` cases
(spawn-bind-then-await, the §7.4 dashboard shape, scope + defer
interplay on both fall-through and early-return paths, ASan-clean
String spawn bindings) and end-to-end via `lyric build --target
native`.

## Phase N8 (cont'd): real async — coroutines + scheduler + sleep leaf (Phase 2, D-N-022)

**SHIPPED (D-N-022):** the coroutine mechanism of `06-async-design.md`
is now the live lowering, superseding the D-N-019/D-N-021 passthrough
(which survives as the degenerate never-suspends case). Three pieces:

- **Scheduler** (`lyric-rt/src/lyric_async.c`): single-threaded,
  cooperative, hot tasks; RUNNING/SLEEPING/WAITING/READY/COMPLETE
  states, FIFO ready queue, deadline-ascending timer list,
  `lyric_task_block_on` drive loop with deadlock detection; resumes
  frames only through the IR-defined `lyric_coro_resume`/
  `lyric_coro_destroy` wrappers (fastcc hazard). Covered by six C
  unit tests driving the exact codegen protocol over fake handles.
- **Emission** (`Lyric.LlvmCodegen`): `async func` → `define i8*
  ... presplitcoroutine` returning its `LyricTask*`; coro.id/alloc/
  begin prologue + `lyric_task_new`; returns lower to defers + ARC
  releases + `lyric_task_complete` + branch to the shared
  final-suspend block; awaits at non-`spawn` call sites auto-unwrap
  (is-complete check, park-and-suspend in coroutines,
  `lyric_task_block_on` in sync contexts); `spawn` keeps the
  un-awaited `__task<T>` value (ARC-managed); ref-typed params are
  retained on coroutine entry (borrows do not survive suspends).
- **Async leaf**: `Std.Time.sleepMillis` inside a coroutine emits
  `lyric_async_sleep` + suspend (parks only the calling task);
  synchronous contexts keep the blocking kernel twin.

Verified by seven new `llvm_self_test_async.l` cases (20 total; the 13
pre-coroutine cases now run through the coroutine path): two spawned
sleepers whose effect order proves genuine interleaving, the same under
ASan, an await chain through a sleeping leaf, String args/results
across suspends under ASan, and the named un-awaited-task diagnostic.

## Phase N8 (cont'd): the async process leaf (Phase 2, D-N-023)

**SHIPPED (D-N-023):** the first async I/O leaf. `lyric-rt` gains a
nonblocking capture op (`lyric_process_start`/`_pump`/`_kill`/
accessors/`_free` over the shared fork/execvp spawn path, `O_NONBLOCK`
pipes, `WNOHANG` reap, SIGKILL timeout preserving captured output;
three C unit tests). The native kernel twin gains
`Std.ProcessCaptureHost.hostRunCaptureListAsync`, pumping the op at
the JVM twin's documented 1 ms cadence with each iteration suspending
through the sleep leaf — honoring `timeoutMs` (managed-twin contract:
`timedOut`, exit -2). The backend redirects in-coroutine
`Std.Process.runCapture` calls to the seam and projects the kernel
Result into the call's `Result[ProcessResult, String]` (Ok payload via
the stdlib's own `projectResult`); the bridge's reachability walk
keeps the seam whenever `runCapture` is reachable. Six new
`llvm_self_test_async.l` cases, including two spawned captures
completing in reverse spawn order — impossible if either blocked the
scheduler — and the same overlap under ASan. `poll()`-based scheduler
fd readiness is deferred to the socket leaf.

## Phase N8 (cont'd): process capture parity — stdin + sync timeout (Phase 2, D-N-024)

**SHIPPED (D-N-024):** the runCapture half of #4752 closed. The child's
stdin is always piped (managed `RedirectStandardInput` parity;
`F_DUPFD`-lift-then-`dup2` child fd wiring; SIGPIPE-safe writes via
macOS `F_SETNOSIGPIPE` / Linux mask-write-consume). `lyric_process_run`
takes `stdin_content` + `timeout_ms` + `out_timed_out`: nonblocking
stdin writes interleave with output reads in the poll loop (a blocking
`> PIPE_BUF` write would deadlock against a full child stdout pipe),
the deadline SIGKILLs with bounded post-kill drain, and `timedOut`
follows the #5107 kill-vs-exit contract. The async op copies stdin at
start and flushes it from its pump. Both kernel seams drop their stdin
`Err` guards; the sync seam normalizes timeout to exit -2.
`runCaptureWithInput` gains the same in-coroutine async-seam redirect
(the /4 intercept). Seven new C tests (clang + gcc: cat round-trip,
256 KiB no-deadlock, EPIPE drop, sync deadline kill, deadline kill
with stdin still in flight, grandchild-writer drain budget, async op
stdin) and four new `llvm_self_test_async.l` cases (30 total).

## Phase N8 (cont'd): process-group deadline kills (Phase 2, D-N-025)

**SHIPPED (D-N-025):** the D-N-024 process-tree-kill deferral closed.
Every capture child runs in its own process group (double setpgid,
child + parent) and both deadline kill sites send
`kill(-pid, SIGKILL)`, so a timed-out `sh -c` pipeline no longer
leaves grandchildren running — the managed twin's
`Kill(entireProcessTree: true)` semantics without the descendant-walk
race. #5107 contract unchanged; the #5176 drain budget remains the
backstop for `setsid` escapees. Documented trade-off: a
group-isolated child no longer receives terminal Ctrl+C with the
parent (parent death still closes the pipes). Verified by the
tightened grandchild-writer C test (EOF-based exit under 2 s; a
child-only-kill regression cannot finish before ~2.3 s), a
new setsid-escapee budget test (self-skips without `setsid`(1)), and
one new `llvm_self_test_async.l` case (31 total).

---

## Phase N9: Native HTTP + TLS transport (epic #5874 phase 5, issue #5890)

Depends on: Phase N4 (FFI boundary) complete; the sans-IO `Std.HttpEngine`
(#5883, merged). This is the native counterpart to the dotnet `Std.TcpHost`
(#5882) / `Std.HttpServer` (#5884) transports and drives the SAME engine —
per docs/61 decision 6/8, the protocol logic is target-independent and only
the transport kernel is per-target. Design: docs/61 §7 (OpenSSL 3.x-dynamic
seam), D128 decision 10.

The band splits the "native HTTPS" work into a verified C foundation (N9.1,
shipped) and the Lyric-level integration layers that sit on top of it, each a
follow-on PR gated on a stdlib native-port prerequisite.

### N9.1 — `lyric_tls_*` / `lyric_sock_*` seam in `lyric-rt` (OpenSSL 3.x) ✅ SHIPPED (D-progress-703)

The narrow C transport seam that everything else builds on:

- **`lyric_sock_*`** — a blocking POSIX socket transport (connect / listen /
  accept / local-port / read / write / close). No OpenSSL dependency.
- **`lyric_tls_*`** — a TLS seam over OpenSSL 3.x loaded DYNAMICALLY with
  dlopen/dlsym on first use, so `lyric_rt.a` has NO link-time dependency on
  libssl/libcrypto and the seam can be re-pointed at mbedTLS (static/musl)
  by swapping `src/lyric_tls.c` alone (the swappable-seam intent of D128
  decision 10). Covers: context create/free (client + server), PEM cert/key
  load, client connect + handshake (SNI + RFC 6125 hostname verification
  hard-wired on, with the docs/61 §4 dual-key insecure override), server
  accept + handshake, read / write / shutdown, ALPN advertise/select on
  both roles, mTLS (client-CA verify + require-client-cert), a thread-local
  `lyric_tls_last_error` diagnostic, and an `lyric_tls_available` probe.
  Handles are raw malloc'd resources freed explicitly (the `lyric_process_*`
  op discipline); the ARC-managed lifetime (docs/61 §7 item 4) is realised
  in the N9.2 twin's opaque-type destructors.

Verified by `lyric-rt/test/lyric_tls_test.c` (real loopback handshakes with
an embedded EC test PKI: plain byte round-trip, server-auth TLS + ALPN
negotiation, TLS 1.3 floor, mTLS accept, mTLS reject, hostname-mismatch
rejection, insecure-skip-verify), run in CI under clang + gcc via
`make -C lyric-rt test` plus an ASan run (`make -C lyric-rt test-asan CC=gcc`)
so a leaked SSL_CTX/SSL/fd or use-after-free fails the run. `llvm_bridge.l`'s
native link gained `-ldl` (inert for non-TLS binaries — a program that never
references the seam does not pull `lyric_tls.o` from the archive).

### N9.2 — `Std.TcpHost` native twin (`_kernel_native/tcp_host.l`) — ✅ SHIPPED (D-progress-712, #6103)

**SHIPPED (D-progress-712):** the `extern func` bindings for the N9.1 seam
and the `Std.TcpHost` public surface on native (the plaintext transport +
`hostAcceptTls`/`hostUpgradeServerTls`/`hostAlpn`/read/write/close), plus
its two gating prerequisites (`_kernel_native/encoding_host.l`,
`_kernel_native/tls_host.l`). Two corrections to this item's original plan
text, both forced by reading the compiler/seam source first rather than
assuming:

- **Not an `opaque type`.** At the time this item shipped, `Llvm.Codegen`'s
  native item-kind dispatch had no `IOpaque` case (it panicked on one) and
  no Lyric-level mechanism existed for a heap type's destructor to run
  custom free() cleanup on a raw resource field — two real, verified
  compiler gaps, both tracked as issue #6234. The first (`IOpaque` codegen)
  has since shipped (#6234 part 1, D-progress-713 — see the "Compiler-level
  prerequisite" paragraph below); the second (the custom-destructor hook)
  remains open and is now the SOLE reason this file still uses plain
  records rather than `opaque type`. `Listener`/`Conn` are plain `pub
  record`s with package-private fields instead (the
  `_kernel_native/process_capture_host.l` `ProcessCaptureResult` "public
  type, private fields, public accessors" shape already in this tree), with
  `hostClose`/`hostStopListener` as the explicit always-must-be-called free
  path — matching the dotnet twin's own explicit-`Dispose`/`Close` contract
  (no GC finalizer exists on that managed target either; `Std.TcpHost` has
  no JVM twin to compare against).
- **The ARC-managed-lifetime raw handle is a `Long`, not a `NativePtr[Byte]`.**
  `Conn.tlsConnHandle` must survive across separate top-level calls
  (`hostAcceptTls` constructs it, `hostRead`/`hostWrite`/`hostClose` use it
  later), and the mode checker's N0100 boundary documents storing
  `NativePtr[T]` in a record/union field as rejected unconditionally (heap
  storage outlives any frame) — a real invariant, honoured here even though
  its enforcement entry point (`checkNativeFfiBoundary`) is defined but not
  yet wired into the native bridge's pipeline. Every `lyric_tls_*` handle is
  declared `Long` at both its extern-func return and parameter positions
  instead (the JNI-`jlong`-style "opaque handle as integer" idiom) — sound
  because a pointer and an `i64` are the identical machine word on every
  native-target triple today (x86-64/AArch64, both LP64).

Two new `LyricList[Byte]`-bridging seam functions
(`lyric_sock_read_bytes`/`_write_bytes`, `lyric_tls_read_bytes`/
`_write_bytes`) support `hostRead`/`hostWrite`, mirroring
`lyric_file_read_bytes`'s own byte-list construction; two new
`LyricString*`-returning conveniences (`lyric_tls_last_error_string`,
`lyric_tls_alpn_string`) avoid Lyric-side raw-buffer marshaling for
diagnostics/ALPN. `_kernel_native/tcp_host_self_test.l` is instead
`lyric-compiler/lyric/llvm_tls_self_test.l` (matching the `llvm_*_self_test.l`
naming convention this tree already uses for tests that import `Lyric.*`
compiler packages to drive `compileToNativeWithFlags`), wired into the
`native-backend-self-tests` CI job, ASan-compiled. At the time this item
shipped the file carried only THREE cases, not the four originally
planned: `Std.Encoding` round-trip and `Std.TcpHost` plain (non-TLS)
round-trip passed as planned, but the PEM-loading case could only exercise
`Std.TlsHost.hostCertFromPemBytes`/`hostIdentityFromPemBytes` (the kernel
boundary) directly rather than through `Std.Tls`'s opaque
`Certificate`/`Identity` wrapper, and the fourth case (a real loopback TLS
handshake via `hostAcceptTls`) was dropped entirely — both cuts traced to
#6234 (native `opaque type` codegen, confirmed by direct repro against
both construction and generic-argument resolution), see D-progress-712's
"CI failure diagnosis and fixes" addendum in `docs/03-decision-log.md` for
the full root-cause breakdown at the time. **This is now stale**: with
#6234 part 1 shipped (see the "Compiler-level prerequisite" paragraph
below), the file's item B was re-added through `Std.Tls`'s real public API,
with the original kernel-boundary variant kept alongside for defense in
depth. **The originally-planned loopback-handshake case (item D) has since
shipped too (D-progress-807):** a real client/server TLS handshake, server
side through `Std.TcpHost.hostAcceptTls` on the main thread, client side on
a genuine second pthread (the concurrency the deferral note above called
for — a handshake, unlike a plain-TCP connect, needs both peers actively
pumping I/O at once). The client thread binds the already-existing
`lyric_tls_client_*` seam functions directly as test-local `extern func`s
rather than through a new `Std.TcpHost`/`Std.TlsHost` public API: N9.2's own
`_kernel_native/tcp_host.l` header is explicit that client TLS is N9.4's
scope (#6105, `Std.Http`), not N9.2's, so item D deliberately does not add
a `hostConnectTls`-shaped function that would preempt that boundary. Item D
was `hostAcceptTls`'s FIRST native invocation ever, and it surfaced two
previously-latent `Lyric.LlvmCodegen`/`Lyric.LlvmBridge` bugs in resolving
`buildServerCtx`'s cross-package UFCS call `cfg.identity.rawHandle()` — an
extension-method-style declaration (`internal func Identity.rawHandle(...)`)
whose declared name carries its receiver type: (1) `lowerUfcsCall`'s
struct-receiver signature lookup never tried the receiver's full type name
joined with the call-site name (only a legacy D037-shaped fallback); (2) the
bundled-compile reachability walk's `callKeyOf`-based call-edge tracing
can't see a UFCS call on a value receiver at all, so `Identity.rawHandle`
was pruned as unreachable before (1) could even matter — fixed with a
bare-member-name reachability fallback resolved through a NEW multi-valued
map (not folded into the existing single-valued one, since `Std.Tls` itself
has two same-named/arity extension methods, `Certificate.rawHandle` and
`Identity.rawHandle`, that would otherwise silently collide). See
`llvm_tls_self_test.l`'s module header and D-progress-807 for the full
reasoning and the four-case test now shipped.

**Prerequisite (SHIPPED alongside):** the `Std.TcpHost` surface takes
`Std.Tls.TlsServerConfig`, so `Std.Tls` must compile on native first —
`_kernel_native/tls_host.l` (`Std.TlsHost` twin: PEM cert/key load via the
seam) and `_kernel_native/encoding_host.l` (`Std.Encoding`'s native twin,
porting the JVM twin's pure-Lyric accumulator verbatim rather than the
.NET twin's BCL-erasure workaround, which does not apply to native's
genuinely byte-typed `lyric_rt` list kernel). `Std.TlsHost`'s native
`CertHandle` holds PEM text directly (not a parsed OpenSSL object — the
seam has no standalone parse-only function, only PEM-text-taking context
constructors), with eager load-time validation added to the seam itself
(`lyric_tls_validate_cert_pem`/`_key_pem`/`_identity_pem`, reusing the
seam's own internal parse path) to match the dotnet/JVM twins' contract.

**Compiler-level prerequisite ✅ SHIPPED (#6234 part 1, D-progress-713):**
`Std.Tls`'s `Certificate`/`Identity` — and every `opaque type` this band's
"wrap the raw handle in an opaque type" idiom depends on — could not compile
for `--target native` at all: `Llvm.Codegen`'s item-kind dispatch had no
`IOpaque` case (single-file compiles panicked; bundled stdlib compiles
silently dropped the item). Fixed by reshaping an `OpaqueTypeDecl` into the
equivalent `RecordDecl` at collection time, so opaque types share every
record code path (layout, construction, field access, ARC destructor
synthesis) — opacity is a front-end visibility concern, not a codegen one.
A `@projectable opaque type` is refused with a clear `N0101` diagnostic
rather than silently compiled with lost projection semantics (#6239) — a
custom-destructor hook for an opaque type wrapping a raw resource (the
`lyric_tls_*`/`lyric_sock_*` handle this section's ARC-managed-lifetime note
above refers to) is a separate, still-open gap (#6234 part 2) — this fix
only makes an opaque type's ordinary ARC-managed fields release correctly,
not a raw-resource cleanup hook. **This item now closes end to end**: #6235
shipped the stdlib native kernel ports this paragraph originally called
un-shipped (`_kernel_native/tls_host.l`, `_kernel_native/tcp_host.l`,
`_kernel_native/encoding_host.l`), and with both the compiler-side blocker
and the kernel ports landed, `Std.Tls.Certificate.fromPem`/`Identity.fromPem`
— the real public API, not a kernel-boundary stand-in — now compile and
construct correctly end to end for `--target native`, verified by
`llvm_tls_self_test.l`'s re-added item B.

### N9.3 — `Std.HttpServer` native twin — ✅ SHIPPED (D-progress-850, #6104)

The thread-per-connection server model (docs/61 §7 item 5) over the existing
pthread FFI kernel: an accept loop spawning one handler thread per
connection, each pumping `hostRead` bytes through its own
`Std.HttpEngine.Connection` and writing serialized responses back. Replaces
the `_kernel/http_server.l` .NET-specific concurrency (Task.Run /
ConcurrentQueue / SemaphoreSlim) with the native thread model. Gated on N9.2.

**SHIPPED (D-progress-850).** `_kernel_native/http_server.l` implements the
same twelve-function `Std.HttpServer` surface as the dotnet/JVM twins
(`startListener`/`nextContext`/`stopListener`/`requestMethod`/`requestPath`/
`requestBody`/`requestQuery`/`requestHeaders`/`urlDecode`/`respondText`/
`respondJson`/`respondBytesWithHeaders`) plus `startListenerTls`, following
the dotnet twin's architecture (drive `Std.HttpEngine`'s per-connection FSM
over `Std.TcpHost`), not the JVM twin's (bypass the engine via the JDK's own
`HttpServer`). Concurrency is thread-per-connection over real
`pthread_create`d OS threads; the pull-model hand-off queue (a background
thread parses a request and blocks until a puller thread responds) is built
directly from D-progress-809's `lyric_mutex_*`/`lyric_sem_*` primitives —
there is no BCL `ConcurrentQueue`/`SemaphoreSlim` equivalent on native. Every
raw mutex/semaphore buffer handle is stored as `Long`, not
`NativePtr[Byte]` — the same "opaque handle as integer" trick N9.2's own
`Conn.tlsConnHandle` already established, needed because the mode checker's
N0100 boundary rejects a `NativePtr[T]` record/union field outright.
`stopListener` deterministically `pthread_join`s the accept thread and every
spawned connection thread before freeing the queue's buffers — a stronger,
blocking-until-fully-drained shutdown contract than the dotnet/JVM twins'
fire-and-forget one (their own `stopListener` doc comments say in-flight
connections finish independently, garbage-collected once idle), needed
because native has no GC to defer the `malloc`'d-buffer cleanup to.

**Scope: HTTP/1.1 only, no h2, no backpressure cap.** `_kernel_native/
tcp_host.l`'s TLS accept path unconditionally advertises `"h2,http/1.1"` as
its ALPN preference (shared with `Std.HttpHost`'s client kernel and the TLS
self-tests — narrowing it here is out of scope), so a connection that
actually negotiates `h2` is closed immediately by `onAccepted` rather than
fed to the HTTP/1.1 parser (which would otherwise silently misinterpret h2's
binary framing as HTTP/1.1 text) — native ALPN-selected h2 is N9.5's job,
already gated on this item. The dotnet twin's `LYRIC_HTTP_MAX_CONNECTIONS`
backpressure cap (#6071) does not ship here: it needs `Std.Parse.
tryParseInt` to read the environment override, and `Std.Parse` has no
`_kernel_native/parse_host.l` twin yet — a disclosed v1 scope decision, not
a silent omission.

Verified by `lyric-compiler/lyric/llvm_http_server_self_test.l` (nine
cases, ASan-compiled): item A is a plaintext HTTP/1.1 round trip (client and
server on the same process, no second thread needed — a bare TCP `connect`
completes into the listen backlog before `accept` runs); item B is a real
concurrent TLS round trip, with the client on a genuine second
`pthread_create`d OS thread driving N9.4's real public
`Std.TcpHost.hostConnectTls` API (no hand-rolled raw `lyric_tls_*` driver
needed, unlike N9.2/N9.4's own self-tests, which predate `hostConnectTls`'s
existence); item C drives the h2-rejection guard end to end by having the
client genuinely negotiate `h2` ALPN and asserting the server closed the
connection rather than hanging or echoing garbage back; item D is a
keep-alive round trip (two requests over one connection, neither carrying
`Connection: close`); item E is the **#6791 regression**:
`stopListener` hung forever on any genuinely idle keep-alive connection
(`Std.HttpEngine` defaults `keepAlive = true`, so this was the default
HTTP/1.1 behavior, not an edge case) because `stopListener` only ever
closed the LISTENING socket, never an already-accepted connection's own
fd — fixed by having `Std.TcpHost` grow `hostFd`/`hostShutdown` (a raw
`shutdown(fd, SHUT_RDWR)` that interrupts a blocked read/write from
another thread without releasing the descriptor) and tracking every
accepted `Conn` in `ServerQueue.activeConns`, `hostShutdown`-ing each one
once the accept thread has joined and before joining every handler
thread; item F is the **#6792 regression**: `spawnHandler` registered a
connection into `activeConns` AFTER spawning its handler thread, racing
that thread's own `unregisterConn` for a connection that finishes fast
enough (a connect-then-immediate-disconnect health-check/scan pattern),
which could leave a permanently stale, already-closed (and potentially
fd-reused) entry behind for a later `stopListener` to `hostShutdown` —
fixed by registering BEFORE spawning the thread, so the child's own start
is always ordered after its registration exists; item G is the
**#6795 regression**: `stopListener` snapshotted `activeConns` under the
queue mutex, released it, then called `hostShutdown` on each entry with
no further synchronization, so a connection finishing NATURALLY and
concurrently (an ordinary `Connection: close` exchange completing while
`stopListener` runs — the common graceful-shutdown case under real load,
not an edge case) could be `unregisterConn`'d and `hostClose`'d by its
own thread between the snapshot and its `hostShutdown` call, shutting
down an already-closed, potentially fd-reused descriptor — fixed by
holding `q.mutex` across the ENTIRE snapshot-then-shutdown sequence
(not just the snapshot), which makes the race impossible by
construction rather than merely unlikely; item G's own role is to prove
`stopListener` still completes cleanly and promptly against twenty
concurrent real connections racing their own natural completion; item H
is the **#6802 regression**: `stopListener` unconditionally
`rtMutexDestroy`/`rtFree`'d the queue mutex and
`rtSemDestroy`/`rtFree`'d the semaphore even while a caller-owned puller
thread could still be genuinely parked inside `nextContext`'s blocking
`rtSemWait` — a real ASan use-after-free the instant that thread next
touched the freed buffer — fixed by a `ServerQueue.waitingPullers`
counter `stopListener` checks under the same mutex immediately before
freeing (nonzero means a live wait is provably still parked, so
`stopListener` does not free; instead it calls a new
`lyric_lsan_ignore_leak` runtime primitive, wrapping LeakSanitizer's
`__lsan_ignore_object`, since a plain unconditional "never free" was
confirmed by direct repro to still fail a real ASan+LSan run — this
project's condvar-backed semaphore does not reliably keep the buffer
reachable from the blocked thread's own stack); item I is the
**#6803 regression**: `enqueueContext` released `q.mutex` BEFORE
`rtSemPost`ing the availability credit, so a handler thread preempted in
that exact window could have its already-`items.add`'d context orphaned
by `stopListener`'s abandoned-queue drain (which trusted `rtSemTryWait`
as its sole "anything left" signal) — fixed by moving the post inside
the same critical section as the add, making "item present" and
"credit posted" atomic from every other thread's point of view.

**Sandbox/CI-validator boundary (same class as D-progress-712/809/823).**
This session could not run `scripts/bootstrap.sh --stage 0`/`--stage 1`
(GitHub release-artifact download is network-policy-blocked in this
sandbox) and confirmed, by direct repro, that the already-installed NuGet
`lyric` v0.5.1 global tool cannot substitute here either: it predates the
`NativePtr`/`nativeAddrOf`/`nativeNullPtr` FFI surface entirely (`error
[T0010] unknown type name 'NativePtr'` on a minimal repro reproducing
`llvm_ffi_self_test.l`'s own already-shipped pthread idiom verbatim) as well
as `.indexOf`/`.startsWith` (#6588/D-progress-831) and the bare-enum-case fix
(#6589/D-progress-830) this item's own kernel depends on. `make -C lyric-rt
test`/`test-asan` pass locally (unchanged C runtime, exercising the exact
`lyric_mutex_*`/`lyric_sem_*` this kernel calls). The single-thread half of
the queue design DID verify locally against the old tool: a minimal
standalone repro of `ServerQueue`'s exact shape (`rtMalloc`+`rtMutexInit`+
`rtSemInit`, `rtMutexLock`/`List[Int].add`/`rtMutexUnlock`/`rtSemPost` to
enqueue, `rtSemWait`/`rtMutexLock`/`List[Int]` index-`0`+`removeAt(0)`/
`rtMutexUnlock` to dequeue, `rtMutexDestroy`/`rtSemDestroy`/`rtFree` to tear
down) compiled and ran correctly (5 enqueued values, summed back out to the
expected total, real exit code 0) — confirming the codegen for `Long`-typed
extern handles, `List[T]` as the shared mutable queue backing store, and the
mutex/semaphore call sequence all work as designed. The moment a repro adds
`pthread_create` — needed to actually exercise the queue ACROSS threads, and
needed by every accept-loop/connection-thread spawn in this kernel — the old
tool's `NativePtr` gap blocks it (confirmed: even `llvm_ffi_self_test.l`'s
own already-shipped, already-CI-green pthread idiom, copied verbatim, fails
the same way on this tool). The cross-thread half of the design is therefore
CI-verified only, exactly the boundary D-progress-712/809/823 already
documented for this same issue
lineage.

**Prerequisites SHIPPED (D-progress-809):** `lyric_sem_*` (a counting
semaphore — native had no blocking wait/signal primitive at all) and
`List[T]`/`slice[T]` `.slice`/`.concat`/`.append` (`Std.HttpEngine.feed`'s
buffer bookkeeping needs both on nearly every parse step).

**BLOCKED, not yet shippable.** With both prerequisites in place, drafting
the `_kernel_native/http_server.l` kernel (the same 12-function surface as
the dotnet/JVM twins + `startListenerTls`, over a real
`pthread_create`-per-connection accept loop, using a
self-unregistering-closure pattern keyed by fd to solve the detached
thread's userdata lifetime problem — see D-progress-809 for the design)
surfaced two further, architectural native-backend gaps independent of
this item's own scope: native `String` had no
`.trim`/`.toLower`/`.indexOf`/`.startsWith`/`.contains`/`.endsWith`
(#6588), and a bare cross-package enum-case value reference (`val v:
HttpVersion = Http1_1`, used throughout `Std.HttpEngine`) failed to
resolve (#6589). Both blocked `Std.HttpEngine`/`Std.String` from compiling
for `--target native` at all — the draft kernel could not be made to
compile, so it was **not committed**; neither `_kernel_native/http_server.l`
nor a self-test for it exist anywhere in the repository.

**Both blockers are now SHIPPED — N9.3 itself remains open, pending only
its own kernel work.** #6589 (bare enum-case resolution): `ctx.enumDefs`
indexes a case's bare name too, mirroring `Msil.Codegen.registerEnumDeclMsil`,
so `Http1_1` (and any other bare, unqualified enum-case reference —
same-file or cross-package) resolves without requiring the
`HttpVersion.Http1_1` workaround (D-progress-830). #6588 (String methods):
`lyric_string_trim`/`lyric_string_to_lower`/`lyric_string_index_of`/
`lyric_string_starts_with`/`lyric_string_contains`/`lyric_string_ends_with`
(`lyric-rt/src/lyric_string.c`) plus the matching `Lyric.LlvmCodegen`
scalar-method dispatch (`lowerScalarMethodCall`, mirroring `.substring`'s
existing wiring) now lower all six methods for `--target native`,
byte-indexed like the existing `.length`/`.substring` (D-N-006) — ordinal
search for `.indexOf`/`.startsWith`/`.contains`/`.endsWith`, and a Unicode
`White_Space`-set-driven `.trim()` matching `Std.Char.isWhiteSpace`'s
code-point list exactly. `.toLower()` applies a genuine (not ASCII-only)
Unicode simple-case mapping across Basic Latin, Latin-1 Supplement, Latin
Extended-A, Greek, and Cyrillic — not the full Unicode Character Database
(no context-sensitive `SpecialCasing.txt` rules: no Turkish dotless-I, no
German ß expansion); widening script coverage is tracked in #6779
(D-progress-831). Verified by a new C unit test (`test_string_trim_case_search`
in `lyric-rt/test/lyric_rt_test.c`, run by `make -C lyric-rt test`) and
end-to-end cases in `lyric-compiler/lyric/llvm_codegen_self_test.l` (ASan-
compiled for the two heap-allocating methods) plus
`indexof_native_self_test.l` (the `import Std.String` → `Option[Int]`
gate, #6752), wired into the `native-backend-self-tests` CI job. A future
contributor picking up #6104/N9.3 starts from zero on the kernel itself —
neither compiler-level gap holds it back any longer.

### N9.4 — `Std.Http` native client twin (`_kernel_native/http_host.l`) — ✅ SHIPPED (D-progress-823, #6105)

**SHIPPED (D-progress-823):** `_kernel_native/http_host.l`, matching the
dotnet/JVM twins' public client surface (`hostDefaultClient`/
`hostClientWithTls`/`hostClientWithRedirects`/`hostMakeRequest`/
`hostWithHeader`/`hostWithStringBody`/`hostSendSafe`/`hostGetSafe`/
`hostPostStringSafe`/`hostReadBodyTextSafe`/`hostReadBodyBytesSafe`/
`hostStatusCode`/`hostResponseHeader`, plus the `*WithCancel*` variants), and
a client-TLS extension to `_kernel_native/tcp_host.l` (`hostConnectTls`/
`hostUpgradeClientTls`, mirroring `hostUpgradeServerTls`'s existing shape, and
a `TlsClientTrust` union covering system-default/additive-CA/exclusive-CA/
insecure trust). Two corrections to this item's original plan text, both
forced by reading the source first rather than assuming:

- **No sans-IO client engine exists to reuse.** `Std.HttpEngine` — this
  item's original "drive the sans-IO engine's client connection FSM" plan —
  is server-only (`_kernel/http_server.l`'s `Connection` type, with no
  client-side counterpart anywhere in the tree, dotnet or JVM). The client
  therefore speaks a genuine, from-scratch HTTP/1.1 wire protocol: RFC 9112
  request/status-line and header-line parsing, `Content-Length` vs
  `Transfer-Encoding: chunked` framing precedence, chunked-body decoding
  (including correct empty-trailer handling — chunk data is followed by
  exactly one more CRLF when there are zero trailer fields, not a second
  CRLF pair), and a 301/302/303/307/308 redirect loop with per-RFC
  method-downgrade rules. All of it is hand-rolled from `String`/byte
  primitives (`.substring`, `.length`, indexing, `+`, `==`) since neither
  `Std.String` nor `Std.Char` combinator helpers are used by design (module
  header documents the exact scope decision).
- **`Std.Http.HttpClient`'s interface surface does not lower on native at
  all today** — a pre-existing, general compiler gap, not specific to this
  kernel. Its seven methods are all `async func`, and `Lyric.LlvmCodegen`'s
  interface vtable dispatch (N3.2) lowers only non-generic, non-async
  abstract methods. Verified two ways: compiling a program that calls
  `Std.Http.defaultClient()` panics with `Lyric.LlvmCodegen: type
  'HttpClient' is not yet supported for --target native (Phase N1 lowers
  scalars and String only)`; an isolated same-shape custom interface
  (`interface Greeter { async func greet(...): String }`) confirms the
  general form with `Lyric.LlvmCodegen: interface method '.greet' on
  'T.Greeter' is not yet lowerable for --target native — only non-generic
  abstract interface methods dispatch through the vtable; default, generic,
  async, and Self-returning interface methods are deferred (N3.2)`. This
  compiler-level fix is out of this item's scope (a codegen change, not a
  kernel-boundary one); `_kernel_native/http_host.l`'s own module header
  documents it in full. The kernel is therefore the real, substantive
  deliverable, called directly rather than through `Std.Http`'s
  interface-returning builder surface (`HttpClientBuilder.build()`,
  `defaultClient()`, `clientWithRedirects`, …) — `Std.Http`'s free functions
  (`getAsync`/`postAsync`/`sendAsync`, which never touch the `HttpClient`
  interface) already call straight into this same kernel and will work
  unmodified once the interface-dispatch gap closes separately.

A new `lyric_tls_client_new_additive` seam function was added to
`lyric-rt/src/lyric_tls.c` (refactoring the existing `lyric_tls_client_new`
body into a shared `client_new_impl(..., additive)` helper): the existing
function treats a non-empty CA PEM as *exclusive* trust (only that CA
verifies), but docs/61 §3.2's `withCaCertificate` client-builder option is
*additive* (system default trust plus the supplied CA) — the seam had no way
to express that distinction before this item. `Std.TcpHost`'s
`buildServerCtx` also had two pre-existing UFCS calls
(`cfg.identity.rawHandle()`, `ca.rawHandle().certPem`) that were never
exercised until this item's self-test drove a live TLS accept through them —
both fixed to the explicit static-call form (`Tls.Identity.rawHandle(id)`,
`Tls.Certificate.rawHandle(ca).certPem`) alongside this item's own new code,
per the next paragraph's finding.

Several previously-undocumented native-codegen gaps surfaced during
implementation and were worked around (none are this item's to fix, all
newly confirmed by direct minimal repro, all cited in full in
D-progress-823): cross-package UFCS method calls do not resolve
(`method '.X' on this receiver is not yet supported for --target native`) —
worked around with explicit static calls everywhere; the `?` operator fails
specifically when the enclosing function is reachable from a *different*
package than the one that defines it (same-package `?` works) — worked
around by replacing every use in `http_host.l` with an explicit
`match { case Ok(v) -> v; case Err(e) -> return Err(error = e) }`; a
module-level `val` with a non-literal (e.g. slice-construction) initializer
is rejected (tracked as #5977) — worked around with zero-arg functions in
place of the two byte-pattern constants this kernel needed; and a bare
nullary enum-case reference (`A` instead of `EnumName.A`) fails to resolve
even within the same file, including as a record field's *default* value
when omitted at a construction site — worked around by always
fully-qualifying enum cases and supplying every field explicitly at
`TlsServerConfig` construction sites.

Verified by `lyric-compiler/lyric/llvm_http_client_self_test.l`, wired into
the `native-backend-self-tests` CI job, ASan-compiled: a real loopback HTTPS
round trip through `hostSendSafe` — TLS handshake against a self-signed
certificate pinned via `hostClientWithTls`'s exclusive-CA trust option (real
chain + hostname verification, not `withInsecureSkipVerify`), a 302 redirect
followed to a fresh TLS connection (this kernel never keeps a connection
alive, always `Connection: close`), and a two-chunk
`Transfer-Encoding: chunked` response body dechunked back to the original
text — with the server driving `Std.TcpHost.hostAcceptTls`/`hostRead`/
`hostWrite` directly on a second `pthread_create`d OS thread (a TLS
handshake needs both peers actively exchanging handshake records at once,
unlike a bare TCP `connect`, which completes into the listen backlog before
`accept` runs).

### N9.5 — lyric-web `serveTls` on native; ALPN h2 — ⛔ BLOCKED on two structural gaps (D-progress-852, #6106); blocker 1's `inout`/`out` root cause now ✅ SHIPPED (N9.6, D-progress-853, #6794)

lyric-web's `serveTls` onto the native `Std.HttpServer`, plus ALPN-selected
h2 (docs/61 §6.4) once the engine's h2 stack is target-independent. Gated on
N9.3 (✅ shipped, D-progress-850).

**Investigated in D-progress-852 and found blocked on two independent,
structural gaps — neither is a lyric-web change or an accept-loop wiring
change.** The "once the engine's h2 stack is target-independent" premise
above does not hold: `Std.HttpEngine.H2Conn`/`H2Frame`/`Hpack` use 49
`inout` parameters (`state: inout H2Connection` / `inout FrameDecoder`,
threaded through mutually-recursive frame dispatch), and native `inout`/
`out` parameter lowering does not exist at all
(`Lyric.LlvmCodegen` panics unconditionally, issue #6794) — confirmed via a
minimal standalone repro on a real `--target native` build, not merely the
grep count. Filed as **issue #6808**. Separately, `lyric-web` `serveTls`
on native needs the native build pipeline to support a multi-package
project/dependency graph at all — `buildOneNativeWithFeatures`
(`cli_build.l`) hardcodes the single-file `Emitter.emitNative` path for
`--target native`, never reaching `emitSingleFileOrProject` (the
`[project.packages]`/`[dependencies]` resolver dotnet/jvm use), and
`findStdlibSourcesNative` (`emitter.l`) only ever resolves `Std.*` — so
**no** ecosystem library (`lyric-web`, `lyric-auth`, `lyric-resilience`, or
any other `lyric-*/` root library) can be imported into a native build
today, not a `lyric-web`-specific gap. Filed as **issue #6809**. Once
#6809 is closed, `lyric-web`'s own remaining per-file native-readiness tax
looks small (a `native` feature entry, `@cfg(feature = "native")` variants
of `serve`/`serveTls`/`buildRequest`/`writeResponse`/`pathGetFullPath`, a
native `Web.Kernel.Runtime` rate-limiter kernel, and fixing the two bare-
`String`-index sites in `web.l` per #6237) — see D-progress-852 for the
full evidence trail and the exact commands used to verify each finding.

**Open questions (docs/61 §9):** Q-TLS-001 (macOS native trust: the seam
uses `SSL_CTX_set_default_verify_paths` + `SSL_CERT_FILE`/`SSL_CERT_DIR` on
both OSes for now; the Security.framework question is deferred). Q-TLS-004
(session resumption / 0-RTT policy — 0-RTT off; resumption cache tuning is a
later item).

**Update (N9.6, D-progress-853):** blocker 1's root cause (#6794 — native
`inout`/`out` parameter lowering did not exist at all) is now fixed and
verified against a real `--target native` build. This unblocks
`Std.HttpEngine.H2Frame`'s entire `inout FrameDecoder` dispatch chain (5
`inout` sites), which now compiles and runs on native standalone. It does
**not** close blocker 1 for the full h2 stack: `Std.HttpEngine.Hpack`'s
Huffman codec (`huffmanEncode`/`huffmanDecode`/`octetsToString`) calls
`Std.Char`'s char↔int bridge, and `Std.Char` has no `_kernel_native/
char_host.l` twin — its only kernel (`_kernel/char_host.l`) is the
.NET-`System.Convert`-backed one, which the native loader still picks up
(no native-specific override exists) and which native codegen cannot lower
(`extern type CharConvert = "System.Convert"` has no native meaning). Real
HTTP/2 traffic always exercises Hpack's Huffman path (RFC 9113 header
compression is mandatory-to-implement), so `Std.HttpEngine.H2Conn`'s full
compile for `--target native` is still blocked — by a different, unrelated,
newly-surfaced gap, not by `inout`/`out` any more. Filed as issue #6811.
Blocker 2 (no native project/multi-package support, #6809) is untouched by
this update. See N9.6 below and D-progress-853 for the full verification
trail.

---

### N9.6 — Native `out`/`inout` function-parameter lowering — ✅ SHIPPED (D-progress-853, #6794; unblocks #6808)

`Lyric.LlvmCodegen`'s function-parameter lowering (`lowerFunctionEnv`)
panicked unconditionally on any `out`/`inout` parameter for `--target
native` — the only one of the three backends missing this. `out`/`inout`
are ordinary, documented Lyric parameter modes used pervasively on
dotnet/JVM (e.g. threading an evolving FSM-state value through a loop
without a wrapper record); native could not compile any function
declaring one.

**Design.** Each `out`/`inout` parameter's LLVM signature type becomes a
pointer to the parameter's own type (the ADDRESS of the caller's storage
cell) instead of the value itself. No callee-side alloca or copy: every
local read (`loadLocal`) and write (`lowerAssign`/`lowerFieldAssign`)
already treats `ctx.varSlots[name]` as a bare pointer-to-declared-type SSA
value (exactly what an `alloca` produces), so binding the parameter name
directly to the incoming pointer makes every subsequent read/write alias
the CALLER's cell — true reference semantics, matching the MSIL backend's
`MByRef` and the JVM backend's boxed-cell by-ref lowering. This also makes
a chained `inout` forward (a parameter received `inout` passed on
unchanged to another `inout` call — the shape `Std.HttpEngine`'s H2 frame
dispatch chain uses pervasively: `dispatchFrame` → per-frame-type handlers
→ nested mutators) a plain pointer forward with no extra copy, at zero
extra implementation cost. At call sites, an `out`/`inout` argument's
ADDRESS is computed instead of its value: a bare local/parameter uses its
existing `varSlots` entry directly; a record field access (`a.b.c`) GEPs
off the record's heap pointer exactly like `lowerFieldAssign` already
does for a direct field write. `out` and `inout` lower IDENTICALLY — the
only language-level difference (an `out` parameter is definite-assignment-
checked at type-check time, T0086) is not a codegen concern; a stray read
of an unwritten `out` parameter reads whatever the caller's cell already
holds, which is never uninitialized memory (every `var` local is zero/
null-initialized when declared without an initializer, and `lyric_release`/
`lyric_retain` on a null pointer are safe no-ops).

**ARC (04-arc-design.md Rules 3-5).** A write through the by-ref cell runs
through the ordinary `lowerAssign`/`lowerFieldAssign` retain-new/release-old
path — since the slot IS the caller's storage, this is exactly the ARC
bookkeeping a direct `x = newVal` at the caller site would perform. The
callee never retains on entry or releases on exit for an `out`/`inout`
parameter, matching Rule 5 (never owns the pointed-to value).

**Scope shipped:** scalar and reference-typed (record/`String`) `out`/
`inout` parameters; a bare local/parameter argument; a record field
(including nested, `a.b.c`) argument; chained `inout` forwarding through
nested calls; two independent `inout` parameters in one call. **Scope
cuts (loud diagnostics, never a silent miscompile):** `out`/`inout` on an
`extern func` C-ABI declaration (use `NativePtr[T]` instead — no
`_kernel_native/` file uses this shape); `out`/`inout` on a `protected
type` method (its hand-built lock/unlock wrapper forwards params by name,
not by address — unverified, no shipped consumer); `out`/`inout` on an
async function's parameter (a suspended coroutine cannot safely hold a
pointer into caller-frame storage across a suspend point); a by-ref
argument that is an index/element expression (`xs[0]`) or a qualified
module-level path — the type checker's `argIsValidByRefTarget` is
deliberately conservative and accepts these as "potential l-values" without
deciding whether native can address them, so the diagnostic lives in
`lowerByRefArg`. See D-progress-853 for the exact panic messages and test
coverage.

**Real-world validation:** `Std.HttpEngine.H2Frame`'s entire `inout
FrameDecoder` mutually-recursive dispatch chain (5 `inout` sites) compiles
and runs standalone on `--target native`. `Std.HttpEngine.Hpack`'s 6
`inout HpackDecoder`/`HpackEncoder` sites also compile; its Huffman codec
functions specifically do not, due to a separate, unrelated gap (`Std.Char`
has no native kernel, issue #6811 — see N9.5's update above). `Std.HttpEngine.H2Conn`'s
38 `inout H2Connection` sites are unverified in isolation (H2Conn always
transitively pulls in Hpack's Huffman path once real header traffic is
exercised) but hit no `inout`-related failure in every case tried.

Verified with a dedicated self-test,
`lyric-compiler/lyric/llvm_inout_self_test.l` (9 cases, 2 under
`-fsanitize=address`), wired into `scripts/ci/native-backend-self-tests.sh`,
plus a zero-regression run of the full existing native self-test suite.

---

### N9.7 — Native multi-package project build support (`[project.packages]`) — ✅ SHIPPED (D-progress-854, #6809); cross-project `[dependencies]` deferred (#6815)

Closes blocker 2 of N9.5 (D-progress-852): `--target native` could only
ever compile ONE `.l` entry file plus its transitive `Std.*` import
closure — `buildOneNativeWithFeatures` hardcoded the single-file
`Emitter.emitNative` path, and `buildProjectFromManifest` (the manifest
project-build entry point) hard-refused `--target native` outright. This
blocked EVERY `lyric-*/` root ecosystem library from being `import`ed
into a native build, not just `lyric-web`.

**Shipped:** `Lyric.LlvmBridge.compileProjectToNativeWithFlags` (compiles
N own packages, each fully lowered, plus the reachability-gated bundled
stdlib closure — mirroring the dotnet/jvm project bridges'
"own-packages-see-each-other" cross-registration, `Jvm.Bridge`'s #6024
precedent), `Lyric.Emitter.emitNativeProject` (merges multi-file packages
via the existing `mergePackageSources`, resolves the native stdlib
sources, dispatches into the bridge), and
`Lyric.Cli.buildProjectFromManifest`'s native branch (resolves `[native]`
triple/opt-level/extra-libs from the manifest, calls `emitNativeProject`
with the same `pkgs` list dotnet/jvm already build from
`[project.packages]`). Also fixed a real bug found during this work: the
native codegen's C-`main` synthesis only scans `units[0]`, a carry-over
single-source assumption — a manifest's `[project.packages]` has no
guaranteed declaration order relative to which package declares `main`,
so `compileProjectToNativeWithFlags` now reorders the assembled units so
the `func main`-declaring package is always first.

**Verified**: a synthetic 2-package project builds and runs end-to-end;
`lyric-web/lyric.toml`'s own 4-package `[project.packages]` (with its
`[dependencies]` stripped to isolate the mechanism) parses,
cross-package-type-checks, and reaches native codegen — failing only on
lyric-web's own already-tracked per-file native-readiness gaps (no
`native` feature, `pathGetFullPath`/`StaticFiles`/`WebTls` have no native
lowering yet), exactly as this item's task description predicted. Full
existing native self-test suite (12 files, 166 cases) passes unmodified;
new `llvm_project_self_test.l` (4 cases) added.

**Deferred, filed as #6815:** cross-project `[dependencies]`
(`workspace = true` / `path = "..."`) are not resolved into the native
bundle — `emitNativeProject` only ever consumes a project's OWN
`[project.packages]`, since native has no restored-binary concept the
way dotnet/jvm's NuGet/Maven restore does. A real sharp edge was found
(not silently accepted): `resolveManifestDependencies` still
unconditionally attempts to BUILD a `{ workspace = true }` dependency for
`--target native` even though the result goes unused, which surfaced as
an unhandled exception (routing through the pre-existing #6237
bare-`String`-indexing gap in `lyric-auth`'s own source) rather than a
clean skip/refusal when validating against `lyric-web`. `--triple`/
`--opt` CLI-flag threading into project-mode native builds, and `lyric
run`/`lyric test`'s manifest/project modes for native, are also deferred
to #6815 — only `lyric build --manifest ... --target native` shipped
here.

---

### N9.9 — Three native-codegen review-finding fixes: bare enum-case patterns, out/inout width mismatches, over-inclusive UFCS reachability — ✅ SHIPPED (D-progress-882/D-progress-883/D-progress-884, #6740, #6813, #6625, #6969, #6976)

Three independent review-finding follow-ups from N9.4/N9.6, all real
correctness gaps confirmed against current `main`:

- **#6740 — bare enum-case pattern silently binds instead of testing
  equality.** `emitPatternTest`'s `PBinding` arm only consults
  `scrutineeHasCase`, which only ever checks `unionInfoOfType` — always
  `None` for an enum (an enum erases to bare `NI32`, indistinguishable
  from a real `Int` by type alone). So `match v { case Http1_1 -> ...;
  case Http1_0 -> ... }` over an enum-typed `v` silently miscompiled: the
  first arm always matched as an unconditional catch-all bind, no
  diagnostic, just a wrong answer for every arm after the first. Fixed by
  extending `scrutineeHasCase` to fall back to `ctx.enumDefs.containsKey(name)`
  when the scrutinee's type is `NI32`, delegating to the SAME
  `emitConstructorTest` enum branch (`sv.ty == NI32` gate) #6753 already
  shipped. New item G in `llvm_enum_case_resolve_self_test.l`.
- **#6813 — no defensive check for a numeric-widened by-ref argument.**
  The type checker's `argSatisfiesParam` widens arithmetic uniformly
  across every parameter mode, so an `Int` local (or record field)
  type-checks against an `inout Long` parameter — but `lowerByRefArg`
  forwarded the raw address tagged with the CALLEE's declared type with
  no check against the argument's ACTUAL type, which would silently
  alias a 4-byte alloca through an 8-byte pointer. Fixed with a named
  panic (`"... must match the parameter's exactly ..."`) in both the
  bare-local and record-field branches of `lowerByRefArg`, matching
  N9.6's "loud diagnostic, never silent miscompile" scope-cut philosophy.
  Two new cases in `llvm_inout_self_test.l`.
- **#6625 — bare-name UFCS reachability fallback is over-inclusive
  across colliding trailing names.** `Lyric.LlvmBridge`'s
  `bareTrailing` fallback (added for #6103 item D — UFCS on a value
  receiver has no resolvable key at the syntax-only reachability stage)
  marks EVERY same-named/arity candidate in the whole bundle reachable,
  so two unrelated types sharing a trailing name (e.g. `.message()` on
  `TlsError`/`RestError`/`XmlError`/…) sweep each other in even when the
  calling package can't reach one of them at all. A precise fix needs
  receiver-type inference threaded into this syntax-only walk (larger,
  future work); this ships a real, SOUND partial narrowing instead: each
  bare-trailing candidate is now filtered to packages within the calling
  function's OWN transitive import closure (`pkgTransitiveClosure`, a
  new BFS over a `pkgImports` adjacency map built from every bundled/own
  file's own `imports`). Sound because the type checker requires a
  cross-package callee's package be imported (directly or transitively)
  for the genuinely-correct call to have type-checked at all — so the
  real target is always inside the closure; this can only narrow away
  UNRELATED candidates, never the correct one. Still over-inclusive when
  two colliding packages ARE co-imported (the general case still needs
  type inference) — documented as a partial fix, not closing the
  underlying issue's "what a real fix needs" scope. Two new unit-level
  cases in `llvm_codegen_self_test.l` exercise `pkgTransitiveClosure`
  directly (a linear closure with an unreachable sibling, and a diamond
  import graph) since no stdlib pair currently has both a colliding
  trailing name AND a not-yet-lowerable body to regression-test the
  full walk end-to-end.
- **Review fix (#6952) — `addPkgImports` first-file-wins dropped
  multi-file package imports.** Caught by `claude-review`: `addPkgImports`
  returned early once a package name was already a key in `pkgImports`,
  so a package split across multiple files (first-class per
  `docs/19-multi-file-packages.md`) only contributed the FIRST file's
  imports — every later file's imports for that package were silently
  dropped, which could wrongly narrow `pkgTransitiveClosure` away from a
  package the package's own later file genuinely imports. Fixed by
  merging into the existing list under `pkg` instead of skipping. New
  test in `llvm_codegen_self_test.l` parses two `SourceFile`s sharing one
  package with disjoint imports and asserts the merged closure contains
  both. Also applied the review's two SUGGESTIONs: an `out Long`
  mode-symmetry case in `llvm_inout_self_test.l`, and a clearer
  `lowerByRefArg` panic message.
- **Review fix (#6969) — #6740's own fix was reachable by an unrelated
  `Int`/`Char` scrutinee.** Caught by a second `claude-review` pass:
  `scrutineeHasCase`'s new `NI32` fallback checked
  `ctx.enumDefs.containsKey(name)` bundle-wide, with no check that the
  scrutinee is actually of that enum's type — since an enum, `Int`, and
  `Char` all erase to the same `NI32`, an ordinary catch-all bind over a
  real `Int`/`Char` whose bind name collided with ANY enum case anywhere
  in the bundle was silently reinterpreted as an equality test instead of
  binding, a hazard #6740's fix itself introduced. Fixed by mirroring
  `Msil.Codegen`'s `scrutEnumHint`/`inferScrutineeEnumHintMsil` (#5995): a
  new `Ctx.varEnumTypes` map records a local/param's declared enum type
  simple name (from `bindLocal`'s binding sites and function-parameter
  binding); `inferScrutineeEnumHint` reads it for a bare-`EPath` match
  scrutinee; `scrutineeHasCase` now scopes its `NI32` check to
  `enumHint + "." + name` — the scrutinee's OWN enum — instead of a
  bundle-wide bare-name check. An empty hint falls through to a plain
  bind, the pre-#6740 safe default. New item H in
  `llvm_enum_case_resolve_self_test.l`.
- **Review fix (#6976) — the #6969 fix's "empty hint" rule dropped
  #6740's coverage for hint-less scrutinees.** A third `claude-review`
  pass: `inferScrutineeEnumHint` only ever produces a hint for a bare
  local/param reference with a KNOWN declared type, so an untyped
  local, a direct call-result match, or a field-access scrutinee all
  yield `""` — and #6969's fix treated `""` as "conclusively not an
  enum," silently reproducing #6740's original unconditional-bind
  defect for those shapes. A naive "fall back to the bundle-wide check
  when hint is empty" fix regressed #6969's own test the other way: a
  plain `Int` PARAMETER also has an empty hint (concretely not an
  enum, not unknown), so the naive fallback re-enabled #6969's
  collision hazard. Fixed by making the hint three-way instead of
  two-way: a new sentinel `nonEnumScrutHint = "#nonenum"` (identifiers
  can't start with `#`, so it never collides with a real enum name) is
  returned for a scrutinee declared literally `Int`/`Char`.
  `scrutineeHasCase`'s `NI32` branch now reads three cases: a real enum
  name scopes the check to that enum (unchanged); the sentinel means
  unconditionally `false` (never falls back); a truly-empty hint falls
  back to the pre-#6969 bundle-wide check, matching `Msil.Codegen`'s own
  accepted trade-off (#5995). New item I in
  `llvm_enum_case_resolve_self_test.l` (a call-result enum scrutinee
  with no hint); confirmed items H and I pass simultaneously, which the
  naive single-fallback fix could not satisfy at once. Also factored
  the four `SLocal` binding arms' near-duplicated hint-registration
  code into one `registerVarEnumTypeFromOpt` helper per the review's
  SUGGESTION.

**Verified:** full existing native self-test suite re-run after the
original fixes, the #6952 review fix, the #6969 review fix, and the
#6976 review fix (`llvm_codegen_self_test.l` 35/35,
`llvm_enum_case_resolve_self_test.l` 9/9, `llvm_inout_self_test.l`
12/12, `llvm_project_self_test.l` 10/10, `llvm_stdlib_self_test.l`
18/18, `llvm_http_client_self_test.l` 13/13), no regressions.

### N9.8 — Weak-aware List/Map/Task kernels: `NativeWeak[T]` as a collection element or async result — ✅ SHIPPED (D-progress-879, #5545)

`lyric_list_new`/`lyric_map_new`/`lyric_task_complete`'s single boolean
element/value/result-is-ref flag becomes a tri-state (0 scalar, 1 strong
ref, 2 weak ref); `lyric-rt/src/lyric_collections.c` gains shared
`elem_retain`/`elem_release` dispatch helpers used by every List/Map
push/set/remove/dtor site, and `lyric_async.c`'s `lyric_task_dtor` gains
the same three-way dispatch inline. `Lyric.LlvmCodegen.refFlagOf` now
returns 2 for a weak type (checked before `isRefNType`, since
`NativeWeak[T]` IS ref-typed by that predicate) instead of the #5539
compile-time rejection. No codegen call-site branching changes needed —
every consumer already forwarded `refFlagOf`'s result opaquely. The
issue's own prerequisite (`List[NativeWeak[T]]` failing to parse) no
longer reproduces on current `main`. Verified: `lyric-rt`'s C unit
tests pass; three new ASan cases in `llvm_heap_self_test.l` (async
result, `List[NativeWeak[T]]`, `Map[K, NativeWeak[T]]`) each confirm
correct upgrade-while-alive AND "does not keep the target strongly
alive," leak-free; full suite 37/37, no regressions.

---

## Dependency graph summary

```
N0.1 ─┬─ N0.2 ─── N0.3 ─┬─ N1.1 ─── N1.2 ─── N1.3 ─┐
      └─ N0.4             │                             │
                          └─────────────────────────────┤
                                                        ▼
                                                N1.4 ─ N1.5 ─ N1.6 ─ N1.7 ─ N1.8
                                                                │
                          ┌─────────────────────────────────────┘
                          ▼
N2.1 ─── N2.2 ─── N2.3 ─── N2.4 ─── N2.5 ─── N2.6 ─── N2.7
  │
  ▼
N3.1 ─── N3.2 ─── N3.3 ─── N3.4 ─── N3.5
                                        │
          N4.1 ─ N4.2 ─ N4.3 ─ N4.4 ─ N4.5 ─ N4.6 ─ N4.7
                                                │
                                                ▼
                                N5.1..N5.9 (can parallelise within N5)
                                                │
                                                ▼
                                N6.1 ─ N6.2 ─ N6.3 ─ N6.4 ─ N6.5
                                                │
                                                ▼
                                        N7.1 ─ N7.2 ─ N7.3

```

Within each phase, items with no intra-phase dependencies can be worked in parallel.
