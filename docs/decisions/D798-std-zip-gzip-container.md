# D798 - Std.Zip reads and writes the gzip container (RFC 1952), with a bounded output (docs/72 slice 3)

**Status:** accepted. Implements slice 3 of `docs/72-h2-client-role-plan.md`. Builds on D248 (`Std.Zip`).

## Context

gRPC message compression (`grpc-encoding: gzip`, docs/72 section 4) needs the gzip container. `Std.Zip` had `inflate` (bounded), `deflate` and `crc32` but no gzip framing, and `lyric-compiler/lyric/cli/cli_targz.l` carries its own private reader for tarballs. docs/72 also flagged that `deflate` had never been measured.

## Decision

1. **Two functions in `Std.Zip`**, pure Lyric, the same error type as the rest of the module (`ZipError`):
   - `gzipEncode(data): slice[Byte]` writes one member: the 10-byte header (`1F 8B 08`, no flags, MTIME 0, XFL 0, OS 255, so the output is deterministic), the `deflate` stream, CRC-32 and ISIZE.
   - `gzipDecode(data, maxOutput): Result[slice[Byte], ZipError]` reads one or more concatenated members. `maxOutput` caps the total across all members and is enforced while inflating (stored blocks and match copies check it before they write), so a bomb is `LimitExceeded` before it is expanded, not after.
2. **What the decoder checks.** Magic, CM = 8 (anything else is `Unsupported`), reserved FLG bits 5 to 7 zero, FEXTRA (length-prefixed, bounds-checked), FNAME and FCOMMENT (zero-terminated within the data), FHCRC (low 16 bits of the CRC-32 of the header, `CorruptEntry` on mismatch), the stream itself, then the trailer: truncation is `Malformed`, a CRC-32 or ISIZE (length modulo 2^32) mismatch is `CorruptEntry`. FTEXT, MTIME, XFL and OS are not interpreted.
3. **Anything after the last member is an error** (`Malformed`), including zero padding. gzip(1) tolerates trailing zeros and warns on other trailing garbage; a gRPC message or HTTP body has no use for either, and accepting unparsed bytes is how smuggling and truncation bugs hide. A caller that really has padded data can slice it off first.
4. **Empty input is `Malformed`** (a truncated header), never an empty result.
5. **The inflater reports where it stopped.** `inflateRange` is now a thin wrapper over a private `inflateStream` that also returns the offset just past the last byte consumed, which multi-member input needs to find the trailer and the next header. Its public signature and behaviour are unchanged.

## Compression quality

`deflate` is greedy LZ77 with a bounded hash chain and one fixed-Huffman block; `gzipEncode` inherits it. Measured against gzip(1) 1.12 on the same inputs (both outputs verified with `gzip -dc` and Python's `gzip.decompress`):

| input | bytes | `gzipEncode` | gzip -1 | gzip -6 |
|---|---|---|---|---|
| repetitive log text | 300 007 | 28 001 | 22 971 | 16 594 |
| this repository's `std/zip.l` | 38 090 | 12 254 | 12 265 | 10 197 |
| `docs/72` (Markdown prose) | 64 809 | 31 105 | 28 894 | 25 012 |
| random bytes | 100 000 | 100 028 | 100 047 | 100 047 |
| empty | 0 | 20 | 30 | 30 |

So on prose and source it is within about 20 to 25 percent of `gzip -6` and level with `gzip -1`; on highly repetitive data it is about 1.7 times `gzip -6` because the Huffman code is fixed. Incompressible data falls back to stored blocks (framing overhead only). That is sufficient for the gRPC use (compression is optional, a peer decodes any valid DEFLATE) and is not a goal to improve here: dynamic Huffman blocks and lazy matching would be a separate `deflate` change, not tracked as part of this slice.

## Verification

`lyric-stdlib/tests/zip_tests.l` (already run on dotnet, the JVM and native by CI): gzip(1) and Python vectors checked in as hex (empty, one byte, `-9`, FNAME with MTIME, `gzip.compress`, a hand-built member with FHCRC, FEXTRA, FNAME and FCOMMENT, three concatenated members, a 1 MB bomb), round trips (empty, 1 byte, text, random 5 000 and 70 000 bytes, 300 KB), the cap at its exact boundary and across members, every prefix of five members rejected, every byte of the stream and trailer flipped, each header and trailer error, and no-panic sweeps over random and magic-prefixed bytes. Details and commands in `docs/progress/2026-12-01-std-zip-gzip.md`.
