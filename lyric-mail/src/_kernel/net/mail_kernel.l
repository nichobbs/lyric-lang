/// Mail.Kernel.Net — extern boundary for email-sending providers.
///
/// BCL System.Net.Mail SMTP backend: all BCL types are declared as
/// `extern type` so the Lyric public layer can hold them directly
/// (no integer handle registry). Error handling uses `try/catch` in
/// the Lyric public layer — no F# wrapper needed.
///
/// Amazon SES and SendGrid backends remain declarative-only — their
/// bindings are placeholders until provider-specific Testcontainers
/// infrastructure lands (#780 follow-up).
///
/// See docs/14-native-stdlib-plan.md for the kernel boundary contract.

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

// ─── SmtpClient construction and configuration ────────────────────────────────

@axiom("new System.Net.Mail.SmtpClient(host, port)")
@externTarget("System.Net.Mail.SmtpClient..ctor")
pub func newSmtpClient(host: in String, port: in Int): SmtpClient = ()

@axiom("System.Net.Mail.SmtpClient.EnableSsl setter")
@externTarget("System.Net.Mail.SmtpClient.set_EnableSsl")
pub func smtpSetEnableSsl(client: in SmtpClient, value: in Bool): Unit = ()

@axiom("System.Net.Mail.SmtpClient.Timeout setter")
@externTarget("System.Net.Mail.SmtpClient.set_Timeout")
pub func smtpSetTimeout(client: in SmtpClient, value: in Int): Unit = ()

@axiom("new System.Net.NetworkCredential(username, password)")
@externTarget("System.Net.NetworkCredential..ctor")
pub func newNetworkCredential(username: in String, password: in String): NetworkCredential = ()

@axiom("System.Net.Mail.SmtpClient.Credentials setter — parameter type is ICredentialsByHost; NetworkCredential satisfies it at the CLR level")
@externTarget("System.Net.Mail.SmtpClient.set_Credentials")
pub func smtpSetCredentials(client: in SmtpClient, cred: in NetworkCredential): Unit = ()

@axiom("System.Net.Mail.SmtpClient.Send(MailMessage) — instance method, callvirt")
@externTarget("System.Net.Mail.SmtpClient.Send")
pub func smtpClientSend(client: in SmtpClient, msg: in MailMessage): Unit = ()

@axiom("System.Net.Mail.SmtpClient.Dispose() — releases the underlying TCP connection")
@externTarget("System.Net.Mail.SmtpClient.Dispose")
pub func smtpClientDispose(client: in SmtpClient): Unit = ()

// ─── MailMessage construction and mutation ────────────────────────────────────

@axiom("new System.Net.Mail.MailMessage()")
@externTarget("System.Net.Mail.MailMessage..ctor")
pub func newMailMessage(): MailMessage = ()

@axiom("System.Net.Mail.MailMessage.From setter")
@externTarget("System.Net.Mail.MailMessage.set_From")
pub func mailSetFrom(msg: in MailMessage, addr: in MailAddress): Unit = ()

@axiom("System.Net.Mail.MailMessage.Subject setter")
@externTarget("System.Net.Mail.MailMessage.set_Subject")
pub func mailSetSubject(msg: in MailMessage, subject: in String): Unit = ()

@axiom("System.Net.Mail.MailMessage.IsBodyHtml setter")
@externTarget("System.Net.Mail.MailMessage.set_IsBodyHtml")
pub func mailSetIsBodyHtml(msg: in MailMessage, value: in Bool): Unit = ()

@axiom("System.Net.Mail.MailMessage.Body setter")
@externTarget("System.Net.Mail.MailMessage.set_Body")
pub func mailSetBody(msg: in MailMessage, body: in String): Unit = ()

@axiom("System.Net.Mail.MailMessage.To getter — returns the MailAddressCollection for recipient mutation")
@externTarget("System.Net.Mail.MailMessage.get_To")
pub func mailGetTo(msg: in MailMessage): MailAddressCollection = ()

// ─── MailAddress construction ─────────────────────────────────────────────────

@axiom("new System.Net.Mail.MailAddress(address) — 1-arg constructor")
@externTarget("System.Net.Mail.MailAddress..ctor")
pub func newMailAddress(address: in String): MailAddress = ()

// ─── MailAddressCollection mutation ──────────────────────────────────────────

@axiom("System.Net.Mail.MailAddressCollection.Add(MailAddress) — exact-type match picks this overload over Add(string)")
@externTarget("System.Net.Mail.MailAddressCollection.Add")
pub func mailAddressCollectionAdd(coll: in MailAddressCollection, addr: in MailAddress): Unit = ()

// ─── Amazon SES (Phase 4 follow-up of #733) ──────────────────────────────────

@axiom("Amazon SES backend not yet implemented (#733 follow-up)")
@cfg(feature = "ses")
pub func connectSes(
  region:    in String,
  accessKey: in String,
  secretKey: in String
): Result[Int, String]
  requires: region.length > 0
  = Err("lyric-mail: Amazon SES backend not yet implemented (Phase 4 follow-up of #733)")

// ─── SendGrid (Phase 4 follow-up of #733) ────────────────────────────────────

@axiom("SendGrid backend not yet implemented (#733 follow-up)")
@cfg(feature = "sendgrid")
pub func connectSendGrid(apiKey: in String): Result[Int, String]
  requires: apiKey.length > 0
  = Err("lyric-mail: SendGrid backend not yet implemented (Phase 4 follow-up of #733)")
