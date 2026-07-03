//! std/_kernel_jvm/parse_host.l - JVM host boundary for primitive parsing.
//!
//! Pure Lyric over the JDK — no `lyric.stdlib.jvm.*` shim classes (the
//! previous version routed through a `lyric.stdlib.jvm.ParseHost` class
//! that never existed at runtime; same elimination as the D-progress-543 /
//! D-progress-555 / D-progress-558 kernel rewrites).  Int and Long parsing
//! are pure Lyric in stdlib/std/parse.l; only Double and Bool cross the
//! boundary here, on the same target-neutral two-argument surface the
//! .NET twin exports.
//!
//! Platform-parity notes vs the .NET kernel's invariant-culture
//! `Double.TryParse(NumberStyles.Float)`:
//!
//!   - `Double.parseDouble` additionally accepts hexadecimal floats
//!     ("0x1p3") and trailing type suffixes ("1.5f", "2d"); both are
//!     rejected here before the JDK call so a string that fails to parse
//!     on .NET also fails on the JVM.
//!   - Both accept "Infinity" / "-Infinity" / "NaN" and leading/trailing
//!     whitespace.
//!
//! Internal: only Std.Parse should import this.
@axiom("java.lang.Double.parseDouble conforms to its documented JVM contract")
package Std.ParseHost

import Std.Core
import Std.String as Str

extern type JDouble = "java.lang.Double"

pub func hostTryParseDouble(s: in String, value: out Double): Bool {
  // Assigned up front: T0086 requires the `out` param written on every
  // path, and the checker does not track assignments through try/catch
  // arms.
  value = 0.0
  val t = Str.trim(s)
  if t.length == 0 {
    return false
  }
  // Reject JDK-only forms the .NET parser refuses: hex floats and
  // trailing type suffixes (but keep "Infinity"/"NaN", whose letters
  // would otherwise trip the suffix check).
  if Str.contains(t, "x") or Str.contains(t, "X") {
    return false
  }
  val last = t[t.length - 1]
  if last == 'd' or last == 'D' or last == 'f' or last == 'F' {
    return false
  }
  try {
    value = JDouble.parseDouble(t)
    true
  } catch Bug as _ {
    false
  }
}

/// Trims and matches "true"/"false" case-insensitively — the documented
/// `System.Boolean.TryParse` behaviour.
pub func hostTryParseBool(s: in String, value: out Bool): Bool {
  value = false
  val t = Str.toLower(Str.trim(s))
  if t == "true" {
    value = true
    true
  } else if t == "false" {
    true
  } else {
    false
  }
}
