# NPM restore cleanups (docs/35 W5 follow-up)

- `[npm.options] manager = "npm" | "pnpm" | "yarn"` (D-progress-1039).
- `B0064` for an `npm:` import of a package `[npm]` does not declare.
- A wasm32 project build restores `[npm]` itself when it is stale or not installed.
- `findAnnotation` / `annotationStringArg` replace three copies of the `@wasmImport`
  argument pattern.
- Tests: manager argument lists, real pnpm and yarn restores (CI installs both, pinned),
  `npmRestoreNeeded`, `npmUndeclaredImports`, manager validation in the manifest.
