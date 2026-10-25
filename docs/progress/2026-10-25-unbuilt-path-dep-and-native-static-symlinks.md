# Unbuilt path dependencies stop a manifest build; native static files resolve symlinks (#8574, #8507, #8571)

**#8574.** `buildProjectFromManifest` (the `--manifest` path of `lyric build`
and `lyric run`, and the release staging build) now stops on
`ResolvedManifestDeps.hadUnbuiltLocalDep`, as the single-file path and
`lyric prove` already did. An unbuilt, missing or unreadable `path = "..."`
dependency prints its actionable message (`localDepNotBuiltMessage`, the
manifest or source error) and the build exits 1, instead of compiling on into
a misleading `T0123` unresolved call and `B0001`. Covered by two tests in
`jvm_path_dependency_self_test.l` whose consumer never references the
dependency, so only the early stop can fail them (dotnet unbuilt DLL, JVM
unreadable source).

**#8507.** lyric-web's static-file root check on `--target native` resolved
paths lexically, so a symlink inside the root that pointed outside it was
served. lyric-rt gains `lyric_path_real_ok` (`realpath(3)`; on Windows
`GetFinalPathNameByHandleW`), which reports a missing path (-1) apart from
every other failure (-2, a loop included). The native `pathGetFullPath`
resolves the longest existing prefix of the raw path (so `..` after a link
climbs from the link's target, as `open` does), appends the missing rest
lexically, and maps a loop to "". On every target `resolveStaticFile` now
reads the canonical path its check accepted, never the raw candidate, and a
root that does not resolve contains nothing. `examples/native-web` mounts
`./public` at `/static`, and `scripts/ci/native-web-smoke.sh` checks absolute
and directory links, `linkdir/../secret.txt`, relative chains in and out of
the root, a loop and a 45-link chain; the check fails on the previous code.
C coverage is `test_path_real` in `lyric-rt/test/lyric_rt_test.c`.

**#8571 item 2.** lyric-search's env-driven `Search.connect` names its probe
timeout `DEFAULT_CONNECT_TIMEOUT_MS` (10000) and reads
`LYRIC_SEARCH_ELASTICSEARCH_CONNECT_TIMEOUT_MS` /
`LYRIC_SEARCH_MEILISEARCH_CONNECT_TIMEOUT_MS`; a non-positive value is
`INVALID_TIMEOUT`, an unparsable one falls back to the default.
