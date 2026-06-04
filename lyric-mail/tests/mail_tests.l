//! tests/mail_tests.l — test suite for the Mail package (pure Lyric surface).
//! Covers: makeAddress, makeAddressWithName, makeAttachment, EmailAddress,
//! Attachment, MailError, and EmailMessage construction.
//! Factory functions that require kernel connections (connectSmtp, etc.) are
//! not exercised here; the pure-Lyric construction helpers are the focus.
@test_module
package Mail.MailTests

import Std.Core
import Std.Testing
import Mail

// ─── makeAddress ──────────────────────────────────────────────────────────────
test "makeAddress returns EmailAddress with the correct address" {
  val addr = Mail.makeAddress("alice@example.com")
  assertEqual(addr.address, "alice@example.com", "address field")
}

test "makeAddress returns EmailAddress with an empty displayName" {
  val addr = Mail.makeAddress("alice@example.com")
  assertEqual(addr.displayName, "", "displayName is empty for bare address")
}

test "makeAddress with a subdomain address" {
  val addr = Mail.makeAddress("bot@mail.example.co.uk")
  assertEqual(addr.address, "bot@mail.example.co.uk", "subdomain address")
  assertEqual(addr.displayName, "", "displayName is empty")
}

test "makeAddress with a unicode-safe email (no injection chars)" {
  val addr = Mail.makeAddress("user+tag@example.com")
  assertEqual(addr.address, "user+tag@example.com", "plus-tag address")
}

// ─── makeAddressWithName ──────────────────────────────────────────────────────
test "makeAddressWithName returns EmailAddress with correct address" {
  val addr = Mail.makeAddressWithName("bob@example.com", "Bob Smith")
  assertEqual(addr.address, "bob@example.com", "address field")
}

test "makeAddressWithName returns EmailAddress with correct displayName" {
  val addr = Mail.makeAddressWithName("bob@example.com", "Bob Smith")
  assertEqual(addr.displayName, "Bob Smith", "displayName field")
}

test "makeAddressWithName with empty displayName is valid" {
  val addr = Mail.makeAddressWithName("anon@example.com", "")
  assertEqual(addr.address, "anon@example.com", "address")
  assertEqual(addr.displayName, "", "empty displayName")
}

test "makeAddressWithName: both fields are independent" {
  val addr1 = Mail.makeAddressWithName("alice@example.com", "Alice")
  val addr2 = Mail.makeAddressWithName("bob@example.com", "Bob")
  assertEqual(addr1.address, "alice@example.com", "addr1 address")
  assertEqual(addr1.displayName, "Alice", "addr1 displayName")
  assertEqual(addr2.address, "bob@example.com", "addr2 address")
  assertEqual(addr2.displayName, "Bob", "addr2 displayName")
}

// ─── makeAttachment ────────────────────────────────────────────────────────────
test "makeAttachment returns Attachment with the correct filename" {
  val att = Mail.makeAttachment("report.pdf", "application/pdf", "SGVsbG8=")
  assertEqual(att.filename, "report.pdf", "filename field")
}

test "makeAttachment returns Attachment with the correct contentType" {
  val att = Mail.makeAttachment("report.pdf", "application/pdf", "SGVsbG8=")
  assertEqual(att.contentType, "application/pdf", "contentType field")
}

test "makeAttachment returns Attachment with the correct dataBase64" {
  val att = Mail.makeAttachment("report.pdf", "application/pdf", "SGVsbG8=")
  assertEqual(att.dataBase64, "SGVsbG8=", "dataBase64 field")
}

test "makeAttachment with empty base64 data is valid" {
  val att = Mail.makeAttachment("empty.txt", "text/plain", "")
  assertEqual(att.filename, "empty.txt", "filename")
  assertEqual(att.contentType, "text/plain", "contentType")
  assertEqual(att.dataBase64, "", "empty dataBase64")
}

test "makeAttachment with a PNG MIME type" {
  val att = Mail.makeAttachment("logo.png", "image/png", "iVBORw0KGgo=")
  assertEqual(att.filename, "logo.png", "png filename")
  assertEqual(att.contentType, "image/png", "png contentType")
  assertEqual(att.dataBase64, "iVBORw0KGgo=", "png dataBase64")
}

// ─── EmailAddress direct construction ────────────────────────────────────────
test "EmailAddress record constructed directly has correct fields" {
  val addr = EmailAddress(address = "carol@example.com", displayName = "Carol")
  assertEqual(addr.address, "carol@example.com", "direct address")
  assertEqual(addr.displayName, "Carol", "direct displayName")
}

// ─── MailError construction ───────────────────────────────────────────────────
test "MailError record has correct message field" {
  val err = MailError(message = "auth failed", code = "AUTH_FAILED")
  assertEqual(err.message, "auth failed", "error message")
}

test "MailError record has correct code field" {
  val err = MailError(message = "quota exceeded", code = "QUOTA_EXCEEDED")
  assertEqual(err.code, "QUOTA_EXCEEDED", "error code")
}

test "MailError with empty code is valid" {
  val err = MailError(message = "unknown error", code = "")
  assertEqual(err.message, "unknown error", "message")
  assertEqual(err.code, "", "empty code")
}

// ─── EmailMessage construction ────────────────────────────────────────────────
test "EmailMessage can be constructed with all required fields" {
  val from = EmailAddress(address = "sender@example.com", displayName = "Sender")
  val to = [EmailAddress(address = "recv@example.com", displayName = "Recv")]
  val msg = EmailMessage(
    from = from,
    to = to,
    cc = [],
    bcc = [],
    subject = "Hello",
    textBody = "Hello world",
    htmlBody = "<p>Hello world</p>",
    attachments = [],
    replyTo = None
  )
  assertEqual(msg.subject, "Hello", "subject")
  assertEqual(msg.textBody, "Hello world", "textBody")
  assertEqual(msg.htmlBody, "<p>Hello world</p>", "htmlBody")
}

test "EmailMessage from field is preserved" {
  val from = EmailAddress(address = "noreply@example.com", displayName = "No Reply")
  val msg = EmailMessage(
    from = from,
    to = [EmailAddress(address = "u@example.com", displayName = "")],
    cc = [],
    bcc = [],
    subject = "Test",
    textBody = "body",
    htmlBody = "",
    attachments = [],
    replyTo = None
  )
  assertEqual(msg.from.address, "noreply@example.com", "from address")
  assertEqual(msg.from.displayName, "No Reply", "from displayName")
}

test "EmailMessage with replyTo Some preserves the address" {
  val from = EmailAddress(address = "a@example.com", displayName = "")
  val replyTo = EmailAddress(address = "reply@example.com", displayName = "Support")
  val msg = EmailMessage(
    from = from,
    to = [EmailAddress(address = "b@example.com", displayName = "")],
    cc = [],
    bcc = [],
    subject = "Re: ticket",
    textBody = "see above",
    htmlBody = "",
    attachments = [],
    replyTo = Some(replyTo)
  )
  match msg.replyTo {
    case Some(addr) -> assertEqual(addr.address, "reply@example.com", "replyTo address")
    case None -> assertTrue(false, "expected Some replyTo")
  }
}

test "EmailMessage to list length is preserved" {
  val from = EmailAddress(address = "s@example.com", displayName = "")
  val to = [
    EmailAddress(address = "a@example.com", displayName = "A"),
    EmailAddress(address = "b@example.com", displayName = "B")
  ]
  val msg = EmailMessage(
    from = from,
    to = to,
    cc = [],
    bcc = [],
    subject = "Multi",
    textBody = "hi",
    htmlBody = "",
    attachments = [],
    replyTo = None
  )
  assertEqualInt(msg.to.length, 2, "to list length")
}
