# D150 — Custom source generators end to end: local generator dependencies, X-series diagnostics

**Status:** accepted, implemented

Implements the consumer side of docs/40 (D075) far enough to use a custom
generator from a project, closing docs/65 F-14 (#7834). Supersedes the
G-series generator codes of D075, which collided with the config-block
diagnostics.

## Context

The compiler half of `@generate(Pkg.Name)` existed, but nothing could use it:

- The parser rejected a dotted annotation argument, so `@generate(Acme.Describe)`
  was a P0012 parse error before any generator ran.
- The generator's DLL was looked up at `.lyric/packages/<name>/`, a path
  nothing in the toolchain writes.
- No generator existed in the repository, and nothing in CI ran one.
- Diagnostics were untyped strings with no position; only the first error a
  generator reported was shown, and its warnings were dropped.
- docs/40's G0001–G0008 shared the G prefix with config-block diagnostics
  (G0001, G0004, G0008, G0009, G0010), and G0008 meant two different things.

## Decision

1. **A generator is an ordinary local dependency.** A `path = "..."` or
   `{ workspace = true }` dependency whose manifest declares
   `kind = "source-generator"` is a generator. Before reading any source, the
   CLI (`Lyric.Cli.resolveGenerators`) checks it declares `generate` and
   `main`, builds it with the normal dependency build (stale-checked), and
   hands its DLL to `Lyric.Generator.preprocess`. Nothing is staged by hand.
2. **Generators are always built for dotnet.** A generator runs on the build
   host as `dotnet exec`, whatever the consumer's `--target`, so a JVM or
   native consumer uses the same generator binary.
3. **A generator is never linked.** Generator dependencies, direct or
   transitive, are excluded from restored DLLs, from source folding on JVM
   and native, and from library builds.
4. **Registry and git generators are not supported yet.** `@generate` naming
   one reports X0009 with that reason; they need a restored generator
   artifact, which the restore pipeline does not produce.
5. **Dotted annotation arguments.** The grammar's bare annotation argument
   becomes `IDENT { '.' IDENT }`, parsed as one `ABare` name.
6. **X-series diagnostics.** Generator diagnostics move to their own prefix,
   keeping docs/40's numbers. Each is reported at the `@generate` annotation
   as `file: error[X000n] line:col: message`, and every failing directive in
   a file is reported:
   - X0001 `@generate` on something that is not a record, union or interface;
   - X0002 the named dependency is not `kind = "source-generator"`;
   - X0003 the generator declares no `generate` or no `main`;
   - X0004 the generated code does not parse (checked before splicing, with
     the line within the generated code);
   - X0005 the generator reported a diagnostic: an Error fails the build,
     a Warning or Info is printed as a warning or note, with the generator's
     own code;
   - X0006 a source-generator package is imported;
   - X0007 reserved for the SDK version check (Q-SG-003);
   - X0008 the generator is not declared in `[dependencies]`;
   - X0009 the generator could not be built or run (build failure, not run
     by `dotnet`, non-zero exit, no response, invalid JSON, timeout).
7. **Responses are decoded with `Std.JsonValue`**, not substring matching. The
   per-invocation timeout is 60 s.
8. **`lyric test --manifest` runs generators** like `lyric build`, for both
   library and test sources.

## Consequences

- `examples/generators/` holds a real generator (`Acme.Describe`) and a
  consumer; `scripts/ci/source-generator-e2e.sh` builds and runs the consumer
  on dotnet and JVM in CI.
- Type errors in generated code are still reported against the consumer's
  file, after the comment header naming the generator; only parse errors are
  attributed to the generator (X0004).
- Generators run with the build's privileges (docs/40 §7, Q-SG-005 unchanged).
