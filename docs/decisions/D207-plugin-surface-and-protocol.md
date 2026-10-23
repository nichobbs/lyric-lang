# D207 — Plugins: annotation surface, generated code, wire protocol and `Std.Plugin`

**Status:** accepted

Resolves docs/69 Q-PLG-005 (declaration syntax) and fixes the contracts that
docs/69 phases P1 to P5 are built against. Q-PLG-001, 002, 004, 006, 007,
008, 009 and 010 are resolved or deferred as listed in "Decisions on the other
open questions". Builds on D204.

## Context

D204 accepted docs/69 as the direction and moved the JSON-RPC peer into the
stdlib. docs/69 §4 sketched new keywords (`plugin_point`, `capability`,
`plugin`, `handle`, `protocol_point`). Reserving them would break existing
code: `handle` alone is a field name in 89 places in the stdlib and the
ecosystem libraries. The work also has to be split between several people
(or agents) at once, so the generated code, the wire protocol and the
runtime API must be fixed before anyone writes them.

## Decision 1: no new keywords; annotations on existing items

Every declaration is an existing item with an annotation. The lexer, parser
and formatter are unchanged.

| docs/69 sketch | D207 form |
|---|---|
| `pub capability C { ... }` | `@capability pub interface C { ... }` |
| `pub capability C(roots: ...)` | `@capability(grant = CGrant) pub interface C`, with `pub exposed record CGrant { roots: ... }` |
| `guard: expr` on a capability method | a `requires:` clause on the method that may name `grant`, the granted `CGrant` |
| `pub plugin_point P version "1.2" { allows: A, B; contributions: K }` | `@plugin_point(version = "1.2", contributions = K, allows(A, B)) pub interface P` |
| `pub protocol_point L { protocol: ..., transport: stdio }` | `@protocol_point(protocol = "lsp/3.17", contributions = K, allows(A)) pub interface L {}` |
| `pub handle H` | `@plugin_handle pub type H = Long` |
| `pub plugin X { implements: ...; requires: ...; optional: ...; contributes: ... }` | see below |

A plugin is a record and ordinary `impl` blocks:

```lyric
@plugin(id = "acme.git-tools", version = "0.4.1", publisher = "acme", implements(EditorExtension, MenuProvider))
pub record GitTools {
  workspace: WorkspaceReadClient           // a required capability
  edit: Option[WorkspaceEditClient]        // an optional capability
  notify: NotifyClient
  var commandsRun: Int = 0                 // plugin state: needs a default
}

impl EditorExtension for GitTools { ... }
impl MenuProvider for GitTools { ... }

@plugin_contributions(EditorExtension)
func gitContributions(): EditorContributions = EditorContributions(commands = ...)

@plugin_request(WorkspaceRead)
func workspaceRequest(): WorkspaceReadGrant = WorkspaceReadGrant(roots = ["${workspace}"])
```

- A field whose type is a generated `<C>Client` requests capability `C`; an
  `Option[<C>Client]` field requests it optionally. Every other field needs a
  default.
- A point that declares `contributions` needs exactly one
  `@plugin_contributions(P)` function returning its contributions type. A
  requested capability that declares a `grant` needs exactly one
  `@plugin_request(C)` function returning the grant type: its value is the
  request shown to the user.
- `${workspace}` and similar placeholders are not interpreted by the
  compiler; the host's grant policy gives them meaning.

The checker-facing rules (docs/69 §5 and §18) keep their meaning. Diagnostics
`K0001`-`K0012` are reported by the expansion pass (Decision 2) with these
meanings:

| Code | Meaning |
|---|---|
| K0001 | A plugin point, capability, grant, contributions or handle type mentions a type that cannot cross a boundary |
| K0002 | `allows(...)` names an interface that is not a `@capability` |
| K0003 | A plugin requests a capability that one of its points does not allow |
| K0004 | A point or capability method does not return `Result[T, E]`, or is generic |
| K0005 | `@plugin_point`/`@capability`/`@protocol_point` on something that is not a `pub interface`, `@plugin_handle` on something that is not a `pub type H = Long`, or `@plugin` on something that is not a `pub record` |
| K0006 | Malformed annotation: a missing or non-`major.minor` `version`, a missing `id`, an unknown argument |
| K0007 | A capability `requires:` clause names something other than `grant`, its own parameters and functions |
| K0008 | `implements(...)` names an interface the plugin record has no `impl` for, or a plugin record implements a point not listed |
| K0009 | A missing, duplicated or wrongly typed `@plugin_contributions` / `@plugin_request` function |
| K0010 | A plugin record field without a default that is not a capability client |
| K0011 | A `@protocol_point` interface with members |
| K0012 | A package with a `@plugin` record also declares `main`, or declares two `@plugin` records |

`K0101`-`K0104` stay runtime (`PluginError`) codes as docs/69 §18 has them.

The docs/69 `@since("1.2")` marker is dropped: the plugin reports the methods
it implements during the handshake (Decision 3), and a call to one it does not
implement is `Unsupported`. A minor version may add methods; a plugin built
against an older minor simply does not list them.

Methods may be `async` or not. The wire is asynchronous either way; requiring
`async` bought nothing and `docs/69` §4.2's rule is relaxed.

## Decision 2: a desugaring pass generates ordinary Lyric

`Lyric.PluginExpand` (`lyric-compiler/lyric/plugin_expand/`) runs in
`Lyric.Pipeline.pipeExpandAndRewriteCollect`, right after `WireExpand`, on
every target. It reads the annotations above, reports `K00xx`, and appends
ordinary items, so every backend compiles plugins with no backend change. It
injects `import Std.Core`, `import Std.Collections`, `import Std.JsonValue`,
`import Std.JsonRpc` and `import Std.Plugin` when it generates anything
(deduplicated, as `Lyric.Stubbable` does). It strips `requires:` clauses that
name `grant` from capability interface methods (they move to the generated
server) and removes the plugin annotations it consumed.

In a package declaring boundary types, points or capabilities:

| Generated | For |
|---|---|
| `pub func pluginEncode<T>(v: in T): JsonValue` and `pub func pluginDecode<T>(j: in JsonValue): Result[T, String]` | each record, exposed record, union, enum and `@plugin_handle` type the package declares that a point, capability, grant or contributions type reaches |
| `pub record <C>Client { conn: PluginConnection }` with one method per `C` method returning `Result[T, CallError[E]]` | each `@capability C` (the plugin side) |
| `pub record <C>Server { impl: C }` and `impl CapabilityProvider for <C>Server` | each `@capability C` (the host side): decodes the grant, checks the moved `requires:` clauses, then calls `impl` |
| `pub func <c>Provider(impl: in C): CapabilityProvider` | each `@capability C` |
| `pub record <P>Remote { conn: PluginConnection }` with one method per `P` method returning `Result[T, CallError[E]]` | each `@plugin_point P` (the host side) |
| `pub func <p>Remotes(host: in PluginHost): List[<P>Remote]` | each `@plugin_point P`: one per catalogued plugin implementing `P`, started on first call |
| `pub record <P>Contribution { pluginId: String, value: K }` and `pub func <p>Contributions(host: in PluginHost): List[<P>Contribution]` | each `@plugin_point P` with contributions `K` |
| `pub func <p>PointInfo(): PluginPointInfo` | each `@plugin_point P` and `@protocol_point P` |
| `pub func <c>CapabilityInfo(): CapabilityInfo` | each `@capability C` |
| `pub func pluginDispatch<P>(impl: in P, method: in String, params: in Option[JsonValue]): Result[JsonValue, RpcError]` | each `@plugin_point P` (the plugin side) |

`<p>`/`<c>` is the interface name with its first letter lower-cased. Encoders
and decoders for a type from another package call that package's generated
`pluginEncode<T>`/`pluginDecode<T>`, so a boundary type must be declared in a
package compiled through this pass (a source-available package or a restored
Lyric package built by this compiler).

In a package with a `@plugin` record `R`:

| Generated | Role |
|---|---|
| `record <R>Server` and `impl PluginServer for <R>Server` | `describe()` builds the manifest, `attach(...)` constructs `R` with a client per granted capability, `dispatch(...)` routes `<Pkg>.<P>/<method>` to `pluginDispatch<P>` |
| `func main(): Int = runPlugin(<R>Server(...))` | the plugin executable's entry point |

## Decision 3: wire protocol, version 1

JSON-RPC 2.0 over the child's stdin and stdout, one message per line
(`Std.JsonRpc.Stdio.newNdjsonTransport`). Stderr is the plugin's log.

- **Manifest probe.** A plugin executable run with the single argument
  `--lyric-plugin-manifest` writes its manifest (Decision 5) to stdout as one
  JSON document and exits 0, without reading stdin. `lyric plugin pack` uses
  this on the author's machine; a host never runs it, it reads `plugin.json`.
- **Handshake.** The host's first message is the request `plugin/hello` with
  params `{"protocol": 1, "points": {"<Pkg>.<P>": "<major>.<minor>", ...},
  "grants": [{"capability": "<Pkg>.<C>", "grant": <grant JSON or null>}, ...]}`.
  The plugin answers `{"protocol": 1, "id": "<plugin id>", "points":
  {"<Pkg>.<P>": {"version": "<major>.<minor>", "methods": ["<name>", ...]}}}`.
  A plugin that cannot satisfy a required capability answers with error
  `-32041` (`NotGranted`). Nothing else may be sent before the handshake
  completes.
- **Point calls** (host to plugin): method `<Pkg>.<P>/<method>`, params an
  object keyed by parameter name, result `{"ok": <T>}` or `{"err": <E>}`.
- **Capability calls** (plugin to host): method `cap/<Pkg>.<C>/<method>`,
  same params and result shapes.
- **Boundary errors** are JSON-RPC error responses, in the implementation-
  defined server range: `-32001` timeout (`Std.JsonRpc.requestTimedOut`),
  `-32040` `Denied` (a `requires:` failed or the capability is not granted),
  `-32041` `NotGranted`, `-32042` `Stale` handle, `-32043` `Unsupported`
  method, `-32044` `Revoked`, `-32045` `ContractViolated`, `-32046`
  `Protocol` (malformed params or result). The standard codes keep their
  JSON-RPC meanings.
- **Cancellation.** `$/cancelRequest` with `{"id": <request id>}`, as in LSP.
- **Shutdown.** The host sends the notification `plugin/shutdown`, closes the
  child's stdin, and kills it if it has not exited after the grace period.

## Decision 4: value encoding

| Lyric | JSON |
|---|---|
| `Bool` | `true`/`false` |
| `Byte`, `Int`, `Long`, `UInt`, `ULong` | number (a JSON reader that loses integers above 2^53, such as JavaScript's, must parse integers exactly; the generated TypeScript SDK does) |
| `Float`, `Double` | number |
| `Char` | one-character string |
| `String` | string |
| `Unit` | `null` |
| `Option[T]` | `null` or the `T` encoding (`Option[Option[T]]` is K0001) |
| `Result[T, E]` | `{"ok": T}` or `{"err": E}` |
| `List[T]`, `slice[T]` (`T` not `Byte`) | array |
| `List[Byte]`, `slice[Byte]` | base64 string |
| `Map[String, T]` | object |
| tuple | array |
| record / exposed record | object keyed by field name, in declaration order |
| union | `{"case": "<Case>", "<field>": ...}` |
| enum | the case name as a string |
| `@plugin_handle` type | number |
| `Std.JsonValue.JsonValue` | itself |

Decoders reject a missing required field, an unknown union case or enum
name, and a wrong JSON kind with `Protocol`; they ignore unknown object
members, so a minor version may add optional fields.

## Decision 5: manifests and artifacts

`plugin.json`, as docs/69 §7, with `"schema": 1`, `id`, `version`,
`publisher`, `points` (each `{"point", "version", "contributions"}`),
`capabilities` (`required`/`optional` lists of `{"name", "grant"}`) and
`payloads`. A payload is one of:

- `{"mode": "process", "runtime": "dotnet", "command": ["dotnet", "exec", "<dll>"]}`
- `{"mode": "process", "runtime": "jvm", "command": ["java", "-jar", "<jar>"]}`
- `{"mode": "process", "os": "<linux|macos|windows>", "arch": "<x86_64|aarch64>", "command": ["<exe>"]}`
- `{"mode": "wasm", "module": "<file>.wasm"}`

Paths are relative to the plugin directory. **A plugin artifact is a
directory** (`<id>-<version>/plugin.json` plus its payload files), not the
zip docs/69 sketched: a host, the compiler and every SDK can read a directory
with what they already have, and an archive adds an extractor to every host
for no protection that signing (deferred, below) would not give. A zip is a
transport format any packaging tool can add later.

`lyric plugin pack --manifest <lyric.toml> [--targets dotnet,jvm,native,wasm] -o <dir>`
builds each requested payload, runs one of them with `--lyric-plugin-manifest`,
adds the `payloads` list and writes the directory. `lyric plugin check <dir>`
validates a directory (schema, files present, versions well formed).

## Decision 6: wasm mode runs the same protocol under `wasmtime run`

A wasm payload is the plugin built with `--target native --triple wasm32-wasi`
(the plain WASI command, docs/35 W2), speaking Decision 3's protocol on its
stdin and stdout. The host starts it with `wasmtime run`, a memory ceiling,
and no `--dir`, `--env` or network, so the module's only route to anything is
a capability call to the host; the host's call timeout bounds each call. This is docs/69 §9.3's route 3
with the WASI command in place of a WIT-typed component: one protocol, one
generated dispatcher and one host code path for both modes, and wasmtime's own
release binary instead of an embedding. `wasmtime` is found on `PATH` or at
`$LYRIC_WASMTIME`. A host prefers a wasm payload whenever it has one and
`wasmtime` is available; the policy can require it for untrusted publishers.
The WIT-typed component and in-process embedding (docs/69 §9.2, §9.3 routes 1
and 2) remain the later optimisation Q-PLG-001 describes.

## Decision 7: the `Std.Plugin` API

`lyric-stdlib/std/plugin.l` (`Std.Plugin`), with process work in the existing
`Std.Process` piped kernels. On the host side:

```lyric
pub union BoundaryError { case Denied(reason: String) case NotGranted(capability: String)
  case Stale case Unsupported(method: String) case Revoked(capability: String)
  case ContractViolated(detail: String) case Timeout(timeoutMs: Int)
  case Crashed(detail: String) case Protocol(detail: String) }
pub union CallError[E] { case App(error: E) case Boundary(error: BoundaryError) }

pub record PluginPointInfo { id: String, version: String, allows: List[String], hasContributions: Bool, protocol: Option[String] }
pub record CapabilityInfo { id: String, hasGrant: Bool }
pub interface CapabilityProvider {
  func info(): CapabilityInfo
  func serve(method: in String, params: in Option[JsonValue], grant: in Option[JsonValue]): Result[JsonValue, RpcError]
}
pub interface GrantPolicy { func decide(manifest: in PluginManifest): GrantDecision }
pub record GrantDecision { allow: Bool, reason: String, grants: List[GrantedCapability] }
pub record GrantedCapability { capability: String, grant: Option[JsonValue] }

pub record PluginHostConfig { points: List[PluginPointInfo], providers: List[CapabilityProvider],
  policy: GrantPolicy, callTimeoutMs: Int = 60000, startTimeoutMs: Int = 10000,
  maxRestarts: Int = 3, preferWasm: Bool = true }
pub func newPluginHost(config: in PluginHostConfig): PluginHost
pub func discoverPlugins(host: in PluginHost, dirs: in List[String]): List[PluginLoadIssue]
pub func pluginManifests(host: in PluginHost): List[PluginManifest]
pub func connectionsFor(host: in PluginHost, pointId: in String): List[PluginConnection]
pub func contributionsFor(host: in PluginHost, pointId: in String): List[PluginContributionJson]
pub func callPlugin(conn: in PluginConnection, method: in String, params: in JsonValue): Result[JsonValue, BoundaryError]
pub func stopPlugin(host: in PluginHost, id: in String): Unit
pub func stopAllPlugins(host: in PluginHost): Unit
pub func revokeCapability(host: in PluginHost, id: in String, capability: in String): Unit
pub func openProtocolPlugin(host: in PluginHost, pointId: in String, pluginId: in String): Result[PipedProcess, BoundaryError]
```

`callPlugin` returns the JSON-RPC `result` (the `{"ok"}`/`{"err"}` object);
the generated `<P>Remote` methods split it into `App` and the success value.
On the plugin side:

```lyric
pub interface PluginServer {
  func describe(): JsonValue
  func attach(conn: in PluginConnection, grants: in List[GrantedCapability]): Result[Unit, BoundaryError]
  func pointMethods(): List[PluginPointMethods]
  func dispatch(method: in String, params: in Option[JsonValue]): Result[JsonValue, RpcError]
}
pub func runPlugin(server: in PluginServer): Int
pub func callHost(conn: in PluginConnection, method: in String, params: in JsonValue): Result[JsonValue, BoundaryError]
```

The method is `attach`, not `bind`: `bind` is a keyword (wire blocks).

Exact field lists of `PluginManifest`, `PluginConnection`,
`PluginContributionJson`, `PluginLoadIssue` and `PluginPointMethods` are the
runtime's to define; the generated code uses only the names above.

## Decisions on the other open questions

- **Q-PLG-001** (wasmtime component C API): not needed for v1 (Decision 6).
- **Q-PLG-002** (OS restrictions in process mode): v1 applies none; the
  isolation for an untrusted publisher is wasm mode, which a policy can
  require. Linux Landlock and network namespaces are a later addition to the
  process launcher.
- **Q-PLG-004** (grant versus request): a grant may narrow a request only
  by the policy returning the value it wants; the runtime checks that every
  list-valued grant field is a subset of the requested list and refuses a
  wider grant with `K0102`. A grant type with non-list fields is compared for
  equality.
- **Q-PLG-006** (signing) and **Q-PLG-007** (registry): deferred. A host
  loads directories its owner put on its plugin path; a signature scheme and a
  registry are separate work.
- **Q-PLG-008** (high-frequency calls): no rule in v1; batched point methods
  are the guidance.
- **Q-PLG-009** (unloading in trusted mode) and trusted in-process mode
  (docs/69 §10): deferred. Every v1 plugin is out of process, so stopping it
  unloads it.
- **Q-PLG-010** (plugins declaring points): still deferred.

## Consequences

- No lexer, parser or formatter change; `Lyric.PluginExpand` is one new
  front-end pass that all three backends share.
- `Std.Plugin` is new stdlib surface on dotnet and the JVM, and the plugin
  side runs on native and wasm32-wasi too.
- Generators (docs/40) become the first plugin point. Because the compiler is
  built by a stage-0 seed that predates `Lyric.PluginExpand`, the compiler's
  host side uses `Std.Plugin`'s dynamic API (`callPlugin`) instead of
  generated `<P>Remote` code; generator packages use the generated plugin
  side like any other plugin.
- docs/69 §4 is rewritten to these forms.
