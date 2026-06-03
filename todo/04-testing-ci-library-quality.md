# Tier 4 — Testing, CI, and Library Quality

## Issues
- **#743** — `ProcessCapture.fs` original issue: `runCapture` compat path now silently drops stderr
- **#1118** — SMTP cc/bcc/attachments/replyTo silently dropped in `NativeSender.send`
- **#1103** — JVM regex: implement daemon-thread timeout shim for ReDoS protection (`.NET` done; JVM gap)
- **#1071** — `sensitive_url_tests.l` only covers `InProcessSessionStore`; Redis URL credential masking untested
- **#1119** — `lyric-stdlib/tests/rest_tests.l` missing (stable `RestClient.json` API has no tests)
- **#1065** — JVM `ProcessCaptureHost.runCaptureWithTimeout` Java implementation not shipped
- **#1080** — CI ecosystem test step hardcodes `Debug` build path
- **#1110** — CI ecosystem `cp` for `Lyric.Stdlib*.dll` uses unguarded glob that could fail silently
- **#1117** — Re-add coverage visibility via `XPlat Code Coverage` collector
- **#1116** — Windows-compatible `Std.Process` test fixtures needed
- **#1125** — `bootstrap.sh` per-host cleanup list hardcoded to 7 libraries, misses 14+ others
- **#1126** — `testDiagnosticsSpawnFailure` missing stdout/stderr empty assertions
- **#1098** — `import Auth as Auth` in test file is a no-op alias

## Prompt

You are working on the **lyric-lang** repository. Read `CLAUDE.md` fully before doing anything else.

Your task is to fix all thirteen issues in this tier. These are testing, CI, and library-quality issues — no new language features are required. Work on a new branch named `fix/tier4-testing-ci-quality`. Open a **draft** PR immediately after your first commit. Keep it draft until every acceptance criterion below is green. Rebase onto `main` at the start of each work session and before marking ready. Push after every coherent batch of changes.

F# changes are permitted only for thin shim corrections and CI/build script fixes. All new test code goes in `.l` files. All new library behaviour goes in `.l` files.

---

### #743 — `runCapture` compat path silently drops stderr

When `Std.ProcessCapture.runCapture` (the backward-compatible entry point) calls the new `hostRunCapture`, it discards `stderr` from the result and returns only `stdout`. Any caller that relied on seeing subprocess stderr in the console will silently lose that output.

**Fix:** Update the `runCapture` doc-comment to state clearly: "Stderr from the child process is silently discarded; use `runCaptureWithDiagnostics` to capture it." This is a documentation fix — the API contract should be explicit. Do not change the behaviour (that would break callers); only document it. Close #743 after the comment lands.

If `ProcessCapture.fs` itself still has any remaining issue with the original bug (stderr not being redirected in some code path), fix that too — verify by reading the current state of the file.

---

### #1118 — SMTP cc/bcc/attachments/replyTo silently dropped

`NativeSender.send` (in `lyric-mail/src/mail.l`) passes only `from`, `to`, `subject`, `bodyText`, and `bodyHtml` to the SMTP kernel. The `cc`, `bcc`, `attachments`, and `replyTo` fields of `EmailMessage` are silently ignored.

**Fix (two options — choose the one that matches actual kernel capability):**

*Option A:* If the current SMTP kernel extern (`smtpSend` in `mail_kernel.l`) does not yet support cc/bcc/attachments (they are tracked in #780), add `requires:` preconditions to `NativeSender.send`:
```
requires: msg.cc.length == 0
requires: msg.bcc.length == 0
requires: msg.attachments.length == 0
```
This surfaces a contract violation at runtime rather than silent data loss. Add a doc-comment on `NativeSender.send` and on the `MailSender` interface noting the current limitation and citing #780.

*Option B:* If the SMTP kernel extern can be extended cheaply to support cc/bcc (they are standard `SmtpClient` fields), extend `smtpSend`'s typed parameters to include `ccAddresses: slice[String]` and `bccAddresses: slice[String]`, wire them through `mail_kernel.l` and `MailHost.fs`, and add tests.

Do not leave the current state (silently accepting cc/bcc and doing nothing with them). Choose the option that reflects actual completeness.

---

### #1103 — JVM regex ReDoS timeout gap

The `.NET` path for `Std.Regex` uses `Regex(pattern, options, TimeSpan.FromSeconds(1))` to enforce a timeout. The JVM path in `lyric-stdlib/std/_kernel_jvm/regex.l` has a known gap — Java's `Pattern` has no built-in match timeout.

**Fix:** Implement the daemon-thread interrupt approach for JVM:
1. Before calling `matcher.find()` / `matcher.matches()`, schedule a daemon thread to call `Thread.interrupt()` on the matcher thread after the timeout.
2. Catch `InterruptedException` from the matcher and map it to the `Err(TimedOut)` variant, matching the `.NET` error shape.
3. Cancel the interrupt thread if the match completes in time.

This goes in `lyric-stdlib/std/_kernel_jvm/regex.l` (or the corresponding Java shim class if the kernel binds to a Java class). Do not add F# code.

Add a JVM-specific test in `lyric-stdlib/tests/regex_tests.l` (guarded `@cfg(feature = "jvm")`) that verifies a catastrophic pattern times out and returns `Err(TimedOut)` rather than hanging.

---

### #1071 — `sensitive_url_tests.l` only covers `InProcessSessionStore`

`lyric-session/tests/sensitive_url_tests.l` verifies that Redis connection URLs with embedded credentials are not logged in plaintext. However, it only exercises the `InProcessSessionStore` code path. The Redis URL credential-masking logic in the actual `RedisStore` path is untested.

**Fix:** Add test cases that exercise the Redis URL path. Since real Redis is not available in CI, use the `@externTarget` shim pattern or a mock: create a `MockRedisStore` (or use the existing test mock infrastructure if one exists in `lyric-testing`) that records the connection URL it was given, then assert that the URL passed to it has credentials redacted.

Alternatively, extract the URL-masking function into a standalone pure function and test it directly without needing a real Redis connection.

---

### #1119 — `rest_tests.l` missing for `RestClient.json`

`lyric-stdlib/std/rest.l` exports `RestClient.json`, a `@stable(since="1.0")` function with non-trivial ownership semantics (caller must call `disposeJson`). There is no `lyric-stdlib/tests/rest_tests.l`.

**Fix:** Create `lyric-stdlib/tests/rest_tests.l` with tests covering:
- Happy path: construct a mock `HttpResponse` with a valid JSON body; call `RestClient.json`; verify `rootElement` is accessible; call `disposeJson`.
- `Err` path: a response where `bodyText` fails returns `Err(Http(Transport(...)))`.
- Ownership contract: calling `disposeJson` after successful extraction does not panic.

The tests must be runnable via `lyric test --manifest lyric-stdlib/lyric.toml` (or the stdlib test runner). Use `Std.Testing` throughout.

---

### #1065 — JVM `ProcessCaptureHost.runCaptureWithTimeout` not shipped

**Addressed by Tier 9** — see `todo/09-jvm-parity.md` §#1065 for the full implementation spec (the Java class, parallel stdout/stderr threads, `process.waitFor(timeout, MILLISECONDS)`, etc.).  Listed here because the work removes the `KNOWN GAP` note from `lyric-stdlib/std/_kernel_jvm/process_capture_host.l`, but the natural owner is the JVM-parity tier — do not duplicate the implementation effort.

---

### #1080 — CI hardcodes `Debug` build path

`.github/workflows/ci.yml` has a step that hardcodes `bin/Debug/` in a path. If the build configuration changes to `Release` or a custom config, the step silently passes without exercising anything.

**Fix:** Replace the hardcoded `Debug` path with `${{ env.BUILD_CONFIG }}` (or equivalent) driven by a matrix variable or a workflow-level env var. Alternatively, use `find` to locate the built artifact by name rather than by path.

---

### #1110 — CI ecosystem `cp` for `Lyric.Stdlib*.dll` uses unguarded glob

The CI ecosystem test step uses a glob like `cp Lyric.Stdlib*.dll ...` that could match zero files and silently proceed. If the DLL is not found, subsequent tests run without it and may pass for the wrong reason.

**Fix:** Add an existence check before the `cp`, or use `cp --no-dereference --verbose` and fail the step if the exit code is non-zero. Alternatively, use an explicit path that fails loudly if the file is missing.

---

### #1117 — Re-add coverage visibility

Coverage collection was removed from CI. Re-add it using `dotnet test --collect:"XPlat Code Coverage"` (the built-in collector, which is more reliable with Expecto-based projects than the external `coverlet.console` tool). Upload the coverage report as a CI artifact. Do not add a blocking gate — coverage is informational.

Add the step only to the main CI workflow (not PR checks) to avoid adding latency to every PR run.

---

### #1116 — Windows-compatible `Std.Process` test fixtures

`lyric-stdlib/tests/process_tests.l` uses `sh -c "..."` which does not exist on Windows. Add a platform guard (`@cfg(feature = "posix")` or equivalent) to skip the POSIX-specific tests on Windows, and file (or reference) a tracking issue for Windows-compatible fixtures.

The tracking issue should propose using `cmd /c` equivalents or a cross-platform test helper, not just skip the tests forever.

---

### #1125 — `bootstrap.sh` cleanup list hardcoded

The `rm -rf` block in `scripts/bootstrap.sh` that cleans up `stage0-publish-*` directories explicitly names 7 libraries. The repo has 21+ ecosystem libraries, each producing its own directory. The other 14+ are never cleaned.

**Fix:** Replace the hardcoded list with a glob: `rm -rf "$BUILD_DIR"/stage0-publish-*`. This cleans all per-library publish directories without needing updating as new libraries are added. Verify the glob does not accidentally match anything it shouldn't.

---

### #1126 — `testDiagnosticsSpawnFailure` missing assertions

`lyric-stdlib/tests/process_capture_tests.l` — the `testDiagnosticsSpawnFailure` test asserts `exitCode == -1` but does not assert that `stdout` and `stderr` are empty strings, even though the contract comment says they should be.

**Fix:** Add `assertEqual(r.stdout, "", "spawn failure stdout must be empty")` and `assertEqual(r.stderr, "", "spawn failure stderr must be empty")` to the test.

---

### #1098 — `import Auth as Auth` no-op alias

`lyric-auth/tests/auth_security_tests.l` has `import Auth as Auth` which aliases a module to its own name — a no-op that may indicate a misunderstanding or a left-over from an alias-rewriter test.

**Fix:** Remove the `as Auth` alias if it is indeed a no-op. If it was intentional (e.g. testing that aliasing works), add a comment explaining why. Either way, do not ship code that looks like a mistake without explanation.

---

## Acceptance Criteria

- [ ] `runCapture` doc-comment explicitly states stderr is discarded; `runCaptureWithDiagnostics` cited as the alternative
- [ ] `NativeSender.send` either has `requires: msg.cc.length == 0` contracts or properly passes cc/bcc through; no silent drops
- [ ] JVM regex timeout shim implemented; catastrophic pattern returns `Err(TimedOut)` on JVM within 2 seconds
- [ ] JVM regex timeout test (`@cfg(feature = "jvm")`) passes in CI
- [ ] Redis URL credential masking tested (not just `InProcessSessionStore` path)
- [ ] `lyric-stdlib/tests/rest_tests.l` exists and covers happy path, transport error, and `disposeJson` contract
- [ ] `lyric test --manifest lyric-stdlib/lyric.toml` runs `rest_tests.l` and passes
- [ ] JVM `ProcessCaptureResult` Java class implemented; `runCaptureWithTimeout` returns `ProcessCaptureResult` with all four fields
- [ ] CI ecosystem step uses a dynamic build-config path (no hardcoded `Debug`)
- [ ] CI ecosystem `cp` for `Lyric.Stdlib*.dll` fails loudly if the file is missing
- [ ] Coverage collection re-added to main CI workflow via `XPlat Code Coverage`; report uploaded as artifact
- [ ] `process_tests.l` has platform guard for POSIX-only tests; tracking issue filed or referenced for Windows fixtures
- [ ] `bootstrap.sh` cleanup uses glob `stage0-publish-*`; no hardcoded library list
- [ ] `testDiagnosticsSpawnFailure` asserts `stdout == ""` and `stderr == ""`
- [ ] `import Auth as Auth` no-op alias removed or explained
- [ ] All existing tests continue to pass (`dotnet run --project bootstrap/tests/Lyric.Emitter.Tests`, `Lyric.Cli.Tests`)
- [ ] No new F# domain logic
- [ ] PR is draft until all criteria above are green; then marked ready for review
- [ ] Branch rebased onto `main` immediately before marking ready
