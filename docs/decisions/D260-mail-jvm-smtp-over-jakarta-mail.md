# D260 — lyric-mail SMTP on the JVM over Jakarta Mail; library internals stay non-`pub`

**Status:** accepted, implemented (#7462, #7668)

Completes #7462 (SES and SendGrid were already shared Lyric over `Std.Http`,
PR #8505) and the remaining items of #7668 (PR #8513 fixed restored-contract
resolution of `JsonElement`).

## Context

`Mail.Kernel.Jvm` reported SMTP as not implemented; no test exercised SMTP
delivery on either target.  `lyric-search` made its response parsers `pub`
only so the tests in another package could call them, which put
`Std.Json.JsonElement` into the library's restored contract.

## Decision

1. **SMTP on the JVM is Jakarta Mail**, `jakarta.mail:jakarta.mail-api` plus
   `org.eclipse.angus:angus-mail` from the library's `[maven]` table, bound
   with `extern type` auto-FFI in `src/_kernel/jvm/mail_kernel.l`.
2. **The wire between `Mail` and the kernel stays the JSON document
   `Mail.messageToJson` builds**, parsed in the kernel with `Std.JsonValue`.
   The public layer is unchanged and the escaping tests still pin the format.
3. **A handle holds settings, not a socket.**  `connectSmtp` records the
   `Session`; each `send` opens a transport, delivers and closes it, so an idle
   timeout never leaves a dead connection behind.  Like the .NET kernel,
   `connectSmtp` dials nothing: an unreachable server is a `SEND_ERROR` from
   the first send.
4. **Message shape matches the .NET kernel**: HTML body when present, else the
   text body; attachments make a `multipart/mixed`.  Attachment parts are built
   from the caller's base64 text (`MimeBodyPart(InternetHeaders, byte[])`)
   instead of decoding and re-encoding, which also avoids the `DataSource`
   interface, which JVM auto-FFI cannot yet call through.
5. **Tests run a real server.**  `scripts/ci/smtp_capture_server.py` records
   the envelope and DATA of each delivery; the gated round-trip tests in
   `mail_tests.l` send through `Mail.connectSmtp()` on both targets and
   `scripts/ci/smtp_verify.py` parses what arrived.  STARTTLS is not covered.
6. **Library-internal helpers are not `pub`.**  The `lyric-search` request
   builders and response parsers are private; its tests are a `@test_module` of
   package `Search` (D245) and reach them there.  A consumer's restored
   contract then carries only the real API.

## Consequences

Running the round trip found two defects in the .NET path that had never been
exercised: `SmtpClient.Send` was lowered to a runtime "unsupported method"
throw (no mail was ever sent), and attachments carried no `Content-Disposition`
filename.  Both are fixed in the same change.  `lyric test` of a consumer no
longer prints a spurious "Access to the path ... is denied" for a dependency
whose package is a directory.
