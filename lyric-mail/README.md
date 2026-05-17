# lyric-mail

Email sending with pluggable provider backends.

## Packages

| Package | Purpose |
|---|---|
| `Mail` | Core types, `MailSender` interface, and public API |
| `Mail.Smtp` | SMTP/MailKit provider |
| `Mail.Ses` | Amazon SES provider |
| `Mail.SendGrid` | SendGrid provider |

## Quick start

```lyric
import Mail
import Mail.Smtp

val sender = Mail.Smtp.connectSmtp({
  host: "smtp.example.com",
  port: 587,
  username: "user@example.com",
  password: "secret"
})

val result = Mail.sendSimple(sender,
  from: "noreply@example.com",
  to: "recipient@example.com",
  subject: "Hello",
  body: "This is a test"
)

sender.close()
```

## Supported providers

Feature-gate the provider you need in `lyric.toml`:

```toml
[features]
mail = ["smtp"]  # or "ses", "sendgrid"
```

- `smtp` — SMTP via MailKit
- `ses` — Amazon Simple Email Service
- `sendgrid` — SendGrid API

## Core types and functions

### MailSender interface

```lyric
pub interface MailSender {
  func send(message: in EmailMessage): Result[String, MailError]
  func close(): Unit
}
```

### EmailMessage type

```lyric
pub record EmailMessage {
  from: EmailAddress
  to: slice[EmailAddress]
  cc: slice[EmailAddress]
  bcc: slice[EmailAddress]
  subject: String
  bodyPlain: String
  bodyHtml: Option[String]
  attachments: slice[Attachment]
  headers: slice[Tuple[String, String]]
}
```

### EmailAddress type

```lyric
pub record EmailAddress {
  email: String
  name: Option[String]
}
```

### Attachment type

```lyric
pub record Attachment {
  filename: String
  contentType: String
  data: slice[Byte]
}
```

### Factory and helper functions

```lyric
Mail.Smtp.connectSmtp(config: in SmtpConfig)
  -> Result[MailSender, MailError]

Mail.Ses.connectSes(region: in String, accessKey: in String, secretKey: in String)
  -> Result[MailSender, MailError]

Mail.SendGrid.connectSendGrid(apiKey: in String)
  -> Result[MailSender, MailError]

Mail.send(sender: in MailSender, message: in EmailMessage)
  -> Result[String, MailError]  // Returns message ID

Mail.sendSimple(sender: in MailSender, from: in String, to: in String,
                subject: in String, body: in String)
  -> Result[String, MailError]

Mail.sendHtml(sender: in MailSender, from: in String, to: in String,
              subject: in String, bodyText: in String, bodyHtml: in String)
  -> Result[String, MailError]
```

## Configuration

### SMTP

Config block for `Mail.Smtp.connectSmtp()`:

```lyric
pub record SmtpConfig {
  host: String
  port: Int
  username: String
  password: String
  useTls: Bool
  timeoutMs: Int
}
```

Environment variable defaults (env prefix `LYRIC_CONFIG_MAIL_SMTP_`):

| Env var | Default | Meaning |
|---|---|---|
| `HOST` | `localhost` | SMTP server hostname |
| `PORT` | `587` | SMTP server port |
| `USERNAME` | `""` | SMTP authentication user |
| `PASSWORD` | `""` | SMTP authentication password |
| `USETLS` | `true` | Enable TLS/STARTTLS |
| `TIMEOUTMS` | `30000` | Connection timeout in ms |

### Amazon SES

Environment variable defaults (env prefix `LYRIC_CONFIG_MAIL_SES_`):

| Env var | Default | Meaning |
|---|---|---|
| `REGION` | `us-east-1` | AWS region |
| `ACCESSKEY` | `""` | AWS Access Key ID |
| `SECRETKEY` | `""` | AWS Secret Access Key |

### SendGrid

Environment variable defaults (env prefix `LYRIC_CONFIG_MAIL_SENDGRID_`):

| Env var | Default | Meaning |
|---|---|---|
| `APIKEY` | `""` | SendGrid API key |

## Decision log

See `docs/03-decision-log.md` D057.
