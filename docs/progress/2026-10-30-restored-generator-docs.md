# Docs follow-up for restored source generators (D266)

The D266 PR (#8596) updated the language reference, docs/40, docs/69 and book
chapter 30, but not every document that describes publishing, lock files or
generator loading:

- `docs/10-bootstrap-progress.md`: the plugin status lists restored generators
  with D263-D265.
- `docs/38-workspace.md` §6: the lock-file example shows a generator entry
  with its `key` id.
- `docs/39-package-registry.md`: §4.2 describes generator packages
  (`lyric-plugin/` layout, `--sign-key`, the `lyric-source-generator` tag) and
  §5.2 the `key` pin, `--update` and `--locked`.
- `docs/40-source-generators.md` §4.2 step 3: the `dotnet exec` manifest probe
  applies to path and workspace generators only.
- Book chapter 33: the source-generator section points to restored, signed
  generators and §30.7.
