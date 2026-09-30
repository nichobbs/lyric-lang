# `Std.JsonValue`: the cross-target JSON value model moves into the stdlib (#7832)

`lyric-jsonrpc`'s strict RFC 8259 value model moves unchanged into the
stdlib as `Std.JsonValue` (`lyric-stdlib/std/json_value.l`, D145). Until now
it was the only JSON tree that could be built and written on both managed
targets,
so `lyric-mcp` and `lyric-ui`'s `Ui.Protocol` depended on the JSON-RPC
library just to produce JSON (docs/65 §15, F-12; docs/62 Q-RPC-001).

- It keeps the same types (`JsonValue`, `JsonField`, `JsonParseError`), the
  same functions, the same strictness and the same depth limit.
- It adds `writeValueIndented(v, width)`: one member per line, `width`
  spaces per level, `[]`/`{}` for empty containers, and text that parses
  back to an equal value.
- `JsonRpc.Json` is removed, and its consumers import `Std.JsonValue`:
  `lyric-jsonrpc` (`JsonRpc`, `JsonRpc.Stdio`), `lyric-mcp` and `lyric-ui`.
  `lyric-ui` and `examples/ui-customers` drop their `lyric-jsonrpc`
  dependency.
- `Std.Json`, the dotnet `JsonDocument` cursor, is unchanged.
- The module is appended to `lyric-stdlib/lyric.full.toml` (so existing
  packages' token indices do not move), and `stage-selfhosted-stdlib.sh`
  checks that the bundle carries it.

`lyric-stdlib/tests/json_value_tests.l` is the former
`lyric-jsonrpc/tests/json_tests.l` plus the indented writer: 51 tests, run
in CI on dotnet and on the JVM. `--target native` does not compile it yet:
`Std.Parse` has no native kernel (#7856).

Adding the module to the bundle exposed two compiler bugs, both of which
ignored the calling file's imports when two bundled packages share a name
(`Std.Yaml.getField` / `Std.JsonValue.getField`, and the union case
`JsonValue.JObject`). Both are fixed here:

- `Lyric.Mono`: when same-named imported functions tie on arity and
  argument types, `resolveAmbiguousOverload` now picks the one whose
  package the root file imports (docs/01 §9.2), instead of giving up and
  raising M0004 or defaulting a type argument to `Object`
  (`yaml_tests.l`'s `isNone(getField(v, "y"))`). Imported non-generic
  functions now carry their origin package, as generic ones already did
  (`pipeAddNonGenericFuncs`). Covered by two new `mono_self_test.l` cases.
- JVM codegen: a name the file binds to an extern type no longer resolves
  to a bundle-global union case or record of the same name from a package
  it does not import (`bundleCtorFallback`). `extern type JObject =
  "java.lang.Object"` in `auto_ffi_jvm_self_test.l` had been resolved to
  `JsonValue$JObject`.

