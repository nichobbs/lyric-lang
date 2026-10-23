# `Std.JsonRpc` in the stdlib; stdlib constants and impls on dotnet (D204)

- `lyric-jsonrpc`'s `JsonRpc` and `JsonRpc.Stdio` are now the stdlib's `Std.JsonRpc` and `Std.JsonRpc.Stdio`
  (`lyric-stdlib/std/json_rpc.l`, `json_rpc_stdio.l`), bundled as Tier 11 of `lyric.full.toml`. The library is
  removed; `lyric-mcp` imports the stdlib packages and has no Lyric dependencies left.
- `Msil.Bridge`/`Msil.Codegen`: on `--target dotnet` a consumer now sees a stdlib package's integer-literal
  `pub val`/`pub const` (inlined at each use) and its `impl` blocks (the record gets the interface's methods; the
  type checker sees the impl head). `Std.JsonValue.defaultMaxDepth` was `T0020 unknown name` on dotnet before.
  A bare constant read resolves through the reader's imports, and a package's own non-literal `val` shadows an
  imported constant; it used to take the first constant registered under the name.
- Tests: `lyric-stdlib/tests/json_rpc_tests.l` (31) and `json_rpc_stdio_tests.l` (38) pass on dotnet and the JVM;
  `json_value_tests.l` gains a bare and qualified constant read (52); `msil_project_bridge_self_test.l` gains
  import-aware constant resolution and a stdlib constant and impl used from a consumer (76). `lyric-mcp` passes
  32/36/7 on both targets; `scripts/ci/jsonrpc-content-length-locale-c-test.sh` passes on both, built against the
  stdlib alone.
- CI: the library's matrix entry and JVM suite are gone; the stdlib JSON steps run the three suites on dotnet and
  the JVM. `publish.yml` no longer packs `Lyric.JsonRpc`.
- Docs: D204 (accepts docs/69 as the plugin direction, resolves Q-PLG-003), docs/69, docs/62, book chapter 12
  and appendix B, `lyric-mcp/README.md`, CLAUDE.md. Open: docs/69 Q-PLG-005, then phase P1.
