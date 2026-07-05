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
// `substring`, `==`, and `+` — the String surface every backend
// (including native) implements — so this file stays target-neutral.
// Index of `c` in the hex alphabet (either case), or -1.
func uuidHexIndexOf(c: in String): Int {
  val lowers = "0123456789abcdef"
  var i = 0
  while i < 16 {
    if lowers.substring(i, 1) == c {
      return i
    }
    i = i + 1
  }
  val uppers = "ABCDEF"
  var j = 0
  while j < 6 {
    if uppers.substring(j, 1) == c {
      return 10 + j
    }
    j = j + 1
  }
  0 - 1
}

// The canonical lowercase spelling of hex digit `idx` (0..15).
func uuidHexChar(idx: in Int): String {
  "0123456789abcdef".substring(idx, 1)
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
    var acc = ""
    var i = 0
    while i < 36 {
      val c = t.substring(i, 1)
      if i == 8 or i == 13 or i == 18 or i == 23 {
        if c != "-" {
          return None
        }
        acc = acc + "-"
      } else {
        val idx = uuidHexIndexOf(c)
        if idx < 0 {
          return None
        }
        acc = acc + uuidHexChar(idx)
      }
      i = i + 1
    }
    Some(value = acc)
  } else if t.length == 32 {
    var acc = ""
    var i = 0
    while i < 32 {
      if i == 8 or i == 12 or i == 16 or i == 20 {
        acc = acc + "-"
      }
      val idx = uuidHexIndexOf(t.substring(i, 1))
      if idx < 0 {
        return None
      }
      acc = acc + uuidHexChar(idx)
      i = i + 1
    }
    Some(value = acc)
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
