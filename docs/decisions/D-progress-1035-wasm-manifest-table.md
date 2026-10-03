# D-progress-1035 — The `[wasm]` manifest table

**Status:** shipped (W4 slice 4)

Implements the manifest half of `docs/35` section 8 that D-progress-1029-1034 left
hard-coded.

## Decision

1. **Fields.** `[wasm] version` (the WIT package version, `major.minor.patch`),
   `world` (the WIT world name, lowercase letters, digits and `-`, starting with a
   letter) and `stack` (the shadow-stack size in bytes, a multiple of 16 between
   64 KiB and 64 MiB). All optional; each violation is a manifest error naming the
   field.
2. **Defaults.** `version` falls back to the project's `[package]` version (a
   single-file build has none, so `0.1.0`); `world` to `<package>-world`; `stack`
   to the 1 MiB of D-progress-1029. `stack` applies to both wasm32 shapes; the other
   two fields only to the component shape.
3. **Shape stays on `[build]`.** `[build] shape` already selects `module` or
   `component` on the docs/63 axis; `[wasm]` does not duplicate it.
4. **Plumbing.** The values ride the shape argument the CLI already passes to the
   native bridge, as `component;version=1.2.0;world=w;stack=131072`, parsed in one
   place (`parseShapeSpec`). The bridge entry points keep their signatures, which the
   self-hosted checker would otherwise force into parallel `*WithOptions` variants
   (T0042 on cross-package default arguments).
5. **`exports` is not implemented.** docs/35 sketched a `[wasm] exports` allow-list;
   `pub` already decides what is exported, so a second list would only add a way
   for the two to disagree.

## Not in this slice

`--wit-out` and `--js-bindings` (the WIT file is already written next to the
component, and `jco transpile` is one command on it), the publish bundle, tuples,
cross-package types and async exports.
