# Chapter 33: Plugins

Lyric has no reflection, so a program cannot load a DLL or a JAR it has never
seen and call into it by name. Plugins are how an application accepts code that
was built separately, possibly by someone else, at run time: the application
declares typed extension points, a plugin implements them, and the two talk to
each other over a small JSON-RPC protocol while the plugin runs in its own
process. The compiler generates everything on both sides of that conversation
from ordinary interfaces and records, so neither side writes any JSON.

This chapter builds a small note-taking extension point end to end: the API
package, a plugin, a host that loads it, packing the plugin into an artifact,
running it as WebAssembly, loading a trusted plugin into the host's own
process, and finally a source generator, which is the compiler's own plugin
point. The language reference covers the same ground in §15; the design is
docs/69 and decisions D207 and D231.

## The pieces

| Piece | Who writes it | What it holds |
|---|---|---|
| API package | the application author | plugin points (the host calls the plugin), capabilities (the plugin calls the host), and the types they carry |
| Plugin | anyone | a `@plugin` record that implements points and holds clients for the capabilities it uses |
| Host | the application author | a `Std.Plugin` `PluginHost` that loads plugin directories and calls them |

Both the host and the plugin depend on the API package. The compiler pass
`Lyric.PluginExpand` reads the plugin annotations and appends the generated code
to each package before type checking, on every target.

## Declaring a point and its capabilities

The API package is a normal package. A capability is a `pub interface` marked
`@capability`; a plugin point is a `pub interface` marked `@plugin_point`:

```lyric
package Notes.Api

import Std.Core
import Std.Collections

pub record Note {
  title: String
  body: List[Byte]
  tags: Map[String, Int]
  pinned: Option[Bool]
}

pub union Change {
  case Added(note: Note)
  case Removed(title: String)
}

pub enum Level {
  case Low
  case High
}

pub exposed record StoreGrant {
  prefixes: List[String]
}

pub func grantAllows(prefixes: in List[String], title: in String): Bool {
  for p in prefixes {
    if title.startsWith(p) {
      return true
    }
  }
  false
}

@capability(grant = StoreGrant)
pub interface Store {
  func load(title: in String): Result[Note, String]
    requires: grantAllows(grant.prefixes, title)
}

@capability
pub interface Log {
  func log(level: in Level, line: in String): Result[Unit, String]
}

pub record NotesContributions {
  commands: List[String]
}

@plugin_point(version = "1.0", contributions = NotesContributions, allows(Store, Log))
pub interface NoteTool {
  func summarize(note: in Note): Result[String, Level]
  func fetch(title: in String): Result[Change, String]
  func logged(line: in String): Result[Bool, String]
}
```

A few rules shape these declarations:

- Every method returns `Result[T, E]` and takes only `in` parameters. The
  error type `E` is the method's own error; failures of the boundary itself
  (a timeout, a crashed plugin) arrive separately, as you will see below.
- Everything a method mentions must be able to cross the boundary as JSON:
  primitives, `String`, `Option`, `Result`, `List`, `slice`,
  `Map[String, T]`, tuples, and the records, unions and enums of this package.
  `List[Byte]` travels as base64. Anything else (a function, an interface, a
  generic record, `Option[Option[T]]`) is diagnostic `K0001`.
- `version = "1.0"` is the point's `major.minor` version. A plugin built
  against version 1.0 keeps working with a host that offers 1.3: a minor
  version may add methods and optional fields, and a plugin reports the
  methods it implements when it starts.
- `contributions = NotesContributions` is static data every plugin of this
  point declares, which the host can read without calling the plugin (menu
  entries, command names).
- `allows(Store, Log)` lists the capabilities a plugin of this point may ask
  for.

**Grants.** `Store` takes a grant: when the host lets a plugin use it, it says
how much, as a `StoreGrant`. The `requires:` clause on `load` names `grant`, so
it is a guard. The compiler moves it out of the interface into the generated
host-side server and checks it before the host's own `load` runs; a plugin that
asks for a title outside its granted prefixes gets `Denied` without the host's
code ever seeing the call.

## Writing a plugin

A plugin is a record with `@plugin`, plus an `impl` for each point it lists:

```lyric
package Notes.Summary

import Std.Core
import Std.Collections
import Std.Plugin
import Notes.Api

@plugin(id = "acme.notes-summary", version = "1.2.0", publisher = "acme", implements(NoteTool))
pub ref record SummaryPlugin {
  store: StoreClient
  log: Option[LogClient]
  var calls: Int = 0
}

impl NoteTool for SummaryPlugin {
  func summarize(note: in Note): Result[String, Level] {
    if note.title == "" {
      return Err(error = Level.High)
    }
    Ok(value = note.title + ":" + note.body.count.toString() + ":" + note.tags.count.toString())
  }

  func fetch(title: in String): Result[Change, String] {
    match store.load(title) {
      case Ok(n) -> Ok(value = Change.Added(note = n))
      case Err(CallError.App(e)) -> Err(error = "app: " + e)
      case Err(CallError.Boundary(b)) -> Err(error = "boundary: " + boundaryErrorMessage(b))
    }
  }

  func logged(line: in String): Result[Bool, String] {
    match log {
      case None -> Ok(value = false)
      case Some(l) -> match l.log(Level.Low, line) {
        case Ok(_) -> Ok(value = true)
        case Err(CallError.App(e)) -> Err(error = "app: " + e)
        case Err(CallError.Boundary(b)) -> Err(error = "boundary: " + boundaryErrorMessage(b))
      }
    }
  }
}

@plugin_contributions(NoteTool)
func summaryContributions(): NotesContributions {
  val cmds: List[String] = newList()
  cmds.add("notes.summarize")
  cmds.add("notes.fetch")
  NotesContributions(commands = cmds)
}

@plugin_request(Store)
func storeRequest(): StoreGrant {
  val prefixes: List[String] = newList()
  prefixes.add("notes/")
  prefixes.add("shared/")
  StoreGrant(prefixes = prefixes)
}
```

The record's fields say what the plugin needs:

- `store: StoreClient` requests the `Store` capability. `StoreClient` is
  generated from `Store`; its `load` sends the call to the host and returns
  `Result[Note, CallError[String]]`.
- `log: Option[LogClient]` requests `Log` optionally. If the host does not
  grant it, the field is `None`.
- `calls` is the plugin's own state, so it needs a default (`K0010`
  otherwise).

`CallError[E]` is either `App(error)`, the error the host's method returned, or
`Boundary(error)`, a `BoundaryError` such as `Denied`, `Timeout` or `Crashed`.
`boundaryErrorMessage` renders one. Those names come from `Std.Plugin`, which is
why the plugin imports it.

`@plugin_contributions(NoteTool)` supplies the point's contributions, and
`@plugin_request(Store)` the grant the plugin asks for. The package has no
`main`: the compiler generates one that serves the protocol, answers the
manifest probe, and constructs `SummaryPlugin` with a client for each granted
capability.

Build the plugin like any other program, for any target:

```sh
lyric build --manifest notes-summary/lyric.toml --target dotnet
```

## Hosting plugins

The host implements the capabilities it offers, decides what to grant, and loads
plugin directories. Implementing a capability is an ordinary `impl`:

```lyric
package Notes.App

import Std.Core
import Std.Collections
import Std.JsonValue
import Std.Plugin
import Notes.Api

pub ref record NoteStore {
  var loads: Int
}

impl Store for NoteStore {
  func load(title: in String): Result[Note, String] {
    self.loads = self.loads + 1
    val body: List[Byte] = newList()
    val tags: Map[String, Int] = newMap()
    Ok(value = Note(title = title, body = body, tags = tags, pinned = None))
  }
}

pub ref record LineLog {
  var lines: List[String]
}

impl Log for LineLog {
  func log(level: in Level, line: in String): Result[Unit, String] {
    self.lines.add(line)
    Ok(value = ())
  }
}
```

A `GrantPolicy` sees each plugin's manifest (what it implements and what it
requests) and returns the grants. This one narrows `Store` to `notes/` and
grants `Log` in full:

```lyric
pub record NotesPolicy {
}

impl GrantPolicy for NotesPolicy {
  func decide(manifest: in PluginManifest): GrantDecision {
    val prefixes: List[String] = newList()
    prefixes.add("notes/")
    val grants: List[GrantedCapability] = newList()
    grants.add(
      GrantedCapability(
        capability = storeCapabilityInfo().id,
        grant = Some(value = pluginEncodeStoreGrant(StoreGrant(prefixes = prefixes)))
      )
    )
    grants.add(GrantedCapability(capability = logCapabilityInfo().id, grant = None))
    GrantDecision(allow = true, reason = "", grants = grants)
  }
}
```

A grant may narrow a request but never widen it: every list in a grant must be
a subset of the requested list, and any other field must equal the request. A
wider grant refuses the plugin with load issue `K0102`. `GrantAllRequested()`
is the policy that grants exactly what each plugin asks for.

Now the host itself:

```lyric
func main(): Int {
  val providers: List[CapabilityProvider] = newList()
  providers.add(storeProvider(NoteStore(loads = 0)))
  providers.add(logProvider(LineLog(lines = newList())))
  val host = newPluginHost(
    PluginHostConfig(points = [noteToolPointInfo()], providers = providers, policy = NotesPolicy())
  )
  for issue in discoverPlugins(host, ["plugins"]) {
    println("not loaded: " + pluginLoadIssueMessage(issue))
  }
  for issue in noteToolContributionIssues(host) {
    println("bad contributions: " + pluginLoadIssueMessage(issue))
  }
  for c in noteToolContributions(host) {
    println(c.pluginId + " contributes " + c.value.commands.count.toString() + " commands")
  }
  for r in noteToolRemotes(host) {
    match r.fetch("notes/today") {
      case Ok(Change.Added(n)) -> println("fetched " + n.title)
      case Ok(Change.Removed(t)) -> println("removed " + t)
      case Err(CallError.App(e)) -> println("plugin error: " + e)
      case Err(CallError.Boundary(b)) -> println("boundary error: " + boundaryErrorMessage(b))
    }
  }
  stopAllPlugins(host)
  0
}
```

Everything with a point or capability name in it is generated in the API
package: `storeProvider` wraps a `Store` implementation as a
`CapabilityProvider` and enforces the guard, `noteToolPointInfo` describes the
point, `noteToolContributions` decodes each plugin's contributions, and
`noteToolRemotes` returns a `NoteToolRemote` per loaded plugin, whose methods
mirror `NoteTool` with `CallError` errors.

`discoverPlugins` reads every `<id>-<version>/plugin.json` under the given
directories. A plugin that implements none of the host's points, was built
against another major version of a point (`K0103`), or is refused by the
policy is reported as a `PluginLoadIssue` and not loaded. Nothing starts until
the first call: the host then launches the plugin, sends it the grants, and
serves its capability calls while it waits for the answer, so `fetch` can call
back into `NoteStore.load` from inside the plugin.

`PluginHostConfig` also sets the call timeout (`callTimeoutMs`, 60 seconds by
default), how often a crashed plugin is restarted (`maxRestarts`, 3, with an
exponential backoff), the shutdown grace period, and whether to prefer a wasm
payload. `stopPlugin` and `revokeCapability` act on one plugin while the host
runs. A `PluginHost` is synchronous and should be used from one thread.

## Packing a plugin

A host reads plugin directories, not projects. `lyric plugin pack` builds the
plugin for each requested target, reads its manifest by running it with
`--lyric-plugin-manifest`, and writes the artifact:

```sh
lyric plugin pack --manifest notes-summary/lyric.toml --targets dotnet,jvm,native -o plugins
lyric plugin check plugins/acme.notes-summary-1.2.0
```

The result is a directory:

```
plugins/acme.notes-summary-1.2.0/
  plugin.json
  ...the dotnet, jvm and native payloads
```

`plugin.json` lists the plugin's id, version, publisher, the points it
implements with their versions and contributions, the capabilities it requests,
and one payload per target. A host picks the payload it can run: a `dotnet`
host can run a `jvm` or native plugin and the other way round, as long as the
runtime is installed. `lyric plugin check` validates a directory and prints
each problem it finds.

Each target needs its toolchain when packing: the .NET SDK, a JDK 21 or later,
`clang` for native, the wasi-sdk plus `wasmtime` for wasm, and for a component
also `wasm-tools` and the preview1 reactor adapter. A project with
`[maven]` dependencies cannot be packed for `jvm`.

### Signing a plugin

A publisher signs an artifact so a host can tell who made it and that no file
was changed or added since (D248). Make a key once, and keep the secret half
somewhere only your build can read:

```sh
lyric plugin keygen -o acme          # acme.key (secret) and acme.pub
lyric plugin pack --manifest notes-summary/lyric.toml --sign-key acme.key -o plugins
lyric plugin verify plugins/acme.notes-summary-1.2.0 --key acme.pub
```

`--sign-key` writes `plugin.sig` into the artifact: a SHA-256 of every file in
the directory and an Ed25519 signature over them, the plugin's id and version.
`lyric plugin sign <dir>` signs an artifact that is already packed, such as one
built with a generated SDK; in CI, put the secret key's text in
`LYRIC_PLUGIN_SIGNING_KEY` and leave out `--key`. File names in a signed
artifact are printable ASCII, and links are not allowed. `lyric plugin verify`
checks a signature the way a host will: a changed or added file is `K0108`,
an unknown key `K0106`, a manifest naming another publisher `K0109`.

## Running a plugin as WebAssembly

A plugin from someone you do not trust should not run as an ordinary process.
A process payload (dotnet, JVM or native) is arbitrary code running as your
user: grants and guards limit what it can ask the host for, not what it can do
by itself, such as reading files or opening sockets. Pack it for wasm as well:

```sh
WASI_SDK_PATH=/opt/wasi-sdk lyric plugin pack --manifest notes-summary/lyric.toml --targets dotnet,wasm -o plugins
```

The wasm payload is the same plugin compiled with
`--target native --triple wasm32-wasi` (Chapter 32). A host with `preferWasm`
(the default) runs it whenever `wasmtime` is available (`$LYRIC_WASMTIME`, else
`PATH`), as `wasmtime run` with a memory ceiling (`wasmMaxMemoryBytes`, 256 MiB
by default) and no directories, environment variables or network. The module
speaks the same protocol on its stdin and stdout, so the host code above does
not change, but the plugin's only way to reach anything outside itself is a
capability call, which the host's grants and guards control.

### As a WebAssembly component

A wasm payload still runs as a separate `wasmtime` process and talks JSON over
its stdin and stdout. A **component** payload skips both: it is the plugin
compiled with `--shape component` (Chapter 32), whose point methods are
WIT-typed exports and whose capability calls are WIT-typed host imports, so a
host can instantiate it inside its own process.

```sh
WASI_SDK_PATH=/opt/wasi-sdk WASM_TOOLS=/opt/wasm-tools/wasm-tools \
LYRIC_WASI_ADAPTER=/opt/wasi_snapshot_preview1.reactor.wasm \
  lyric plugin pack --manifest notes-summary/lyric.toml --targets dotnet,component -o plugins
```

The plugin's source does not change. For the notes plugin, the component's WIT
has the exported interface `lyric:notes-summary/notes-summary` with
`plugin-describe`, `plugin-attach`, `plugin-methods` and one function per point
method (`note-tool-summarize: func(note: note) -> result<string, level>`), and
one imported interface per capability it requests
(`notes-api-store`, with `load: func(title: string) -> result<note,
store-call-error-wire>`). The `store-call-error-wire` variant carries either
the capability's own error (`app`) or a boundary error (`denied`, `revoked`,
`timeout`, ...), which `StoreClient` turns back into `CallError` for your code.

Two things are stricter than in process mode. Names must read back from their
WIT spelling: `customer_id` and `getURL` become `customer-id` and `get-url`,
which a host reads as `customerId` and `getUrl`, so the compiler refuses them
(`K0013`); write `customerId` and `getUrl`. And a few boundary types have no WIT
form: `UInt`, `ULong`, `Char`, `slice[T]`, `JsonValue`, a union case with
several fields, and recursive types (`K0014`). Both checks run only when you
build a component, so the same plugin still packs for the other targets.

### Running a component in the host's process

A wasm module under `wasmtime run` is still a process per plugin, and a call
that never returns keeps that process busy after the host gives up on it. A
component runs inside the host instead. A host opts in by giving its
configuration the in-process runtime from `Std.PluginWasm`:

```lyric
import Std.Plugin
import Std.PluginWasm

val host = newPluginHost(
  PluginHostConfig(
    points = [noteToolPointInfo()],
    providers = [storeProvider(store), logProvider(log)],
    policy = NotesPolicy(),
    componentRuntime = Some(value = inProcessWasmRuntime())
  )
)
```

Nothing else in the host changes: the generated remotes, the grant policy and
the capability providers work as before, and a plugin that ships a component
runs as one whenever `hasInProcessWasm()` is true, ahead of a wasm payload
(a host without the runtime ignores component payloads and picks among the
others). Each plugin gets its own
store with no directories, environment or network (stderr is inherited, for
its log), its memory is capped at `wasmMaxMemoryBytes`, and every call is
bounded by `callTimeoutMs`. That bound is real: wasmtime's epoch interruption
stops a component in the middle of a loop that never yields, the call returns
`Timeout`, and the next call starts the plugin afresh. A trap (a panic, an
out-of-memory) is `Crashed`, with the same restart backoff and `maxRestarts` as
a process plugin.

The runtime is a small C library, `lyric-rt/src/lyric_wasmhost.c`, over the
wasmtime C API. It loads libwasmtime 49 when it is first used, from
`$LYRIC_WASMTIME_LIB`, next to itself, or the loader path
(`scripts/ci/fetch-wasmtime-capi.sh` downloads the pinned release). A native
host links the runtime from `lyric_rt.a`; a dotnet or JVM host loads
`liblyric_wasmhost.so` (built by `make -C lyric-rt wasmhost`) from
`$LYRIC_WASMHOST_LIB`, from beside the program (on .NET), or from the loader
path. When either library is missing, `hasInProcessWasm()` is false,
`inProcessWasmUnavailableReason()` says which, and the host simply chooses
another payload.

## Trusted plugins in the host's process

A process boundary costs every call a round trip through a pipe. For a plugin
you wrote yourself, or one from a team whose code you would link into the
application anyway, the host can load it into its own process instead. The
plugin's source does not change; only the host decides, and it has to decide
twice. The host gives its configuration a loader:

```lyric
import Std.Plugin.Trusted

val host = newPluginHost(
  PluginHostConfig(
    points = [noteToolPointInfo()],
    providers = providers,
    policy = FirstPartyPolicy(),
    trustedLoader = Some(value = trustedPluginLoader())
  )
)
```

and its grant policy marks the plugins it trusts:

```lyric
impl GrantPolicy for FirstPartyPolicy {
  func decide(manifest: in PluginManifest): GrantDecision {
    val decision = grantAllRequested(manifest)
    GrantDecision(
      allow = decision.allow,
      reason = decision.reason,
      grants = decision.grants,
      trusted = manifest.publisher == "acme"
    )
  }
}
```

The plugin also has to ship a trusted payload for the host's runtime. Pack it
with `--trusted`:

```sh
lyric plugin pack --manifest notes-summary/lyric.toml --targets dotnet,jvm,native --trusted -o plugins
```

For dotnet and the JVM the trusted payload is the plugin's ordinary assembly or
jar, listed a second time with `"mode": "trusted"`; for native, pack builds a
shared library with `lyric build --target native --shape plugin`. A plugin the
policy trusts and that has such a payload is loaded into the host: the dotnet
host gives it an `AssemblyLoadContext`, the JVM host a class loader, the native
host `dlopen`s the library. Every other plugin runs exactly as before, from its
process or wasm payload, so one policy can trust some plugins and sandbox the
rest.

Nothing else changes for either side. The generated remote still calls the
plugin's generated dispatcher, the plugin's capability clients still reach the
host's providers through the grants and the guards, and `revokeCapability`
still takes effect at once; the calls are simply direct. On the notes example a
`summarize` call takes a few microseconds in process against a few hundred over
a pipe.

What you give up is isolation. A trusted plugin can read any file the host can,
and if it crashes, hangs or calls `exit`, the host goes with it. On dotnet and
the JVM a panic inside a plugin method is caught and the call fails with
`ContractViolated`; on native, which has no unwinding, any panic in a trusted
plugin ends the host. There are no restarts and no call timeouts. Stopping a
trusted plugin forgets its state, and the next call starts a fresh one, but its
code stays loaded: trusted plugins are never unloaded, so a plugin you need to
replace while the host runs should stay out of process.

A few limits follow from loading code into a running program. A Native AOT
dotnet host or a GraalVM native-image JVM host cannot load code, and native
hosts load plugins on Linux and macOS only; on those hosts the loader says why
(`unavailableReason()`) and every plugin runs out of process. A native plugin
library must be built by the same Lyric release as the host: both carry a
fingerprint of the release and of the boundary packages, and a mismatch is
refused. A JVM plugin's own packages must not share names with the host's.

## Protocol plugins: hosting a language server

Some plugins already speak a protocol of their own. A language server speaks
LSP, and there is no reason to re-describe its messages as Lyric methods. A
*protocol point* declares the protocol and the capabilities, and nothing
else:

```lyric
pub exposed record LanguageContributions {
  languageIds: List[String]
  fileGlobs: List[String]
}

@capability(grant = WorkspaceEditGrant)
pub interface WorkspaceEdit {
  func applyEdit(edit: in DocumentEdit): Result[Bool, String]
    requires: uriWithin(edit.uri, grant.roots)
}

@protocol_point(protocol = "lsp/3.17", version = "1.0", contributions = LanguageContributions, allows(WorkspaceEdit))
pub interface LanguageServer {}
```

A protocol plugin is an ordinary program in any language, with a
hand-written `plugin.json` that `lyric plugin check` validates. It implements
that one point, because its stdin and stdout carry its own protocol.

The host opens a supervised session and speaks the protocol over the
session's process:

```lyric
val session = match openLanguageServerSession(host, pluginId) {
  case Ok(s) -> s
  case Err(b) -> return fail(boundaryErrorMessage(b))
}
val proc = match protocolProcess(session) { case Ok(p) -> p; case Err(_) -> return 1 }
var peer = newPeer(newContentLengthTransportOverProcess(proc), client)
```

If the server exits, the next `protocolProcess` restarts it with the same
backoff and limit as any other plugin and increments `session.generation`; a
client that sees the generation change sends `initialize` again.
`closeProtocolSession` stops it without counting a crash.

The capabilities still mean something. When the server sends
`workspace/applyEdit`, the client calls the capability *as the plugin*:

```lyric
val workspace = WorkspaceEditAs(host = client.host, pluginId = client.pluginId)
match workspace.applyEdit(DocumentEdit(uri = uri, edits = edits)) {
  case Ok(done) -> applied(done, "")
  case Err(e) -> applied(false, describe(e))
}
```

`WorkspaceEditAs` is generated for every capability. It applies the plugin's
grant, any revocation and the `requires:` guard before the host's
implementation runs, so a server granted `file:///workspace/` cannot edit a
document anywhere else. `examples/plugins/lsp` holds the whole thing: the API,
a small TODO language server and an editor that hosts it.

## Plugins in other languages

`lyric plugin sdk` generates an SDK for an API package in C#, Java or
TypeScript, so a plugin can be written in any of them:

```sh
lyric plugin sdk --api notes-api/lyric.toml --lang typescript -o sdk-ts
```

The SDK holds the boundary types and their codecs, a process-mode server,
capability clients, a manifest builder and a JSON Schema of the boundary. A
plugin written against it speaks the same protocol as a Lyric plugin, so the
host cannot tell the difference.

## A source generator is a plugin

Source generators (Chapter 30) are the compiler's own plugin point. The API
package is `Lyric.GeneratorSdk`: the point `SourceGenerator` and the capability
`ProjectRead`. A generator is a `kind = "source-generator"` package with a
`@plugin` record:

```lyric
@runtime_checked
@io
package Acme.Describe

import Std.Core
import Std.Collections
import Lyric.GeneratorSdk

pub func generateSource(req: in GeneratorRequest): GeneratorResponse {
  val td = req.typeDescriptor
  var fields = ""
  var i = 0
  while i < td.fields.length {
    if i > 0 {
      fields = fields + ", "
    }
    fields = fields + td.fields[i].name + ": " + td.fields[i].fieldType.name
    i += 1
  }
  val src = "pub func " + td.name + ".describe(v: in " + td.name + "): String {\n  \"" + td.name + " { " + fields +
    " }\"\n}\n"
  val noImports: List[String] = newList()
  val diags: List[GeneratorDiagnostic] = newList()
  GeneratorResponse(lyricSource = src, additionalImports = noImports.toArray(), diagnostics = diags.toArray())
}

@plugin(id = "acme.describe", version = "0.1.0", publisher = "acme", implements(SourceGenerator))
pub record DescribePlugin {}

impl SourceGenerator for DescribePlugin {
  func generate(req: in GeneratorRequest): Result[GeneratorResponse, GeneratorError] {
    Ok(value = generateSource(req))
  }
}
```

Keeping the work in a plain function (`generateSource` here) lets the tests
call it directly. The compiler is the host: it builds the generator for dotnet,
reads its manifest, starts it once per build and calls `generate` for each
`@generate(Acme.Describe)` annotation. A generator that needs a project file
(a schema, say) adds a `files: ProjectReadClient` field, requests a
`ProjectReadGrant(roots = ...)` with `@plugin_request(ProjectRead)`, and calls
`files.readText("schemas/order.json")`; the compiler grants what the generator
requests and refuses any path outside the granted roots, an absolute path, or
one with `..` in it.

## A widget for lyric-ui

`lyric-ui` (chapter 31) has its own plugin point, `Ui.Plugins.WidgetPlugin`. A
widget plugin depends on two small libraries, the point (`Ui.Plugins`) and
the builders for its view (`Ui.Plugins.Build`). Both need only the standard
library, so a widget plugin builds for every target:

```toml
[dependencies]
"Ui.Plugins"       = { path = "../lyric-ui/plugins" }
"Ui.Plugins.Build" = { path = "../lyric-ui/plugins/build" }
```

The host calls the plugin three ways:

- `init` for a new placement, with its configuration;
- `update` with the state and the message an interaction produced;
- `configure` to show the state again under a new configuration, or when the
  user presses Retry.

Each call returns a `WidgetStep`: the next state, as JSON the host keeps and
sends back next time, the view, and outcomes for the screen. The view is a
`WidgetTree`, built with `Ui.Plugins.Build`, which has the same builders as
`Ui.Widgets`. Where a `Ui.Widgets` builder takes a message, these take a
message string, and the text of an input arrives as the message's `data`:

```lyric
package Acme.Stars

import Ui.Plugins
import Ui.Plugins.Build as B

@plugin(id = "acme.stars", version = "1.0.0", publisher = "acme", implements(WidgetPlugin))
pub record Stars {}

func starsView(value: in Int): WidgetTree {
  val row: List[WidgetTree] = newList()
  for i in [1, 2, 3, 4, 5] {
    row.add(B.keyed("star-" + i.toString(), B.button(if i <= value then "*" else "-", "set:" + i.toString())))
  }
  B.row(row)
}

impl WidgetPlugin for Stars {
  func init(req: in WidgetInit): Result[WidgetStep, WidgetError] =
    Ok(value = WidgetStep(state = JInt(value = 0i64), view = starsView(0), outcomes = newList()))
  func update(req: in WidgetUpdate): Result[WidgetStep, WidgetError] { ... }     // "set:4" -> state 4, outcome "rated"
  func configure(req: in WidgetConfigure): Result[WidgetStep, WidgetError] { ... }
}

@plugin_contributions(WidgetPlugin)
func contributions(): WidgetContributions { ... }   // WidgetDecl(name = "stars", title, description, configSchema, defaultConfig)
```

A widget plugin keeps no state of its own and has no capabilities: it
computes from what the host sends. Anything else it wants, it asks the screen
for through an outcome.

The host shows only the properties the built-in widgets use. It keeps a
link's `href` only for an application path or an `http`/`https` URL, and it
refuses a view of more than 2000 nodes.

`examples/plugins/ui-widgets/widgets` is a complete widget plugin with a
rating and a tag list, and `scripts/ci/ui-widget-plugins-e2e.sh` runs it with
real plugin processes.

## Diagnostics

The compiler reports plugin declarations it cannot accept as `K0000`-`K0014`;
appendix B has the table. The ones you will meet first:

| Code | Typical cause |
|---|---|
| `K0001` | a method or field type that cannot be encoded as JSON |
| `K0003` | a plugin requests a capability its points do not allow |
| `K0004` | a point method that does not return `Result[T, E]` |
| `K0008` | `implements(P)` without an `impl P for ...`, or the other way round |
| `K0010` | a plugin record field with no default that is not a capability client |
| `K0012` | a plugin package that declares its own `main` |

## What is not supported yet

- Hosts do not check signatures yet: `lyric plugin sign` and `verify` exist,
  and load-time verification and per-application catalogues follow (D248).
  Unloading a trusted plugin is not supported (D231).
- A widget plugin's point (`WidgetPlugin` 1.0) allows no capabilities.
- A process or wasm-module plugin that ignores the cancellation of a timed-out
  call keeps its CPU until the host stops it (#8465); only a component plugin
  is stopped at the timeout.
- The in-process component runtime is not available on Windows hosts yet (#8542).
- A `ULong` above 2^63 travels as a JSON floating-point number and can lose
  precision.
- The language server does not run the plugin pass, so the generated names
  (`StoreClient`, `noteToolRemotes`) are unknown in the editor even though the
  build accepts them.
- The C#, Java and TypeScript SDK runtimes ignore `$/cancelRequest` for a call
  that is already running.
- On `--target native` a panic ends the process: a native plugin that panics is
  restarted by the host, and a native host whose capability provider panics
  exits.
