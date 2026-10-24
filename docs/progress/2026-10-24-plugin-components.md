# Plugins P5: WIT-typed components hosted in-process by wasmtime (D232)

- **Compiler** (`Lyric.PluginExpand`, `Lyric.ComponentGlue`, the native
  bridge):
  - `--shape component` builds of a `@plugin` package export
    `plugin-describe`, `plugin-attach`, `plugin-methods`, `plugin-type-hints`
    and one function per implemented point method; capabilities become
    imports of `witName("<A>.<C>")` returning per-capability
    `<C>CallErrorWire` variants (`<C><Method>CallErrorWire` for another error
    type, bare `app` for a `Unit` error).
  - `pluginTypeHints` names the union case fields and `Map` positions the WIT
    does not carry; imports are keyed by their bare interface name.
  - New diagnostics `K0013` (a name that does not survive the WIT round trip)
    and `K0014` (a type a component cannot carry), component builds only.
  - `lyric plugin pack --targets component` and `lyric plugin check` for the
    new `{"mode": "component"}` payload.
- **Stdlib**:
  - `Std.Plugin`: `ComponentPayload`, `selectPluginPayload(..., inProcessWasm)`
    (a component just before a wasm payload, in both positions),
    `ComponentRuntime`/`ComponentImports`/`ComponentStartFailure`,
    `PluginHostConfig.componentRuntime`, `pluginWitName`, `pluginCamelName`,
    and component mode in `registerPlugin`/`callPlugin`/`stopPlugin`
    alongside trusted mode (D231).
  - `Std.PluginWasm`: `inProcessWasmRuntime()`, `hasInProcessWasm()`,
    `inProcessWasmUnavailableReason()`, over the kernels `Std.PluginWasmBind`
    (`@library("lyric_wasmhost")` on dotnet and the JVM, `extern func` on
    native) and `Std.PluginWasmLoad` (all three kernel trees).
- **lyric-rt**: `lyric_wasmhost.c` over the wasmtime 49 C API (vendored
  headers, libwasmtime loaded with `dlopen`), engine with epoch interruption
  and signal-based traps off, a store per instance with a memory limiter and
  an empty WASI p2 context, generic JSON/component value conversion with the
  type hints; `liblyric_wasmhost` for dotnet and JVM hosts; an unsupported
  twin on wasm32 and Windows (#8542).
- **Tests and CI**: `plugin_expand_self_test.l`,
  `llvm_wasm32_plugin_component_self_test.l` (jco),
  `scripts/ci/plugin-component-pack-e2e.sh`, `make -C lyric-rt
  test-wasmhost`, and `scripts/ci/plugin-component-e2e.sh`, which packs the
  `@plugin` fixture `greeter_component.l` and runs
  `plugin_component_e2e_tests.l` on dotnet, JVM and native hosts with and
  without libwasmtime. `scripts/ci/fetch-wasm-toolchain.sh` also fetches the
  pinned wasmtime CLI for pack.
- **Docs**: docs/69 §9.3 and §16 (P5 done), docs/01 §15.7-15.8 and §15.10,
  book chapter 33, appendix B, the chapter 1 toolchain table, docs/17 for the
  new kernels, the decision entry D232.
