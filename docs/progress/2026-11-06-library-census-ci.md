# The library census as a CI gate (#8613)

D355.

- `scripts/ci/library-tyerr-census.sh` builds every library manifest with
  `LYRIC_TYERR_GATE=1` and counts the W0036 silent-TyError sites; the CI job
  `library-tyerr-census` runs it on every code change and fails on any site.
  Native-only libraries (`lyric-gpu`, `-window`, `-text`, `-draw`,
  `-gpu-window`, `lyric-game/platform`, `lyric-ui/native/host`) build for
  `--target native`, the rest on dotnet and the JVM.
- A build that stops on a parse, type or dependency error never reports W0036,
  so it is listed as UNCHECKED instead of counted as clean. Builds run dotnet
  first, then JVM (a JVM build writes its jar under the same `.dll` name in a
  library's `bin/`), and a build that fails loading a library dependency built
  later in the run is retried. Current state: 81 of 81 builds checked, 0
  unchecked, 0 sites.
- Checker follow-ups from the review of #8841: the package-qualifier join is one
  helper (`qualifierOfSegs`), and self-tests cover a package's own enum against
  an imported one of the same name, a case name two sibling enums share (typed
  by the expected type, still an error against the wrong one), and a `try` with
  two handlers.
