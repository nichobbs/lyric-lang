# lyric-mail

Email sending with pluggable provider backends: SMTP, Amazon SES, and
SendGrid, behind one `MailSender` interface.

## Platform parity

| Feature | `dotnet` | `jvm` |
|---|---|---|
| `smtp` (SMTP) | Available — `System.Net.Mail` (BCL, no extra NuGet dependency) | Available — Jakarta Mail (`jakarta.mail-api` + Eclipse Angus, restored from the `[maven]` table with `lyric restore`) behind `Mail.Kernel.Jvm` (#7462, D260) |
| `ses` (Amazon SES) | Available — SES v2 over `Std.Http` with AWS Signature V4, pure Lyric (#7462) | Same code |
| `sendgrid` (SendGrid) | Available — v3 `mail/send` over `Std.Http`, pure Lyric (#7462) | Same code |

`Mail`, the public package, compiles and its whole test suite passes on
*both* targets (`lyric test --manifest lyric-mail/lyric.toml` and `lyric
test --target jvm --manifest lyric-mail/lyric.toml`) — the JVM build used
to fail outright because the package imported `System.Net.Mail` externs
unconditionally; that kernel-boundary violation is fixed (#7254). SMTP is
bound per target (`System.Net.Mail` / Jakarta Mail); SES and SendGrid are plain
HTTPS APIs implemented once in Lyric, so they run on both targets with no
provider SDK.  SMTP delivery is exercised against a local capture server on
both targets by `scripts/ci/smtp-roundtrip-e2e.sh` (STARTTLS is not covered).  SES and SendGrid have not been driven against the live provider in CI; their request
bodies and the SigV4 signature are pinned by unit tests (the signature against
the published AWS test vector).

The `dotnet`/`jvm` platform features are resolved automatically from
`--target` (D-N-013 target normalization; see
`docs/24-build-features.md` §2.3) — you don't pass them yourself.

## Packages

| Package | Purpose |
|---|---|
| `Mail` | Core types, `MailSender` interface, and the public API — the only package application code imports |
| `Mail.Kernel.Net` | `--target dotnet` extern boundary (`System.Net.Mail`) |
| `Mail.Kernel.Jvm` | `--target jvm` extern boundary (Jakarta Mail) |

## Quick start

```lyric
import Mail

val sender = match Mail.connectSmtp() {
  case Ok(s) -> s
  case Err(e) -> panic("could not connect: " + e.message)
}

val result = Mail.sendSimple(sender, "recipient@example.com", "Hello", "This is a test")

sender.close()
```

`connectSmtp()`/`connectSes()`/`connectSendGrid()` take no arguments —
configuration is read from environment variables (see "Configuration"
below), not a config record passed at the call site.

## Enabling a provider

Feature-gate the provider(s) you need in your own `lyric.toml`:

```toml
[features]
default = ["dotnet", "smtp"]  # add "ses" and/or "sendgrid" as needed
```

- `smtp` — SMTP: `System.Net.Mail` on dotnet, Jakarta Mail on jvm (see "Platform parity")
- `ses` — Amazon SES v2 over `Std.Http` (both targets)
- `sendgrid` — SendGrid v3 over `Std.Http` (both targets)

## Core types and functions

### MailSender interface

```lyric
pub interface MailSender {
  func send(msg: in EmailMessage): Result[Unit, MailError]
  func close(): Unit
}
```

Every implementation (including a custom out-of-tree one) must call
`Mail.validateNoInjection(msg)` before dispatch — see its doc comment.

### EmailMessage / EmailAddress / Attachment

```lyric
pub record EmailMessage {
  from: EmailAddress
  to: slice[EmailAddress]
  cc: slice[EmailAddress]
  bcc: slice[EmailAddress]
  subject: String
  textBody: String
  htmlBody: String
  attachments: slice[Attachment]
  replyTo: Option[EmailAddress]
}

pub record EmailAddress {
  address: String
  displayName: String
}

pub record Attachment {
  filename: String
  contentType: String
  dataBase64: String   // base64-encoded binary content
}
```

### Factory and helper functions

```lyric
Mail.connectSmtp(): Result[MailSender, MailError]
Mail.connectSes(): Result[MailSender, MailError]           // requires the `ses` feature
Mail.connectSendGrid(): Result[MailSender, MailError]       // requires the `sendgrid` feature

Mail.send(sender: in MailSender, msg: in EmailMessage): Result[Unit, MailError]
Mail.sendSimple(sender: in MailSender, to: in String, subject: in String, body: in String): Result[Unit, MailError]
Mail.sendHtml(sender: in MailSender, to: in String, subject: in String, htmlBody: in String, textBody: in String): Result[Unit, MailError]

Mail.makeAddress(address: in String): EmailAddress
Mail.makeAddressWithName(address: in String, displayName: in String): EmailAddress
Mail.makeAttachment(filename: in String, contentType: in String, dataBase64: in String): Attachment
Mail.validateNoInjection(msg: in EmailMessage): Option[MailError]
Mail.validateSmtpConfig(port: in Int, timeoutMs: in Int): Option[MailError]

Mail.maxTotalAttachmentBytes: Int
```

## Validation and safety guarantees

`Mail.send` (and every in-tree `MailSender` implementation, as defense in
depth) rejects a message with any of the following, returning a
structured `Err` rather than a panic — every field of an `EmailMessage` is
client-controllable, so a precondition assert on it would crash the
process instead (D118):

| Check | `MailError.code` |
|---|---|
| No recipients (`to` is empty) | `NO_RECIPIENTS` |
| A CR/LF/NUL character anywhere that could inject MIME headers (CWE-93) | `HEADER_INJECTION` |
| A `to`/`cc`/`bcc`/`replyTo` address that is empty, has no `@` (or more than one), or has an empty local or domain part | `INVALID_ADDRESS` |
| Total decoded attachment size over `Mail.maxTotalAttachmentBytes` (25 MiB) | `ATTACHMENTS_TOO_LARGE` |

Before #7254, an implausible recipient address was silently dropped from
the outgoing message instead of rejected — a partial send with no
indication anything was wrong. It is now rejected outright.

`displayName` on `from`/`to`/`cc`/`bcc`/`replyTo` is carried through to the
underlying `MailAddress` on `--target dotnet` (previously dropped).

## Configuration

Configuration is read from environment variables at connection time —
there is no config record passed to `connectSmtp()`/`connectSes()`/
`connectSendGrid()`.

### SMTP (`LYRIC_CONFIG_SMTP_*`)

| Env var | Default | Meaning |
|---|---|---|
| `LYRIC_CONFIG_SMTP_HOST` | `localhost` | SMTP server hostname |
| `LYRIC_CONFIG_SMTP_PORT` | `587` | SMTP server port — must be an integer in `1..65535`, else `Err(code = "INVALID_CONFIG")` |
| `LYRIC_CONFIG_SMTP_USERNAME` | `""` | SMTP authentication user |
| `LYRIC_CONFIG_SMTP_PASSWORD` | `""` | SMTP authentication password |
| `LYRIC_CONFIG_SMTP_USETLS` | `true` | Enable TLS/STARTTLS |
| `LYRIC_CONFIG_SMTP_TIMEOUTMS` | `30000` | Connection timeout in ms — must be an integer `>= 1`, else `Err(code = "INVALID_CONFIG")` |

### Sender (`LYRIC_CONFIG_SENDER_*`)

Used as the envelope `from` address by `sendSimple`/`sendHtml`.

| Env var | Default | Meaning |
|---|---|---|
| `LYRIC_CONFIG_SENDER_FROMADDRESS` | `""` | Envelope From address |
| `LYRIC_CONFIG_SENDER_FROMDISPLAYNAME` | `""` | Envelope From display name |

### Amazon SES (`LYRIC_CONFIG_SES_*`)

`connectSes()` returns a sender that calls SES v2 `SendEmail` over HTTPS,
signed with AWS Signature Version 4. Messages without attachments use `Simple`
content; messages with attachments are rendered as `Raw` MIME.

| Env var | Meaning |
|---|---|
| `LYRIC_CONFIG_SES_REGION` | AWS region (lowercase letters, digits, `-`) — required, else `Err(code = "INVALID_CONFIG")` |
| `LYRIC_CONFIG_SES_ACCESSKEY` | AWS Access Key ID — required |
| `LYRIC_CONFIG_SES_SECRETKEY` | AWS Secret Access Key — required |
| `LYRIC_CONFIG_SES_SESSIONTOKEN` | Session token for temporary credentials (optional) |
| `LYRIC_CONFIG_SES_ENDPOINT` | Endpoint override (default `https://email.<region>.amazonaws.com`); must be `https://`, or `http://` for `localhost`/`127.0.0.1`/`[::1]` only |

### SendGrid (`LYRIC_CONFIG_SENDGRIDMAIL_*`)

`connectSendGrid()` returns a sender that calls `POST /v3/mail/send` with a
bearer API key.

| Env var | Meaning |
|---|---|
| `LYRIC_CONFIG_SENDGRIDMAIL_APIKEY` | API key — required, else `Err(code = "INVALID_CONFIG")` |
| `LYRIC_CONFIG_SENDGRIDMAIL_ENDPOINT` | Endpoint override (default `https://api.sendgrid.com`); `https://`, or `http://` for loopback only |

A provider rejection is returned as `Err` with the HTTP status and the start of
the response body in `message`, and `code` `AUTH_FAILED` (401/403),
`QUOTA_EXCEEDED` (429), `PROVIDER_ERROR` (5xx) or `SEND_ERROR`.

The region/apiKey preconditions above are enforced identically on every
target — previously they existed only as a dead-code precondition in
`Mail.Kernel.Net` that nothing ever called (#7254).

## Decision log

See `docs/03-decision-log.md` D062.
