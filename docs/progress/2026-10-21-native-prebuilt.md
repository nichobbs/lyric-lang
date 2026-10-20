# Prebuilt native libraries (docs/67 G3 S5, #7942, D192)

- Manifest: `[native.libs.<name>.prebuilt.<triple>]` (`url`, `sha256`, `members`), validated.
- `lyric restore` downloads (curl), verifies the pinned SHA-256, unpacks zip members with
  `Jvm.ZipReader`, and records the digest; dependencies' libraries included.
- Build: a prebuilt library resolves to its restore directory; "run `lyric restore`" when absent.
- Tests: `native_libs_self_test.l` restores a zip through `file://`, builds and runs an
  application against it, refuses a wrong checksum without unpacking, and validates tables.
- Docs: D192, language reference §3.6, book chapter 13.
