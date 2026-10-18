# Spike: Component Model async ABI for the wasm32 `component` shape (docs/35 Q-JS-006)

A time-boxed spike, not a feature. It answers what Lyric's
`--target native --triple wasm32-wasi --shape component` build would need to
emit WASI 0.3 ("Preview 3") async: `async func`, `future<T>`, `stream<T>` and
the async canonical-ABI built-ins. No compiler or runtime code for async ships
with this entry. Every claim below is marked **verified** (a command was run
and its output is quoted or summarised) or **unverified** (read from a spec or
inferred, not run).

Today (unchanged by this spike): an `async func` export is lowered as a blocking
WIT function with warning `W0041` (D-progress-1043), and a
`@wasmImport(..., promise)` extern is rejected in the component shape
(component_glue.l's `promise` check, `N0018` at the bridge; D-progress-1048).

## 1. Spec status

Read on 2026-10-17 from `WebAssembly/component-model` `main` (raw files
`README.md`, `design/mvp/Explainer.md`, `CanonicalABI.md`,
`canonical-abi/definitions.py`, `WIT.md`, `Concurrency.md`) and
`WebAssembly/WASI` `main` (`README.md`, `docs/Proposals.md`). The GitHub API
returns 403 from this sandbox, so no commit SHA was recorded; the content is
pinned by date and by the file hashes in the appendix.

- The component-model README lists three WASI Developer Preview releases:
  **0.2.0**, **0.3.0** ("the first release with native concurrency support ...
  adds `async` functions, `stream`s and `future`s as well as new ABI built-in
  functions") and **0.3.1** (`map<K,V>` and the `implements`/`external-id`
  annotations).
- The spec marks each post-0.2 feature with an emoji gate, written here as
  `[name]`. Explainer.md "Gated Features" says `[async]` (native concurrency:
  `async`, `stream`, `future`), `[map]` and `[implements]` "have already
  shipped as part of a subsequent WASI Developer Preview release ... and thus
  are not open to breaking changes before the final 1.0 release."
- Still gated (may break, not on by default): `[more-async-builtins]` more canonical options on
  async built-ins, `[stackful]` **stackful** async lift (`async` without `callback`),
  `[threads]` threading built-ins, `[error-context]` `error-context`, `[forward]` `stream.forward`/
  `future.forward`, `[fixed-length-lists]` fixed-length lists, and others.
- WASI README: "WASI 0.3 (Preview 3) is the current preview ... replacing the
  earlier explicit streams and polling interfaces with the component model's
  native, composable `async` functionality via the `future` and `stream`
  types."

So the stability precondition docs/35 Q-JS-006 waited for is met for the
**stackless (callback) async lift**, async lower, `task.return`,
`waitable-set.*`, `subtask.*`, `future.*`, `stream.*`, `context.get/set`,
`backpressure.inc/dec` and `thread.yield`. Stackful lift and `error-context`
are not stable.

ABI facts Lyric's wrappers depend on (from `CanonicalABI.md` /
`definitions.py`, cross-checked against wit-bindgen output and the PoCs in §2):

| Item | Rule |
|---|---|
| Async lift, callback | core `(params...) -> i32`; the `i32` packs `code \| (waitable_set << 4)`, codes `EXIT=0`, `YIELD=1`, `WAIT=2`; the callback is `(event, p1, p2) -> i32` with the same packing |
| Async lift result | never a core result: the callee calls `task.return` with the flattened result as **parameters** (a pointer when it spills past `MAX_FLAT_PARAMS = 16`) |
| Async lower | params spill to memory past `MAX_FLAT_ASYNC_PARAMS = 4`; a result is always written through a trailing out-pointer; core result is `i32` = `subtask_state \| (subtask_handle << 4)`, states `STARTING=0, STARTED=1, RETURNED=2, CANCELLED_BEFORE_STARTED=3, CANCELLED_BEFORE_RETURNED=4` |
| Events | `NONE=0, SUBTASK=1, STREAM_READ=2, STREAM_WRITE=3, FUTURE_READ=4, FUTURE_WRITE=5, TASK_CANCELLED=6` |
| `{future,stream}.new` | returns `i64`: readable handle in the low 32 bits, writable in the high 32 |
| `{future,stream}.{read,write}` | return `-1` (`BLOCKED`) or `state \| (count << 4)` with `COMPLETED=0, DROPPED=1, CANCELLED=2` |
| Core names (wit-component) | export `[async-lift]<name>` and `[callback][async-lift]<name>`; import `[export]<iface>` `[task-return]<name>`; import `<iface>` `[async-lower]<name>`; `$root` `[waitable-set-new]`, `[waitable-join]`, `[waitable-set-wait]`, `[subtask-drop]`, `[context-get-0]`, ...; `[export]<iface>` `[future-new-N]<fn>`, `[async-lower][future-write-N]<fn>`, `[stream-new-N]<fn>`, ... ; stackful lift is `[async-lift-stackful]<name>` |

The naming table was taken from `wit-bindgen c` 0.63.0 output for a test WIT
(**verified**: generated and read) and confirmed by `wasm-tools component new`
accepting hand-written modules that use those names (**verified**, §2).

## 2. Toolchain

Versions tested. "Newest" was found from crates.io (`wasmtime-cli` max stable
49.0.3, `wasm-tools` 1.262.0, `wit-bindgen-cli` 0.63.0), npm (`jco` 1.39.0,
`preview2-shim` 0.30.0, `preview3-shim` 0.11.0) and by probing release-asset
URLs (wasi-sdk 34 exists, 35-38 return 404; wasmtime 49.0.4 and 50.0.0 return
404). All were downloaded into empty scratch directories.

| Tool | Current pin | Newest tested |
|---|---|---|
| wasi-sdk | 24 (clang 18) | 34 (clang 23.1.0) |
| wasmtime (+ preview1 reactor adapter) | 26.0.1 | 49.0.3 |
| wasm-tools | 1.220.0 | 1.262.0 |
| jco | 1.8.1 | 1.39.0 |
| preview2-shim | 0.17.1 | 0.30.0 (plus preview3-shim 0.11.0) |
| wit-bindgen (reference only) | - | 0.63.0 |
| node | runner default (22.22.0 here) | 22.22.0, 24.22.0 (LTS), 26.12.0 |

Hand-written proof-of-concept components (WAT core modules or C plus a
hand-written WIT, none generated by Lyric), all **verified**:

| PoC | What it exercises |
|---|---|
| A | root exports `double-later: async func(x: u32) -> u32` (YIELDs once, `task.return` from the callback) and `greet: async func(name: string) -> string` |
| B | export `run: async func(ms: u32) -> u32` that async-lowers WASI 0.3 `wasi:clocks/monotonic-clock@0.3.0.wait-for`, waits on a waitable set, returns `ms + 1` |
| C | export `run` async-lowering a custom `lyric:spikec/host.fetch-len: async func(url: string) -> u32` (JS `async function`), and `one: async func(x: u32) -> future<u32>` (returns the readable end, then writes `x*3`) |
| E | `numbers: async func(n: u32) -> stream<u32>` writing `0..n-1` then dropping the writable end |
| F | PoC A lifted stackful (`[async-lift-stackful]`, no callback) |
| G | PoC A's exports written in C against `wit-bindgen c` bindings, compiled `--target=wasm32-wasip1 -mexec-model=reactor` with wasi-sdk 34, `fprintf(stderr)` through wasi-libc, componentized with the **preview1 reactor adapter**: the same pipeline shape Lyric uses |

Results:

| Question | wasm-tools 1.220.0 | wasm-tools 1.262.0 | wasmtime 26.0.1 | wasmtime 49.0.3 | jco 1.8.1 | jco 1.39.0 |
|---|---|---|---|---|---|---|
| (a) parse/validate WIT with `async func`, `future<T>`, `stream<T>` | **no**: `expected keyword func, found an identifier` at `async` | **yes**, default features | - | - | - | - |
| (b) componentize a core module using async built-ins (A, B, C, E, G) | n/a | **yes**, `component embed` + `component new`, validates with default features | - | - | - | - |
| (b') stackful lift (F) | n/a | builds; `validate` fails "requires the component model async stackful feature" unless `--features cm-async-stackful` | - | - | - | - |
| (c) run async export A | old validator rejects component (`invalid leading byte (0x9) for canonical function`) | - | **no**, same parse error | **yes**, no flags: `run --invoke 'double-later(21)'` prints `42`, `greet("lyric")` prints `"lyric"` | **no**: `failed to extract interface information from component` | **yes** on node 24 and 26 (no flags): `doubleLater(21)` returns a Promise resolving to `42`; **no** on node 22: `WebAssembly.promising is not a function` (also with `--experimental-wasm-jspi`) |
| (c) WASI 0.3 async import B | - | - | - | **yes**: `run(250)` prints `251` after about 260 ms, with and without `-S p3` | - | **yes** (node 24): jco imports `@bytecodealliance/preview3-shim/clocks`; `run(250) -> 251`, about 262 ms |
| (c) JS-host async import C | - | - | - | not runnable from the CLI (custom import; `--invoke` needs a linker that provides it) | - | **yes** (node 24), with `--map lyric:spikec/host=./host.js`: `run("https://x") -> 1009` after the JS promise's 100 ms; `.d.ts` types the import `fetchLen(url: string): Promise<number>` |
| (c) `future<u32>` export C | - | - | - | **unverified** (the CLI cannot run C, see above) | - | **yes**: `one(14)` resolves to a `FutureValue` whose value is `42`; `.d.ts`: `Promise<PromiseLike<number>>` |
| (c) `stream<u32>` export E | - | - | - | **no output**: `--invoke 'numbers(5)'` panics in `wasm-wave` "unsupported value type" (the CLI's value printer, not the runtime) | - | **partly**: iterates five elements but yields `{"0":0}, {"0":1}, ...` while the `.d.ts` says `AsyncIterable<number>`; looks like a jco bug in `u32` stream element lifting, not filed |
| (c) stackful F | - | - | - | **yes** with `-W component-model-async-stackful=y`; without it the module fails to parse | - | **yes** (node 24); the callee never blocks, so this does not prove jco handles a blocking stackful callee |
| (c) adapter + async export G | - | - | - | **yes**: prints the stderr lines and `42`; component imports `wasi:*@0.2.12` from the 49.0.3 adapter alongside the async export | - | **yes** (node 24) |

Flags summary: wasm-tools 1.262 and wasmtime 49 need **no flags** for the
stable (`[async]`) subset; stackful needs `--features cm-async-stackful` /
`-W component-model-async-stackful=y`. jco 1.39 needs no transpile flag for
native CM async (its `--async-mode jspi`/`--async-imports` options are for the
older JSPI-over-sync-functions path), but its output calls
`WebAssembly.promising`, so the host must be **node >= 24** (V8 13.6 here).
Node 22 cannot run any async-lifted export from jco 1.39.

Not verified: wasmtime running `future`/`stream` values end to end (needs a
Rust embedding or a composed consumer component; `wac` was not tried),
cancellation (`subtask.cancel`, `TASK_CANCELLED`), backpressure, more than one
concurrent call into the same instance, and browsers.

## 3. Upgrade impact on the existing suite

Bumped locally to wasi-sdk 34, wasmtime 49.0.3 (and its preview1 reactor
adapter), wasm-tools 1.262.0, jco 1.39.0 and preview2-shim 0.30.0, with the
SHA-256s re-derived from fresh downloads (appendix). Baseline on the current
pins: `llvm_wasm32_component_self_test.l` 24/24 (**verified**).

With the new pins and no source changes, the wasm32 runtime did not build and
18 of 24 component tests failed. Every failure had one of three causes, all
"upgrade only" (nothing async):

1. **clang 23 deprecates `--target=wasm32-wasi`.** `lyric-rt/Makefile` builds
   with `-Werror`, so `make -C lyric-rt wasm32-wasi` stopped at
   `argument '--target=wasm32-wasi' is deprecated, use --target=wasm32-wasip1
   instead`. Fix: `WASM_CFLAGS` uses `--target=wasm32-wasip1` (wasi-sdk 24's
   clang 18 accepts it too; runtime unit tests pass under both toolchains).
2. **wasi-sdk 34's sysroot has no `wasm32-wasi` headers** (only
   `wasm32-wasip1`, `-wasip1-threads`, `-wasip2`, `-wasip3`; wasi-sdk 24 had
   both spellings). The bridge normalised `--triple wasm32-wasi` to
   `wasm32-unknown-wasi`, so compiling the generated `.cabi.c` failed with
   `'stdlib.h' file not found`: 17 failures. Fix: `normalizeNativeTriple`
   (`llvm_bridge.l`) maps it to `wasm32-unknown-wasip1`. The user-facing
   `--triple wasm32-wasi` is unchanged.
3. **LLVM 23 changed `llvm.coro.end` to return `void`** (it returns `i1` in
   LLVM 18) and auto-upgrades old calls, but the backend named the result
   (`%coro.done = call i1 @llvm.coro.end(...)`), so the upgraded call was
   invalid: `Instruction has a name, but provides a void value!`. Only the
   async-export test (21) hit it; it would hit any native async code built by
   LLVM >= 23. Fix: the call is emitted unnamed (`NCall` with an empty `dest`
   now renders without an assignment in `llvm_ir.l`); the `i1` declaration
   stays because LLVM 18 rejects a `void` one. Checked against wasi-sdk 24's
   clang 18, wasi-sdk 34's clang 23 and the host's clang 18.1.3.

No jco CLI change, preview2-shim API change or adapter change broke anything:
jco 1.39 still has `--map`, `-o` and `--name`, the sync-shape output runs on
node 22, and the 49.0.3 adapter's `wasi:*@0.2.12` imports are satisfied by
preview2-shim 0.30.0.

After the three fixes (**verified**, all locally):

| Check | Old pins | New pins |
|---|---|---|
| `make -C lyric-rt test-wasm32-wasi` | passed | passed |
| `llvm_wasm32_self_test.l` | - | 11/11 |
| `llvm_wasm32_module_self_test.l` | 32/32 | 32/32 |
| `cli_wasm_npm_project_self_test.l` | - | 6/6 |
| `llvm_wasm32_component_self_test.l` | 24/24 | 24/24 |
| `memfs_test.mjs`, `gen_wasm_glue.py --check`, `audit-native-extern-abi.sh` (0 mismatches), `audit-axioms.sh`, `audit-kernel-stubs.sh`, `audit-strchar-collision.sh` | - | pass |
| `scripts/ci/wasm32-wasi-rt-tests.sh` end to end, fresh tool cache (downloads, SHA-256 checks, npm install, every suite) | - | exit 0 |
| a host `--target native` async program (`spawn` + two `await`s) | - | prints the expected value |

Not verified here: the host native ASan suites (`llvm_heap_self_test.l`,
`llvm_stdlib_self_test.l`) cannot link in this sandbox
(`libclang_rt.asan_static-x86_64.a` is missing), so the coroutine change is
covered on the host only by the non-ASan program above and by CI.

The bump and its three fixes ship as a separate PR (no async in it). Its
CI lane still runs on the runner's node; it needs node >= 24 only once the
suite exercises async exports through jco (§2).

## 4. What Lyric would need

The native backend already lowers `async func` to LLVM coroutines on a
single-threaded ready-queue scheduler (`lyric_task_*`, `lyric_sched_poll`,
`lyric_host_task_*`; docs/35 §11). Coroutines are stackless, which matches the
**callback** (stackless) lift exactly: Lyric never needs the gated stackful
lift or stack switching. The work is all at the boundary.

### 4.1 WIT emission (`component_glue.l`, `renderWit` and the export/import collectors)

- Emit `name: async func(...) -> T` for a `pub async func` export instead of
  the sync signature, and drop `W0041` for it.
- Emit `async func` for a `@wasmImport(..., promise)` extern and stop rejecting
  it in the component shape (the `promise` check near line 1862, `N0018` in
  `llvm_bridge.l`).
- Type mapping for `future<T>` and `stream<T>` (see 4.5). WIT `error-context`
  stays out (`[error-context]` gated).

### 4.2 Async exports: callback lift (`component_glue.l` `renderCabi`/`cabiRuntime`)

Replace `cabi_drive` (which busy-loops `lyric_wasm_poll` plus `nanosleep`)
with two generated C entry points per async export (unverified design):

- `[async-lift]<name>(flat args)`: lift arguments as today, call the shim
  (which returns the Lyric `LyricTask*`), store it in per-call state, then run
  one scheduler turn (below).
- `[callback][async-lift]<name>(event, p1, p2)`: dispatch the event (4.4),
  then run one scheduler turn.
- A scheduler turn calls `lyric_sched_poll()`. If this call's task is complete:
  lower the result exactly as the sync path does today, but pass it to the
  `[task-return]<name>` import as parameters (a pointer when the flat form
  exceeds 16 values; memory and `realloc` options must match the lift's) and
  return `EXIT`. Otherwise: `-2` (host operations pending) returns
  `WAIT | set << 4`; `> 0` (a timer) starts an async-lowered
  `wasi:clocks/monotonic-clock@0.3.0.wait-for` subtask and waits on it (PoC B
  shows that call works), or returns `YIELD` if the shape should not import a
  0.3 clock; `-1` traps as today.
- Per-call state must not be a C global: two concurrent calls into one
  instance are allowed, and `task.return` only returns for the *current*
  CM task. Keep it behind `context.set`/`context.get` slot 0 (`[context-set-0]`).
- Cross-call completion: one scheduler turn may complete a *different* call's
  Lyric task. That call cannot be `task.return`ed from here, so it needs a
  wake-up: either each call joins a private unit `future` into its waitable
  set and the completing turn writes it, or turns return `YIELD` while some
  other call is complete but unreturned. The first is precise, the second is
  simpler; this is the main open design question (not verified).
- Leave `cabi_post_*` for sync exports only (async lifts have no post-return).
- Stack: WIT async lifts run on the caller's stack for each callback turn, so
  `[wasm] stack` keeps its current meaning.

### 4.3 Async imports: async lower (`component_glue.l` `renderImportWrapper`)

For a `promise` host import (unverified design, but PoC C shows the ABI):

- Lower arguments (spilling past 4 flat values into a heap buffer that lives
  until the subtask is `STARTED`), pass a result buffer, call
  `[async-lower]<name>`.
- `RETURNED`: lift the result now and return an already-finished host task
  (`lyric_host_task_new` + `lyric_host_task_finish`).
- `STARTING`/`STARTED`: create `lyric_host_task_new()`, record
  `{subtask handle, LyricTask*, arg buffer, result buffer, lift function}` in a
  wrapper table, `waitable.join` the subtask into the instance's waitable set,
  and return the task; the Lyric caller `await`s it like any task.
- On `SUBTASK` events: `STARTED` frees the arg buffer; `RETURNED` lifts the
  result buffer and calls `lyric_host_task_finish` (or `lyric_host_task_fail`
  for a lift error), then `subtask.drop`. `lyric_host_tasks_pending()` already
  makes `lyric_sched_poll` report `-2`, which maps to `WAIT`.
- The module shape's `lyric_wasm_host_finish_*` / `lyric_wasm_host_fail`
  exports are not needed in the component shape; the finish happens inside
  the generated C.
- Import calls from a sync export: a sync-lifted export may not block, so an
  async import used from a non-async export would trap. The rule "a `promise`
  import is only callable from an `async` context" already holds in Lyric
  through `await`, but the checker should say so with a diagnostic in the
  component shape.

### 4.4 Runtime hooks (`lyric-rt/src/lyric_wasm_async.c`, a new component twin)

| CM concept | Lyric runtime |
|---|---|
| async-lifted export call | `lyric_task_new` (via the shim) + per-call record in context slot 0 |
| `task.return` | after `lyric_task_is_complete`, from `lyric_task_result` |
| `task.cancel` / `TASK_CANCELLED` event | no Lyric equivalent yet; needs a cancel hook on `LyricTask` (docs/68 `cancel`, unshipped). V1: ignore the event and finish normally (allowed, `task.cancel` is optional) |
| subtask (async-lowered import) | `lyric_host_task_new` / `lyric_host_task_finish` / `lyric_host_task_fail` |
| `waitable-set.wait` | not called: the callback loop returns `WAIT` instead (no blocking in core code) |
| scheduler turn | `lyric_sched_poll`, unchanged contract (`>0` ns to next timer, `-2` host pending, `-1` dead) |
| timers | today `nanosleep` through the preview1 adapter; under async either a 0.3 `wait-for` subtask or `YIELD` |

New C entry points the generated wrappers would call: a dispatcher
`lyric_cabi_on_event(event, handle, code)` and a subtask table
(`lyric_cabi_subtask_add/take`). They belong in generated C or a new
`lyric_component_async.c` that only component builds link, as
`lyric_wasm_async.c` is today for the module shape.

### 4.5 Types: `Async[T]`, `future<T>`, `stream<T>`

- `async func f(...): T` in Lyric (a `Task[T]` result) maps to WIT
  `async func f(...) -> T`, not to `-> future<T>`. That is what docs/35 §11
  should say: the CM's `async` function effect already carries "the caller may
  wait", and both hosts present it as a Promise (verified in jco). This
  supersedes the "`Async[T]` maps to WIT `future<T>`" line in docs/35 §11.
- `future<T>` as a value (a parameter, a record field, a result of a sync
  function) is a separate, rarer need (e.g. HTTP trailers). Mapping it to
  `Task[T]` collides with docs/68's planned rule that handles cannot escape
  their `scope` (V0035): a received future is created outside any Lyric scope
  and a returned one escapes. Recommend a distinct boundary type (e.g.
  `Std.Component.Future[T]`) with `await` support, deferred until a consumer
  needs it.
- `stream<T>`: `Std.Stream` is a synchronous, `Result`-returning
  `ByteReader`/`ByteWriter`/`TextReader`/`TextWriter` set with no element
  type and no async. Options: (1) map only `stream<u8>` onto
  `Std.Stream.ByteReader`/`ByteWriter` by blocking the calling task through the
  scheduler (fits WASI 0.3's `wasi:cli` and `wasi:http` byte streams, no new
  language surface); (2) a new generic async type (`AsyncReader[T]` /
  `AsyncWriter[T]` with `async func read(max): Result[List[T], E]`). Open
  question for a decision entry; recommendation: (1) first, since every WASI
  0.3 stream that matters is bytes.

### 4.6 Phased plan

| Phase | Scope | Size | Needs |
|---|---|---|---|
| A0 | Toolchain bump (§3), no async | S | wasi-sdk 34, wasmtime 49.0.3, wasm-tools 1.262.0, jco 1.39.0, preview2-shim 0.30.0, node >= 24 on the jco steps |
| A1 | Async exports with scalar/`String`/compound results via callback lift; one call in flight per instance (traps or queues a second, decided in A1); timers by `YIELD`; drop `W0041` | M | wasm-tools 1.262.0 (1.220.0 rejects async WIT; the first accepting release was not bisected), wasmtime 49.0.3 for tests, jco 1.39.0 + node >= 24 |
| A2 | `promise` host imports via async lower (lift `N0018`'s component rejection); subtask table; `SUBTASK` events finish host tasks | M | same as A1 |
| A3 | Concurrent calls per instance (context slot state, cross-call wake-up), 0.3 clock subtask for timers, cancellation mapping once docs/68 `cancel` exists | M | same; wasmtime `-S p3` for the clock import |
| A4 | `stream<u8>` <-> `Std.Stream` byte interfaces, then `future<T>` boundary type | L | jco fix for stream element lifting (or a newer jco), a wasmtime embedding or composed consumer for tests |
| - | Stackful lift | not planned | gated (`[stackful]`); unnecessary with coroutines |

## 5. Recommendation

**Go**, for the stackless subset. The precondition Q-JS-006 waited on is met:
async functions, `future` and `stream` shipped in WASI 0.3.0 and are frozen
until 1.0, and the current toolchain (wasm-tools 1.262.0, wasmtime 49.0.3,
jco 1.39.0 on node >= 24) builds and runs hand-written async components
through the same wasip1 + preview1-adapter pipeline Lyric uses. Lyric's
coroutine lowering fits the callback lift with no stack switching, and the
gated pieces (stackful lift, `error-context`) are not needed.

Smallest first slice (A1 above), after the toolchain-bump PR lands:

- `pub async func` exports emit `async func` in the WIT and a
  `[async-lift]` / `[callback][async-lift]` pair that runs
  `lyric_sched_poll` turns, returns `YIELD` while timers are pending, and
  calls `[task-return]` with the existing result lowering.
- One call in flight per instance (per-call state behind `context.set`
  slot 0, but a second concurrent call traps with a clear message until A3).
- `W0041` removed for the component shape; the existing async test (21)
  becomes "an async export returns a Promise under jco and a value under
  wasmtime".
- CI: the jco steps run on node 24.

Defer imports (A2), concurrency and timers via WASI 0.3 clocks (A3) and
`stream`/`future` values (A4); A4 also waits on the jco stream element bug
seen in PoC E. Open questions to record with A1's decision entry: the
cross-call wake-up mechanism (§4.2), whether `future<T>` gets its own type
or reuses `Task[T]` (§4.5), and `stream<u8>` onto `Std.Stream` versus a new
generic async stream type.

## Appendix: reproduction

SHA-256 of the downloads (all fetched 2026-10-17):

```
b761e3a0721dbae9c09a0059e5fdb2bf917d1b4a8a7b430fb3b5aafb0984b2c4  wasi-sdk-34.0-x86_64-linux.tar.gz
4001225413f208345b980525f31c4080e1873808b38d0ddc7918497340667fbb  wasmtime-v49.0.3-x86_64-linux.tar.xz
79fa20ff8d49f1aba13d25af4fd616a1431028fff954b2927e55fcac4fefd6e3  wasi_snapshot_preview1.reactor.wasm (v49.0.3)
655b8df67d54c3ef9b52fc237c4e94bbfbb5f5f43825245cb0940a7002a9ed65  wasm-tools-1.262.0-x86_64-linux.tar.gz
bf4efe883ab70d34a4740253911dda20caf895d58a003af58369506b04684cbe  wit-bindgen-0.63.0-x86_64-linux.tar.gz
cc2f601cee82d9a5a233302fe307abc600727035fd7d2c3a3571755989e95008  node-v24.22.0-linux-x64.tar.xz
fd47865ecd6391ebb431fc815e01b9135bf83ded5cf373247e9331e196b7aded  node-v26.12.0-linux-x64.tar.xz
```

The current pins' downloads matched the SHA-256s in
`scripts/ci/wasm32-wasi-rt-tests.sh`.

PoC A, the minimal async export (core module; `world exp { export
double-later: async func(x: u32) -> u32; ... }`):

```wat
(module
  (import "[export]$root" "[task-return]double-later" (func $ret (param i32)))
  (memory (export "memory") 1)
  (global $saved (mut i32) (i32.const 0))
  (func (export "[async-lift]double-later") (param $x i32) (result i32)
    local.get $x
    global.set $saved
    i32.const 1) ;; YIELD
  (func (export "[callback][async-lift]double-later") (param i32 i32 i32) (result i32)
    global.get $saved
    i32.const 2
    i32.mul
    call $ret
    i32.const 0)) ;; EXIT
```

```sh
wasm-tools parse core.wat -o core.wasm
wasm-tools component embed wit/ core.wasm -w exp -o embedded.wasm
wasm-tools component new embedded.wasm -o comp.wasm
wasmtime run --invoke 'double-later(21)' comp.wasm        # 42
jco transpile comp.wasm -o js --name comp                  # then on node >= 24:
node -e 'import("./js/comp.js").then(async m => console.log(await m.doubleLater(21)))'
```

SHA-256 of the spec files as read on 2026-10-17 (raw `main` of
`WebAssembly/component-model` and `WebAssembly/WASI`):

```
267bfc5decf4eb7952090324c9e845c8598e611d8de9dcc8cd7594d6a1f21f6c  component-model/design/mvp/Explainer.md
0790395f318e84e0af5d8adae5bc222388470bf1b5a7da157b7650120e90b65c  component-model/design/mvp/CanonicalABI.md
eff34e28dc0917f8a3690cb6cf3a182977b168a38ba2171c9c49b0edba38c8ca  component-model/design/mvp/canonical-abi/definitions.py
56d661602a66623d856f28a2d10eeaa10323dc33c5dcb65b985291015ca50415  component-model/design/mvp/WIT.md
ee0d9ef5bc7ecb28e33525d1f66c6726dde7e8df04d9fbb9131df921c34eec93  component-model/design/mvp/Concurrency.md
e4f10e26b987c4b6b72624a9e55acf2736308087c8091948ded1516812ceecb6  component-model/README.md
8d6c2db209df59fb17fb419724d8fb78530e523c35ef7d398fa36e64a35f46e5  WASI/README.md
e2c7d077e1392b28b3a5743d80cb102969aeb5b8798063e61d72adc1ecd433ee  WASI/docs/Proposals.md
```

The design questions this spike left open are settled in D184.
