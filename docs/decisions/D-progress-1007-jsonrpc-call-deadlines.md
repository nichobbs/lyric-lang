# D-progress-1007 — Deadlines for JSON-RPC calls and bounded transport reads (#7451)

**Status:** shipped

Fixes #7451 (follow-up to #7245 item 2 and D-progress-0996, which bounded
the queue `call` fills while it waits but not the wait itself).

## Problem

`JsonRpc.call` sent a request and then read the transport until the
matching response arrived. `RpcTransport.receive()` blocks with no bound, so
a peer that never answered — and never closed its end — hung the caller for
ever. For `lyric-mcp`'s client, which talks to a spawned server process,
that meant one wedged server wedged the agent that called it. A deadline
could not be added inside `call` alone: nothing below it could wait with a
bound.

## Decision

1. **The transport seam gains a bounded receive.** `RpcTransport` adds
   `receiveWithin(timeoutMs): Result[ReceiveOutcome, String]`, with
   `ReceiveOutcome = RpcMessage(text) | RpcEndOfStream | RpcTimedOut`. Its
   contract: a timeout loses nothing — a partly received message stays
   buffered and is returned whole by a later receive. This is a breaking
   change for code that implements `RpcTransport` itself; the library is
   `@experimental` at 0.x, and every implementation in the repository is
   updated.

2. **Every call has a deadline; none is unbounded.** `callWithin(peer,
   method, params, timeoutMs)` takes one per call. `call` keeps its
   signature and applies the peer's call timeout, a new `RpcPeer` field set
   by `newPeer` to `defaultCallTimeoutMs` (60 000 ms) or chosen with
   `newPeerWithTimeout` / `setCallTimeout`. There is deliberately no "wait
   for ever" setting: timeouts range over 1 ms to `maxCallTimeoutMs`
   (24 h), enforced by `requires: isValidCallTimeout(...)`. 60 s matches
   the MCP SDKs' default request timeout; a tool that waits on a person
   should use `input_required` (docs/64 §3.1) rather than a long deadline.

3. **One deadline per call, fixed when the request is sent.** Each wait on
   the transport is given only the time left (monotonic clock,
   `Std.Time.monotonicNanos`). Inbound requests and notifications that
   arrive while waiting are queued as before and do not extend it.

4. **A timeout is a typed local error with its own code.** The call returns
   `RpcError(code = requestTimedOut, ...)`, `requestTimedOut = -32001`,
   with `data = {"timeoutMs": N}`; `isTimeoutError(e)` tests for it. The
   issue proposed `internalError`, but callers need to tell "the peer is
   slow" from "the transport broke" without parsing messages, and `-32001`
   is inside the range JSON-RPC 2.0 §5.1 leaves to implementation-defined
   server errors and is the code the MCP SDKs use for a request timeout.
   Transport failure, end of stream, malformed input and queue overflow
   stay `internalError`. Nothing is sent to the peer: JSON-RPC 2.0 has no
   cancellation, and MCP's `notifications/cancelled` is out of scope here.

5. **A late response is dropped, never mis-delivered.** Request ids are
   allocated monotonically and never reused, so no pending-request table is
   needed: the timed-out id matches no later call (`classifyForCall`
   ignores it) and `runLoop` drops it as an unsolicited response.

6. **Bounded reads are real on every transport, at the kernel.**
   - `Std.Process.pipedReadLineWithin(p, timeoutMs)` (public union
     `PipedReadOutcome`). dotnet: the blocking `StreamReader.ReadLine()`
     runs on a thread-pool thread (`Task.Run`) and the caller waits with
     `Task.Wait(int)`; a timed-out read stays outstanding on the handle and
     the next read of either kind joins it, so nothing is lost or
     reordered. JVM: the existing `available()`-polled loop checks the
     deadline where it would otherwise sleep. Native: lyric-rt's
     `lyric_process_piped_read_line_within` `poll(2)`s the pipe; partial
     lines stay in the handle's buffer on all three.
   - `Std.Console.openStdinReader` / `readStdin` / `readStdinWithin`
     (public union `StdinChunk`): raw stdin bytes with a bounded wait.
     dotnet: `Stream.Read` on `Console.OpenStandardInput()` behind
     `Task.Run` + `Task.Wait(int)`. JVM: a daemon platform
     thread (`new Thread(Runnable)` over a record implementing `Runnable`,
     `setDaemon(true)` so it never keeps the JVM alive; not a virtual thread,
     since a read blocked on `System.in` would pin its carrier and
     `startVirtualThread` needs JDK 21) joined with `Thread.join(long)`;
     `available()` polling is not used because it cannot tell end of
     stream from silence. Native has no console input yet (existing gap,
     `_kernel_native/console_host.l`), so this API is dotnet/JVM.
   New externs live only in `_kernel*/` files; `docs/17-axiom-audit.md`
   records the widened `@axiom`s.

7. **The stdio transports frame bytes, not characters.** `JsonRpc.Stdio`'s
   `NdjsonTransport`/`ContentLengthTransport` now read through a
   `ByteSource` seam (production: the stdin reader) into a `FrameBuffer`
   they keep for life, and cut a frame at a `\n` byte or after exactly the
   declared body bytes, decoding UTF-8 once the frame is complete. That is
   what makes a mid-frame timeout safe — the consumed bytes are simply
   still in the buffer — and makes the Content-Length count exact by
   construction. The character/line cores (`clReceiveVia`,
   `ndjsonReceiveVia`) stay public for other streams (`Mcp.Stdio` reuses
   the latter). The transports also take their writer as a field, so
   `newNdjsonTransportOver`/`newContentLengthTransportOver` build them
   over any byte source and writer.

8. **`lyric-mcp`'s client exposes both levels.** `setClientCallTimeout`
   bounds every operation; `callToolWithin`, `callResumableToolWithin` and
   `resumeToolCallWithin` take a per-call timeout for the calls a slow
   tool can legitimately stretch. `Mcp.Stdio.PipedNdjsonTransport`
   implements `receiveWithin` over `pipedReadLineWithin`.

## Alternatives rejected

- **A generic background-worker wrapper around `receive()`** (no interface
  change). It would work for any transport on dotnet, but the JVM target
  has no bridge from a Lyric closure to a thread outside `spawn`/`scope`,
  and a `scope` join has no bound. Per-kernel bounded reads are also
  cheaper: no thread hop unless a wait is actually bounded.
- **A replay buffer over the char-level `CharReader`** (re-feed consumed
  code units after a timeout). Correct, but it needs a per-code-unit
  timed read, which on dotnet costs a thread hop per character. Byte
  chunks cost one per read.
- **Keeping `call` unbounded and adding only `callWithin`.** It leaves the
  default path — the one every existing caller uses — open to the hang the
  issue reports.

## Verification

- `lyric-jsonrpc`: 48 + 31 + 30 tests, dotnet and JVM — silent peer times
  out with `requestTimedOut` (elapsed time checked), each wait bounded by
  the time left, late response dropped by both the next call and
  `runLoop`, queued notifications do not extend the deadline, end of
  stream is not a timeout, contract violations; byte framing across split
  reads, CRLF, multi-byte UTF-8, timeouts mid-line and mid-body, limits.
- `lyric-mcp`: 31 + 36 + 7 tests, dotnet and JVM — including real child
  processes: a silent `sleep` server times out a `callToolWithin`, and an
  `sh` server that answers late has its stale answer dropped while the
  next call gets its own. `mcp_stdio_process_tests.l` is no longer gated
  to dotnet.
- `lyric-stdlib/tests/process_tests.l` (dotnet + JVM): timeout, late line,
  partial line kept across a timeout, end of stream, negative-timeout
  precondition. `console_stdin_tests.l` via
  `scripts/ci/console-stdin-test.sh` (dotnet + JVM) with a controlled
  stdin. The native read is covered by `lyric-rt`'s C tests and an
  ASan-built `llvm_stdlib_self_test.l` case.
