# D-progress-887 — Native `Std.ProcessPipedHost`: real fork/pipe long-lived piped-child-stdio kernel over a new `lyric-rt` seam (#6142); `Std.Process`'s shared facade found genuinely unreachable on native by two independent, newly-filed compiler gaps

**Status:** shipped

**What shipped.** `_kernel_native/process_piped_host.l` — previously a
stub whose every function unconditionally panicked with a message
pointing at this issue (see that file's own prior header) — now
implements the real long-lived piped-child-stdio contract
`_kernel/process_piped_host.l` (dotnet) and `_kernel_jvm/
process_piped_host.l` document: spawn a child with only its stdin and
stdout piped (stderr inherited from this process, never captured), then
read/write lines, check liveness, kill, wait-with-timeout, read the exit
code, close stdin alone, or close everything — matching lyric-mcp's
stdio-transport motivating use case (docs/62 §5.2).

**`lyric-rt`: a new seam, deliberately separate from `spawn_capture`.**
`lyric_process.c` already had a fork/execvp/pipe helper
(`spawn_capture`), but it unconditionally pipes ALL of stdin/stdout/
stderr for its "capture everything, drain to completion" batch model —
reusing it here would mean either capturing-but-never-draining stderr
(risking the child deadlocking on a full, un-drained OS pipe buffer the
moment it logs enough — exactly the failure mode the dotnet/JVM twins'
"stderr inherited" contract exists to avoid) or a nonblocking-pump
rewrite this handle shape doesn't need. `spawn_piped` is a new, smaller
sibling: only stdin/stdout pipes, fd 2 left completely untouched so it
stays inherited, same D-N-025 own-process-group + low-fd-aliasing-guard
discipline as `spawn_capture`. The held handle
(`LyricPipedProc`: pid, stdin/stdout fds, a line-buffer, cached reap
state) uses BLOCKING pipe fds (unlike `spawn_capture`'s nonblocking,
poll-multiplexed ones): a caller holds this handle across many separate
top-level calls with no single loop driving both directions at once —
the same model `Std.TcpHost`'s `hostRead`/`hostWrite` already use for a
connection, not a new pattern. Eight new C entry points: `_spawn`
(returns `NULL` only on a genuine pipe/fork failure — an `execvp`
failure inside the child is exit code 127 once observed, not a spawn
failure, matching `lyric_process_run`'s identical convention),
`_read_line` (buffers until a `\n` — a `\r` immediately before it
stripped, matching `.NET`'s `StreamReader.ReadLine()` and the JVM twin's
own byte-level splitter — returns a final unterminated remainder once
at EOF, then reports "no more lines" forever after), `_write_line`
(blocks until the whole line + `\n` is accepted), `_is_alive`/
`_wait_exit`/`_exit_code` (a shared WNOHANG-then-blocking reap, cached
once observed since a second `waitpid` on an already-reaped pid fails
`ECHILD`), `_kill` (SIGKILL the whole process group, idempotent-safe),
`_close_stdin`, `_close`.

**Lyric-side representation: the handle is a `Long`, not a
`NativePtr[Byte]`** — the exact same reasoning `_kernel_native/
tcp_host.l`'s `Conn.tlsConnHandle` already established (D-progress-712):
`PipedHandle` must survive across separate top-level calls, and the
mode checker's N0100 boundary rejects a `NativePtr[T]` record/union
field unconditionally (heap storage outlives any frame), so the raw
`void*` rides as an `i64` at both the extern-func return and parameter
positions.

**Argument parsing: `Std.Process.spawnPiped` builds one quoted STRING
for every target, but native's `fork`+`execvp` needs a real argv
LIST with no shell involved.** `Std.Process.buildArgString` produces a
space-separated `"..."`-token string (the same shape `ProcessStartInfo
.Arguments` expects on dotnet, which the CLR re-parses); native has no
such re-parser, so this file's `parseArgString` re-materializes the
list — reusing the SAME token-scanning algorithm `_kernel_jvm/
process_capture_host.l`'s own `parseArgString` already uses to solve
the identical problem for `ProcessBuilder`'s `List<String>`
constructor, minus the `executable`-prepend step JVM's version needs
and native's `rtPipedSpawn` doesn't (it takes the executable path as
its own separate parameter, exactly like `rtProcessRun`). Writing this
parser surfaced a THIRD gap beyond the two below: copying the JVM
algorithm verbatim uses `argStr[i]` bracket indexing, which has no
native codegen lowering (issue #6237, distinct from #6588's own
`.trim`/`.indexOf`/etc additions) — fixed by rewriting every character
access as `.substring(i, 1)`, the same idiom `_kernel_native/
http_host.l`'s own header parser already uses for identical reasons.
This one IS fixed in the shipped file, unlike the two below.

**Two more gaps found by direct repro, NOT fixed here — filed as their
own issues, not silently routed around.** A minimal program calling
`Std.Process.spawnPiped` (the actual, real caller-facing API a stdio
transport would use) was compiled through
`Lyric.LlvmBridge.compileToNativeWithFlags` to verify end-to-end
reachability, not just that this kernel file itself compiles in
isolation. It does NOT reach this kernel at all:

1. `Std.Process.buildArgString` (called by `spawnPiped` before ever
   calling `hostSpawnPiped`) uses `String.replace`, which has no
   `--target native` codegen lowering — confirmed by direct repro:
   `Lyric.LlvmCodegen: method '.replace' on this receiver is not yet
   supported for --target native (no matching function 'replace/3' in
   the bundled import closure)`. Filed as issue #6888 (a
   `lyric_string_replace` seam following #6588's own precedent for
   `.trim`/`.toLower`/`.indexOf`/`.startsWith`/`.contains`/`.endsWith`).
2. `Std.Process.spawnPiped`/`pipedReadLine`/`pipedWriteLine` each wrap
   their host call in `try { } catch Bug as b { ... }`;
   `Lyric.LlvmCodegen` unconditionally panics on any `STry` node for
   `--target native` (D-N-003: no unwinding) — confirmed by direct
   repro (after working around gap 1 above with a hand-built
   already-parsed-argv test path) with the exact message `Lyric.
   LlvmCodegen: try/catch is not supported for --target native (D-N-003:
   no unwinding)`. Filed as issue #6887, recommending the SAME
   Result-seam fix issue #4752 already used to make `runCapture`/
   `runCaptureWithInput` reachable on native without `try/catch` at all.

Both are real, pre-existing, general compiler/stdlib gaps unrelated to
this kernel's own correctness — fixing either is out of this PR's scope
per this repo's "smaller, fully-finished slice over broad slice with
caveats" standard (a `String.replace` seam and a `Std.Process`
API-surface Result-seam migration are each their own self-contained
piece of work, deserving their own PR and verification, not a drive-by
fix bundled into a native-kernel-focused change). This kernel's own
functions are verified directly instead (below), and the module header
documents both gaps and their issue numbers so a future reader hits the
explanation immediately rather than rediscovering the same two panics.

**Verification.** `make -C lyric-rt test` (gcc, clang) green, including
six new C-level cases in `lyric_rt_test.c`
(`test_process_piped_line_roundtrip`, `_final_line_without_newline`,
`_crlf_stripped`, `_kill`, `_spawn_failure`, `_stderr_inherited` — the
last one redirects the TEST PROCESS's own stderr to a temp file via
`dup2`, spawns a child that writes to stderr, and confirms the bytes
land in that file rather than being captured by the kernel, the direct
proof of the "stderr never piped" contract). Clean under ASan (`gcc
-fsanitize=address`, no leaks/UB). On real Linux CI (`--target native`
via `Lyric.LlvmBridge.compileToNativeWithFlags`, real `clang`):
`llvm_stdlib_self_test.l` gained a `Std.ProcessPipedHost native kernel`
case calling `hostSpawnPiped`/`hostPipedReadLineOpt`/
`hostPipedWriteLine`/`hostPipedIsAlive`/`hostPipedKill`/
`hostPipedWaitExit`/`hostPipedExitCode`/`hostPipedCloseStdin`/
`hostPipedClose` DIRECTLY (bypassing the two blocked `Std.Process`
functions above, exactly as `llvm_tls_self_test.l`'s own "kernel
boundary" item tests `Std.TlsHost` directly) against three real
children: `/bin/cat` (single-line round trip, three-line ordering,
`closeStdin` + final-buffered-line + clean exit), `/bin/sh -c "sleep
30"` (kill mid-run, `waitExit` timeout-then-success), and a nonexistent
executable (exit 127, not a spawn failure) plus `/bin/echo` with a
quoted multi-word argument (proving `parseArgString`'s real quote/
escape handling, not just the no-args path); 19/19 cases in that file
pass, no regressions. `./bin/lyric fmt --write` applied cleanly to both
changed `.l` files.

**Related:** #6142 (this entry's issue), #6887 (`try/catch`-on-native,
filed here), #6888 (`String.replace`-on-native, filed here), #6237
(`String[i]` bracket indexing, the third gap this entry's own
`parseArgString` fixed rather than filed), #6588 (the precedent
`.replace`'s eventual fix would extend), #4752 (the Result-seam
precedent #6887 recommends), D-progress-712 (`Conn.tlsConnHandle`'s
identical `Long`-as-pointer-handle precedent), docs/62 §5.2 (the
motivating lyric-mcp stdio transport).

**Addendum: `lyric_process_piped_close`/`hostPipedClose` double-free/
use-after-free fixed (#6975, found in review of this same change before
merge).** An earlier version of `lyric_process_piped_close`
unconditionally `free()`'d the handle struct; a second call on the same
handle then read-and-freed already-freed memory — a real double-free the
function's own "safe to call during best-effort cleanup" doc comment
directly invited, unlike `lyric_process_piped_kill`/`_is_alive`/
`_close_stdin` in the same file, which were already internally
idempotent. Fixed with a `closed` guard flag, but — unlike those three
functions — WITHOUT ever calling `free()` on the struct itself: there is
no way to safely check "was this pointer already freed" by dereferencing
that same pointer, so a genuinely idempotent close cannot also fully
free the handle. The struct (small, fixed-size) is deliberately retained
for the rest of the process's life once closed instead, using the same
sanctioned, disclosed, bounded `lyric_lsan_ignore_leak` suppression this
codebase already established for the analogous #6802 case (now
documented as having two callers, not one) — the fds and line buffer,
the actually scarce resources, are still fully released on first close.
Also added the same `closed: Bool` guard at the Lyric level
(`PipedHandle`, mirroring `Std.HttpServer`'s `HttpListener.stopped`
precedent) as defense in depth, so the common case never even reaches
the extern boundary a second time. New C-level regression test
(`test_process_piped_double_close`, `lyric_rt_test.c`) calls
`lyric_process_piped_close` twice on the same handle, verified clean
under a manual ASan build of `lyric_rt_test.c` (no crash, no leak
report — confirming the suppression actually works, not just that the
code compiles). Re-verified: `llvm_stdlib_self_test.l` 19/19, all
`lyric-rt` C tests (plain + ASan) green.

**Addendum: NULL-deref in `lyric_process_piped_read_line` after
`hostPipedClose` when a line was still buffered (#6993, found in
review of this same PR before merge).** The #6975 addendum above
freed `p->linebuf.data` and set it `NULL` on close, but never reset
`p->linebuf.len` to `0`. Since the struct itself is deliberately
retained after close (see the #6975 addendum), the pointer stays
dereferenceable — but if a caller closed a handle while a second,
not-yet-consumed line was still sitting in `linebuf` (`len > 0`), the
NEXT `hostPipedReadLineOpt`/`lyric_process_piped_read_line` call would
scan `p->linebuf.data[i]` for a newline with `data == NULL` and
`len > 0`: a NULL-pointer read on the very first loop iteration. Fixed
by also resetting `p->linebuf.len = 0` and `p->linebuf.cap = 0`
alongside the existing `data = NULL`, so a post-close read correctly
falls through to `linebuf.len > 0` being false and `stdout_rd < 0`
(also set on close) and returns `0` ("no more lines") instead of
dereferencing anything. New C-level regression test
(`test_process_piped_read_after_close_with_buffered_line`,
`lyric_rt_test.c`): spawns `printf "a\nb\n"` (both lines delivered in
one `read(2)`, so the first `read_line` call buffers both and returns
only `"a"`, leaving `"b\n"` in `linebuf`), closes the handle with that
second line still buffered, then calls `read_line` again and asserts
it returns `0` cleanly. Verified this test genuinely reproduces the
bug on the pre-fix code (a real `AddressSanitizer: SEGV` inside
`lyric_process_piped_read_line`, not a hypothetical) before confirming
the fix resolves it. Re-verified: `llvm_stdlib_self_test.l` 19/19, all
`lyric-rt` C tests (plain + ASan) green.
