# Resolver census: report what it does not cover (docs/70 phase 2c follow-up to D314)

- `scripts/ci/resolve-diff.sh` ran `lyric check` with `|| true`, so a project
  that did not check showed no `R0001` and counted as clean. Run locally against
  this repository, 38 of 97 manifests do not check on `--target dotnet` (an
  unbuilt local dependency, a package that needs a restore, a native-only
  library, a NuGet package the checker cannot index), so the census of D314 was
  narrower than "97 projects, 0 disagreements" said. The script now reports each
  such project as not covered, and fails on it only under
  `RESOLVE_DIFF_STRICT=1`.
- The `resolveCtx` doc comment now says the context is always built.
- Open: cover the native-only libraries (`lyric check` supports dotnet and the
  JVM only) and the projects that need a restore or built dependencies, so the
  strict mode can be CI's default.
