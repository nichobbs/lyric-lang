# JSON-RPC call deadlines and bounded transport reads (#7451)

`JsonRpc.call` no longer waits for ever for a peer that never answers.
Every call now has a deadline: `call` applies the peer's call timeout
(60 s by default; `newPeerWithTimeout`, `setCallTimeout`) and `callWithin`
takes one per call. A timeout fails the call with `requestTimedOut`
(`-32001`, `isTimeoutError`), and a response that arrives later is dropped
rather than handed to another call. `RpcTransport` gained
`receiveWithin(timeoutMs)`, which every transport implements without losing
a partly received message. See D-progress-1007 for the design.

Beneath it, two stdlib seams now wait with a bound on the targets that
carry them:

- `Std.Process.pipedReadLineWithin` — dotnet (`Task.Run` + `Task.Wait`),
  JVM (deadline in the polling loop) and native (lyric-rt
  `lyric_process_piped_read_line_within`, `poll(2)`).
- `Std.Console.openStdinReader` / `readStdin` / `readStdinWithin` — raw
  stdin bytes with a bounded wait, dotnet and JVM (a daemon thread joined
  with a timeout).

`JsonRpc.Stdio`'s stdio transports now frame bytes through a `ByteSource`
seam and a `FrameBuffer`, so a timeout in the middle of a message keeps its
bytes for the next receive. `lyric-mcp`'s client gained
`setClientCallTimeout` and the per-call `callToolWithin`,
`callResumableToolWithin` and `resumeToolCallWithin`, and its piped
transport reads through `pipedReadLineWithin`.

Verified on dotnet and JVM: `lyric-jsonrpc` (109 tests), `lyric-mcp` (74
tests, including real silent and late-answering child processes),
`lyric-stdlib/tests/process_tests.l`, and the new
`lyric-stdlib/tests/console_stdin_tests.l` (run with a controlled stdin by
`scripts/ci/console-stdin-test.sh`); on native, `make -C lyric-rt test`
and a new `llvm_stdlib_self_test.l` case (ASan). CI now runs the `lyric-jsonrpc` and `lyric-mcp` suites on the JVM,
and `mcp_stdio_process_tests.l` is no longer gated to dotnet.

Docs: docs/62 §3–§5.2, docs/64 §3.4/§6, docs/17 (axioms),
docs/10-stdlib-plan.md, `lyric-jsonrpc/README.md`, `lyric-mcp/README.md`,
book chapter 12 and appendix B.
