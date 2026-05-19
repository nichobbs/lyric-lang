// Mail.Kernel.Net — extern boundary for email-sending providers.
//
// Bridges Lyric's Mail package to .NET email libraries:
//   MailKit.Net.Smtp  — SMTP client via MailKit  (@cfg feature = "smtp")
//   AWSSDK.SimpleEmail — Amazon SES             (@cfg feature = "ses")
//   SendGrid           — SendGrid email API      (@cfg feature = "sendgrid")
//
// Each provider exposes three functions: connect (returns an opaque Int handle),
// send (accepts a JSON-serialised EmailMessage), and close.
//
// Kernel functions are declared without feature gates so they are always
// available for type-checking.  The factory functions in Mail.l are
// @cfg-gated to activate only the selected provider.
//
// Message JSON format (produced by Mail.serialiseMessage):
//   {
//     "from":        {"address": "...", "displayName": "..."},
//     "to":          [{"address": "...", "displayName": "..."}, ...],
//     "cc":          [...],
//     "bcc":         [...],
//     "subject":     "...",
//     "textBody":    "...",
//     "htmlBody":    "...",
//     "attachments": [{"filename": "...", "contentType": "...", "dataBase64": "..."}, ...],
//     "replyTo":     {"address": "...", "displayName": "..."} | null
//   }
//
// See docs/14-native-stdlib-plan.md for the kernel boundary contract.

package Mail.Kernel.Net

import Std.Core

// ─── SMTP provider (MailKit) ──────────────────────────────────────────────────

/// Open an authenticated SMTP connection.  Returns an opaque connection handle.
@axiom("MailKit SMTP client for .NET")
pub func connectSmtp(
  host:      in String,
  port:      in Int,
  username:  in String,
  password:  in String,
  useTls:    in Bool,
  timeoutMs: in Int
): Result[Int, String] = Err("")

// ─── Amazon SES provider ──────────────────────────────────────────────────────

/// Initialise an SES client for the given region and credentials.
/// Pass empty strings for accessKey/secretKey to use the ambient IAM role.
@axiom("Amazon SES SDK for .NET")
pub func connectSes(region: in String, accessKey: in String, secretKey: in String): Result[Int, String] = Err("")

// ─── SendGrid provider ────────────────────────────────────────────────────────

/// Initialise a SendGrid client with the given API key.
@axiom("SendGrid SDK for .NET")
pub func connectSendGrid(apiKey: in String): Result[Int, String] = Err("")

// ─── Shared send / close (dispatch by feature at call site) ──────────────────

/// Send a message encoded as JSON via the active provider.
@axiom("Mail provider send operation for .NET")
pub func send(senderHandle: in Int, messageJson: in String): Result[Unit, String] = Ok(())

/// Release the active provider connection.
@axiom("Mail provider close operation for .NET")
pub func close(senderHandle: in Int): Unit = ()
