# D263 - Plugin listing paths are printable ASCII (narrows D248 Decision 5)

**Status:** accepted. Narrows D248 Decision 5 (docs/69 §12); shipped with
`Std.PluginSign` and `lyric plugin sign`/`verify` (plugins P7).

## Context

D248 Decision 5 allowed any listing path that is valid UTF-8 in NFC with no
empty, `.` or `..` segment and no C0 or C1 control character, sorted by UTF-8
bytes, and refused two paths that differ only in case. Implementing it on the
three host targets showed that non-ASCII names cannot be checked or read
consistently:

- `--target native` has no Unicode normalization (`String.isNormalized` is not
  implemented there; the tables are not in `lyric-rt`), so a native host could
  not apply the NFC rule at all.
- A JVM host whose locale is POSIX (`sun.jnu.encoding` = ANSI_X3.4-1968, the
  default in many containers) maps every non-ASCII file name to `?`: a file
  written as `é.txt` is created, listed and read as `?.txt`. The same signed
  artifact would then fail verification (`K0108`) on such a host and pass on
  another.
- "Differ only in case" has no portable meaning beyond ASCII: Unicode case
  folding is locale-dependent (the Turkish dotted and dotless `i`), and file
  systems fold differently.

A plugin artifact's files are written by `lyric plugin pack` or an SDK's
build: payload names derive from project names, plus directories such as
`jvm/` and `component/`. Nothing in the toolchain produces non-ASCII names.

## Decision

1. A listing path's characters are printable ASCII (`0x20` to `0x7E`) other
   than `\`. Segments are separated by `/`, and no segment may be empty, `.`
   or `..`. This replaces the NFC and control-character rules, which it
   implies.
2. Listing paths are sorted by their bytes (for ASCII, the same as UTF-8 byte
   order and code-unit order on every target).
3. Two paths that differ only in ASCII case fail the listing.
4. `plugin.sig`'s `files` paths are held to the same rules when it is parsed,
   so a malformed or hostile file never reaches the message reconstruction.
5. An artifact with any other file name cannot be signed: `lyric plugin sign`
   and `pack --sign-key` report the path, with characters outside printable
   ASCII written as `\u{XXXX}` so the report itself carries no control
   character or lookalike.

The rest of D248 Decision 5 (regular files only, links and other entries
refused, `plugin.sig` excluded, empty directories ignored) is unchanged.

## Rejected alternatives

- **Porting NFC to `lyric-rt` first.** It would fix native but not the JVM's
  locale-dependent name decoding, and it leaves Unicode case folding
  undefined.
- **Requiring hosts to run in a UTF-8 locale.** A plugin host is an ordinary
  application; a signature that verifies only under some locales is not a
  signature a publisher can rely on.
