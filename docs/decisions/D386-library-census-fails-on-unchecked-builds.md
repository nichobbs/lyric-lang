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
2. A build is checked when it succeeds, reports I0001 (the checker reports it only
   for a program that type-checks), or fails with "JVM codegen failed" (emission runs
   only on a program that type-checked). Middle-end `M` codes are not evidence: a
   Mono failure can be caused by a silent unchecked type, which is what the census
   hunts. Any other non-zero exit is unchecked, whatever the error class and even
   when it prints no code (a malformed dependency manifest, a timeout); only the
   exact diagnostic `error[I0001]` is a site. A build with a tracked cause is listed
   in `KNOWN_UNCHECKED` as "manifest|target|issue" and reported separately without
   failing. The sites are printed before the unchecked builds.
3. A build that stops because a local dependency is not built yet is retried once
   the dependency exists, as one that fails to load a restored one already was (the
   first run of the strict census flagged `lyric-access` and `lyric-unicode-dict`
   for exactly that).
4. Native-only libraries (`lyric-access/platform`, `lyric-draw`, `lyric-gpu`,
   `lyric-gpu-window`, `lyric-text`, `lyric-window`, `lyric-game/platform`,
   `lyric-ui/native/host`) are not built by the census. Resolving their system
   libraries (`pkg-config`) and the runtime archive precedes compilation, so the
   old census counted them as checked without ever type-checking them. Their
   `native-platforms.yml` e2e jobs build them with the real toolchain, and with I0001
   always an error a silent site fails those jobs. The census prints which libraries
   it skipped.
