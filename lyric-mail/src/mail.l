// Mail — email sending library for Lyric.
//
// Provides a uniform `MailSender` interface over SMTP (MailKit), Amazon SES,
// and SendGrid.  Obtain a sender with one of the feature-gated `connect*`
// factory functions, then call `Mail.send` or the convenience helpers.
//
// Usage:
//
//   import Mail
//
//   val sender = Mail.connectSmtp()?
//   Mail.sendSimple(sender, "alice@example.com", "Hello", "World")?
//   Mail.send(sender, EmailMessage(
//     from        = Mail.makeAddress("bot@example.com"),
//     to          = [Mail.makeAddressWithName("alice@example.com", "Alice")],
//     cc          = [],
//     bcc         = [],
//     subject     = "Report",
//     textBody    = "See attached.",
//     htmlBody    = "<p>See attached.</p>",
//     attachments = [Mail.makeAttachment("report.pdf", "application/pdf", base64Data)],
//     replyTo     = None
//   ))?
//
// Runtime config env vars (LYRIC_CONFIG_SMTP_*, LYRIC_CONFIG_SENDER_*):
//   LYRIC_CONFIG_SMTP_HOST          — SMTP server hostname (required for SMTP)
//   LYRIC_CONFIG_SMTP_PORT          — SMTP port (default: 587)
//   LYRIC_CONFIG_SMTP_USERNAME      — SMTP username (default: "")
//   LYRIC_CONFIG_SMTP_PASSWORD      — SMTP password (default: "", @sensitive)
//   LYRIC_CONFIG_SMTP_USETLS        — use TLS (default: true)
//   LYRIC_CONFIG_SMTP_TIMEOUTMS     — send timeout ms (default: 30000)
//   LYRIC_CONFIG_SENDER_FROMADDRESS     — envelope From address (required)
//   LYRIC_CONFIG_SENDER_FROMDISPLAYNAME — envelope From display name (default: "")
//   LYRIC_CONFIG_SENDER_PROVIDER        — provider name: smtp/ses/sendgrid (default: "smtp")
//
// See docs/03-decision-log.md D062 and lyric-mail/README.md.

@runtime_checked
package Mail

import Std.Core
import Std.Collections
import Std.String
import Std.Environment as Env
import Mail.Kernel.Net as MailKernel

// ─── Address and attachment types ────────────────────────────────────────────

/// An email address with an optional display name.
@stable(since="0.1")
pub record EmailAddress {
  address:     String
  displayName: String
}

/// A file attachment: filename, MIME content-type, and base64-encoded content.
@stable(since="0.1")
pub record Attachment {
  filename:    String
  contentType: String
  dataBase64:  String   // base64-encoded binary content
}

// ─── Message type ─────────────────────────────────────────────────────────────

/// A complete email message ready for sending.
@stable(since="0.1")
pub record EmailMessage {
  from:        EmailAddress
  to:          slice[EmailAddress]
  cc:          slice[EmailAddress]
  bcc:         slice[EmailAddress]
  subject:     String
  textBody:    String
  htmlBody:    String
  attachments: slice[Attachment]
  replyTo:     Option[EmailAddress]
}

// ─── Error type ───────────────────────────────────────────────────────────────

/// An error returned by a mail provider.
@stable(since="0.1")
pub record MailError {
  message: String
  code:    String    // provider-specific error code, e.g. "AUTH_FAILED", "QUOTA_EXCEEDED"
}

// ─── Sender interface ─────────────────────────────────────────────────────────

/// An email sender.  Obtain one with `connectSmtp()`, `connectSes()`, or
/// `connectSendGrid()`.  Close it with `sender.close()` when done.
@stable(since="0.1")
pub interface MailSender {
  /// Send a single email message.
  func send(msg: in EmailMessage): Result[Unit, MailError]
    requires: msg.subject.length > 0
    requires: msg.to.length > 0

  /// Release the underlying provider connection.
  func close(): Unit
}

// ─── Native sender wrapper (internal) ────────────────────────────────────────

// Integer handle issued by the kernel; opaque to consumers.
record NativeSender { senderHandle: Int }

impl MailSender for NativeSender {
  func send(msg: in EmailMessage): Result[Unit, MailError] {
    val toAddrs = addressesToSlice(msg.to)
    match MailKernel.smtpSend(
      self.senderHandle,
      msg.from.address,
      toAddrs,
      msg.subject,
      msg.textBody,
      msg.htmlBody
    ) {
      case Ok(_)    -> Ok(())
      case Err(err) -> Err(MailError(message = err, code = "SEND_ERROR"))
    }
  }

  func close(): Unit {
    MailKernel.close(self.senderHandle)
  }
}

// ─── Config (env-var backed) ──────────────────────────────────────────────────
//
// Config blocks are declared here for documentation purposes.
// Field values are read from environment variables at connection time.
// SMTP: LYRIC_CONFIG_SMTP_HOST, LYRIC_CONFIG_SMTP_PORT, LYRIC_CONFIG_SMTP_USERNAME,
//       LYRIC_CONFIG_SMTP_PASSWORD, LYRIC_CONFIG_SMTP_USETLS, LYRIC_CONFIG_SMTP_TIMEOUTMS
// Sender: LYRIC_CONFIG_SENDER_FROMADDRESS, LYRIC_CONFIG_SENDER_FROMDISPLAYNAME
// SES: LYRIC_CONFIG_SES_REGION, LYRIC_CONFIG_SES_ACCESSKEY, LYRIC_CONFIG_SES_SECRETKEY
// SendGrid: LYRIC_CONFIG_SENDGRIDMAIL_APIKEY

// ─── Factory functions ────────────────────────────────────────────────────────

/// Open an SMTP connection using environment variable config.
/// Requires the `smtp` feature to be active (`[features] smtp = []`).
/// Config is read from LYRIC_CONFIG_SMTP_* env vars.
@stable(since="0.1")
@cfg(feature = "smtp")
pub func connectSmtp(): Result[MailSender, MailError] {
  val host      = Env.getVarOrDefault("LYRIC_CONFIG_SMTP_HOST", "localhost")
  val portStr   = Env.getVarOrDefault("LYRIC_CONFIG_SMTP_PORT", "587")
  val username  = Env.getVarOrDefault("LYRIC_CONFIG_SMTP_USERNAME", "")
  val password  = Env.getVarOrDefault("LYRIC_CONFIG_SMTP_PASSWORD", "")
  val useTlsStr = Env.getVarOrDefault("LYRIC_CONFIG_SMTP_USETLS", "true")
  val toMs      = Env.getVarOrDefault("LYRIC_CONFIG_SMTP_TIMEOUTMS", "30000")
  val port      = match parseInt(portStr) { case Some(n) -> n  case None -> 587 }
  val useTls    = useTlsStr != "false"
  val timeoutMs = match parseInt(toMs) { case Some(n) -> n  case None -> 30000 }
  match MailKernel.connectSmtp(host, port, username, password, useTls, timeoutMs) {
    case Ok(handle) -> Ok(NativeSender(senderHandle = handle))
    case Err(msg)   -> Err(MailError(message = msg, code = "CONNECT_ERROR"))
  }
}

/// Open an Amazon SES client.
/// Requires the `ses` feature to be active (`[features] ses = []`).
/// Config is read from LYRIC_CONFIG_SES_* env vars (region, accessKey, secretKey).
@stable(since="0.1")
@cfg(feature = "ses")
pub func connectSes(): Result[MailSender, MailError] {
  val region    = Env.getVarOrDefault("LYRIC_CONFIG_SES_REGION", "us-east-1")
  val accessKey = Env.getVarOrDefault("LYRIC_CONFIG_SES_ACCESSKEY", "")
  val secretKey = Env.getVarOrDefault("LYRIC_CONFIG_SES_SECRETKEY", "")
  match MailKernel.connectSes(region, accessKey, secretKey) {
    case Ok(handle) -> Ok(NativeSender(senderHandle = handle))
    case Err(msg)   -> Err(MailError(message = msg, code = "CONNECT_ERROR"))
  }
}

/// Open a SendGrid client.
/// Requires the `sendgrid` feature to be active (`[features] sendgrid = []`).
/// Config is read from LYRIC_CONFIG_SENDGRIDMAIL_APIKEY env var.
@stable(since="0.1")
@cfg(feature = "sendgrid")
pub func connectSendGrid(): Result[MailSender, MailError] {
  val apiKey = Env.getVarOrDefault("LYRIC_CONFIG_SENDGRIDMAIL_APIKEY", "")
  match MailKernel.connectSendGrid(apiKey) {
    case Ok(handle) -> Ok(NativeSender(senderHandle = handle))
    case Err(msg)   -> Err(MailError(message = msg, code = "CONNECT_ERROR"))
  }
}

// ─── Convenience functions ────────────────────────────────────────────────────

/// Top-level wrapper for `sender.send(msg)`.
///
/// Guards every CRLF / NUL-bearing field on `msg` before the kernel
/// path can compose it into MIME headers (CWE-93).  The convenience
/// wrappers (`sendSimple`, `sendHtml`) carry the same `requires:`
/// clauses; this guard catches the direct-`send` path that constructed
/// the `EmailMessage` record by hand.  See lyric-lang #396 / #740.
@stable(since="0.1")
pub func send(sender: in MailSender, msg: in EmailMessage): Result[Unit, MailError]
  requires: msg.subject.length > 0
  requires: msg.to.length > 0
  requires: not containsHeaderInjection(msg.subject)
  requires: not containsHeaderInjection(msg.from.address)
  requires: not containsHeaderInjection(msg.from.displayName)
{
  // Recipient addresses and attachment metadata can also carry CRLF;
  // since they're collections the contract clauses above can't pin
  // them, so check at the call boundary and produce a structured Err
  // for the caller.
  var i = 0
  while i < msg.to.length {
    if containsHeaderInjection(msg.to[i].address) or
       containsHeaderInjection(msg.to[i].displayName) {
      return Err(MailError(
        message = "to[" + ("" + i) + "] contains CR/LF/NUL — header injection rejected",
        code    = "HEADER_INJECTION"))
    }
    i = i + 1
  }
  var ci = 0
  while ci < msg.cc.length {
    if containsHeaderInjection(msg.cc[ci].address) or
       containsHeaderInjection(msg.cc[ci].displayName) {
      return Err(MailError(
        message = "cc[" + ("" + ci) + "] contains CR/LF/NUL — header injection rejected",
        code    = "HEADER_INJECTION"))
    }
    ci = ci + 1
  }
  var bi = 0
  while bi < msg.bcc.length {
    if containsHeaderInjection(msg.bcc[bi].address) or
       containsHeaderInjection(msg.bcc[bi].displayName) {
      return Err(MailError(
        message = "bcc[" + ("" + bi) + "] contains CR/LF/NUL — header injection rejected",
        code    = "HEADER_INJECTION"))
    }
    bi = bi + 1
  }
  // replyTo is optional — guard it when present.  Without this the
  // MailKit / SendGrid kernels can still smuggle a Reply-To header.
  match msg.replyTo {
    case None -> ()
    case Some(addr) ->
      if containsHeaderInjection(addr.address) or
         containsHeaderInjection(addr.displayName) {
        return Err(MailError(
          message = "replyTo contains CR/LF/NUL — header injection rejected",
          code    = "HEADER_INJECTION"))
      }
  }
  var ai = 0
  while ai < msg.attachments.length {
    if containsHeaderInjection(msg.attachments[ai].filename) or
       containsHeaderInjection(msg.attachments[ai].contentType) {
      return Err(MailError(
        message = "attachments[" + ("" + ai) +
                  "] filename/contentType contains CR/LF/NUL — header injection rejected",
        code    = "HEADER_INJECTION"))
    }
    ai = ai + 1
  }
  return sender.send(msg)
}

/// Send a plain-text email to a single recipient using Sender config for the
/// From address.
///
/// `to`, `subject`, and `body` must all be non-empty.
@stable(since="0.1")
pub func sendSimple(
  sender:  in MailSender,
  to:      in String,
  subject: in String,
  body:    in String
): Result[Unit, MailError]
  requires: to.length > 0
  requires: subject.length > 0
  requires: body.length > 0
  requires: not containsHeaderInjection(subject)
  requires: not containsHeaderInjection(to)
{
  val toAddr = makeAddress(to)
  val msg    = buildMessage([toAddr], subject, body, "")
  return sender.send(msg)
}

/// Send an HTML email (with a plain-text fallback) to a single recipient.
@stable(since="0.1")
pub func sendHtml(
  sender:   in MailSender,
  to:       in String,
  subject:  in String,
  htmlBody: in String,
  textBody: in String
): Result[Unit, MailError]
  requires: to.length > 0
  requires: subject.length > 0
  requires: htmlBody.length > 0
  requires: not containsHeaderInjection(subject)
  requires: not containsHeaderInjection(to)
{
  val toAddr = makeAddress(to)
  val msg    = buildMessage([toAddr], subject, textBody, htmlBody)
  return sender.send(msg)
}

/// Construct an `EmailAddress` from a bare address string (no display name).
@stable(since="0.1")
pub func makeAddress(address: in String): EmailAddress
  requires: not containsHeaderInjection(address)
{
  return EmailAddress(address = address, displayName = "")
}

/// Construct an `EmailAddress` with both an address and a display name.
@stable(since="0.1")
pub func makeAddressWithName(address: in String, displayName: in String): EmailAddress
  requires: not containsHeaderInjection(address)
  requires: not containsHeaderInjection(displayName)
{
  return EmailAddress(address = address, displayName = displayName)
}

/// Construct an `Attachment` from a filename, MIME content-type, and base64-
/// encoded data.
@stable(since="0.1")
pub func makeAttachment(
  filename:    in String,
  contentType: in String,
  dataBase64:  in String
): Attachment
  requires: filename.length > 0
  requires: contentType.length > 0
  requires: not containsHeaderInjection(filename)
  requires: not containsHeaderInjection(contentType)
{
  return Attachment(
    filename    = filename,
    contentType = contentType,
    dataBase64  = dataBase64)
}

// ─── Private helpers ──────────────────────────────────────────────────────────

// Build an EmailMessage using env-var Sender config for the From address.
func buildMessage(
  to:       in slice[EmailAddress],
  subject:  in String,
  textBody: in String,
  htmlBody: in String
): EmailMessage {
  val fromAddress     = Env.getVarOrDefault("LYRIC_CONFIG_SENDER_FROMADDRESS", "")
  val fromDisplayName = Env.getVarOrDefault("LYRIC_CONFIG_SENDER_FROMDISPLAYNAME", "")
  val fromAddr = EmailAddress(
    address     = fromAddress,
    displayName = fromDisplayName)
  return EmailMessage(
    from        = fromAddr,
    to          = to,
    cc          = [],
    bcc         = [],
    subject     = subject,
    textBody    = textBody,
    htmlBody    = htmlBody,
    attachments = [],
    replyTo     = None)
}

// Extract the address strings from a slice of EmailAddress values.
func addressesToSlice(addrs: in slice[EmailAddress]): slice[String] {
  var result: slice[String] = []
  for addr in addrs {
    result = result + [addr.address]
  }
  return result
}

// Return true if `s` contains characters that could inject MIME headers.
// Rejects carriage return, line feed, and NUL.
func containsHeaderInjection(s: in String): Bool {
  var i = 0
  while i < s.length {
    val ch = s[i]
    if ch == '\r' or ch == '\n' or ch == '\u{0}' { return true }
    i = i + 1
  }
  return false
}
