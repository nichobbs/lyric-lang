//! std/uuid.l - UUID (Universally Unique Identifier) generation and parsing.
//!
//! `Uuid` is a thin wrapper over the target's UUID kernel (`System.Guid`
//! on .NET, `java.util.UUID` on the JVM, the canonical string form over
//! lyric-rt on native — D-N-026), storing a 128-bit value formatted as
//! the standard 32-hex-digit hyphenated string
//! ("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx").
//!
//! `newUuid()` generates a version 4 (random) UUID from the target's
//! cryptographic RNG.  `nilUuid()` returns the all-zeros sentinel.
//!
//! `parseUuidOpt` accepts the same four formats on every target —
//! validated and canonicalized here in shared code, so each kernel only
//! ever sees the canonical lowercase hyphenated form (D-N-026):
//!   "D" — hyphenated 32 hex digits (default)
//!   "N" — 32 hex digits without hyphens
//!   "B" — hyphenated, braces-wrapped
//!   "P" — hyphenated, parentheses-wrapped
//! Hex digits may be either case; leading/trailing ASCII whitespace is
//! tolerated.  The .NET-only exotic "X" form
//! ("{0x..,0x..,..,{0x..,..}}") is intentionally not part of the
//! cross-target surface.
package Std.Uuid

import Std.Core
import Std.String
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
// The canonicalizer below deliberately restricts itself to `length`,
// `substring`, `==`, and `Std.String`'s ordinal search and builder, the
// String surface every backend (including native) implements, so this file
// stays target-neutral. Each position costs one single-character substring
// and one search, and the result is built once (#7284).
// The canonical lowercase spelling of hex digit `c` (either case), or ""
// when `c` is not a hex digit.
func uuidHexCanonical(c: in String): String {
  if indexOfFromRaw("0123456789abcdef", c, 0) >= 0 {
    c
  } else {
    val j = indexOfFromRaw("ABCDEF", c, 0)
    if j >= 0 {
      "abcdef".substring(j, 1)
    } else {
      ""
    }
  }
}

func uuidIsSpace(c: in String): Bool {
  c == " " or c == "\t" or c == "\r" or c == "\n"
}

func uuidTrim(s: in String): String {
  var start = 0
  var stop = s.length
  while start < stop and uuidIsSpace(s.substring(start, 1)) {
    start = start + 1
  }
  while stop > start and uuidIsSpace(s.substring(stop - 1, 1)) {
    stop = stop - 1
  }
  s.substring(start, stop - start)
}

/// Validate one of the four accepted formats and rewrite it to the
/// canonical lowercase hyphenated "D" form, or None if malformed.
func uuidCanonicalize(s: in String): Option[String] {
  var t = uuidTrim(s)
  // The "B"/"P" wrappers are defined around the HYPHENATED form only
  // (matching .NET's format definitions): a braced/parenthesized bare
  // 32-hex string is rejected below, not silently accepted (#5199).
  var wrapped = false
  if t.length >= 2 {
    val first = t.substring(0, 1)
    val last = t.substring(t.length - 1, 1)
    if first == "{" and last == "}" {
      t = t.substring(1, t.length - 2)
      wrapped = true
    } else if first == "(" and last == ")" {
      t = t.substring(1, t.length - 2)
      wrapped = true
    }
  }
  if t.length == 32 and wrapped {
    return None
  }
  if t.length == 36 {
    val acc = StringBuilder.new()
    var i = 0
    while i < 36 {
      val c = t.substring(i, 1)
      if i == 8 or i == 13 or i == 18 or i == 23 {
        if c != "-" {
          return None
        }
        acc.append("-")
      } else {
        val h = uuidHexCanonical(c)
        if h.length == 0 {
          return None
        }
        acc.append(h)
      }
      i = i + 1
    }
    Some(value = acc.toString())
  } else if t.length == 32 {
    val acc = StringBuilder.new()
    var i = 0
    while i < 32 {
      if i == 8 or i == 12 or i == 16 or i == 20 {
        acc.append("-")
      }
      val h = uuidHexCanonical(t.substring(i, 1))
      if h.length == 0 {
        return None
      }
      acc.append(h)
      i = i + 1
    }
    Some(value = acc.toString())
  } else {
    None
  }
}

/// Parse a UUID from a string.  Accepts the hyphenated, no-hyphens,
/// brace-wrapped, and parentheses-wrapped forms ("D"/"N"/"B"/"P"),
/// either hex case, with leading/trailing ASCII whitespace tolerated —
/// uniformly on every target (D-N-026).  Returns `None` for any
/// unrecognised or malformed input.
@stable(since = "1.0")
pub func parseUuidOpt(s: in String): Option[Uuid] {
  match uuidCanonicalize(s) {
    case Some(d) -> hostParseCanonicalGuid(d)
    case None -> None
  }
}
