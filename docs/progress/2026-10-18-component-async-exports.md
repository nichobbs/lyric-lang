# Component shape: async exports use the Component Model async ABI (D184 slice A1)

A `pub async func` export of a `--shape component` build is now a WIT
`async func` instead of a blocking function with `W0041` (D-progress-1043).
`W0041` is retired.

- **WIT.** The export line reads `name: async func(...)`. A component with an
  async export also imports `wasi:clocks/monotonic-clock@0.3.0`, whose WIT
  (`types.duration` and `wait-for`) is written into the generated `.wit` as a
  nested package, so `wasm-tools component embed` needs no `deps/` folder.
- **Lift.** Each async export gets a `[async-lift]` core export and its
  `[callback][async-lift]` (the stackless callback ABI; the gated stackful lift
  is not used). Both run one turn of the cooperative scheduler
  (`lyric_sched_poll`). When the call's task is complete the turn passes the
  result to `[task-return]` as flat values (from the return area through the
  same memory-to-flat readers the image imports use, or the area itself past
  16 flat values), runs the export's `cabi_post` shim to free what the result
  allocated, and returns `EXIT`; otherwise it returns `WAIT` on the call's
  waitable set.
- **Timers.** A task asleep in `Std.Time.sleepMillis` parks the call on an
  async-lowered `wait-for` for the earliest deadline (one outstanding timer
  per instance, replaced when an earlier deadline appears, handed to the next
  call's set when a call ends), never a busy `YIELD` or a blocking
  `nanosleep`. Measured under wasmtime 49: `later(41, 300)` returns after
  310 ms, `later(41, 1000)` after 1012 ms.
- **Per-call state.** The async shim takes its call's slot and, when its task
  completes, snapshots the lowered result into that slot
  (`lyric_cabi_async_done`), since the turn that completes it need not be its
  own. Callbacks find their call through `context.get` slot 0. One call is in
  flight per instance until slice A3: a second traps with a message naming the
  limit. A `TASK_CANCELLED` event is acknowledged and the call runs to
  completion.

Also in this change, the review nits from #8377: a comment where
`llvm.coro.end` is declared (it must stay `i1` for LLVM 18) and an
`llvm_ir_self_test.l` case for a call rendered without a result name.

The wasm CI lane installs `@bytecodealliance/preview3-shim` 0.11.0 beside
`preview2-shim` and runs the component suite's node steps on a pinned node
24.22.0 (jco's async output calls `WebAssembly.promising`, absent from node
22).

Verified locally with wasi-sdk 34, wasmtime 49.0.3, wasm-tools 1.262.0 and
jco 1.39.0: `llvm_wasm32_component_self_test.l` 24/24 (the async test now
checks the WIT, runs `later` and a `String`-returning `tag` under wasmtime, and
awaits every export under jco on node 24), `llvm_wasm32_module_self_test.l`
32/32, `llvm_wasm32_self_test.l` 11/11, `llvm_ir_self_test.l` 17/17,
`llvm_heap_self_test.l` 47/47 and `llvm_stdlib_self_test.l` 45/45.

jco 1.39.0 returns a Promise from a sync export of a component that also has
async exports while typing it as a plain value; the test awaits it, which is
correct either way.
