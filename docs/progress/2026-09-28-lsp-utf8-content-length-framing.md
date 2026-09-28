# UTF-8 byte-exact Content-Length framing for `lyric lsp` (#7510)

`lyric-compiler/lyric/lsp.l`'s hand-rolled JSON-RPC framing computed
`Content-Length` as `json.length` (UTF-16 code units, the .NET/JVM
`String.length` convention) when writing, and read the declared count in
UTF-16 code units from `Console.Read()` when reading. The LSP base protocol
defines `Content-Length` as the UTF-8 byte length of the body. Any
non-ASCII character in a diagnostic, a hover string, a document's own
content, or a file path desynchronised the stream: the header undercounted
a multi-byte character's bytes (é is 2 UTF-8 bytes but 1 UTF-16 code unit;
😀 is 4 UTF-8 bytes but 2 UTF-16 code units), so the reader on the other
end of the pipe stopped short or read into the next frame's header.

## Fix

- **Writing**: `lspEncodeFrame(json: String): slice[Byte]` computes
  `Content-Length` from `encodeUtf8(json).length` and returns the whole
  frame (header + blank line + body) as raw bytes; `writeLspFrame` sends
  it through `Std.Console.writeStdoutBytes` (new, see below) — never
  through a text writer that could re-encode.
- **Reading**: `lspScanFrame(buf: slice[Byte]): LspFrameScan` is a pure,
  no-I/O scanner over a byte buffer — `LspScanNeedMore` /
  `LspScanBadHeader(message)` / `LspScanFrame(body, consumed)` — that reads
  the header block, decodes it as UTF-8, parses `Content-Length`
  case-insensitively, and waits for exactly that many body bytes.
  `lspReadFrame` drives it against real stdin through
  `Std.Console`'s byte-level `StdinReader` (#7451), buffering unconsumed
  bytes across calls so two back-to-back frames split at exactly the right
  boundary. A missing/non-numeric/negative `Content-Length`, an oversized
  header block with no terminating blank line, and a non-UTF-8 body/header
  are all reported as `LspReadError(message)` (logged to stderr, the loop
  then exits cleanly) instead of panicking or hanging. A stream that
  closes strictly between frames is `LspReadEof` (a clean shutdown); one
  that closes mid-frame (partial header or partial body already buffered)
  is `LspReadError`, naming the truncation — not silently swallowed and
  not a hang.
- The framing logic is deliberately split into pure functions
  (`lspEncodeFrame`, `lspScanFrame`, `lspDecodeFrameBody`) over
  `slice[Byte]`/`String` with no I/O, so it is unit-tested directly with
  no real stdin/stdout, and a thin stateful layer
  (`LspStdin`/`lspReadFrame`) that drives them against
  `Std.Console`'s `StdinReader`.
- The former UTF-16-code-unit surrogate-pair handling
  (`lspAppendCodeUnit`/`lspFlushCodeUnits`, added for #7252 as a narrower
  fix within the old code-unit reader) is now dead code and removed along
  with the old `readLspFrame`; the new byte-level reader has no surrogate
  handling to do — it decodes complete UTF-8 byte sequences directly.

## New stdlib API: `Std.Console.writeStdoutBytes`

No stdout byte-writing primitive existed (`Std.Console` had a stdin byte
reader from #7451, but stdout only had text-based `print`/`println`).
Added `writeStdoutBytes(bytes: in slice[Byte]): Unit` (`@stable(since =
"1.2")`) — writes raw bytes to stdout verbatim, no text encoding applied —
with a kernel implementation on all three targets:

- **dotnet** (`_kernel/console_host.l`): `Console.OpenStandardOutput()` +
  `Stream.Write(byte[], int, int)` + `Stream.Flush()`.
- **JVM** (`_kernel_jvm/console_host.l`): `System.out.write(byte[])` +
  `PrintStream.flush()`.
- **native** (`_kernel_native/console_host.l`): a new
  `lyric_console_write_bytes(fd, LyricList*)` runtime primitive
  (`lyric-rt/src/lyric_posix.c` + `lyric-rt/include/lyric_rt.h`), mirroring
  `lyric_console_write`'s `write_all` retry-on-EINTR/partial-write loop.

## `lyric-jsonrpc` audit

Checked whether `JsonRpc.Stdio` (`lyric-jsonrpc/src/stdio.l`) has the same
Content-Length bug — it does not: `clSendVia` already computes
`encodeUtf8(payload).length`, and the byte-level receive path
(`ByteSource`/`FrameBuffer`, #7451) already decodes UTF-8 only once a
frame is known complete — extensively covered by
`lyric-jsonrpc/tests/stdio_tests.l`'s existing café/😀/中文 cases. The one
residual gap: `HostStringWriter.write` (the production stdout adapter)
went through `hostConsoleWrite`'s text writer, so the correctly-computed
UTF-8 byte count depended on the platform console's default text encoding
matching UTF-8 to actually land the declared bytes on the wire. Hardened
it to `writeStdoutBytes(encodeUtf8(s))` for the same byte-exact guarantee
`lsp.l` now has, removing that implicit assumption (`Std.ConsoleHost`
import dropped, now unused).

## Tests

- `lyric-compiler/lyric/lsp_self_test.l`: 9 new cases — ASCII, a BMP
  character (é, 2 UTF-8 bytes vs. 1 UTF-16 unit), a supplementary-plane
  character (😀, 4 UTF-8 bytes vs. 2 UTF-16 units), two back-to-back
  frames splitting at exactly the right boundary, a partial header, a
  truncated body, a missing/non-numeric/negative `Content-Length` header —
  all against the pure `lspEncodeFrame`/`lspScanFrame`/`lspDecodeFrameBody`
  functions, no real stdin/stdout. Removed the 5 now-obsolete UTF-16
  surrogate-decoding cases (`lspAppendCodeUnit`/`lspFlushCodeUnits` no
  longer exist).
- `lyric-rt/test/lyric_rt_test.c`: `test_console_write_bytes` covers
  `lyric_console_write_bytes` (non-ASCII bytes, `NULL`, empty).
- `lyric-stdlib/tests/console_stdout_bytes_tests.l` (new) +
  `scripts/ci/console-stdout-bytes-test.sh` (new): writes a café/😀/中文
  payload via `writeStdoutBytes` and nothing else, byte-diffed (`cmp`,
  never a shell string comparison) against the expected UTF-8 encoding.
  Wired into `ci.yml` next to the existing stdin byte-reader checks (after
  `console-stdin-test.sh` on dotnet and on JVM) and into
  `scripts/ci/native-target-smoke-test.sh` for `--target native`.
- Manual end-to-end verification (not checked in — see below): spawned
  `./bin/lyric lsp` as a real subprocess, sent `initialize`, opened a
  document whose doc comment contains `café 😀 中文`, requested hover, and
  asserted the response contains the exact non-ASCII text byte-for-byte;
  `shutdown`/`exit` then closed the process cleanly (exit 0). Not added as
  an automated self-test: an in-process `@test_module` cannot locate the
  built `./bin/lyric` binary path portably across CI/sandbox layouts, and
  the pure-function unit tests already cover the exact byte-length
  semantics this bug was about.
- Ran locally (this session): `lsp_self_test.l` (12/12); `lyric-jsonrpc`'s
  full suite (118 tests: json/jsonrpc/stdio) on `--target dotnet` and
  `--target jvm` (0 failed both); `lyric-mcp`'s full suite (43 tests,
  including `mcp_stdio_process_tests.l`'s real-subprocess NDJSON framing)
  on `--target dotnet`; `console-stdout-bytes-test.sh` on dotnet, jvm, and
  native; `make -C lyric-rt test` (native runtime unit tests, including
  the new one); `bash scripts/ci/compiler-self-tests-batch.sh` (0 `not
  ok`); `bash scripts/ci/jvm-generics-self-tests-batch.sh` (0 `not ok`);
  `bash scripts/audit-axioms.sh` (no drift — the new kernel functions sit
  inside files with an existing file-level `@axiom` line, no new axiom
  string introduced); `bash scripts/ci/check-workflow-size.sh` (still
  under the soft ceiling).

## Docs

- `docs/10-stdlib-plan.md`'s `Std.Console` row documents `writeStdoutBytes`.
- `book/chapters/appendix-b-quick-reference.md`'s `Std.Console` row lists it.
- `docs/62-jsonrpc-mcp.md` §3's note that the LSP server's Content-Length
  framing "carries a documented UTF-8-length caveat" is updated — that
  caveat is what this fixes; the LSP server's own migration onto
  `JsonRpc`/`JsonRpc.Stdio` (Q-RPC-002) remains open, unrelated to this
  byte-framing fix.

## Out of scope

- Migrating `lsp.l` onto `JsonRpc.Stdio` wholesale (Q-RPC-002,
  docs/62-jsonrpc-mcp.md §3) — a larger refactor, not needed to fix the
  framing bug itself.
- `docs/16-lsp-vscode-plan.md` was checked and does not describe framing
  byte semantics (only a stale `JsonRpc.fs` reference from the pre-self-
  hosted era), so it needed no edit.
