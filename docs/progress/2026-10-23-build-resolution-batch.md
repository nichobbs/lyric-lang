# CLI argument checks, F0050, directory-form dependency entries, selective-import closure, L0017

A batch of build-system fixes (all in Lyric, in `lyric-compiler/lyric/`).

- **#8321**: every subcommand rejects an option it does not take
  (`rejectUnknownOption`) and a command that takes one source file rejects a
  second (`rejectExtraPositional`), instead of dropping or misreading them.
  The book's `lyric test --doctests`, `lyric test --jvm` and
  `lyric build --entrypoint`/`--verbose` examples, which named flags that do
  not exist, were corrected.
- **#8362**: new diagnostic `F0050`, a `--features` name the governing
  manifest's `[features]` table does not declare, from `build`, `run`, `test`
  and `prove` (`Mf.undeclaredCliFeatures`, `Lyric.Cli.undeclaredFeaturesError`).
- **#8248**: a workspace or path dependency's `[project.packages]` entry may
  be a directory of `.l` files; `readDepEntrySources` collects it through
  `Lyric.Discovery.projectEntryFiles` and reports listing problems.
- **#7952**: `importLinePackage` / `collectImportLines` understand selective
  imports (`import P.{a, b}`), so a package's import closure includes `P`.
- **#7913**: new lexer diagnostic `L0017` for a digit invalid for its base
  (`0b12`, `0o9`), reported on the digit instead of an out-of-range `L0010`.

Tests: `lexer_self_test.l`, `emitter_project_self_test.l`,
`manifest_self_test.l`, `cli_shared_self_test.l`,
`cli_workspace_builder_self_test.l` (dotnet and JVM), and
`scripts/ci/cli-args-e2e.sh` (registered in `compiler-self-tests-batch.sh`).
