# D301 — Cache the bundled-stdlib type check of `--target native` (#7971)

**Status:** accepted, implemented

## Context

The native stdlib check (#7933, docs/progress/2026-10-01-native-stdlib-type-check.md) type-checks every bundled `Std.*`
package a program's import closure reaches, on every build: +0.3 s for a small
program and +1.3 s for one importing the whole standard library. The earlier
comments on #7971 found that a cache has to restore more than a verdict:
`checkBundledStdlibPackage` returns the package after `lowerRecordSites` and
`lowerArraySites`, which consume the checker's site tables, and neither those
tables nor the AST has a serialised form.

## Decision

`Lyric.NativeStdlibCache` (`lyric-compiler/lyric/native_stdlib_cache.l`) records,
per package, that a check against an exact set of inputs reported no error and
**recorded no lowering site**. Both lowering passes return their input unchanged
when they have no site (`lowerRecordArith`, `lowerRecordEq`, `lowerArrays` early
out), so for such a package the lowered package is the parsed one and a hit hands
that back with no check and nothing to deserialise.
`Lyric.Pipeline.stdlibLoweringIsIdentity` is the single list of the tables the two
passes read. A package with sites (`Std.Buffer`, `Std.Linalg`, `Std.ParallelHost`
at the time of writing: 3 of 102) is always checked in full and never stored.

### Key

SHA-256 over: the format tag, the compiler fingerprint, `native:<target os>`
(the checker's only target inputs: the `native` mode flag and the `target_os`
feature that erases `@cfg` items), the package name, and for the package and each
package of its import closure, in load order, the package name and the hash of the
text of every file declaring it. The checker reads nothing else.

The compiler fingerprint is `VERSION()` plus the SHA-512 of every file named
`lyric*`/`Lyric*` in the compiler's own directory (the dev layout's compiler DLLs,
a release's executable). `VERSION()` alone is "0.1.0" on every dev build, so a
rebuilt compiler would otherwise reuse a stale verdict. If the directory is
unreadable, holds no such file, or a file cannot be hashed, the fingerprint is
empty and the cache is off: an unknowable compiler is never assumed unchanged.

### Soundness

- An entry's text restates the format tag and its own key, and `lookup` accepts a
  file only when it equals, byte for byte, the text `store` writes for that key. A
  truncated, edited, empty, foreign, renamed or copied-over file, or a directory in
  its place, is a miss, so the package is checked in full and the entry rewritten.
- Only a clean, site-free result is stored, so a hit never has diagnostics to replay
  (an error stops the build and is never cached; warnings are not shown for
  stdlib packages).
- Writing is best effort. A missing, read-only or blocked cache directory costs the
  speedup and nothing else.
- Entries are never deleted by the compiler; a stale one is unreachable under the
  new key. `rm -rf` of the directory is always safe.
- Verified: the generated LLVM IR of a program is byte-identical with the cache off,
  cold and warm (`scripts/ci/native-stdlib-cache-e2e.sh`).

### Location and switches

`$LYRIC_CACHE_DIR/native-stdlib-check/`, else `~/.lyric/cache/native-stdlib-check/`
(`%USERPROFILE%` without `HOME`), beside the existing `~/.lyric/tools`.
`LYRIC_CACHE_DIR=off` disables it. `LYRIC_TRACE_STDLIB_CHECK_CACHE=1` prints
`hit`, `miss`, `miss-stored` or `uncacheable` per package on stderr.

## Relation to docs/70 (checked package interfaces)

The cache stores a verdict keyed by source hashes, not any compiler data structure,
so it neither constrains nor depends on `Lyric.Iface`. When D267's checked package
interfaces replace the whole-package check of the bundled stdlib, this package is
deleted with it; the interface build step would take over the same key recipe
(sources of the closure, compiler fingerprint, target).

## Consequences

- A warm native build skips the check of 99 of the 102 packages: see the progress
  entry for the measured times.
- A cold build (first build, a compiler rebuild, a stdlib edit) costs one extra
  hash of the stdlib sources and the compiler files, plus a small file write per
  package.
- Packages with sites still pay the check. Caching them needs a serialised form of
  the lowered package or of the site tables (an AST serialiser, or `Lyric.Fmt`
  print and re-parse proved loss-free by a round trip over the whole stdlib); that
  is a larger piece of work than this cache, not a variant of it, and is tracked
  as its own issue (linked from the PR).
