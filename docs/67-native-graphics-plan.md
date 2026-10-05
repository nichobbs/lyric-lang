# 67 - Native graphics, GPU and windowing: implementation plan (sketch)

**Status:** Specced in D155 (phase G0): Q-GFX-001 to Q-GFX-004 are
resolved, `docs/01` specifies the §4 language features as not yet
implemented, and `docs/00` / `docs/04` carry the §4.9 revisions. Phases G1
to G10 are open; G1's 32-bit `Float` (§4.1) and component-wise record
arithmetic (§4.6) have shipped on every backend.
D156 and D157 resolve Q-GFX-005 to Q-GFX-010 (§10).

**Builds on:** `native/plan/` (the LLVM backend, D-N-001 onward),
`docs/65-ui-library-sketch.md` §13.3 (non-HTML hosts), `docs/63-build-profiles-and-debugger.md`
(profile axis, #6263), `docs/35-js-wasm-component-sketch.md` (future WASM
target), `docs/39-package-registry.md` (lock-file checksums).

---

## 1. Motivation and scope

`lyric-ui` (docs/65) targets line-of-business screens rendered as HTML by
a host runtime. It does not cover native windowed applications, code
editors, or graphics-heavy programs such as games, and it cannot: every
event round-trips through a session loop, the widget set is closed, and
there is no drawing surface.

This plan covers the **building blocks** that make native graphical
programs possible in Lyric:

1. Language and backend features for data-oriented, allocation-free hot
   paths: a real 32-bit `Float`, by-value records, fixed arrays, a
   contiguous mutable buffer type, vector math.
2. FFI that can bind real C libraries (struct layouts, callbacks, generated
   bindings, native dependency resolution).
3. Libraries: windowing and input, GPU access, 2D drawing, text, a game
   loop, and eventually a native host for `lyric-ui`.

**Target:** `--target native` first and, for the libraries, only. Native
is the right backend for this work:

- ARC means no garbage-collector pauses in a frame loop
  (`native/plan/04-arc-design.md`).
- C FFI, `NativePtr[T]` and callback trampolines already exist (N4).
- LLVM optimises and auto-vectorises scalar code well.
- The same backend is the route to `wasm32` and browser WebGPU later
  (docs/35, docs/65 §13.1), so the GPU binding chosen here carries over.

The **language** features in §4 are defined for every target, per the
project's parity rule. Their MSIL and JVM lowerings are planned in §4 and
tracked as dated issues; they are not deferred silently. The graphics
**libraries** are native-only, declared as such in their manifests, the
same way `lyric-mq`'s backends are scoped per target today.

**Non-goals:** a general-purpose game engine or editor, console platforms,
ray tracing, a scene graph, physics, networking for games, and exposing
hardware intrinsics or inline assembly (still rejected, §4.6).

---

## 2. Decisions this plan proposes

| # | Question | Proposal |
|---|---|---|
| 1 | Backend | `--target native` for all graphics libraries; language features on every target. |
| 2 | Windowing, input, audio | SDL3 (C API, zlib licence), bound through `_kernel_native/`. |
| 3 | GPU API | `webgpu.h` (the `webgpu-native/webgpu-headers` C API), implemented by wgpu-native; Dawn is a drop-in alternative. Shaders in WGSL. |
| 4 | Text | FreeType (rasterisation) and HarfBuzz (shaping), glyph atlas on the GPU. |
| 5 | Mutable bulk data | `buffer[T]`, a contiguous buffer with **value semantics via copy-on-write** (§4.4). |
| 6 | Value types | All-by-value records and small unions lower without heap or ARC on native (§4.2), aligning the implementation with the reference's "records are value types". |
| 7 | `Float` | Becomes the 32-bit type the reference already says it is on MSIL and native; the JVM already complies (§4.1). |
| 8 | Vector maths | `Std.Math` vector, matrix and quaternion records; component-wise `derives Add, Sub` on homogeneous numeric records; no new operator overloading (§4.6). |
| 9 | C structs | `foreign record`, C-layout records declared only in kernel files (§4.7). |
| 10 | Bindings | `lyric bindgen` generates kernel files from `webgpu.yml` and from clang's JSON AST; generated code is checked in and CI checks it is current (§5.3). |
| 11 | Dependencies | Prebuilt native libraries per target triple, restored with checksums into the lock file (§6). |

---

## 3. Current state (audited 2026-10-01, `main` at 6c8bc68)

Each item was checked against the code, not only the plan documents.

| Area | State | Where |
|---|---|---|
| `Float` | Lowered to `double` on native (`typeExprToNType` maps `Float` and `Double` to `NDouble`) and on MSIL (`Float` maps to `MDouble`). The reference says 32-bit IEEE 754; `.toFloat()` is documented as "reserved pending backend support". The lexer already accepts an `f32` suffix. About 38 uses in stdlib and ecosystem sources. | `lyric-compiler/lyric/llvm_codegen.l:610`, `lyric-compiler/msil/codegen.l:8047`, `docs/01` §2.1 |
| Records | Always heap-allocated with an ARC header on native. The IR layer has no by-value aggregate ABI (D-N-016 note). On MSIL only all-primitive records become `readonly struct`. | `native/plan/03-type-mapping.md` "Record types" |
| Unions, `Option` | Heap-allocated with an ARC header on native, so an `Option[Vec3]` per frame is a `malloc`. | `native/plan/03-type-mapping.md` "Union types" |
| `List[T]` / `slice[T]` | Shared `LyricList` representation with uniform 8-byte `int64_t` cells: no packed `Float` or record storage, so data cannot be handed to a GPU or C API without a copy and repack. `slice[T]` has no in-place mutation. | `lyric-rt/include/lyric_rt.h:233-241`, D-N-015, `docs/01` §2.7 |
| `array[N, T]` | Parsed (`TArray`) and specified with range-subtype bounds-check elision; not lowered on native, and erased to an untyped object reference on MSIL and JVM. | `parser/parser_ast.l:261`, `docs/01` §2.7 |
| FFI | `extern func` with scalars, `String` and `NativePtr[T]`. Structs only by pointer, and there is no way to declare a C-layout struct. Callback trampolines require the userdata pointer to be the **last** parameter. | `docs/01` §11.6, `native/plan/05-ffi-design.md` |
| Platforms | Linux x86-64 and AArch64, macOS AArch64. No Windows. | `docs/01` §13.1 (`--target native`) |
| Concurrency | Cooperative, single-threaded scheduler. No safe multi-threading. | `native/plan/06-async-design.md` |
| Dependencies | Path and workspace `[dependencies]` compile from source into a native build (#7833, closing #6815). No library package carries its own `extern func` kernel yet, so a dependency that binds C symbols, and the propagation of its link flags to the application, are untested. | `docs/01` §13.1, `cli/workspace_builder.l` |
| Release codegen | Overflow checks are not gated on the build profile. | #6263 |
| Positioning | Before D155, `docs/00` listed "game developers needing hot-path optimization" as not the audience and described the memory model as host GC only, and `docs/04` rejected operator overloading beyond numeric distinct types. D155 revised both (§4.9); `docs/04` still rejects SIMD intrinsics. | `docs/00`, `docs/04` |

---

## 4. Language and backend design

### 4.1 `Float` becomes 32-bit

GPUs work in f32: vertex attributes, uniforms and most shader maths. An
f64-only language doubles upload bandwidth and needs a conversion pass
for every buffer.

- `Float` lowers to `float` (native) and `System.Single` / `R4` (MSIL).
  The JVM already lowers it to `float` (D-progress-464).
- A float literal is `Double` unless suffixed (`1.5f32`) or next to a
  `Float` operand, mirroring the integer-literal rule (#7346).
- `Float < Double` is already a lossless widening chain (reference
  §4.1); `.toFloat()` is implemented on numeric primitives, narrowing
  with round-to-nearest-even.
- Existing `Float` uses are audited: those that meant 64-bit move to
  `Double` in the same change.

This is a behaviour change for existing code, but it moves the
implementation onto the specification rather than changing the
specification.

**Shipped (G1).** All three backends lower `Float` to binary32. The
literal rule is wider than the second bullet above: an unsuffixed literal
also becomes a `Float` where a `Float` is required (a binding, argument,
default value, field, return value, list element, range bound or pattern),
and it denotes the binary32 value nearest its decimal text, rounded once.
`Float` renders with .NET's `Single.ToString()` rules on every target.
The audit found no stdlib `Float` that meant 64-bit; in the ecosystem,
`OTel.recordHistogram` moved to `Double` and `lyric-proto` dropped its
`Double`-to-`Single` narrowing workaround. Pinned by
`lyric-compiler/lyric/float32_self_test.l` on all three targets.

### 4.2 By-value records and small unions

A record with no `var` field is a value (D157). On native, such a record
whose fields are all by-value types (scalars, distinct types over
scalars, other by-value records, `array[N, T]` of those) lowers to an
LLVM aggregate with no ARC header: on the stack, in registers, inline
inside other values and inline inside `buffer[T]`. A union whose payloads
are all by-value lowers to an inline tagged struct, so `Option[Vec3]`
costs no allocation.

Work:

- A by-value aggregate ABI in the IR layer (`insertvalue` /
  `extractvalue` or memory-backed temporaries), and the C ABI for by-value
  struct arguments and returns per System V AMD64 and AAPCS64.
- ARC insertion skips by-value types entirely; a by-value record with no
  reference fields has no destructor.
- **Mutable records stay shared (D157).** A record with a `var` field
  has identity on every backend, so it keeps its heap representation; the
  by-value lowering applies only to records without `var` fields.

The language is unchanged; this is a codegen policy.

_Status:_ by-value **records** shipped on native (G1, #7940; progress entry
`2026-10-02-native-by-value-records`): a record with no `var` field whose fields
are scalars, enums, distinct types or other such records is an LLVM struct value
(`insertvalue`/`extractvalue`, no heap, no ARC), boxed only inside `List`/`Map`/
`Task` slots. Opaque types and generic instantiations over reference types
keep the heap form. An interface implementer stays a value too: an upcast
copies it into a box the interface value owns, and its vtable slots are thunks
that read it back out (#8010). An `extern func` taking or returning a by-value
record, directly or in a callback type, follows the platform C ABI on x86-64,
AArch64 and wasm32 (#8009): the record is coerced into registers, passed as
`byval` memory, or returned through `sret`, as clang lowers the same C
prototype, so `WGPUColor` or `SDL_FRect` cross by value. An inline array or
union in an `extern func` signature is still `N0010`, as is a by-value record on
a Windows triple (the Microsoft x64 and ARM64 C ABIs are not lowered; Windows is
not a native target yet, §6).

Inline **unions** shipped too (progress entry `2026-10-02-native-inline-unions`):
a union whose every case payload field is by-value (scalars, enums, distinct
types, by-value records, other inline unions; nullary cases are free) is the
struct value `{ i32 disc, i32 pad, [W x i64] payload }`, so `Option[Vec3]`,
`Option[Int]`, `Result[Int, Int]` and enums with scalar payloads cost no
allocation and no ARC. Generic unions classify per instantiation; unions with a
reference payload, recursive unions and `impl` targets keep the heap form.
The C ABI for by-value structs remains open (`array[N, T]` fields: §4.3).

### 4.3 `array[N, T]`

A fixed-length array with inline storage and value semantics: assigning
or passing it copies it. It is what C struct fields such as `float m[16]`,
matrices and small lookup tables need.

- Element writes `a[i] = v` need a writable place: a `var` local, an
  `out`/`inout` parameter, or a `var` field.
- Bounds checks are elided when the index is a literal in range or a
  NAMED range subtype that proves the access (an inline `Int range` annotation
  is not a proof). An integer index of any width is accepted; a non-`Int` one
  is range checked as a `Long`.
- Lowered to `[N x T]` on native, to a `List` on MSIL, and on the JVM to
  a typed Java array (`float[]`) for a numeric element and an `ArrayList`
  otherwise (D167, #8041).

**Status: implemented (D167, progress entry `2026-10-02-fixed-arrays`).**
Bracket-literal construction, zero fill, element writes, copies by the
ownership rule (an array stored into a writable place, or read from one and
escaping, is copied; immutable places are never copied), `.length`, `for`,
`.toSlice()`, `==` and named-range-subtype bounds-check elision work on all
three targets. On native an array of by-value elements is
an inline `[N x T]` with no allocation and a by-value record may hold one; any
other element type is a heap array. A value-generic length `N` (D167 item 6)
sizes a function's array parameters and, since D169, a record's array fields
(`record Mat[N: Nat] { var m: array[N, Float] }`), its methods specialised per
length on all three targets and the record one type on dotnet and the JVM and
one layout per length on native; such a record may be used from any package
(D173). Opaque types and unions take one the same way (D175); protected
types cannot yet (#7864). An array
in an `extern func` signature is open (N0010: C passes no array by value; pass
a `NativePtr` to its first element).

### 4.4 `buffer[T]`: contiguous, mutable, value semantics

This is the central language change, and the one with real design
weight.

```lyric
import Std.Buffer

record Vertex {
  pos: Vec3
  uv: Vec2
  color: Rgba8
}

func buildQuad(at: in Vec3, size: in Float): buffer[Vertex] {
  var vs: buffer[Vertex] = Buffer.filled(4, Vertex.zero())
  vs[0] = Vertex(pos = at, uv = Vec2(x = 0.0f32, y = 0.0f32), color = Rgba8.white())
  // ...
  return vs
}

func tint(vs: inout buffer[Vertex], c: in Rgba8) {
  for i in 0 ..< vs.length {
    vs[i] = vs[i].copy(color = c)
  }
}
```

**Shape**

- Runtime length fixed at creation, with `Buffer.filled`,
  `Buffer.fromSlice` and `grow` / `truncate` returning new lengths.
- Elements are stored packed and unboxed with C-compatible layout.
- `T` must satisfy `Plain` (§4.5).
- Reads are `b[i]`; writes are `b[i] = v` through a writable place, as for
  `array[N, T]`. Bounds-checked, with the same range-subtype elision.
- Views: `b.view(start, end)` is a read-only `slice`-like window that
  shares storage.

**Semantics: value, via copy-on-write.** A `buffer[T]` behaves like a
value. Assigning it, passing it as `in`, storing it in a field or
capturing it in a closure or `spawn` produces a logical copy. The
physical copy happens only when a write meets a buffer whose storage is
shared:

- On native, the storage block carries the ARC count. A write checks
  `rc == 1` (one load and a well-predicted branch), copies if shared, then
  writes in place. In a loop over a `var` or `inout` buffer the check
  stays true after the first iteration.
- On MSIL and JVM there is no reference count. The compiler marks a
  buffer value as shared whenever it copies the value (the cases above)
  and a write to a shared buffer copies and clears the mark. The mark is
  never cleared otherwise, so this is conservative: always correct, but
  sometimes copies where native would not. Native is the performance
  target; the managed targets get correct semantics.

**Alternatives considered**

| Option | Why not |
|---|---|
| Reference-semantic mutable buffer, like `List[T]` | Aliased mutation: a function that receives `in buffer[T]` could still write through it, two tasks could race on one buffer, contracts can be invalidated through an alias, and the verifier would need heap frame conditions. It would add exactly the shared mutable state that `protected type` exists to fence. |
| Ownership and borrowing (Rust-style) | `docs/00` rules out a borrow checker, and it would reach into every part of the language. |
| Immutable `slice[T]` only, rebuilt per frame | Allocates and copies per frame; the reason this plan exists. |

**Interop.** Safe code never sees a pointer. GPU uploads go through
`queue.writeBuffer(gpuBuf, offset, in vs)`, which copies, so lifetimes
never cross the FFI boundary. Kernel code (and `@unsafe_ffi` functions)
gets `b.withPointer(f)` and `b.withMutPointer(f)`; the latter first makes
the storage unique. The pointer may not escape the closure: the existing
`N0100` non-escape rule for `nativeAddrOf`, extended to these closures.
Zero-copy mapped GPU buffers come later and need the same non-escaping
closure form (`mapped.with { view -> ... }`).

**Parallel writes.** Splitting one buffer across threads, the core of a
job system, is a structured stdlib primitive rather than a language
feature: `Parallel.forChunks(inout b, chunkSize) { chunk -> ... }`, which
hands each worker a disjoint, non-escaping mutable window. It needs the
multi-threaded scheduler (G8) and can only be built by the runtime,
because only the runtime can guarantee disjointness.

### 4.5 The `Plain` marker

A compiler-derived structural marker (not user-implementable), in the
style of the D034 markers. A type is `Plain` when its bit pattern is its
whole meaning:

- scalars (`Bool`, `Byte`, `Int`, `Long`, `UInt`, `ULong`, `Float`,
  `Double`, `Char`);
- distinct types over `Plain` types **without** a range constraint;
- records with no `var` field whose fields are all `Plain` and which
  declare no `invariant:` (D157);
- `array[N, T]` of `Plain`;
- enums (as their ordinal).

Excluded, and why:

- **References** (`String`, `List`, closures, interfaces, non-by-value
  records): not meaningful as bytes.
- **Range subtypes and records with invariants**: a buffer can be filled
  by C code or read back from the GPU. Foreign writes bypass construction
  checks, so a range-typed element could hold an out-of-range value.
  Validated domain types stay out; convert at the boundary with
  `tryFrom`.
- **Opaque types**, outside their defining package: viewing an opaque
  value as bytes would crack its representational privacy.

`Plain` is what D034's dropped `Copyable` marker was missing (D-progress-807
dropped it because the front end had no layout information). `Plain` is
defined structurally, so the front end can compute it without asking a
backend.

### 4.6 Vector maths without general operator overloading

`docs/04` rejects arbitrary operator overloading and allows derived
arithmetic on numeric distinct types. This plan stays inside that
mechanism:

- `Std.Math` ships `Vec2`, `Vec3`, `Vec4`, `Mat3`, `Mat4`, `Quat` and
  `Rgba8` as by-value `Plain` records of `Float` (and `Byte`).
- `derives Add, Sub` is extended to **homogeneous numeric records** (every
  field the same numeric type) as component-wise operations: `a + b` on
  two `Vec3`s. This is the same "constrained derive" the out-of-scope
  entry already accepts, applied to records.
- Everything that is not component-wise between equal types is a method:
  `v.scale(s)`, `a.dot(b)`, `a.cross(b)`, `m.mul(n)`, `m.transform(v)`.

Whether this extension is acceptable is Q-GFX-004 (resolved yes, D155).
**Shipped (G1):** `@derive(Add, Sub)` on a non-generic record whose fields
share one numeric primitive type and which has no invariant; other derives
and shapes are T0152. The checker records each operator and
`Lyric.ContractElaborator.lowerRecordArith` rewrites it to a constructor over
the fields before any backend runs (`record_arith_self_test.l`, all three
targets). SIMD stays as `docs/04`
says: no intrinsics. Clang's SLP vectoriser handles small by-value float
records reasonably well. A portable `vector[N, T]` type lowering to LLVM
vectors is a later option, considered only if benchmarks show the
vectoriser falls short.

### 4.7 `foreign record`: C layout at the boundary

C APIs take nested descriptor structs: `WGPURenderPipelineDescriptor`
holds pointers to arrays of other structs and a `nextInChain` extension
chain, and `SDL_Event` is a 128-byte union. Lyric records cannot express
that layout, and should not have to.

```lyric
// lyric-gpu/src/_kernel_native/webgpu.l (generated)
foreign record WGPUColor {
  r: Double
  g: Double
  b: Double
  a: Double
}

foreign record WGPURenderPassColorAttachment {
  nextInChain: NativePtr[WGPUChainedStruct]
  view: NativePtr[WGPUTextureViewImpl]
  depthSlice: UInt
  resolveTarget: NativePtr[WGPUTextureViewImpl]
  loadOp: UInt
  storeOp: UInt
  clearValue: WGPUColor
}
```

- Allowed only in kernel files (Decision F: the extern boundary stays
  audited and in one place).
- Fields are `Plain`, `NativePtr[T]`, `array[N, T]` or other `foreign
  record`s, laid out with C alignment rules for the target triple.
- Passed by value or by pointer (`nativeAddrOf` on a `var` local),
  following the platform C ABI (§4.2's ABI work).
- C unions such as `SDL_Event` are a `foreign record` holding an
  `array[N, Byte]`, with typed accessors generated beside it.
- The public library surface never exposes a `foreign record`: safe
  wrappers take ordinary Lyric records and enums and build the descriptor
  inside the kernel.

### 4.8 Callbacks with userdata anywhere

The trampolines (N4) assume the userdata pointer is the last C
parameter. SDL3 puts it first (`SDL_EventFilter(void* userdata,
SDL_Event*)`); current `webgpu.h` uses callback-info structs with two
userdata slots. Callback parameters gain an explicit marker
(`@userdata`) naming which parameter carries the closure pointer, and
trampolines are synthesised for that position.

### 4.9 Does this break Lyric's core goals?

| Goal (`docs/00`, `docs/04`) | Effect |
|---|---|
| Make expectations explicit | Strengthened. With value semantics, a parameter mode tells the caller whether a function can change their buffer (`in` cannot, `inout` can). Today an `in List[T]` can still be mutated by the callee (reference-level immutability, §4.4 of the reference). |
| No global mutable state | Unaffected. Buffers live in bindings and fields; module-level `var` stays a parse error. |
| Structured, race-free concurrency | Preserved. Copy-on-write means a buffer captured by `spawn` is a logical copy, so two tasks never write one storage block. Shared writes go through `Parallel.forChunks` or a `protected type`. |
| Representational privacy of opaque types | Preserved by excluding opaque types from `Plain` outside their package (§4.5). |
| Range subtypes and invariants | Preserved by excluding constrained types from `Plain`; foreign data re-enters through `tryFrom`. |
| Contracts and verification | Improved. A value-semantic buffer maps directly to the SMT theory of arrays, with no aliasing frame conditions. |
| No reflection | Unaffected. |
| No `unsafe` pointers in application code | Unchanged in substance: pointers stay confined to kernels and `@unsafe_ffi`, as `N0100` already enforces on native. |
| No operator overloading beyond derives | Kept, with one widening of the derive rule to homogeneous numeric records (Q-GFX-004). |
| No SIMD intrinsics | Kept. |

So the plan fits the design, but two documents describe a narrower
language than this and must be revised in G0, with the justification
`docs/04` requires:

- `docs/00`: the "not the audience" line on game developers, and the
  memory-model row (native is ARC, not host GC).
- `docs/04`: the operator-overloading entry (homogeneous numeric
  records), and a note under "Inline assembly / hardware intrinsics" that
  portable vector types, if added, are not intrinsics.

---

## 5. Libraries

### 5.1 Layering

```
  lyric-ui native host (G10)        games and tools (G7 sample)
            |                                  |
   lyric-draw (2D)  +  lyric-text        lyric-game (frame loop, input, assets)
            \              |              /
             lyric-gpu (webgpu.h)   lyric-window (SDL3: window, input, audio)
                          \              /
              _kernel_native/ generated bindings + foreign records
                                 |
              native backend: by-value types, buffer[T], Float, FFI
```

### 5.2 Packages

| Package | Contents | Native dependency |
|---|---|---|
| `lyric-window` | Windows, display scale, event pump (keyboard, mouse, gamepad, touch, text input and IME composition events), clipboard, high-resolution timing, audio streams, file dialogs, native window handles for GPU surface creation (including the `CAMetalLayer` on macOS). Main-thread event loop. | SDL3 |
| `lyric-gpu` | Instance, adapter, device, queue; buffers, textures, samplers; bind group layouts and bind groups; render and compute pipelines; command encoders and passes; surface configuration and present; device-lost and validation errors surfaced as `Result` values. WGSL shader modules from source or file. | wgpu-native |
| `lyric-text` | Font loading, fallback chains, shaping (HarfBuzz), rasterisation (FreeType), a glyph atlas texture, line breaking. Bidirectional text through FriBidi in a later slice. | FreeType, HarfBuzz |
| `lyric-draw` | Immediate-mode 2D renderer on `lyric-gpu`: instanced signed-distance quads (rectangles, rounded rectangles, borders, shadows), images, clip stacks and layers, text runs from `lyric-text`. Paths through CPU tessellation in a later slice. This is the model GPUI and egui use, and it covers almost all UI drawing. | none beyond the above |
| `lyric-game` | Fixed-timestep update with interpolated rendering, input snapshots per frame, PNG and audio loading, sprite batching on `lyric-draw`, deterministic replay of recorded input. | SDL3 (through `lyric-window`) |
| `lyric-ui` native host | Renders `Ui.Core` `View` trees (docs/65) with `lyric-draw` and `lyric-text`: a flex-style layout engine in Lyric, focus and keyboard navigation, IME composition, clipboard, scrolling, and accessibility through AccessKit's C API. Replaces the HTML runtime for native builds; application code is unchanged. | AccessKit |

`lyric-game` keeps the docs/65 discipline: game logic is a deterministic
`update(state, input, dt)`, effects are data, and a recorded input stream
replays a session exactly. That gives games the same `lyric test`-based
testing story as business screens.

### 5.3 `lyric bindgen`

Hand-writing kernels for `webgpu.h` (several hundred functions, enums and
structs) and SDL3 is slow and error-prone. A new CLI command generates
them:

- **Input:** `webgpu.yml` from `webgpu-native/webgpu-headers` (the
  machine-readable source the C header is itself generated from), and
  `clang -Xclang -ast-dump=json` output for any C header (SDL3, FreeType,
  HarfBuzz, AccessKit).
- **Output:** a `_kernel_native/` file of `extern func`, `foreign record`,
  enum constants and callback typedefs, plus an allow-list file that
  selects which symbols to bind.
- Generated files are checked in. CI regenerates them and fails if they
  differ, as docs/65 §10.3 does for the TypeScript widget schema.
- Implemented in Lyric as `Lyric.Bindgen` in `lyric-compiler/lyric/`,
  dispatched from `cli_main.l`.

---

## 6. Toolchain and distribution

- **Library packages that bind C.** Path and workspace dependencies
  already compile from source into a native build (#7833). The libraries
  above are the first dependencies that declare `extern func` kernels and
  link C libraries, so G3 verifies that a dependency's kernel files are
  loaded and its link requirements reach the application's link step, with
  a test project that consumes such a library.
- **Native library resolution.** The `[native]` table gains `libs`
  entries naming a library, its version, and where it comes from: a
  system `pkg-config` lookup, or a prebuilt archive per target triple
  restored by `lyric restore`, with SHA-256 checksums in the lock file
  (the docs/39 lock-file pattern). Prebuilt is the default for SDL3 and
  wgpu-native, so a fresh machine needs no system packages.
- **Bundling.** `lyric build --target native` places the shared libraries
  next to the executable with an `$ORIGIN` rpath on Linux, and produces an
  `.app` bundle with `@rpath` and an `Info.plist` on macOS. Code signing
  and notarisation are a later slice.
- **Windows.** A Windows x86-64 native target (clang targeting
  `x86_64-pc-windows-msvc`, with `lyric-rt`'s POSIX layer ported to Win32
  for files, processes, sockets, threads and TLS). Games without Windows
  are a narrow niche, so this is a planned phase (G9), not an
  afterthought, but it is independent of G4 to G7 and can run in parallel.

---

## 7. Testing

The production-readiness standard applies; graphics code is not exempt
from CI.

- **Headless GPU in CI.** Linux runners use Mesa's lavapipe (software
  Vulkan) under wgpu-native, and SDL3's offscreen video driver. Rendering
  tests draw to a texture, read it back, and compare against checked-in
  golden images with a per-pixel tolerance. A failure uploads the actual
  image and a diff image as CI artefacts.
- **Memory.** All native graphics tests also run under AddressSanitizer,
  as the existing native self-tests do, so ARC mistakes at the FFI
  boundary fail CI.
- **Language features.** Each of §4's features gets a `*_self_test.l` on
  every backend it is defined for, including copy-on-write behaviour
  (aliasing is never observable) and `Plain` diagnostics.
- **Logic.** Game and UI logic is tested with plain `lyric test` and
  input replay; no GPU needed.
- **Performance.** `lyric bench` budgets for the copy-on-write write
  check in a tight loop, by-value record arithmetic against a C
  baseline, and a frame-time budget for a `lyric-draw` stress scene.

---

## 8. Phases

Sizes are relative: S (days), M (one to two weeks), L (several weeks),
XL (a quarter or more of focused work).

| Phase | Scope | Depends on | Exit criteria | Size |
|---|---|---|---|---|
| **G0** | Decision-log entry for §4; revisions to `docs/00` and `docs/04`; Q-GFX-001 to Q-GFX-004 resolved. | none | Decision accepted; reference updated with the new types as "specified". **Done (D155).** | S |
| **G1** | `Float` as f32 on MSIL and native (the JVM already complies), with the literal rule and `.toFloat()` checked on all three and migration of existing uses (§4.1); by-value records and small unions on native, with the C ABI for by-value structs (§4.2); `array[N, T]` (§4.3, D167: implemented on all three targets, value-generic `N` in functions too; in records #8090); profile-gated overflow checks on native (#6263); range-subtype bounds-check elision on native. | G0 | Self-tests on every backend; ASan clean; a bench showing `Vec3` arithmetic does not allocate (met: `benchmarks/bench_vec3.l` reports `alloc=0B/run` on native for `+`/`-`, scaling and an inline `array[8, Vec3]`, asserted in CI by `scripts/ci/bench-vec3-alloc.sh`). | L |
| **G2** | `Plain` marker (§4.5); `buffer[T]` with copy-on-write on native, and the shared-mark lowering on MSIL and JVM (§4.4); verifier array model; `withPointer` and `withMutPointer` under the `N0100` rules. | G1 | Self-tests on all backends prove aliasing is never observable; the COW check costs at most a small, fixed per-write overhead in `lyric bench`. | L |
| **G3** | `foreign record` (§4.7); `@userdata` callbacks (§4.8); `lyric bindgen` (§5.3); C-binding library dependencies with link-requirement propagation (§6); `[native]` library resolution, restore with checksums, and bundling (§6). | G1, G2 | A test library binds a small C API end to end through generated bindings and is consumed by a separate application project. | XL |
| **G4** | `lyric-window` on SDL3 and an example that opens a window, handles input, and plays a sound. | G3 | Example runs on Linux and macOS; event handling tested headless with the offscreen driver. | M |
| **G5** | `lyric-gpu` on wgpu-native; examples: triangle, textured quad, compute (a GPU prefix sum). Golden-image CI on lavapipe. | G4 | All three examples pass golden-image tests in CI. | L |
| **G6** | `Std.Math` vectors and matrices (§4.6), `lyric-text`, `lyric-draw`. | G5 | A text-heavy stress scene renders within its frame budget on lavapipe and on real hardware; golden images for shaping (Latin, Arabic, CJK). | XL |
| **G7** | `lyric-game` and a small, complete 2D sample game with recorded-input replay tests. | G6 | Sample game playable on Linux and macOS; replay tests in CI. | M |
| **G8** | Multi-threaded native scheduler (native/plan Phase 2) and `Parallel.forChunks` (§4.4). | G2 | Parallel buffer processing scales across cores in `lyric bench`; ThreadSanitizer clean. | L |
| **G9** | Windows x86-64 native target (§6). | G3 | Native test suite passes on Windows CI; G4 to G7 examples run there. | XL |
| **G10** | Native `lyric-ui` host (§5.2): layout, widgets, focus, IME, clipboard, accessibility. | G6 | `examples/ui-customers/` runs natively with no application changes; screen-reader smoke test on macOS. | XL |

**Critical path to a first native graphics program:** G0, G1, G2, G3, G4,
G5. G8 and G9 can run in parallel once their dependencies land.

**Tracking:** epic #7939; G1 #7940, G2 #7941, G3 #7942, G4 #7943, G5 #7944,
G6 #7945, G7 #7946, G8 #7947, G9 #7948, G10 #7949.

**Later (not planned here):** a Lyric shader subset compiled to WGSL,
sharing `Std.Math` types between CPU and GPU code; `wasm32` with browser
WebGPU through docs/35; zero-copy mapped GPU buffers; path rendering on
the GPU.

---

## 9. Risks

- **G3 is the largest unknown.** By-value struct ABIs differ per platform
  in detail (homogeneous float aggregates on AAPCS64, register
  classification on System V). Mitigation: generate C test shims in CI
  that round-trip every `foreign record` shape through a real C function.
- **`webgpu.h` churn.** The header has changed shape between releases
  (callback-info structs, for example). Mitigation: generated bindings
  pinned to a header version, upgraded deliberately.
- **Text is hard.** Shaping, fallback, bidirectional layout and IME
  together are why most UI toolkits embed a browser. G6 and G10 are sized
  accordingly and ship in slices, Latin first.
- **COW surprises.** An unexpected second reference makes a hot loop copy
  once. Mitigation: a `lyric lint` rule that flags a buffer copied
  immediately before a loop that writes to it.
- **Float migration** may surface code that silently relied on 64-bit
  precision. Mitigation: the audit in G1 moves such uses to `Double`
  before the switch.

---

## 10. Open questions

| Id | Question | Recommendation |
|---|---|---|
| Q-GFX-001 | `buffer[T]` semantics: copy-on-write value (§4.4) or reference? | **Resolved (D155):** copy-on-write value. |
| Q-GFX-002 | Make `Float` 32-bit on every backend now, with migration? | **Resolved (D155):** yes. |
| Q-GFX-003 | GPU API: `webgpu.h` (wgpu-native / Dawn) or SDL3's own GPU API? SDL_GPU means one dependency, but per-backend shader formats (SPIR-V, MSL, DXIL) and an offline shader toolchain; `webgpu.h` uses WGSL everywhere and maps to the browser. | **Resolved (D155):** `webgpu.h` via wgpu-native. |
| Q-GFX-004 | Extend `derives Add, Sub` to homogeneous numeric records (§4.6)? | **Resolved (D155):** yes. |
| Q-GFX-005 | Name and exact rules of the `Plain` marker; whether enums with explicit ordinals qualify. | **Resolved (D156):** `Plain`, as §4.5; Lyric enums have no explicit ordinals. |
| Q-GFX-006 | `lyric bindgen` input: clang JSON AST only, or also `webgpu.yml`? | **Resolved (D156):** both; `webgpu.yml` drives WebGPU. |
| Q-GFX-007 | Native libraries: prebuilt archives by default, or system packages? | **Resolved (D156):** prebuilt by default, `pkg-config` opt-in. |
| Q-GFX-008 | Are by-value record semantics (`var` field mutation through a copy) currently consistent across backends? | **Resolved (D157, superseding D156 item 4):** consistent on all three, with reference semantics. Records without `var` fields are values; records with `var` fields have identity; an explicit marker for mutable records is a follow-up. |
| Q-GFX-009 | Priority of the Windows port (G9) against G6 and G7. | **Resolved (D156):** start G9 in parallel once G3 lands. |
| Q-GFX-010 | Should `lyric-game` include an entity-component system? | **Resolved (D156):** no; a separate library may follow the sample game. |
