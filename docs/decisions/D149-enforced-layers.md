# D149 — Enforced layers and package classes (`[layers]`, `@pure`, `@io`)

**Status:** accepted, implemented

Implements docs/65 §5 (phase U3) and D138's Q-UI-003. The language
reference is docs/01 §9.4.

## Context

docs/65 splits a screen into domain, ports, logic, effects and view
packages, and D137 decided that the split is enforced by the compiler
rather than by convention. D138 added two package-level purity rules
(Y0007, Y0008) instead of effect inference. None of it existed: a logic
package could import `Std.File` or call `Std.Time.now()` and nothing
objected.

## Decision

1. **Package classes.** A package declares `@pure` or `@io` on its
   `package` line. A function in a `@pure` package may be marked `@io`; it
   is the package's declared I/O surface. The class is written to the
   contract metadata (`"purity"`, only when set, so an unclassified
   package's contract is unchanged), and a function's `@io` rides in its
   contract repr, so both survive compilation. A package rebuilt from
   metadata gets its class back as a source annotation.
2. **Every stdlib and first-party library package is classified.**
   Computation-only packages and host helpers are `@pure` (for example
   `Std.Core`, `Std.Collections`, `Std.String`, `Std.Json`, `Std.Path`,
   `Std.HttpEngine`, `Forms`, `Ui.Core`, `Validation`, `Proto`); anything
   that touches the environment is `@io`. `Std.Time` and `Std.Uuid` are
   `@pure` with `@io` on `now`, `nowEpochMillis`, `monotonicNanos`,
   `sleepMillis` and `newUuid`. Where a library package's purity was in
   doubt it is `@io`: a wrong `@io` only restricts, a wrong `@pure` would be
   unsound.
3. **`[layers]` manifest table.** `preset`, `[layers.packages]` (package
   name or pattern to layer) and `[layers.rules]` (inline tables or
   `[layers.rules.<name>]` sub-tables with `may_import`, `may_not_import`,
   `async`). `*` matches one dotted segment and a final `**` one or more.
   Unknown keys are errors, so a misspelt rule cannot silently weaken the
   layering. `@layer("x")` in source assigns a layer the manifest does not.
4. **Pattern precedence.** The most specific matching assignment wins;
   equally specific assignments naming different layers are an error. In a
   rule, a package pattern decides before layers and classes, and the more
   specific of a `may_import` and a `may_not_import` pattern wins, a tie
   denying. This is what lets the `ui` preset close every layer to `Ui.**`
   while opening `Ui.Core` to logic.
5. **The `ui` preset** follows docs/65 §5.2 with two corrections: a view may
   import any `logic` package (the manifest cannot tell which screen's logic
   is "own"), and a view may import another `view`, which an embedded
   component needs (§6.2). `Ui.Forms` is view-only like `Ui.Widgets`.
6. **Where the checks run.** Import and `async` rules (Y0001, Y0002, Y0004,
   Y0005, Y0006, Y0009) run in the CLI on the project's own parsed,
   `@cfg`-erased packages before any backend, for `build`, `test`, `run`
   and `check`, so they are identical on every target. External packages
   are classified from the stdlib sources (header only, no full parse),
   dependency sources and restored packages' contract metadata; an
   `import extern` counts as `io`.
7. **Type-level rules.** Y0003 (call to an `@io` function), Y0007 (a
   module-level `val` holding a host object, which includes `List`, `Map`
   and `Set`, or a protected-type instance) and Y0008 (call to a protected
   `entry`) need resolved calls and types. The type checker records the
   facts (`SymbolTable.effectCallSites`, `mutableModuleVals`, from
   `ResolvedSignature.isIo`/`isEntry`); `Lyric.Pipeline` reports them for a
   package that may not do I/O: a `@pure` package, or one whose layer does
   not allow `io` (the CLI passes that reason per package, through
   `ProjectPackage.ioForbiddenReason`, to all three backends). In a `@pure`
   package, calls inside its own `@io` functions are exempt.
8. **Diagnostics.** Y0001 forbidden import, Y0002 unclassified import,
   Y0003 `@io` call, Y0004 `async func`, Y0005 `@layer` disagreement, Y0006
   unknown layer or preset, Y0007 mutable module state, Y0008 protected
   entry call, Y0009 malformed annotation or `[layers.packages]` entry.

## Consequences

- `examples/ui-customers` declares the `ui` preset; its store adapter and
  entry point stay unlayered, which is where the layers meet.
- The package-level rules apply to every `@pure` package in any build,
  including the stdlib's own build, which therefore checks its
  classification.
- The manifest parser's inline tables now keep string-array values
  (`TVStrList`); they were parsed and dropped before.
- Y0007 is shallow, as D138 specified: a record value holding a `List` in a
  field is not reported. Aliasing through the model passed to `update` is
  outside these rules (docs/65 §5.5).
