# Custom source generators run end to end (#7834)

A project can now use a custom `@generate(Pkg.Name)` generator with no manual
staging (docs/40, D150), closing docs/65 F-14.

- **Resolution.** A `path` or `workspace = true` dependency whose manifest
  says `kind = "source-generator"` is a generator. `Lyric.Cli.resolveGenerators`
  checks it declares `generate` and `main` (X0003) and builds it for dotnet,
  whatever the consumer's target, before any source is read; its DLL goes to
  `Lyric.Generator.preprocess` in a `GeneratorSet`. Generator dependencies are
  never linked, folded or built as libraries.
- **Parser.** A bare annotation argument may be a qualified name, so
  `@generate(Acme.Describe)` parses (it was a P0012 error).
- **Diagnostics.** The generator codes move from G (shared with config
  blocks) to X, keeping docs/40's numbers: X0001–X0006, X0008, X0009. Each
  is reported at the annotation with file, line and column, every failing
  directive in a file is reported, and a generator's warnings and notes are
  printed. Generated code is parse-checked before splicing (X0004).
- **Response decoding** uses `Std.JsonValue`; the per-invocation timeout is
  60 s.
- **`lyric test --manifest`** runs generators over library and test sources.

Tests: `generator/generator_self_test.l` (22 cases, including each X code
and response decoding); `examples/generators/` (a real `Acme.Describe`
generator and a consumer) built and run by
`scripts/ci/source-generator-e2e.sh` on dotnet and JVM in CI, checking the
generated output and the generator's warning for a union; native verified
locally.
