# The library census fails on an unchecked build (#8613)

- `scripts/ci/library-tyerr-census.sh` exits 1 when a library build stops on any
  error other than I0001 (D386), instead of listing it and passing. Every error
  class counts, not only `T`, `P` and `L`.
- `lyric-access/platform` builds only on `--target native` (it uses `foreign
  record`), so it joins the native-only list instead of failing on the JVM.
