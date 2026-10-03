# wasm32 component shape, slice 3: WIT imports (docs/35 W4)

`@wasmImport` extern funcs now work with `--shape component` (D-progress-1034).

## What ships

- `Lyric.ComponentGlue` collects the annotated externs of each package, rewrites
  them to generated C functions, and renders one WIT interface per import module
  plus `import` lines in the world.
- The generated C lowers canonical arguments, calls the core import, and lifts
  results (strings through a return area).
- The component self-test builds a program importing two modules (`Unit`, `Int`,
  `String` in and out, `Double`), transpiles it with `jco --map`, and calls it
  from node with the host functions supplied.
- `N0017` is removed: the rewrite covers every project package, so no host import is left unlowered.
