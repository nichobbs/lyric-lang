# JSON-RPC/MCP call-deadline follow-ups (PR #7520 review, D-progress-1007)

Six non-blocking suggestions from the PR #7520 review (D-progress-1007,
"Deadlines for JSON-RPC calls and bounded transport reads", #7451) landed
here as real fixes, each verified on every target it touches.

## 1. JVM monotonic clock for piped-process deadlines

`lyric-stdlib/std/_kernel_jvm/process_piped_host.l`'s `readLineUntil` /
`pastDeadline` / `hostPipedWaitExit` / `hostPipedReadLineWithinResult` used
`System.currentTimeMillis()` (wall-clock, subject to NTP steps and manual
clock changes) for deadline arithmetic. Switched to `System.nanoTime()`
(monotonic), matching native's `lyric_monotonic_nanos()` and the pattern
`_kernel_jvm/task.l`'s `makeCancelSourceTimeout` already uses. Also
tightened `readLineUntil`'s deadline check from "once every 64 non-sleeping
iterations" to every iteration (`nanoTime()` is a cheap call); only the
CPU-spin throttle (a 1ms yield) stays capped to every 64th iteration.
`_kernel_jvm/console_host.l`'s stdin reader was named in the task but does
not need this change: its bounded read already uses `Thread.join(long)`
with a **relative** millisecond duration, never `currentTimeMillis()` for
deadline arithmetic, so it was already immune to wall-clock drift.

## 2. dotnet blocking reads move off the thread pool

`_kernel/process_piped_host.l` and `_kernel/console_host.l`'s `taskRun`
switched from `Task.Run(Action)` to
`Task.Factory.StartNew(Action, TaskCreationOptions.LongRunning)`, so each
blocking `ReadLine`/`Read` gets its own dedicated thread instead of a
thread-pool slot — under pool pressure, `Task.Run` could delay the blocking
read from even starting, making a short `Task.Wait(ms)` report a spurious
timeout even though nothing was actually stuck. Auto-FFI cannot resolve
`TaskFactory.StartNew` against a `() -> Unit` lambda argument (reference-
assembly overload scoring has no BCL delegate type to compare against until
the call commits to one overload), so both files keep an explicit
`@externInstance @externTarget("...TaskFactory.StartNew")` wrapper, the
same pattern other BCL delegate-taking members in this kernel tree use. The
"a timeout loses nothing, the next call joins the outstanding read" contract
is unchanged. Verified with `scripts/ilverify-selfhosted.sh` (0 IL-validity
errors across 126 DLLs) since closure-to-delegate construction here is
exactly the shape #7166 fixed.

## 3. `FrameBuffer.appendBytes` is amortised O(chunk), and an off-by-one at EOF is fixed

`lyric-jsonrpc/src/stdio.l`'s `FrameBuffer.bytes` was a `slice[Byte]`;
`slice[T]` is immutable (`.append`/`.concat` each return a fresh copy —
language reference §2.7), so re-concatenating the whole pending buffer on
every `appendBytes` call cost O(pending size) per append — O(message size²)
total to accumulate one large message split across many small reads.
`bytes` is now a `List[Byte]` (the same amortised-O(1)-append growable
array `Std.Encoding`/`Std.Hash`/the H2 framer already build byte
accumulators on), so appending a chunk of size n costs amortised O(n); the
consumed prefix is still dropped in one pass, but only once per frame
boundary crossed, not once per append. `ndjsonStep`/`clStep`/`decodeFrame`/
`headerLineText` were updated for the new field type (`.count` in place of
`.length`, and a new `listByteSlice` helper materialises exactly the bytes
one completed frame needs — bounded per frame, not per append).

Also fixed the off-by-one this task named: an EOF-terminated final NDJSON
line was checked against `MAX_MESSAGE_BYTES` only via the earlier
"pending bytes while still waiting for a delimiter" gate
(`> MAX_MESSAGE_BYTES + 1`, one byte looser than the `\n`-terminated path's
own `cut - start > MAX_MESSAGE_BYTES` check), so an EOF-terminated line of
exactly `MAX_MESSAGE_BYTES + 1` bytes could slip through uncaught.
`ndjsonStep`'s EOF branch now applies the identical `> MAX_MESSAGE_BYTES`
check before accepting the tail. New test:
`lyric-jsonrpc/tests/stdio_tests.l`'s "NDJSON bytes: an EOF-terminated final
line obeys the same 16 MiB limit as a newline-terminated line" (both the
16777217-byte rejection and the exact-16777216-byte acceptance).

## 4. `Mcp.Client` drains `RpcPeer.pendingQueue` after every call

`Mcp.Client` only ever calls `JsonRpc.callWithin`, never `runLoop`,
so a server-sent request/notification queued while a call waits (per
`callWithin`'s "Dispatch model" doc) was never drained — it sat there until
enough calls queued past `maxPendingMessages` (4096), after which every
later call started failing its own queue-overflow guard. Added
`JsonRpc.drainPendingQueue(peer): Result[Unit, String]`, a public library
function dispatching (or dropping, for a notification) every queued entry
exactly as `runLoop` would — a queued request with no handler answer (e.g.
`Mcp.Client`'s `NullHandler`) gets the ordinary `-32601 Method not found`
response sent back, not silently dropped, matching JSON-RPC 2.0 §4's "every
request gets some response." `Mcp.Client.requestWithin` calls it right
after `callWithin` returns, best-effort (a drain failure never shadows the
call's own already-obtained result). New test in `lyric-mcp/tests/mcp_tests.l`:
"Mcp.Client drains pendingQueue after each call: >maxPendingMessages
notifications across calls do not break later calls" — `maxPendingMessages
+ 200` rounds, each staging one interleaved server notification ahead of
its call's response; every round must still succeed.

## 5. `JsonRpc.isTimeoutError` doc caveat

Documented that `isTimeoutError` matches on the wire-level `-32001` code
alone, which a remote peer can legitimately send for its own reasons — the
function cannot distinguish a local deadline from a remote `-32001`
failure. Typed `Mcp.Client` errors that would carry this distinction
natively are tracked separately (#7522); not attempted here.

## 6. `docs/17-axiom-audit.md` JVM stdin reader description

Corrected "uses a virtual thread and `Thread.join(long)`" to match
`_kernel_jvm/console_host.l`'s actual implementation: a **daemon platform
thread** (`new Thread(Runnable)` + `setDaemon(true)`), not a virtual
thread — a blocking read on `System.in` pins a virtual thread's carrier,
which is exactly why the kernel avoids one (see that file's own module
doc). `scripts/audit-axioms.sh --update` regenerated the §19 baseline
after the two `@axiom` string changes from item 2 (`Task.Run/Wait` →
`TaskFactory.StartNew/Wait`); `scripts/audit-axioms.sh` (no flags) then
passes clean.

## Verification

- `./bin/lyric test --manifest lyric-jsonrpc/lyric.toml` — 3 suites, 38 +
  31 + 3 pass, 0 fail (`--target dotnet` and `--target jvm`, including the
  new EOF-boundary test).
- `./bin/lyric test --manifest lyric-mcp/lyric.toml` — 4 suites, 32 + 36 +
  7 pass, 0 fail (`--target dotnet` and `--target jvm`, including the new
  pendingQueue-drain test and the real-subprocess `PipedHost` tests that
  exercise both the `TaskFactory.StartNew` and JVM `nanoTime()` changes).
- `bash scripts/ci/jvm-ecosystem-suites.sh` — storage/resilience/jsonrpc/mcp/
  health, all pass.
- `bash scripts/ci/console-stdin-test.sh ./bin/lyric` and `--target jvm` —
  both pass.
- `lyric-stdlib/tests/process_args_tests.l` (`lyric test`), `process_tests.l`
  and `process_capture_tests.l` (`lyric run`) — pass on dotnet.
- `bash scripts/ci/native-target-smoke-test.sh` — passes (native's process/
  console kernels were not touched by this change; the smoke suite is
  otherwise green).
- `bash scripts/ilverify-selfhosted.sh bootstrap/src/Lyric.Cli.Aot/bin/Release/net10.0/lyric`
  — 126 DLLs, 0 IL-validity errors.
- `bash scripts/audit-axioms.sh` — passes against the updated §19 baseline.
- `lyric-rt` was not touched, so `make -C lyric-rt test` was not run.

## Changed files

- `lyric-stdlib/std/_kernel_jvm/process_piped_host.l`
- `lyric-stdlib/std/_kernel/process_piped_host.l`
- `lyric-stdlib/std/_kernel/console_host.l`
- `lyric-jsonrpc/src/stdio.l`
- `lyric-jsonrpc/src/jsonrpc.l`
- `lyric-jsonrpc/tests/stdio_tests.l`
- `lyric-mcp/src/client.l`
- `lyric-mcp/tests/mcp_tests.l`
- `docs/17-axiom-audit.md`
- `docs/progress/2026-09-27-jsonrpc-mcp-deadline-followups.md` (this file)
