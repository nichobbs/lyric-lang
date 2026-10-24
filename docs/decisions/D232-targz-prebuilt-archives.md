# D232 - `.tar.gz` prebuilt native library archives

**Status:** accepted, implemented for `--target native` (docs/67 phase G3 follow-up, #8401 item 2); completes D192's
archive formats

## Decision

1. **Same table, one more format.** `[native.libs.<name>.prebuilt.<triple>]` accepts a URL ending `.tar.gz` or `.tgz`
   (a query string is ignored; the suffix is matched in lower case). Like a `.zip` it needs `members`, the files to extract, with the same
   `"<path> -> <file name>"` rename form; a manifest without them is rejected. The SHA-256 pin, the restore marker and
   the offline `lyric build` are unchanged (D192).
2. **Pure Lyric, no `tar` or `gzip` process.** `lyric-compiler/lyric/cli/cli_targz.l` reads the gzip container
   (RFC 1952: optional extra, name, comment and header-CRC fields skipped, the trailer's length checked) and inflates it
   with `Jvm.Deflate`, the inflater `Jvm.ZipReader` already uses. The tar reader checks each header's checksum and
   understands ustar (with the `prefix` field), pax extended headers (`path`, `linkpath`, `size`), GNU long names and
   links (`L`, `K`) and base-256 sizes. A restore therefore needs nothing installed beyond `curl`, on every host.
3. **Links are followed.** Upstream tarballs ship `libfoo.so -> libfoo.so.1` and `libfoo.dylib -> libfoo.3.dylib`; a
   member that is a symbolic or hard link is resolved (relative to the link's directory, `..` and `.` normalised, at
   most 16 hops) and the target's bytes are written under the member's own file name.
4. **Limits.** `Jvm.Deflate` caps output at 64 MiB, so a tarball that inflates past that is refused rather than
   truncated; `.tar.xz`, `.tar.bz2` and `.tar.zst` are not read (the URL would be treated as a bare library file, so the
   link step fails naming it). Multi-member gzip streams and non-ASCII member names are not handled.

## Verification

`native_libs_self_test.l` builds a real tarball with the host `tar` (a symbolic link member, a sibling header file),
restores it, links an application against the extracted library and runs it; a missing member and a non-gzip file
under a `.tar.gz` name each fail the restore with their reason; a tarball URL without `members` is a manifest error.
