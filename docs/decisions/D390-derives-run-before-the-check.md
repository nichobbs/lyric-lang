# D390 - Derives run before the checker, with generated spans mapped to the deriving type (docs/70 phase 3b slice S1, #8613)

**Status:** shipped. First slice of D370.

## Context

D370 moves declaration expansion ahead of body checking. Derives
(`@derive(Equals|Hash|Show|Ord)`, `@generate(Json)`) are the smaller of the two
passes and read only syntax (the file's items and the imported packages'
type items), so they go first.

## Decision

1. `pipeCheckAndMono` runs `deriveFileWithImports` on its input before
   `pipeCheckFront`; the later derive after the `?` lowering is removed. The
   checker, the checked desugarings, the contract elaborator, `?` lowering and
   mono see the derived functions as ordinary items of the package.
   `pipeCheckFront` called alone (`lyric prove`'s front, the JVM bridge's
   check-only path) is unchanged and does not derive.
2. New package `Lyric.Expand` (`lyric-compiler/lyric/expand/expand.l`):
   - `generatedSpanBase(file)`: the first offset beyond every span of the
     package. A generated span takes `base + 2 * origins.count`, so spans are
     unique with no mutable counter (a compiler source cannot use `ref record`
     under the seed) and start and end differ (the checker skips a site whose
     span ends at or before its start);
   - `respanGenerated(file, items, base, cause, origins)`: a fresh span on each
     item, function, expression, statement and pattern of a batch of generated
     items. The span takes the line and column of the causing declaration (a
     line of 0 would mean "no source" and the checker records no site for such a
     node), and `origins` maps its key to the cause's span;
   - `relocateDiagnostics(origins, diags)`: an error in generated code is
     reported at the cause with "(in code generated for this declaration)"
     appended; a warning there is dropped.
3. `DiagSink` carries `origins` (default empty). `gateTo` and `reportTo` apply
   `relocateDiagnostics`, so every gate of the middle end relocates in one
   place (the answer to where warning suppression lives: the sink).
   `deriveFileWithImports` takes the map as a defaulted parameter, so other
   callers are unchanged.
4. Each type's derived items are respanned with that type's item span as the
   cause.

## Consequences

- Derived functions are type-checked, mode-checked and elaborated like user
  code, and the checker's callee sites cover the calls in them.
- A derived body the checker rejects is now a compile error at the `@derive`.
  The census (every `lyric.toml` built for dotnet with the old and new
  compiler; the stdlib, compiler and benchmark programs that use derives, run
  on both targets) found three classes, fixed here: `Hash` derives call the
  `hashCode` backend intrinsic, which had no signature (now
  `hashCode[T](x: T): Int`, a polymorphic builtin like `toString`);
  `@generate(Json)` decoders name `Std.JsonHost.JsonElement` and need
  `import Std.JsonHost`, which the derive now injects as it does `Std.Json`;
  and `@derive(Ord)` on a field of an enum type, which already warned D0001
  ("comparison will fail") and is now the error T0033 at the `@derive`. No
  source in the repository does the last.
- Known and not caused here: a union `@derive(Hash)` fails JVM verification
  (`Shape$hash`, operand stack underflow) with the seed compiler too.
- `derives_self_test.l` covers unique spans, origins and relocation.
