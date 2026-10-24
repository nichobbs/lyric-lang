# D229 - Trusted (in-process) plugins (docs/69 §10, P6): the call path, trusted payloads, the policy flag, entry points, native libraries and the failure model

**Status:** shipped. Extends D207 and D228; implements docs/69 §10 and
resolves Q-PLG-009. Tracking issue #8483.

## Context

D207 deferred trusted mode: every plugin ran in a process or under wasmtime.
docs/69 §10 sketched loading first-party plugins into the host's process on
dotnet (a collectible `AssemblyLoadContext` and a fixed-name entry type), the
JVM (a child class loader and a `META-INF/services` entry) and native
(`dlopen` against a shared build of `lyric_rt`), with unloading left open. It
did not say how calls cross, what an artifact looks like, how a host opts in,
or what happens when the plugin fails. Lyric also has no downcast (D212), so a
host cannot turn an object it obtained by reflection into a Lyric interface.

## Decision

1. **The call path keeps the protocol and replaces the transport.** A trusted
   point call is a direct call of the plugin's generated `PluginServer.dispatch`
   with the same params object and `{"ok"}`/`{"err"}` result that process mode
   writes to a pipe; the host attaches the server as `plugin/hello` does (the
   granted capabilities less the revoked ones, `NotGranted` refused, the
   reported methods checked against the host's point versions by the same
   `plParseHello`). A capability call from the plugin is `callHost` on a
   connection whose new `link: Option[HostLink]` reaches `plServeCapability`,
   so grant lookup, revocation, the generated guards and the provider are the
   code a process plugin's `cap/...` request runs. One dispatcher remains
   (D207 Decision 6).
   - Alternatives rejected: a typed path (the host calling the plugin's
     implementation of the point interface) needs the API package's types to
     be one type on both sides, which a .NET plugin assembly does not give (it
     carries its own copy) and which on the JVM would break the minor-version
     rule of docs/69 §11; it also needs a second copy of every guard and
     revocation check. JSON-RPC text over function calls keeps the
     serialisation cost and needs a reentrant in-process peer.
   - Measured on the notes fixture (`plugin_trusted_e2e_tests.l`, 500
     `summarize` calls of a record with a byte list and a map, Linux x86-64):
     dotnet 8 µs per call in process against 241-462 µs over a pipe, JVM
     42 µs against 1393-1444 µs, native 6 µs against 117-124 µs (three runs). The remaining cost is
     encoding and decoding the JSON value objects, which is not worth a second
     dispatcher.

2. **Trusted payloads are a new manifest payload mode.**
   `{"mode": "trusted", "runtime": "dotnet"|"jvm", "library": "<file>"}` and
   `{"mode": "trusted", "os": ..., "arch": ..., "library": "<lib>"}`, as
   `Std.Plugin.TrustedManagedPayload` and `TrustedNativePayload`. The library
   suffix is checked (`.dll`, `.jar`, `.so` on linux, `.dylib` on macos, `.dll`
   on windows; `trustedLibrarySuffix`). The managed trusted payload is the
   process payload's own file. `lyric plugin pack --trusted` adds a trusted
   payload for each of its dotnet, jvm and native targets, building the native
   one with `--shape plugin` as `native/lib<name>.so`; `lyric plugin check`
   validates the forms, the suffixes and the files, with one trusted payload
   per runtime or os/arch pair. `selectPluginPayload` never returns a trusted
   payload; `selectTrustedPayload` picks the one for the host's runtime (and,
   on native, os and arch).

3. **Two opt-ins, never automatic.** The host gives `PluginHostConfig` a
   `trustedLoader: Option[TrustedLoader] = None`, which
   `Std.Plugin.Trusted.trustedPluginLoader()` provides, and the grant policy
   answers `GrantDecision(..., trusted = true)` (a new field, default
   `false`). The loader is its own package so that a host that never loads
   plugins in process does not link the loading kernel (a Native AOT host keeps
   no `AssemblyLoadContext` reference, a native host keeps its runtime
   unexported). At registration the host computes the process or wasm payload
   with the existing order and, when the loader can load in this process
   (`unavailableReason()` is empty) and the plugin is not a protocol plugin, the
   trusted payload; with neither it reports `NoUsablePayload` before asking the
   policy, as before. After the policy: a trusted decision with a trusted
   payload opens the library (its failure is the new load issue
   `TrustedLoadFailed`, never a silent fallback); anything else uses the
   process or wasm payload; a plugin with only a trusted payload that the
   policy does not trust is `NoUsablePayload`. `trusted` is a permission: a
   trusted plugin without a usable trusted payload runs out of process.

4. **Entry points: two fixed, versioned functions found by name.**
   `Lyric.PluginExpand` generates `pub func lyricPluginServerV1(): PluginServer`
   (a fresh `<R>Server`) and `pub func lyricPluginEntryV1(): Unit` (hands one to
   `Std.PluginTrustedHost.offerTrustedPluginServer`) for a `@plugin` record.
   - dotnet: the assembly goes into a non-collectible `AssemblyLoadContext` of
     its own. The context does not load `Lyric.Stdlib`, so the runtime falls
     back to the default context and the plugin binds to the host's copy; every
     other assembly beside the plugin is loaded into the plugin's context first.
     The assembly's declared entry point (the generated `main`) names the
     plugin package's `Program` class; the kernel invokes its public static
     `lyricPluginEntryV1` and takes the offered server, holding a lock so two
     loading threads never take each other's.
   - JVM: a `URLClassLoader` over the jar whose parent is the loader of the
     host's `Std.Plugin`. Delegation is parent first, so the host's classes
     (the stdlib and an API package both sides share) win; the plugin's own
     packages come from the jar, and a plugin whose package class resolves from
     the host is refused. The jar's `Main-Class` names the class whose
     `lyricPluginEntryV1` is invoked, under the same lock.
   - native: `dlopen` (`RTLD_NOW | RTLD_LOCAL`) and `dlsym` of
     `lyric_plugin_abi_v1` and `lyric_plugin_entry_v1`; the second returns
     `lyricPluginServerV1()` (`lyric_rt`'s `lyric_plugin_*` helpers).
   - Why the managed plugin hands its server over instead of returning it:
     without a downcast a host cannot convert the `object` a reflective call
     returns, while a plugin whose stdlib is the host's can pass the server as
     the host's type. Why no fixed-name type or `META-INF/services` entry (the
     §10 sketch): the payload's own entry point (PE `EntryPoint`, jar
     `Main-Class`) already names the class holding the fixed-name function, so
     nothing extra is generated and the trusted and process payloads are one
     file.

5. **Native: `--shape plugin` libraries without a runtime of their own.**
   `lyric build --target native --shape plugin` links the plugin package with
   `-fPIC -shared` (macOS: `-dynamiclib -undefined dynamic_lookup`), exports
   only the two entry symbols (a version script; an exported-symbol list on
   macOS) and links no `lyric_rt`: its runtime references bind to the host
   executable at `dlopen`. A native build that reaches the trusted loader
   (`lyric_plugin_dl_open`) links its runtime archive whole and exports it
   (`-rdynamic --whole-archive`; `-force_load -export_dynamic` on macOS), so the
   process has one heap, one reference-counting discipline and one scheduler.
   This replaces §10's shared build of `lyric_rt`: the host stays a
   self-contained executable with nothing to install beside it, and a plugin
   cannot bring a second runtime because it contains none.
   - Objects cross between the host's and the plugin's code with no copying,
     so both embed a fingerprint (SHA-256 of the Lyric release and of the
     `core.l`, `json_value.l`, `json_rpc.l` and `plugin.l` sources): the plugin
     as `lyric_plugin_abi_v1`, the host as `lyric_plugin_host_abi_v1`, both
     written by the build. A mismatch is refused at open. The fingerprint does
     not distinguish two builds of an unreleased compiler that differ only in
     code generation.
   - `N0027`: a target other than Linux or macOS (a Windows DLL cannot import
     the runtime from the executable that loads it without an import library
     built for that executable; wasm32 has no dynamic loading). `N0028`: a
     package without a `@plugin` record. `F0043`: `--shape plugin` on dotnet or
     the JVM, whose trusted payload is the ordinary assembly or jar.
   - No separate acknowledgement for native. A panic in a native trusted plugin
     ends the host (no unwinding, D-N-003), but on every target a trusted plugin
     can end the host (a crash, a stack overflow, `exit`, native code it calls);
     `trusted` already means accepting that, and a native-only flag would
     suggest the managed form is safe. The loader reports Windows and wasm32
     native hosts as unable to load (`unavailableReason()`), so they run every
     plugin out of process.

6. **Failure model.** No restart and no call timeout (`callTimeoutMs`,
   `startTimeoutMs`, `maxRestarts` and the backoff do not apply). On dotnet and
   the JVM each call into the plugin runs under `runCatchingBug`: a panic inside
   a point call fails it with `ContractViolated`, as a process plugin's
   `-32603` does, and the plugin keeps running. A failure while the plugin is
   set up (no server offered, `attach` panicking or refusing, methods that do
   not match the host's point versions) fails it for good with that error
   (`Crashed`, `NotGranted` or `Protocol`), since a restart would repeat it.
   Errors that are not panics map as in process mode: the plugin's own errors
   in `{"err"}`, a dispatcher's JSON-RPC error through `boundaryErrorFromRpc`.
   A protocol plugin is never loaded in process (D228: its stdio carries its
   protocol).

7. **Q-PLG-009: nothing is unloaded.** `stopPlugin` drops the server and the
   next call attaches a fresh one from the same library, so the plugin's record
   state restarts while its statics persist. The .NET context is not
   collectible, the class loader is never closed and the library is never
   `dlclose`d: collectible contexts and released loaders leak through statics,
   thread locals and objects the host still holds, and a native library's code
   is the destructor of every object it allocated. A plugin that must be
   replaced while the host runs belongs in process or wasm mode.

8. **FFI fixes the kernels needed.**
   - MSIL: an `extern type` aliasing `System.Object` is encoded as
     `ELEMENT_TYPE_OBJECT` in signatures and scores as `object` in auto-FFI
     overload resolution; a CLASS TypeRef to `System.Object` named a different
     signature, so no member taking `object` (`MethodBase.Invoke`,
     `Monitor.Enter`) could bind.
   - JVM: a Lyric `slice` of one extern class scores as that class's array and
     is copied into one (`emitNarrowObjectArray`) for a JDK parameter of that
     type (`new URLClassLoader(URL[], ClassLoader)`); slices erase to
     `Object[]`.
   - JVM project builds count a package with a `@plugin` record as the one
     declaring `main` (which `Lyric.PluginExpand` generates after the scan), so
     the jar's `Main-Class` is the plugin package.

## Consequences

- `Std.Plugin`: `TrustedManagedPayload`, `TrustedNativePayload`,
  `trustedLibrarySuffix`, `selectTrustedPayload`, `GrantDecision.trusted`,
  `TrustedLoader`, `TrustedLibrary`, `HostLink`, `PluginHostConfig.trustedLoader`,
  `PluginConnection.link`, `PluginIssueKind.TrustedLoadFailed`. New packages
  `Std.Plugin.Trusted` and the kernel `Std.PluginTrustedHost` (three twins),
  both `seed: current` in the full stdlib manifest.
- `scripts/ci/plugin-trusted-e2e.sh` runs a dotnet, a JVM and a native host
  with a plugin of the same runtime through point calls, capability calls
  (granted, narrowed by the grant, denied by the guard, revoked), an optional
  capability, contributions, stopping and restarting, the fallback to process
  mode under an untrusting policy, and the timing comparison;
  `plugin_manifest_tests.l` covers the payload forms and the selection and
  failure rules with an in-memory loader on all three targets.
- Trusted plugins written in C# or Java are not offered: the generated SDKs
  implement process mode.
