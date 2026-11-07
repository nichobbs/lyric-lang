# The library census fails on an unchecked build (#8613)

- `scripts/ci/library-tyerr-census.sh` exits 1 when a library build stops on any
  error other than I0001 (D386), instead of listing it and passing. Every error
  class counts, not only `T`, `P` and `L`.
- `lyric-access/platform` builds only on `--target native` (it uses `foreign
  record`), so it joins the native-only list instead of failing on the JVM.
- The first run of the strict census (D386) showed the old counts were partly
  illusory: native-only libraries failed on `pkg-config` and `lyric_rt.a` before any
  type-checking, so they are no longer built by the census (their native e2e jobs
  build them for real); two dotnet libraries were flagged only because a local
  dependency was not built yet, so that case is retried; JVM codegen and middle-end
  failures happen after checking and count as checked. `lyric-ui` on the JVM fails in
  the middle end (M0004, `toWire` cannot infer `Msg`); that is a separate JVM build
  problem the census now makes visible, not a silent site.

