# D317 - The single bare-name lookup and T0219 come from `Lyric.Resolve`; the checker's import-rule tables are deleted (docs/70 phase 2c, #8612)

**Status:** shipped for the checked package's own scope. Step 7 of docs/70 §13
phase 2c, after D316.

## Context

After D314-D316 the resolver answered every bare-name question except three,
which the checker still answered from its own tables, built from the file's
imports: the single lookup under the import rule (`tryFindOneCore`,
`symTableImportVisible`), T0219 (a name a file uses that only a sibling file's
import makes visible: `FileImportRule` per file, `fileBareVia` and kin), and
three readers of the tables (`dotNamedExtensionTier`, the alias hints, the
"imported under an alias is named `Alias.name`" arity check).

## Decision

1. **The single lookup** walks the files nearest first (the file being checked,
   then its siblings, or every file for a synthesised item) and takes the first
   file whose scope resolves the name (`resolverPickIn`). A name no file
   resolves is a package-less symbol (a built-in, an `import extern` binding)
   or nothing. The checker's scan (`tryFindOneCore`) now serves a dependency's
   signature scope only.
2. **T0219 reads the resolver's per-file scopes.** `Lyric.Resolve` gains
   `bareVia` (how a file lets a declaration of a package be written bare: the
   import as written, "" for its own package and the prelude), `externVia` and
   `qualifiedVia`. `FileScope.directPkgs` holds each import as written
   (`import P.{A, B as C}`, `import P as Q`), which is the advice T0219 gives.
   A qualified reference accepted through a package a direct import itself
   imports (`qualifiedPkgReachable`) walks the registered package imports from
   the file's direct packages, as before.
3. **The three readers** use `symTableWholeImportTier` (1 for a package a file
   imports whole, 2 for one reached only through a re-export, -1 otherwise),
   `symTableAliasOfPackage` and `symTableIsImportAlias`, all over the files'
   scopes.
4. **The resolver is given the dependency items the checker registers**, with
   a destructuring module-level `val` already split (#7763); without it a name
   such as `lo` of `pub val (lo, hi) = ...` was unknown to the resolver.
5. **Deleted:** `FileImportRule`, `fileRules`, `buildFileImportRule`,
   `symTableImportVisible` and the maps it read (`importVisiblePkgs`,
   `importVisibleNames`, `importAliases`), the `wholeVia`/`namesVia` lists of
   `ImportSets`, `renderImportDecl`, `scanVisible`, and the differential mode
   (`LYRIC_RESOLVE_DIFF`, `R0001`, `R0002`, `scripts/ci/resolve-diff.sh`): its
   purpose was to compare the resolver with the checker's own answer, which
   the checker no longer computes for the checked package.

## Consequences

- For the checked package there is one answer to "what does this bare name
  mean": the resolver's. What remains of the checker's own lookup is the scan
  for a dependency's signatures (the resolver has no scopes for dependencies:
  `DepPackage` carries no imports; phase 5's interface artifact does) and the
  program-wide lookups of D315.
- #8720 (census coverage) is moot with the differential gone and is closed.

## Verification

`resolve_self_test` (31, with `bareVia`, `externVia`, `qualifiedVia`),
`typechecker_self_test` (1057, including the per-file import and T0219 cases),
`enum_case_collision_self_test`, `value_generic_record_self_test`,
`emitter_project_self_test`, `package_merge_self_test`, the reject corpus, the
multi-file end-to-end, `lyric check` over every dotnet stdlib test.
