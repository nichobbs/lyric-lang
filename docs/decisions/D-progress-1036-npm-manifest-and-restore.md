# D-progress-1036 — The `[npm]` table and NPM restore

**Status:** shipped (W5 slice 1)

Implements the dependency half of `docs/35` section 9: declaring NPM packages and
restoring them. The extern form that calls them is the next slice.

## Decision

1. **`[npm]` / `[npm.options]`.** Rows are `"name" = "range"` or
   `{ version = "range" }`. A name must be a valid NPM name (`pkg` or `@scope/pkg`,
   lowercase letters, digits and `-._~`, not starting with `.` or `_`, at most 214
   characters); a range must be non-empty; `registry` must be an `http(s)://` URL.
   Wrongly typed values are errors, not silently ignored (the same check now applies
   to `[wasm]` `version`, `world` and `stack`, which previously treated a quoted
   `stack` as undeclared).
2. **Package identifier mapping.** As in docs/35 section 9.3, plus an `N` prefix for
   a segment that begins with a digit so the identifier stays a valid Lyric name.
3. **Q-JS-004 is a hard error.** Two names that map to the same identifier
   (`foo-bar` and `foo_bar`) fail manifest parsing naming both. A disambiguating suffix
   would make the identifier depend on declaration order, and a shim's package name
   is part of its callers' source.
4. **Restore.** `lyric restore` writes `target/npm/package.json` (private) and runs
   `npm install --prefix target/npm --ignore-scripts --no-audit --no-fund`
   (plus `--registry`). Install scripts never run: restoring a dependency must not
   execute its code. A non-zero exit, a timeout, or a declared package missing from
   `node_modules` is `B0040`. `pnpm`/`yarn` selection is not implemented; `npm` only.
5. **Shims.** docs/35 said restore "generates" shims and also that they are hand
   authored. Resolved as: restore scaffolds a missing `_extern_npm/<name>.l` with the
   `@axiom("from npm <name> <range>")` header and the package declaration, and never
   overwrites an existing file. File names drop `@` and write `/` as `__`. A shim
   that lost its header is `B0043` (the annotation is what puts it in the kernel
   trust tier).
6. **Auto-restore.** `lyric build`'s auto-restore does not notice `[npm]` edits,
   like `[nuget]`/`[maven]`.

## Not in this slice

The `@externTarget("npm", package:, symbol:)` form, its lowering to wasm imports in
the module shape and WIT imports in the component shape, and the build-time `B0041`
and `B0042` checks. `B0041` is only meaningful once a build consumes the shims.
