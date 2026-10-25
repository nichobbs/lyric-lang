# lyric-mail SMTP on the JVM; Lyric.Search consumer builds on both targets (#7462, #7668)

- **JVM SMTP.** `Mail.Kernel.Jvm` binds Jakarta Mail through `[maven]` and
  `extern type` auto-FFI and delivers real mail (D260).  `connectSmtp()` now
  succeeds on both targets.
- **Round trip in CI.** `scripts/ci/smtp-roundtrip-e2e.sh` runs the whole
  `lyric-mail` suite on dotnet and jvm against `scripts/ci/smtp_capture_server.py`
  and verifies the captured messages (`scripts/ci/smtp_verify.py`): envelope
  with Bcc, address headers and display names, a non-ASCII subject, HTML-over-text
  bodies, `multipart/mixed`, attachment filename and bytes, an unreachable
  server and bad credentials.  New CI step "SMTP round trip" in the ecosystem
  job.
- **.NET defects the round trip exposed.** `SmtpClient.Send` never sent (the
  call was lowered to a runtime throw; now bound by a declared-signature
  extern), and attachments had no `Content-Disposition` filename.
- **`Lyric.Search` consumer.** After #8513 the restore itself works; this adds
  `scripts/ci/search-consumer-e2e.sh` (build, run and `lyric test` of a
  dependent project on dotnet and jvm, in the compiler self-test batch), removes
  the spurious "Access to the path ... is denied" that `lyric test` printed for
  a directory-form dependency package (it now reads the sources through
  `readDepEntrySources`, as `lyric build` does), and makes the `es*`/`ms*`
  parsers, builders and backend functions private, with the search tests moved
  into package `Search` (D245).
