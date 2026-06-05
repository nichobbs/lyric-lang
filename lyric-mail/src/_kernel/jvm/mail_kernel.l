//! Mail.Kernel.Jvm — JVM extern boundary for email-sending providers.
//!
//! JVM implementation of the same contract as Mail.Kernel.Net.  Each provider
//! maps to a JVM-side host helper namespace backed by the corresponding
//! Java email library:
//!   jakarta.mail.Session   — SMTP client via Jakarta Mail  (@cfg feature = "smtp")
//!   software.amazon.awssdk.services.ses — Amazon SES      (@cfg feature = "ses")
//!   com.sendgrid.SendGrid  — SendGrid email API            (@cfg feature = "sendgrid")
//!
//! Each provider exposes three functions: connect (returns an opaque Int handle),
//! send (accepts a JSON-serialised EmailMessage), and close.
//!
//! Message JSON format is identical to the .NET kernel — see Mail.Kernel.Net
//! for the schema.  The public Mail package consumes either kernel without
//! re-shaping.
//!
//! Only active when compiled with feature = "jvm" (Phase 6).
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.
@cfg(feature = "jvm")
package Mail.Kernel.Jvm

// ─── SMTP provider (Jakarta Mail) ────────────────────────────────────────────
@axiom("Jakarta Mail SMTP client for JVM")
@cfg(feature = "smtp")
extern package lyric.mail.SmtpClient {
  /// Open an authenticated SMTP connection.  Returns an opaque connection handle.
  pub func connect(host: String, port: Int, username: String, password: String, useTls: Bool, timeoutMs: Int): Result[Int, String]

  /// Send a message encoded as JSON.  `senderHandle` is the handle returned by connect.
  pub func send(senderHandle: Int, messageJson: String): Result[Unit, String]

  /// Close the SMTP connection and release resources.
  pub func close(senderHandle: Int): Unit
  // ─── Amazon SES provider ──────────────────────────────────────────────────────
}

@axiom("Amazon SES SDK v2 for JVM")
@cfg(feature = "ses")
extern package lyric.mail.SesClient {
  /// Initialise an SES client for the given region and credentials.
  /// Pass empty strings for accessKey/secretKey to use the ambient IAM role.
  pub func connect(region: String, accessKey: String, secretKey: String): Result[Int, String]

  /// Send a message encoded as JSON via SES.
  pub func send(senderHandle: Int, messageJson: String): Result[Unit, String]

  /// Release the SES client.
  pub func close(senderHandle: Int): Unit
  // ─── SendGrid provider ────────────────────────────────────────────────────────
}

@axiom("SendGrid Java SDK for JVM")
@cfg(feature = "sendgrid")
extern package lyric.mail.SendGridClient {
  /// Initialise a SendGrid client with the given API key.
  pub func connect(apiKey: String): Result[Int, String]

  /// Send a message encoded as JSON via SendGrid.
  pub func send(senderHandle: Int, messageJson: String): Result[Unit, String]

  /// Release the SendGrid client.
  pub func close(senderHandle: Int): Unit
  // ─── Re-exports with `in` mode ────────────────────────────────────────────────
}

/// Open a Jakarta Mail SMTP connection.
@cfg(feature = "smtp")
pub func connectSmtp(
  host: in String,
  port: in Int,
  username: in String,
  password: in String,
  useTls: in Bool,
  timeoutMs: in Int,
): Result[Int, String] {
  lyric.mail.SmtpClient.connect(host, port, username, password, useTls, timeoutMs)
}

/// Open an Amazon SES client.
@cfg(feature = "ses")
pub func connectSes(region: in String, accessKey: in String, secretKey: in String): Result[Int, String] {
  lyric.mail.SesClient.connect(region, accessKey, secretKey)
}

/// Open a SendGrid client.
@cfg(feature = "sendgrid")
pub func connectSendGrid(apiKey: in String): Result[Int, String] {
  lyric.mail.SendGridClient.connect(apiKey)
}

/// Send a JSON-encoded message via the SMTP provider.
@cfg(feature = "smtp")
pub func send(senderHandle: in Int, messageJson: in String): Result[Unit, String] {
  return lyric.mail.SmtpClient.send(senderHandle, messageJson)
}

/// Send a JSON-encoded message via Amazon SES.
@cfg(feature = "ses")
pub func send(senderHandle: in Int, messageJson: in String): Result[Unit, String] {
  return lyric.mail.SesClient.send(senderHandle, messageJson)
}

/// Send a JSON-encoded message via SendGrid.
@cfg(feature = "sendgrid")
pub func send(senderHandle: in Int, messageJson: in String): Result[Unit, String] {
  return lyric.mail.SendGridClient.send(senderHandle, messageJson)
}

/// Release the SMTP provider connection.
@cfg(feature = "smtp")
pub func close(senderHandle: in Int): Unit {
  lyric.mail.SmtpClient.close(senderHandle)
}

/// Release the SES provider connection.
@cfg(feature = "ses")
pub func close(senderHandle: in Int): Unit {
  lyric.mail.SesClient.close(senderHandle)
}

/// Release the SendGrid provider connection.
@cfg(feature = "sendgrid")
pub func close(senderHandle: in Int): Unit {
  lyric.mail.SendGridClient.close(senderHandle)
}
