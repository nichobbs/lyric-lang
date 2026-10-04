# NPM dependencies: calling packages from wasm32 builds (docs/35 W5, slice 2)

A restored NPM package can now be called from Lyric (D-progress-1037).

- A shim declares `@wasmImport("npm:<package>") extern func ... = "<export>"`.
- Module shape: the generated glue imports the package (override with
  `options.imports["npm:<package>"]`); the `.d.ts` makes the module optional.
- Component shape: the import is the WIT interface `npm-<package>`, satisfied by
  `jco transpile --map`.
- Build checks: `B0061` (no shim) and `B0062` (a bound export the installed package
  lacks, probed under `node`).
- Tests: module shape under node with a fake package (import, override, missing
  package, `.d.ts`); component shape through jco with a scoped package; the shim
  scan, probe parsing and `B0061`/`B0062` checks, end to end against a real `npm
  install`.
