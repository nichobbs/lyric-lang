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

// ─── SMTP provider (MailKit) ──────────────────────────────────────────────────

@axiom("MailKit SMTP client for .NET")
@cfg(feature = "smtp")
extern package MailKit.Net.Smtp {
  /// Open an authenticated SMTP connection.  Returns an opaque connection handle.
  pub func connect(
    host:      String,
    port:      Int,
    username:  String,
    password:  String,
    useTls:    Bool,
    timeoutMs: Int
  ): Result[Int, String]

  /// Send a message encoded as JSON.  `senderHandle` is the handle returned by connect.
  pub func send(senderHandle: Int, messageJson: String): Result[Unit, String]

  /// Close the SMTP connection and release resources.
  pub func close(senderHandle: Int): Unit
}

// ─── Amazon SES provider ──────────────────────────────────────────────────────

@axiom("Amazon SES SDK for .NET")
@cfg(feature = "ses")
extern package AWSSDK.SimpleEmail {
  /// Initialise an SES client for the given region and credentials.
  /// Pass empty strings for accessKey/secretKey to use the ambient IAM role.
  pub func connect(region: String, accessKey: String, secretKey: String): Result[Int, String]

  /// Send a message encoded as JSON via SES.
  pub func send(senderHandle: Int, messageJson: String): Result[Unit, String]

  /// Release the SES client.
  pub func close(senderHandle: Int): Unit
}

// ─── SendGrid provider ────────────────────────────────────────────────────────

@axiom("SendGrid SDK for .NET")
@cfg(feature = "sendgrid")
extern package SendGrid {
  /// Initialise a SendGrid client with the given API key.
  pub func connect(apiKey: String): Result[Int, String]

  /// Send a message encoded as JSON via SendGrid.
  pub func send(senderHandle: Int, messageJson: String): Result[Unit, String]

  /// Release the SendGrid client.
  pub func close(senderHandle: Int): Unit
}

// ─── Re-exports with `in` mode ────────────────────────────────────────────────

/// Open a MailKit SMTP connection.
@cfg(feature = "smtp")
pub func connectSmtp(
  host:      in String,
  port:      in Int,
  username:  in String,
  password:  in String,
  useTls:    in Bool,
  timeoutMs: in Int
): Result[Int, String] {
  MailKit.Net.Smtp.connect(host, port, username, password, useTls, timeoutMs)
}

/// Open an Amazon SES client.
@cfg(feature = "ses")
pub func connectSes(
  region:    in String,
  accessKey: in String,
  secretKey: in String
): Result[Int, String] {
  AWSSDK.SimpleEmail.connect(region, accessKey, secretKey)
}

/// Open a SendGrid client.
@cfg(feature = "sendgrid")
pub func connectSendGrid(apiKey: in String): Result[Int, String] {
  SendGrid.connect(apiKey)
}

/// Send a JSON-encoded message via the SMTP provider.
@cfg(feature = "smtp")
pub func send(senderHandle: in Int, messageJson: in String): Result[Unit, String] {
  return MailKit.Net.Smtp.send(senderHandle, messageJson)
}

/// Send a JSON-encoded message via Amazon SES.
@cfg(feature = "ses")
pub func send(senderHandle: in Int, messageJson: in String): Result[Unit, String] {
  return AWSSDK.SimpleEmail.send(senderHandle, messageJson)
}

/// Send a JSON-encoded message via SendGrid.
@cfg(feature = "sendgrid")
pub func send(senderHandle: in Int, messageJson: in String): Result[Unit, String] {
  return SendGrid.send(senderHandle, messageJson)
}

/// Release the SMTP provider connection.
@cfg(feature = "smtp")
pub func close(senderHandle: in Int): Unit {
  MailKit.Net.Smtp.close(senderHandle)
}

/// Release the SES provider connection.
@cfg(feature = "ses")
pub func close(senderHandle: in Int): Unit {
  AWSSDK.SimpleEmail.close(senderHandle)
}

/// Release the SendGrid provider connection.
@cfg(feature = "sendgrid")
pub func close(senderHandle: in Int): Unit {
  SendGrid.close(senderHandle)
}
