# Lyric Native Backend — Implementation Plan

This directory contains the complete implementation plan for a native code
generation backend targeting LLVM IR. The native backend adds `--target native`
to the Lyric compiler, producing self-contained binaries via LLVM and clang.

## Status

Phase 1's first slice SHIPPED (D-progress-540): N0 (lyric-rt + IR layer),
N1 (scalar codegen; `lyric build hello.l --target native -o hello` works
end-to-end), N4.1 (`extern func`), N4.6 (`@cfg(target = ...)`), and the
console/math/libc kernel + bridge/CLI subsets of N4.4/N5/N6.  Three plan
corrections were required and are codified in `docs/03-decision-log.md`
§D-N-014 (package head/location, loader-based kernel selection,
`Native`-suffixed entry points) — read that entry alongside this plan.

Phase N2's core SHIPPED (D-progress-545): records, unions, enums,
distinct types, pattern matching, and ARC retain/release insertion per
`04-arc-design.md` Rules 1–7, verified end-to-end under
AddressSanitizer/LeakSanitizer (`llvm_heap_self_test.l`).  Closures
(N2.6) SHIPPED in D-progress-548 (by-value captures, synthesised
capture-releasing destructors, signature-keyed closure types, indirect
calls); `NativeWeak[T]` (N2.5) SHIPPED in D-progress-549 — all of
Phase N2 is complete.

N3.1 SHIPPED (D-progress-546 types, D-progress-547 functions): generic
records/unions instantiate on demand per concrete type-argument tuple
(constructor-argument inference + expected-type threading), and generic
functions instantiate per call site with unification-based inference,
cache-first recursion handling, and generic UFCS.  Tuples (N3.3)
SHIPPED in D-progress-550 as synthesised records.  Interfaces/vtables
(N3.2) SHIPPED in D-progress-568 (heap-boxed fat pointer per D-N-016,
non-generic `impl I for Record`, ASan-verified).  Protected types (N3.4)
SHIPPED in D-progress-573 (D-N-017): a record-shaped heap object with a
trailing heap-buffer mutex field, `entry`/`func` members both locking via
a codegen-synthesised lock/unlock wrapper around a desugared inner body,
ASan-verified.  N3 is complete (`when:` barriers / invariant re-checking /
generic protected types remain deferred, tracked in D-N-017).

Phase N4 is COMPLETE (D-progress-540 shipped N4.1/N4.6 and the
kernel/CLI subsets; D-progress-551 the nativeAddrOf codegen;
D-progress-552 the rest): the N0100 mode-checker FFI boundary
(NativePtr[T]/nativeAddrOf/nativeNullPtr only in `@unsafe_ffi`
functions and `_kernel_native/` packages, var-only operands, no frame
escape), callback trampolines (a Lyric closure passed to an extern
func parameter of function type, the closure riding the callback's
trailing NativePtr[Byte] userdata slot), and the `llvm_ffi_self_test.l`
suite (extern libc/libm calls, C-string bridging, pthread trampoline
round-trips under ASan).
N5.8 SHIPPED (D-progress-556): `List[T]` / `Map[K, V]` lower to the
lyric-rt kernels (64-bit slots, container-owned retention flags),
with `for`-loop lowering over lists, indexing, and the reserved
`Std.Collections` accessors (`newList` / `newMap` / `mapGet` /
`dictGetKeys` / `dictGetValues`; `lyric_map_keys` / `lyric_map_values`
added to lyric-rt).  Verified ASan-clean by
`llvm_collections_self_test.l`.
The N5 stdlib kernel files SHIPPED (D-progress-557, issue #4752):
`_kernel_native/` twins for `Std.FileHost`, `Std.EnvironmentHost`,
`Std.TimeHost`, and `Std.ProcessCaptureHost` over exception-free
Result/Option seams both kernel twins implement, plus the codegen
support they surfaced (Unit-typed union/record payload fields for
`Result[Unit, E]`, diverging `panic` branches in value-position
`if`/`match`, type-only bundled units).  Verified ASan-clean by
`llvm_stdlib_self_test.l`, which compiles real `Std.File` /
`Std.Environment` / `Std.Process` / `Std.Time` programs through the
full bridge pipeline.  The process runner's stdin/timeout deferrals
were later closed by D-N-024; the remaining native-side deferrals
(Std.Uuid, the Std.Time calendar surface) are tracked in #4752.
`slice[T]` SHIPPED (D-N-015, D-progress-562): slices share the RC'd
list representation (immutable by construction; the planned borrowed
fat pointer is superseded — see D-N-015), unlocking bytes-mode file
I/O, directory enumeration (`listFiles`/`listDirs`/recursive),
`Std.Environment.args()`, and `toArray()` on the native target,
verified under ASan by the extended `llvm_stdlib_self_test.l`.
N6.4 SHIPPED (D-progress-564): the `[native]` manifest table
(`triple` / `opt_level` / `extra_libs`) supplies defaults for
`--target native` builds, with the `--triple` / `--opt` CLI flags
overriding and `extra_libs` adding `-l<name>` clang link flags.
N7.2 SHIPPED (D-progress-576, D-N-018): `lyric test --target native`
compiles a single-file `@test_module` through `Emitter.emitNative` and
runs the binary directly; native's lack of try/catch (D-N-003) means
per-test isolation isn't possible the way dotnet/jvm do it, so a new
`synthesizeNative` test-synthesis path calls each test straight through
(a failing assertion aborts the whole process instead of reporting
`not ok` and continuing) — see D-N-018 for the full rationale and the two
native-codegen gaps (bare `toString`, `println`) it surfaced and fixed
along the way. N7.1's dedicated 3-OS CI matrix remains a follow-up; the
existing single-OS (Linux) native CI job is the production gate today.

Phase 1 is complete. Phase 2's first slice — `async func`/`await`
(Phase N8) — SHIPPED (D-N-019): a non-generator `async func` compiles
through the same codegen path as a plain `func`, and `await expr` is a
pure passthrough, since `Task[T]` is not a real type anywhere in the
self-hosted front end and `spawn`/`scope` (out of scope for this slice)
is the only construct that could make an async call's result observable
as anything other than an immediately-available value. Verified by
`llvm_self_test_async.l` and end-to-end via `lyric build --target
native`. Async generators (`yield` inside `async func`), the implicit
`cancellation` parameter, and `spawn`/`scope` structured concurrency are
each deferred with their own tracked follow-up; `spawn`/`scope` is also
the point at which real LLVM-coroutine suspension (`06-async-design.md`'s
original mechanism, hand-verified against `clang` 18 before this slice
began) becomes necessary.

`defer` (D-N-020) SHIPPED for its normal-exit paths — fall-off, `return`,
`break`, `continue` — by extending the existing ARC scope-exit mechanism
with a parallel per-scope stack of pending deferred blocks, run in
reverse declaration order before that scope's ARC releases; no new IR
shape or runtime support was needed. A `defer` registered before a
`panic` does not run (native has no unwinding, D-N-003, so nothing
triggers scope exit); the landingpad-based mechanism `01-design-
decisions.md`'s D-N-003 entry originally sketched for a panic-triggered
`defer` remains unimplemented. Verified by `llvm_self_test_defer.l` (8
cases, including a direct negative check that a deferred block does not
run before a panic) and end-to-end via `lyric build --target native`.

`spawn`/`scope` (D-N-021) SHIPPED as the same passthrough model the MSIL
emitter itself uses (its `ESpawn` is a pure passthrough and its `SScope`
a plain block — read before implementing, per the code-as-source-of-truth
discipline): `spawn expr` evaluates `expr` at the spawn site, `scope { }`
is a real lexical scope whose ARC releases and `defer` blocks run at
scope exit. D-N-021 refines the paragraph above: the true trigger for
real LLVM-coroutine suspension is not `spawn`/`scope` syntax but the
first **async leaf primitive** (async sleep/timer, then async I/O) —
a .NET task only stays incomplete if it awaits such a leaf, and native's
stdlib has none, so .NET semantics restricted to the native surface also
degenerate to sequential execution and the passthrough is observationally
equivalent for every compilable program. Verified by five new
`llvm_self_test_async.l` cases including the language reference's §7.4
dashboard shape.

Real async (D-N-022) SHIPPED, superseding the two passthrough slices
above on the lowering mechanism: every non-generator `async func` now
emits as a real LLVM coroutine (`presplitcoroutine`, returning its
`LyricTask*`), `lyric-rt` gained the cooperative single-threaded
scheduler (`lyric_async.c`: hot tasks, ready queue, deadline-ordered
timer list, `lyric_task_block_on`), and `Std.Time.sleepMillis` inside a
coroutine is the first async leaf — it parks only the calling task
instead of blocking the thread. Spawned tasks genuinely interleave,
verified by effect-order tests under ASan in `llvm_self_test_async.l`
(20 cases; the 13 pre-coroutine cases double as the regression net for
the coroutine path). See D-N-022 and the status header of
`06-async-design.md` for the shipped-vs-sketch deltas.

The first async I/O leaf (D-N-023) SHIPPED on top: in-coroutine
`Std.Process.runCapture` drives a nonblocking lyric-rt capture op
through the sleep leaf (1 ms pump cadence, the JVM kernel twin's
documented idiom), so subprocess captures overlap instead of stalling
the scheduler — and `timeoutMs` is honored on this path. Verified by
six more `llvm_self_test_async.l` cases including reverse-order
completion of two spawned captures under ASan. `poll()`-based fd
readiness in the scheduler is deferred to the socket leaf.

Native process capture reached managed parity (D-N-024): both seams
accept stdin content through an always-piped child stdin (nonblocking
writes interleaved with output reads, so large content cannot
deadlock; SIGPIPE-safe), the synchronous runner honors `timeoutMs`
with a SIGKILL deadline and the #5107 kill-vs-exit contract, and
`runCaptureWithInput` works on native — including the in-coroutine
async-seam redirect. Verified by five new lyric-rt C tests
(clang + gcc) and four more `llvm_self_test_async.l` cases (30
total, 256 KiB stdin round-trip ASan-clean). This closes the
runCapture half of #4752.

## Reading order

1. `01-design-decisions.md` — all architectural decisions with rationale. Read
   this first. Do not begin any implementation item without reading this doc.
2. `02-architecture.md` — how the native backend fits into the existing compiler
   pipeline; directory structure; the bridge pattern; IR shape overview.
3. `03-type-mapping.md` — authoritative Lyric-type → LLVM IR type mapping. Every
   codegen agent must treat this as the source of truth.
4. `04-arc-design.md` — ARC (reference counting) memory model, object header
   layout, retain/release insertion rules, the `lyric-rt` runtime library.
5. `05-ffi-design.md` — `extern func` declaration syntax, `NativePtr[T]`,
   `NativeWeak[T]`, C ABI calling conventions, callback trampolines, the
   `_kernel_native/` boundary.
6. `06-async-design.md` — LLVM coro.* intrinsic model for async/await (Phase 2
   implementation; this document specifies the full mechanism so Phase 2 agents
   have no design work to do).
7. `07-stdlib-port.md` — analysis of every `_kernel/` module; which are pure
   Lyric (port automatically), which need new `_kernel_native/` implementations.
8. `08-work-items.md` — ordered work items with dependencies and acceptance
   criteria. Agents execute from this file.

## Decisions summary

| ID | Decision | Chosen |
|---|---|---|
| D-N-001 | LLVM integration strategy | Emit `.ll` textual IR, shell out to clang as driver |
| D-N-002 | Union/tagged-union layout | In-place tagged struct (discriminant + inline payload) |
| D-N-003 | Panic / exception model | `abort()` — no unwinding, no `defer` in Phase 1 |
| D-N-004 | Async Phase 1 scope | Designed now (LLVM coro); implemented in Phase 2 |
| D-N-005 | ARC cycle collection | `NativeWeak[T]` only; static detection is a future mode-checker pass |
| D-N-006 | String representation | RC-managed heap object with inline UTF-8 data |
| D-N-007 | FFI extern syntax | New `extern func name(args): Ret = "symbol"` declaration form |
| D-N-008 | Platform Phase 1 scope | Linux x86-64 + AArch64, macOS AArch64 |
| D-N-009 | Linking | clang as universal driver (handles opt + link + ABI) |
| D-N-010 | Generics | Full monomorphization via existing `Lyric.Mono` |
| D-N-011 | ARC intrinsics | External C symbols in `lyric-rt` static library |
| D-N-012 | Collection repr | `List[T]`: RC heap (data + len + cap); `slice[T]`: borrowed (ptr + len) |
| D-N-013 | `@cfg(target=X)` | Pseudo-feature `"target.X"` injected into `activeFeatures`; no new predicate branch |

## New top-level directories

```
lyric-compiler/llvm/     — the native backend (Lyric source, mirrors msil/ and jvm/)
lyric-rt/                — the native runtime C library (lyric_rt.a)
lyric-stdlib/std/_kernel_native/   — native stdlib kernel (extern func declarations)
```

## What is NOT in scope for Phase 1

- Windows target (Phase 2)
- Async/await (Phase 2 — mechanism fully specified in `06-async-design.md`; first slice SHIPPED, D-N-019 — see above)
- Garbage collection / tracing GC (never; ARC is the permanent model)
- `defer` blocks (Phase 2, requires cleanup landingpads for the panic-unwind case; first slice — normal-exit paths, no landingpads needed — SHIPPED, D-N-020, see above)
- Protected types with async (Phase 2)
- Hot-reload / REPL for native (separate future item)
- Debug info / DWARF (Phase 2)
- Incremental compilation (Phase 3)
