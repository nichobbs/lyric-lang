# wasm32: the `[wasm]` manifest table (docs/35 W4, slice 4)

`lyric.toml` can now set the component's WIT package version, the world name and the
wasm32 shadow-stack size (D-progress-1035).

- `[wasm] version`, `world`, `stack` parsed and validated in `Lyric.Manifest`;
  the component version defaults to the project's `[package]` version instead of a
  hard-coded `0.1.0`.
- The CLI folds them into the shape argument; `Lyric.LlvmBridge` parses it once.
- Tests: manifest parsing and rejection cases; a component build with all three
  options; a package that only imports host functions (the last open W4 review
  suggestion).
