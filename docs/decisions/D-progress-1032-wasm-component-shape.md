# D-progress-1032 — wasm32 `component` shape: WIT, canonical ABI wrappers, wasm-tools pipeline

**Status:** shipped (W4 slice 1)

Extends D-progress-1029 (module shape); implements `docs/35` §5-§7 for scalar and
`String` exports.

## Decision

1. **Same codegen, different boundary.** The component shape links the program
   as the module shape's reactor (`-mexec-model=reactor`, wasi-libc, 1 MiB
   stack) with a generated C file (`<stem>.cabi.c`) compiled in, then
   componentizes the result. No new backend.
2. **WIT from the exports.** `Lyric.ComponentGlue` renders one interface per
   exporting Lyric package and one world (`<package>-world`), package
   `lyric:<package>@<version>` (version `0.1.0` until the `[wasm]` table lands).
   Names are kebab-cased, WIT keywords are `%`-escaped. Exports the ABI cannot
   lift (async, more than 16 flat parameters) are `W0040`, never dropped silently.
3. **Canonical ABI wrappers.** The generated C defines `cabi_realloc`, a lifted
   core export `lyric:<pkg>/<iface>@<ver>#<func>` per function, and
   `cabi_post_*` for string results. Arguments are borrowed from the caller and
   released after the call (ARC rules 5/6); string results are copied into a
   static return area and freed by `cabi_post`.
4. **Toolchain.** `wasm-tools component embed` + `component new --adapt
   wasi_snapshot_preview1=$LYRIC_WASI_ADAPTER`. The tools are located via
   `$WASM_TOOLS` or PATH; absence or failure is `N0016`. `@wasmImport` with the
   component shape is `N0017` until WIT imports are generated.
5. **CI.** `scripts/ci/wasm32-wasi-rt-tests.sh` fetches pinned wasm-tools 1.220.0,
   the wasmtime 26.0.1 reactor adapter and jco 1.8.1 (preview2-shim 0.17.1),
   and `llvm_wasm32_component_self_test.l` validates the component, checks the
   printed WIT, transpiles it with jco and calls it from node.

## Not in this slice

option/result/list/record/variant lifting, WIT imports, `--wit-out` /
`--js-bindings`, the publish bundle, async exports (Q-JS-006) and the `[wasm]`
table are the remaining W4 slices.
