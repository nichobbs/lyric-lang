# D145 — `Std.JsonValue`: the cross-target JSON value model moves into the stdlib

**Status:** accepted, implemented

Resolves #7832 and docs/62 Q-RPC-001; docs/65 §15 finding F-12.

## Context

The stdlib's `Std.Json` is a read-only cursor over the .NET `JsonDocument`:
dotnet-only, and it can neither build nor serialise a document.
`Std.Yaml.parseJson` is cross-target, but it is lenient (YAML 1.2 is a JSON
superset) and has no writer.

The one strict, writable, cross-target JSON model in the tree was
`JsonRpc.Json` in `lyric-jsonrpc`, written for JSON-RPC framing (docs/62 §2).
`lyric-mcp` and `lyric-ui` (`Ui.Protocol`) depended on `lyric-jsonrpc` just
to build and write JSON, and any other library that needed JSON would have
had to do the same.

## Decision

1. The model moves unchanged into the stdlib as **`Std.JsonValue`**
   (`lyric-stdlib/std/json_value.l`). It keeps the same types (`JsonValue`,
   `JsonField`, `JsonParseError`), the same functions, the same strictness
   and the same depth limit.
2. It gains `writeValueIndented(v, width)`: one member per line, `width`
   spaces per level, and text that parses back to an equal value.
3. `JsonRpc.Json` is removed, not aliased. The package was
   `@stable(since = "0.1")` inside a library at version 0.1.0 with only
   in-repo consumers, and all of them move in the same change. A forwarding
   package would keep two names for one model indefinitely.
4. `Std.Json` keeps its current API. It is the dotnet fast path for reading
   large documents through the BCL; rebuilding it on `Std.JsonValue` would
   change its behaviour for no consumer's benefit.

## Name

`Std.JsonValue` rather than `Std.Json2` or a v2 of `Std.Json`. The module is
a value model, not a replacement for the cursor: both are useful and they
coexist. Its exported names (`parseValue`, `writeValue`, `isNull`,
`getField`, ...) overlap `Std.Yaml`'s accessor names by design, so a file
that imports both whole must qualify them (docs/01 §9.2, T0123).

## Consequences

- `lyric-jsonrpc` ships `JsonRpc` and `JsonRpc.Stdio` over `Std.JsonValue`.
- `lyric-ui` and `examples/ui-customers` no longer depend on `lyric-jsonrpc`.
- `lyric-mcp` imports `Std.JsonValue` directly.
- `lyric-stdlib/tests/json_value_tests.l` (the former
  `lyric-jsonrpc/tests/json_tests.l`, plus the indented writer) runs on
  dotnet and on the JVM.
- `--target native` cannot compile the module yet: it depends on
  `Std.Parse`, which has no native kernel. That gap predates this move and
  is tracked in #7856.
