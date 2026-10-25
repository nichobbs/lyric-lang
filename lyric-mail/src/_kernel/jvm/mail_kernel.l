//! Mail.Kernel.Jvm — JVM extern boundary for the SMTP provider.
//!
//! JVM counterpart of `Mail.Kernel.Net`, over Jakarta Mail
//! (`jakarta.mail:jakarta.mail-api` plus the Eclipse Angus implementation,
//! both declared in this library's `[maven]` table) through `extern type`
//! auto-FFI: `Session`, `Transport`, `MimeMessage`, `InternetAddress`,
//! `MimeMultipart` and `MimeBodyPart` are resolved against the real JARs at
//! compile time.  An earlier revision declared `extern package` blocks, which
//! parse but bind nothing, and then reported every call as not implemented.
//!
//! The wire between `Mail.NativeSenderJvm` and this kernel is the JSON
//! document `Mail.messageToJson` builds (address/displayName pairs, subject,
//! text and HTML bodies, base64 attachments), parsed here with
//! `Std.JsonValue`.  The handle returned by `connectSmtp` names the
//! connection settings only: each `send` opens a transport, delivers and
//! closes it, so a handle never holds a socket that an idle timeout can kill.
//!
//! Message shape matches `Mail.Kernel.Net`'s: the HTML body when there is one,
//! otherwise the text body, as a single part; with attachments the body part
//! and one part per attachment are wrapped in `multipart/mixed`.  Attachment
//! parts are built from the caller's base64 text as it stands (re-wrapped at
//! 76 columns, the MIME line limit) rather than decoded and re-encoded.  Bcc
//! recipients are envelope recipients only; Angus strips the `Bcc` header
//! when it writes the message.
//!
//! Only active when compiled with feature = "jvm".
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.
@cfg(feature = "jvm")
@io
package Mail.Kernel.Jvm

import Std.Core
import Std.Collections
import Std.JsonValue as Jv

extern type JProperties = "java.util.Properties"

extern type JConcurrentHashMap = "java.util.concurrent.ConcurrentHashMap"

extern type JAtomicInteger = "java.util.concurrent.atomic.AtomicInteger"

extern type JSession = "jakarta.mail.Session"

extern type JTransport = "jakarta.mail.Transport"

extern type JMimeMessage = "jakarta.mail.internet.MimeMessage"

extern type JInternetAddress = "jakarta.mail.internet.InternetAddress"

extern type JRecipientType = "jakarta.mail.Message$RecipientType"

extern type JMimeMultipart = "jakarta.mail.internet.MimeMultipart"

extern type JMimeBodyPart = "jakarta.mail.internet.MimeBodyPart"

extern type JInternetHeaders = "jakarta.mail.internet.InternetHeaders"

/// The settings one `connectSmtp` handle stands for.  `Session` is thread
/// safe and cheap, so it is built once here; transports are per send.
ref record SmtpConn {
  session: JSession
  host: String
  port: Int
  username: String
  password: String
}

val handleCounter: JAtomicInteger = JAtomicInteger.new(0)

// Keyed by `handle.toString()`.  A raw `ConcurrentHashMap`, read back through
// `containsKey` + `get`, as `Jobs.Kernel.Jvm` does.
val connRegistry: JConcurrentHashMap = JConcurrentHashMap.new()

func setProp(props: in JProperties, key: in String, value: in String): Unit {
  val _ = props.setProperty(key, value)
}

/// Record the connection settings for an SMTP server and return a handle.
/// Nothing is dialled here, matching `Mail.Kernel.Net`: an unreachable server
/// surfaces as a `SEND_ERROR` from the first `send`.  `useTls` requires
/// STARTTLS and certificate-host verification; `timeoutMs` bounds the connect,
/// read and write phases.
@axiom("jakarta.mail.Session settings conform to the Jakarta Mail SMTP provider contract")
@cfg(feature = "smtp")
pub func connectSmtp(
  host: in String,
  port: in Int,
  username: in String,
  password: in String,
  useTls: in Bool,
  timeoutMs: in Int,
): Result[Int, String] {
  try {
    val props = JProperties.new()
    setProp(props, "mail.transport.protocol", "smtp")
    setProp(props, "mail.smtp.host", host)
    setProp(props, "mail.smtp.port", port.toString())
    setProp(props, "mail.smtp.connectiontimeout", timeoutMs.toString())
    setProp(props, "mail.smtp.timeout", timeoutMs.toString())
    setProp(props, "mail.smtp.writetimeout", timeoutMs.toString())
    if username.length > 0 {
      setProp(props, "mail.smtp.auth", "true")
    }
    if useTls {
      setProp(props, "mail.smtp.starttls.enable", "true")
      setProp(props, "mail.smtp.starttls.required", "true")
      setProp(props, "mail.smtp.ssl.checkserveridentity", "true")
    }
    val session = JSession.getInstance(props)
    val handle = handleCounter.incrementAndGet()
    val conn = SmtpConn(session = session, host = host, port = port, username = username, password = password)
    val _ = connRegistry.put(handle.toString(), conn)
    Ok(handle)
  } catch Bug as b {
    Err("lyric-mail: could not configure the SMTP session: " + b.message)
  }
}

func strField(obj: in Jv.JsonValue, key: in String, fallback: in String): String {
  match Jv.getString(obj, key) {
    case Some(v) -> v
    case None -> fallback
  }
}

func arrField(obj: in Jv.JsonValue, key: in String): List[Jv.JsonValue] {
  match Jv.getArray(obj, key) {
    case Some(v) -> v
    case None -> newList()
  }
}

func fieldOrNull(obj: in Jv.JsonValue, key: in String): Jv.JsonValue {
  match Jv.getField(obj, key) {
    case Some(v) -> v
    case None -> Jv.JNull
  }
}

func addressOf(obj: in Jv.JsonValue): JInternetAddress {
  val address = strField(obj, "address", "")
  val name = strField(obj, "displayName", "")
  if name.length == 0 {
    JInternetAddress.new(address)
  } else {
    JInternetAddress.new(address, name, "UTF-8")
  }
}

func addRecipients(msg: in JMimeMessage, kind: in JRecipientType, root: in Jv.JsonValue, key: in String): Unit {
  val items = arrField(root, key)
  for item in items {
    msg.addRecipient(kind, addressOf(item))
  }
}

func wrapBase64(b64: in String): String {
  var wrapped = ""
  var i = 0
  while i < b64.length {
    val n = if b64.length - i < 76 { b64.length - i } else { 76 }
    wrapped = wrapped + b64.substring(i, n) + "\r\n"
    i = i + n
  }
  wrapped
}

func attachmentPart(att: in Jv.JsonValue): JMimeBodyPart {
  val headers = JInternetHeaders.new()
  headers.addHeader("Content-Type", strField(att, "contentType", "application/octet-stream"))
  headers.addHeader("Content-Transfer-Encoding", "base64")
  val encoded = wrapBase64(strField(att, "dataBase64", ""))
  val part = JMimeBodyPart.new(headers, encoded.getBytes("US-ASCII"))
  part.setFileName(strField(att, "filename", "attachment"))
  part
}

func bodyPart(subtype: in String, text: in String): JMimeBodyPart {
  val part = JMimeBodyPart.new()
  part.setText(text, "UTF-8", subtype)
  part
}

func fillBody(msg: in JMimeMessage, root: in Jv.JsonValue): Unit {
  val html = strField(root, "htmlBody", "")
  val text = strField(root, "textBody", "")
  val subtype = if html.length > 0 { "html" } else { "plain" }
  val body = if html.length > 0 { html } else { text }
  val attachments = arrField(root, "attachments")
  if attachments.count == 0 {
    msg.setText(body, "UTF-8", subtype)
  } else {
    val multipart = JMimeMultipart.new()
    multipart.addBodyPart(bodyPart(subtype, body))
    for att in attachments {
      multipart.addBodyPart(attachmentPart(att))
    }
    msg.setContent(multipart)
  }
}

func buildMessage(session: in JSession, root: in Jv.JsonValue): JMimeMessage {
  val msg = JMimeMessage.new(session)
  msg.setFrom(addressOf(fieldOrNull(root, "from")))
  msg.setSubject(strField(root, "subject", ""), "UTF-8")
  addRecipients(msg, JRecipientType.TO, root, "to")
  addRecipients(msg, JRecipientType.CC, root, "cc")
  addRecipients(msg, JRecipientType.BCC, root, "bcc")
  match Jv.getField(root, "replyTo") {
    case Some(rt) -> if not Jv.isNull(rt) { msg.setHeader("Reply-To", addressOf(rt).toString()) }
    case None -> ()
  }
  fillBody(msg, root)
  msg.saveChanges()
  msg
}

func closeQuietly(transport: in JTransport): Unit {
  try {
    transport.close()
  } catch Bug as _ {
    ()
  }
}

func deliver(conn: in SmtpConn, msg: in JMimeMessage): Result[Unit, String] {
  val transport = conn.session.getTransport("smtp")
  try {
    if conn.username.length > 0 {
      transport.connect(conn.host, conn.port, conn.username, conn.password)
    } else {
      transport.connect()
    }
    transport.sendMessage(msg, msg.getAllRecipients())
    transport.close()
    Ok(())
  } catch Bug as b {
    closeQuietly(transport)
    Err(b.message)
  }
}

/// Deliver one JSON-encoded message (`Mail.messageToJson`) through the
/// connection `senderHandle` names.
@axiom("jakarta.mail.Transport.sendMessage conforms to the Jakarta Mail SMTP provider contract")
@cfg(feature = "smtp")
pub func send(senderHandle: in Int, messageJson: in String): Result[Unit, String] {
  if not connRegistry.containsKey(senderHandle.toString()) {
    return Err("lyric-mail: unknown or closed SMTP handle " + senderHandle.toString())
  }
  val conn: SmtpConn = connRegistry.get(senderHandle.toString()) ?? panic("lyric-mail: SMTP handle vanished")
  match Jv.parseValue(messageJson) {
    case Err(e) -> Err("lyric-mail: malformed message document: " + Jv.JsonParseError.message(e))
    case Ok(root) -> {
      try {
        deliver(conn, buildMessage(conn.session, root))
      } catch Bug as b {
        Err(b.message)
      }
    }
  }
}

/// Forget the connection settings behind `senderHandle`.  Idempotent.
@axiom("ConcurrentHashMap.remove conforms to its documented JVM contract")
@cfg(feature = "smtp")
pub func close(senderHandle: in Int): Unit {
  val _ = connRegistry.remove(senderHandle.toString());
  ()
}
