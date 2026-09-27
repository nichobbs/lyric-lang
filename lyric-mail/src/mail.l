//! Mail — email sending library for Lyric.
//! Stability: @experimental — the API compiles and unit tests cover the typed
//! envelope, but the SMTP, Amazon SES, and SendGrid backends have not been
//! driven against a live provider in CI.
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
package Mail

import Std.Core
import Std.Char
import Std.Collections
import Std.Format
import Std.String
import Std.Parse
import Std.Environment as Env
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
pub record MailSenderStub {
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
  if s.length >= 1 and s[s.length - 1] == '=' {
    padding = 1i64
  }
  if s.length >= 2 and s[s.length - 2] == '=' {
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
    if s[i] == '@' {
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
    val ch = s[i]
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
        MailKernel.attachmentCollectionAdd(attColl, bclAtt)
        ai = ai + 1
      }
      self.client.Send(mailMsg)
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
// hands back. Genuinely wired into `connectSmtp` (#7254) — `send`/`close`
// really do call into `Mail.Kernel.Jvm` — but that kernel has no real Jakarta
// Mail binding yet (see its module header), so every `connectSmtp()` call on
// this target currently returns `Err(code = "NOT_IMPLEMENTED")` before a
// `NativeSenderJvm` is ever constructed.
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
    val ch = s[i]
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
      buf = buf + ch.toString()
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
    case Err(msg) -> Err(MailError(message = msg, code = "NOT_IMPLEMENTED"))
  }
}

// Read a required (non-empty) env var config field, or an Err naming which
// one was missing. Shared by connectSes/connectSendGrid so the same
// precondition holds identically on every target (#7254) — neither provider
// is implemented on any target yet, but a caller that mistypes/omits a
// required credential should see that named, not a generic
// "not implemented".
func requireEnvVar(envVar: in String, fieldDescription: in String): Result[String, MailError] {
  val v = Env.getVarOrDefault(envVar, "")
  if v.length == 0 {
    return Err(MailError(message = fieldDescription + " is required (set " + envVar + ")", code = "INVALID_CONFIG"))
  }
  return Ok(v)
}

/// Open an Amazon SES client.
/// Requires the `ses` feature to be active (`[features] ses = []`).
/// Config is read from LYRIC_CONFIG_SES_* env vars (region, accessKey,
/// secretKey) — `region` must be non-empty, enforced identically on every
/// target (#7254). Not yet implemented on any target: always returns
/// `Err(code = "NOT_IMPLEMENTED")` once config validation passes (#7462).
@stable(since = "0.1")
@cfg(feature = "ses")
pub func connectSes(): Result[MailSender, MailError] {
  val region = match requireEnvVar("LYRIC_CONFIG_SES_REGION", "SES region") {
    case Ok(v) -> v
    case Err(e) -> return Err(e)
  }
  Err(MailError(message = "Amazon SES not yet implemented (#7462)", code = "NOT_IMPLEMENTED"))
}

/// Open a SendGrid client.
/// Requires the `sendgrid` feature to be active (`[features] sendgrid = []`).
/// Config is read from LYRIC_CONFIG_SENDGRIDMAIL_APIKEY env var — `apiKey`
/// must be non-empty, enforced identically on every target (#7254). Not yet
/// implemented on any target: always returns `Err(code = "NOT_IMPLEMENTED")`
/// once config validation passes (#7462).
@stable(since = "0.1")
@cfg(feature = "sendgrid")
pub func connectSendGrid(): Result[MailSender, MailError] {
  val apiKey = match requireEnvVar("LYRIC_CONFIG_SENDGRIDMAIL_APIKEY", "SendGrid apiKey") {
    case Ok(v) -> v
    case Err(e) -> return Err(e)
  }
  Err(MailError(message = "SendGrid not yet implemented (#7462)", code = "NOT_IMPLEMENTED"))
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
    val ch = s[i]
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
