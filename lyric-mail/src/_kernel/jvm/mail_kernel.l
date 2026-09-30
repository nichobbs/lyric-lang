//! Mail.Kernel.Jvm — JVM extern boundary for email-sending providers.
//!
//! JVM counterpart of `Mail.Kernel.Net`. A prior revision of this file
//! declared `extern package lyric.mail.SmtpClient { ... }` (and SES /
//! SendGrid siblings) against a `lyric.mail.*` namespace that does not
//! exist anywhere — no Java class backs it, in this repo or in any
//! published JAR. `extern package` is a confirmed no-op in both the type
//! checker and the MSIL/JVM codegens (it parses but generates no real
//! binding — the same defect documented in `Auth.Kernel.Jvm`'s header for
//! the `extern package io.jsonwebtoken { ... }` it replaced), so calling
//! any of those functions would either do nothing or crash with
//! `NoClassDefFoundError`/`ClassNotFoundException` at runtime — dead,
//! silently-unsafe code with zero callers (`mail.l` never reached this
//! kernel at all before #7254).
//!
//! This rewrite drops the dead `extern package` declarations and reports
//! each provider honestly as not yet implemented on this target — the
//! same maturity level `Mail.connectSes`/`Mail.connectSendGrid` already
//! report on `--target dotnet` (Amazon SES / SendGrid backends are
//! placeholders on both targets; only SMTP is real, and only on
//! `--target dotnet`). `mail.l`'s `connectSmtp` now calls into
//! `connectSmtp` below under `@cfg(feature = "jvm")`, so this kernel is
//! genuinely reachable rather than dead code — it just has nothing real
//! to do yet.
//!
//! A real Jakarta Mail SMTP client here needs a genuine JVM auto-FFI
//! kernel (`extern type` bindings to `jakarta.mail.Session` /
//! `jakarta.mail.Transport` / `jakarta.mail.internet.MimeMessage`,
//! resolved against a real Maven-supplied JAR — the same idiom
//! `Auth.Kernel.Jvm.hmacSha256` already uses for `javax.crypto.Mac`), not
//! a `lyric.mail.*` declarative stub.  Tracked in #7462; not
//! attempted here to avoid shipping an unverified, untested SMTP
//! integration under a "wired" label.
//!
//! Only active when compiled with feature = "jvm" (Phase 6).
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.
@cfg(feature = "jvm")
@io
package Mail.Kernel.Jvm

import Std.Core

/// Open a JVM SMTP connection.  Not yet implemented — see the module
/// header. `host`/`port`/`username`/`password`/`useTls`/`timeoutMs` are
/// accepted (not `_`-discarded) to keep the signature identical to
/// `Mail.Kernel.Net`'s once a real Jakarta Mail binding lands.
@axiom("JVM SMTP backend not yet implemented — see module header")
@cfg(feature = "smtp")
pub func connectSmtp(
  host: in String,
  port: in Int,
  username: in String,
  password: in String,
  useTls: in Bool,
  timeoutMs: in Int,
): Result[Int, String] {
  Err("lyric-mail: JVM SMTP backend not yet implemented (#7462)")
}

/// Send a JSON-encoded message via the SMTP provider.  Not yet
/// implemented — see the module header.
@axiom("JVM SMTP backend not yet implemented — see module header")
@cfg(feature = "smtp")
pub func send(senderHandle: in Int, messageJson: in String): Result[Unit, String] {
  Err("lyric-mail: JVM SMTP backend not yet implemented (#7462)")
}

/// Release the SMTP provider connection.  A no-op: `connectSmtp` never
/// hands out a real handle on this target, so there is nothing to
/// release.
@axiom("JVM SMTP backend not yet implemented — see module header")
@cfg(feature = "smtp")
pub func close(senderHandle: in Int): Unit {
  ()
}
