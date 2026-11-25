# Std.Zip gzip container, RFC 1952 (docs/72 slice 3)

Decision: D798. Slice 3 of `docs/72-h2-client-role-plan.md`; unblocks the gRPC `gzip` message encoding in slice 6 and the server-side decode in slice 8.

## What shipped

- `Std.Zip.gzipEncode(data): slice[Byte]` and `Std.Zip.gzipDecode(data, maxOutput): Result[slice[Byte], ZipError]` in `lyric-stdlib/std/zip.l`. Multi-member input, optional header fields (FEXTRA, FNAME, FCOMMENT, FHCRC), header and trailer validation, a total output cap that rejects a bomb before it expands, truncated and corrupt input refused, trailing bytes refused.
- `inflateRange` is now a wrapper over a private `inflateStream` that reports the end offset (no public change).
- Tests added to `lyric-stdlib/tests/zip_tests.l` (`testGzipVectors`, `testGzipRoundTrips`, `testGzipBombGuard`, `testGzipTruncated`, `testGzipCorrupt`, `testGzipArbitraryBytes`, `testGzipCompressionRatio`). The file is already in CI's stdlib runtime suite list, in the JVM run and in `scripts/ci/native-target-smoke-test.sh`, so no workflow change.
- Book: `Std.Zip` rows in chapter 12 and appendix B list the new functions.

## Compression ratio (docs/72 flagged it as unverified)

`deflate` really compresses (LZ77 plus fixed Huffman), falling back to stored blocks. Numbers are in D798: within about 20 to 25 percent of `gzip -6` on prose and source, 1.7 times larger on very repetitive data, framing overhead only on random data.

## Verification

Toolchain: private copy `cp -r /home/user/tc-s8 /home/user/tc-72-3` with `env.sh` pointed at it and `LYRIC_STD_PATH` at the worktree. The dotnet run links the prebuilt `Lyric.Stdlib.dll`, so it was rebuilt from the tree and installed into the copy first:

```
$LYRIC build --manifest lyric-stdlib/lyric.full.toml -o <dir>/Lyric.Stdlib.dll --target dotnet --no-restore
cp <dir>/Lyric.Stdlib.dll /home/user/tc-72-3/bin/lib/
```

Then, from the worktree (all print `zip tests: ok`):

```
$LYRIC run lyric-stdlib/tests/zip_tests.l                                 # dotnet
env -u JAVA_TOOL_OPTIONS $LYRIC run --target jvm lyric-stdlib/tests/zip_tests.l
$LYRIC run --target native lyric-stdlib/tests/zip_tests.l                 # clang + lyric_rt.a
```

Regression: `lyric-stdlib/tests/plugin_catalogue_tests.l` (a consumer of `Std.Zip`) via `$LYRIC test`, 9 pass, 0 fail on dotnet and on JVM. `scripts/audit-axioms.sh`, `scripts/audit-kernel-stubs.sh`, `scripts/ci/check-workflow-size.sh` clean (ci.yml untouched). `lyric fmt --write` on both changed `.l` files.

Interop: `gzipEncode` output for empty, random, 300 KB log text, `zip.l` and `docs/72` written to files by a scratch program and checked with `gzip -dc | cmp` and `python3 -I -c 'gzip.decompress'`; the checked-in vectors were produced by `gzip -n`, `gzip` (with name and mtime) and Python's `gzip.compress`, and each decodes with `gzip -dc`.

Not run: the `lyric-compiler` self-tests that import `Std.Zip` (the full `make lyric` build does not finish in the container).
