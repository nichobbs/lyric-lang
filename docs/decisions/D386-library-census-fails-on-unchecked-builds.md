# D386 - The library census fails on an unchecked build (docs/70 5.3, step 6, #8613)

**Status:** shipped. Tightens D355's census script after the I0001 flip (D385).

## Context

`scripts/ci/library-tyerr-census.sh` builds every library manifest and counts the
I0001 sites it reports. A build that stops on any other error never reaches the
I0001 gate, so it proves nothing about its sites. The script listed such builds
as UNCHECKED but still exited 0, and recognised only `T`, `P` and `L` error
codes. One manifest, `lyric-access/platform`, was permanently unchecked: it is
written with `foreign record` types (a native-only feature) and was also built on
the JVM, where `accesskit_rect` does not resolve (T0010).

## Decision

1. An UNCHECKED build fails the run (exit 1) with a message naming the builds. A
   manifest the census cannot judge is a hole in the census: it is fixed or listed
   as native-only, never counted as clean.
2. A build is checked when it succeeds or reports I0001 (the checker reports it only
   for a program that type-checks). A build that exits non-zero without an I0001 is
   unchecked, whatever the error class and even when it prints no code at all (a
   malformed dependency manifest); only the exact diagnostic `error[I0001]` is a site.
   The sites are printed before the unchecked builds, so a run with both shows both.
3. `lyric-access/platform` is listed in `NATIVE_ONLY` with the other libraries
   that build only on `--target native`.
