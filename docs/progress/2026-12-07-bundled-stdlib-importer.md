# A bundled stdlib package is checked as a stdlib importer on the native TIR path (docs/70 phase 3c, D882)

## What shipped

- `bundledTirOf` includes the package's own entry in the list the checker gets, so a stdlib package resolves another stdlib package's `internal` functions; `buildServerCtx`, `applyClientIdentity` and `resolveTrust` now lower from TIR on native (D882).
- `LYRIC_NATIVE_TIR_TRACE=1` prints each bundled package's builder failures with their first message.
