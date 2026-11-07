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
2. Any error code other than I0001 (`error[A-HJ-Z]NNNN`, not just `T`, `P`, `L`)
   marks a build unchecked, since only an I0001 is a site.
3. `lyric-access/platform` is listed in `NATIVE_ONLY` with the other libraries
   that build only on `--target native`.
