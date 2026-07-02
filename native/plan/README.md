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

Phase N2's core SHIPPED (D-progress-542): records, unions, enums,
distinct types, pattern matching, and ARC retain/release insertion per
`04-arc-design.md` Rules 1–7, verified end-to-end under
AddressSanitizer/LeakSanitizer (`llvm_heap_self_test.l`).  Closures
(N2.6) SHIPPED in D-progress-544 (by-value captures, synthesised
capture-releasing destructors, signature-keyed closure types, indirect
calls); `NativeWeak[T]` (N2.5) SHIPPED in D-progress-545 — all of
Phase N2 is complete.

N3.1 SHIPPED (D-progress-542 types, D-progress-543 functions): generic
records/unions instantiate on demand per concrete type-argument tuple
(constructor-argument inference + expected-type threading), and generic
functions instantiate per call site with unification-based inference,
cache-first recursion handling, and generic UFCS.
Remaining work items (rest of N2/N3, the rest of N4/N5/N6, N7 CI)
execute from `08-work-items.md` as written, modulo the D-N-014 naming
mapping.

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
- Async/await (Phase 2 — mechanism fully specified in `06-async-design.md`)
- Garbage collection / tracing GC (never; ARC is the permanent model)
- `defer` blocks (Phase 2, requires cleanup landingpads)
- Protected types with async (Phase 2)
- Hot-reload / REPL for native (separate future item)
- Debug info / DWARF (Phase 2)
- Incremental compilation (Phase 3)
