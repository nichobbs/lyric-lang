//! Mail.Kernel.Net — extern boundary for email-sending providers.
//!
//! BCL System.Net.Mail SMTP backend: all BCL types are declared as
//! `extern type` so the Lyric public layer can hold them directly
//! (no integer handle registry). Error handling uses `try/catch` in
//! the Lyric public layer — no F# wrapper needed.
//!
//! Amazon SES and SendGrid backends remain declarative-only — their
//! bindings are placeholders until provider-specific Testcontainers
//! infrastructure lands (#780 follow-up).
//!
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.
package Mail.Kernel.Net

import Std.Core

// SMTP externs are intentionally not `@cfg(feature = "smtp")`-gated: the
// SMTP backend is the default mail provider and uses only `System.Net.Mail`
// types that ship in the BCL.  No additional NuGet dependency is needed,
// so the externs are always emittable.  SES/SendGrid below carry their own
// `@cfg` gates because they pull in optional AWS SDK / SendGrid NuGet
// dependencies.  See #1112.
// ─── Extern types ─────────────────────────────────────────────────────────────
@axiom("BCL System.Net.Mail.SmtpClient (SYSLIB0014 advisory: acceptable for Phase-4 SMTP path)")
pub extern type SmtpClient = "System.Net.Mail.SmtpClient"

@axiom("BCL System.Net.Mail.MailMessage")
pub extern type MailMessage = "System.Net.Mail.MailMessage"

@axiom("BCL System.Net.Mail.MailAddress")
pub extern type MailAddress = "System.Net.Mail.MailAddress"

@axiom("BCL System.Net.Mail.MailAddressCollection")
pub extern type MailAddressCollection = "System.Net.Mail.MailAddressCollection"

@axiom("BCL System.Net.NetworkCredential")
pub extern type NetworkCredential = "System.Net.NetworkCredential"



// ─── Attachment support ───────────────────────────────────────────────────────
@axiom("BCL System.Net.Mail.AttachmentCollection")
pub extern type AttachmentCollection = "System.Net.Mail.AttachmentCollection"

@axiom("BCL System.Net.Mail.Attachment — MIME attachment backed by a MemoryStream")
pub extern type BclAttachment = "System.Net.Mail.Attachment"

@axiom("BCL System.IO.MemoryStream — byte buffer for building attachment content")
pub extern type MemoryStream = "System.IO.MemoryStream"

@axiom("BCL System.Convert.FromBase64String — decode a base64 string to byte[]")
@externTarget("System.Convert.FromBase64String")
pub func base64Decode(s: in String): slice[Byte] = ()

@axiom("new System.IO.MemoryStream(byte[]) — wrap a byte array in a MemoryStream")
@externTarget("System.IO.MemoryStream..ctor")
pub func newMemoryStream(buf: in slice[Byte]): MemoryStream = ()

@axiom("new System.Net.Mail.Attachment(Stream, String, String) — create MIME attachment from stream with filename and content-type")
@externTarget("System.Net.Mail.Attachment..ctor")
pub func newBclAttachment(stream: in MemoryStream, name: in String, mediaType: in String): BclAttachment = ()



// ─── Amazon SES (Phase 4 follow-up of #733) ──────────────────────────────────
@axiom("Amazon SES backend not yet implemented (#733 follow-up)")
@cfg(feature = "ses")
pub func connectSes(region: in String, accessKey: in String, secretKey: in String): Result[Int, String]
  requires: region.length > 0
  = Err("lyric-mail: Amazon SES backend not yet implemented (Phase 4 follow-up of #733)")

// ─── SendGrid (Phase 4 follow-up of #733) ────────────────────────────────────
@axiom("SendGrid backend not yet implemented (#733 follow-up)")
@cfg(feature = "sendgrid")
pub func connectSendGrid(apiKey: in String): Result[Int, String]
  requires: apiKey.length > 0
  = Err("lyric-mail: SendGrid backend not yet implemented (Phase 4 follow-up of #733)")
