//! tests/mail_tests.l — test suite for the Mail package (pure Lyric surface).
//! Covers: makeAddress, makeAddressWithName, makeAttachment, EmailAddress,
//! Attachment, MailError, and EmailMessage construction; recipient-address
//! validation, the attachment-size cap, and SES/SendGrid config
//! preconditions added in #7254; the exact-cap-boundary and multi-attachment
//! sum-overflow cases, the tightened `isPlausibleAddress` shape check, and
//! (on `--target jvm`) `messageToJson` escaping/`displayName` carry-through
//! added in #7476.
//! Factory functions that require kernel connections (connectSmtp, etc.) are
//! not exercised here; the pure-Lyric construction helpers are the focus.
@test_module
package Mail.MailTests

import Std.Core
import Std.Environment
import Std.Testing
import Std.String
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

test "makeAttachment with non-empty base64 data is valid" {
  val att = Mail.makeAttachment("data.bin", "application/octet-stream", "AQID")
  assertEqual(att.filename, "data.bin", "filename")
  assertEqual(att.contentType, "application/octet-stream", "contentType")
  assertEqual(att.dataBase64, "AQID", "dataBase64 preserved")
}

// Zero-byte attachments are legal: Convert.FromBase64String("") yields
// byte[0], a valid (if empty) attachment payload (#3173).
test "makeAttachment accepts empty base64 (zero-byte attachment)" {
  val att = Mail.makeAttachment("empty.bin", "application/octet-stream", "")
  assertEqual(att.dataBase64, "", "empty dataBase64 preserved")
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

// ─── Attachment fields in EmailMessage ───────────────────────────────────────
test "EmailMessage with multiple attachments preserves attachment count" {
  val att1 = Mail.makeAttachment("a.txt", "text/plain", "SGVsbG8=")
  val att2 = Mail.makeAttachment("b.png", "image/png", "iVBORw0KGgo=")
  val msg = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = ""),
    to = [EmailAddress(address = "r@example.com", displayName = "")],
    cc = [],
    bcc = [],
    subject = "Files",
    textBody = "two files",
    htmlBody = "",
    attachments = [att1, att2],
    replyTo = None
  )
  assertEqualInt(msg.attachments.length, 2, "two attachments in message")
  assertEqual(msg.attachments[0].filename, "a.txt", "first attachment filename")
  assertEqual(msg.attachments[1].filename, "b.png", "second attachment filename")
  assertEqual(msg.attachments[0].contentType, "text/plain", "first attachment contentType")
  assertEqual(msg.attachments[1].dataBase64, "iVBORw0KGgo=", "second attachment dataBase64")
}

test "EmailMessage attachment fields are independent from other messages" {
  val attA = Mail.makeAttachment("a.pdf", "application/pdf", "AAAA")
  val attB = Mail.makeAttachment("b.pdf", "application/pdf", "BBBB")
  val msgA = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = ""),
    to = [EmailAddress(address = "r@example.com", displayName = "")],
    cc = [],
    bcc = [],
    subject = "A",
    textBody = "",
    htmlBody = "",
    attachments = [attA],
    replyTo = None
  )
  val msgB = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = ""),
    to = [EmailAddress(address = "r@example.com", displayName = "")],
    cc = [],
    bcc = [],
    subject = "B",
    textBody = "",
    htmlBody = "",
    attachments = [attB],
    replyTo = None
  )
  assertEqual(msgA.attachments[0].dataBase64, "AAAA", "msgA attachment data")
  assertEqual(msgB.attachments[0].dataBase64, "BBBB", "msgB attachment data")
}

// ─── containsHeaderInjection via Mail.send ───────────────────────────────────
// Mail.MailSenderStub records call counts and always returns Ok.
// The header-injection guard in Mail.send fires before sender.send is reached,
// so no live SMTP connection is needed.
// Verify that Mail.send rejects an attachment with an injected filename before
// delegating to the sender — the guard in the public wrapper fires first.
test "Mail.send rejects an attachment whose filename contains a CR character" {
  var sender = Mail.MailSenderStub(callCount = 0)
  val attBad = Attachment(filename = "report\r.pdf", contentType = "application/pdf", dataBase64 = "SGVsbG8=")
  val msg = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = ""),
    to = [EmailAddress(address = "r@example.com", displayName = "")],
    cc = [],
    bcc = [],
    subject = "Injected",
    textBody = "body",
    htmlBody = "",
    attachments = [attBad],
    replyTo = None
  )
  val result = Mail.send(sender, msg)
  match result {
    case Err(e) -> {
      assertEqual(e.code, "HEADER_INJECTION", "error code is HEADER_INJECTION")
      assertEqualInt(sender.callCount, 0, "sender.send never called — guard fires first")
    }
    case Ok(_) -> assertTrue(false, "expected Err but got Ok")
  }
}

test "Mail.send rejects an attachment whose filename contains an LF character" {
  var sender = Mail.MailSenderStub(callCount = 0)
  val attBad = Attachment(filename = "report\n.pdf", contentType = "application/pdf", dataBase64 = "SGVsbG8=")
  val msg = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = ""),
    to = [EmailAddress(address = "r@example.com", displayName = "")],
    cc = [],
    bcc = [],
    subject = "Injected",
    textBody = "body",
    htmlBody = "",
    attachments = [attBad],
    replyTo = None
  )
  match Mail.send(sender, msg) {
    case Err(e) -> {
      assertEqual(e.code, "HEADER_INJECTION", "LF filename: error code is HEADER_INJECTION")
      assertEqualInt(sender.callCount, 0, "LF filename: sender.send never called")
    }
    case Ok(_) -> assertTrue(false, "LF filename: expected Err but got Ok")
  }
}

test "Mail.send rejects an attachment whose contentType contains a CR character" {
  var sender = Mail.MailSenderStub(callCount = 0)
  val attBad = Attachment(filename = "report.pdf", contentType = "application/pdf\rX-Evil: 1", dataBase64 = "SGVsbG8=")
  val msg = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = ""),
    to = [EmailAddress(address = "r@example.com", displayName = "")],
    cc = [],
    bcc = [],
    subject = "Injected",
    textBody = "body",
    htmlBody = "",
    attachments = [attBad],
    replyTo = None
  )
  match Mail.send(sender, msg) {
    case Err(e) -> {
      assertEqual(e.code, "HEADER_INJECTION", "contentType: error code is HEADER_INJECTION")
      assertEqualInt(sender.callCount, 0, "contentType: sender.send never called")
    }
    case Ok(_) -> assertTrue(false, "contentType injection: expected Err but got Ok")
  }
}

test "Mail.send rejects an attachment whose contentType contains a LF character" {
  var sender = Mail.MailSenderStub(callCount = 0)
  val attBad = Attachment(filename = "report.pdf", contentType = "application/pdf\nX-Evil: 1", dataBase64 = "SGVsbG8=")
  val msg = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = ""),
    to = [EmailAddress(address = "r@example.com", displayName = "")],
    cc = [],
    bcc = [],
    subject = "Injected",
    textBody = "body",
    htmlBody = "",
    attachments = [attBad],
    replyTo = None
  )
  match Mail.send(sender, msg) {
    case Err(e) -> {
      assertEqual(e.code, "HEADER_INJECTION", "contentType LF: error code is HEADER_INJECTION")
      assertEqualInt(sender.callCount, 0, "contentType LF: sender.send never called")
    }
    case Ok(_) -> assertTrue(false, "contentType injection: expected Err but got Ok")
  }
}

// Control case: a clean-filename attachment passes all guards without Err.
test "Mail.send accepts an attachment with a clean filename" {
  var sender = Mail.MailSenderStub(callCount = 0)
  val attGood = Attachment(filename = "report.pdf", contentType = "application/pdf", dataBase64 = "SGVsbG8=")
  val msg = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = ""),
    to = [EmailAddress(address = "r@example.com", displayName = "")],
    cc = [],
    bcc = [],
    subject = "Clean",
    textBody = "body",
    htmlBody = "",
    attachments = [attGood],
    replyTo = None
  )
  val result = Mail.send(sender, msg)
  match result {
    case Ok(_) -> assertTrue(true, "clean attachment passes header-injection guard")
    case Err(e) -> assertTrue(false, "expected Ok but got Err: " + e.message)
  }
}

// Subject and From were previously guarded by `requires:` clauses, so a
// CRLF-bearing subject/address panicked the process instead of returning Err.
// These tests pin the fail-closed-with-Err behaviour on those fields.
test "Mail.send rejects a subject containing a CR/LF (no panic, returns Err)" {
  var sender = Mail.MailSenderStub(callCount = 0)
  val msg = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = ""),
    to = [EmailAddress(address = "r@example.com", displayName = "")],
    cc = [],
    bcc = [],
    subject = "Hello\r\nBcc: victim@evil.com",
    textBody = "body",
    htmlBody = "",
    attachments = [],
    replyTo = None
  )
  match Mail.send(sender, msg) {
    case Err(e) -> {
      assertEqual(e.code, "HEADER_INJECTION", "injected subject: code is HEADER_INJECTION")
      assertEqualInt(sender.callCount, 0, "injected subject: sender.send never called")
    }
    case Ok(_) -> assertTrue(false, "injected subject: expected Err but got Ok")
  }
}

test "Mail.send rejects a From address containing a CR/LF (no panic, returns Err)" {
  var sender = Mail.MailSenderStub(callCount = 0)
  val msg = EmailMessage(
    from = EmailAddress(address = "s@example.com\r\nX-Evil: 1", displayName = ""),
    to = [EmailAddress(address = "r@example.com", displayName = "")],
    cc = [],
    bcc = [],
    subject = "Clean",
    textBody = "body",
    htmlBody = "",
    attachments = [],
    replyTo = None
  )
  match Mail.send(sender, msg) {
    case Err(e) -> {
      assertEqual(e.code, "HEADER_INJECTION", "injected from: code is HEADER_INJECTION")
      assertEqualInt(sender.callCount, 0, "injected from: sender.send never called")
    }
    case Ok(_) -> assertTrue(false, "injected from: expected Err but got Ok")
  }
}

// Length preconditions were removed from the public API because a `requires:`
// on client-controllable fields crashes the process (D118).  Emptiness is now
// handled gracefully: no recipients -> Err; an empty subject is a valid email.
test "Mail.send with no recipients returns Err (no panic)" {
  var sender = Mail.MailSenderStub(callCount = 0)
  val msg = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = ""),
    to = [],
    cc = [],
    bcc = [],
    subject = "Subject",
    textBody = "body",
    htmlBody = "",
    attachments = [],
    replyTo = None
  )
  match Mail.send(sender, msg) {
    case Err(e) -> {
      assertEqual(e.code, "NO_RECIPIENTS", "empty recipients: code is NO_RECIPIENTS")
      assertEqualInt(sender.callCount, 0, "empty recipients: sender.send never called")
    }
    case Ok(_) -> assertTrue(false, "empty recipients: expected Err but got Ok")
  }
}

test "Mail.send with an empty subject succeeds (empty subject is valid)" {
  var sender = Mail.MailSenderStub(callCount = 0)
  val msg = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = ""),
    to = [EmailAddress(address = "r@example.com", displayName = "")],
    cc = [],
    bcc = [],
    subject = "",
    textBody = "body",
    htmlBody = "",
    attachments = [],
    replyTo = None
  )
  match Mail.send(sender, msg) {
    case Ok(_) -> assertEqualInt(sender.callCount, 1, "empty subject: sender.send called once")
    case Err(e) -> assertTrue(false, "empty subject should be valid, got Err: " + e.message)
  }
}

// ─── Mail.validateNoInjection is pub and reusable by out-of-tree senders (#5499) ─
// The header-injection guard is exported so any MailSender implementation can
// enforce the interface's safety contract directly, not only through the
// Mail.send wrapper. These tests call it as an external implementer would.
test "Mail.validateNoInjection flags a CRLF-injected subject with Some(HEADER_INJECTION)" {
  val msg = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = ""),
    to = [EmailAddress(address = "r@example.com", displayName = "")],
    cc = [],
    bcc = [],
    subject = "Hi\r\nBcc: victim@example.com",
    textBody = "body",
    htmlBody = "",
    attachments = [],
    replyTo = None
  )
  match Mail.validateNoInjection(msg) {
    case Some(e) -> assertEqual(e.code, "HEADER_INJECTION", "injected subject is flagged")
    case None -> assertTrue(false, "an injected subject must be flagged by validateNoInjection")
  }
}

test "Mail.validateNoInjection returns None for a clean message" {
  val msg = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = "Sender"),
    to = [EmailAddress(address = "r@example.com", displayName = "Recv")],
    cc = [],
    bcc = [],
    subject = "Quarterly report",
    textBody = "See attached.",
    htmlBody = "<p>See attached.</p>",
    attachments = [],
    replyTo = None
  )
  match Mail.validateNoInjection(msg) {
    case Some(e) -> assertTrue(false, "a clean message must not be flagged: " + e.message)
    case None -> assertTrue(true, "clean message passes")
  }
}

// ─── Recipient address validation (#7254) ────────────────────────────────────
// An empty or "@"-less recipient address must be rejected with a structured
// Err, not silently skipped and sent to a partial recipient list.
test "Mail.send rejects a `to` recipient with an empty address" {
  var sender = Mail.MailSenderStub(callCount = 0)
  val msg = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = ""),
    to = [EmailAddress(address = "", displayName = "")],
    cc = [],
    bcc = [],
    subject = "Subject",
    textBody = "body",
    htmlBody = "",
    attachments = [],
    replyTo = None
  )
  match Mail.send(sender, msg) {
    case Err(e) -> {
      assertEqual(e.code, "INVALID_ADDRESS", "empty to address: code is INVALID_ADDRESS")
      assertEqualInt(sender.callCount, 0, "empty to address: sender.send never called")
    }
    case Ok(_) -> assertTrue(false, "empty to address: expected Err but got Ok")
  }
}

test "Mail.send rejects a `to` recipient whose address has no @" {
  var sender = Mail.MailSenderStub(callCount = 0)
  val msg = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = ""),
    to = [EmailAddress(address = "not-an-address", displayName = "")],
    cc = [],
    bcc = [],
    subject = "Subject",
    textBody = "body",
    htmlBody = "",
    attachments = [],
    replyTo = None
  )
  match Mail.send(sender, msg) {
    case Err(e) -> assertEqual(e.code, "INVALID_ADDRESS", "no-@ to address: code is INVALID_ADDRESS")
    case Ok(_) -> assertTrue(false, "no-@ to address: expected Err but got Ok")
  }
}

test "Mail.send rejects a `cc` recipient with an empty address, even with a valid `to`" {
  var sender = Mail.MailSenderStub(callCount = 0)
  val msg = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = ""),
    to = [EmailAddress(address = "good@example.com", displayName = "")],
    cc = [EmailAddress(address = "", displayName = "")],
    bcc = [],
    subject = "Subject",
    textBody = "body",
    htmlBody = "",
    attachments = [],
    replyTo = None
  )
  match Mail.send(sender, msg) {
    case Err(e) -> {
      assertEqual(e.code, "INVALID_ADDRESS", "empty cc address: code is INVALID_ADDRESS")
      assertEqualInt(sender.callCount, 0, "a partial send never reaches the sender")
    }
    case Ok(_) -> assertTrue(false, "empty cc address: expected Err but got Ok")
  }
}

test "Mail.send rejects a `bcc` recipient with an empty address" {
  var sender = Mail.MailSenderStub(callCount = 0)
  val msg = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = ""),
    to = [EmailAddress(address = "good@example.com", displayName = "")],
    cc = [],
    bcc = [EmailAddress(address = "", displayName = "")],
    subject = "Subject",
    textBody = "body",
    htmlBody = "",
    attachments = [],
    replyTo = None
  )
  match Mail.send(sender, msg) {
    case Err(e) -> assertEqual(e.code, "INVALID_ADDRESS", "empty bcc address: code is INVALID_ADDRESS")
    case Ok(_) -> assertTrue(false, "empty bcc address: expected Err but got Ok")
  }
}

test "Mail.send accepts a message whose recipients all have plausible addresses" {
  var sender = Mail.MailSenderStub(callCount = 0)
  val msg = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = ""),
    to = [EmailAddress(address = "a@example.com", displayName = "")],
    cc = [EmailAddress(address = "b@example.com", displayName = "")],
    bcc = [EmailAddress(address = "c@example.com", displayName = "")],
    subject = "Subject",
    textBody = "body",
    htmlBody = "",
    attachments = [],
    replyTo = None
  )
  match Mail.send(sender, msg) {
    case Ok(_) -> assertEqualInt(sender.callCount, 1, "all-plausible recipients: sender.send called once")
    case Err(e) -> assertTrue(false, "all-plausible recipients should succeed, got Err: " + e.message)
  }
}

// ─── Attachment size cap (#7254) ─────────────────────────────────────────────
test "Mail.send rejects a message whose total attachment size exceeds maxTotalAttachmentBytes" {
  var sender = Mail.MailSenderStub(callCount = 0)
  // ~26 MiB of base64 payload (over the 25 MiB cap): 4 base64 chars decode to
  // 3 bytes, so ~35,000,000 chars decodes to ~26.25 MiB.
  val hugeBase64 = repeat("AAAA", 8750000)
  val att = Mail.makeAttachment("huge.bin", "application/octet-stream", hugeBase64)
  val msg = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = ""),
    to = [EmailAddress(address = "r@example.com", displayName = "")],
    cc = [],
    bcc = [],
    subject = "Subject",
    textBody = "body",
    htmlBody = "",
    attachments = [att],
    replyTo = None
  )
  match Mail.send(sender, msg) {
    case Err(e) -> {
      assertEqual(e.code, "ATTACHMENTS_TOO_LARGE", "oversized attachment: code is ATTACHMENTS_TOO_LARGE")
      assertEqualInt(sender.callCount, 0, "oversized attachment: sender.send never called")
    }
    case Ok(_) -> assertTrue(false, "oversized attachment: expected Err but got Ok")
  }
}

test "Mail.send accepts a message whose total attachment size is within maxTotalAttachmentBytes" {
  var sender = Mail.MailSenderStub(callCount = 0)
  val att = Mail.makeAttachment("small.bin", "application/octet-stream", "SGVsbG8=")
  val msg = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = ""),
    to = [EmailAddress(address = "r@example.com", displayName = "")],
    cc = [],
    bcc = [],
    subject = "Subject",
    textBody = "body",
    htmlBody = "",
    attachments = [att],
    replyTo = None
  )
  match Mail.send(sender, msg) {
    case Ok(_) -> assertEqualInt(sender.callCount, 1, "small attachment: sender.send called once")
    case Err(e) -> assertTrue(false, "small attachment should succeed, got Err: " + e.message)
  }
}

// ─── SES / SendGrid config preconditions (#7254) ─────────────────────────────
// A missing/empty required credential must be reported as such,
// identically on every target.
test "Mail.connectSes returns Err naming the missing LYRIC_CONFIG_SES_REGION" {
  match Mail.connectSes() {
    case Err(e) -> assertEqual(e.code, "INVALID_CONFIG", "missing SES region: code is INVALID_CONFIG")
    case Ok(_) -> assertTrue(false, "SES with no region configured should not connect")
  }
}

test "Mail.connectSendGrid returns Err naming the missing LYRIC_CONFIG_SENDGRIDMAIL_APIKEY" {
  match Mail.connectSendGrid() {
    case Err(e) -> assertEqual(e.code, "INVALID_CONFIG", "missing SendGrid apiKey: code is INVALID_CONFIG")
    case Ok(_) -> assertTrue(false, "SendGrid with no apiKey configured should not connect")
  }
}

// ─── SendGrid / SES over HTTPS (#7462) ───────────────────────────────────────
func providerMessage(): Mail.EmailMessage {
  Mail.EmailMessage(
    from = Mail.makeAddress("a@x.com"),
    to = [Mail.makeAddress("b@y.com")],
    cc = [],
    bcc = [],
    subject = "Hi",
    textBody = "T",
    htmlBody = "",
    attachments = [],
    replyTo = None
  )
}

test "Mail.buildSendGridPayload renders the v3 mail/send body" {
  val msg = Mail.EmailMessage(
    from = Mail.makeAddressWithName("a@x.com", "Bot"),
    to = [Mail.makeAddress("b@y.com")],
    cc = [Mail.makeAddress("c@y.com")],
    bcc = [Mail.makeAddress("d@y.com")],
    subject = "Hi",
    textBody = "T",
    htmlBody = "<p>H</p>",
    attachments = [Mail.makeAttachment("f.txt", "text/plain", "QUJD")],
    replyTo = Some(value = Mail.makeAddress("r@x.com"))
  )
  val json = Mail.buildSendGridPayload(msg)
  assertTrue(
    json.startsWith(
      "{\"personalizations\":[{\"to\":[{\"email\":\"b@y.com\"}],\"cc\":[{\"email\":\"c@y.com\"}],\"bcc\":[{\"email\":\"d@y.com\"}]}],\"from\":{\"email\":\"a@x.com\",\"name\":\"Bot\"},\"subject\":\"Hi\",\"reply_to\":{\"email\":\"r@x.com\"},\"content\":[{\"type\":\"text/plain\",\"value\":\"T\"},{\"type\":\"text/html\""
    ),
    "personalizations, from, subject, reply_to, then text before html: " + json
  )
  assertTrue(
    json.endsWith(
      "\"attachments\":[{\"content\":\"QUJD\",\"filename\":\"f.txt\",\"type\":\"text/plain\",\"disposition\":\"attachment\"}]}"
    ),
    "attachments close the object: " + json
  )
}

test "Mail.buildSendGridPayload omits optional parts that are absent" {
  assertEqual(
    Mail.buildSendGridPayload(providerMessage()),
    "{\"personalizations\":[{\"to\":[{\"email\":\"b@y.com\"}]}],\"from\":{\"email\":\"a@x.com\"},\"subject\":\"Hi\",\"content\":[{\"type\":\"text/plain\",\"value\":\"T\"}]}",
    "minimal message"
  )
}

test "Mail.buildSesPayload uses Simple content without attachments" {
  assertEqual(
    Mail.buildSesPayload(providerMessage(), "B"),
    "{\"FromEmailAddress\":\"a@x.com\",\"Destination\":{\"ToAddresses\":[\"b@y.com\"]},\"Content\":{\"Simple\":{\"Subject\":{\"Data\":\"Hi\",\"Charset\":\"UTF-8\"},\"Body\":{\"Text\":{\"Data\":\"T\",\"Charset\":\"UTF-8\"}}}}}",
    "simple SES body"
  )
}

test "Mail.buildSesPayload sends Raw MIME when there are attachments" {
  val msg = Mail.EmailMessage(
    from = Mail.makeAddress("a@x.com"),
    to = [Mail.makeAddress("b@y.com")],
    cc = [],
    bcc = [Mail.makeAddress("d@y.com")],
    subject = "Hi",
    textBody = "T",
    htmlBody = "",
    attachments = [Mail.makeAttachment("f.txt", "text/plain", "QUJD")],
    replyTo = None
  )
  val json = Mail.buildSesPayload(msg, "B")
  assertTrue(json.contains("\"Raw\":{\"Data\":"), "raw content: " + json)
  assertTrue(json.contains("\"BccAddresses\":[\"d@y.com\"]"), "bcc travels in Destination: " + json)
  val mime = Mail.buildMimeMessage(msg, "B")
  assertTrue(
    mime.startsWith("From: a@x.com\r\nTo: b@y.com\r\nSubject: Hi\r\nMIME-Version: 1.0\r\n"),
    "headers: " + mime
  )
  assertFalse(mime.contains("d@y.com"), "bcc is not a MIME header")
  assertTrue(
    mime.contains("Content-Type: multipart/mixed; boundary=\"B\"\r\n\r\n--B\r\n"),
    "multipart/mixed opens: " + mime
  )
  assertTrue(
    mime.contains(
      "Content-Disposition: attachment; filename=\"f.txt\"\r\nContent-Transfer-Encoding: base64\r\n\r\nQUJD\r\n"
    ),
    "attachment part: " + mime
  )
  assertTrue(mime.endsWith("--B--\r\n"), "closing boundary")
}

test "Mail.buildMimeMessage wraps base64 at 76 columns and encodes non-ASCII headers" {
  val long = repeat("QUJD", 40)
  val msg = Mail.EmailMessage(
    from = Mail.makeAddressWithName("a@x.com", "Zoë"),
    to = [Mail.makeAddress("b@y.com")],
    cc = [],
    bcc = [],
    subject = "café",
    textBody = "T",
    htmlBody = "<p>H</p>",
    attachments = [Mail.makeAttachment("f.bin", "application/octet-stream", long)],
    replyTo = None
  )
  val mime = Mail.buildMimeMessage(msg, "B")
  assertTrue(mime.contains("Subject: =?UTF-8?B?"), "non-ASCII subject is an encoded word: " + mime)
  assertTrue(mime.contains("From: =?UTF-8?B?"), "non-ASCII display name is an encoded word")
  assertTrue(mime.contains("multipart/alternative; boundary=\"B_alt\""), "text and html share an alternative part")
  assertTrue(mime.contains(repeat("QUJD", 19) + "\r\n"), "76-column line")
  assertFalse(mime.contains(repeat("QUJD", 20)), "no line longer than 76 columns")
}

test "Mail.sigV4Authorization matches the AWS get-vanilla test vector" {
  assertEqual(
    Mail.sigV4Authorization(
      "GET",
      "/",
      "example.amazonaws.com",
      "us-east-1",
      "service",
      "AKIDEXAMPLE",
      "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
      "",
      "20150830T123600Z",
      ""
    ),
    "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31",
    "signature from the published AWS Signature V4 test suite"
  )
}

test "Mail.sigV4Authorization signs the session token when present" {
  val auth = Mail.sigV4Authorization(
    "POST",
    "/v2/email/outbound-emails",
    "h",
    "us-east-1",
    "ses",
    "AK",
    "SK",
    "TOKEN",
    "20150830T123600Z",
    "{}"
  )
  assertTrue(auth.contains("SignedHeaders=host;x-amz-date;x-amz-security-token,"), "token header is signed: " + auth)
}

test "Mail provider helpers: endpoint host, status codes, regions" {
  assertEqual(Mail.endpointHost("https://email.us-east-1.amazonaws.com"), "email.us-east-1.amazonaws.com", "https host")
  assertEqual(Mail.endpointHost("http://127.0.0.1:8025/base"), "127.0.0.1:8025", "host and port, path dropped")
  assertEqual(Mail.mailErrorCodeForStatus(401), "AUTH_FAILED", "401")
  assertEqual(Mail.mailErrorCodeForStatus(403), "AUTH_FAILED", "403")
  assertEqual(Mail.mailErrorCodeForStatus(429), "QUOTA_EXCEEDED", "429")
  assertEqual(Mail.mailErrorCodeForStatus(503), "PROVIDER_ERROR", "503")
  assertEqual(Mail.mailErrorCodeForStatus(400), "SEND_ERROR", "400")
  assertTrue(Mail.isValidAwsRegion("eu-west-2"), "real region")
  assertFalse(Mail.isValidAwsRegion(""), "empty region")
  assertFalse(Mail.isValidAwsRegion("evil.com/x"), "a region may not change the host")
}

test "Mail provider endpoints must be https unless they are loopback" {
  match Mail.newSendGridSender("key", "http://example.com") {
    case Err(e) -> assertEqual(e.code, "INVALID_CONFIG", "plain http to a remote host is refused")
    case Ok(_) -> assertTrue(false, "http://example.com would send the API key in clear text")
  }
  match Mail.newSesSender("us-east-1", "AK", "SK", "", "http://email.us-east-1.amazonaws.com") {
    case Err(e) -> assertEqual(e.code, "INVALID_CONFIG", "SES over plain http is refused")
    case Ok(_) -> assertTrue(false, "plain http SES endpoint must be rejected")
  }
  match Mail.newSendGridSender("key", "https://api.eu.sendgrid.com") {
    case Ok(_) -> assertTrue(true, "https is accepted")
    case Err(e) -> assertTrue(false, "https endpoint rejected: " + e.message)
  }
  assertTrue(Mail.isLoopbackAuthority("localhost:8025"), "localhost with port")
  assertTrue(Mail.isLoopbackAuthority("127.0.0.1"), "ipv4 loopback")
  assertTrue(Mail.isLoopbackAuthority("[::1]:8025"), "ipv6 loopback with port")
  assertFalse(Mail.isLoopbackAuthority("localhost.evil.com"), "prefix is not loopback")
  assertFalse(Mail.isLoopbackAuthority("example.com:80"), "remote host")
  match Mail.newSendGridSender("key", "http://localhost:8025") {
    case Ok(_) -> assertTrue(true, "loopback http is accepted")
    case Err(e) -> assertTrue(false, "loopback http rejected: " + e.message)
  }
}

test "Mail.sigV4Authorization signs the host including its port" {
  val bare = Mail.sigV4Authorization(
    "POST",
    "/p",
    "localhost",
    "us-east-1",
    "ses",
    "AK",
    "SK",
    "",
    "20150830T123600Z",
    "{}"
  )
  val withPort = Mail.sigV4Authorization(
    "POST",
    "/p",
    "localhost:8025",
    "us-east-1",
    "ses",
    "AK",
    "SK",
    "",
    "20150830T123600Z",
    "{}"
  )
  assertTrue(bare != withPort, "a different host authority changes the signature")
  assertEqual(Mail.endpointHost("http://localhost:8025/x"), "localhost:8025", "the port stays in the signed host")
}

test "Mail.validateNoInjection rejects CR/LF in attachment contentType and filename" {
  val bad = Mail.EmailMessage(
    from = Mail.makeAddress("a@x.com"),
    to = [Mail.makeAddress("b@y.com")],
    cc = [],
    bcc = [],
    subject = "Hi",
    textBody = "T",
    htmlBody = "",
    attachments = [Mail.makeAttachment("f.txt", "text/plain\r\nBcc: evil@x.com", "QUJD")],
    replyTo = None
  )
  assertTrue(Mail.validateNoInjection(bad).isSome(), "contentType with CRLF is rejected")
  val badName = Mail.EmailMessage(
    from = bad.from,
    to = bad.to,
    cc = [],
    bcc = [],
    subject = "Hi",
    textBody = "T",
    htmlBody = "",
    attachments = [Mail.makeAttachment("f\r\n.txt", "text/plain", "QUJD")],
    replyTo = None
  )
  assertTrue(Mail.validateNoInjection(badName).isSome(), "filename with CRLF is rejected")
}

test "Mail SendGrid and SES senders validate before dispatch and report transport failures" {
  val sg = match Mail.newSendGridSender("key", "http://127.0.0.1:1") {
    case Ok(s) -> s
    case Err(e) -> return assertTrue(false, "sender construction failed: " + e.message)
  }
  match sg.send(providerMessage()) {
    case Err(e) -> assertEqual(e.code, "SEND_ERROR", "closed port: transport failure")
    case Ok(_) -> assertTrue(false, "nothing listens on port 1")
  }
  val noRecipients = Mail.EmailMessage(
    from = Mail.makeAddress("a@x.com"),
    to = [],
    cc = [],
    bcc = [],
    subject = "Hi",
    textBody = "T",
    htmlBody = "",
    attachments = [],
    replyTo = None
  )
  match sg.send(noRecipients) {
    case Err(e) -> assertEqual(e.code, "NO_RECIPIENTS", "validated before any request")
    case Ok(_) -> assertTrue(false, "no recipients must be rejected")
  }
  val ses = match Mail.newSesSender("us-east-1", "AK", "SK", "", "http://127.0.0.1:1/") {
    case Ok(s) -> s
    case Err(e) -> return assertTrue(false, "sender construction failed: " + e.message)
  }
  match ses.send(providerMessage()) {
    case Err(e) -> assertEqual(e.code, "SEND_ERROR", "closed port: transport failure")
    case Ok(_) -> assertTrue(false, "nothing listens on port 1")
  }
  match Mail.newSesSender("us-east-1", "AK", "SK", "", "ftp://x") {
    case Err(e) -> assertEqual(e.code, "INVALID_CONFIG", "endpoint must be http(s)")
    case Ok(_) -> assertTrue(false, "ftp endpoint must be rejected")
  }
}

// ─── connectSmtp port/timeout validation (#7254) ─────────────────────────────
// Tested directly against `Mail.validateSmtpConfig`, not by round-tripping
// through `Std.Environment.setVar` + `Mail.connectSmtp()`: `setVar` is a
// documented no-op on `--target jvm` (see `validateSmtpConfig`'s doc
// comment), so an env-var-driven test of this validation logic would only
// ever see the default config on that target. Calling the pure validator
// directly makes the same assertions hold identically on both targets.
test "Mail.validateSmtpConfig rejects a port above 65535" {
  match Mail.validateSmtpConfig(70000, 30000) {
    case Some(e) -> assertEqual(e.code, "INVALID_CONFIG", "port above range: code is INVALID_CONFIG")
    case None -> assertTrue(false, "port 70000 should be rejected")
  }
}

test "Mail.validateSmtpConfig rejects a port of 0" {
  match Mail.validateSmtpConfig(0, 30000) {
    case Some(e) -> assertEqual(e.code, "INVALID_CONFIG", "port 0: code is INVALID_CONFIG")
    case None -> assertTrue(false, "port 0 should be rejected")
  }
}

test "Mail.validateSmtpConfig rejects a negative port" {
  match Mail.validateSmtpConfig(-1, 30000) {
    case Some(e) -> assertEqual(e.code, "INVALID_CONFIG", "negative port: code is INVALID_CONFIG")
    case None -> assertTrue(false, "a negative port should be rejected")
  }
}

test "Mail.validateSmtpConfig accepts the port boundaries 1 and 65535" {
  match Mail.validateSmtpConfig(1, 30000) {
    case None -> assertTrue(true, "port 1 is valid")
    case Some(e) -> assertTrue(false, "port 1 should be valid, got Err: " + e.message)
  }
  match Mail.validateSmtpConfig(65535, 30000) {
    case None -> assertTrue(true, "port 65535 is valid")
    case Some(e) -> assertTrue(false, "port 65535 should be valid, got Err: " + e.message)
  }
}

test "Mail.validateSmtpConfig rejects a zero timeoutMs" {
  match Mail.validateSmtpConfig(587, 0) {
    case Some(e) -> assertEqual(e.code, "INVALID_CONFIG", "timeoutMs 0: code is INVALID_CONFIG")
    case None -> assertTrue(false, "timeoutMs 0 should be rejected")
  }
}

test "Mail.validateSmtpConfig rejects a negative timeoutMs" {
  match Mail.validateSmtpConfig(587, -100) {
    case Some(e) -> assertEqual(e.code, "INVALID_CONFIG", "negative timeoutMs: code is INVALID_CONFIG")
    case None -> assertTrue(false, "a negative timeoutMs should be rejected")
  }
}

test "Mail.validateSmtpConfig accepts an in-range port and positive timeoutMs" {
  match Mail.validateSmtpConfig(587, 30000) {
    case None -> assertTrue(true, "587/30000 is valid config")
    case Some(e) -> assertTrue(false, "in-range config should be valid, got Err: " + e.message)
  }
}

// ─── connectSmtp is reachable on every target (#7254) ────────────────────────
// Before #7254, `--target jvm` failed to *compile* `Mail` at all (the
// package unconditionally imported `System.Net.Mail` externs). This asserts
// the weaker, always-true-across-targets property that `connectSmtp()`
// with in-range default config produces some `Result` — on `--target
// dotnet` a real `NativeSender` (`Ok`, closed immediately below); on
// `--target jvm` a structured `Err(code = "NOT_IMPLEMENTED")` from
// `Mail.Kernel.Jvm` (not a compile failure, and not a silent no-op).
test "Mail.connectSmtp is reachable and returns a well-formed Result on this target" {
  match Mail.connectSmtp() {
    case Ok(sender) -> sender.close()
    case Err(e) -> assertEqual(
      e.code,
      "NOT_IMPLEMENTED",
      "the only expected failure mode is JVM's not-yet-implemented kernel"
    )
  }
}

// ─── connectSmtp: malformed (non-numeric) config values (#7476 suggestion 3) ─
// A malformed LYRIC_CONFIG_SMTP_PORT/TIMEOUTMS previously fell back to the
// default silently; now it must be named in a structured Err.
// `Std.Environment.setVar` is a documented no-op on `--target jvm` (see
// `Mail.validateSmtpConfig`'s doc comment), so a round-trip through it would
// only ever observe the default config on that target — the same reason
// `Mail.validateSmtpConfig`'s own tests below call the pure validator
// directly instead of round-tripping through env vars. Each test here is
// unconditional (so `Lyric.TestSynth`'s dispatcher, generated ahead of
// `@cfg` erasure, always finds its synthesized function — see the
// `messageToJsonForTest` note above) and consults a per-target helper to
// know whether the env-var round-trip is meaningful on this target.
@cfg(feature = "dotnet")
func envVarConfigRoundTripSupported(): Bool {
  true
}

@cfg(feature = "jvm")
func envVarConfigRoundTripSupported(): Bool {
  false
}

test "Mail.connectSmtp rejects a non-numeric LYRIC_CONFIG_SMTP_PORT" {
  if not envVarConfigRoundTripSupported() {
    assertTrue(true, "Std.Environment.setVar is a no-op on this target (jvm)")
  } else {
    Std.Environment.setVar("LYRIC_CONFIG_SMTP_PORT", "not-a-port")
    match Mail.connectSmtp() {
      case Err(e) -> assertEqual(e.code, "INVALID_CONFIG", "non-numeric port: code is INVALID_CONFIG")
      case Ok(sender) -> {
        sender.close()
        assertTrue(false, "a non-numeric port must never be silently accepted")
      }
    }
    Std.Environment.setVar("LYRIC_CONFIG_SMTP_PORT", "587")
  }
}

test "Mail.connectSmtp rejects a non-numeric LYRIC_CONFIG_SMTP_TIMEOUTMS" {
  if not envVarConfigRoundTripSupported() {
    assertTrue(true, "Std.Environment.setVar is a no-op on this target (jvm)")
  } else {
    Std.Environment.setVar("LYRIC_CONFIG_SMTP_TIMEOUTMS", "not-a-timeout")
    match Mail.connectSmtp() {
      case Err(e) -> assertEqual(e.code, "INVALID_CONFIG", "non-numeric timeoutMs: code is INVALID_CONFIG")
      case Ok(sender) -> {
        sender.close()
        assertTrue(false, "a non-numeric timeoutMs must never be silently accepted")
      }
    }
    Std.Environment.setVar("LYRIC_CONFIG_SMTP_TIMEOUTMS", "30000")
  }
}

// ─── isPlausibleAddress shape check (#7476 suggestion 5) ─────────────────────
// Previously `isPlausibleAddress` only checked for the presence of an '@'
// anywhere in the string, letting "@", "a@", "@b", and "a@b@c" through.
test "Mail.send rejects a `to` address that is just \"@\"" {
  var sender = Mail.MailSenderStub(callCount = 0)
  val msg = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = ""),
    to = [EmailAddress(address = "@", displayName = "")],
    cc = [],
    bcc = [],
    subject = "Subject",
    textBody = "body",
    htmlBody = "",
    attachments = [],
    replyTo = None
  )
  match Mail.send(sender, msg) {
    case Err(e) -> assertEqual(e.code, "INVALID_ADDRESS", "bare @: code is INVALID_ADDRESS")
    case Ok(_) -> assertTrue(false, "bare @: expected Err but got Ok")
  }
}

test "Mail.send rejects a `to` address with no local part (\"@example.com\")" {
  var sender = Mail.MailSenderStub(callCount = 0)
  val msg = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = ""),
    to = [EmailAddress(address = "@example.com", displayName = "")],
    cc = [],
    bcc = [],
    subject = "Subject",
    textBody = "body",
    htmlBody = "",
    attachments = [],
    replyTo = None
  )
  match Mail.send(sender, msg) {
    case Err(e) -> assertEqual(e.code, "INVALID_ADDRESS", "no local part: code is INVALID_ADDRESS")
    case Ok(_) -> assertTrue(false, "no local part: expected Err but got Ok")
  }
}

test "Mail.send rejects a `to` address with no domain part (\"a@\")" {
  var sender = Mail.MailSenderStub(callCount = 0)
  val msg = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = ""),
    to = [EmailAddress(address = "a@", displayName = "")],
    cc = [],
    bcc = [],
    subject = "Subject",
    textBody = "body",
    htmlBody = "",
    attachments = [],
    replyTo = None
  )
  match Mail.send(sender, msg) {
    case Err(e) -> assertEqual(e.code, "INVALID_ADDRESS", "no domain part: code is INVALID_ADDRESS")
    case Ok(_) -> assertTrue(false, "no domain part: expected Err but got Ok")
  }
}

test "Mail.send rejects a `to` address with two @ signs (\"a@b@c\")" {
  var sender = Mail.MailSenderStub(callCount = 0)
  val msg = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = ""),
    to = [EmailAddress(address = "a@b@c", displayName = "")],
    cc = [],
    bcc = [],
    subject = "Subject",
    textBody = "body",
    htmlBody = "",
    attachments = [],
    replyTo = None
  )
  match Mail.send(sender, msg) {
    case Err(e) -> assertEqual(e.code, "INVALID_ADDRESS", "two @ signs: code is INVALID_ADDRESS")
    case Ok(_) -> assertTrue(false, "two @ signs: expected Err but got Ok")
  }
}

test "Mail.send rejects a `to` address whose domain contains whitespace" {
  var sender = Mail.MailSenderStub(callCount = 0)
  val msg = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = ""),
    to = [EmailAddress(address = "a@exa mple.com", displayName = "")],
    cc = [],
    bcc = [],
    subject = "Subject",
    textBody = "body",
    htmlBody = "",
    attachments = [],
    replyTo = None
  )
  match Mail.send(sender, msg) {
    case Err(e) -> assertEqual(e.code, "INVALID_ADDRESS", "whitespace domain: code is INVALID_ADDRESS")
    case Ok(_) -> assertTrue(false, "whitespace domain: expected Err but got Ok")
  }
}

test "Mail.send accepts a plausible \"local@domain\" address" {
  var sender = Mail.MailSenderStub(callCount = 0)
  val msg = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = ""),
    to = [EmailAddress(address = "a@b", displayName = "")],
    cc = [],
    bcc = [],
    subject = "Subject",
    textBody = "body",
    htmlBody = "",
    attachments = [],
    replyTo = None
  )
  match Mail.send(sender, msg) {
    case Ok(_) -> assertEqualInt(sender.callCount, 1, "plausible address: sender.send called once")
    case Err(e) -> assertTrue(false, "plausible address should succeed, got Err: " + e.message)
  }
}

// ─── replyTo address validation (#7476 suggestion 4) ─────────────────────────
// Previously an empty replyTo address was silently dropped from the
// outgoing message instead of rejected.
test "Mail.send rejects a message whose replyTo address is empty" {
  var sender = Mail.MailSenderStub(callCount = 0)
  val msg = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = ""),
    to = [EmailAddress(address = "r@example.com", displayName = "")],
    cc = [],
    bcc = [],
    subject = "Subject",
    textBody = "body",
    htmlBody = "",
    attachments = [],
    replyTo = Some(EmailAddress(address = "", displayName = "Support"))
  )
  match Mail.send(sender, msg) {
    case Err(e) -> {
      assertEqual(e.code, "INVALID_ADDRESS", "empty replyTo: code is INVALID_ADDRESS")
      assertEqualInt(sender.callCount, 0, "empty replyTo: sender.send never called")
    }
    case Ok(_) -> assertTrue(false, "empty replyTo: expected Err but got Ok")
  }
}

test "Mail.send rejects a message whose replyTo address has no @" {
  var sender = Mail.MailSenderStub(callCount = 0)
  val msg = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = ""),
    to = [EmailAddress(address = "r@example.com", displayName = "")],
    cc = [],
    bcc = [],
    subject = "Subject",
    textBody = "body",
    htmlBody = "",
    attachments = [],
    replyTo = Some(EmailAddress(address = "not-an-address", displayName = ""))
  )
  match Mail.send(sender, msg) {
    case Err(e) -> assertEqual(e.code, "INVALID_ADDRESS", "no-@ replyTo: code is INVALID_ADDRESS")
    case Ok(_) -> assertTrue(false, "no-@ replyTo: expected Err but got Ok")
  }
}

test "Mail.send accepts a message with a valid replyTo address" {
  var sender = Mail.MailSenderStub(callCount = 0)
  val msg = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = ""),
    to = [EmailAddress(address = "r@example.com", displayName = "")],
    cc = [],
    bcc = [],
    subject = "Subject",
    textBody = "body",
    htmlBody = "",
    attachments = [],
    replyTo = Some(EmailAddress(address = "support@example.com", displayName = "Support"))
  )
  match Mail.send(sender, msg) {
    case Ok(_) -> assertEqualInt(sender.callCount, 1, "valid replyTo: sender.send called once")
    case Err(e) -> assertTrue(false, "valid replyTo should succeed, got Err: " + e.message)
  }
}

test "Mail.send accepts a message with no replyTo (None)" {
  var sender = Mail.MailSenderStub(callCount = 0)
  val msg = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = ""),
    to = [EmailAddress(address = "r@example.com", displayName = "")],
    cc = [],
    bcc = [],
    subject = "Subject",
    textBody = "body",
    htmlBody = "",
    attachments = [],
    replyTo = None
  )
  match Mail.send(sender, msg) {
    case Ok(_) -> assertEqualInt(sender.callCount, 1, "no replyTo: sender.send called once")
    case Err(e) -> assertTrue(false, "no replyTo should succeed, got Err: " + e.message)
  }
}

// ─── Attachment-size cap: exact boundary and multi-attachment overflow ──────
// (#7476 suggestion 1). `approxBase64DecodedLength`/`totalAttachmentBytes`
// previously used `Int` arithmetic that overflows for a long enough base64
// string; these tests pin the exact-cap boundary (== cap passes, cap + 1
// fails) and a case where no single attachment exceeds the cap but the sum
// of several does.
//
// Both boundary strings share the same 34,952,536-character 'A'-filled base
// (from `repeat("AAAA", 8738134)`) and differ only in their trailing `=`
// padding: `approxBase64DecodedLength` computes `(len / 4) * 3 - padding`,
// so one trailing `=` (padding 1) decodes one byte larger than two trailing
// `=` (padding 2).
test "Mail.send accepts a single attachment whose decoded size is exactly maxTotalAttachmentBytes" {
  var sender = Mail.MailSenderStub(callCount = 0)
  val base = repeat("AAAA", 8738134)
  val exactCapBase64 = base.substring(0, base.length - 2) + "=="
  val att = Mail.makeAttachment("exact.bin", "application/octet-stream", exactCapBase64)
  val msg = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = ""),
    to = [EmailAddress(address = "r@example.com", displayName = "")],
    cc = [],
    bcc = [],
    subject = "Subject",
    textBody = "body",
    htmlBody = "",
    attachments = [att],
    replyTo = None
  )
  match Mail.send(sender, msg) {
    case Ok(_) -> assertEqualInt(sender.callCount, 1, "exactly-at-cap attachment: sender.send called once")
    case Err(e) -> assertTrue(false, "exactly-at-cap attachment should succeed, got Err: " + e.message)
  }
}

test "Mail.send rejects a single attachment whose decoded size is maxTotalAttachmentBytes + 1" {
  var sender = Mail.MailSenderStub(callCount = 0)
  val base = repeat("AAAA", 8738134)
  val overCapBase64 = base.substring(0, base.length - 1) + "="
  val att = Mail.makeAttachment("over.bin", "application/octet-stream", overCapBase64)
  val msg = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = ""),
    to = [EmailAddress(address = "r@example.com", displayName = "")],
    cc = [],
    bcc = [],
    subject = "Subject",
    textBody = "body",
    htmlBody = "",
    attachments = [att],
    replyTo = None
  )
  match Mail.send(sender, msg) {
    case Err(e) -> {
      assertEqual(e.code, "ATTACHMENTS_TOO_LARGE", "one-byte-over-cap attachment: code is ATTACHMENTS_TOO_LARGE")
      assertEqualInt(sender.callCount, 0, "one-byte-over-cap attachment: sender.send never called")
    }
    case Ok(_) -> assertTrue(false, "one-byte-over-cap attachment: expected Err but got Ok")
  }
}

test "Mail.send rejects a message whose attachments individually fit under the cap but sum over it" {
  var sender = Mail.MailSenderStub(callCount = 0)
  // Each attachment decodes to roughly half of maxTotalAttachmentBytes, well
  // under the cap on its own; their sum is maxTotalAttachmentBytes + 1.
  val half = repeat("AAAA", 4369067)
  val att1Base64 = half.substring(0, half.length - 1) + "="
  val att2Base64 = half
  val att1 = Mail.makeAttachment("half1.bin", "application/octet-stream", att1Base64)
  val att2 = Mail.makeAttachment("half2.bin", "application/octet-stream", att2Base64)
  val msg = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = ""),
    to = [EmailAddress(address = "r@example.com", displayName = "")],
    cc = [],
    bcc = [],
    subject = "Subject",
    textBody = "body",
    htmlBody = "",
    attachments = [att1, att2],
    replyTo = None
  )
  match Mail.send(sender, msg) {
    case Err(e) -> {
      assertEqual(e.code, "ATTACHMENTS_TOO_LARGE", "sum-over-cap attachments: code is ATTACHMENTS_TOO_LARGE")
      assertEqualInt(sender.callCount, 0, "sum-over-cap attachments: sender.send never called")
    }
    case Ok(_) -> assertTrue(false, "sum-over-cap attachments: expected Err but got Ok")
  }
}

// ─── messageToJson: control-character escaping and displayName carry-through
// (#7476 suggestion 2, suggestion 8) ──────────────────────────────────────────
// `Mail.messageToJson` is `@cfg(feature = "jvm")` (plus `smtp`), so it does
// not exist as a symbol on `--target dotnet` at all — a `@cfg`-gated `test`
// item would leave `Lyric.TestSynth`'s generated dispatcher referencing a
// test function that erasure removed (test-synthesis runs over the
// unconditional item list, ahead of `@cfg` erasure). Each test below is
// therefore unconditional and calls a same-named, per-target helper (the
// `storageKeyGuardedHandler` idiom in `lyric-storage`'s aspect-weaving
// tests): the `jvm` + `smtp` variant calls the real `Mail.messageToJson`,
// the `dotnet` variant returns `None` so the test degenerates to a no-op
// assertion on that target. `Std.Json` is BCL-backed (.NET-only, see
// mail.l's kernel notes), so a parse-based round-trip is not available on
// `--target jvm` either; the escaped form is asserted directly instead, per
// the finding's own fallback.
@cfg(feature = "jvm")
@cfg(feature = "smtp")
func messageToJsonForTest(msg: in EmailMessage): Option[String] {
  return Some(value = Mail.messageToJson(msg))
}

@cfg(feature = "dotnet")
func messageToJsonForTest(msg: in EmailMessage): Option[String] {
  return None
}

test "Mail.messageToJson escapes a multi-line textBody as valid JSON (no raw newlines)" {
  val msg = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = ""),
    to = [EmailAddress(address = "r@example.com", displayName = "")],
    cc = [],
    bcc = [],
    subject = "Multi-line",
    textBody = "line one\nline two\r\nline three\ttabbed",
    htmlBody = "",
    attachments = [],
    replyTo = None
  )
  match messageToJsonForTest(msg) {
    case None -> assertTrue(true, "messageToJson is not available on this target (dotnet)")
    case Some(jsonStr) -> {
      assertTrue(not containsRawControlChar(jsonStr), "no raw CR/LF/TAB in the JSON output")
      assertTrue(
        Std.String.contains(jsonStr, "line one\\nline two\\r\\nline three\\ttabbed"),
        "body escaped with short forms"
      )
    }
  }
}

test "Mail.messageToJson escapes a control character below U+0020 as \\u00XX" {
  val msg = EmailMessage(
    from = EmailAddress(address = "s@example.com", displayName = ""),
    to = [EmailAddress(address = "r@example.com", displayName = "")],
    cc = [],
    bcc = [],
    subject = "Subject",
    textBody = "before\u{0001}after",
    htmlBody = "",
    attachments = [],
    replyTo = None
  )
  match messageToJsonForTest(msg) {
    case None -> assertTrue(true, "messageToJson is not available on this target (dotnet)")
    case Some(jsonStr) -> {
      assertTrue(not containsRawControlChar(jsonStr), "no raw control character in the JSON output")
      assertTrue(Std.String.contains(jsonStr, "before\\u0001after"), "control char escaped as \\u0001")
    }
  }
}

test "Mail.messageToJson carries the from/to displayName through to the JSON output" {
  val msg = EmailMessage(
    from = EmailAddress(address = "sender@example.com", displayName = "Sender Name"),
    to = [EmailAddress(address = "recv@example.com", displayName = "Recv Name")],
    cc = [],
    bcc = [],
    subject = "Subject",
    textBody = "body",
    htmlBody = "",
    attachments = [],
    replyTo = None
  )
  match messageToJsonForTest(msg) {
    case None -> assertTrue(true, "messageToJson is not available on this target (dotnet)")
    case Some(jsonStr) -> {
      assertTrue(Std.String.contains(jsonStr, "\"displayName\":\"Sender Name\""), "from displayName present in JSON")
      assertTrue(Std.String.contains(jsonStr, "\"displayName\":\"Recv Name\""), "to displayName present in JSON")
    }
  }
}

// Any bare CR, LF, or TAB character — used to assert `messageToJson` never
// leaves one unescaped in its output.
func containsRawControlChar(s: in String): Bool {
  var i = 0
  while i < s.length {
    val ch = s[i]
    if ch == '\n' or ch == '\r' or ch == '\t' or ch == '\u{0001}' {
      return true
    }
    i = i + 1
  }
  return false
}
