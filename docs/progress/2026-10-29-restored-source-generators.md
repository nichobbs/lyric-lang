# Restored source generators with signed lock entries (#8580, D266)

A source generator can now come from the registry or from git, not only from a
path or workspace dependency. D266 settles what D248 Decision 7 left open:

- **The package is the signed artifact.** `lyric publish` of a `kind =
  "source-generator"` package runs `lyric plugin pack`, signs the artifact with
  `--sign-key <file>` or `LYRIC_PLUGIN_SIGNING_KEY` (required), writes the
  public key as `lyric-plugin/signer.pub`, and pushes a package holding only
  `lyric-plugin/`: no `lib/` assembly for a consumer to link, no NuGet
  dependencies (the artifact carries them). A git generator commits the same
  layout.
- **Where the key comes from.** A dependency may pin it, `{ version = "1.0.0",
  key = "lyric-ed25519:..." }` (registry and git only); otherwise the shipped
  `signer.pub` is trusted on first restore.
- **`lyric.lock` pins the key id.** `lyric restore` verifies the artifact
  (K0105-K0110) and writes `key = "<id>"` into the dependency's entry. A
  different key later fails the restore, naming both ids, until `lyric restore
  --update <name>`; `--locked` fails on it and refuses `--update`; `lyric
  update` carries the pins over and puts the previous lock back if a key
  changed. A build re-restores when a restored generator has no pin yet.
- **Loading.** The build checks the key against the pin (X0009 otherwise) and
  loads the generator with `Std.Plugin.discoverPlugins` under the pinned keys
  alone, so its signature and files are checked again (a changed file is
  K0108). A restored package without `lyric-plugin/` is a library (X0002).

Code: `Lyric.Cli` `cli_generator_packages.l` (locating and verifying a
generator package), `cli_restore.l` (`--update`, the key pass and the
`--locked` check), `cli_update.l`, `cli_publish.l` (`publishGenerator`, shared
`nuspecMetadata`/`packAndPush`), `workspace_builder.l`
(`resolveRestoredGenerator`), `Lyric.Generator` (`RestoredGenerator`, host
trust, `loadRestoredGenerator`), `Lyric.Lockfile` (`key`) and `Lyric.Manifest`
(`DependencyEntry.key`).

Also fixed: `Lyric.Workspace.findWorkspaceRoot` walked from the filesystem root
to `Path.dirname("/") == "."` and so read the working directory's `lyric.toml`.
A project outside any workspace, built from inside one (the repository root),
adopted that workspace and wrote its `lyric.lock` there. The walk now stops at
the root. That exposed a second bug the leak had hidden: a bare `[workspace]`
header with no keys under it left no manifest entry, so it was not a workspace
at all (the #5865 shape); `Lyric.Manifest` now finds the header by a line scan
(`textHasSectionHeader`), as it already did for `[package]`.

Tests: `scripts/ci/source-generator-restore-e2e.sh` (in `plugin-suites.sh`)
publishes `examples/generators/describe` to a local feed, builds the consumer
on dotnet and the JVM, and checks a rotated key against restore, `--update`,
`lyric update` and `--locked`, a mismatched pinned key (K0106), a changed
restored file (K0108), and a git generator. Unit tests: `manifest_self_test.l`
(the `key` field), `cli_restore_self_test.l` (the lock round-trip),
`generator_self_test.l` (X0002, X0006 and the X0009 text) and
`cli_workspace_builder_self_test.l` (the walk stops at the root), and a
bare-`[workspace]` case in `manifest_self_test.l`.
