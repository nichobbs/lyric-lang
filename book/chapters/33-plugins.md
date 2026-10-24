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
running it as WebAssembly, and finally a source generator, which is the
compiler's own plugin point. The language reference covers the same ground in
§15; the design is docs/69 and decision D207.

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
`clang` for native, and the wasi-sdk plus `wasmtime` for wasm. A project with
`[maven]` dependencies cannot be packed for `jvm`.

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

## Diagnostics

The compiler reports plugin declarations it cannot accept as `K0000`-`K0012`;
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

- A trusted in-process mode, plugin signing and a plugin registry (D207).
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
