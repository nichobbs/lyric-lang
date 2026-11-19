# Native on macOS: bounded and try writes no longer wait on a full send buffer; per-suite limits in the native platform suite

The `macos` job of the "Native platforms" workflow ran into its 90-minute limit on every run after #9129 merged (2026-11-15), where it used to take about 34 minutes. GitHub keeps no log for a job that times out, so the suite that hung was unknown.

## The hang

`make -C lyric-rt test` never finished on macOS: `lyric_tls_test`'s `test_sock_write_bounded` (added by #9129) writes to a peer that never reads and expects `LYRIC_BOUNDED_DEADLINE` after 300 ms. `sample` on the stuck process showed every sample in one stack:

```
main -> lyric_sock_write_bytes_bounded -> __sendto
```

`lyric_sock_write_bytes_bounded` and `lyric_sock_try_write_bytes` sent with `MSG_DONTWAIT` on a blocking socket. Linux honours the flag. XNU does not for a full send buffer: the flag only keeps `send` from waiting for the buffer's lock, and the call still sleeps until the peer reads or `SO_SNDTIMEO` passes, however small the write (a 1 KiB send in a loop blocks the same way). So on macOS a bounded plain write ignored its deadline and its wake pipe, and an async `hostWrite` to a slow peer blocked its scheduler thread. `test_sock_try_ops` had not caught the second case because its sockets carry a 5-second send timeout, which ended the blocked send with the `EAGAIN` the test expects.

## The fix

`lyric-rt/src/lyric_tls.c` ("Sends that never wait for room"): on macOS both paths ask `poll` whether the socket is writable and then send at most `SO_SNDLOWAT` bytes (2 KiB by default). A socket `poll` reports writable has at least that much room, and a send of no more than the room never waits; only the connection's own writer takes room away. Callers already loop over partial writes. Switching the socket to `O_NONBLOCK` for the one call and back was turned down for the reason D405 item 5 turns it down on Winsock: the flag belongs to the socket, so a blocking read another thread starts on the same connection meanwhile would fail. `recv(MSG_DONTWAIT)` is honoured on macOS, so the read paths are unchanged, and so is every path on Linux and Windows.

`test_sock_try_ops` now also checks that the full buffer is reported within 2 seconds, so it fails on a send that waits for the socket timeout.

## Per-suite limits

`scripts/ci/native-platform-tests.sh` runs each suite in its own process group under a watchdog (perl, since macOS has no `timeout(1)`). A suite still running after `LYRIC_SUITE_TIMEOUT_SEC` (default 600; the slowest takes about 80 seconds on Linux arm64) has its processes listed and its group killed, is reported as `suite timed out after 600s: <name>`, and the remaining suites still run. Staging the compiler bundle, about 22 minutes on Linux arm64, has its own limit (`LYRIC_STAGE_TIMEOUT_SEC`, default 3600) and is now reported like a suite. Each suite prints its elapsed time.

## Verification

On macOS 27 (arm64): `make -C lyric-rt test` passes (`lyric_tls_test` in 5 seconds; it did not finish before), `tcp_host_bounded_native_tests.l`, `http_timeout_native_tests.l` and `assert_panics_native_tests.l` pass with `--target native`, and the whole `native-platform-tests.sh` passes: 125 suites in 24 minutes 27 seconds, the slowest 64 seconds, staging the compiler bundle 9 minutes. The watchdog was exercised with a command that hangs, one that fails, one killed by a signal and one that does not exist. Linux was not run locally; the workflow's `linux-arm64` job covers it.
