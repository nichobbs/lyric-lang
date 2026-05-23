/// Mail.Kernel.Net — extern boundary for email-sending providers.
///
/// Phase 4 of #733: BCL System.Net.Mail SMTP backend functional via
/// `Lyric.Mail.SmtpHost`.  Amazon SES and SendGrid backends remain
/// declarative-only — their bindings are routed to placeholder
/// `*NotYet` targets that return a clear "not yet implemented" error
/// until provider-specific Testcontainers infrastructure lands
/// (#780 follow-up).
///
/// Each provider exposes three functions: `connectXxx` (returns an
/// opaque Int handle), `smtpSend` (accepts typed native parameters),
/// and `close`.  The Lyric public layer assembles these from the
/// `EmailMessage` record before the extern call; the F# host receives
/// native types and calls BCL APIs directly — no JSON parsing required.
///
/// See docs/14-native-stdlib-plan.md for the kernel boundary contract.

package Mail.Kernel.Net

import Std.Core

// ─── SMTP provider (BCL System.Net.Mail.SmtpClient) ──────────────────────────

@axiom("Lyric.Mail.SmtpHost.connect — System.Net.Mail.SmtpClient over the supplied host/port; useTls maps to EnableSsl")
@externTarget("Lyric.Mail.SmtpHost.connect")
@cfg(feature = "smtp")
pub func connectSmtp(
  host:      in String,
  port:      in Int,
  username:  in String,
  password:  in String,
  useTls:    in Bool,
  timeoutMs: in Int
): Result[Int, String]
  requires: host.length > 0
  requires: port >= 1
  requires: port <= 65535
  requires: timeoutMs >= 1
  = ()

// ─── Amazon SES (Phase 4 follow-up of #733) ──────────────────────────────────

@axiom("Amazon SES backend not yet implemented (#733 follow-up)")
@externTarget("Lyric.Mail.SmtpHost.sesConnectNotYet")
@cfg(feature = "ses")
pub func connectSes(
  region:    in String,
  accessKey: in String,
  secretKey: in String
): Result[Int, String]
  requires: region.length > 0
  = ()

// ─── SendGrid (Phase 4 follow-up of #733) ────────────────────────────────────

@axiom("SendGrid backend not yet implemented (#733 follow-up)")
@externTarget("Lyric.Mail.SmtpHost.sendGridConnectNotYet")
@cfg(feature = "sendgrid")
pub func connectSendGrid(apiKey: in String): Result[Int, String]
  requires: apiKey.length > 0
  = ()

// ─── SMTP-feature-gated send / close ─────────────────────────────────────────
//
// Per-provider gating: `smtpSend` and `close` dispatch is bound per-feature
// to keep the routing honest once additional backend shims land
// (#1016 follow-up).  Each backend will have its own
// `@externTarget("Lyric.Mail.<Backend>.smtpSend")` arm gated by its feature.

@axiom("Lyric.Mail.SmtpHost.smtpSend — dispatches via System.Net.Mail.SmtpClient.Send using typed native parameters; no JSON parsing in the host")
@externTarget("Lyric.Mail.SmtpHost.smtpSend")
@cfg(feature = "smtp")
pub func smtpSend(
  handle:      in Int,
  fromAddress: in String,
  toAddresses: in slice[String],
  subject:     in String,
  bodyText:    in String,
  bodyHtml:    in String
): Result[Unit, String]
  requires: fromAddress.length > 0
  requires: toAddresses.length > 0
  requires: subject.length > 0
  = ()

@axiom("Lyric.Mail.SmtpHost.close — disposes the underlying SmtpClient and removes the handle from the registry")
@externTarget("Lyric.Mail.SmtpHost.close")
@cfg(feature = "smtp")
pub func close(senderHandle: in Int): Unit = ()

// SES / SendGrid send + close arms remain placeholders until those host
// shims land (#780 follow-up).  Until then, opening an SES or SendGrid
// handle returns Err from the connect arm; there's nothing to dispatch
// to.  Each backend will add its own `smtpSend` / `close` arm here gated
// by its feature when the shim lands.
