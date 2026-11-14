# D482 - A call that leaves out an argument another package declares takes the default from that package's interface (docs/70 phase 3a, #8613)

**Status:** shipped; extends D460 and D581. Interface format version 5. Pulled forward from phase 5b by the owner, limited to defaults.

## Context

A call that leaves out a defaulted parameter, or a record construction that leaves out a defaulted field, places the
declaration's default at the call (D581). The builder reads that expression from the checker's tables of the callee's own
package, so a default declared in another package could not be built. Measured on the compiler (dotnet, per-package emit):
65 sites counted as `a default argument declared in another package`, and more that failed earlier as "no type for node #0",
because even a literal default of another package was typed from the consumer's table by the declaration's node id.

D460 put each function's defaults in the package interface, but the call site had no way to use them: a default is built in
its package's `SymbolId` numbering, each package has its own `DefPathInterner`, and the verifier needs a `TSymEntry` for every
symbol a default names.

## Decision

- `IfParam` and `IfField` carry `dfltEntries`, the declarations (`TSymEntry`) of the symbols the default names, written
  after the default (`putEntries`/`readEntries` in `iface_expr.l`); `IfField.dflt` carries a non-generic record field's
  default. The producer is `Lyric.Tir.Build.buildPackageDefaults`, now returning `IfDefault` (expression and entries) per
  function and per record, keyed by the function's or record's DefPath key and the parameter's or field's name. The format
  version is 5.
- `Lyric.Tir.Build.DepDefaults` is a store of encoded interfaces by package. A build shares one store among the options of
  its packages (`MiddleEndOptions.depDefaults`). `pipeCheckFront` registers a package's interface once it is built (a
  library build that writes one, and a check-only build under `--verify-ir` or `wantTir`), so a package checked after it
  finds it; the dotnet project paths also register the `Lyric.Interface.<Pkg>` resources of restored dependencies.
- At the call, `buildDefaultArg` for a callee whose `originPackage` is not the checked package reads the default with
  `readCarriedDefault`: it decodes the declaring package's interface with the consumer's interner (cached per consumer), so
  the default's symbols and the declarations it names are numbered as the consumer's own, adds those declarations to the
  body's `env.syms`, renumbers the nodes (`refreshDefaultIds`) and keeps `coerceArg(default, paramTy)` at the call, since the
  carried default is pre-coercion. The callee's key is its symbol's DefPath key (for a record construction, the record's).
- A default with no carried form (a shape `defaultCarriable` rejects, a package whose interface the build does not have,
  a generic record) stays counted as `a default argument declared in another package`.

## Results

Compiler census: 11708 -> 12152 of 12767 bodies built, `a default argument declared in another package` 65 -> 12, I0003 0.
`scripts/ci/tir-foreign-defaults-e2e.sh` builds a two-package project (literal, `newList()` and record field defaults, with
named and positional arguments) with `--verify-ir` and runs it.

## Not covered

The 12 sites left are defaults declared in stdlib packages (`Std.Plugin`, `Std.PluginCatalogue`): the stdlib is source-loaded
in these builds, so no interface of it is registered. The JVM and native bridges do not register interfaces yet, so their
cross-package defaults stay counted. Both are the next slices of this work, not accepted gaps.
