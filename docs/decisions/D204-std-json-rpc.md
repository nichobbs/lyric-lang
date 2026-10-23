# D204 — Plugins (docs/69) accepted as the direction; `Std.JsonRpc` moves into the stdlib

**Status:** accepted, implemented (items 2–5)

Backs `docs/69-plugins.md` and resolves its Q-PLG-003.

## Context

`docs/69` proposes a plugin architecture without reflection: applications
declare typed plugin points and parameterised capabilities, and untrusted
plugins run in a separate process (JSON-RPC over stdio) or as WebAssembly
components. Generators (docs/40) are the first plugin point.

Process mode needs a JSON-RPC peer in `Std.Plugin`, and the compiler itself is
the first host. The only JSON-RPC peer in the tree was the `lyric-jsonrpc`
ecosystem library (`JsonRpc`, `JsonRpc.Stdio`), and neither the stdlib nor the
compiler may depend on an ecosystem library. D145 already moved that
library's JSON model into the stdlib as `Std.JsonValue` for the same kind of
reason.

## Decision

1. **docs/69 is the design direction for plugins.** Its hosting modes, its
   order of work (process mode, then wasm mode, then trusted in-process) and
   generators as the first plugin point stand. The language surface
   (`plugin_point`, `capability`, `plugin`) waits on Q-PLG-005 (the
   declaration syntax), which this entry does not settle.
2. **The JSON-RPC peer and its stdio framings move unchanged into the stdlib**
   as `Std.JsonRpc` (`lyric-stdlib/std/json_rpc.l`) and `Std.JsonRpc.Stdio`
   (`lyric-stdlib/std/json_rpc_stdio.l`). The types, functions, constants and
   `@stable` markers are the same; only the package names change.
3. **`lyric-jsonrpc` is removed, not aliased**, as D145 removed
   `JsonRpc.Json`. Its one in-repo consumer, `lyric-mcp`, moves in the same
   change and no longer has any Lyric package dependency. `publish.yml` no
   longer packs `Lyric.JsonRpc`; versions already on nuget.org stay there
   but get no further releases.
4. **Both packages are bundled into `Lyric.Stdlib.dll`** (Tier 11 of
   `lyric-stdlib/lyric.full.toml`, appended last so earlier packages' token
   indices do not move), as D111 requires of a stdlib package that declares
   types.
5. **A consumer on `--target dotnet` sees a stdlib package's literal
   constants and its `impl` blocks.** Until now `Msil.Bridge` exposed only a
   stdlib package's types and `pub func`s, so `Std.JsonValue.defaultMaxDepth`
   was an unknown name on dotnet but not on the JVM or native (which compile
   the stdlib from source), and nothing outside the stdlib could use an
   `impl` the stdlib declares. `Std.JsonRpc` is the first stdlib module that
   needs both: its error codes are `pub val`s, and `NdjsonTransport` and
   `ContentLengthTransport` are passed where an `RpcTransport` is expected.
   - A `pub val` or `pub const` declared `Int` (or untyped) with an integer
     literal initializer, a negated one included, is inlined at every use.
     That is the same surface contract metadata carries for restored
     packages (`Lyric.ContractMeta.reprForInlinableVal`): a literal constant
     has no initialised field in its own assembly, because its package
     inlines it. Any other module-level value stays unreachable from another
     assembly, for restored packages and the stdlib alike.
   - A bare read of a constant resolves through the reading package's
     imports, as the type checker resolves it (docs/01 §9.2), instead of
     taking whichever package registered the name first. A package's own
     module-level value of that name always wins. This also corrects reads
     between packages of one build, which previously took the first
     registered constant of that name.
   - An `impl I for R` gives `R` the methods of `I` (with `I` resolved in
     the impl's package, so it may come from another stdlib package), as a
     restored package's `impl` does. The type checker sees the impl's head
     without its method bodies.

## Consequences

- `lyric-stdlib/tests/json_rpc_tests.l` and `json_rpc_stdio_tests.l` (the
  former `lyric-jsonrpc` suites) run on dotnet and on the JVM in the stdlib
  test steps of CI. `scripts/ci/jsonrpc-content-length-locale-c-test.sh`
  builds its echo program against the stdlib alone.
- `lyric-mcp` imports `Std.JsonRpc` and `Std.JsonRpc.Stdio`.
- `docs/69` Q-PLG-003 is resolved. The rest of P0 (Q-PLG-005) and P1 remain.
- The production stdio transports read stdin through `Std.Console`'s
  `StdinReader`, which has no native implementation yet
  (`_kernel_native/console_host.l`); that gap predates this move.
