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
//
// SmtpClient, MailMessage, MailAddress, NetworkCredential (declared here as
// `pub extern type`, not `import extern` — a type imported via `import
// extern` is scoped to the importing package only, docs/47-import-extern-
// syntax.md §2.2, so it cannot be referenced qualified from `mail.l` the way
// `pub extern type` names below already are) moved here (back) from `mail.l`
// (#7254): externs must live only in a kernel file (`import extern`/`extern
// type`/`@externTarget` are never allowed in the public `Mail` package), and
// `mail.l`'s `NativeSender` (the `--target dotnet`-only `MailSender` impl)
// consumes these extern types qualified through this package, exactly like
// `KMailAddressCollection`/`KMailAddress` below already do.
@axiom("BCL System.Net.Mail.SmtpClient — SMTP client")
pub extern type SmtpClient = "System.Net.Mail.SmtpClient"

@axiom("BCL System.Net.Mail.MailMessage — a MIME email message")
pub extern type MailMessage = "System.Net.Mail.MailMessage"

@axiom("BCL System.Net.Mail.MailAddress — a parsed mail address, held for construction")
pub extern type MailAddress = "System.Net.Mail.MailAddress"

@axiom("BCL System.Net.NetworkCredential — SMTP auth credential")
pub extern type NetworkCredential = "System.Net.NetworkCredential"

// `SmtpClient.Credentials`'s property setter is typed
// `System.Net.ICredentialsByHost` (an interface `NetworkCredential`
// implements), which auto-FFI's overload matcher cannot bridge to for a
// cross-package extern-type argument (#7254) — a declared-signature wrapper
// binds it directly, mirroring `mailAddressCollectionAdd` above.
@axiom("SmtpClient.Credentials property setter — NetworkCredential implements the ICredentialsByHost parameter type")
@externInstance
@externTarget("System.Net.Mail.SmtpClient.set_Credentials")
pub func setCredentials(client: in SmtpClient, cred: in NetworkCredential): Unit = ()

// ─── Attachment support ───────────────────────────────────────────────────────
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

// `Add(T)` on these collections lives on the generic base
// `Collection<T>`, which auto-FFI's Extends walk deliberately does not
// cross (generic TypeSpec base), so a bare `coll.Add(x)` is a
// compile-time resolution failure (#5562).  Declared-signature wrappers
// bind it the way the stdlib collections kernels do — the runtime
// resolves the MemberRef through the instantiated base.
@axiom("BCL System.Net.Mail.MailAddressCollection — recipient list on MailMessage")
pub extern type KMailAddressCollection = "System.Net.Mail.MailAddressCollection"

@axiom("BCL System.Net.Mail.MailAddress — parsed mail address")
pub extern type KMailAddress = "System.Net.Mail.MailAddress"

@axiom("BCL System.Net.Mail.AttachmentCollection — attachment list on MailMessage")
pub extern type KAttachmentCollection = "System.Net.Mail.AttachmentCollection"

@axiom("Collection<MailAddress>.Add(MailAddress) via MailAddressCollection — append a recipient")
@externInstance
@externTarget("System.Net.Mail.MailAddressCollection.Add")
pub func mailAddressCollectionAdd(coll: in KMailAddressCollection, addr: in KMailAddress): Unit = ()

@axiom("Collection<Attachment>.Add(Attachment) via AttachmentCollection — append an attachment")
@externInstance
@externTarget("System.Net.Mail.AttachmentCollection.Add")
pub func attachmentCollectionAdd(coll: in KAttachmentCollection, att: in BclAttachment): Unit = ()

// Amazon SES / SendGrid: `mail.l`'s own `connectSes`/`connectSendGrid` (not
// this kernel) own the "not yet implemented" response and the
// region/apiKey preconditions (#7254) — those preconditions must hold
// identically on every target, and this kernel has no JVM twin function to
// mirror them in.  Nothing in this kernel calls into a real SES/SendGrid
// client yet, so there is nothing target-specific for this file to declare
// for either provider.
