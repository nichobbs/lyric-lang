# D182 - A single file's features come from its own manifest, chosen once; `--features` with no manifest is F0049

**Status:** accepted, implemented (#8339)

Refines D123 §5 (single-file builds thread a nearby manifest's `[features]`
defaults, with no feature flags of their own) and the build selection #8325 /
#8342 gave `lyric prove` and the language server.

## Context

Two commands chose a single source file's feature set in different ways:

- `lyric build <file>` (`emitSingleFileOrProject`, D123) took the features of
  the nearest `lyric.toml` above the file, whether or not that manifest's
  `[project.packages]`/`[project.tests]` entries list it. `lyric prove
  <file>` (`typeCheckForProveFile` and `Lyric.Discovery.sourceBuildsForFile`)
  took the features of the manifests that *list* the file and, when none
  did, none at all. For a script beside a project (`tools/gen.l` next to a
  manifest that lists only `src/`) the two commands compiled different
  `@cfg` items: `lyric prove` could refute, or reject as ill-typed, the
  variant `lyric build` never compiles, and pass the one it does without
  checking it.
- With no manifest, `lyric build <file> --features a` resolved features
  against nothing and silently compiled the file without `a`. `lyric run`
  had no feature flags at all, so `lyric run dup.l --features a` passed the
  two words to the program and ran the file without `a`. `lyric test` and
  `lyric prove` likewise compiled the file without the features they were
  asked for.
- `--target native` single-file builds and `lyric test --target native`
  erased `@cfg` items with no features even under a manifest, so the same
  file compiled different items per target.

## Decision

1. **One function chooses a single file's build.**
   `Lyric.Discovery.singleFileSourceBuild(sourcePath, explicitManifest,
   target, --features, --no-default-features, --all-features)` is the
   configuration of a file compiled on its own: the features of
   `explicitManifest` (`--manifest`) when given, otherwise of the file's own
   manifest (`singleFileManifest`: the nearest `lyric.toml` with a
   `[package]` section, walking up from the file's directory, not the
   working directory, as D123 discovers it), resolved for the target by
   `Lyric.Manifest.resolveFeatureSelection`; with no manifest, none.
   Every single-file manifest lookup is the one walk
   `Disc.singleFileManifestDetailed`, which first makes the path absolute and
   resolves its `.` and `..` segments (`normalizePath`): `lyric run
   ../loose/a.l` from inside another project finds `loose/`'s manifest (or
   none), never the working directory's.
   `emitSingleFileOrProject` (`lyric build`, `run`, `test`, and `lyric
   check`, which compiled a file with no manifest at all before), the native
   single-file build and test, `typeCheckForProveFile`'s check of the file
   alone, and `sourceBuildsForFile` (`lyric prove` and the language server)
   all call it, so they compile, check and prove the same items.
2. **A file under a manifest that does not list it takes that manifest's
   features.** This keeps `lyric build`'s D123 rule rather than `lyric
   prove`'s "no features" fallback. A manifest's `[features]` table is
   project-wide configuration (its `default` set is what every build of the
   project starts from), and D123 already made the nearest manifest the
   source of a single file's dependencies; taking its dependencies but not
   its features would build the file against packages compiled with features
   the file itself does not see. Dropping the features instead would have
   silently changed `lyric build` and `lyric run` for every script inside an
   ecosystem library whose manifest defaults to a platform feature
   (`default = ["dotnet"]`), compiling them without their kernels.
3. **`lyric prove` covers the build `lyric build <file>` makes.** A file that
   some manifest lists is still proved once per listing manifest's build
   (#8325). When the manifest `lyric build <file>` uses (the nearest one) is
   not one of those, that build is proved and type-checked too
   (`Disc.nearestManifestListsSource`; `sourceBuildsForFile` and
   `typeCheckForProveFile` add it). This matters beyond unlisted files: a
   project's directory entry takes every `.l` file under it, so a file inside
   `src/tool/`, which has its own `[package]` manifest, belongs to the
   project's `src` package (built with the project's features) and is built
   alone by `lyric build src/tool/x.l` under the nested manifest's features.
   Proving only the project's build gave a false "proved" for a
   postcondition the nested build violates at runtime; the proof now covers
   both builds, labelled, and refutes it. Changing which files a directory
   entry takes was the alternative; it would change the project build, which
   `Lyric.Discovery.projectEntryFiles` defines for both `lyric build` and
   `lyric prove` (#8108), so the proof instead covers every build that
   compiles the file.
4. **`--manifest` with a source file is honoured by every command, and a
   bad one is a hard error.** `lyric prove --manifest <m> <file>` checks and
   proves the file under `m` alone (within `m`'s project when one of its
   entries lists the file, otherwise on its own with `m`'s features), as
   `lyric build --manifest <m> <file>` builds it; it was previously ignored
   in single-file mode. `lyric run --manifest <m> <file>` and `lyric check
   --manifest <m> <file>` reach the build too (both ignored it before). An
   explicit `--manifest` that cannot be read or does not parse fails every
   single-file command before anything is compiled or proved
   (`prove: cannot read manifest <path>: ...`, or the parse error; the
   shared `Lyric.Cli.singleFileManifestError` with
   `Disc.manifestLoadError`), never a silent build with no manifest.
5. **`--features` with no manifest is error `F0049`.** Features are declared
   in a manifest's `[features]` table, so with neither `--manifest` nor a
   manifest above the file there is nothing for `--features` to select.
   `lyric build` (`--watch` and `--aot` included, rejected once, up front),
   `run` (single file, `--watch` included), `test` and `prove` all fail
   before compiling anything:
   `error[F0049]: --features a selects features a manifest's [features] table
   declares, but dup.l has no manifest (no lyric.toml with a [package] section
   in its directory or any parent); declare the features in one, or pass
   --manifest <lyric.toml>`. When the nearest `lyric.toml` is broken (it
   exists but does not parse), the message names that file and its parse
   error instead, since that is what to fix. `F0049` is the next free code of
   the CLI build family (`F0040`-`F0044` are the profile/shape flags).
   `--no-default-features` and `--all-features` select nothing without a
   manifest (there are no defaults and no declared features) and are
   accepted: they cannot change what is compiled, so there is nothing to
   report. An explicit `--manifest` that cannot be read or parsed is the
   hard error of item 4, not `F0049`. A `--features` name a manifest does
   not declare is not reported; that predates this decision and is tracked
   separately.
6. **`lyric run` takes the feature flags.** `--features`,
   `--no-default-features` and `--all-features` are options of `lyric run`,
   for a single file and a project, as for `lyric build`; arguments after
   `--` are the program's, so `lyric run app.l -- --features a` still passes
   the flag to the program.
7. **Native single-file builds honour the file's features.** `lyric build
   --target native <file>` and `lyric test --target native <file>` erase
   `@cfg` items with `singleFileSourceBuild`'s features for `native`
   (`Lyric.LlvmBridge.compileToNativeWithFeatures`), as the dotnet and JVM
   builds of the file do; the file is still compiled alone (D123).

## Unchanged

- A file whose nearest manifest does not list it is type-checked by `lyric
  prove` on its own
  (`Emitter.typeCheckSourceForFeatures`), now with the features above; it is
  not compiled against the manifest's own packages or dependencies the way
  `lyric build` compiles it, since a proof never builds or restores a
  dependency. An unlisted file that imports one of them fails `lyric prove`'s
  check, as before.
- `--target native` single-file builds read `[native]` from `--manifest` or
  the manifest discovered from the working directory (`resolveNativeConfig`),
  not from the file's own manifest.
- A `@test_module` that links the compiler's own DLLs (`Lyric.*` imports,
  #2364) is still compiled with no features (#7481).

## Tests

`scripts/ci/single-file-features-e2e.sh` (run by
`compiler-self-tests-batch.sh`): `F0049` from `build` (dotnet and jvm, no
output written, `--aot`, and `--watch`, which exits instead of polling),
`run`, `run --watch`, `prove` and `test`, and through a `../` path from
inside another project (which also takes no features for `run` and
`prove`); a missing and a broken `--manifest` are hard errors for `prove`
and `build`, with nothing proved; the nested-manifest file is refuted
(`V0008`) on dotnet and the JVM, never proved, and running it violates the
postcondition; `check`, `run --manifest` and `test --features` agree with
`build` under a manifest; the same file
without `--features`, with `--no-default-features` and with
`--all-features` still builds and runs, and `-- --features a` reaches the
program; an unlisted `@cfg` twin file under a manifest is proved with its
default features and refuted under `--no-default-features` (also with
`--target jvm`, `--features` and `--manifest`), runs the matching twin on
dotnet and the JVM, and a file that type-checks only under the default
feature is accepted by both `lyric build` and `lyric prove` and rejected by
both, with the same diagnostic, under `--no-default-features`.
`lsp_self_test.l` covers the language server's builds for an unlisted
document and a manifest-less one; `native-target-smoke-test.sh` covers a
native single-file build under its manifest's features, and
`single-file-features-aot-e2e.sh` (e2e-cli-tests) a `--aot` build under
them.
