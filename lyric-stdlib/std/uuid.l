//! std/uuid.l - UUID (Universally Unique Identifier) generation and parsing.
//!
//! `Uuid` is a thin alias over `System.Guid`, which stores a 128-bit value
//! and formats it as the standard 32-hex-digit hyphenated string
//! ("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx").
//!
//! `newUuid()` generates a version 4 (random) UUID using the BCL's
//! cryptographically-seeded `Guid.NewGuid()`.  `nilUuid()` returns the
//! all-zeros sentinel.
//!
//! `parseUuidOpt` accepts all formats that `System.Guid.TryParse` recognises:
//!   "D" — hyphenated 32 hex digits (default)
//!   "N" — 32 hex digits without hyphens
//!   "B" — hyphenated, braces-wrapped
//!   "P" — hyphenated, parentheses-wrapped
package Std.Uuid

import Std.Core
import Std.UuidHost

// =====================================================================
// Construction.
// =====================================================================
/// Generate a new random (version 4) UUID using a cryptographic RNG.
/// Each call returns a distinct value with overwhelming probability.
@stable(since = "1.0")
pub func newUuid(): Uuid {
  hostNewGuid()
}

/// The nil UUID — all 128 bits are zero.
/// Canonical string form: "00000000-0000-0000-0000-000000000000".
@stable(since = "1.0")
pub func nilUuid(): Uuid {
  hostEmptyGuid()
}

// =====================================================================
// Formatting.
// =====================================================================
/// Format `u` as the canonical lowercase hyphenated string.
/// Example: "550e8400-e29b-41d4-a716-446655440000".
@stable(since = "1.0")
pub func uuidToString(u: in Uuid): String {
  hostGuidToString(u)
}

// =====================================================================
// Parsing.
// =====================================================================
/// Parse a UUID from a string.  Accepts any format that `System.Guid.TryParse`
/// recognises (hyphenated, no-hyphens, brace-wrapped, parentheses-wrapped).
/// Returns `None` for any unrecognised or malformed input.
@stable(since = "1.0")
pub func parseUuidOpt(s: in String): Option[Uuid] {
  var v: Uuid = default()
  if hostTryParseGuid(s, v) {
    Some(value = v)
  } else {
    None
  }
}
