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
import Mail.Kernel.Net
import Mail.Kernel.Jvm

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
  to:          [EmailAddress]
  cc:          [EmailAddress]
  bcc:         [EmailAddress]
  subject:     String
  textBody:    String
  htmlBody:    String
  attachments: [Attachment]
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
    val json = serialiseMessage(msg)
    match mailKernelSend(senderHandle, json) {
      case Ok(_)    -> Ok(())
      case Err(msg) -> Err(MailError(message = msg, code = "SEND_ERROR"))
    }
  }

  func close(): Unit {
    mailKernelClose(senderHandle)
  }
}

// ─── Config ───────────────────────────────────────────────────────────────────

/// SMTP connection settings.
config Smtp {
  host:      String
  port:      Int range 1 ..= 65535   = 587
  username:  String                  = ""
  @sensitive
  password:  String                  = ""
  useTls:    Bool                    = true
  timeoutMs: Int range 1000 ..= 60000 = 30000
}

/// Envelope-level sender settings shared by all providers.
config Sender {
  fromAddress:     String
  fromDisplayName: String = ""
  provider:        String = "smtp"   // smtp | ses | sendgrid
}

/// Amazon SES connection settings.
config Ses {
  region:    String = "us-east-1"
  @sensitive
  accessKey: String = ""
  @sensitive
  secretKey: String = ""
}

/// SendGrid connection settings.
config SendGridMail {
  @sensitive
  apiKey: String = ""
}

// ─── Factory functions ────────────────────────────────────────────────────────

/// Open an SMTP connection using the Smtp config block.
/// Requires the `smtp` feature to be active (`[features] smtp = []`).
@stable(since="0.1")
@cfg(feature = "smtp")
pub func connectSmtp(): Result[MailSender, MailError] {
  match mailKernelConnectSmtp(
    Smtp.host, Smtp.port, Smtp.username, Smtp.password, Smtp.useTls, Smtp.timeoutMs)
  {
    case Ok(handle) -> Ok(NativeSender(senderHandle = handle))
    case Err(msg)   -> Err(MailError(message = msg, code = "CONNECT_ERROR"))
  }
}

/// Open an Amazon SES client.
/// Requires the `ses` feature to be active (`[features] ses = []`).
/// Config is read from `LYRIC_CONFIG_SES_*` env vars (region, accessKey, secretKey).
@stable(since="0.1")
@cfg(feature = "ses")
pub func connectSes(): Result[MailSender, MailError] {
  match mailKernelConnectSes(Ses.region, Ses.accessKey, Ses.secretKey) {
    case Ok(handle) -> Ok(NativeSender(senderHandle = handle))
    case Err(msg)   -> Err(MailError(message = msg, code = "CONNECT_ERROR"))
  }
}

/// Open a SendGrid client.
/// Requires the `sendgrid` feature to be active (`[features] sendgrid = []`).
/// Config is read from `LYRIC_CONFIG_SENDGRID_*` env vars (apiKey).
@stable(since="0.1")
@cfg(feature = "sendgrid")
pub func connectSendGrid(): Result[MailSender, MailError] {
  match mailKernelConnectSendGrid(SendGridMail.apiKey) {
    case Ok(handle) -> Ok(NativeSender(senderHandle = handle))
    case Err(msg)   -> Err(MailError(message = msg, code = "CONNECT_ERROR"))
  }
}

// ─── Convenience functions ────────────────────────────────────────────────────

/// Top-level wrapper for `sender.send(msg)`.
@stable(since="0.1")
pub func send(sender: in MailSender, msg: in EmailMessage): Result[Unit, MailError]
  requires: msg.subject.length > 0
  requires: msg.to.length > 0
{
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

// Build an EmailMessage using the Sender config for the From address.
func buildMessage(
  to:       in [EmailAddress],
  subject:  in String,
  textBody: in String,
  htmlBody: in String
): EmailMessage {
  val fromAddr = EmailAddress(
    address     = Sender.fromAddress,
    displayName = Sender.fromDisplayName)
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

// Produce a JSON string representation of an EmailMessage for the kernel.
// Uses manual string building to avoid a hard dependency on Std.Json at the
// message-construction level.
func serialiseMessage(msg: in EmailMessage): String {
  val fromJson   = serialiseAddress(msg.from)
  val toJson     = serialiseAddressList(msg.to)
  val ccJson     = serialiseAddressList(msg.cc)
  val bccJson    = serialiseAddressList(msg.bcc)
  val attJson    = serialiseAttachmentList(msg.attachments)
  val replyJson  = match msg.replyTo {
    case Some(addr) -> serialiseAddress(addr)
    case None       -> "null"
  }
  return "{" +
    "\"from\":"        + fromJson  + "," +
    "\"to\":"          + toJson    + "," +
    "\"cc\":"          + ccJson    + "," +
    "\"bcc\":"         + bccJson   + "," +
    "\"subject\":"     + jsonString(msg.subject)  + "," +
    "\"textBody\":"    + jsonString(msg.textBody) + "," +
    "\"htmlBody\":"    + jsonString(msg.htmlBody) + "," +
    "\"attachments\":" + attJson   + "," +
    "\"replyTo\":"     + replyJson +
    "}"
}

// Serialise a single EmailAddress to JSON.
func serialiseAddress(addr: in EmailAddress): String {
  return "{\"address\":" + jsonString(addr.address) +
         ",\"displayName\":" + jsonString(addr.displayName) + "}"
}

// Serialise a list of EmailAddress values to a JSON array.
func serialiseAddressList(addrs: in [EmailAddress]): String {
  var result = "["
  var first  = true
  for addr in addrs {
    if not first { result = result + "," }
    result = result + serialiseAddress(addr)
    first  = false
  }
  return result + "]"
}

// Serialise a list of Attachment values to a JSON array.
func serialiseAttachmentList(attachments: in [Attachment]): String {
  var result = "["
  var first  = true
  for att in attachments {
    if not first { result = result + "," }
    result = result +
      "{\"filename\":"    + jsonString(att.filename)    + "," +
       "\"contentType\":" + jsonString(att.contentType) + "," +
       "\"dataBase64\":"  + jsonString(att.dataBase64)  + "}"
    first = false
  }
  return result + "]"
}

// Return true if `s` contains characters that could inject MIME headers.
// Rejects carriage return, line feed, and NUL.
func containsHeaderInjection(s: in String): Bool {
  var i = 0
  while i < s.length {
    val ch = s.charAt(i).toString()
    if ch == "\r" or ch == "\n" or ch == "\u{0}" { return true }
    i = i + 1
  }
  return false
}

// Wrap a string value in JSON double quotes, escaping backslash, double-quote,
// and the common control characters.
func jsonString(s: in String): String {
  var buf = "\""
  var i   = 0
  while i < s.length {
    val ch = s.charAt(i).toString()
    if ch == "\"" {
      buf = buf + "\\\""
    } else if ch == "\\" {
      buf = buf + "\\\\"
    } else if ch == "\n" {
      buf = buf + "\\n"
    } else if ch == "\r" {
      buf = buf + "\\r"
    } else if ch == "\t" {
      buf = buf + "\\t"
    } else {
      buf = buf + ch
    }
    i = i + 1
  }
  return buf + "\""
}

// ─── Kernel dispatchers (target-gated) ────────────────────────────────────────
// Each helper has two @cfg-gated implementations.  The compiler keeps exactly
// one per active target; the public package code calls these wrappers so the
// same source compiles under --target dotnet and --target jvm.

@cfg(feature = "dotnet")
@cfg(feature = "smtp")
func mailKernelConnectSmtp(
  host:      in String,
  port:      in Int,
  username:  in String,
  password:  in String,
  useTls:    in Bool,
  timeoutMs: in Int
): Result[Int, String] {
  return Mail.Kernel.Net.connectSmtp(host, port, username, password, useTls, timeoutMs)
}
@cfg(feature = "jvm")
@cfg(feature = "smtp")
func mailKernelConnectSmtp(
  host:      in String,
  port:      in Int,
  username:  in String,
  password:  in String,
  useTls:    in Bool,
  timeoutMs: in Int
): Result[Int, String] {
  return Mail.Kernel.Jvm.connectSmtp(host, port, username, password, useTls, timeoutMs)
}

@cfg(feature = "dotnet")
@cfg(feature = "ses")
func mailKernelConnectSes(
  region:    in String,
  accessKey: in String,
  secretKey: in String
): Result[Int, String] {
  return Mail.Kernel.Net.connectSes(region, accessKey, secretKey)
}
@cfg(feature = "jvm")
@cfg(feature = "ses")
func mailKernelConnectSes(
  region:    in String,
  accessKey: in String,
  secretKey: in String
): Result[Int, String] {
  return Mail.Kernel.Jvm.connectSes(region, accessKey, secretKey)
}

@cfg(feature = "dotnet")
@cfg(feature = "sendgrid")
func mailKernelConnectSendGrid(apiKey: in String): Result[Int, String] {
  return Mail.Kernel.Net.connectSendGrid(apiKey)
}
@cfg(feature = "jvm")
@cfg(feature = "sendgrid")
func mailKernelConnectSendGrid(apiKey: in String): Result[Int, String] {
  return Mail.Kernel.Jvm.connectSendGrid(apiKey)
}

@cfg(feature = "dotnet")
func mailKernelSend(senderHandle: in Int, messageJson: in String): Result[Unit, String] {
  return Mail.Kernel.Net.send(senderHandle, messageJson)
}
@cfg(feature = "jvm")
func mailKernelSend(senderHandle: in Int, messageJson: in String): Result[Unit, String] {
  return Mail.Kernel.Jvm.send(senderHandle, messageJson)
}

@cfg(feature = "dotnet")
func mailKernelClose(senderHandle: in Int): Unit {
  Mail.Kernel.Net.close(senderHandle)
}
@cfg(feature = "jvm")
func mailKernelClose(senderHandle: in Int): Unit {
  Mail.Kernel.Jvm.close(senderHandle)
}
