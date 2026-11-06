# D415 - Checked arithmetic default for `@proof_required`, `lyric check` generator sandbox policy, and `ref record` reference semantics (#8854, #8855)

**Status:** shipped (#8854)

## Context

Three user-visible semantics and CLI policies were identified during the comprehensive adversarial review of the compiler, verifier, and toolchain:

1. **Unbounded integer arithmetic default in `@proof_required` modules.** Under plain `@proof_required`, the verifier previously modelled `Int`, `Long`, `SByte`, and `Short` arithmetic in function bodies as mathematical unbounded integers unless `@proof_required(checked_arithmetic)` was explicitly written, and unsigned/narrow integer widths (`Byte`, `SByte`, `Short`, `UShort`) lacked complete width range and overflow side-conditions. As a result, a function whose postcondition held only over mathematical integers could be discharged by `lyric prove` even though a `--release` build wraps silently on overflow and a `--debug` build panics.
2. **Untrusted build-time code execution during `lyric check` and `lyric restore`.** `lyric check` is invoked automatically by IDE on-save hooks and CI pre-checks, yet it ran arbitrary `[[generators]]` host processes declared in `lyric.toml`. Similarly, `lyric restore` probed `[npm]` packages with `node -e "import(...)"`, allowing transitive lifecycle scripts or module top-level side effects to access child processes, the network, or the filesystem.
3. **`ref record` identity without `var` fields.** While `ref record` (D222) was introduced as the marker for records with reference identity, a `ref record` with no `var` fields was still treated as a value record by `==`/`!=` (structural field-by-field equality), by the MSIL backend (eligible for CLR `struct` value-type lowering), by the native LLVM backend (eligible for inline by-value struct lowering), and by the mode checker.

## Decision

1. **`@proof_required` enables `checked_arithmetic` by default.**
   - Every `@proof_required` package now enables bounded-width overflow verification conditions (`checked_arithmetic`) by default across all signed and unsigned fixed-width integer types (`8`-bit `Byte`/`SByte`, `16`-bit `Short`/`UShort`, `32`-bit `Int`/`UInt`, `64`-bit `Long`/`ULong`).
   - `@proof_required(checked_arithmetic)` remains accepted as an explicit synonym.
   - `@proof_required(unbounded_arithmetic)` is added as an explicit opt-out for packages that intentionally reason over mathematical unbounded integers.
2. **Generator and restore sandboxing (`lyric check [--allow-generators]`).**
   - `lyric check` runs source generators with `preferWasm = true`, restricts WASM generator filesystem grants to `ProjectRead` on the project root, and skips external process `[[generators]]` by default with a warning (`skipping external process generator '<name>' during 'lyric check'`).
   - Passing `--allow-generators` to `lyric check` explicitly permits external process generators when needed.
   - When process generators are disallowed (`not processGeneratorsAllowed()`), `loadRestoredGenerator` checks that the restored plugin manifest actually carries a runnable WASM payload (`WasmPayload` with `wasmtime` available) before loading, rather than falling back to a trusted/process payload inside `Plugin.load`.
   - `lyric restore` runs `npm install --ignore-scripts` and sandboxes the Node ESM export-discovery probe by monkey-patching `child_process`, `net`, `http`, `https`, `tls`, `dgram`, `dns`, `worker_threads`, `process.dlopen`, `process.binding`, and `fs` write methods (calling `module.syncBuiltinESMExports()` so ESM named imports see the patched bindings).
3. **`ref record` always has reference identity and heap allocation.**
   - Declaring a record `ref record` gives it reference identity (`==` and `!=` compare whether two bindings refer to the same instance unless `@derive(Equals)` is present) and heap allocation on every target (a reference class on `--target dotnet` and `--target jvm`, an ARC heap object on `--target native`), whether or not the record declares any `var` fields.
4. **Manifest and linker argument validation.**
   - `[native]` `extra_libs` entries are validated as bare library names (no leading `-`, `/`, `\`, `:`, `@`, or NUL bytes).
   - `[native]` `linker_args` rejects dangerous linker flags (`--`, `-plugin`, `--plugin`, `-init`, `-fini`, `-rpath`, `--dynamic-linker`, `-dynamic-linker`, `@file` response files, and driver-wrapped equivalents under `-Wl,`, `-Wa,`, `-Wp,`, `-Xlinker`, and `-Xclang`).
   - Dependency `subdir` fields in `lyric.toml` and `lyric.lock` are validated to stay within the target checkout directory (rejecting `..`, leading `/` or `\`, and Windows drive/volume colons `:`).

## Consequences

- Proofs discharged under `@proof_required` now hold in both `--debug` and `--release` profiles by default without requiring authors to remember `(checked_arithmetic)`. Existing tests or packages that intentionally test mathematical unbounded arithmetic can annotate `@proof_required(unbounded_arithmetic)`.
- Running `lyric check` on an untrusted repository no longer executes arbitrary host binaries from `[[generators]]` unless `--allow-generators` is passed.
- `ref record` behaves uniformly across type-checking, mode-checking, MSIL, JVM, and native LLVM codegen regardless of whether its fields are `var`.
