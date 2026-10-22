# 69. Plugins: typed plugin points, parameterised capabilities, and isolated hosting

_Status: **Unbacked sketch.** Proposes a general plugin architecture for
applications written in Lyric, with source generators (docs/40, D075, D150) as
the first plugin point it is proved on. Extends docs/01 §10 (`wire`,
`contributes[T]`) and §11.7 (`@library` C bindings), docs/35 (the `component`
output shape and WIT generation), and docs/62 (`lyric-jsonrpc`). Open questions
Q-PLG-001 to Q-PLG-010 are listed in §17. No decision-log entry yet._

## 1. Why this exists

Lyric has no reflection (docs/04), and that rules out the usual .NET and JVM
plugin pattern: scan a directory, load assemblies or classes, find types that
implement an interface, and instantiate them. Applications still need plugins.
The motivating cases are:

- **Source generators.** docs/40 already runs custom generators as
  subprocesses with a hand-written JSON protocol on stdin and stdout, one
  process per annotated type, with no sandbox (Q-SG-005).
- **UI widgets.** `lyric-ui` (docs/65) has a closed set of semantic widgets.
  Third-party widgets need a way in.
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
| Compiler | The `plugin_point`, `capability`, `protocol_point` and `plugin` declarations; the boundary-type rules; generating proxies, manifests, WIT, JSON schemas and SDKs |
| `Std.Plugin` | Discovery, manifests, the hosting modes, the handshake and version negotiation, enforcing grants, lifecycle |
| The application | Its plugin points and capabilities, and the policy that decides grants (including asking the user) |

Every plugin runs in one of three **hosting modes**:

| Mode | Isolation | Host targets | Plugin authors | v1 |
|---|---|---|---|---|
| **Process** | Separate OS process; a crash or hang cannot take the host down; unloading is killing the process | All, including Native AOT | Any language, through generated SDKs | Yes |
| **Wasm** | WebAssembly component; the plugin reaches only the capability imports it was granted | All (§9.3) | Lyric (docs/35 `component` shape), C# through componentize-dotnet, Rust, others | Yes |
| **Trusted** | None; runs in the host process | Same target as the host; not Native AOT | Lyric, C#, Java | No (§10) |

The plugin author writes one declaration. Which mode a plugin runs in is
decided by the artifact the author ships and by the host's policy, never by the
plugin's source.

## 4. Language surface

### 4.1 Capabilities

A `capability` is a portable interface (§5) the host implements and the plugin
calls. It may take parameters, which are fixed when the capability is granted.

```lyric
package Editor.Api

pub capability WorkspaceRead(roots: List[PathPattern]) {
  async func readFile(path: in DocPath): Result[String, IoError]
    guard: Paths.matchesAny(path, roots)

  async func findFiles(glob: in String): Result[List[DocPath], IoError]
}

pub capability Notify {
  async func showMessage(level: in Severity, text: in String): Result[Unit, NotifyError]
}

pub capability NetHttp(hosts: List[String]) {
  async func send(req: in HttpRequestData): Result[HttpResponseData, HttpError]
    guard: List.contains(hosts, req.host)
}
```

Rules:

- Parameters have boundary types (§5). They are part of the request the plugin
  makes and of the grant the host returns.
- A method may carry a `guard:` clause: a boolean expression over the
  capability's parameters and the method's `in` arguments. Only `@pure` code
  may appear in it (docs/65 layering rules). The host evaluates it before
  dispatching the call. A false guard fails the call with
  `BoundaryError.Denied` and never reaches the implementation.
- Guards are the declarative part of enforcement. The host's implementation can
  apply further checks, but a guard is visible in the plugin point's published
  surface, so a plugin author and a user approving a grant can read it.
- A capability method's own `requires:` clauses are checked on the host side,
  like a guard. They express the plugin's obligations and are also published.

### 4.2 Plugin points

```lyric
package Editor.Api

pub exposed record EditorContributions {
  commands: List[CommandDecl] = []
  keybindings: List[KeybindingDecl] = []
  activation: List[ActivationEvent] = []
}

pub plugin_point EditorExtension version "1.2" {
  allows: WorkspaceRead, WorkspaceEdit, Notify, NetHttp
  contributions: EditorContributions

  async func activate(): Result[Unit, PluginError]
  async func runCommand(id: in CommandId, args: in JsonValue): Result[Unit, PluginError]

  @since("1.2")
  async func onSave(doc: in DocumentRef): Result[Unit, PluginError]
}
```

Rules:

- `version` is a semantic version (`major.minor`). §11 says how it changes.
- `allows:` lists every capability a plugin of this point may request.
- `contributions:` names an `exposed record` type. A plugin supplies a value of
  it, which is recorded in the plugin's manifest and readable by the host
  without starting the plugin (§7).
- Every method is `async` and returns `Result[T, E]` (`K0004` otherwise).
  Calls cross a process or sandbox boundary and can fail in ways that are not
  the plugin's error, so the result type has to carry failure.
- A method added in a minor version carries `@since("major.minor")`.
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

pub protocol_point LanguageServer {
  protocol: "lsp/3.17"
  transport: stdio
  allows: WorkspaceRead, NetHttp
  contributions: LanguageContributions
}
```

`Std.Plugin` launches the process, applies the process-mode restrictions
(§9.1), restarts it on failure and stops it. It hands the application a
connected byte stream; the application's own protocol client (for LSP, the
`Lyric.Lsp` code) does the rest. Capabilities on a protocol point are enforced
only to the extent the host routes the protocol's own requests through them
(for example the LSP `workspace/applyEdit` request through `WorkspaceEdit`),
plus any operating-system restrictions §9.1 can apply. Process and wasm modes
apply to protocol points; a wasm protocol plugin exports a single
`handle(message: List[Byte])` stream interface (§9.2).

### 4.4 Plugins

```lyric
package Acme.GitTools

import Editor.Api

pub plugin GitTools {
  implements: EditorExtension, MenuProvider
  requires: WorkspaceRead(roots: [PathPattern.workspace()]), Notify
  optional: WorkspaceEdit, NetHttp(hosts: ["api.github.com"])

  contributes: EditorExtension = EditorContributions {
    commands: [CommandDecl(id: "git.blame", title: "Git: Blame")],
    activation: [ActivationEvent.OnCommand("git.blame")],
  }

  impl EditorExtension {
    async func activate(): Result[Unit, PluginError] { ... }
    async func runCommand(id: in CommandId, args: in JsonValue): Result[Unit, PluginError] {
      val text = ctx.workspaceRead.readFile(...)?
      match ctx.workspaceEdit { ... }
    }
  }

  impl MenuProvider { ... }
}
```

From a `plugin` declaration the compiler generates:

- **The manifest** (§7). It is derived from the declaration, so it cannot
  disagree with the code.
- **A typed context**, `ctx`, in scope inside the plugin's `impl` blocks. Each
  capability in `requires:` is a non-optional field. Each capability in
  `optional:` is an `Option` field, `None` when the host did not grant it. The
  host refuses to load a plugin whose required capabilities it does not grant
  (`PluginError.NotGranted`), so a plugin never runs in a state its types do
  not describe.
- **The plugin side of the boundary** for each hosting mode: the request
  dispatcher in process mode, the component exports in wasm mode.

A plugin that implements several points runs as one process or one wasm
instance, with one set of grants.

The context is a convenience and an early error, not the enforcement. Every
capability call is checked on the host side (§8), because a non-Lyric plugin
has no generated context at all.

### 4.5 Handles

A host often needs to give a plugin a reference to something it owns: a
document, an editor, a tree node. Such a reference is declared as a handle:

```lyric
pub handle DocumentRef
```

A handle is an opaque token. A plugin can store it, compare it, and pass it to
capability methods and back to the host. It cannot see inside it. In process
mode it is an integer issued by the host per plugin. In wasm mode it is a WIT
`resource` the host owns.

Handles are valid until the host invalidates them (the document closes, the
plugin is stopped). A call with an invalidated handle fails with
`BoundaryError.Stale`. Handles issued to one plugin are meaningless to another:
the host keeps a separate table per plugin, so a plugin cannot forge or borrow
another plugin's handles.

## 5. Boundary types

Everything that crosses a plugin boundary is copied, so the compiler restricts
what plugin points and capabilities may mention. A **boundary type** is one of:

- `Bool`, `Byte`, `Int`, `Long`, `UInt`, `ULong`, `Float`, `Double`, `Char`,
  `String`, `Unit`;
- `Option[T]`, `Result[T, E]`, `List[T]`, `Map[String, T]`, tuples, of
  boundary types;
- an `exposed record`, a union or an enum whose fields are boundary types,
  declared in the same API package or in a package it imports;
- a `handle`;
- `Std.JsonValue.JsonValue`, for deliberately open data.

Excluded, with `K0001` naming the offending type:

- function types and closures (a call cannot carry code);
- interfaces (an interface value is an object in one address space);
- opaque types, unless `@projectable`, in which case the projection crosses;
- protected types;
- generic type parameters (a plugin point is not generic in v1);
- `out` and `inout` parameters.

These rules are close to the docs/35 §7.1 WIT mapping. The plugin rules are
stricter where WIT is looser (no `Map` with non-`String` keys, because JSON in
process mode cannot represent it without a convention) and add handles and
`JsonValue`.

A range subtype crosses as its underlying type. The receiving side re-checks
the range, as for any value from outside the program.

## 6. Contracts at the boundary

A plugin is code the host's verifier never saw, and the host is code the
plugin's verifier never saw. Neither side may assume the other's contracts hold.

- **Host calls a plugin point method.** The plugin side checks the method's
  `requires:` on entry (its generated dispatcher runs the normal elaborated
  checks). The host side checks `ensures:` on the returned value before giving
  it to the caller. A failed `ensures:` becomes
  `BoundaryError.ContractViolated`, not a host panic: the fault is the
  plugin's, and the host has to survive it.
- **Plugin calls a capability.** The host checks `guard:` and `requires:`
  before dispatch, with the same error translation. The plugin side checks
  the capability's `ensures:` on the result.
- **In `@proof_required` code**, a call through a plugin point is a call to an
  unverified function. The verifier treats its `ensures:` as established by
  the runtime check (the proxy's result has passed it), not as an axiom about
  the plugin.

## 7. The manifest

The compiler writes a manifest, `plugin.json`, into every plugin artifact. A
host reads it without running the plugin.

```json
{
  "schema": 1,
  "id": "acme.git-tools",
  "version": "0.4.1",
  "publisher": "acme",
  "points": [
    { "point": "Editor.Api.EditorExtension", "version": "1.2",
      "contributions": { "commands": [ ... ], "activation": [ ... ] } },
    { "point": "Editor.Api.MenuProvider", "version": "1.0", "contributions": { ... } }
  ],
  "capabilities": {
    "required": [ { "name": "Editor.Api.WorkspaceRead", "params": { "roots": [ ... ] } },
                  { "name": "Editor.Api.Notify" } ],
    "optional": [ { "name": "Editor.Api.WorkspaceEdit" },
                  { "name": "Editor.Api.NetHttp", "params": { "hosts": ["api.github.com"] } } ]
  },
  "payloads": [
    { "mode": "wasm", "file": "plugin.wasm" },
    { "mode": "process", "os": "linux", "arch": "x86_64", "command": ["bin/git-tools"] },
    { "mode": "process", "runtime": "dotnet", "command": ["dotnet", "exec", "lib/GitTools.dll"] }
  ]
}
```

- `id` is a reverse-DNS-style identifier, unique per publisher.
- The `contributions` objects are values of each point's contributions type,
  encoded as in §9.1. The host validates them against the type when it reads
  the manifest (`K0101` at load time on a mismatch).
- A plugin artifact (`.lyplugin`) is a zip of the manifest and its payloads,
  plus a signature (§12). `lyric plugin pack` builds one.
- A plugin written in another language ships a manifest produced by the SDK
  tooling (§13). `lyric plugin check <artifact>` validates any artifact
  against the API packages it names.

## 8. Host API: `Std.Plugin`

```lyric
import Std.Plugin as Plugin

val host = Plugin.newHost(Plugin.HostConfig {
  apiVersion: ...,                      // the points and capabilities this host offers
  policy: myGrantPolicy,                // implements Plugin.GrantPolicy
  capabilities: [
    Plugin.provide[WorkspaceRead](workspaceReadImpl),
    Plugin.provide[Notify](notifyImpl),
  ],
})

val catalog = Plugin.discover(host, [userPluginDir, bundledPluginDir])?

// Read contributions without starting anything.
val commands = Plugin.contributionsOf[EditorExtension](catalog)

// Proxies that start the plugin on first call (or on an activation event).
val extensions: List[Plugin.Loaded[EditorExtension]] = Plugin.instancesOf[EditorExtension](host, catalog)

for ext in extensions {
  match await ext.proxy.runCommand(id, args) {
    case Ok(_) -> ...
    case Err(CallError.App(e)) -> ...        // the plugin's own error
    case Err(CallError.Boundary(b)) -> ...   // Denied, Stale, Timeout, Crashed, ...
  }
}
```

- `Plugin.instancesOf[P]` and `Plugin.contributionsOf[P]` require `P` to be a
  plugin point (`K0005`). The compiler supplies the point's identity (package,
  name, version and interface hash) as a constant. This is the only "type
  lookup" in the system, and it happens at compile time.
- A proxy of point `P` has each of `P`'s methods with its result widened from
  `Result[T, E]` to `Result[T, CallError[E]]`, where
  `union CallError[E] { case App(error: E) case Boundary(error: BoundaryError) }`.
- `BoundaryError` covers `Denied`, `NotGranted`, `Stale`, `Timeout`,
  `Crashed`, `ContractViolated`, `Unsupported` (a `@since` method the plugin's
  negotiated version lacks), `Revoked` and `Protocol`.
- `Plugin.GrantPolicy` is the application's code. It receives a plugin's
  manifest and returns the grants: which requested capabilities, with which
  parameter values. A grant's parameters may be narrower than the request
  (fewer roots, fewer hosts), never wider (`K0102` if the policy returns a
  wider value, checked by a per-capability comparison the capability can
  declare, Q-PLG-004). The policy is where an editor asks the user.
- Grants can be revoked while a plugin runs. Calls on a revoked capability
  fail with `BoundaryError.Revoked`, which every capability result already
  carries.
- Plugins can be stopped, reloaded and updated while the host runs. In process
  and wasm modes this is real unloading, since nothing of the plugin lives in
  the host's memory.

## 9. Hosting modes

### 9.1 Process mode

- **Transport.** JSON-RPC 2.0 over the child process's stdin and stdout,
  newline-delimited (docs/62's NDJSON framing). Stderr is captured into the
  host's log under the plugin's id.
- **Handshake.** The host sends `plugin/hello` with the host's version of each
  point the plugin implements and the granted capabilities and parameters. The
  plugin answers with its versions. Both sides then use the highest common
  minor version (§11). A plugin that fails the handshake within the start
  timeout is `Crashed`.
- **Method names.** Point methods are `<Point>/<method>`, capability methods
  `cap/<Capability>/<method>`, both with fully qualified names. Calls go both
  ways on the same connection, and many may be in flight at once.
- **Encoding.** Records are JSON objects keyed by field name. Unions are
  `{"case": "Name", ...fields}`. Enums are strings. `Long` and `ULong` are
  JSON numbers when they are within ±2^53, otherwise strings. `List[Byte]` is
  base64. Handles are `{"$handle": n}`. The generated JSON Schema for each
  point is the reference that SDKs in other languages are built from.
- **Cancellation.** `$/cancelRequest` as in LSP. Cancelling a host-side call
  (a `scope` exiting, a timeout) sends it.
- **Lifecycle.** A plugin starts lazily, on the first call or on one of its
  activation events. It is restarted after a crash with exponential backoff,
  up to a limit the policy sets, after which its proxies return `Crashed`
  until reloaded. Shutdown is `plugin/shutdown`, then closing stdin, then
  killing after a grace period.
- **Operating-system restrictions.** Process isolation keeps a plugin's faults
  out of the host, but by itself it does not stop a native process from
  opening files or sockets. On Linux the host may additionally start the
  process under seccomp, Landlock and a network namespace derived from the
  grants (no `NetHttp` granted: no network). Similar restrictions exist on
  macOS (sandbox profiles) and Windows (AppContainer). Which of these v1
  applies is Q-PLG-002. Until they apply, a process-mode plugin is honest
  about its capabilities only if it is a Lyric plugin built by `lyric`,
  because there is nothing else stopping it; the host policy should treat a
  process-mode plugin from an untrusted publisher accordingly, and prefer its
  wasm payload when it has one.

### 9.2 Wasm mode

- **The component.** A Lyric plugin built for wasm is a component (docs/35
  `component` shape). The compiler generates its WIT world from the plugin
  declaration: the world **exports** one interface per implemented point and
  **imports** one interface per capability the point allows. Handles are WIT
  resources owned by the host. Async methods are WIT `async func` (D184).
- **Grants.** Every allowed capability import has to be satisfied for the
  component to instantiate. The host links the real implementation for a
  granted capability and a stub that returns `Denied` for one that is not.
  The plugin gets no WASI filesystem, network, clocks or randomness except
  through capabilities. A point that needs time or randomness declares a
  capability for it, which keeps plugins like generators deterministic by
  default.
- **Resource limits.** The host sets a memory ceiling and uses wasmtime's
  epoch interruption to bound the time any one call runs (`Timeout`).
- **Protocol points.** A wasm protocol plugin exports
  `handle: async func(message: list<u8>) -> list<list<u8>>` plus a
  notification import, and the host adapts that to the byte stream §4.3
  promises the application.

### 9.3 Running wasmtime from each host target

Three routes, by preference:

1. **In process on `native`**, through the wasmtime C API with `@library`
   bindings (docs/01 §11.7).
2. **In process on `dotnet` and `jvm`**, through the same `@library`
   bindings, which §11.7 provides on every target. This route depends on the
   wasmtime C API's component-model coverage, including the async ABI
   (Q-PLG-001).
3. **Out of process**, through `lyric-wasm-host`, a small native Lyric program
   that embeds wasmtime and speaks process-mode JSON-RPC to the host. This
   works on every host target, Native AOT included, and costs an extra process
   hop. It is the fallback for any target where route 1 or 2 is not
   available.

Route 3 is built first. It makes wasm mode available everywhere once process
mode exists, and it puts wasmtime in a separate process from hosts that do
not want a native dependency.

## 10. Trusted mode (later phase)

For first-party plugins where the cost of a boundary matters, a plugin can be
loaded into the host's process:

- **dotnet:** a plugin assembly in a collectible `AssemblyLoadContext` that
  resolves the API packages to the host's loaded copies, so the plugin's
  `EditorExtension` is the host's `EditorExtension`. The entry point is a
  compiler-generated type with a fixed name; the kernel looks it up by that
  name and nothing else.
- **jvm:** a child class loader that delegates the API packages to the parent;
  discovery through a generated `META-INF/services` entry.
- **native:** `dlopen` of a shared library and `dlsym` of a fixed versioned
  symbol, against a shared-library build of `lyric_rt` so ARC state is not
  duplicated.

The host policy must explicitly mark a plugin trusted; in-process loading is
never chosen automatically. Native AOT hosts do not offer it. The plugin still
sees the same `ctx` and the same boundary-type rules, so a plugin can move
between modes without source changes. Unloading is not offered in this mode
(Q-PLG-009).

## 11. Versioning

- A plugin point's version is `major.minor`. `lyric public-api-diff` on the
  API package classifies a change to a point:
  - adding a method marked `@since` the new minor, adding an optional field
    with a default to a boundary record, or adding a union case to a type
    only the host produces, is **minor**;
  - anything else (removing or changing a method, a required field, a
    capability parameter) is **major**.
  `lyric publish` refuses an API package whose version change is smaller than
  its point changes require (`K0006`).
- A plugin built against `1.n` loads in a host offering `1.m`. The handshake
  uses `1.min(n, m)`. A call to a method newer than the negotiated version
  returns `Unsupported` without reaching the plugin.
- A plugin and a host with different major versions do not load together
  (`K0103`). A host can offer several major versions of a point at once by
  declaring each (`EditorExtensionV1`, `EditorExtensionV2`) and adapting
  between them in its own code.
- A point's interface hash (over its boundary surface) is part of its
  identity. Two API package builds that claim the same version but hash
  differently are refused at handshake (`K0104`).

## 12. Distribution and trust

- **Signing.** A `.lyplugin` artifact is signed over its manifest and
  payloads. The host policy decides which publishers it accepts; an unsigned
  or wrongly signed artifact does not load unless the policy explicitly allows
  it (for local development). The signature scheme is Q-PLG-006.
- **Build-time plugins** (generators) are pinned by `lyric.lock` with a
  checksum, as docs/40 §7 already does.
- **Runtime catalogues.** Discovery scans the directories the host names. A
  registry or marketplace is out of scope for this sketch (Q-PLG-007).
- **Consent.** Showing a user what a plugin requests (the manifest's
  capabilities, parameters and guards) and recording their decision is the
  application's job, through `GrantPolicy`. `Std.Plugin` provides
  `Plugin.describeRequest(manifest)`, a structured summary for that UI.

## 13. Plugins in other languages

`lyric plugin sdk --api <api-package> --lang csharp|java|typescript --out <dir>`
generates, for each point and capability of an API package:

- the boundary types in that language;
- a process-mode server: the JSON-RPC loop, the handshake, and an interface
  for each point the author implements;
- a capability client with the grant-aware context;
- a manifest builder, so the author's build writes `plugin.json`.

C# authors can also target wasm mode with componentize-dotnet against the
generated WIT. Java has no comparable component toolchain at the time of
writing, so Java plugins use process mode. Any other language with a
JSON-RPC library can implement a plugin from the JSON Schema alone.

## 14. Wire integration

Plugins join a `wire` graph as contributions, so the rest of the graph sees
the same `List[T]` whether its entries were compiled in or loaded:

```lyric
wire EditorApp {
  @provided host: Plugin.Host
  @provided catalog: Plugin.Catalog

  contributes[CommandSource] builtins = Commands.builtin()
  contributes[CommandSource] each plugins = Plugin.instancesOf[EditorExtension](host, catalog)
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

## 15. Generators: the first plugin point

Generators prove the design because they already exist, already use a
subprocess and a JSON protocol, and have open questions this design answers.

```lyric
package Lyric.GeneratorSdk

pub capability ProjectRead(roots: List[String]) {
  async func readText(path: in String): Result[String, GeneratorIoError]
    guard: Paths.underAny(path, roots)
}

pub plugin_point SourceGenerator version "3.0" {
  allows: ProjectRead
  contributions: GeneratorContributions   // generator names, schema version

  async func generate(req: in GeneratorRequest): Result[GeneratorResponse, GeneratorFailure]
}
```

```lyric
package Acme.Describe

pub plugin Describe {
  implements: SourceGenerator
  contributes: SourceGenerator = GeneratorContributions { names: ["Describe"] }

  impl SourceGenerator {
    async func generate(req: in GeneratorRequest): Result[GeneratorResponse, GeneratorFailure] { ... }
  }
}
```

What changes relative to docs/40:

- `kind = "source-generator"` and the fixed `pub func generate` entry point
  (X0003) are replaced by the `plugin` declaration. The request and response
  types are unchanged; the hand-written stdin/stdout protocol in
  `Lyric.Generator` and `lyric-generator-sdk` is replaced by generated code.
- The compiler is a plugin host. It grants `ProjectRead` with `roots` set to
  the consuming project's directory, or nothing if the generator does not
  request it.
- **Q-SG-001 (batching)** stops mattering: a generator process lives for the
  whole build, and one call per annotated type is a request on an open
  connection, not a process start.
- **Q-SG-004 (LSP)** gets a long-lived generator the language server can call
  on save.
- **Q-SG-005 (sandboxing)** is answered by wasm mode. A generator has no
  ambient I/O there, so wasm becomes the default payload for generators once
  §16 phase P3 lands, and `lyric publish` warns on a generator without a wasm
  payload.
- A generator still runs on the build host whatever the consumer's
  `--target` (D150). With a wasm payload, "the build host" stops mattering:
  the same `.wasm` runs under the compiler on every platform.

## 16. Phases

| Phase | Deliverable |
|---|---|
| P0 | Decision-log entry codifying this design; resolve Q-PLG-003, Q-PLG-005 |
| P1 | Language: `plugin_point`, `capability` (with parameters and `guard:`), `plugin`, `handle`; boundary-type checks; `K0001`-`K0012`; manifest generation; `docs/01` section and book chapter |
| P1 | `Std.Plugin` process mode on `dotnet`, `jvm` and `native` hosts; JSON-RPC moved into the stdlib (Q-PLG-003) |
| P2 | Generators migrated to `SourceGenerator` (§15); docs/40 updated; `examples/generators` and `scripts/ci/source-generator-e2e.sh` on the new path; one C# generator built with the generated SDK in CI |
| P3 | Wasm mode through `lyric-wasm-host` (§9.3 route 3); generators default to wasm payloads |
| P4 | `protocol_point`; an LSP example; `contributes[T] each` and keyed contributions |
| P5 | In-process wasmtime (§9.3 routes 1 and 2) |
| P6 | `lyric-ui` widget point (docs/65); trusted mode (§10) |

Out of scope for every phase in this sketch: plugins declaring their own
plugin points, calls from one plugin to another, and hot reload in trusted
mode.

## 17. Open questions

**Q-PLG-001: wasmtime component-model coverage in its C API.** Routes 1 and 2
in §9.3 need components, resources and the async ABI through the C API. If
coverage is incomplete, route 3 stays the only route on the affected targets
until it is, or a thin C shim over the Rust API is built and shipped with
`lyric-rt`. Recommendation: build route 3 first and decide when P5 starts.

**Q-PLG-002: operating-system restrictions in process mode.** Which of
seccomp, Landlock, network namespaces, macOS sandbox profiles and Windows
AppContainer v1 applies, and whether a host may refuse process-mode payloads
from untrusted publishers by default. Recommendation: Linux Landlock plus
network namespace in P1, the rest tracked per platform.

**Q-PLG-003: where JSON-RPC lives.** `Std.Plugin` needs a JSON-RPC peer, and
`lyric-jsonrpc` is an ecosystem library the stdlib and the compiler cannot
depend on. Options: move the core peer and NDJSON framing into the stdlib as
`Std.JsonRpc` (as `Std.JsonValue` was moved in D145), or give `Std.Plugin` a
private implementation. Recommendation: move it, and make `lyric-jsonrpc` a
re-export plus its extras, so there is one implementation.

**Q-PLG-004: comparing a grant with a request.** "A grant may narrow a request
but not widen it" needs a comparison per capability. Options: the capability
declares `narrows: func(granted: Params, requested: Params): Bool`; or
parameters are restricted to lists and the check is set inclusion.
Recommendation: a declared `narrows` function, defaulting to element-wise
inclusion when every parameter is a list.

**Q-PLG-005: declaration syntax.** Whether `plugin_point`, `capability`,
`protocol_point` and `plugin` are new keywords or annotated forms of existing
items (`@plugin_point interface`, `@capability interface`, `@plugin record`).
The annotated forms avoid new keywords but need the parameter and `guard:`
syntax anyway. Recommendation: keywords, following D051's "one keyword,
different modifiers" precedent where it fits (`pub plugin point` is one
option).

**Q-PLG-006: signing.** Sigstore, a publisher key scheme, or reusing NuGet and
Maven signing for plugins distributed through them (docs/39).

**Q-PLG-007: a plugin registry.** Whether plugins publish through the
docs/39 channels with a `kind = "plugin"` tag, or need their own registry.

**Q-PLG-008: per-frame and per-keystroke calls.** Some points may be called
far too often for a process hop (widget rendering, editor decorations).
Whether such points should be required to be wasm-only, batched by design, or
marked so the host can refuse process-mode payloads for them. Unknown until a
real point needs it.

**Q-PLG-009: unloading in trusted mode.** Collectible load contexts on .NET
and class-loader release on the JVM can leak through statics and thread
locals; native unloading invalidates ARC objects whose code is gone. Whether
trusted mode ever offers unloading.

**Q-PLG-010: plugins declaring plugin points.** Deferred. Needs dependency
ordering between plugins, version resolution across plugin-provided API
packages, and a decision about plugin-to-plugin calls.

## 18. Diagnostics

| Code | Meaning |
|---|---|
| K0001 | A plugin point, capability or handle signature mentions a type that cannot cross a boundary (§5) |
| K0002 | `allows:` names something that is not a capability |
| K0003 | A plugin requests a capability its point does not allow |
| K0004 | A point or capability method is not `async`, or does not return `Result[T, E]` |
| K0005 | `Plugin.instancesOf`, `contributionsOf` or `provide` applied to a type that is not a plugin point or capability |
| K0006 | An API package's version change is smaller than its point changes require (§11) |
| K0007 | A `guard:` clause is not a `@pure` boolean expression over parameters and `in` arguments |
| K0008 | A plugin does not implement every method of a point it lists, or implements a method the point lacks |
| K0009 | A plugin's `contributes:` value is missing for a point it implements, or has the wrong type |
| K0010 | `@since` on a method names a version newer than its point, or is missing on a method added after `major.0` |
| K0011 | A capability parameter value in `requires:` or `optional:` does not have the parameter's type |
| K0012 | Two points or capabilities in one plugin's `implements:`/`requires:` share a qualified name |
| K0101 | (load) A manifest's contributions do not match the point's contributions type |
| K0102 | (load) A grant policy returned parameters wider than the request |
| K0103 | (load) Major version mismatch between plugin and host |
| K0104 | (load) Same point version, different interface hash |

`K01xx` codes are reported by `Std.Plugin` as `PluginError` values and in
`lyric plugin check`, not by the compiler.
