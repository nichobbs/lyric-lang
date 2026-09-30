# Enforced package layering: `[layers]`, `@pure`, `@io` (docs/65 U3, D149)

The layer rules of docs/65 §5 are now checked by the compiler, on every
target.

- **Manifest.** `[layers]` names an optional preset (`ui`),
  `[layers.packages]` places project packages by name or pattern (`*` one
  segment, final `**` one or more), and `[layers.rules]` defines or replaces
  layers (`may_import`, `may_not_import`, `async`), inline or as
  sub-tables. Unknown keys are errors. The manifest parser's inline tables
  now keep string arrays.
- **Classes.** A package declares `@pure` or `@io` on its `package` line; a
  function in a `@pure` package may be `@io`. Both reach contract metadata
  (`"purity"`, and `@io` in the function's repr), so a restored package keeps
  them. All stdlib packages (public and kernel, on all three kernel trees)
  and all first-party library packages are classified.
- **Import rules** (new `Lyric.Layers` package, run from the CLI for
  `build`, `test`, `run` and `check` before any backend): Y0001 forbidden
  import, Y0002 unclassified import, Y0004 `async func`, Y0005 `@layer`
  disagreement, Y0006 unknown layer or preset, Y0009 malformed annotation or
  assignment. `import extern` counts as `io`.
- **Type-level rules.** The type checker records calls to `@io` functions
  and protected entries (`ResolvedSignature.isIo`/`isEntry`) and module
  values holding host objects or protected instances; `Lyric.Pipeline`
  reports them (Y0003, Y0008, Y0007) for `@pure` packages and for packages
  whose layer does not allow `io`, with the reason passed per package to
  the MSIL, JVM and native bridges.
- **Example.** `examples/ui-customers` declares the `ui` preset and passes on
  dotnet and JVM; importing `Std.File` from its logic, or its ports from a
  view, fails the build with Y0001.

Tests: `layers_self_test.l` (patterns, the preset, every diagnostic,
custom rules, and the type-level rules through
`Lyric.Pipeline.effectDiagnostics`), `[layers]` cases in
`manifest_self_test.l`, purity round trips in `contract_meta_self_test.l`
and `restored_packages_self_test.l`.
