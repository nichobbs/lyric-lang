/// Mail.Kernel.Net — extern boundary for email-sending providers.
///
/// Phase 4 of #733: BCL System.Net.Mail SMTP backend functional via
/// `Lyric.Mail.SmtpHost`.  Amazon SES and SendGrid backends remain
/// declarative-only — their bindings are routed to placeholder
/// `*NotYet` targets that return a clear "not yet implemented" error
/// until provider-specific Testcontainers infrastructure lands
/// (#780 follow-up).
///
/// Each provider exposes three functions: `connectXxx` (returns an
/// opaque Int handle), `send` (accepts a JSON-serialised
/// EmailMessage), and `close`.
///
/// Message JSON format (produced by Mail.serialiseMessage):
///   {
///     "from":        {"address": "...", "displayName": "..."},
///     "to":          [{"address": "...", "displayName": "..."}, ...],
///     "cc":          [...],
///     "bcc":         [...],
///     "subject":     "...",
///     "textBody":    "...",
///     "htmlBody":    "...",
///     "attachments": [{"filename": "...", "contentType": "...", "dataBase64": "..."}, ...],
///     "replyTo":     {"address": "...", "displayName": "..."} | null
///   }
///
/// See docs/14-native-stdlib-plan.md for the kernel boundary contract.

package Mail.Kernel.Net

import Std.Core

// ─── SMTP provider (BCL System.Net.Mail.SmtpClient) ──────────────────────────

@axiom("Lyric.Mail.SmtpHost.connect — System.Net.Mail.SmtpClient over the supplied host/port; useTls maps to EnableSsl")
@externTarget("Lyric.Mail.SmtpHost.connect")
@cfg(feature = "smtp")
pub func connectSmtp(
  host:      in String,
  port:      in Int,
  username:  in String,
  password:  in String,
  useTls:    in Bool,
  timeoutMs: in Int
): Result[Int, String]
  requires: host.length > 0
  requires: port >= 1
  requires: port <= 65535
  requires: timeoutMs >= 1
  = ()

// ─── Amazon SES (Phase 4 follow-up of #733) ──────────────────────────────────

@axiom("Amazon SES backend not yet implemented (#733 follow-up)")
@externTarget("Lyric.Mail.SmtpHost.sesConnectNotYet")
@cfg(feature = "ses")
pub func connectSes(
  region:    in String,
  accessKey: in String,
  secretKey: in String
): Result[Int, String]
  requires: region.length > 0
  = ()

// ─── SendGrid (Phase 4 follow-up of #733) ────────────────────────────────────

@axiom("SendGrid backend not yet implemented (#733 follow-up)")
@externTarget("Lyric.Mail.SmtpHost.sendGridConnectNotYet")
@cfg(feature = "sendgrid")
pub func connectSendGrid(apiKey: in String): Result[Int, String]
  requires: apiKey.length > 0
  = ()

// ─── Shared send / close (dispatched by handle's backend tag) ────────────────

@axiom("Lyric.Mail.SmtpHost.send — parses the messageJson shape produced by Mail.serialiseMessage and dispatches via System.Net.Mail.SmtpClient.Send")
@externTarget("Lyric.Mail.SmtpHost.send")
pub func send(senderHandle: in Int, messageJson: in String): Result[Unit, String]
  requires: messageJson.length > 0
  = ()

@axiom("Lyric.Mail.SmtpHost.close — disposes the underlying SmtpClient and removes the handle from the registry")
@externTarget("Lyric.Mail.SmtpHost.close")
pub func close(senderHandle: in Int): Unit = ()
