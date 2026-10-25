//! Mail — email sending library for Lyric.
//! Stability: @experimental — the API compiles and unit tests cover the typed
//! envelope and the SES/SendGrid wire formats, but the SMTP, Amazon SES, and
//! SendGrid backends have not been driven against a live provider in CI.
//!
//! Provides a uniform `MailSender` interface over SMTP, Amazon SES,
//! and SendGrid.  Obtain a sender with one of the feature-gated `connect*`
//! factory functions, then call `Mail.send` or the convenience helpers.
//!
//! Usage:
//!
//!   import Mail
//!
//!   val sender = Mail.connectSmtp()?
//!   Mail.sendSimple(sender, "alice@example.com", "Hello", "World")?
//!   Mail.send(sender, EmailMessage(
//!     from        = Mail.makeAddress("bot@example.com"),
//!     to          = [Mail.makeAddressWithName("alice@example.com", "Alice")],
//!     cc          = [],
//!     bcc         = [],
//!     subject     = "Report",
//!     textBody    = "See attached.",
//!     htmlBody    = "<p>See attached.</p>",
//!     attachments = [Mail.makeAttachment("report.pdf", "application/pdf", base64Data)],
//!     replyTo     = None
//!   ))?
//!
//! Runtime config env vars (LYRIC_CONFIG_SMTP_*, LYRIC_CONFIG_SENDER_*):
//!   LYRIC_CONFIG_SMTP_HOST          — SMTP server hostname (required for SMTP)
//!   LYRIC_CONFIG_SMTP_PORT          — SMTP port (default: 587)
//!   LYRIC_CONFIG_SMTP_USERNAME      — SMTP username (default: "")
//!   LYRIC_CONFIG_SMTP_PASSWORD      — SMTP password (default: "", @sensitive)
//!   LYRIC_CONFIG_SMTP_USETLS        — use TLS (default: true)
//!   LYRIC_CONFIG_SMTP_TIMEOUTMS     — send timeout ms (default: 30000)
//!   LYRIC_CONFIG_SENDER_FROMADDRESS     — envelope From address (required)
//!   LYRIC_CONFIG_SENDER_FROMDISPLAYNAME — envelope From display name (default: "")
//!   LYRIC_CONFIG_SENDER_PROVIDER        — provider name: smtp/ses/sendgrid (default: "smtp")
//!
//! See docs/03-decision-log.md D062 and lyric-mail/README.md.
@runtime_checked
@io
package Mail

import Std.Core
import Std.Char
import Std.Collections
import Std.Format
import Std.String
import Std.Parse
import Std.Environment as Env
import Std.Http
import Std.Errors
import Std.Json as Json
import Std.Hash as Hash
import Std.Encoding as Enc
import Std.Time as Time
import Std.Uuid as Uuid
import Mail.Kernel.Net as MailKernel
import Mail.Kernel.Jvm as MailKernelJvm

// ─── Address and attachment types ────────────────────────────────────────────
/// An email address with an optional display name.
@stable(since = "0.1")
pub record EmailAddress {
  address: String
  displayName: String
}

/// A file attachment: filename, MIME content-type, and base64-encoded content.
@stable(since = "0.1")
pub record Attachment {
  filename: String
  contentType: String
  dataBase64: String   // base64-encoded binary content
}

// ─── Message type ─────────────────────────────────────────────────────────────
/// A complete email message ready for sending.
@stable(since = "0.1")
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

// ─── Error type ───────────────────────────────────────────────────────────────
/// An error returned by a mail provider.
@stable(since = "0.1")
pub record MailError {
  message: String
  code: String    // provider-specific error code, e.g. "AUTH_FAILED", "QUOTA_EXCEEDED"
}

// ─── Sender interface ─────────────────────────────────────────────────────────
/// An email sender.  Obtain one with `connectSmtp()`, `connectSes()`, or
/// `connectSendGrid()`.  Close it with `sender.close()` when done.
@stable(since = "0.1")
pub interface MailSender {
  /// Send a single email message.
  ///
  /// No `requires:` clauses: every field of `msg` is client-controllable, and
  /// a precondition assert on client data crashes the process instead of
  /// returning `Err` (D118).  Invalid messages (no recipients, injected
  /// headers) are rejected with a structured `Err` at `Mail.send` /
  /// `validateNoInjection`.
  ///
  /// **Implementation contract (#5499):** every `MailSender.send` implementation
  /// MUST call `Mail.validateNoInjection(msg)` (now `pub`) and return its
  /// `MailError` before any transport dispatch — the header-injection guard is
  /// part of this interface's safety contract, not merely a convenience in
  /// `Mail.send`. The in-tree `NativeSender` does this; out-of-tree senders are
  /// responsible for the same, since Lyric interfaces cannot enforce a shared
  /// body without a client-crashing `requires:`.
  func send(msg: in EmailMessage): Result[Unit, MailError]

  /// Release the underlying provider connection.
  func close(): Unit
}

// ─── No-op sender for testing guard-only call paths ──────────────────────────
// Records the number of delegate calls without touching any transport.  The
// `Mail.send` header-injection guard fires before `send` is ever reached, so
// injection tests can use this without a live SMTP server.
/// A no-op `MailSender` that records call counts and always returns `Ok`.
/// Intended for unit tests that exercise the `Mail.send` guard path without an
/// SMTP/SES/SendGrid connection.
///
/// Why it lives in the `Mail` package rather than the `Mail.MailTests` test
/// module (#3183): the in-bundle test/manifest build lowers the test module
/// and `Mail` into one compilation, and `impl Mail.MailSender for …` declared
/// in the test module fails MSIL lowering with `MPImpl interface type
/// 'Mail.MailSender' has no TypeDef or TypeRef row` — the interface's metadata
/// row is not visible to an implementor in a *different* in-bundle package.
/// (`MockMailSender` in lyric-testing implements the same interface only
/// because lyric-testing is built as a separate library against restored
/// `Mail` metadata, which does emit the TypeRef.)  Keeping the stub in the
/// interface's own package puts the TypeDef in the same assembly.  It is
/// `pub` so the test module can construct it, but carries no `@stable`
/// annotation, so it is excluded from the stable public-API surface that
/// `lyric public-api-diff` tracks.
pub ref record MailSenderStub {
  var callCount: Int
}

impl MailSender for MailSenderStub {
  func send(msg: in EmailMessage): Result[Unit, MailError] {
    self.callCount = self.callCount + 1
    return Ok(())
  }
  func close(): Unit {
  }
}

// The total decoded size of every attachment on one message, in bytes, above
// which `Mail.send` rejects the message with `Err` rather than dispatching a
// partially-oversized payload to the provider. 25 MiB matches common SMTP
// relay / provider caps (e.g. Amazon SES's default 40 MB *encoded* limit, of
// which base64 overhead accounts for roughly a third).
@stable(since = "0.1")
pub val maxTotalAttachmentBytes: Int = 26214400

// 25 * 1024 * 1024
// Approximate the decoded byte length of a base64 string without actually
// decoding it: each 4 input characters encode 3 output bytes, and up to two
// trailing `=` pad characters subtract from that. Good enough for a size-cap
// check — exact to within 2 bytes — without paying for (or depending on a
// target-specific kernel for) a real base64 decode just to measure size.
//
// Computed in `Long`, not `Int` (#7468): `s.length * 3` overflows a 32-bit
// `Int` for any string longer than ~715M characters, which would wrap
// negative and let an oversized attachment slip past the `maxTotalAttachmentBytes`
// cap. `(len / 4) * 3` (rather than `len * 3 / 4`) also avoids overflowing on
// the multiply for very long inputs.
func approxBase64DecodedLength(s: in String): Long {
  if s.length == 0 {
    return 0i64
  }
  var padding: Long = 0i64
  if s.length >= 1 and charAtOrReplacement(s, s.length - 1) == '=' {
    padding = 1i64
  }
  if s.length >= 2 and charAtOrReplacement(s, s.length - 2) == '=' {
    padding = 2i64
  }
  val len = s.length.toLong()
  return (len / 4i64) * 3i64 - padding
}

// Sum of every attachment's approximate decoded size, in bytes.
//
// Short-circuits as soon as the running total exceeds
// `maxTotalAttachmentBytes` (#7468): both avoids letting a `Long` total wrap
// on a pathological number of huge attachments and avoids doing more work
// than needed once the cap is already known to be exceeded.
func totalAttachmentBytes(attachments: in slice[Attachment]): Long {
  var total: Long = 0i64
  val cap = maxTotalAttachmentBytes.toLong()
  var i = 0
  while i < attachments.length {
    total = total + approxBase64DecodedLength(attachments[i].dataBase64)
    if total > cap {
      return total
    }
    i = i + 1
  }
  return total
}

// Exactly one '@', a non-empty local part, and a non-empty domain part
// containing no whitespace, CR, or LF — the minimal shape check that
// catches the silently-skipped-recipient bug (#7254). An address failing
// this is rejected with a structured `Err` rather than silently dropped
// from the recipient list a partial send goes out to.
//
// Previously this only checked for the presence of `@` anywhere in the
// string, which let through implausible shapes like `@`, `a@`, `@b`, and
// `a@b@c` (#7476 suggestion 5).
func isPlausibleAddress(address: in String): Bool {
  val atIndex = findAtSignIndex(address)
  match atIndex {
    case None -> false
    case Some(i) -> {
      val localPart = address.substring(0, i)
      val domainPart = address.substring(i + 1, address.length - i - 1)
      if localPart.length == 0 or domainPart.length == 0 {
        false
      } else if containsAtSign(domainPart) {
        // More than one '@' in the address (rejects "a@b@c").
        false
      } else {
        not containsWhitespaceOrNewline(domainPart)
      }
    }
  }
}

func findAtSignIndex(s: in String): Option[Int] {
  var i = 0
  while i < s.length {
    if charAtOrReplacement(s, i) == '@' {
      return Some(value = i)
    }
    i = i + 1
  }
  return None
}

func containsAtSign(s: in String): Bool {
  match findAtSignIndex(s) {
    case Some(_) -> true
    case None -> false
  }
}

func containsWhitespaceOrNewline(s: in String): Bool {
  var i = 0
  while i < s.length {
    val ch = charAtOrReplacement(s, i)
    if ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n' {
      return true
    }
    i = i + 1
  }
  return false
}

// Reject a recipient list (or `replyTo`) containing an implausible address
// instead of silently skipping it: a partial send is worse than a rejected
// one, since the caller has no signal that some recipients never received
// the message (#7254), and an implausible `replyTo` was previously dropped
// entirely rather than validated like `to`/`cc`/`bcc` (#7476 suggestion 4).
// `from` is not checked here — the BCL `MailAddress` constructor already
// throws `FormatException` on a malformed `from`, which the caller sees as
// `Err(code = "SEND_ERROR")`.
func validateRecipientAddresses(msg: in EmailMessage): Option[MailError] {
  var i = 0
  while i < msg.to.length {
    if not isPlausibleAddress(msg.to[i].address) {
      return Some(value = MailError(message = "to[" + ("" + i) + "] has an invalid address", code = "INVALID_ADDRESS"))
    }
    i = i + 1
  }
  var ci = 0
  while ci < msg.cc.length {
    if not isPlausibleAddress(msg.cc[ci].address) {
      return Some(value = MailError(message = "cc[" + ("" + ci) + "] has an invalid address", code = "INVALID_ADDRESS"))
    }
    ci = ci + 1
  }
  var bi = 0
  while bi < msg.bcc.length {
    if not isPlausibleAddress(msg.bcc[bi].address) {
      return Some(value = MailError(message = "bcc[" + ("" + bi) + "] has an invalid address", code = "INVALID_ADDRESS"))
    }
    bi = bi + 1
  }
  match msg.replyTo {
    case None -> ()
    case Some(rt) -> if not isPlausibleAddress(rt.address) {
      return Some(value = MailError(message = "replyTo has an invalid address", code = "INVALID_ADDRESS"))
    }
  }
  return None
}

// ─── Native sender wrapper (internal, --target dotnet) ───────────────────────
// The SmtpClient is held directly as an opaque extern type — no integer
// handle registry needed (Gap 1: BCL reference type storage via extern type).
// The extern types themselves live in `Mail.Kernel.Net` (externs are allowed
// only in kernel files); this package consumes them qualified through that
// import, exactly like `KMailAddressCollection`/`KMailAddress` already do
// inside the kernel itself.
@cfg(feature = "dotnet")
record NativeSender {
  client: MailKernel.SmtpClient
}

@cfg(feature = "dotnet")
impl MailSender for NativeSender {
  /// Build a `MailMessage` from `msg` and dispatch it through the
  /// SMTP client.  Recipients (`to`, `cc`, `bcc`), `replyTo`, and
  /// `attachments` are all forwarded to the underlying BCL MailMessage.
  /// Each attachment's `dataBase64` field is decoded with
  /// `Convert.FromBase64String` and wrapped in a `MemoryStream`; the
  /// `filename` and `contentType` become the BCL `Attachment` name and
  /// media type respectively.  Fixes #1118.
  func send(msg: in EmailMessage): Result[Unit, MailError] {
    // Defense-in-depth (#3181): the Mail.send wrapper runs the full
    // header-injection guard, but the MailSender interface is callable
    // directly, so re-run the FULL guard here (subject, from, to/cc/bcc,
    // replyTo, and attachments) before any BCL header is constructed —
    // not just the attachment metadata, which left subject/recipients
    // unguarded on the direct-send path.
    match validateNoInjection(msg) {
      case Some(e) -> return Err(e)
      case None -> ()
    }
    // Reject a recipient-less message with a structured Err on the direct-send
    // path too, rather than letting the BCL surface a generic exception (#5490)
    // — mirrors the same check in the Mail.send wrapper.
    if msg.to.length == 0 {
      return Err(MailError(message = "message has no recipients", code = "NO_RECIPIENTS"))
    }
    // Reject any recipient with an implausible address on the direct-send path
    // too (#7254) — mirrors the same check in the Mail.send wrapper, instead of
    // silently skipping it below and sending to a partial recipient list.
    match validateRecipientAddresses(msg) {
      case Some(e) -> return Err(e)
      case None -> ()
    }
    // Reject an oversized attachment payload before dispatch (#7254) — mirrors
    // the same check in the Mail.send wrapper.
    if totalAttachmentBytes(msg.attachments) > maxTotalAttachmentBytes.toLong() {
      return Err(
        MailError(message = "total attachment size exceeds maxTotalAttachmentBytes", code = "ATTACHMENTS_TOO_LARGE")
      )
    }
    try {
      val mailMsg = MailKernel.MailMessage.new()
      val fromAddr = MailKernel.MailAddress.new(msg.from.address, msg.from.displayName)
      mailMsg.set_From(fromAddr)
      mailMsg.set_Subject(msg.subject)
      val toCollection = mailMsg.get_To()
      var i = 0
      while i < msg.to.length {
        val addr = MailKernel.MailAddress.new(msg.to[i].address, msg.to[i].displayName)
        MailKernel.mailAddressCollectionAdd(toCollection, addr)
        i = i + 1
      }
      val ccCollection = mailMsg.get_CC()
      var ci = 0
      while ci < msg.cc.length {
        val addr = MailKernel.MailAddress.new(msg.cc[ci].address, msg.cc[ci].displayName)
        MailKernel.mailAddressCollectionAdd(ccCollection, addr)
        ci = ci + 1
      }
      val bccCollection = mailMsg.get_Bcc()
      var bi = 0
      while bi < msg.bcc.length {
        val addr = MailKernel.MailAddress.new(msg.bcc[bi].address, msg.bcc[bi].displayName)
        MailKernel.mailAddressCollectionAdd(bccCollection, addr)
        bi = bi + 1
      }
      match msg.replyTo {
        case Some(rt) -> {
          if rt.address.length > 0 {
            val replyToList = mailMsg.get_ReplyToList()
            val rtAddr = MailKernel.MailAddress.new(rt.address, rt.displayName)
            MailKernel.mailAddressCollectionAdd(replyToList, rtAddr)
          }
        }
        case None -> ()
      }
      if msg.htmlBody.length > 0 {
        mailMsg.set_IsBodyHtml(true)
        mailMsg.set_Body(msg.htmlBody)
      } else {
        mailMsg.set_IsBodyHtml(false)
        mailMsg.set_Body(msg.textBody)
      }
      // Decode each base64 attachment payload and append it to the BCL
      // MailMessage.Attachments collection.
      // MemoryStreams created here are never explicitly disposed: they are
      // byte-array-backed (no unmanaged resources), so the GC reclaims them
      // safely on both the success and the throw path.
      val attColl = mailMsg.get_Attachments()
      var ai = 0
      while ai < msg.attachments.length {
        val att = msg.attachments[ai]
        val bytes = MailKernel.base64Decode(att.dataBase64)
        val stream = MailKernel.newMemoryStream(bytes)
        val bclAtt = MailKernel.newBclAttachment(stream, att.filename, att.contentType)
        // The (stream, name, mediaType) constructor names only the Content-Type
        // `name` parameter; most mail clients show the Content-Disposition
        // `filename`, so set it too (#7462).
        bclAtt.get_ContentDisposition().set_FileName(att.filename)
        MailKernel.attachmentCollectionAdd(attColl, bclAtt)
        ai = ai + 1
      }
      MailKernel.sendMessage(self.client, mailMsg)
      Ok(())
    } catch Exception as e {
      Err(MailError(message = e.message, code = "SEND_ERROR"))
    }
  }

  func close(): Unit {
    try {
      self.client.Dispose()
    } catch Exception as e {
      // Swallow dispose errors — same policy as the legacy F# shim.
      ()
    }
  }
}

// ─── Native sender wrapper (internal, --target jvm) ───────────────────────────
// `handle` is the opaque Int connection handle `Mail.Kernel.Jvm.connectSmtp`
// hands back; `send`/`close` call into `Mail.Kernel.Jvm`, which delivers
// through Jakarta Mail (#7462).
//
// Gated on both `jvm` AND `smtp` (#7476 suggestion 6): every method this
// record's `impl` calls into (`Mail.Kernel.Jvm.connectSmtp`/`send`/`close`)
// is itself gated on `feature = "smtp"`, so a `jvm` build without `smtp`
// active must erase this record and its `impl` too, or the call sites below
// would be left referencing erased symbols.
@cfg(feature = "jvm")
@cfg(feature = "smtp")
record NativeSenderJvm {
  handle: Int
}

@cfg(feature = "jvm")
@cfg(feature = "smtp")
impl MailSender for NativeSenderJvm {
  func send(msg: in EmailMessage): Result[Unit, MailError] {
    match validateNoInjection(msg) {
      case Some(e) -> return Err(e)
      case None -> ()
    }
    if msg.to.length == 0 {
      return Err(MailError(message = "message has no recipients", code = "NO_RECIPIENTS"))
    }
    match validateRecipientAddresses(msg) {
      case Some(e) -> return Err(e)
      case None -> ()
    }
    if totalAttachmentBytes(msg.attachments) > maxTotalAttachmentBytes.toLong() {
      return Err(
        MailError(message = "total attachment size exceeds maxTotalAttachmentBytes", code = "ATTACHMENTS_TOO_LARGE")
      )
    }
    match MailKernelJvm.send(self.handle, messageToJson(msg)) {
      case Ok(_) -> Ok(())
      case Err(m) -> Err(MailError(message = m, code = "SEND_ERROR"))
    }
  }

  func close(): Unit {
    MailKernelJvm.close(self.handle)
  }
}

// JSON-encode `msg` for `Mail.Kernel.Jvm.send`'s `messageJson` parameter.
// Field names and shape match `EmailMessage` directly (address/displayName
// pairs for from/to/cc/bcc/replyTo; filename/contentType/dataBase64 triples
// for attachments) — a schema the module header on `Mail.Kernel.Jvm`
// documents.
//
// Escapes `"` and `\`, plus every character below U+0020 as `\uXXXX`
// (`\n`/`\r`/`\t` use the short forms). `validateNoInjection` only rejects
// CR/LF/NUL — it does not cover every control character, and it never
// touches `textBody`/`htmlBody` at all, so a multi-line body (or any other
// control character in a field this function touches) must still be escaped
// here to produce valid JSON (#7476).
@cfg(feature = "jvm")
@cfg(feature = "smtp")
func jsonEscape(s: in String): String {
  var buf = ""
  var i = 0
  while i < s.length {
    val ch = charAtOrReplacement(s, i)
    if ch == '"' {
      buf = buf + "\\\""
    } else if ch == '\\' {
      buf = buf + "\\\\"
    } else if ch == '\n' {
      buf = buf + "\\n"
    } else if ch == '\r' {
      buf = buf + "\\r"
    } else if ch == '\t' {
      buf = buf + "\\t"
    } else if Std.Char.toInt(ch) < 0x20 {
      buf = buf + "\\u00" + Std.Format.hexPad(Std.Char.toInt(ch), 2)
    } else {
      buf = buf + s.substring(i, 1)
    }
    i = i + 1
  }
  return buf
}

@cfg(feature = "jvm")
@cfg(feature = "smtp")
func addressToJson(addr: in EmailAddress): String {
  return "{\"address\":\"" + jsonEscape(addr.address) + "\",\"displayName\":\"" + jsonEscape(addr.displayName) + "\"}"
}

@cfg(feature = "jvm")
@cfg(feature = "smtp")
func addressListToJson(addrs: in slice[EmailAddress]): String {
  var buf = "["
  var i = 0
  while i < addrs.length {
    if i > 0 {
      buf = buf + ","
    }
    buf = buf + addressToJson(addrs[i])
    i = i + 1
  }
  return buf + "]"
}

@cfg(feature = "jvm")
@cfg(feature = "smtp")
func attachmentToJson(att: in Attachment): String {
  return "{\"filename\":\"" + jsonEscape(att.filename) + "\",\"contentType\":\"" + jsonEscape(att.contentType) +
    "\",\"dataBase64\":\"" +
    jsonEscape(att.dataBase64) +
    "\"}"
}

@cfg(feature = "jvm")
@cfg(feature = "smtp")
func attachmentListToJson(attachments: in slice[Attachment]): String {
  var buf = "["
  var i = 0
  while i < attachments.length {
    if i > 0 {
      buf = buf + ","
    }
    buf = buf + attachmentToJson(attachments[i])
    i = i + 1
  }
  return buf + "]"
}

// `pub` (but not `@stable`, so excluded from the tracked public-API surface —
// see the `MailSenderStub` doc comment above for the same reasoning) so
// `Mail.MailTests` can assert on its output directly: the escaping and
// field-carry-through (e.g. `displayName`) this function performs are
// otherwise only observable by a live JVM SMTP transport, which the test
// suite does not have (#7476 suggestion 8).
@cfg(feature = "jvm")
@cfg(feature = "smtp")
pub func messageToJson(msg: in EmailMessage): String {
  val replyToJson = match msg.replyTo { case Some(addr) -> addressToJson(addr); case None -> "null" }
  return "{\"from\":" + addressToJson(msg.from) + ",\"to\":" + addressListToJson(msg.to) + ",\"cc\":" +
    addressListToJson(msg.cc) +
    ",\"bcc\":" +
    addressListToJson(msg.bcc) +
    ",\"subject\":\"" +
    jsonEscape(msg.subject) +
    "\",\"textBody\":\"" +
    jsonEscape(msg.textBody) +
    "\",\"htmlBody\":\"" +
    jsonEscape(msg.htmlBody) +
    "\",\"attachments\":" +
    attachmentListToJson(msg.attachments) +
    ",\"replyTo\":" +
    replyToJson +
    "}"
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
/// SMTP port must be a valid TCP port; timeoutMs must be positive. Both are
/// parsed from env vars by `connectSmtp`, so an operator typo (an
/// out-of-range port, a negative timeout) is rejected with a clear Err
/// rather than passed through to `SmtpClient.new`/`.set_Timeout` uninspected
/// (#7254). `pub` so it is directly unit-testable without needing to mutate
/// process env vars — `Std.Environment.setVar` is a documented no-op on
/// `--target jvm` (`Std.EnvironmentHost.hostSetEnvironmentVariable`; the JVM
/// has no supported way to mutate `System.getenv()`), so an env-var-driven
/// test of this logic would only exercise the default config on that
/// target.
@stable(since = "0.1")
pub func validateSmtpConfig(port: in Int, timeoutMs: in Int): Option[MailError] {
  if port < 1 or port > 65535 {
    return Some(value = MailError(message = "SMTP port out of range 1..65535: " + ("" + port), code = "INVALID_CONFIG"))
  }
  if timeoutMs < 1 {
    return Some(value = MailError(message = "SMTP timeoutMs must be >= 1: " + ("" + timeoutMs), code = "INVALID_CONFIG"))
  }
  return None
}

/// Open an SMTP connection using environment variable config.
/// Requires the `smtp` feature to be active (`[features] smtp = []`).
/// Config is read from LYRIC_CONFIG_SMTP_* env vars.  Rejects a
/// non-numeric, or a numeric but out-of-range, `LYRIC_CONFIG_SMTP_PORT`
/// (must be 1..65535) or `LYRIC_CONFIG_SMTP_TIMEOUTMS` (must be >= 1) with
/// `Err(code = "INVALID_CONFIG")`, naming the offending variable, before
/// attempting a connection.
@stable(since = "0.1")
@cfg(feature = "smtp")
pub func connectSmtp(): Result[MailSender, MailError] {
  val host = Env.getVarOrDefault("LYRIC_CONFIG_SMTP_HOST", "localhost")
  val portStr = Env.getVarOrDefault("LYRIC_CONFIG_SMTP_PORT", "587")
  val username = Env.getVarOrDefault("LYRIC_CONFIG_SMTP_USERNAME", "")
  val password = Env.getVarOrDefault("LYRIC_CONFIG_SMTP_PASSWORD", "")
  val useTlsStr = Env.getVarOrDefault("LYRIC_CONFIG_SMTP_USETLS", "true")
  val toMs = Env.getVarOrDefault("LYRIC_CONFIG_SMTP_TIMEOUTMS", "30000")
  // An unparsable value is a genuine operator typo, not "unset" — an unset
  // var never reaches `parseOptInt` at all (`getVarOrDefault` already
  // substituted a parseable default above). Report it by name rather than
  // silently falling back to the default (#7476 suggestion 3).
  val port = match parseOptInt(portStr) {
    case Some(n) -> n
    case None -> return Err(MailError(message = "LYRIC_CONFIG_SMTP_PORT is not a valid integer: " + portStr, code = "INVALID_CONFIG"))
  }
  val useTls = useTlsStr != "false"
  val timeoutMs = match parseOptInt(toMs) {
    case Some(n) -> n
    case None -> return Err(
      MailError(message = "LYRIC_CONFIG_SMTP_TIMEOUTMS is not a valid integer: " + toMs, code = "INVALID_CONFIG")
    )
  }
  match validateSmtpConfig(port, timeoutMs) {
    case Some(e) -> return Err(e)
    case None -> ()
  }
  return connectSmtpNative(host, port, username, password, useTls, timeoutMs)
}

@cfg(feature = "dotnet")
func connectSmtpNative(
  host: in String,
  port: in Int,
  username: in String,
  password: in String,
  useTls: in Bool,
  timeoutMs: in Int,
): Result[MailSender, MailError] {
  try {
    val client = MailKernel.SmtpClient.new(host, port)
    client.set_EnableSsl(useTls)
    client.set_Timeout(timeoutMs)
    if username.length > 0 {
      val cred = MailKernel.NetworkCredential.new(username, password)
      MailKernel.setCredentials(client, cred)
    }
    Ok(NativeSender(client = client))
  } catch Exception as e {
    Err(MailError(message = e.message, code = "CONNECT_ERROR"))
  }
}

// Gated on both `jvm` AND `smtp` (#7476 suggestion 6) — see the note on
// `NativeSenderJvm` above: this function references `NativeSenderJvm` and
// `MailKernelJvm.connectSmtp`, both `smtp`-gated, so it must be too.
@cfg(feature = "jvm")
@cfg(feature = "smtp")
func connectSmtpNative(
  host: in String,
  port: in Int,
  username: in String,
  password: in String,
  useTls: in Bool,
  timeoutMs: in Int,
): Result[MailSender, MailError] {
  match MailKernelJvm.connectSmtp(host, port, username, password, useTls, timeoutMs) {
    case Ok(handle) -> Ok(NativeSenderJvm(handle = handle))
    case Err(msg) -> Err(MailError(message = msg, code = "INVALID_CONFIG"))
  }
}

// Read a required (non-empty) env var config field, or an Err naming which
// one was missing. Shared by connectSes/connectSendGrid so the same
// precondition holds identically on every target (#7254).
func requireEnvVar(envVar: in String, fieldDescription: in String): Result[String, MailError] {
  val v = Env.getVarOrDefault(envVar, "")
  if v.length == 0 {
    return Err(MailError(message = fieldDescription + " is required (set " + envVar + ")", code = "INVALID_CONFIG"))
  }
  return Ok(v)
}

// ─── HTTPS providers: SendGrid and Amazon SES (#7462) ─────────────────────────
// Both providers are plain HTTPS APIs, so they are implemented once here over
// `Std.Http` and behave identically on every target (no provider SDK, no
// per-target kernel).  The builders below are `pub` and carry no `@stable`
// annotation, so tests can pin the exact wire format without it becoming part
// of the stable API surface.
record HeaderPair {
  name: String
  value: String
}

func hasNonAscii(s: in String): Bool {
  var i = 0
  while i < s.length {
    if charAtOrReplacement(s, i) > '\u{007f}' {
      return true
    }
    i = i + 1
  }
  return false
}

func escapeQuoted(s: in String): String {
  return s.replace("\\", "\\\\").replace("\"", "\\\"")
}

// RFC 2047 encoded-word for header text that is not plain ASCII.
func encodeHeaderText(s: in String): String {
  if hasNonAscii(s) {
    return "=?UTF-8?B?" + Enc.encodeBase64(Enc.encodeUtf8(s)) + "?="
  }
  return s
}

/// `Name <addr>` as it appears in a MIME or SES address field.
pub func formatAddressHeader(a: in EmailAddress): String {
  if a.displayName.length == 0 {
    return a.address
  }
  if hasNonAscii(a.displayName) {
    return encodeHeaderText(a.displayName) + " <" + a.address + ">"
  }
  return "\"" + escapeQuoted(a.displayName) + "\" <" + a.address + ">"
}

func joinAddressHeaders(list: in slice[EmailAddress]): String {
  var buf = ""
  var i = 0
  while i < list.length {
    if i > 0 {
      buf = buf + ", "
    }
    buf = buf + formatAddressHeader(list[i])
    i = i + 1
  }
  return buf
}

// A JSON array of the formatted addresses, e.g. `["a@b","\"N\" <c@d>"]`.
func jsonAddressArray(list: in slice[EmailAddress]): String {
  var buf = "["
  var i = 0
  while i < list.length {
    if i > 0 {
      buf = buf + ","
    }
    buf = buf + Json.encodeString(formatAddressHeader(list[i]))
    i = i + 1
  }
  return buf + "]"
}

// Base64 wrapped at 76 columns with CRLF line ends (RFC 2045 section 6.8).
func wrapBase64(b64: in String): String {
  var buf = ""
  var i = 0
  while i < b64.length {
    val take = if b64.length - i < 76 { b64.length - i } else { 76 }
    buf = buf + b64.substring(i, take) + "\r\n"
    i = i + take
  }
  return buf
}

// ── SendGrid v3 ──────────────────────────────────────────────────────────────
func sgAddress(a: in EmailAddress): String {
  val base = "{\"email\":" + Json.encodeString(a.address)
  if a.displayName.length > 0 {
    return base + ",\"name\":" + Json.encodeString(a.displayName) + "}"
  }
  return base + "}"
}

func sgAddressArray(list: in slice[EmailAddress]): String {
  var buf = "["
  var i = 0
  while i < list.length {
    if i > 0 {
      buf = buf + ","
    }
    buf = buf + sgAddress(list[i])
    i = i + 1
  }
  return buf + "]"
}

/// The JSON body of `POST /v3/mail/send` for `msg`.  `bcc` recipients go in the
/// personalization (never in a visible header), the text part precedes the
/// HTML part as SendGrid requires, and attachments are sent as-is (their
/// content is already base64).
pub func buildSendGridPayload(msg: in EmailMessage): String {
  var personalization = "{\"to\":" + sgAddressArray(msg.to)
  if msg.cc.length > 0 {
    personalization = personalization + ",\"cc\":" + sgAddressArray(msg.cc)
  }
  if msg.bcc.length > 0 {
    personalization = personalization + ",\"bcc\":" + sgAddressArray(msg.bcc)
  }
  personalization = personalization + "}"
  var body = "{\"personalizations\":[" + personalization + "],\"from\":" + sgAddress(msg.from) + ",\"subject\":" +
    Json.encodeString(msg.subject)
  match msg.replyTo {
    case Some(rt) -> {
      if rt.address.length > 0 {
        body = body + ",\"reply_to\":" + sgAddress(rt)
      }
    }
    case None -> ()
  }
  var content = ""
  if msg.textBody.length > 0 {
    content = "{\"type\":\"text/plain\",\"value\":" + Json.encodeString(msg.textBody) + "}"
  }
  if msg.htmlBody.length > 0 {
    if content.length > 0 {
      content = content + ","
    }
    content = content + "{\"type\":\"text/html\",\"value\":" + Json.encodeString(msg.htmlBody) + "}"
  }
  body = body + ",\"content\":[" + content + "]"
  if msg.attachments.length > 0 {
    body = body + ",\"attachments\":["
    var i = 0
    while i < msg.attachments.length {
      if i > 0 {
        body = body + ","
      }
      val att = msg.attachments[i]
      body = body + "{\"content\":" + Json.encodeString(att.dataBase64) + ",\"filename\":" + Json.encodeString(att.filename) +
        ",\"type\":" +
        Json.encodeString(att.contentType) +
        ",\"disposition\":\"attachment\"}"
      i = i + 1
    }
    body = body + "]"
  }
  return body + "}"
}

// ── Amazon SES v2 ────────────────────────────────────────────────────────────
func mimeBodyPart(contentType: in String, text: in String): String {
  return "Content-Type: " + contentType + "; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n" +
    wrapBase64(Enc.encodeBase64(Enc.encodeUtf8(text)))
}

/// The RFC 5322 / MIME rendering of `msg` that SES `Raw` content carries when
/// the message has attachments.  `bcc` is deliberately absent from the
/// headers; SES takes the envelope recipients from `Destination`.
pub func buildMimeMessage(msg: in EmailMessage, boundary: in String): String {
  var buf = "From: " + formatAddressHeader(msg.from) + "\r\nTo: " + joinAddressHeaders(msg.to) + "\r\n"
  if msg.cc.length > 0 {
    buf = buf + "Cc: " + joinAddressHeaders(msg.cc) + "\r\n"
  }
  match msg.replyTo {
    case Some(rt) -> {
      if rt.address.length > 0 {
        buf = buf + "Reply-To: " + formatAddressHeader(rt) + "\r\n"
      }
    }
    case None -> ()
  }
  buf = buf + "Subject: " + encodeHeaderText(msg.subject) + "\r\nMIME-Version: 1.0\r\n"
  buf = buf + "Content-Type: multipart/mixed; boundary=\"" + boundary + "\"\r\n\r\n"
  buf = buf + "--" + boundary + "\r\n"
  if msg.textBody.length > 0 and msg.htmlBody.length > 0 {
    val alt = boundary + "_alt"
    buf = buf + "Content-Type: multipart/alternative; boundary=\"" + alt + "\"\r\n\r\n"
    buf = buf + "--" + alt + "\r\n" + mimeBodyPart("text/plain", msg.textBody)
    buf = buf + "--" + alt + "\r\n" + mimeBodyPart("text/html", msg.htmlBody)
    buf = buf + "--" + alt + "--\r\n"
  } else if msg.htmlBody.length > 0 {
    buf = buf + mimeBodyPart("text/html", msg.htmlBody)
  } else {
    buf = buf + mimeBodyPart("text/plain", msg.textBody)
  }
  var i = 0
  while i < msg.attachments.length {
    val att = msg.attachments[i]
    val name = escapeQuoted(encodeHeaderText(att.filename))
    buf = buf + "--" + boundary + "\r\n"
    buf = buf + "Content-Type: " + att.contentType + "; name=\"" + name + "\"\r\n"
    buf = buf + "Content-Disposition: attachment; filename=\"" + name + "\"\r\n"
    buf = buf + "Content-Transfer-Encoding: base64\r\n\r\n" + wrapBase64(att.dataBase64)
    i = i + 1
  }
  return buf + "--" + boundary + "--\r\n"
}

func sesDestination(msg: in EmailMessage): String {
  var buf = "{\"ToAddresses\":" + jsonAddressArray(msg.to)
  if msg.cc.length > 0 {
    buf = buf + ",\"CcAddresses\":" + jsonAddressArray(msg.cc)
  }
  if msg.bcc.length > 0 {
    buf = buf + ",\"BccAddresses\":" + jsonAddressArray(msg.bcc)
  }
  return buf + "}"
}

func sesTextContent(text: in String): String {
  return "{\"Data\":" + Json.encodeString(text) + ",\"Charset\":\"UTF-8\"}"
}

/// The JSON body of SES v2 `SendEmail` for `msg`: `Simple` content when there
/// are no attachments, `Raw` MIME (built with `boundary`) when there are.
pub func buildSesPayload(msg: in EmailMessage, boundary: in String): String {
  var body = "{\"FromEmailAddress\":" + Json.encodeString(formatAddressHeader(msg.from)) + ",\"Destination\":" +
    sesDestination(msg)
  match msg.replyTo {
    case Some(rt) -> {
      if rt.address.length > 0 {
        body = body + ",\"ReplyToAddresses\":" + jsonAddressArray([rt])
      }
    }
    case None -> ()
  }
  if msg.attachments.length > 0 {
    val mime = buildMimeMessage(msg, boundary)
    return body + ",\"Content\":{\"Raw\":{\"Data\":" + Json.encodeString(Enc.encodeBase64(Enc.encodeUtf8(mime))) + "}}}"
  }
  var parts = ""
  if msg.textBody.length > 0 {
    parts = "\"Text\":" + sesTextContent(msg.textBody)
  }
  if msg.htmlBody.length > 0 {
    if parts.length > 0 {
      parts = parts + ","
    }
    parts = parts + "\"Html\":" + sesTextContent(msg.htmlBody)
  }
  return body + ",\"Content\":{\"Simple\":{\"Subject\":" + sesTextContent(msg.subject) + ",\"Body\":{" + parts + "}}}}"
}

func hmacBytes(key: in slice[Byte], message: in String): slice[Byte] {
  return Hash.hmacSha256(key, Enc.encodeUtf8(message))
}

/// The `Authorization` header value for an AWS Signature Version 4 request
/// (https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv4-create-signed-request.html)
/// with an empty query string.  Signs `host` and `x-amz-date`, plus
/// `x-amz-security-token` when `sessionToken` is non-empty; `Content-Type` is
/// left unsigned so the HTTP layer remains free to set it.
pub func sigV4Authorization(
  method: in String,
  canonicalUri: in String,
  host: in String,
  region: in String,
  service: in String,
  accessKey: in String,
  secretKey: in String,
  sessionToken: in String,
  amzDate: in String,
  payload: in String,
): String {
  val dateStamp = amzDate.substring(0, 8)
  var canonicalHeaders = "host:" + host + "\nx-amz-date:" + amzDate + "\n"
  var signedHeaders = "host;x-amz-date"
  if sessionToken.length > 0 {
    canonicalHeaders = canonicalHeaders + "x-amz-security-token:" + sessionToken + "\n"
    signedHeaders = signedHeaders + ";x-amz-security-token"
  }
  val payloadHash = Hash.sha256OfBytes(Enc.encodeUtf8(payload)).toLower()
  val canonicalRequest = method + "\n" + canonicalUri + "\n\n" + canonicalHeaders + "\n" + signedHeaders + "\n" +
    payloadHash
  val credScope = dateStamp + "/" + region + "/" + service + "/aws4_request"
  val stringToSign = "AWS4-HMAC-SHA256\n" + amzDate + "\n" + credScope + "\n" +
    Hash.sha256OfBytes(Enc.encodeUtf8(canonicalRequest)).toLower()
  val kDate = hmacBytes(Enc.encodeUtf8("AWS4" + secretKey), dateStamp)
  val kRegion = hmacBytes(kDate, region)
  val kService = hmacBytes(kRegion, service)
  val kSigning = hmacBytes(kService, "aws4_request")
  val signature = Enc.encodeHex(hmacBytes(kSigning, stringToSign)).toLower()
  return "AWS4-HMAC-SHA256 Credential=" + accessKey + "/" + credScope + ", SignedHeaders=" + signedHeaders +
    ", Signature=" +
    signature
}

// `20261023T123456Z` for the current instant.
func currentAmzDate(): String {
  val iso = Time.toIsoString(Time.now())
  return iso.substring(0, 19).replace("-", "").replace(":", "") + "Z"
}

/// The authority (`host[:port]`) of an `http(s)://` endpoint URL.
pub func endpointHost(endpoint: in String): String {
  var rest = endpoint
  if rest.startsWith("https://") {
    rest = rest.substring(8)
  } else if rest.startsWith("http://") {
    rest = rest.substring(7)
  }
  var stop = 0
  while stop < rest.length and charAtOrReplacement(rest, stop) != '/' {
    stop = stop + 1
  }
  return rest.substring(0, stop)
}

/// Map an HTTP status from a provider to a `MailError.code`.
pub func mailErrorCodeForStatus(status: in Int): String {
  if status == 401 or status == 403 {
    return "AUTH_FAILED"
  }
  if status == 429 {
    return "QUOTA_EXCEEDED"
  }
  if status >= 500 {
    return "PROVIDER_ERROR"
  }
  return "SEND_ERROR"
}

// Checks every `MailSender.send` implementation must run before dispatch.
func validateForDispatch(msg: in EmailMessage): Option[MailError] {
  match validateNoInjection(msg) {
    case Some(e) -> return Some(value = e)
    case None -> ()
  }
  if msg.to.length == 0 {
    return Some(value = MailError(message = "message has no recipients", code = "NO_RECIPIENTS"))
  }
  match validateRecipientAddresses(msg) {
    case Some(e) -> return Some(value = e)
    case None -> ()
  }
  if totalAttachmentBytes(msg.attachments) > maxTotalAttachmentBytes.toLong() {
    return Some(
      value = MailError(
        message = "total attachment size exceeds maxTotalAttachmentBytes",
        code = "ATTACHMENTS_TOO_LARGE"
      )
    )
  }
  return None
}

// Plain (non-`async`) so it may `await` in place and still wrap the send in
// `try` (V0012 forbids `await` inside `try` in an `async func`).
func sendHttpCatching(client: in HttpClient, req: in HttpRequest, url: in String): Result[HttpResponse, HttpError] {
  return try {
    await client.send(req)
  } catch Bug as bug {
    Err(error = ConnectionFailed(url = url, message = bug.message))
  }
}

func providerFailure(resp: in HttpResponse): MailError {
  val status = HttpResponse.statusCode(resp)
  var detail = ""
  val bodyRead = await HttpResponse.bodyText(resp)
  match bodyRead {
    case Ok(text) -> {
      detail = if text.length > 500 { text.substring(0, 500) } else { text }
    }
    case Err(_) -> ()
  }
  return MailError(
    message = "provider returned HTTP " + status.toString() + ": " + detail,
    code = mailErrorCodeForStatus(status)
  )
}

// POST `body` as JSON to `url` with `headers`; `Ok` only for a 2xx answer.
func postJsonToProvider(
  client: in HttpClient, url: in String, headers: in slice[HeaderPair], body: in String
): Result[Unit, MailError] {
  val parsed = match Url.tryFrom(url) {
    case Err(_) -> return Err(MailError(message = "invalid provider endpoint URL: " + url, code = "INVALID_CONFIG"))
    case Ok(u) -> u
  }
  var req = withJsonBody(request(POST, parsed), body)
  var i = 0
  while i < headers.length {
    match withHeader(req, headers[i].name, headers[i].value) {
      case Ok(r) -> {
        req = r
      }
      case Err(_) -> return Err(
        MailError(
          message = "provider header " + headers[i].name + " is not a valid HTTP header",
          code = "INVALID_CONFIG"
        )
      )
    }
    i = i + 1
  }
  match sendHttpCatching(client, req, url) {
    case Err(e) -> return Err(MailError(message = HttpError.message(e), code = "SEND_ERROR"))
    case Ok(resp) -> {
      if HttpResponse.isSuccess(resp) {
        return Ok(())
      }
      return Err(providerFailure(resp))
    }
  }
}

@cfg(feature = "sendgrid")
record SendGridSender {
  endpoint: String
  apiKey: String
  client: HttpClient
}

@cfg(feature = "sendgrid")
impl MailSender for SendGridSender {
  func send(msg: in EmailMessage): Result[Unit, MailError] {
    match validateForDispatch(msg) {
      case Some(e) -> return Err(e)
      case None -> ()
    }
    val headers = [HeaderPair(name = "Authorization", value = "Bearer " + self.apiKey)]
    return postJsonToProvider(self.client, self.endpoint + "/v3/mail/send", headers, buildSendGridPayload(msg))
  }

  func close(): Unit {
  }
}

@cfg(feature = "ses")
record SesSender {
  endpoint: String
  region: String
  accessKey: String
  secretKey: String
  sessionToken: String
  client: HttpClient
}

@cfg(feature = "ses")
impl MailSender for SesSender {
  func send(msg: in EmailMessage): Result[Unit, MailError] {
    match validateForDispatch(msg) {
      case Some(e) -> return Err(e)
      case None -> ()
    }
    val path = "/v2/email/outbound-emails"
    val body = buildSesPayload(msg, "=_lyric_" + Uuid.uuidToString(Uuid.newUuid()))
    val amzDate = currentAmzDate()
    val auth = sigV4Authorization(
      "POST",
      path,
      endpointHost(self.endpoint),
      self.region,
      "ses",
      self.accessKey,
      self.secretKey,
      self.sessionToken,
      amzDate,
      body
    )
    var headers = [HeaderPair(name = "x-amz-date", value = amzDate), HeaderPair(name = "Authorization", value = auth)]
    if self.sessionToken.length > 0 {
      headers = [
        HeaderPair(name = "x-amz-date", value = amzDate),
        HeaderPair(name = "Authorization", value = auth),
        HeaderPair(name = "x-amz-security-token", value = self.sessionToken)
      ]
    }
    return postJsonToProvider(self.client, self.endpoint + path, headers, body)
  }

  func close(): Unit {
  }
}

// An endpoint endpointOverride must be an absolute http(s) URL; a trailing slash is
// dropped so `endpoint + path` never doubles it.
func normalizeEndpoint(raw: in String): Result[String, MailError] {
  if not (raw.startsWith("https://") or raw.startsWith("http://")) or endpointHost(raw).length == 0 {
    return Err(MailError(message = "provider endpoint must be an absolute http(s) URL: " + raw, code = "INVALID_CONFIG"))
  }
  // The API key or SigV4 headers would travel in clear text over http://, so
  // that is accepted only for a loopback test server.
  if raw.startsWith("http://") and not isLoopbackAuthority(endpointHost(raw)) {
    return Err(
      MailError(
        message = "provider endpoint must use https:// (http:// is allowed only for localhost, 127.0.0.1 and [::1]): " +
          raw,
        code = "INVALID_CONFIG"
      )
    )
  }
  var stop = raw.length
  while stop > 0 and charAtOrReplacement(raw, stop - 1) == '/' {
    stop = stop - 1
  }
  return Ok(raw.substring(0, stop))
}

/// True when the `host[:port]` authority names the loopback interface.
pub func isLoopbackAuthority(authority: in String): Bool {
  var host = authority
  if host.startsWith("[") {
    val close = lastIndexOfRaw(host, "]")
    host = if close > 0 { host.substring(0, close + 1) } else { host }
  } else {
    val colon = lastIndexOfRaw(host, ":")
    host = if colon >= 0 { host.substring(0, colon) } else { host }
  }
  return host == "localhost" or host == "127.0.0.1" or host == "[::1]"
}

/// True for a plausible AWS region name (`us-east-1`): lowercase letters,
/// digits and `-` only, so it can never alter the endpoint host it is built
/// into.
pub func isValidAwsRegion(region: in String): Bool {
  if region.length == 0 {
    return false
  }
  var i = 0
  while i < region.length {
    val c = charAtOrReplacement(region, i)
    if not ((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-') {
      return false
    }
    i = i + 1
  }
  return true
}

/// Open an Amazon SES client (SES v2 `SendEmail` over HTTPS, AWS Signature
/// Version 4; the same code on every target).
/// Requires the `ses` feature to be active (`[features] ses = []`).
/// Config is read from LYRIC_CONFIG_SES_* env vars: `REGION`, `ACCESSKEY`
/// and `SECRETKEY` are required and a missing one is `Err(code =
/// "INVALID_CONFIG")` naming it (#7254); `SESSIONTOKEN` is optional (temporary
/// credentials); `ENDPOINT` overrides `https://email.<region>.amazonaws.com`
/// (for a VPC endpoint or a local test server).  Nothing is sent until
/// `send`; a provider rejection comes back as `Err` with the HTTP status in the
/// message and `code` `AUTH_FAILED`, `QUOTA_EXCEEDED`, `PROVIDER_ERROR` or
/// `SEND_ERROR` (#7462).
@stable(since = "0.1")
@cfg(feature = "ses")
pub func connectSes(): Result[MailSender, MailError] {
  val region = match requireEnvVar("LYRIC_CONFIG_SES_REGION", "SES region") {
    case Ok(v) -> v
    case Err(e) -> return Err(e)
  }
  if not isValidAwsRegion(region) {
    return Err(
      MailError(
        message = "LYRIC_CONFIG_SES_REGION is not a valid AWS region name: " + region,
        code = "INVALID_CONFIG"
      )
    )
  }
  val accessKey = match requireEnvVar("LYRIC_CONFIG_SES_ACCESSKEY", "SES accessKey") {
    case Ok(v) -> v
    case Err(e) -> return Err(e)
  }
  val secretKey = match requireEnvVar("LYRIC_CONFIG_SES_SECRETKEY", "SES secretKey") {
    case Ok(v) -> v
    case Err(e) -> return Err(e)
  }
  val sessionToken = Env.getVarOrDefault("LYRIC_CONFIG_SES_SESSIONTOKEN", "")
  val endpointOverride = Env.getVarOrDefault("LYRIC_CONFIG_SES_ENDPOINT", "")
  val endpoint = match normalizeEndpoint(if endpointOverride.length > 0 { endpointOverride } else { "https://email." + region + ".amazonaws.com" }) {
    case Ok(v) -> v
    case Err(e) -> return Err(e)
  }
  return newSesSender(region, accessKey, secretKey, sessionToken, endpoint)
}

/// Build an SES sender from explicit values (what `connectSes` does after
/// reading the environment).  `endpoint` is an absolute `http(s)` URL without a
/// path.  `pub` without `@stable` so tests can aim a sender at a closed port.
@cfg(feature = "ses")
pub func newSesSender(
  region: in String,
  accessKey: in String,
  secretKey: in String,
  sessionToken: in String,
  endpoint: in String,
): Result[MailSender, MailError] {
  if not isValidAwsRegion(region) {
    return Err(MailError(message = "not a valid AWS region name: " + region, code = "INVALID_CONFIG"))
  }
  val normalized = match normalizeEndpoint(endpoint) { case Ok(v) -> v; case Err(e) -> return Err(e) }
  return Ok(
    SesSender(
      endpoint = normalized,
      region = region,
      accessKey = accessKey,
      secretKey = secretKey,
      sessionToken = sessionToken,
      client = defaultClient()
    )
  )
}

/// Open a SendGrid client (v3 `mail/send` over HTTPS; the same code on every
/// target).
/// Requires the `sendgrid` feature to be active (`[features] sendgrid = []`).
/// Config is read from LYRIC_CONFIG_SENDGRIDMAIL_* env vars: `APIKEY` is
/// required (`Err(code = "INVALID_CONFIG")` when empty, #7254); `ENDPOINT`
/// overrides `https://api.sendgrid.com` (EU data residency or a local test
/// server).  Provider rejections map to `MailError.code` as for `connectSes`
/// (#7462).
@stable(since = "0.1")
@cfg(feature = "sendgrid")
pub func connectSendGrid(): Result[MailSender, MailError] {
  val apiKey = match requireEnvVar("LYRIC_CONFIG_SENDGRIDMAIL_APIKEY", "SendGrid apiKey") {
    case Ok(v) -> v
    case Err(e) -> return Err(e)
  }
  val endpointOverride = Env.getVarOrDefault("LYRIC_CONFIG_SENDGRIDMAIL_ENDPOINT", "")
  val endpoint = match normalizeEndpoint(if endpointOverride.length > 0 { endpointOverride } else { "https://api.sendgrid.com" }) {
    case Ok(v) -> v
    case Err(e) -> return Err(e)
  }
  return newSendGridSender(apiKey, endpoint)
}

/// Build a SendGrid sender from explicit values (what `connectSendGrid` does
/// after reading the environment).  `pub` without `@stable` so tests can aim a
/// sender at a closed port.
@cfg(feature = "sendgrid")
pub func newSendGridSender(apiKey: in String, endpoint: in String): Result[MailSender, MailError] {
  val normalized = match normalizeEndpoint(endpoint) { case Ok(v) -> v; case Err(e) -> return Err(e) }
  return Ok(SendGridSender(endpoint = normalized, apiKey = apiKey, client = defaultClient()))
}

// ─── Convenience functions ────────────────────────────────────────────────────
/// Top-level wrapper for `sender.send(msg)`.
///
/// Guards every CRLF / NUL-bearing field on `msg` (via `validateNoInjection`)
/// before the kernel path can compose it into MIME headers (CWE-93), and
/// rejects a recipient-less message.  These are structured-`Err` checks, not
/// `requires:` clauses — a precondition assert on client-controlled fields
/// would crash the process (D118).  `sendSimple`/`sendHtml` route through this
/// same guard.  See lyric-lang #396 / #740.
@stable(since = "0.1")
pub func send(sender: in MailSender, msg: in EmailMessage): Result[Unit, MailError] {
  // No `requires: msg.subject.length > 0` / `msg.to.length > 0`: those fields
  // are client-controllable, so a precondition assert crashes the process on
  // an empty subject/recipient list (the same DoS class as the injection
  // clauses removed above).  A message with no recipients is rejected here
  // with a structured Err; an empty subject/body is a valid email.
  if msg.to.length == 0 {
    return Err(MailError(message = "message has no recipients", code = "NO_RECIPIENTS"))
  }
  // Reject an implausible recipient address instead of the underlying
  // MailSender silently skipping it and sending to a partial list (#7254).
  match validateRecipientAddresses(msg) {
    case Some(e) -> return Err(e)
    case None -> ()
  }
  // Reject an oversized total attachment payload before dispatch (#7254).
  if totalAttachmentBytes(msg.attachments) > maxTotalAttachmentBytes.toLong() {
    return Err(
      MailError(message = "total attachment size exceeds maxTotalAttachmentBytes", code = "ATTACHMENTS_TOO_LARGE")
    )
  }
  // Header-injection is enforced here (and again in the MailSender.send
  // implementation) via a structured Err — NOT a `requires:` clause.  Every
  // field of `msg` is client-controllable, so a `requires: not
  // containsHeaderInjection(...)` would elaborate into a runtime precondition
  // assert (D118) that panics the process on a CRLF-bearing subject/address
  // instead of returning `Err` — the same DoS class fixed for the web/auth
  // aspects and lyric-storage.  `validateNoInjection` covers subject, from,
  // to/cc/bcc, replyTo, and attachments in one pass.
  match validateNoInjection(msg) {
    case Some(e) -> return Err(e)
    case None -> ()
  }
  return sender.send(msg)
}

/// Send a plain-text email to a single recipient using Sender config for the
/// From address.
///
/// A CRLF/NUL-bearing `to`/`subject` is rejected at the send boundary with a
/// structured `Err` (not a `requires:` clause, which would crash on client
/// input); an empty subject/body is a valid email.
@stable(since = "0.1")
pub func sendSimple(sender: in MailSender, to: in String, subject: in String, body: in String): Result[Unit, MailError] {
  // No `requires:` on these client-controllable strings — see `Mail.send`.  An
  // empty/CRLF-bearing `to`/`subject` is rejected with a structured Err at the
  // send boundary rather than panicking the process here.
  val toAddr = makeAddress(to)
  val msg = buildMessage([toAddr], subject, body, "")
  return send(sender, msg)
}

/// Send an HTML email (with a plain-text fallback) to a single recipient.
@stable(since = "0.1")
pub func sendHtml(
  sender: in MailSender, to: in String, subject: in String, htmlBody: in String, textBody: in String
): Result[Unit, MailError] {
  // No `requires:` on client-controllable strings — see `Mail.send`.
  val toAddr = makeAddress(to)
  val msg = buildMessage([toAddr], subject, textBody, htmlBody)
  return send(sender, msg)
}

/// Construct an `EmailAddress` from a bare address string (no display name).
@stable(since = "0.1")
pub func makeAddress(address: in String): EmailAddress {
  // Constructing an address with a CRLF payload is harmless; it is rejected
  // when the message is sent (validateNoInjection).  A `requires:` here would
  // panic on client-controlled input instead.
  return EmailAddress(address = address, displayName = "")
}

/// Construct an `EmailAddress` with both an address and a display name.
@stable(since = "0.1")
pub func makeAddressWithName(address: in String, displayName: in String): EmailAddress {
  // See makeAddress: injection is rejected at send time, not via a panicking
  // `requires:` on client-controlled input.
  return EmailAddress(address = address, displayName = displayName)
}

/// Construct an `Attachment` from a filename, MIME content-type, and base64-
/// encoded data.
@stable(since = "0.1")
pub func makeAttachment(filename: in String, contentType: in String, dataBase64: in String): Attachment {
  // No length/injection `requires:` on these client-controllable strings — see
  // makeAddress.  Constructing the record is harmless; a bad filename/
  // contentType is rejected when the message is sent (validateNoInjection).
  return Attachment(filename = filename, contentType = contentType, dataBase64 = dataBase64)
}

// ─── Private helpers ──────────────────────────────────────────────────────────
// Build an EmailMessage using env-var Sender config for the From address.
func buildMessage(
  to: in slice[EmailAddress], subject: in String, textBody: in String, htmlBody: in String
): EmailMessage {
  val fromAddress = Env.getVarOrDefault("LYRIC_CONFIG_SENDER_FROMADDRESS", "")
  val fromDisplayName = Env.getVarOrDefault("LYRIC_CONFIG_SENDER_FROMDISPLAYNAME", "")
  val fromAddr = EmailAddress(address = fromAddress, displayName = fromDisplayName)
  return EmailMessage(
    from = fromAddr,
    to = to,
    cc = [],
    bcc = [],
    subject = subject,
    textBody = textBody,
    htmlBody = htmlBody,
    attachments = [],
    replyTo = None
  )
}

// Return true if `s` contains characters that could inject MIME headers.
// Rejects carriage return, line feed, and NUL.
func containsHeaderInjection(s: in String): Bool {
  var i = 0
  while i < s.length {
    val ch = charAtOrReplacement(s, i)
    if ch == '\r' or ch == '\n' or ch == '\u{0000}' {
      return true
    }
    i = i + 1
  }
  return false
}

/// Full CRLF/NUL header-injection guard over every field of an `EmailMessage`
/// (CWE-93).  Returns `Some(MailError)` for the first offending field, `None`
/// when the message is clean.
///
/// `pub` so that any out-of-tree `MailSender` implementation can enforce the
/// same guarantee the in-tree `NativeSender` does — the `MailSender.send`
/// contract requires every implementation to call this before dispatch, so the
/// injection guard holds regardless of whether a caller went through the
/// `Mail.send` wrapper or invoked an implementation's `send` directly (#3181 /
/// #5499).  Kept a free function returning `Option[MailError]` (not an
/// interface `requires:`) because a precondition assert on client-controlled
/// message fields would crash the process instead of returning `Err` (D118).
@stable(since = "0.1")
pub func validateNoInjection(msg: in EmailMessage): Option[MailError] {
  if containsHeaderInjection(msg.subject) {
    return Some(
      value = MailError(
        message = "subject contains CR/LF/NUL — header injection rejected",
        code = "HEADER_INJECTION"
      )
    )
  }
  if containsHeaderInjection(msg.from.address) or containsHeaderInjection(msg.from.displayName) {
    return Some(
      value = MailError(message = "from contains CR/LF/NUL — header injection rejected", code = "HEADER_INJECTION")
    )
  }
  var i = 0
  while i < msg.to.length {
    if containsHeaderInjection(msg.to[i].address) or containsHeaderInjection(msg.to[i].displayName) {
      return Some(
        value = MailError(
          message = "to[" + ("" + i) + "] contains CR/LF/NUL — header injection rejected",
          code = "HEADER_INJECTION"
        )
      )
    }
    i = i + 1
  }
  var ci = 0
  while ci < msg.cc.length {
    if containsHeaderInjection(msg.cc[ci].address) or containsHeaderInjection(msg.cc[ci].displayName) {
      return Some(
        value = MailError(
          message = "cc[" + ("" + ci) + "] contains CR/LF/NUL — header injection rejected",
          code = "HEADER_INJECTION"
        )
      )
    }
    ci = ci + 1
  }
  var bi = 0
  while bi < msg.bcc.length {
    if containsHeaderInjection(msg.bcc[bi].address) or containsHeaderInjection(msg.bcc[bi].displayName) {
      return Some(
        value = MailError(
          message = "bcc[" + ("" + bi) + "] contains CR/LF/NUL — header injection rejected",
          code = "HEADER_INJECTION"
        )
      )
    }
    bi = bi + 1
  }
  match msg.replyTo {
    case None -> ()
    case Some(addr) -> if containsHeaderInjection(addr.address) or containsHeaderInjection(addr.displayName) {
      return Some(
        value = MailError(
          message = "replyTo contains CR/LF/NUL — header injection rejected",
          code = "HEADER_INJECTION"
        )
      )
    }
  }
  var ai = 0
  while ai < msg.attachments.length {
    if containsHeaderInjection(msg.attachments[ai].filename) or containsHeaderInjection(msg.attachments[ai].contentType) {
      return Some(
        value = MailError(
          message = "attachments[" + ("" + ai) +
            "] filename/contentType contains CR/LF/NUL — header injection rejected",
          code = "HEADER_INJECTION"
        )
      )
    }
    ai = ai + 1
  }
  None
}
