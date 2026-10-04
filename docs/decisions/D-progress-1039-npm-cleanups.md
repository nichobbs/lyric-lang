# D-progress-1039 — NPM restore cleanups

**Status:** shipped (W5 follow-up, tracked in #8118)

## Decision

1. **Package manager.** `[npm.options] manager` is `npm` (default), `pnpm` or `yarn`
   (classic). Each is run with install hooks disabled, against the generated
   `target/npm/package.json`: `npm install --prefix`, `pnpm install --dir
   --no-frozen-lockfile` (pnpm demands a lockfile under `CI=true` otherwise),
   `yarn install --cwd --non-interactive`. The packages land where the probe and the
   glue look for them in all three layouts (pnpm links `node_modules/<name>`). Yarn
   Berry is not supported: it dropped `--cwd`. Anything but the three names is a
   manifest error.
2. **`B0064`.** A project package whose `@wasmImport("npm:<package>")` names a package
   `[npm]` does not declare fails the wasm32 build. A host-supplied module that is not
   an NPM package takes a plain module name. This replaces `checkNpmShims` silently
   skipping such imports.
3. **Auto-restore.** A wasm32 project build runs the NPM restore itself when a declared
   package is missing from `target/npm/node_modules/` or the generated `package.json`
   no longer matches the `[npm]` table; `--no-restore` opts out. Other targets never
   install NPM packages. The restore also scaffolds a missing shim, so `B0061` fires
   only under `--no-restore`.
4. **One annotation reader.** `findAnnotation` and `annotationStringArg`
   (`parser_ast.l`) replace three hand-written copies of the `@wasmImport("...")`
   argument pattern in `llvm_codegen.l`, `component_glue.l` and `cli_restore.l`.

## Not changed

Transitive NPM dependencies stay installed but unshimmed (docs/35 section 14).
