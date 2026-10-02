# D-progress-1029 — The wasm32 `module` shape links wasi-libc and satisfies its WASI imports from generated glue

**Status:** shipped (W3 slice 1; timers, `fetch` and the `docs/65` U7 hook follow)

Refines D-progress-1028 and `docs/35` §4, which listed `wasm32-unknown-unknown`
as the browser triple.

## Context

`lyric_rt` and the stdlib kernels are written against a libc: `malloc`,
`snprintf`, `memcpy`, `getentropy`, the clock and `write(2)`. A bare
`wasm32-unknown-unknown` build has no libc, so using it would mean a second
runtime (or a hand-written freestanding libc) just for the browser.

## Decision

1. **One toolchain, two shapes.** The `module` shape builds with the same
   wasi-sdk sysroot as `wasm32-wasi`. Its linked module imports a handful of
   `wasi_snapshot_preview1` functions (six for a console program: `fd_write`,
   `fd_close`, `fd_seek`, `fd_prestat_get`, `fd_prestat_dir_name`, `proc_exit`)
   and the generated JS glue implements them. `--triple wasm32-wasi --shape
   module` is the spelling; the browser needs no separate triple.
2. **Reactor, not command.** The module is linked `-mexec-model=reactor`: no
   `_start`, an `_initialize` the glue calls once, and the exports below. A
   package's `main` is reachable as `run(args)` rather than being the entry.
3. **Exports.** Every `pub func` of the program's own packages whose
   parameters and result are `Int`, `Long`, `Bool`, `Byte`, `Float`, `Double`,
   `String` or `Unit` (not generic, `async`, overloaded or `out`/`inout`) is
   exported by its `Pkg.name` symbol; the glue wraps it under its bare name.
   Every other `pub func` is reported as `W0040` and left out. Records, lists
   and options cross the boundary in W4's canonical-ABI work, not here.
4. **Value ABI.** `Int`/`Byte`/`Bool` are `i32`, `Long` is `i64` (a `bigint` in
   JS), `Float` is `f32`. A `String` argument is created in linear memory by the
   glue (`lyric_wasm_string_new`), passed borrowed and released after the
   call; a returned `String` is owned by the caller and released after the
   glue copies it out (native/plan/04-arc-design.md rules 5 and 6). The
   helpers live in `lyric-rt/src/lyric_wasm.c` behind an ABI version the glue
   checks at instantiation.
5. **Artifacts.** `lyric build --target native --triple wasm32-wasi --shape
   module` writes `<name>.wasm`, `<name>.js` (an ES module: the export table
   plus the static runtime from `lyric-compiler/lyric/wasm/glue_runtime.js`)
   and `<name>.d.ts`. The glue is always written; `--js-bindings` is reserved
   for the component shape's `jco` step.
6. **Shape axis.** `module` and `component` are new `docs/63` shape values,
   valid only with `--target native` (`F0043` otherwise); `component` fails
   with `F0044` until W4. A wasm32 triple with no `--shape` still produces the
   plain WASI command module of W2.

## Consequences

- No second runtime and no freestanding libc: a fix to `lyric_rt` reaches the
  browser build for free.
- The glue's WASI surface is deliberately minimal (stdio, clock, random, args,
  env); every other WASI call returns `ENOSYS`, matching the capability matrix
  of `docs/35` §5.3 (no filesystem, process or sockets in the browser).
- A wasm trap (panic, abort) leaves the instance's state undefined, since the
  runtime has no unwinding; the glue rethrows the `WebAssembly.RuntimeError`
  and the panic text has already reached the `stderr` hook.
