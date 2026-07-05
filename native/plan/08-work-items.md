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

---

### N5.5 — Update `Std.Uuid` for native

**Depends on:** N4.4 (`uuid.l` kernel exists)

Generate 16 random bytes via `getrandom`, format as UUID string.

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
