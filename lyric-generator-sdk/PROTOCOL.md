# Lyric generator protocol

A custom source generator is a plugin implementing the `SourceGenerator` plugin
point (version 3.0) of `Lyric.GeneratorSdk`, and the compiler is its host. The
exchange is the plugin wire protocol of D207 (docs/69 §9.1): JSON-RPC 2.0 over
the generator process's stdin and stdout, one message per line. This document
describes that exchange as the compiler uses it, and the JSON of the request and
response.

A generator written in Lyric never handles any of this itself:
`Lyric.PluginExpand` generates its `main`, its manifest, the dispatcher and the
codecs from the `@plugin` record (README.md). The document is for reading
traces, for testing, and for anyone writing a generator by hand.

## 1. Lifecycle

1. **Build.** The compiler builds the generator package (a `path` or
   `workspace = true` dependency with `kind = "source-generator"`) for dotnet,
   whatever the consumer's `--target`.
2. **Manifest probe.** On the first `@generate` naming the generator, the
   compiler runs

   ```
   dotnet exec <Generator>.dll --lyric-plugin-manifest
   ```

   The generator prints its manifest as one JSON document and exits 0 without
   reading stdin. The manifest must list the point
   `Lyric.GeneratorSdk.SourceGenerator` with a `3.x` version:

   ```json
   {"schema":1,"id":"acme.describe","version":"0.1.0","publisher":"acme",
    "points":[{"point":"Lyric.GeneratorSdk.SourceGenerator","version":"3.0","contributions":null}],
    "capabilities":{"required":[],"optional":[]}}
   ```

   A generator that requests `ProjectRead` lists it with the value of its
   `@plugin_request(ProjectRead)` function, for example
   `{"name":"Lyric.GeneratorSdk.ProjectRead","grant":{"roots":["schemas"]}}`.
3. **Start.** The compiler registers the generator with the payload
   `dotnet exec <Generator>.dll`, grants exactly the capabilities it requests,
   and starts it on the first call. One process serves every annotated type
   of the build; the compiler stops it when the build ends.
4. **Handshake.** The compiler's first message:

   ```json
   {"jsonrpc":"2.0","id":1,"method":"plugin/hello","params":{
     "protocol":1,
     "points":{"Lyric.GeneratorSdk.SourceGenerator":"3.0"},
     "grants":[{"capability":"Lyric.GeneratorSdk.ProjectRead","grant":{"roots":["schemas"]}}]}}
   ```

   `grants` is empty when the generator requests nothing. The generator
   answers:

   ```json
   {"jsonrpc":"2.0","id":1,"result":{"protocol":1,"id":"acme.describe",
     "points":{"Lyric.GeneratorSdk.SourceGenerator":{"version":"3.0","methods":["generate"]}}}}
   ```

5. **Calls.** One request per annotated type (§2), and capability calls from
   the generator while a request is in progress (§4).
6. **Shutdown.** The notification `plugin/shutdown`, then the compiler closes
   the generator's stdin, and kills it if it has not exited within two
   seconds.

Stdout belongs to the protocol. A generator logs to stderr.

## 2. The `generate` call

```json
{"jsonrpc":"2.0","id":2,"method":"Lyric.GeneratorSdk.SourceGenerator/generate",
 "params":{"req": <GeneratorRequest>}}
```

The result is `{"ok": <GeneratorResponse>}`, or `{"err": <GeneratorError>}`
when the generator refuses the request outright:

```json
{"jsonrpc":"2.0","id":2,"result":{"ok":{"lyricSource":"...","additionalImports":[],"diagnostics":[]}}}
{"jsonrpc":"2.0","id":2,"result":{"err":{"message":"unsupported request"}}}
```

A problem with the annotated type belongs in the response's `diagnostics`, not
in `err`.

## 3. Encoding

Values follow D207 Decision 4:

| Lyric | JSON |
|---|---|
| `String` | string |
| `Bool` | `true` / `false` |
| `Int` | number |
| `slice[T]`, `List[T]` | array |
| `Option[T]` | `null` or the value; a decoder also accepts the member being absent |
| record | object keyed by field name |
| enum | the case name as a string |

Decoders reject a missing required member, an unknown enum case and a wrong
JSON kind, and ignore members they do not know. A field with a default in the
Lyric record (such as `TypeDescriptor.cases`) is still required on the wire;
the compiler always sends it.

### 3.1 `GeneratorRequest`

As the compiler writes it (members in this order; the order carries no
meaning):

```json
{
  "generatorArg": "Acme.Describe",
  "packageName": "Acme.App",
  "sourceFile": "src/app.l",
  "typeDescriptor": {
    "kind": "Record",
    "name": "Order",
    "packageName": "Acme.App",
    "typeParams": [],
    "fields": [
      {"name": "id", "fieldType": {"kind": "Primitive", "name": "Int", "typeArgs": []},
       "isPublic": true, "annotations": []},
      {"name": "note", "fieldType": {"kind": "OptionType", "name": "Option[String]", "typeArgs": ["String"]},
       "isPublic": true, "annotations": [{"name": "label", "args": ["\"Note\""]}],
       "defaultSource": "None"}
    ],
    "annotations": [{"name": "generate", "args": ["Acme.Describe"]}],
    "cases": [],
    "invariants": [{"source": "id > 0", "message": null, "line": 7, "column": 3}]
  },
  "declarations": [
    {"name": "Status", "kind": "DeclaredEnum", "underlying": null, "range": null,
     "cases": [{"name": "Open", "annotations": [], "fields": []}]},
    {"name": "Qty", "kind": "DeclaredDistinct", "underlying": "Int",
     "range": {"min": "0", "max": "100", "maxInclusive": true}, "cases": []}
  ]
}
```

- `typeDescriptor.kind`: `Record`, `ExposedRecord`, `Union`, `Interface`,
  `Opaque` or `Enum`.
- `fieldType.kind`: `Primitive`, `Slice`, `OptionType`, `ResultType`, `Named`
  or `Generic`; `typeArgs` holds the inner type names as source text.
- `defaultSource` is present only when the field has a default (its source
  text); the decoder reads its absence as `None`.
- A union's or enum's `cases` each have `name`, `annotations` and `fields`; a
  positional union field has the name `""`. An enum case has no fields.
- An invariant's `message` is its `@message("...")`, or `null`.
- `declarations` lists the enum, distinct and alias declarations of the same
  file that the annotated type's source names; `kind` is `DeclaredEnum`,
  `DeclaredDistinct` or `DeclaredAlias`, `range` is `null` unless the
  distinct type has one, and a range bound that is open is `null`.
- Annotation arguments are source text: `@label("Name")` has the argument
  `"\"Name\""`.

### 3.2 `GeneratorResponse`

```json
{
  "lyricSource": "pub func Order.describe(v: in Order): String {\n  \"Order { id: Int }\"\n}\n",
  "additionalImports": ["import Std.Json"],
  "diagnostics": [
    {"severity": "Warning", "message": "Acme.Describe describes records only", "code": "AD001"},
    {"severity": "Info", "message": "nothing to do", "code": null}
  ]
}
```

- `lyricSource` holds complete Lyric items. The compiler checks that it parses
  (X0004) and appends it to the source file after a comment line naming the
  generator.
- Each `additionalImports` entry must be exactly one `import <QualifiedName>`
  or `import extern <QualifiedName>` statement, optionally with
  `as <Identifier>`. Anything else (a second statement, a newline, a
  malformed name) fails the response (X0009): the entries are spliced into the
  consumer's source.
- `severity` is `Error`, `Warning` or `Info`. Each diagnostic is reported under
  X0005 with its own `code`; an `Error` fails the build and the generated code
  for that type is not used.

### 3.3 `GeneratorError`

```json
{"message": "why the request could not be handled"}
```

The compiler reports it as X0009.

## 4. The `ProjectRead` capability

A generator that holds a `ProjectReadClient` calls

```json
{"jsonrpc":"2.0","id":7,"method":"cap/Lyric.GeneratorSdk.ProjectRead/readText","params":{"path":"schemas/order.json"}}
```

and gets `{"ok": "<file text>"}`, or `{"err": "cannot read 'schemas/order.json'"}`
when the file cannot be read. The path is relative to the consuming project's
directory (the one holding its `lyric.toml`). It is denied, with JSON-RPC error
`-32040` before anything is read, unless it is inside one of the granted
`roots` (`"."` is the whole project) and is relative, `/`-separated and free of
empty, `.` and `..` segments, backslashes and colons: the rule of
`projectPathWithin` in `Lyric.GeneratorSdk`, which the compiler applies to the
request.

## 5. Errors and limits

| Situation | Reported as |
|---|---|
| The manifest probe fails, times out or prints an invalid manifest | X0009 |
| The manifest does not implement `Lyric.GeneratorSdk.SourceGenerator` | X0009 |
| The generator was built against another major version of the point | X0009 |
| The process crashes, or its pipes fail | X0009; a crashed generator is not restarted |
| A call runs longer than 60 seconds | X0009 (the call is cancelled with `$/cancelRequest`) |
| `{"err": ...}` or a malformed response | X0009 |
| Generated code that does not parse | X0004 |
| A diagnostic the generator returned | X0005 |

Boundary errors use the D207 codes: `-32001` timeout, `-32040` denied,
`-32041` not granted, `-32043` unsupported method, `-32046` malformed params
or result.

## 6. Versioning

The request and response are versioned with the `SourceGenerator` point. A
generator built against `3.x` runs under a compiler offering `3.y`: a newer
minor version may add methods (a generator that does not list one in the
handshake is never sent it) and optional members (older decoders ignore
them). A different major version is refused when the generator is loaded.
The `schemaVersion` member of the stdin/stdout protocol (schemas 1 and 2) no
longer exists.
