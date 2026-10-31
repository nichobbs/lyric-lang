# Per-file import scopes in warning mode, docs/70 phase 2a step 4 (#8612)

Imports are now per file (docs/70 §4.1, language reference §9.2, docs/19 §4
step 2), in warning mode:

- `Lyric.TypeChecker` builds one import rule per file of a package
  (`FileImportRule`: whole, selective, alias and `import extern` sets, each
  with the import that provides it) beside the package union it still
  resolves through. Each item is checked in the scope of the file it is
  written in (`symTableEnterSpanFile` in the signature, impl and body
  passes), and every re-entry (`enterDeclaringScope`,
  `enterDeclaringScopeIfForeign`, `unionCaseFieldTypes`) saves and restores
  the entered file and enters the file the declaration is written in. A
  name is judged by the file its own span lies in, so a record's field type
  read from another file is judged by the file that declares the record. A
  synthesised item (no source position) uses the union.
- A name a file can use only through a sibling file's import is the new
  warning **W0032**, once per name and file, naming the sibling's path and
  the import to add: bare values and calls, constructors and cases, types,
  qualified references (`P.x`, including what an alias rewrote), and
  `import extern` names. The name still resolves; no new error.
- Renames (`T0148`) and selective imports (`T0210`) are checked against
  each file's own imports, with `T0210` now reported at each file's own
  import. A rename that collides with a name only a sibling's import brings
  in stays `T0148` (its message says so) until the rule becomes an error,
  as `B0012` does.
- `Lyric.AliasRewriter` rewrites each item with its own file's aliases and
  renames (`AliasEnv`; `rewriteFileReporting` returns its diagnostics, which
  `pipePrepareForCheck` reports). An alias or rename only a sibling binds
  still rewrites, as W0032 from the rewriter when the file imports the
  package in another form, or from the checker's qualified-reference check
  when it does not import it at all.
- Follow-ups from #8660: the `array[` scan runs once per file inside the
  assembly (`PackageAssembly.spellsArray`), and
  `source_path_diagnostics_self_test` checks that a project build stops at,
  and reports only, the first package whose files do not assemble, on dotnet
  and the JVM. docs/63 §9.7 marks the line-origin design historical.

Behaviour visible in output:

- New warnings W0032 on multi-file packages that relied on a sibling's
  imports.
- An implicit alias (`import A.B` makes `B.f` mean `A.B.f`) that two files
  bind to different packages now rewrites each file's uses to its own
  file's package; before, the first file in source order won for every file.
- A bad selective import repeated in two files is reported in each file.
- A cross-file `T0148` carries the suffix "(through another file's import:
  ...)".

Census, with the new compiler building the compiler bundle, the stdlib
(`full-selfhosted-stdlib-build.sh`), every ecosystem library and example
manifest on dotnet, the native-only libraries on native and the web/UI
libraries on the JVM: 7 occurrences, all in `lyric-compiler/` (fixed by adding
the import the sibling already had: `verifier/vcgen_methods.l` `import
Std.String as Str`, `cli/cli_prove.l` `import Std.Parse`, `cli/cli_clean.l`,
`cli_doc.l`, `cli_fmt.l` and `cli_openapi.l` `import Std.Errors`,
`type_checker/typechecker_scope.l` `import Lyric.Parser`); 0 in
`lyric-stdlib/`, 0 in the ecosystem libraries, 0 in `examples/`.

Also fixes main's stage-1 build: two `SourceFile` constructions #8663 added
in `Lyric.Pipeline` lacked the required `files` field (T0105).

Tests: `typechecker_self_test` (a sibling-only name warns with the right
file, line and import; an own import does not; one warning per name and
file; types, values and qualified names; a declaration's field types judged
in its own file; aliases and implicit aliases per file; selective imports
and T0210 per file; renames and the cross-file T0148; a synthesised item),
`source_path_diagnostics_self_test` (W0032 through a real build on dotnet and
the JVM; the first failing assembly stops the build), and
`scripts/ci/multi-file-package-merge-e2e.sh` (a package that builds and runs
with W0032).
