# Plugins P6: trusted (in-process) mode (D229)

- **Policy and host** (`Std.Plugin`):
  - `GrantDecision.trusted` and `PluginHostConfig.trustedLoader`
    (`Std.Plugin.Trusted.trustedPluginLoader()`) together let a host load a
    plugin into its own process. Without both the plugin runs from its process
    or wasm payload, in the usual order.
  - New payload mode `trusted` (`TrustedManagedPayload`,
    `TrustedNativePayload`, `selectTrustedPayload`, `trustedLibrarySuffix`) and
    load issue `TrustedLoadFailed`.
  - In process, a point call is a direct call of the generated dispatcher, and
    a capability call reaches the host's grants, revocations, guards and
    providers through `HostLink`. No restarts, no call timeout; on dotnet and
    the JVM a panic in a call is `ContractViolated`. `stopPlugin` drops the
    server; nothing is unloaded (Q-PLG-009).
- **Loaders** (`Std.PluginTrustedHost`, three kernel twins):
  - dotnet: a non-collectible `AssemblyLoadContext`, `Lyric.Stdlib` shared with
    the host, the assembly's entry point naming the class whose
    `lyricPluginEntryV1` runs.
  - JVM: a `URLClassLoader` with the host's stdlib loader as parent, the jar's
    `Main-Class` naming the class.
  - native: `dlopen` of a `--shape plugin` library, an ABI fingerprint check,
    and `lyric_plugin_entry_v1`.
- **Compiler**:
  - `Lyric.PluginExpand` generates `lyricPluginServerV1` and
    `lyricPluginEntryV1` for a `@plugin` record.
  - `lyric build --target native --shape plugin` builds a shared library with
    no runtime of its own (N0027, N0028); a native program that reaches the
    loader links its runtime whole and exports it.
  - `lyric plugin pack --trusted` adds trusted payloads; `lyric plugin check`
    validates them.
  - MSIL: an extern alias of `System.Object` is `object` in signatures and
    overload scoring. JVM: a slice of an extern class binds a JDK parameter of
    that array type. JVM project builds take a `@plugin` package as the entry
    package.
- **lyric-rt**: `lyric_plugin.c` (`lyric_plugin_dl_open`, `_dl_sym`,
  `_dl_error`, `_call_text`, `_call_entry`, `_text`), with stubs on Windows and
  wasm32.
- **Tests**:
  - `scripts/ci/plugin-trusted-e2e.sh` with `plugin_trusted_e2e_tests.l` and
    the `plugin_fixtures/trusted_notes` project: 12 of 12 on dotnet, JVM and
    native hosts.
  - `plugin_manifest_tests.l`: 35 of 35 on dotnet, JVM and native, 8 of them
    new for trusted mode (an in-memory loader and server).
  - `plugin_manifest_self_test.l` (the `check` forms, 14 of 14) and
    `cli_build_self_test.l` (`--shape plugin`, 105 of 105); `lyric_rt_test`
    covers the loader's failure paths.
  - Timing, 500 calls over three runs: dotnet 8 µs in process against
    241-462 µs over a pipe, JVM 42 µs against 1393-1444 µs, native 6 µs
    against 117-124 µs.
- **Docs**: docs/69 §10 (shipped design) and §16, docs/01 §15.7 and the native
  shape paragraph, book chapter 33 ("Trusted plugins in the host's process"),
  chapter 1 and appendix B.
