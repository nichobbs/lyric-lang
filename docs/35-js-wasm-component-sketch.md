# 35 — WebAssembly Target and JS Ecosystem Integration (sketch)

**Status:** Specced in D-progress-1028; sketch rewritten 2026-10-01 around the native (LLVM)
backend. The original revision assumed a .NET AOT `wasi-wasm` route; that
premise is withdrawn (§3). Open questions that still block implementation are
in §13. Backed by D-progress-1028 (route, phase order (§12) and the resolved
questions (§13.1)).
**Builds on:** `native/plan/` (LLVM backend, D-N-001..D-N-017),
`docs/14-native-stdlib-plan.md` (extern kernel pattern),
`docs/63-build-profiles-and-debugger.md` (profile and shape axes),
`docs/65-ui-library-sketch.md` §13.1 (client WASM host),
`docs/67-native-graphics-plan.md` (WebGPU, `Float`/by-value record changes),
`docs/21-nuget-linking.md` (dependency table and shim model).
**Decision-log entry:** D-progress-1028.
**Goal:** Compile Lyric to WebAssembly so that (A) Lyric programs and UI hosts
run in the browser and in any WASI runtime, (B) JS-first teams consume Lyric
libraries as ordinary NPM modules, and (C) Lyric programs call NPM packages
via declared host imports, without sacrificing Lyric's safety properties inside
the WASM boundary.

---

## 1. Motivation

Three consumers drive this target:

- **Browser UI.** `docs/65` §13.1 and `docs/67` both assume a client-side
  host: the model-view-update loop runs in the browser and drives WebGPU and
  the DOM through a thin import surface.
- **Portable libraries.** A Lyric library should be usable from Node, Deno,
  Bun and server-side WASI runtimes (wasmtime and similar) with typed bindings.
- **JS ecosystem access.** Lyric programs on this target need to call NPM
  packages in the same way .NET programs call NuGet packages.

The WebAssembly Component Model (WIT) is the right interface abstraction for
the second consumer; a plain core module with JS imports is the right
abstraction for the first. The design therefore supports both **output
shapes** (§4) from a single code generator.

---

## 2. Scope of this sketch

In scope:
- The route to WASM: the native backend retargeted to `wasm32` (§3, §4, §5).
- Native-backend prerequisites surfaced by the 2026-10 wasm32 audit (§6).
- WIT generation from Lyric's `exposed` type surface (§7).
- CLI and `lyric.toml` extensions (§8).
- The `[npm]` dependency table and NPM extern shim model (§9).
- The degraded-semantics policy (§10) and async lowering (§11).
- Phases (§12) and open questions (§13).

Out of scope: see §14.

---

## 3. Route: native backend to wasm32, not .NET WASI, not TypeScript

### 3.1 Why LLVM `wasm32`

- **No runtime to ship.** The native backend uses ARC and has no garbage
  collector. A .NET-based browser build carries the .NET runtime and GC
  (several MB, as recorded in `docs/65` §13.1).
- **One GPU story.** `docs/67` binds WebGPU through `webgpu.h`. The same
  binding carries over to the browser with a JS-side implementation of the
  imports; a .NET-wasm route would need a second binding.
- **Mature toolchain.** LLVM's `wasm32` backend, `wasm-ld` and wasi-sdk are
  stable. `dotnet publish -r wasi-wasm` is experimental, and it was never
  verified that the self-hosted MSIL emitter's output survives the WASI
  runtime pack.
- **Async already lowers.** The native backend lowers `async` through LLVM
  coroutines (`native/plan/06-async-design.md`), which is a plain state
  machine on wasm32 and needs no host stack switching.
- **Parity.** `wasm32` is a new target triple on an existing backend, not a
  fourth backend. The MSIL/JVM/native parity rule is satisfied by the existing
  native parity work plus the gaps tracked in §6.

### 3.2 Why not transpile to TypeScript

A TS transpilation target is simpler to build and has been requested. It is
not the primary mechanism for two structural reasons:

1. **Safety properties dissolve.** TypeScript's type system is structural.
   `opaque type UserId` becomes a branded string; any TS cast defeats it.
   `protected type` semantics have no JS equivalent. Range subtypes become
   runtime checks with no type-level enforcement. Contracts survive as
   runtime asserts but the `@proof_required` story is meaningless.
2. **Semantic confusion.** Developers who meet Lyric-as-TS and then the
   native or .NET version will find different semantics at the boundary.

A TS target could be justified as an explicitly degraded "scripting/tooling"
output; that is a separate, narrower use case for a distinct sketch.

### 3.3 .NET WASI is not pursued

The `dotnet publish -r wasi-wasm` route from the earlier revision is dropped:
size, an experimental runtime pack, an unverified interaction with the
self-hosted MSIL emitter, and no WebGPU path. It may be revisited only if the
native route proves unworkable.

---

## 4. Targets and output shapes

The triple selects the platform; the **shape** selects the artifact. Both are
independent of the build profile, following `docs/63`.

| Triple | Use |
|---|---|
| `wasm32-wasi` | WASI runtimes (wasmtime, node `node:wasi`), component shape |
| `wasm32-unknown-unknown` | Browser core module with explicit JS imports |

| Shape | Artifact | Interface | Typical consumer |
|---|---|---|---|
| `module` | Core `.wasm` plus generated JS glue | `extern` imports and exports (DOM, WebGPU, timers, `abort`) | Browser UI, `lyric-ui` client host |
| `component` | WASI Component `.wasm` plus `.wit` | Typed WIT exports/imports via the canonical ABI | Node/Deno/Bun via `jco`, wasmtime, other languages |

Both shapes share all code generation. They differ only in boundary code:
the `module` shape exports plain functions and imports host functions by
name; the `component` shape adds the canonical-ABI lift/lower wrappers,
`cabi_realloc`, and componentisation (`wasm-tools component new`).

Delivery order is `module` first, then `component` (§12). `module` unblocks
`docs/65` U7 and the browser half of `docs/67`; `component` follows once the
canonical-ABI layer exists.

---

## 5. Toolchain and runtime

### 5.1 Toolchain

- **wasi-sdk**, pinned in CI in the same way clang-18 is pinned today. It
  provides clang, `wasm-ld`, `llvm-ar` and wasi-libc. A hand-built sysroot is
  not used.
- `lyric_rt` is built per triple (`lyric_rt-wasm32-wasi.a`); the Makefile
  gains cross-compile variables (`CC`, `AR`, `--target`, `--sysroot`), no
  `-fPIC`, no `-ldl`/`-lpthread`, and `-Werror` becomes conditional on the
  stubbed sources. `findLyricRtArchive` becomes triple-aware.
- The native bridge's link step stops hard-coding `-lpthread -ldl` and a
  host `clang` invocation; it selects a link recipe per triple (`wasm-ld`
  flags, exports, stack size, `.wasm` suffix).
- CPU features are set explicitly (`+bulk-memory`, `+nontrapping-fptoint`,
  and later `+atomics` for threads).

### 5.2 Single-threaded v1

The v1 profile is **single-threaded** (Q-JS-001 resolved, §13.1):

- `lyric_mutex_*` and `lyric_sem_*` become re-entrancy counters in a wasm
  runtime variant of `lyric_posix.c`. `lyric_mutex_size()` still answers so
  codegen's size query is unchanged.
- `scope`/`spawn` run cooperatively on the coroutine scheduler. A blocking
  acquire on a held lock panics, since no other thread could release it.
- A `wasm32-wasi-threads` profile (shared memory, `+atomics`) is a later
  extension.

### 5.3 Capability matrix

| Area | `wasm32-wasi` | Browser `module` |
|---|---|---|
| Console, strings, collections, ARC, weak refs, time, uuid | works | works (console, `abort` via imports) |
| Files, directories, env, args | works with preopened dirs and `__wasi_args_get`; `/proc/self/exe` path replaced | unavailable; clean error |
| Async scheduler | works; sleeps through `clock_nanosleep` | timers through a host import, never a blocking sleep |
| Process spawn (`lyric_process.c`) | unavailable; stubbed to a clean spawn error | unavailable |
| Sockets, TLS, HTTP server | unavailable; stubbed | unavailable; HTTP client later through a `fetch` host import |
| Threads | single-threaded stub | single-threaded stub |

Unavailable capabilities fail with a defined error value, never an undefined
symbol at link time: the unavailable kernels (`process_*_host.l`,
`tcp_host.l`, `tls_host.l`, `http_server.l`) get wasm twins under
`_kernel_native/` following the existing loader-based selection (D-N-014).

### 5.4 Testing

- `lyric_rt` C unit tests run the portable subset under wasmtime or node with
  `#ifndef __wasi__` guards around the fork, pthread, process and TLS tests.
- The `llvm_*_self_test.l` suites gain a wasm lane that compiles with the
  `wasm32-wasi` triple and runs under wasmtime. ASan does not apply; the ARC
  leak/UAF checks rely on the runtime's own live-object counters instead.
- `lyric test --target native --triple wasm32-wasi` is the user-facing entry
  (Q-JS-005, §13.1).

---

## 6. Native-backend prerequisites (wasm32 audit, 2026-10)

The audit found a toolchain, runtime and ABI-layout job, not a codegen
rewrite. Triple plumbing (`--triple`, `[native] triple`, `NPackage.triple`)
exists end to end, struct access uses field-index GEPs, and emitted IR has no
varargs, exceptions, tail calls or atomics. The findings, with the severity the
audit gave them (blocker/major/minor) or `W0`/`resolved` once phase W0 fixed them:

| # | Area | Finding | Status |
|---|---|---|---|
| 1 | ARC header | The C header is `{rc, weak, dtor}` while codegen models `{i32, ptr}` and relies on `weak` hiding in LP64 padding (`lyric_rt.h`, `llvm_codegen.l`). On wasm32 the header is 12 bytes and offsets diverge; the `2*sizeof(void*)` assert fails. Fix: an explicit three-field header on all targets (LP64 stays 16 bytes). | W0 |
| 2 | Size tables | `sizeOfN`/`alignOfN`/`structSize`/`recAllocSize` hard-code 8-byte pointers. Replace with target-derived sizes (`getelementptr null, 1`). | W0 |
| 3 | Coroutines | Audit flagged `llvm.coro.size.i64`; on inspection the width is only the intrinsic's result type and `lyric_alloc` takes `i64` on every target, so no change is needed (W0). | resolved |
| 4 | Pointer-as-`Long` | Of the 107 `_kernel_native` externs mentioning `Long` or `NativePtr`, the wasm-relevant kernels are already width-stable. The `Long`-as-pointer-handle idiom is confined to the TCP/TLS, HTTP server and piped-process kernels, which are unavailable on WASI and get wasm twins in W2. `libc.l`'s `size_t`/`ssize_t`/variadic externs move to fixed-width `lyric-rt` wrappers (W0). | W0 |
| 5 | Link step | A single hard-coded host `clang ... -lpthread -ldl` invocation. | blocker |
| 6 | Runtime archive | Single-triple `lyric_rt.a`; no CPU-feature flags. | blocker |
| 7 | `fptosi` | Non-saturating conversion traps on NaN/out-of-range on wasm. Use the saturating form or `+nontrapping-fptoint`. | major |
| 8 | Datalayout | `datalayoutForTriple` returned "" for non-x86/ARM triples; wasm32 now has a pinned layout (W0). | W0 |
| 9 | Threads, process, TLS, sockets | See §5.2 and §5.3. | major |
| 10 | Async scheduler | `nanosleep` blocks; the browser needs a timer import. | major |
| 11 | Misc | `/proc/self/exe`, `getrandom` guard, `Float` width (below). | minor |

**Typed-pointer syntax is not a risk.** The emitter renders `i8*`-style
types and builds with clang-18 in CI today; wasm32 uses the same clang.

**`Float` width.** `Float` currently lowers to `double` on every backend.
The WIT `f32` mapping (§7) and WebGPU interop (`docs/67`) require a true
32-bit `Float`. That work is `docs/67` G1 (G0, the decision entry, is done as D155) and is owned by a
separate work stream; this plan depends on it landing before the `component`
shape's type mapping is final (§12, W1).

---

## 7. WIT generation from Lyric types

WIT is the interface language for the Component Model. In the `component`
shape, `lyric build` generates a `.wit` file alongside the `.wasm` binary.
The WIT surface is derived from the package's `pub` declarations whose types
are entirely in the `exposed` tier.

### 7.1 Type mapping

| Lyric type | WIT type | Notes |
|---|---|---|
| `Bool` | `bool` | |
| `Int` | `s32` | |
| `Long` | `s64` | |
| `Float` | `f32` | requires the 32-bit `Float` change (§6) |
| `Double` | `f64` | |
| `String` | `string` | UTF-8 in the canonical ABI |
| `Unit` | (no return type) | |
| `Option[T]` | `option<T>` | |
| `Result[T, E]` | `result<T, E>` | |
| `List[T]` | `list<T>` | |
| `exposed record Foo` | `record foo { ... }` | fields mapped recursively |
| Union type | `variant` | each constructor becomes a case |
| `Async[T]` | `future<T>` | see §11 |
| `opaque type T` | not exported | only the `@projectable` exposed twin appears |
| `protected type T` | not exported | see §10.1 |
| Range subtype | underlying type with contract guard | see §10.2 |
| Generic `T` | not directly exportable | only instantiated forms are exported |

Types not in the table (function types, first-class module references,
`inout` parameters in complex positions) are not WIT-exportable. The compiler
emits an informational diagnostic (`W0040`) per excluded `pub func`.

### 7.2 Example

```lyric
// billing.l
@projectable
pub opaque type InvoiceId = Long

pub exposed record Invoice {
    pub id: InvoiceId,
    pub amount_cents: Long
}

pub func create(in customer_id: String, in cents: Long): Result[Invoice, String] = ...
```

generates

```wit
package lyric:billing@1.0.0;

interface billing {
  type invoice-id = s64;

  record invoice {
    id: invoice-id,
    amount-cents: s64,
  }

  create: func(customer-id: string, cents: s64) -> result<invoice, string>;
}

world billing-world {
  export billing;
}
```

Lyric snake_case and PascalCase identifiers map to kebab-case automatically.

### 7.3 Canonical ABI layer

The native backend emits ordinary C-ABI functions. For the `component` shape
the compiler additionally emits, per exported function, a lift/lower wrapper:
strings and lists are copied between linear memory and the caller through
`cabi_realloc`, records are flattened or spilled according to the canonical
ABI's rules, and `variant`/`option`/`result` use the discriminant-plus-payload
layout. Ownership at the boundary is by copy; ARC objects never cross it
(Lyric `exposed` records are value-copied into the canonical layout).

### 7.4 Generated JS bindings

`jco transpile billing.wasm` produces a TypeScript module:

```typescript
export interface Invoice { id: bigint, amountCents: bigint }
export function create(customerId: string, cents: bigint): Invoice | string;
```

---

## 8. CLI and `lyric.toml` extensions

### 8.1 CLI

```
lyric build --target native --triple wasm32-wasi --shape component [--wit-out <path>] [--js-bindings]
lyric build --target native --triple wasm32-unknown-unknown --shape module
```

`--shape module|component` are additional, triple-gated values on the
`docs/63` shape axis. Today `--target native` fixes the shape at `aot`
(`docs/63` "Settled"); for `wasm32` triples `module`/`component` replace that
rule, and `portable`/`standalone`/`aot` become a diagnostic there. Convenience aliases `--target wasm` (module) and
`--target wasm-component` (component) are sugar over the above.

| Flag | Default | Meaning |
|---|---|---|
| `--wit-out <path>` | `target/wasm/<pkg>.wit` | Where to write the generated WIT file (component shape) |
| `--js-bindings` | off | Also run `jco transpile` (component) or emit the JS glue module (module) |

`lyric publish` for a wasm shape bundles the `.wasm`, WIT and generated
bindings as an NPM-compatible tarball.

### 8.2 `lyric.toml`

```toml
[wasm]
shape   = "component"            # "module" or "component"
world   = "billing-world"        # component shape; defaults to "<package-name>-world"
exports = ["billing", "users"]   # interfaces to export; default: all eligible pub interfaces
stack   = "1MiB"                 # linear-memory stack size (wasm-ld -z stack-size)

[npm]
"node-fetch"           = "^3"
"@aws-sdk/client-s3"  = "^3.600"
```

`[wasm]` follows the `[native]` table's precedence rules (CLI over manifest).

---

## 9. NPM dependencies (`[npm]`) and extern shims

### 9.1 `[npm]` table

`[npm]` declares NPM package dependencies, analogous to `[nuget]`. The model
parallels `docs/21-nuget-linking.md` §§3-4.

```toml
[npm]
"node-fetch"          = "^3"
"zod"                 = "^3.22"

[npm.options]
registry = "https://registry.npmjs.org/"   # default
```

`lyric restore` invokes `npm install` (or the configured `pnpm`/`yarn`) into
`target/npm/node_modules/` and generates extern shim files for each declared
package.

### 9.2 Boundary lowering

NPM calls cross the same boundary in both shapes, lowered differently:

- `module` shape: each shim symbol becomes a named wasm import
  (`env`/package-qualified), satisfied by the generated JS glue.
- `component` shape: each shim becomes a WIT `import` in the package's world;
  the host (via `jco`) satisfies it with the JS package.

### 9.3 Shim files

For each `[npm]` entry `lyric restore` generates `_extern_npm/<pkg>.l`:

- **Committed to the source tree**, so reviewers see the imported surface in
  diffs. Same policy as NuGet shims.
- **Marked `@axiom`**, placing them in the same trust tier as `_kernel/*.l`.
- **Manually authored in v1.** NPM packages have no machine-readable type
  signatures beyond `.d.ts`; a future `lyric restore --generate-npm-shims`
  could translate `.d.ts` to Lyric extern declarations.

```lyric
@axiom("from npm node-fetch ^3")
package NodeFetch

@externTarget("npm", package: "node-fetch", symbol: "default")
pub extern func fetch(in url: String): Async[Result[Response, FetchError]]

pub exposed record Response {
    pub status: Int,
    pub ok: Bool
}

pub exposed record FetchError {
    pub message: String
}
```

NPM package names map to Lyric package identifiers by stripping `@`,
replacing `/` with `.`, and PascalCasing each `-`/`_`-separated segment
(`node-fetch` to `NodeFetch`, `@aws-sdk/client-s3` to `AwsSdk.ClientS3`).

### 9.4 Diagnostic codes

| Code | Meaning |
|---|---|
| `B0040` | NPM package failed to install (`npm install` non-zero exit) |
| `B0041` | Package declared in `[npm]` but no shim in `_extern_npm/`; run `lyric restore` |
| `B0042` | Shim references a symbol not present in the installed package version |
| `B0043` | `@axiom` shim was hand-edited to remove the annotation; restore refused |

---

## 10. Degraded-semantics policy

Each Lyric feature without a direct WASM equivalent is either **(A)** a compile
error or **(B)** a documented runtime approximation. Silent stripping is never
correct.

### 10.1 `protected type`

**Policy:** (A) at the export surface, (B) internally.

At the export surface it is rejected:

```
E0050: `protected type Ledger` cannot appear in a wasm export surface.
       Expose a non-protected facade record instead.
```

Internally it is allowed in the single-threaded v1 profile (§5.2): mutual
exclusion is trivially satisfied by the single thread and the lock is a
nesting-depth counter (a nested acquire by the current holder increments it;
it exists for correct release bookkeeping, not to permit concurrent access). A blocking acquire on an already-held lock panics. This
matches the entry-barrier semantics when no other thread can release.

### 10.2 Range subtypes

**Policy:** (B). They map to their underlying WIT primitive. The range
invariant is checked at the export boundary: entering with an out-of-range
value triggers a contract failure (as a `requires:` violation in
`@runtime_checked` mode). Generated TS bindings carry a JSDoc range note.

### 10.3 `@proof_required`

**Policy:** (B), silently downgraded to `@runtime_checked` for wasm builds
unless `[wasm] strict = true` (Q-JS-003 resolved to opt-in strict; see §13.1),
which makes it a compile error. SMT verification is a compile-time property
and does not change the emitted binary.

### 10.4 Opaque types and the no-reflection guarantee

**Preserved.** Opaque types do not appear in the WIT surface; JS callers see
only `@projectable` exposed twins. The sandbox enforces that structurally.
Boundary records cross into JS as ordinary inspectable objects, which is
documented and expected.

### 10.5 Unavailable platform capabilities

Process spawn, sockets, TLS and the HTTP server are unavailable on wasm
(§5.3). They return a defined error value rather than failing to link.

---

## 11. Async lowering

The native backend lowers `async func` through LLVM coroutines onto the
runtime's single-threaded ready-queue scheduler. On wasm32 that is unchanged
except at the host edge:

- **`module` shape:** the scheduler is driven by the host event loop. Sleeps
  and timers become host timer imports; an exported `lyric_poll`/callback
  re-enters the scheduler when a host promise resolves. Blocking is never
  used.
- **`component` shape:** `Async[T]` maps to WIT `future<T>` once the
  Component Model async ABI is stable (Q-JS-006). Until then `async func`
  exports use a callback-style or synchronous-subset lowering with a warning.

No separate backend pass is needed (the earlier revision's claim that the
MSIL/JVM state-machine lowering needed an unrelated WASM pass no longer
applies, because the native lowering is coroutine-based).

---

## 12. Phases

| Phase | Scope | Notes |
|---|---|---|
| W0 | **Shipped (#7960).** Layout hardening, target-neutral: three-field ARC header, allocation sizes from LLVM (`NSizeOf`) instead of 64-bit size tables, pinned wasm32 datalayout, fixed-width `lyric-rt` wrappers for the `size_t`/variadic libc externs. The coroutine size intrinsic needed no change, and the `Long`-as-pointer audit found only `libc.l` exposed on the wasm-relevant kernels | Landed ahead of any wasm work; benefits existing targets; verified by every native self-test suite plus a wasm32 lowering smoke test that compiles with clang's WebAssembly backend |
| W1 | 32-bit `Float` | Owned by a separate work stream (`docs/67` G1); this plan blocks the `component` type mapping on it |
| W2 | **Slice 1 shipped (runtime, #7995):** `lyric-rt` builds for `wasm32-wasi` and its C tests run under wasmtime in CI. **Slice 2 (compiler):** the native bridge links `--triple wasm32-wasi` with a wasi-sdk clang against the per-triple runtime archive, emits `__main_argc_argv`, and `llvm_wasm32_self_test.l` runs Lyric programs under wasmtime in CI. **Slice 3 (open):** the TCP/TLS, piped-process and HTTP-server kernels declare pointer handles as `Long`, which wasm-ld rejects, so programs reaching them do not link yet. `wasm32-wasi` build: wasi-sdk pinned, per-triple `lyric_rt`, `wasm32` datalayout, link recipe, single-threaded runtime, unavailable-kernel twins, wasmtime test lane | Shape-agnostic bring-up: a plain core module that runs under WASI with no JS glue or WIT. It is the shared codegen base that W3 (`module`) and W4 (`component`) build their boundary code on, so it is not itself either published shape |
| W3 | Browser `module` shape: JS imports (console, timers, `abort`), glue generator, `docs/65` U7 hook | |
| W4 | `component` shape: canonical ABI wrappers, WIT generation, `jco` integration, publish bundle | |
| W5 | `[npm]` table, `lyric restore`, extern shims, `B004x` diagnostics | |

Each phase also updates `docs/01`, the book (toolchain table and CLI
appendix), `docs/10-bootstrap-progress.md`, and adds a `docs/progress/`
entry, per repository policy.

---

## 13. Open questions

### 13.1 Resolved in review (2026-10-01)

- **Route.** Native backend to `wasm32`; the .NET WASI route is dropped (§3).
- **Q-JS-001** (`protected type` internal use): allowed in the
  single-threaded v1 profile as a re-entrancy-counter lock; export-surface use
  stays an error (§5.2, §10.1).
- **Q-JS-003** (`@proof_required`): downgraded by default, with
  `[wasm] strict = true` making it a compile error (§10.3).
- **Q-JS-005** (`lyric test`): tests run on the wasm artifact under wasmtime
  or node via the native test lane (§5.4); a native-host run remains the
  default for ordinary development.
- **Ordering with `docs/67` G1:** wasm32 waits for, or includes, the 32-bit
  `Float` change (W1).

### 13.2 Still open

**Q-JS-002 — NPM shim ownership.** Curated shims in-tree (`stdlib/npm/`),
in a community registry, or generated from `.d.ts`. Start in-tree for a small
set; decide the registry model before the 20th package.

**Q-JS-004 — Scoped NPM name collisions.** `@a/b-c` and `@a/b` plus `-c` can
map to the same Lyric name. Suffix disambiguator, or hard `lyric restore`
error?

**Q-JS-006 — WIT async stability.** Gate the `component` async export on the
Component Model async ABI stabilising, or ship the callback/synchronous
subset first with a warning?

**Q-JS-007 — Linear-memory limits.** Default stack size and maximum heap for
the `module` shape; whether `lyric_alloc` failure traps or returns an error.

**Q-JS-008 — Browser I/O.** Whether `Std.Http` gets a `fetch`-backed browser
twin kernel in W3 or later, and how `Std.File` behaves with no preopened
filesystem.

**Q-JS-009 — Threads profile.** Whether `wasm32-wasi-threads` (shared memory,
`+atomics`, cross-origin isolation) is ever supported, and what it would do to
the single-threaded `protected type` semantics.

---

## 14. Out of scope

- **Browser packaging.** Bundling (webpack, Vite, Rollup) is the JS
  developer's concern; we provide the `.wasm`, glue, WIT and optional TS
  bindings.
- **WasmGC backend.** A standalone WasmGC emitter would be a new backend and
  is deferred until the toolchain matures.
- **TypeScript transpilation target.** See §3.2.
- **.NET WASI.** See §3.3.
- **Deno and Bun specifics.** The component artefact works on both; platform
  packaging is deferred.
- **NPM shim auto-generation from `.d.ts`.** Manual in v1.
- **Transitive NPM dependencies.** Installed but not shimmed, matching the
  NuGet policy in `docs/21-nuget-linking.md` §11.
