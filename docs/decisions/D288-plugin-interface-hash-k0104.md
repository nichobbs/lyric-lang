# D288 - Plugin interface hash and `K0104` (#8486)

**Status:** shipped (points and capabilities; see Limits)

## Context

docs/69 §18 reserved `K0104`: "the plugin was built against a different shape of
the point than the host". The handshake compared `major.minor` versions only
(`K0103` on a major mismatch), so two builds with the same version and different
method signatures failed only when a call did not decode.

## Decision

1. `Lyric.PluginExpand` computes a SHA-256 for each point, protocol point and
   capability from a canonical text: kind, qualified name, version, protocol,
   contributions and grant types, each method as `name(mode param: type, ...):
   result`, and the declarations of the boundary types it reaches in its own
   package, sorted and spelled by the formatter. Layout, comments and contracts
   do not change it. Types of other packages take part by written name.
2. The hash is emitted as `interfaceHash` in `<p>PointInfo`, `<c>CapabilityInfo`,
   the generated `describe()` manifest (per point and per capability request)
   and the point's entry in the `plugin/hello` answer
   (`PluginPointMethods.interfaceHash`). All the new record fields default to
   `""`, which is never compared, so hand-written manifests and the C#, Java and
   TypeScript SDK runtimes keep working.
3. `registerPlugin` refuses a plugin whose manifest hash differs from the host's
   for a matching version with `PluginIssueKind.InterfaceHashMismatch`
   (`K0104`, naming the point or capability). A plugin whose manifest carried no
   hash is checked at `plugin/hello`, which fails the start with a `K0104`
   message.
4. `lyric plugin check <dir> --api <dir|file.l|lyric.toml>` compares the
   manifest's hashes with those of the API package (`PluginExpand.interfaceHashes`).

## Limits

The hash covers a type of another package by its written name only, so a change
inside a boundary type declared in a different package is not seen. The
`plugin/hello` check covers points; capabilities are checked at load through the
manifest. Component payloads are checked through their manifest, not their hello.
