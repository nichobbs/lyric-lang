# D-progress-1037 — NPM shims are `@wasmImport` externs

**Status:** shipped (W5 slice 2)

Completes the consumption half of `docs/35` section 9: calling a restored NPM package
from a wasm32 build.

## Decision

1. **No new extern form.** docs/35 sketched
   `@externTarget("npm", package:, symbol:)`. `@externTarget` is the kernel-only
   .NET extern (`docs/14` Decision F), and `@wasmImport` already types, validates and
   lowers a host function in both wasm shapes (D-progress-1031, D-progress-1034). A
   shim binds a package export as `@wasmImport("npm:<package>") extern func f(...) = "<export>"`;
   `"default"` binds the default export.
2. **Module shape.** The `npm:` prefix marks the module as a package. The glue
   gains a table of literal `import("<package>")` thunks (the package name is a
   literal so bundlers follow it) and awaits them in `instantiate` unless the caller
   passes `options.imports["npm:<package>"]`, which wins. A package that cannot be
   loaded fails `instantiate` naming the import and pointing at `lyric restore`. The
   `.d.ts` types the module as optional, and `instantiate`'s options argument
   becomes optional when every host import is an `npm:` module.
3. **Component shape.** `npm:<package>` becomes the WIT interface
   `npm-<package>`: `@` dropped, each run of other characters a single `-`
   (`npm:@aws-sdk/client-s3` is `npm-aws-sdk-client-s3`). The interface id is
   `lyric:<package>/npm-<name>@<version>`; `jco transpile --map` points it at the
   package. `npm:` with no name is N0018. Two packages whose names differ only in
   separators share an interface; this is accepted because `[npm]` rejects names that
   collide as Lyric identifiers and a package named like another with different
   punctuation is not a case worth a second naming scheme.
4. **`B0061`.** A wasm32 project build refuses a manifest with an `[npm]` package
   that has no `_extern_npm/` shim.
5. **`B0062`.** For each shim import of a declared package the build asks `node`
   (a probe script written beside `target/npm/node_modules`) for the package's
   export names and rejects a bound name it lacks, listing the real exports. `node`
   is the authority because exports are a runtime property (conditional `exports`
   maps, CJS interop); parsing `package.json` would guess. The check runs only for
   `wasm32` triples.

## Not in this slice

`Bool`, `Byte`, records and `Async` results across an NPM import (the host-import ABI
types of D-progress-1031 and 1034 apply), and generating the `--map` arguments.
