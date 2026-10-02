# wasm32 `module` shape: reactor module, generated JS glue and TypeScript declarations (docs/35 W3, slice 1)

First slice of phase W3 (D-progress-1029). `lyric build --target native
--triple wasm32-wasi --shape module` produces a core `.wasm` that runs in a
browser or any JS host, plus the ES-module glue and `.d.ts` that make its
`pub func`s callable.

## What ships

- `--shape module` (and `[build] shape = "module"`) on the `docs/63` axis;
  `--shape component` is recognised and fails with `F0044` until W4. Both are
  `F0043` on the managed targets. The default output is `<stem>.wasm`.
- Link recipe: wasi-sdk clang as for W2, plus `-mexec-model=reactor`, a 1 MiB
  stack, and `--export` for the glue helpers and every exported `pub func`
  (`N0011` for a non-wasm32 triple, `N0012` for an unknown shape name, `N0013`
  when the glue cannot be written).
- `lyric-rt/src/lyric_wasm.c`: the string/alloc helpers the glue calls, versioned
  by `lyric_wasm_abi_version`.
- `lyric-compiler/lyric/wasm_glue.l` (`Lyric.WasmGlue`): export collection with
  `W0040` notes for functions that cannot cross, the JS and `.d.ts` renderers.
  The static runtime is `lyric-compiler/lyric/wasm/glue_runtime.js`, embedded as
  `wasm_glue_runtime.l` by `scripts/gen_wasm_glue.py` (a `--check` mode keeps
  the two in step).
- Glue behaviour: a WASI shim for stdio (line-buffered `console.log` /
  `console.error` by default, or `stdout`/`stderr` hooks), clock, random, args
  and env; `run(args)` for a program with `main`; typed wrappers that marshal
  `Int`, `Long` (as `bigint`), `Bool`, `Byte`, `Float`, `Double`, `String` and
  `Unit`, releasing every argument and result `String`.

## Tests

`llvm_wasm32_module_self_test.l` builds modules through the real bridge and
drives them from node through the generated glue: every scalar kind and
`String` (including non-ASCII), `run()` with argv and an exit code, no
linear-memory growth over 20,000 string calls, a panic surfacing as a trap with
its message on the `stderr` hook, unsupported `pub func`s left out of the glue
and `.d.ts`, a `main`-less library, and `N0011`.

## Not in this slice

Host timers for `Std.Time.sleepMillis`/`async`, a `fetch`-backed `Std.Http`,
the `docs/65` U7 client-host hook and the `[wasm]` manifest table follow in
later W3 slices; records, lists and options at the boundary are W4.
