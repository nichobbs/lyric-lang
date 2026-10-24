# `.tar.gz` prebuilt native library archives (#8401 item 2, D232)

`[native.libs.<name>.prebuilt.<triple>]` now accepts `.tar.gz` and `.tgz` URLs
beside `.zip` and bare library files. `lyric restore` reads the gzip container
and the tar (ustar, pax, GNU long names, symbolic and hard links followed) with
a pure-Lyric reader over `Jvm.Deflate`, so no `tar` or `gzip` is needed.

- Code: `lyric-compiler/lyric/cli/cli_targz.l` (`gunzip`, `readTarEntries`,
  `extractTarMember`), `restorePrebuilt` in `cli_native_libs.l`,
  `Lyric.Manifest.prebuiltIsTarGz` and its `members` check.
- Tests: three cases in `native_libs_self_test.l` (a real `tar czf` tarball with
  a symlink member restored, linked and run; a missing member and a non-gzip
  file; the manifest check). Run on Linux in the native lane and on macOS in
  `macos-native.yml`.
- Docs: D232, language reference section 3.6, book chapter 13.
- Limits: output past 64 MiB (the inflater's cap) is refused; `.tar.xz`,
  `.tar.bz2` and `.tar.zst` are not read.
