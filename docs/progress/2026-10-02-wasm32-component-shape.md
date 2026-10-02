# wasm32 `component` shape, slice 1 (docs/35 W4)

`lyric build --target native --triple wasm32-wasi --shape component` now
produces a WebAssembly component for programs whose `pub func`s use `Int`,
`Long`, `Bool`, `Byte`, `Float`, `Double`, `String` and `Unit` (D-progress-1032).

## What ships

- `Lyric.ComponentGlue`: WIT rendering and the canonical-ABI C wrappers.
- Native bridge: reactor link with the wrappers, `wasm-tools` embed/new with the
  preview1 reactor adapter, `<name>.wit` next to the component; `N0016`/`N0017`.
- CLI: the `F0044` stub for the component shape is gone; default output `.wasm`.
- `llvm_wasm32_component_self_test.l` and the CI wiring (pinned tools).

## Remaining W4

Richer type lifting, WIT imports, `--wit-out`/`--js-bindings`, publish bundle,
async exports, `[wasm]` table.
