# Windows: a socket shutdown that lands before the read (D209, #8501)

Issue #8501 reported two Windows `native-tests` problems. Checked against the job logs and `main`:

- `llvm_inline_union_self_test` cases 8, 9, 16 and 18 (expected 3, actual 11011) were not an inline-union layout
  bug. Windows passes `main`'s full 32-bit result as the exit status where POSIX keeps the low byte, and those
  cases return 11011, 1037, 1001 and 943 (low bytes 3, 13, 233, 175). The failing runs predate
  `Lyric.LlvmBridge.nativeExitStatus` (#8491), and every Windows `native-tests` run since is green.
- `llvm_http_server_self_test` item E (`stopListener` on an idle keep-alive connection) was the Winsock
  shutdown gap #8491 closed with `CancelIoEx`. That cancel reaches only I/O already pending, so a handler thread
  that had answered a request and not yet issued its next `recv` when `stopListener` shut the connection down
  still blocked for good. That is a race, and it fits one failure that passed on a re-run.

`lyric_sock_shutdown` now also records a read-side shutdown per socket, and every blocking read on Windows
(`lyric_sock_read` and the Schannel `recv_more`) goes through `lyric_win32_sock_recv`, which waits in 50 ms
`WSAPoll` slices that look at the record, so a shutdown ends a read whether it began before or after it. The
socket's `SO_RCVTIMEO` is still honoured, and `lyric_sock_close` drops the record. `lyric_tls_test` gains
`test_sock_shutdown_before_read`, which shuts down first and reads second, with no sleep.
