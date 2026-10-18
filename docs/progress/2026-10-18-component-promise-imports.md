# Component shape: promise host imports are async-lowered WIT imports (D184 slice A2)

`@wasmImport("module", promise)` now works in `--shape component` builds
(D-progress-1048 had restricted it to the module shape). The import is a WIT
`async func`, and the importing code awaits it like any async call.

- **Lyric side.** A promise import always takes the image path. The generated
  wrapper is an `async func` with the extern's name and signature. It stores
  the arguments in a memory image (canonical layout), allocates a return area
  for any non-`Unit` result, calls the raw extern, which the call awaits in
  place, then frees the image and reads the result from the area.
- **Codegen.** The bridge records the raw extern's C symbol as a module-less
  promise import (`WasmImportDecl` with an empty module), so codegen declares
  it returning the task pointer and awaits each call, as it does a module-shape
  promise import.
- **C side.** `cSym(image, area)` makes the `[async-lower]` core call. It
  passes up to 4 flat arguments read from the image, else the image's address,
  plus the area as the result's out-pointer. It hands the returned status to
  `lyric_cabi_host_call`:
  - A `RETURNED` status yields an already-finished host task.
  - Otherwise the subtask is recorded with a pending `lyric_host_task_new`
    task, and is joined to the running call's waitable set (later calls take
    every outstanding subtask into their set).
  - A `SUBTASK` event at `RETURNED` finishes the task and drops the subtask.
    A cancelled state fails it with `host import was cancelled before it
    returned`.
  - The image and area stay allocated until the wrapper has awaited the task,
    so the host may read the arguments and write the result late.
- **WIT.** Promise imports render as `name: async func(...)`. A component with
  only promise imports (no async export) also gets the async runtime and the
  WASI 0.3 clock import. Two externs binding one host function with and
  without `promise` are an `N0019` signature clash.

A host rejection never reaches the Lyric code (the Component Model's only error
channel is a `result` in the signature). Checked under jco 1.39.0: the pending
export call rejects with the host's error.

Verified locally with wasi-sdk 34, wasmtime 49.0.3, wasm-tools 1.262.0, jco
1.39.0 and node 24.22.0. The new component test imports four promise functions
from a JS host: a `String` one, a five-argument one that spills to the image,
an `Option[Int]` one and a `Unit` one. One `async func` export calls each in
turn and checks every result. `llvm_wasm32_component_self_test.l` 25/25,
`llvm_wasm32_module_self_test.l` 32/32, `llvm_wasm32_self_test.l` 11/11.
Running a promise import under wasmtime needs a host that provides it, which
the wasmtime CLI cannot, so that path is covered by jco only.
