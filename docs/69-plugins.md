# 69. Plugins: typed plugin points, parameterised capabilities, and isolated hosting

_Status: **Accepted as the direction in D204** (which also moved the JSON-RPC
peer into the stdlib, Q-PLG-003) and **specced in D207** (the annotation
surface, generated code, wire protocol, manifests and `Std.Plugin`; see its
implementation notes for where the shipped code refines it). Implemented
through phase P3 of §16: the annotations and `Lyric.PluginExpand`
(`K0000`-`K0012`), `Std.Plugin` process mode on dotnet, JVM and native hosts,
plugins on every target including wasm32-wasi under `wasmtime run`,
`lyric plugin pack`/`check`/`sdk` with C#, Java and TypeScript SDKs, and source
generators (docs/40) as the first plugin point, protocol points (P4, D228),
the `lyric-ui` widget point (the first half of P6, D230, §15.1) and trusted
(in-process) mode (P6's second half, D231, §10); P5 is open. Extends docs/01
§10 (`wire`, `contributes[T]`), docs/35 (the wasm32-wasi command output) and
docs/62 (the JSON-RPC peer, now `Std.JsonRpc`). Open questions are listed in
§17._

## 1. Why this exists

Lyric has no reflection (docs/04), and that rules out the usual .NET and JVM
plugin pattern: scan a directory, load assemblies or classes, find types that
implement an interface, and instantiate them. Applications still need plugins.
The motivating cases are:

- **Source generators.** docs/40 already runs custom generators as
  subprocesses with a hand-written JSON protocol on stdin and stdout, one
  process per annotated type, with no sandbox (Q-SG-005).
- **UI widgets.** `lyric-ui` (docs/65) has a closed set of semantic widgets.
  Third-party widgets need a way in (§15.1).
- **Application plugins.** An editor in the shape of VS Code has extensions,
  menu providers and language servers, each with a different interface and a
  different set of things it may do.

The requirements this design answers:

1. Plugins may be **third party** and are not trusted.
2. Plugins can be chosen at startup or loaded from disk while the host runs.
3. Hosts on every target: `dotnet` (including Native AOT), `jvm` and `native`.
   Some limitations per target are acceptable.
4. Lyric is the main plugin language; C# and Java authors should be able to
   write plugins too, and other languages should not be excluded.
5. Plugin calls are `async`.
6. A wasmtime dependency in the host is acceptable.
7. An application declares its own plugin points, each with its own interface
   and its own capabilities.

Plugins defining plugin points of their own (one plugin extending another) are
deferred (§16).

## 2. The key constraints

**No reflection is needed.** A plugin system needs a known entry point, a
shared interface, and a check that both sides agree on that interface. None of
that inspects a type's members, so none of it weakens opaque types or the
no-reflection rule.

**Untrusted code cannot run in the host's process unconfined.** .NET Core
removed Code Access Security. The JVM's SecurityManager was deprecated by
JEP 411 and disabled in JDK 24 by JEP 486. A shared library loaded with
`dlopen` has every privilege of its host. There is therefore no in-process
sandbox for native code on any of Lyric's targets. A third-party plugin runs
either in a separate process or inside a WebAssembly sandbox. VS Code reached
the same conclusion: extensions run in a separate extension-host process.

**Native AOT cannot load managed code at all.** An AOT host can still run
out-of-process plugins and wasm plugins, which is a further reason not to make
in-process loading the core mechanism.

## 3. Model

| Concept | Declared by | Meaning |
|---|---|---|
| **Plugin point** | The application's API package | An interface the host calls on plugins, with a version, a contributions schema, and the capabilities plugins may ask for |
| **Capability** | The application's API package | An interface the plugin calls on the host, optionally parameterised (a path root, a host list) |
| **Protocol point** | The application's API package | A plugin point whose messages are an existing protocol (LSP, DAP, MCP) rather than a generated one |
| **Plugin** | The plugin package | Implements one or more plugin points and requests capabilities |
| **Host** | The application, through `Std.Plugin` | Finds plugins, decides grants, runs them, enforces grants, calls them |

Responsibilities split three ways:

| Layer | Owns |
|---|---|
| Compiler | The `@plugin_point`, `@capability`, `@protocol_point`, `@plugin_handle` and `@plugin` declarations; the boundary-type rules; generating proxies, servers, codecs and the plugin's manifest (`Lyric.PluginExpand`); SDKs and a JSON Schema for other languages (`lyric plugin sdk`) |
| `Std.Plugin` | Discovery, manifests, the hosting modes, the handshake and version negotiation, enforcing grants, lifecycle |
| The application | Its plugin points and capabilities, and the policy that decides grants (including asking the user) |

Every plugin runs in one of three **hosting modes**:

| Mode | Isolation | Host targets | Plugin authors | v1 |
|---|---|---|---|---|
| **Process** | Separate OS process; a crash or hang cannot take the host down; unloading is killing the process | All, including Native AOT | Any language, through generated SDKs | Yes |
| **Wasm** | A wasm32-wasi command module under `wasmtime run` with no directories, environment or network; the plugin reaches the outside only through capability calls | All hosts that can run `wasmtime` (§9.2) | Lyric (`--target native --triple wasm32-wasi`), any language that builds a WASI command | Yes |
| **Trusted** | None; runs in the host process | Same target as the host; dotnet (not Native AOT), JVM (not a native image), native on Linux and macOS | Lyric | P6 (§10) |

The plugin author writes one declaration. Which mode a plugin runs in is
decided by the artifact the author ships and by the host's policy, never by the
plugin's source.

## 4. Language surface

D207 settled the syntax (Q-PLG-005): every declaration is an existing item
with an annotation, so there are no new keywords. `handle`, `plugin` and
`capability` stay ordinary identifiers.

### 4.1 Capabilities

A capability is an interface the host implements and the plugin calls. It may
take parameters, fixed when the capability is granted, declared as a grant
record.

```lyric
package Editor.Api

pub exposed record WorkspaceReadGrant {
  roots: List[String]
}

@capability(grant = WorkspaceReadGrant)
pub interface WorkspaceRead {
  async func readFile(path: in String): Result[String, IoError]
    requires: Paths.underAny(path, grant.roots)

  async func findFiles(glob: in String): Result[List[String], IoError]
}

@capability
pub interface Notify {
  async func showMessage(level: in Severity, text: in String): Result[Unit, NotifyError]
}
```

Rules:

- The grant record's fields have boundary types (§5). Its value is part of the
  request the plugin makes and of the grant the host returns.
- A capability method's `requires:` clauses may name `grant` (the granted
  record) besides the method's own parameters. They take the place of the
  `guard:` clauses this sketch first proposed. The compiler moves them out of
  the interface into the generated host-side server, which evaluates them
  before dispatching; a false clause fails the call with `Denied` and never
  reaches the implementation. They stay visible in the API package's source,
  so a plugin author and a user approving a grant can read them.

### 4.2 Plugin points

```lyric
package Editor.Api

pub exposed record EditorContributions {
  commands: List[CommandDecl] = []
  keybindings: List[KeybindingDecl] = []
}

@plugin_point(version = "1.2", contributions = EditorContributions, allows(WorkspaceRead, WorkspaceEdit, Notify))
pub interface EditorExtension {
  async func activate(): Result[Unit, PluginError]
  async func runCommand(id: in String, args: in JsonValue): Result[Unit, PluginError]
  async func onSave(doc: in DocumentRef): Result[Unit, PluginError]
}
```

Rules:

- `version` is `major.minor`. §11 says how it changes.
- `allows(...)` lists every capability a plugin of this point may request.
- `contributions` names an `exposed record`. A plugin supplies a value of it,
  recorded in its manifest and readable without starting the plugin (§7).
- Every method returns `Result[T, E]` (`K0004` otherwise); it may be `async`
  or not. Calls cross a process or sandbox boundary and can fail in ways that
  are not the plugin's error, so the host-side proxy widens the error to
  `CallError[E]` (§8).
- A minor version may add methods. The plugin lists the methods it implements
  during the handshake (D207 Decision 3), and a call to one it lacks is
  `Unsupported`; this replaces the `@since` marker sketched earlier.
- `requires:` and `ensures:` on point methods are allowed. §6 says how they
  are checked.

### 4.3 Protocol points

Some plugin kinds already have a protocol with its own specification, schemas
and implementations. Re-expressing LSP as a Lyric plugin point would mean
keeping a copy of the specification and would exclude every existing language
server. A protocol point leaves the messages alone and gives the host only
lifecycle and capability control:

```lyric
pub exposed record LanguageContributions {
  languageIds: List[String]
  fileGlobs: List[String]
}

@protocol_point(protocol = "lsp/3.17", contributions = LanguageContributions, allows(WorkspaceRead))
pub interface LanguageServer {}
```

`Std.Plugin` launches the process in a supervised `ProtocolSession`
(`openProtocolSession`, or the generated `open<P>Session`), restarts it after
it exits with process mode's backoff and restart limit, and stops it;
`protocolProcess` hands the application the running process, and the
session's `generation` changes with each start so the client knows to repeat
its handshake. The application's own protocol client does the rest.
Capabilities on a protocol point are enforced to the extent the host routes
the protocol's own requests through them: the generated `<C>As` record (or
`callCapabilityAs`) calls a capability on the plugin's behalf with its grant,
revocations and guards, so the LSP `workspace/applyEdit` request goes through
`WorkspaceEdit`. A protocol plugin implements that one point, since its
stdin and stdout carry its own protocol. Its `plugin.json` is written by its
author and checked with `lyric plugin check`. `examples/plugins/lsp` is a
complete editor and language server.

### 4.4 Plugins

```lyric
package Acme.GitTools

import Editor.Api

@plugin(id = "acme.git-tools", version = "0.4.1", publisher = "acme", implements(EditorExtension))
pub record GitTools {
  workspace: WorkspaceReadClient
  edit: Option[WorkspaceEditClient]
  notify: NotifyClient
  var commandsRun: Int = 0
}

impl EditorExtension for GitTools {
  async func activate(): Result[Unit, PluginError] = Ok(value = ())
  async func runCommand(id: in String, args: in JsonValue): Result[Unit, PluginError] {
    match self.workspace.readFile("README.md") {
      case Ok(text) -> ...
      case Err(e) -> ...
    }
  }
  async func onSave(doc: in DocumentRef): Result[Unit, PluginError] = Ok(value = ())
}

@plugin_contributions(EditorExtension)
func contributions(): EditorContributions =
  EditorContributions(commands = [CommandDecl(id = "git.blame", title = "Git: Blame")])

@plugin_request(WorkspaceRead)
func workspaceRequest(): WorkspaceReadGrant = WorkspaceReadGrant(roots = ["${workspace}"])
```

- A field whose type is a generated `<C>Client` requests capability `C`; an
  `Option[<C>Client]` field requests it optionally and is `None` when the
  host did not grant it. Every other field needs a default. The host refuses
  to load a plugin whose required capabilities it does not grant
  (`NotGranted`), so a plugin never runs in a state its types do not
  describe.
- A client's methods return `Result[T, CallError[E]]`: the capability's own
  error, or a boundary error such as `Denied` or `Revoked`.
- From the record, the compiler generates the manifest (§7), derived from the
  declaration so it cannot disagree with the code, the request dispatcher, and
  the plugin's `main`.

A plugin that implements several points runs as one process, with one set of
grants. The typed fields are a convenience and an early error, not the
enforcement: every capability call is checked on the host side (§8), because a
non-Lyric plugin has no generated code at all.

### 4.5 Handles

A host often needs to give a plugin a reference to something it owns: a
document, an editor, a tree node. Such a reference is declared as a handle:

```lyric
@plugin_handle
pub type DocumentRef = Long
```

A handle is a token. A plugin can store it, compare it, and pass it to
capability methods and back to the host; it crosses the boundary as a JSON
number. `@plugin_handle` applies only to `pub type H = Long` (K0005), and a
distinct type without it does not cross a boundary at all (K0001). The host
issues handles and must validate every one it receives: a handle it did not
issue to that plugin, or has invalidated (the document closed, the plugin
stopped), must not be honoured. `Std.Plugin` keeps no handle table in v1; that
check is the host application's, in its capability implementations. The
`Stale` boundary error (`-32042`) exists for a hand-written
`CapabilityProvider` to report it.

## 5. Boundary types

Everything that crosses a plugin boundary is copied, so the compiler restricts
what plugin points and capabilities may mention. A **boundary type** is one of:

- `Bool`, `Byte`, `Int`, `Long`, `UInt`, `ULong`, `Float`, `Double`, `Char`,
  `String`, `Unit`;
- `Option[T]`, `Result[T, E]`, `List[T]`, `slice[T]`, `Map[String, T]`,
  tuples, of boundary types;
- a record, an `exposed record`, a union with named case fields or an enum
  whose fields are boundary types, declared in the API package or in another
  package compiled through `Lyric.PluginExpand`;
- a `@plugin_handle` type;
- `Std.JsonValue.JsonValue`, for deliberately open data.

Excluded, with `K0001` naming the offending type:

- function types and closures (a call cannot carry code);
- interfaces (an interface value is an object in one address space);
- opaque types and protected types;
- generic records, unions and aliases, and generic types other than the
  built-in ones above (a plugin point is not generic in v1);
- `Option[T]` where `T` is already nullable on the wire (`Option[Option[T]]`,
  `Option[Unit]`, `Option[JsonValue]`): `None` and `Some` would be
  indistinguishable;
- union cases with positional fields, distinct types that are not
  `@plugin_handle`, range types, fixed-size arrays, and `Map` with
  non-`String` keys;
- `out` and `inout` parameters.

These rules are close to the docs/35 §7.1 WIT mapping. The plugin rules are
stricter where WIT is looser (no `Map` with non-`String` keys, because JSON in
process mode cannot represent it without a convention) and add handles and
`JsonValue`.

A range type is excluded rather than silently widened: an API that wants one
declares the base type and checks the range in the implementation.

## 6. Contracts at the boundary

A plugin is code the host's verifier never saw, and the host is code the
plugin's verifier never saw. Neither side may assume the other's contracts hold.

As shipped (D207 implementation notes):

- **Plugin calls a capability.** The generated host-side server decodes the
  grant and evaluates every `requires:` clause that names `grant` before it
  calls the implementation; a false clause is `Denied` (`-32040`) and never
  reaches it.
- **Other contracts run where the implementation is.** A point method's
  `requires:`/`ensures:` are elaborated into the plugin's implementation, and
  a capability's other clauses into the host's. A violation there fails the
  handler; the peer answers JSON-RPC `-32603`, which the caller sees as
  `BoundaryError.ContractViolated`, and the process that owns the
  implementation keeps running.
- **Not yet checked:** the host does not re-check a point method's `ensures:`
  on the decoded result. Until it does, a host treats a plugin's result as
  input from outside the program. In `@proof_required` code a call through a
  plugin point is a call to an unverified function, whose `ensures:` is not an
  axiom about the plugin.

## 7. The manifest and the artifact

A plugin's manifest, `plugin.json`, is what a host reads without running the
plugin. A Lyric plugin's generated `main` prints it (without payloads) when run
with the single argument `--lyric-plugin-manifest`; `lyric plugin pack` adds
the payloads and writes it into the artifact.

```json
{
  "schema": 1,
  "id": "acme.git-tools",
  "version": "0.4.1",
  "publisher": "acme",
  "points": [
    { "point": "Editor.Api.EditorExtension", "version": "1.2",
      "contributions": { "commands": [ ... ], "keybindings": [] } }
  ],
  "capabilities": {
    "required": [ { "name": "Editor.Api.WorkspaceRead", "grant": { "roots": ["${workspace}"] } },
                  { "name": "Editor.Api.Notify", "grant": null } ],
    "optional": [ { "name": "Editor.Api.WorkspaceEdit", "grant": null } ]
  },
  "payloads": [
    { "mode": "wasm", "module": "plugin.wasm" },
    { "mode": "process", "os": "linux", "arch": "x86_64", "command": ["acme-git-tools"] },
    { "mode": "process", "runtime": "dotnet", "command": ["dotnet", "exec", "Acme.GitTools.dll"] },
    { "mode": "process", "runtime": "jvm", "command": ["java", "-jar", "Acme.GitTools.jar"] }
  ]
}
```

- `id` is dot-separated segments of letters, digits, `-` and `_`
  (reverse-DNS style). `version` is `major.minor.patch` with an optional
  `-prerelease` and `+build` suffix; a point's `version` is `major.minor`.
- `contributions` is the value of the plugin's `@plugin_contributions`
  function, encoded as in §9.1 (`null` when the point declares none). `grant`
  is the value of its `@plugin_request` function, the request a grant policy
  shows the user.
- A payload is `ManagedPayload` (`runtime` `dotnet` or `jvm`), `NativePayload`
  (one `os` of `linux`, `macos`, `windows` and `arch` of `x86_64`,
  `aarch64`) or `WasmPayload` (`module`). Paths are relative to the artifact
  directory and may not leave it.
- **An artifact is a directory** named `<id>-<version>` holding `plugin.json`
  and its payload files, not an archive (D207 Decision 5): every host, SDK and
  the compiler reads a directory with what it already has.
  `lyric plugin pack [--manifest <lyric.toml>] [--targets dotnet,jvm,native,wasm] [-o <dir>]`
  builds each payload, probes one for its manifest and writes the directory;
  `lyric plugin check <dir>` validates one (the schema, the required fields,
  the versions, the payload forms, the files and the directory name) and
  reports every problem.
- A plugin written in another language writes its manifest with the manifest
  builder its generated SDK provides (§13), and is checked the same way.

## 8. Host API: `Std.Plugin`

`Std.Plugin` (`lyric-stdlib/std/plugin.l`, `@experimental`) is synchronous: a
host calls a plugin and gets the answer, and while it waits it serves the
plugin's capability calls on the same thread. A host is an ordinary program on
dotnet, the JVM or native.

```lyric
import Std.Plugin
import Editor.Api

val host = newPluginHost(PluginHostConfig(
  points = [editorExtensionPointInfo()],          // generated per point
  providers = [workspaceReadProvider(myWorkspace), notifyProvider(myNotifier)],
  policy = myGrantPolicy,                         // implements GrantPolicy
))

for issue in discoverPlugins(host, [userPluginDir, bundledPluginDir]) {
  log(pluginLoadIssueMessage(issue))
}

// Read contributions without starting anything.
for c in editorExtensionContributions(host) {
  registerCommands(c.pluginId, c.value.commands)
}

// Remotes start their plugin on the first call.
for ext in editorExtensionRemotes(host) {
  match ext.runCommand(id, args) {
    case Ok(_) -> ...
    case Err(CallError.App(e)) -> ...        // the plugin's own error
    case Err(CallError.Boundary(b)) -> ...   // Denied, Timeout, Crashed, ... (boundaryErrorMessage(b))
  }
}

stopAllPlugins(host)
```

- **Generated, per API package** (`Lyric.PluginExpand`): `<p>PointInfo()`,
  `<p>Remotes(host)` (a `<P>Remote` per loaded plugin of point `P`, each
  method returning `Result[T, CallError[E]]`), `<p>Contributions(host)`,
  `<c>CapabilityInfo()` and `<c>Provider(target)`, which wraps the host's
  implementation of capability `C` in a server that checks the grant clauses;
  `<C>As(host, pluginId)`, the capability called on a plugin's behalf; and
  `open<P>Session(host, pluginId)` for a protocol point.
- **Runtime:** `newPluginHost(config)`, `discoverPlugins(host, dirs)` (each
  subdirectory holding a `plugin.json` is one plugin, in name order),
  `registerPlugin(host, manifest, dir)` (for a manifest built in memory),
  `pluginManifests`, `connectionsFor`, `contributionsFor`,
  `callPlugin(conn, method, params)` (the untyped call the generated remotes
  use), `stopPlugin`, `stopAllPlugins`, `revokeCapability(host, id, capability)`,
  `openProtocolSession(host, pointId, pluginId)`, `protocolProcess(session)`
  and `closeProtocolSession(session)` (§4.3), `callCapabilityAs(host, id,
  method, params)`, and `openProtocolPlugin(host, pointId, pluginId)`, the
  unsupervised form. Trusted mode (§10) adds
  `GrantDecision.trusted`, `PluginHostConfig.trustedLoader` (with
  `Std.Plugin.Trusted.trustedPluginLoader()`), the `TrustedLoader`,
  `TrustedLibrary` and `HostLink` interfaces and `selectTrustedPayload`.
  Manifest helpers:
  `parsePluginManifest`, `readPluginManifest`, `pluginManifestToJson`,
  `addPluginPayload`, `selectPluginPayload`, `pluginLaunchCommand` and
  `findWasmtime`.
- **`PluginHostConfig`**: `points`, `providers`, `policy`, `callTimeoutMs`
  (60000), `startTimeoutMs` (10000), `maxRestarts` (3), `preferWasm` (true),
  `restartBackoffMs` (250), `maxRestartBackoffMs` (10000), `shutdownGraceMs`
  (2000), `wasmMaxMemoryBytes` (256 MiB).
- **Loading** validates the manifest, matches its points against the host's
  (a different major version is `K0103`; no matching point, a capability no
  point allows, or a duplicate id are load issues), asks the `GrantPolicy`
  for a `GrantDecision`, checks each grant against the request (Q-PLG-004: a
  list-valued grant field must be a subset of the requested list, any other
  field must equal it; a wider grant is `K0102`), requires every required
  capability to be granted and to have a provider, and chooses the payload.
  `grantAllRequested(manifest)` and the `GrantAllRequested` policy grant
  exactly what a plugin asks for.
- `BoundaryError` covers `Denied`, `NotGranted`, `Stale`, `Unsupported` (a
  method the plugin did not report in the handshake), `Revoked`,
  `ContractViolated`, `Timeout`, `Crashed` and `Protocol`.
- Grants can be revoked while a plugin runs: its later calls to that
  capability fail with `Revoked`, and a restart no longer receives the grant.
- Plugins can be stopped and started again while the host runs; in process
  and wasm modes this is real unloading.

The plugin side is `runPlugin(server)` and `callHost(conn, method, params)`;
a Lyric plugin never calls them directly, because `Lyric.PluginExpand`
generates its `PluginServer` and `main`.

## 9. Hosting modes

### 9.1 Process mode

- **Transport.** JSON-RPC 2.0 over the child's stdin and stdout, one message
  per line (`Std.JsonRpc.Stdio`'s NDJSON framing). Stderr is the plugin's log.
- **Handshake.** The host's first message is `plugin/hello` with
  `{"protocol": 1, "points": {"<Pkg>.<P>": "<major>.<minor>", ...}, "grants":
  [{"capability": "<Pkg>.<C>", "grant": <JSON or null>}, ...]}`. The plugin
  answers `{"protocol": 1, "id": ..., "points": {"<Pkg>.<P>": {"version": ...,
  "methods": [...]}}}`; a call to a method it did not list is `Unsupported`.
  A plugin missing a required grant answers `-32041` (`NotGranted`). A
  handshake that does not complete within `startTimeoutMs` is `Crashed`.
- **Method names.** Point methods are `<Pkg>.<P>/<method>`, capability
  methods `cap/<Pkg>.<C>/<method>`. Params are an object keyed by parameter
  name; a result is `{"ok": T}` or `{"err": E}`. A plugin may call capabilities
  while a point call is in progress.
- **Encoding** (D207 Decision 4). Records are objects keyed by field name,
  unions `{"case": "Name", ...fields}`, enums strings, `Option` `null` or the
  value, `List[Byte]`/`slice[Byte]` base64, `Map[String, T]` an object,
  handles and every integer type JSON numbers. Decoders reject a missing
  required member, an unknown case and a wrong JSON kind (`Protocol`), and
  ignore unknown members.
- **Boundary errors** are JSON-RPC errors: `-32001` timeout, `-32040`
  `Denied`, `-32041` `NotGranted`, `-32042` `Stale`, `-32043` `Unsupported`,
  `-32044` `Revoked`, `-32045` `ContractViolated`, `-32046` `Protocol`; the
  standard codes keep their meanings (`-32603` is `ContractViolated`).
- **Cancellation.** A call that exceeds `callTimeoutMs` sends
  `$/cancelRequest` and returns `Timeout`; the plugin keeps running.
- **Lifecycle.** A plugin starts on its first call. A crashed plugin is
  restarted on the next call after an exponential backoff, up to
  `maxRestarts` times; after that every call is `Crashed`. Shutdown is
  `plugin/shutdown`, then closing stdin, then killing after
  `shutdownGraceMs`.
- **Operating-system restrictions.** v1 applies none (Q-PLG-002, D207).
  Process isolation keeps a plugin's faults out of the host, but does not stop
  a native or managed process from opening files or sockets, so a process-mode
  plugin respects its capabilities only by being honest. A host that runs
  plugins from untrusted publishers should require their wasm payload.

### 9.2 Wasm mode

- **The module.** A wasm payload is the plugin built with
  `--target native --triple wasm32-wasi` (docs/35's plain WASI command), which
  speaks §9.1's protocol on its stdin and stdout. There is one protocol, one
  generated dispatcher and one host code path for both modes (D207
  Decision 6).
- **Running it.** The host starts it as
  `wasmtime run -W max-memory-size=<wasmMaxMemoryBytes> <module>`, with no
  `--dir`, `--env` or network, so its only route to anything outside is a
  capability call; `callTimeoutMs` bounds each call. `wasmtime` is found at
  `$LYRIC_WASMTIME` or on `PATH` (`findWasmtime`).
- **Payload choice.** With `preferWasm` (the default) and `wasmtime` present,
  a host runs the wasm payload; otherwise it prefers a native payload for its
  os and arch, then a managed payload of its own runtime, then the other
  managed runtime, and falls back to wasm last.
- **Not in v1:** a WIT-typed component with capabilities as imports, and an
  in-process wasmtime embedding (the routes this section first proposed).
  They remain the later optimisation of Q-PLG-001, with no change to plugin
  source.

## 10. Trusted mode

_Shipped in D231 (phase P6, the trusted half). Resolves Q-PLG-009: nothing
is unloaded in this mode._

For first-party plugins where the cost of a boundary matters, a host can load
a plugin into its own process. Trusted mode is a third transport for the same
protocol, not a second plugin model: the plugin keeps its generated server,
its capability clients, its grants and the host's guards, so the same source
runs in process, wasm and trusted mode.

### 10.1 Who decides

In-process loading is never chosen automatically. It needs both:

- **the host** to hold a loader: `PluginHostConfig.trustedLoader =
  Some(value = Std.Plugin.Trusted.trustedPluginLoader())`. The loader is a
  separate package, so a host that never loads plugins in process does not link
  the loading code at all; and
- **the grant policy** to mark the plugin trusted: `GrantDecision(..., trusted
  = true)`.

A plugin the policy trusts runs in process when it ships a trusted payload for
the host's runtime (and, on native, its os and arch) and the loader can load
in this process; otherwise it runs from its process or wasm payload with the
payload order of §9.2. A plugin the policy does not trust always runs from its
process or wasm payload, and one that ships only a trusted payload is then not
loaded (`NoUsablePayload`). A protocol plugin (§4.3) is never loaded in
process: its stdio carries its own protocol. A trusted payload that is chosen
but cannot be loaded is the load issue `TrustedLoadFailed`, never a silent
fallback to another mode.

The loader reports why it cannot load (`unavailableReason()`) on a Native AOT
dotnet host, a GraalVM native-image JVM host, and Windows or wasm32 native
hosts; such a host runs every plugin out of process.

### 10.2 The call path

A point call is a direct call of the plugin server's `dispatch(method,
params)`, with the same params object and `{"ok"}`/`{"err"}` result that
process mode writes to the pipe; the generated `<P>Remote` is unchanged. The
handshake is the same too: the host attaches the server with the granted
capabilities (less the revoked ones), reads the methods it reports per point,
and checks them as it checks a `plugin/hello` answer. A capability call from
the plugin goes through `callHost` on a connection whose `HostLink` reaches
the host's capability server directly: the grant lookup, revocation, the
generated server's guards and the provider are the code a process plugin's
`cap/...` request runs. There is one dispatcher (D207 Decision 6).

A typed path (the host calling the plugin's implementation of the point
interface) was considered and rejected: it would need the API package's types
to be one type on both sides, which a .NET plugin assembly cannot give (it
carries its own copy) and which would break §11's minor-version rule on the
JVM; and it would need a second copy of every guard and revocation check. The
JSON value objects cross directly, with no text, so the remaining cost is
encoding and decoding them: D231 records the measured cost of a call in
process and over a pipe.

### 10.3 Artifacts

A trusted payload is a manifest payload of mode `trusted`:

| Payload | Loaded by |
|---|---|
| `{"mode": "trusted", "runtime": "dotnet", "library": "<file>.dll"}` | a dotnet host, into its own `AssemblyLoadContext` |
| `{"mode": "trusted", "runtime": "jvm", "library": "<file>.jar"}` | a JVM host, with its own `URLClassLoader` |
| `{"mode": "trusted", "os": ..., "arch": ..., "library": "<lib>.so"}` | a native host on that os and arch (`.dylib` on macOS), with `dlopen` |

The managed trusted payloads are the process payloads' own files: the same
assembly or jar runs either way. A native trusted payload is a shared library
built with `lyric build --target native --shape plugin`. `lyric plugin pack
--trusted` adds the trusted payloads for its dotnet, jvm and native targets
(building the native library), and `lyric plugin check` validates them (the
suffix for the runtime or os, the file, one trusted payload per runtime or
os/arch pair).

### 10.4 Entry points

`Lyric.PluginExpand` generates two fixed, versioned functions in the package
of a `@plugin` record `R`:

- `pub func lyricPluginServerV1(): PluginServer`, a fresh `<R>Server`;
- `pub func lyricPluginEntryV1(): Unit`, which hands such a server to
  `offerTrustedPluginServer` of the loading kernel, `Std.PluginTrustedHost`.

The kernels find them by name only:

- **dotnet:** the plugin assembly goes into a non-collectible
  `AssemblyLoadContext` of its own. `Lyric.Stdlib` resolves to the host's
  loaded copy (the context does not load it, so the runtime falls back to the
  default context); every other assembly beside the plugin is loaded into the
  plugin's context first, so the plugin keeps its own packages and
  dependencies. The assembly's declared entry point (the generated `main`)
  names the plugin package's `Program` class, whose `lyricPluginEntryV1` the
  kernel invokes; the server it offers lands in the host's own copy of the
  kernel.
- **jvm:** a `URLClassLoader` over the jar whose parent is the loader of the
  host's stdlib. Loading is parent first, so every class the host has (the
  `Std.*` packages, and an API package host and plugin share) is the host's;
  the plugin's own packages come from the jar, and a plugin package whose
  name the host also uses is refused. The jar's `Main-Class` (the plugin
  package's class) names the class whose `lyricPluginEntryV1` is invoked.
- **native:** `dlopen` of the library and `dlsym` of `lyric_plugin_abi_v1`
  and `lyric_plugin_entry_v1`, which returns `lyricPluginServerV1()`.

A managed plugin hands its server over through the host's stdlib rather
than returning it, because Lyric has no downcast (D212): a host cannot turn
the `object` a reflective call returns into a `PluginServer`, while a plugin
whose stdlib is the host's own can pass the server to it as the host's type.
The host holds a lock while the entry point runs and it takes the offer, so
two threads loading plugins never take each other's server. The payload's own entry point names the class, so no extra
generated type or `META-INF/services` entry is needed, and the trusted and
process payloads are one file.

### 10.5 Native specifics

A `--shape plugin` library contains its own compiled copy of the Lyric code it
uses but no `lyric_rt`: its runtime symbols stay undefined and bind to the
host executable when the library is opened. A native build that reaches the
trusted loader links its whole runtime and exports it (`-rdynamic` with the
archive linked whole on Linux, `-force_load` and `-export_dynamic` on macOS),
so the process has one heap, one reference-counting discipline and one
scheduler. The host stays a self-contained executable; there is no shared
build of `lyric_rt` to install, and a plugin cannot bring a second runtime.
The library exports only the two entry symbols (a version script on Linux, an
exported-symbol list on macOS).

Objects cross between the host's code and the plugin's with no copying, so
both must lay them out alike. Both embed a fingerprint of the Lyric release
and of the boundary packages' sources (`Std.Core`, `Std.JsonValue`,
`Std.JsonRpc`, `Std.Plugin`); a library whose `lyric_plugin_abi_v1` differs
from the host's is refused. The fingerprint does not distinguish two builds of
an unreleased compiler that differ only in code generation: rebuild plugins
with the host's compiler.

`--shape plugin` is `N0027` for a target other than Linux or macOS (a Windows
DLL cannot import the runtime from the executable that loads it, and wasm32
has no dynamic loading) and `N0028` for a package without a `@plugin` record.

### 10.6 Failure model

A trusted plugin has no isolation. A crash, a call that never returns, a
stack overflow or a call to exit stops the host, and native has no unwinding
(D-N-003), so any panic in a native trusted plugin stops the host too. The
policy's `trusted` flag means accepting that on every target; there is no
separate native acknowledgement, which would suggest that managed trusted
mode is safe.

On dotnet and the JVM a panic inside a call is caught: the call fails with
`ContractViolated`, as a process plugin's `-32603` does, and the plugin keeps
running. A failure while the plugin is set up (its entry point offers no
server, `attach` fails or refuses with `NotGranted`, its methods do not match
the host's point versions) fails it for good: every call returns that error,
since a restart would repeat it. There is no restart and no call timeout:
`callTimeoutMs`, `startTimeoutMs`, `maxRestarts` and the backoff settings do
not apply. Errors that are not panics map as in process mode: the plugin's own
errors travel in `{"err"}`, and a dispatcher's JSON-RPC error goes through
`boundaryErrorFromRpc`.

### 10.7 Lifecycle and unloading (Q-PLG-009)

`stopPlugin` drops the plugin's server; the next call takes a fresh one from
the entry point and attaches it, so the plugin's record state starts again,
as a restarted process's does. Its library stays loaded, and its static state
with it.

Nothing is unloaded. A .NET collectible context and a released JVM class
loader leak through statics, thread locals and any object the host still
holds, and a native library's code runs the destructors of the objects it
allocated, which outlive every call into it. The context is therefore not
collectible, the class loader is never closed and the library is never
`dlclose`d. A plugin that must be replaceable while the host runs belongs in
process or wasm mode.

## 11. Versioning

- A plugin point's version is `major.minor`. Adding a method, adding an
  optional (`Option`) field to a boundary record, or adding a union case to a
  type only the host produces is a **minor** change; anything else (removing
  or changing a method, a required field, a grant field) is **major**.
- A plugin built against `1.n` loads in a host offering `1.m`. The plugin
  reports the methods it implements in the handshake, and a call to any other
  method returns `Unsupported` without reaching it (this replaces the `@since`
  marker first sketched here). Decoders ignore unknown members, so an older
  side tolerates fields a newer one adds.
- A plugin and a host with different major versions do not load together
  (`K0103`). A host can offer several major versions of a point at once by
  declaring each (`EditorExtensionV1`, `EditorExtensionV2`) and adapting
  between them in its own code.
- **Not in v1:** `lyric public-api-diff` classifying point changes and
  `lyric publish` enforcing the version bump, and an interface hash refused at
  handshake (`K0104`). The version is the author's promise until they exist.

## 12. Distribution and trust

- **Signing** is deferred (Q-PLG-006, D207). A host loads the artifact
  directories its owner put on its plugin path, and its `GrantPolicy` sees
  each manifest's `publisher` before anything runs.
- **Build-time plugins** (generators) are pinned by `lyric.lock` with a
  checksum, as docs/40 §7 already does.
- **Runtime catalogues.** Discovery scans the directories the host names. A
  registry or marketplace is deferred (Q-PLG-007, D207).
- **Consent.** Showing a user what a plugin requests and recording their
  decision is the application's job, through `GrantPolicy`, which receives the
  parsed `PluginManifest` (its `required` and `optional` capability requests
  with their grant values).

## 13. Plugins in other languages

`lyric plugin sdk --api <dir|file.l|lyric.toml> --lang csharp|java|typescript -o <dir>`
generates, for each point and capability of an API package:

- the boundary types in that language, with their D207 Decision 4 codecs;
- a process-mode server: the JSON-RPC loop, the handshake and the manifest
  probe, and an interface for each point the author implements;
- a capability client per capability;
- a manifest builder, so the author's build writes `plugin.json`;
- `<package>.schema.json`, a JSON Schema 2020-12 document of every boundary
  type and of each point's and capability's methods, from which a plugin in
  any other language with a JSON-RPC library can be written.

These plugins run in process mode. `scripts/ci/plugin-sdk-e2e.sh` builds one
plugin per language and drives it through every boundary type, the reverse
capability calls and the boundary error codes.

## 14. Wire integration

_The two entry forms are implemented (phase P4): `contributes[T] each` and
keyed contributions, specified in docs/01 §10.5, expanded by
`Lyric.WireExpand` on every target, diagnostics `W0028`, `P0348` and
`P0349`._

Plugins join a `wire` graph as contributions, so the rest of the graph sees
the same `List[T]` whether its entries were compiled in or loaded:

```lyric
wire EditorApp {
  @provided host: PluginHost

  contributes[CommandSource] builtins = Commands.builtin()
  contributes[CommandSource] each plugins = editorExtensionRemotes(host)
    .map(Commands.fromExtension)
    inside: builtins

  singleton palette: CommandPalette = CommandPalette.make(CommandSource)
}
```

`contributes[T] each name = e` takes a `List[T]` and contributes its elements
as one block, in list order. Ordering clauses (`wraps:`, `inside:`) apply to
the block as a whole. This is a small extension to docs/01 §10.5 and is useful
without plugins too.

Selecting from compiled-in implementations at startup needs no plugin
machinery at all: a keyed contribution, `contributes[T] key "otlp" name = e`,
makes `T` also available as `Map[String, T]`, and config picks the key. This
is the right tool when every option ships with the application.

As shipped: other entries order themselves against an `each` block by its
name, and an including wire's `remove`, `reorder` and replace act on the whole
block. A keyed entry also keeps its place in the ordered `List[T]`, so the list
and the map agree; the map is the graph name `TByKey` (`CommandSourceByKey`),
present once a collection has a keyed entry, with the keyed entries inserted
in collection order. Keys are plain string literals, unique per `T` in one
graph (`W0028`). `each` and `key` do not combine on one entry (`P0349`): a key
names one value, and a block has none.

## 15. Generators: the first plugin point

Generators prove the design because they already existed, already used a
subprocess and a JSON protocol, and had open questions this design answers.
`Lyric.GeneratorSdk` (`lyric-generator-sdk/`) is the point's API package:

```lyric
package Lyric.GeneratorSdk

pub exposed record ProjectReadGrant {
  roots: List[String]
}

@capability(grant = ProjectReadGrant)
pub interface ProjectRead {
  func readText(path: in String): Result[String, String]
    requires: projectPathWithin(path, grant.roots)
}

@plugin_point(version = "3.0", allows(ProjectRead))
pub interface SourceGenerator {
  func generate(req: in GeneratorRequest): Result[GeneratorResponse, GeneratorError]
}
```

```lyric
package Acme.Describe

import Lyric.GeneratorSdk

@plugin(id = "acme.describe", version = "0.1.0", publisher = "acme", implements(SourceGenerator))
pub record DescribePlugin {}

impl SourceGenerator for DescribePlugin {
  func generate(req: in GeneratorRequest): Result[GeneratorResponse, GeneratorError] {
    Ok(value = generateSource(req))
  }
}
```

What changed relative to the pre-D207 docs/40:

- The fixed `pub func generate` entry point and the generator's hand-written
  `main` are replaced by the `@plugin` record; `kind = "source-generator"`
  stays, and X0003 now means the package declares no `@plugin` record. The
  request and response types are unchanged apart from `schemaVersion`, which
  is replaced by the point's version, and the new `GeneratorError`. The
  hand-written stdin/stdout JSON code in `Lyric.Generator` and
  `lyric-generator-sdk` is gone; the codecs are generated.
- The compiler is a plugin host. It probes the built generator with
  `--lyric-plugin-manifest`, registers it with a `dotnet exec` payload,
  grants exactly the capabilities it requests, and serves `ProjectRead`
  itself, relative to the consuming project's directory, with the same
  `projectPathWithin` rule as the SDK. Because the compiler is built by a
  stage-0 seed that predates `Lyric.PluginExpand`, its host side uses
  `callPlugin` rather than a generated `SourceGeneratorRemote`.
- **Q-SG-001 (batching)** stopped mattering: one generator process lives for
  the whole build, and one call per annotated type is a request on an open
  connection, not a process start.
- **Q-SG-004 (LSP)** gets a long-lived generator the language server can call;
  the language server does not run generators yet.
- **Q-SG-005 (sandboxing)** is not answered yet. Generators are built for
  dotnet (D150) and run as process payloads with ambient I/O (`preferWasm` is
  off and a crashed generator is not restarted). Building them as wasm
  payloads, where `ProjectRead` would be their only I/O, is the planned
  answer.
- A generator runs on the build host whatever the consumer's `--target`
  (D150).

### 15.1 Widgets: the `lyric-ui` point

`Ui.Plugins` (`lyric-ui/plugins/`, D230) is the API package of the second
plugin point, `WidgetPlugin` (docs/65 §6.5):

```lyric
@plugin_point(version = "1.0", contributions = WidgetContributions)
pub interface WidgetPlugin {
  func init(req: in WidgetInit): Result[WidgetStep, WidgetError]
  func update(req: in WidgetUpdate): Result[WidgetStep, WidgetError]
  func configure(req: in WidgetConfigure): Result[WidgetStep, WidgetError]
}
```

- **State lives in the host.** A `WidgetStep` is the next state (a
  `JsonValue` the host passes back on the next call), the view and the
  outcomes. A crashed plugin is restarted on the next call and continues from
  the last state.
- **Views cross as `WidgetTree`**, a `Ui.Core.View` without closures: a
  handler names an event and a message string. `Ui.PluginWidgets` turns a tree
  into a `View` with host closures that produce `WidgetSignal`s.
- **Calls are effects** of the embedding screen
  (`Ui.PluginWidgets.Host.runWidgetRequest`).
- **No capabilities.** A widget asks its screen for anything else through
  `WidgetOutcome`s, so it is deterministic and a wasm payload has no access to
  anything.
- **The host distrusts the tree.** It bounds the tree, drops unknown
  properties and unsafe links, and shows an error banner with a Retry button
  for every failure (the plugin's error, a timeout, a crash, a refused view)
  over the last good view.

The widgets a plugin offers are its contributions (`WidgetDecl`: name, title,
description, a JSON Schema of the configuration and a default), listed by
`widgetCatalog` without starting anything. `examples/plugins/ui-widgets` is a
plugin and a screen that uses it.

## 16. Phases

| Phase | Deliverable | Status |
|---|---|---|
| P0 | Decision-log entries; Q-PLG-003 and `Std.JsonRpc` (D204); Q-PLG-005 and the contracts (D207) | Done |
| P1 | The annotations (§4), boundary-type checks, `K0000`-`K0012`, generated codecs, clients, servers, dispatchers, manifest and `main` (`Lyric.PluginExpand`) | Done |
| P1 | `Std.Plugin` process mode on dotnet, JVM and native hosts, over `Std.JsonRpc`; plugins on every target | Done |
| P2 | Generators migrated to `SourceGenerator` (§15); docs/40 updated; `examples/generators` and `scripts/ci/source-generator-e2e.sh` on the new path | Done |
| P2 | `lyric plugin pack`, `check` and `sdk` (C#, Java, TypeScript, JSON Schema), with a plugin per language in CI | Done |
| P3 | Wasm mode: wasm32-wasi command payloads under `wasmtime run` (§9.2) | Done; generators still use dotnet payloads (§15) |
| P4 | Protocol points: supervised `ProtocolSession`, routing through grants (`<C>As`, `callCapabilityAs`), the LSP example (`examples/plugins/lsp`), `contributes[T] each` and keyed contributions (D228) | Done |
| P5 | WIT-typed components and in-process wasmtime (Q-PLG-001) | Open; its prerequisite, C callbacks through `@library` bindings on every host target (wasmtime host functions are C function pointers with a `void *env`), shipped in D229 |
| P6 | `lyric-ui` widget point (docs/65 §6.5, §15.1, D230) | Done: `Ui.Plugins`, `Ui.PluginWidgets`, `examples/plugins/ui-widgets`, `scripts/ci/ui-widget-plugins-e2e.sh` |
| P6 | Trusted mode (§10): `trusted` payloads, `GrantDecision.trusted`, `Std.Plugin.Trusted`, `--shape plugin`, `lyric plugin pack --trusted` (D231) | Done |

Out of scope for every phase: plugins declaring their own plugin points, calls
from one plugin to another, and unloading or hot reload in trusted mode
(Q-PLG-009). Trusted plugins written in C# or Java against the generated SDKs
are not offered: those SDKs implement process mode.

## 17. Open questions

**Q-PLG-001: wasmtime component-model coverage in its C API.** _Not needed for
v1 (D207 Decision 6)._ Wasm mode runs a WASI command under `wasmtime run`
(§9.2). An in-process embedding with WIT-typed components would need
components, resources and the async ABI through the C API; the question is
reopened when P5 starts.

**Q-PLG-002: operating-system restrictions in process mode.** _Decided for v1
in D207: none; the isolation for an untrusted publisher is wasm mode, which a
policy can require. Landlock and network namespaces are a later addition._ Which of
seccomp, Landlock, network namespaces, macOS sandbox profiles and Windows
AppContainer v1 applies, and whether a host may refuse process-mode payloads
from untrusted publishers by default. Recommendation: Linux Landlock plus
network namespace in P1, the rest tracked per platform.

**Q-PLG-003: where JSON-RPC lives.** _Resolved in D204._ `Std.Plugin` needs a
JSON-RPC peer, and `lyric-jsonrpc` was an ecosystem library the stdlib and the
compiler cannot depend on. The peer and both stdio framings moved unchanged
into the stdlib as `Std.JsonRpc` and `Std.JsonRpc.Stdio`, and `lyric-jsonrpc`
was removed (it had no extras to keep), as D145 did for `Std.JsonValue`.

**Q-PLG-004: comparing a grant with a request.** _Resolved in D207: a
list-valued grant field must be a subset of the requested list, any other
field must equal the request, and a wider grant is load issue `K0102`. No
`narrows` function._ "A grant may narrow a request
but not widen it" needs a comparison per capability. Options: the capability
declares `narrows: func(granted: Params, requested: Params): Bool`; or
parameters are restricted to lists and the check is set inclusion.
Recommendation: a declared `narrows` function, defaulting to element-wise
inclusion when every parameter is a list.

**Q-PLG-005: declaration syntax.** _Resolved in D207: annotations on existing
items (§4), no new keywords._ Whether `plugin_point`, `capability`,
`protocol_point` and `plugin` are new keywords or annotated forms of existing
items (`@plugin_point interface`, `@capability interface`, `@plugin record`).
The annotated forms avoid new keywords but need the parameter and `guard:`
syntax anyway. Recommendation: keywords, following D051's "one keyword,
different modifiers" precedent where it fits (`pub plugin point` is one
option).

**Q-PLG-006: signing.** _Deferred (D207)._ Sigstore, a publisher key scheme, or reusing NuGet and
Maven signing for plugins distributed through them (docs/39).

**Q-PLG-007: a plugin registry.** _Deferred (D207)._ Whether plugins publish through the
docs/39 channels with a `kind = "plugin"` tag, or need their own registry.

**Q-PLG-008: per-frame and per-keystroke calls.** _No rule in v1 (D207);
batched point methods are the guidance._ Some points may be called
far too often for a process hop (widget rendering, editor decorations).
Whether such points should be required to be wasm-only, batched by design, or
marked so the host can refuse process-mode payloads for them. Unknown until a
real point needs it.

**Q-PLG-009: unloading in trusted mode.** _Resolved in D231: trusted mode never
unloads (§10.7); a plugin that must be replaced while the host runs belongs in
process or wasm mode._
Collectible load contexts on .NET
and class-loader release on the JVM can leak through statics and thread
locals; native unloading invalidates ARC objects whose code is gone. Whether
trusted mode ever offers unloading.

**Q-PLG-010: plugins declaring plugin points.** _Deferred (D204, D207)._ Needs dependency
ordering between plugins, version resolution across plugin-provided API
packages, and a decision about plugin-to-plugin calls.

## 18. Diagnostics

`Lyric.PluginExpand` reports the compile-time codes (D207 Decision 1, with
the implementation notes):

| Code | Meaning |
|---|---|
| K0000 | Internal error: the pass generated code that does not parse (a compiler bug to report) |
| K0001 | A point, capability, grant, contributions or handle type mentions a type that cannot cross a boundary (§5), or a method has an `out`/`inout` parameter |
| K0002 | `allows(...)` names an interface that is not a `@capability` |
| K0003 | A plugin requests a capability that none of its points allows |
| K0004 | A point or capability method does not return `Result[T, E]` or is generic, or the interface is generic or declares associated types |
| K0005 | A plugin annotation on the wrong kind of item (`@plugin_point`/`@capability`/`@protocol_point` not on a `pub interface`, `@plugin_handle` not on `pub type H = Long`, `@plugin` not on a `pub record`) |
| K0006 | A malformed annotation: a missing or malformed `version`, `id` or `protocol`, `grant =`/`contributions =` not naming a type, an unknown argument |
| K0007 | A capability `requires:` clause names something other than `grant`, its own parameters and functions |
| K0008 | `implements(...)` names an interface the plugin record has no `impl` for, or that is not a point; or the record implements a point it does not list |
| K0009 | A missing, duplicated or wrongly typed `@plugin_contributions` / `@plugin_request` function |
| K0010 | A plugin record field without a default that is not a capability client |
| K0011 | A `@protocol_point` interface with members |
| K0012 | A package with a `@plugin` record also declares `main`, or declares two `@plugin` records |

`Std.Plugin` reports load issues as `PluginLoadIssue` values; two carry
docs/69 codes (`pluginIssueCode`):

| Code | Meaning |
|---|---|
| K0101 | (load) A plugin's contributions do not decode as the point's contributions type; the generated `<p>ContributionIssues(host)` reports it and `<p>Contributions` leaves the plugin out |
| K0102 | (load) A grant policy returned a grant wider than the request |
| K0103 | (load) Major version mismatch between plugin and host |

A trusted payload that the policy chose but that cannot be loaded into the host's
process is the load issue `TrustedLoadFailed` (no code).

`K0104` (interface hash) is reserved and not checked in v1. `lyric plugin check`
reports manifest problems as text, without codes.
