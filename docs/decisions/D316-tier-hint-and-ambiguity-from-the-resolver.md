# D316 - The bare-function tier, the import hint and bare-name ambiguity come from `Lyric.Resolve` (docs/70 phase 2c, #8612)

**Status:** shipped for the checked package's own scope. Step 6 of docs/70 §13
phase 2c, after D315.

## Context

After D314 and D315 the resolver answered what a bare name means and which
declarations it can mean, but three questions were still answered by the
checker's own import-rule code, which ran only under the file's import rule:
which package a bare function call binds to (`symTableBareFuncTier`,
`symTableBareFuncVisible`, `symTablePackageExportsFunc`), how to tell the user
to import a hidden name (`symTableHiddenImportHint`), and whether two packages
collide on a name (`symTableAmbiguousImportPackages`, T0123).

## Decision

1. **`Lyric.Resolve` exposes the deciding step.** `resolveBare` is now
   `winningStep` (the declarations at the first step of §4.3 that has any, and
   how the file reaches them) plus the message. Two readers of it:
   `winningPackages` (the packages that declare what the name means) and
   `ambiguousPackages` (those packages when there are two or more, the T0123
   case). `importHint` exposes the hint text.
2. **A package of several files is judged by the union of its files' scopes**
   for these three questions, as before: backends resolve a bare name
   package-wide until phase 2d (#8690), so a name two files import from
   different packages is ambiguous, and T0219 (a name only a sibling file
   imports) is still reported per file.
3. **Tier becomes membership.** `symTableBareFuncTier` is 0 for a function whose
   package is among the winning packages of any file and -1 for any other; a
   function of a nearer step shadows a farther one, and a package-private one
   is never a candidate, which is what the tier scan and the
   package-exports check computed. `symTableBareFuncVisible` is membership in
   `visibleDecls`.
4. **Deleted:** `symTablePackageExportsFunc`, `scanPackageExportsFunc`,
   `funcExportCache`, `hiddenImportHintPass`, `publicPackageOf` and the old
   bodies of the three functions above.

## Consequences

- No source or behaviour change intended; the checker's tests, the reject
  corpus and the census are the check.
- Still the checker's own: the lookup under a dependency's signature scope
  (`tryFindOneCore`), the sibling-file rules (T0219), `symTableImportVisible`
  and the import-rule maps they read, which go with the next step (the single
  lookup and T0219 from the resolver).

## Verification

`typechecker_self_test` (1057, including the T0123, T0097, hint and tier
cases), `enum_case_collision_self_test`, `value_generic_record_self_test`,
`emitter_project_self_test`, `package_merge_self_test`, the reject corpus and
the census.
