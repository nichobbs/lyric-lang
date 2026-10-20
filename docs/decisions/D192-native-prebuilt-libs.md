# D192 - Prebuilt native libraries: per-triple archives with a pinned SHA-256

**Status:** accepted, implemented for `--target native` (docs/67 phase G3, #7942); completes docs/67 §6's library resolution

## Decision

1. **Declaration.** `[native.libs.<name>.prebuilt.<triple>]` gives `url`, `sha256` (64 lower-case
   hex digits) and, for a `.zip`, `members` (or `member`) to extract. A bare `.so`/`.dylib` URL
   needs no members. A library names exactly one of `dir`, `pkg_config`, or prebuilt tables.
2. **Checksum in the manifest.** docs/67 §6 put the checksum in `lyric.lock`, after docs/39's
   pattern. Here the URL names an exact artifact and no version range exists to resolve, so
   the pin is the manifest's own `sha256`: changing the URL and changing the digest are one
   reviewed edit, and there is no lock state to drift. The restore refuses a file whose digest
   differs and unpacks nothing.
3. **Restore, not build, downloads.** `lyric restore` fetches the host triple's archive and
   `[native].triple`'s, for the project and its path and workspace dependencies, into
   `.lyric/native/<name>/<triple>/` with a `.sha256` marker; a restore whose marker matches is
   a no-op. `lyric build` stays offline and says to run `lyric restore`.
4. **Transport.** `curl -fsSL --retry 2`, as `lyric upgrade` already does; it also reads
   `file://`, which is how the tests exercise the real fetch path without a network. Archives
   are unpacked with the pure-Lyric `Jvm.ZipReader` (stored and deflate), so no `unzip` is needed.
5. **Resolution.** A restored directory is linked and bundled exactly like a `dir` library (D191).

## Not in this slice

macOS `.app` bundles, code signing, and `.tar.gz` archives (SDL3 publishes source tarballs for
Linux; its binary for that platform comes from `pkg_config` or a project's own archive).
