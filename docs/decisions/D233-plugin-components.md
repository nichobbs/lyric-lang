# D233 - Plugin components (docs/69 §9.3, P5): `--shape component` plugins, the WIT mapping, and in-process wasmtime hosting

**Status:** shipped. Extends D207, D228 and D231; implements docs/69 §9.3 and
resolves Q-PLG-001. Builds on the component shape (docs/35, D-progress-1028
to 1038) and C callbacks through `@library` bindings (D229).

## Context

Wasm mode (D207 Decision 6) runs a plugin as a WASI command under
`wasmtime run`: a process per plugin, JSON over stdin and stdout, and a call
timeout that only abandons the call (a plugin that ignores the cancellation
keeps its CPU, #8465). docs/69 sketched a component route: the plugin as a
WIT-typed component whose point methods are exports and whose capability
calls are imports, instantiated inside the host by an embedded wasmtime.
That needed a WIT mapping of the plugin boundary, generated component code,
a way to carry D207's JSON across typed component values, and a wasmtime
embedding reachable from dotnet, JVM and native hosts.

## Decision

1. **A component is a build shape, not a second plugin model.** A `@plugin`
   package built with `--target native --triple wasm32-wasi --shape
   component` goes through `Lyric.PluginExpand`'s component path
   (`expandFileForComponent`, run by the native bridge before the component
   shims). Plugin source is unchanged between modes. The plugin package
   exports `pluginDescribe`, `pluginAttach(grants)`, `pluginMethods`,
   `pluginTypeHints` and one `pub func <ptLower><M>` per implemented point
   method (WIT `note-tool-summarize`); there is no `main` and no JSON-RPC
   server. The API package's host-side items are not generated and its other
   generated functions are `internal`, because the component shape exports
   every `pub func`.

2. **Capabilities are imports, with per-capability error variants.** Each
   method `n` of a requested capability `<A>.<C>` is a `@wasmImport("<A>.<C>")`
   extern of the WIT interface `witName("<A>.<C>")` (the full capability id,
   so `Fixture.Api.Secrets` is `fixture-api-secrets`), returning
   `Result[T, <C>CallErrorWire]`. The variant is generated per capability
   (`<C><Method>CallErrorWire` for a method whose error type differs from the
   first method's) with the cases `App(error: E)` (bare `App` when `E` is
   `Unit`), `Denied(reason)`, `NotGranted(capability)`, `Revoked(capability)`,
   `Unsupported(method)`, `ContractViolated(detail)`, `Timeout(timeoutMs)`,
   `Crashed(detail)`, `Protocol(detail)` and `Stale`: `BoundaryError`'s field
   names. The host maps by case name only, so the type names need nothing on
   its side. `<C>Client` holds an `__<C>Calls` interface implemented over the
   imports, so `CallError[E]` reaches plugin code unchanged.
   - A single generic `CallErrorWire[E]` was rejected: a WIT variant cannot
     be generic, and one variant per error type in one interface would need
     mangled names.

3. **Names and types the WIT cannot carry are diagnostics.** A host maps WIT
   names back with camel and Pascal case, so every crossing name must survive
   `camel(witName(n)) == n`; one that does not (`customer_id`, `getURL`), or
   two names that become one WIT name, is **K0013**. A type a component
   cannot carry (`UInt`, `ULong`, `Char`, `slice[T]`, `JsonValue`, a
   multi-field union case, a field-less record, a recursive type, nesting
   deeper than 8, a `Unit` parameter, field or tuple element, a type outside
   the build, a protocol point) is **K0014**. Both are reported only when
   generating component code, so the same source still builds for process and
   wasm mode. `@plugin_handle` crosses as `u64` and `Map[String, T]` as
   `list<tuple<string, t>>`.

4. **The type hints export.** A WIT variant case carries only its payload
   type, not the Lyric field name D207's JSON uses, and a `Map[String, T]` is
   indistinguishable from a `List[(String, T)]`. The generated
   `pluginTypeHints()` (WIT `plugin-type-hints`) returns
   `{"exports": {"<func>": {"params": [H...], "result": H}}, "imports":
   {"<interface>#<func>": ...}}` with `H` one of `null`, `variant` (case to
   field and inner hint), `record`, `list`, `map`, `option`, `result` or
   `tuple`. Imports are keyed by the bare interface name, which the plugin
   build knows without the WIT package's name or version; the host also
   accepts the full instance name. On input (JSON to value) the host needs no
   hints. A component without the export is hosted with no hints.

5. **Map order is not part of the boundary.** A map crosses as pairs in the
   order the sender's map iterates, which is not insertion order on every
   target. As with member order in a D207 JSON object, readers look keys up
   by name.

6. **The payload and its selection.** `{"mode": "component", "component":
   "<file>.wasm"}` (`ComponentPayload`), confined like a wasm module, checked
   by `lyric plugin check`, refused by `pluginLaunchCommand`.
   `selectPluginPayload` takes a fifth parameter `inProcessWasm`; with it a
   component goes immediately before a wasm payload in both places a wasm
   payload can be chosen (first when `preferWasm`, last otherwise), without it
   never. `registerPlugin` passes "not a protocol plugin, has a component
   payload, and `componentRuntime` is available". A trusted payload the
   policy trusts (D231) still wins. `lyric plugin pack --targets component`
   builds `component/<name>.wasm` with its `.wit` and reads the manifest by
   calling `plugin-describe` under `wasmtime run --invoke`.
   - "Component first regardless of `preferWasm`" was rejected:
     `preferWasm = false` means the host prefers native and managed
     processes, and a component is a wasm payload.

7. **The runtime is injected through `PluginHostConfig.componentRuntime`.**
   `Std.Plugin` declares `ComponentRuntime`, `ComponentImports` and
   `ComponentStartFailure`; the wasmtime-backed implementation is
   `Std.PluginWasm.inProcessWasmRuntime()` (with `hasInProcessWasm()` and
   `inProcessWasmUnavailableReason()`), over the kernels `Std.PluginWasmBind`
   and `Std.PluginWasmLoad`. `Std.Plugin` cannot import it: the compiler hosts
   generator plugins with `Std.Plugin`, so stage 1 builds it with the v0.7.5
   seed, which cannot compile D229 callbacks or `Std.Ffi`.

8. **The shim loads libwasmtime at run time.** `lyric-rt/src/lyric_wasmhost.c`
   over the wasmtime 49 C API, compiled against headers vendored in
   `lyric-rt/third_party/wasmtime`, `dlopen`s libwasmtime from
   `$LYRIC_WASMTIME_LIB`, next to itself, or the loader path, as the TLS seam
   loads OpenSSL. A native host links the shim from `lyric_rt.a` and needs no
   wasmtime to link; dotnet and JVM hosts load `liblyric_wasmhost`
   (`make -C lyric-rt wasmhost`) through `@library("lyric_wasmhost")`,
   `$LYRIC_WASMHOST_LIB` first. `scripts/ci/fetch-wasmtime-capi.sh` fetches
   the pinned C API with its SHA-256. Every host detects availability the same
   way; without it component payloads are skipped and `wasmtime run` payloads
   still work.

9. **Isolation.** One engine per process with signal-based traps off
   (explicit bounds checks, so wasmtime never handles `SIGSEGV` inside the CLR
   or the JVM) and epoch interruption on: a ticker thread bumps the epoch every
   5 ms while a call runs and each store's deadline callback checks the clock.
   One store per instance, its memories capped at `wasmMaxMemoryBytes` by the
   store limiter, with an empty WASI p2 context (no directories, environment,
   arguments or network; stderr inherited). Imports that are not `wasi:*` are
   served by the host.

10. **Failures.** A trap is `Crashed` and the next call re-instantiates with
    process mode's backoff and `maxRestarts`. A call past `callTimeoutMs`
    returns `Timeout` and drops the instance; the next call re-instantiates
    without counting a crash, so a component plugin's CPU is bounded by the
    call timeout (#8465 remains for process and wasm mode). A component that
    cannot be compiled or linked, a refused `plugin-attach`, or a missing
    `plugin-attach`/`plugin-methods` is a final `Protocol` error.
    `stopPlugin` drops the instance and releases the compiled component.

11. **Windows.** The shim has an unsupported twin on wasm32 and Windows, so
    `hasInProcessWasm()` is false there; Windows hosts are #8542.

## Tests

`plugin_expand_self_test.l` (generated items, K0013/K0014, the hints);
`llvm_wasm32_plugin_component_self_test.l` (a generated component under jco
and node); `scripts/ci/plugin-component-pack-e2e.sh` (pack and check);
`make -C lyric-rt test-wasmhost` (a WAT component, plain, ASan and UBSan);
`scripts/ci/plugin-component-e2e.sh` packs the `@plugin` fixture
`greeter_component.l` and runs `plugin_component_e2e_tests.l` on dotnet, JVM
and native hosts with and without libwasmtime: point calls with union and Map
results and a Map argument, capability imports granted, narrowed, with a
`Unit` error, with union and Map arguments, an optional capability not
granted and a revoked one, an unlisted method, traps and the restart limit,
a CPU loop stopped at the timeout, the memory cap and unloading;
`plugin_manifest_tests.l` covers the payload and its selection on dotnet,
the JVM and native.
