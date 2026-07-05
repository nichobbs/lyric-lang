//! std/_kernel_jvm/uuid_host.l — JVM host boundary for java.util.UUID.
//!
//! Mirrors _kernel/uuid_host.l.  Pure Lyric over the JVM auto-FFI — the
//! previous version routed three of the four operations through a phantom
//! `lyric.stdlib.jvm.UuidHost` class that never existed at runtime (same
//! elimination as the file/console/math kernel rewrites, D-progress-555):
//!
//!   hostEmptyGuid    — java.util.UUID has no "Empty" constant;
//!                      `UUID(0L, 0L)` via the auto-FFI constructor.
//!   hostGuidToString — `UUID.toString()` (lowercase-hyphenated, the same
//!                      canonical form as .NET).
//!
//! `hostParseCanonicalGuid` is the exception-free Option seam all three
//! kernel twins implement (D-N-026): Std.Uuid's shared canonicalizer
//! validates the four cross-target formats ("D"/"N"/"B"/"P") and hands
//! every twin the canonical lowercase hyphenated form, so the
//! `UUID.fromString` call here only ever sees "D"-form input — which
//! also retires this twin's historical divergence (fromString never
//! accepted the "N"/"B"/"P" spellings .NET's TryParse did; now the
//! shared canonicalizer handles them for every target).  fromString
//! throws IllegalArgumentException (a RuntimeException, catchable as
//! Bug) on malformed input, absorbed into the None arm.
//!
//! `hostNewGuid` maps directly to java.util.UUID.randomUUID().
//!
//! Internal: only Std.Uuid should import this.
@axiom("java.util.UUID conforms to its documented JVM contract")
package Std.UuidHost

import Std.Core

extern type Uuid = "java.util.UUID"

// java.util.UUID.randomUUID() — direct static method, no shim needed.
@externTarget("java.util.UUID.randomUUID")
pub func hostNewGuid(): Uuid = ()

// java.util.UUID has no "Empty" constant: construct the all-zero UUID.
pub func hostEmptyGuid(): Uuid {
  Uuid.new(0, 0)
}

pub func hostGuidToString(g: in Uuid): String {
  g.toString()
}

// Parse the canonical lowercase hyphenated form produced by Std.Uuid's
// shared canonicalizer (D-N-026).
pub func hostParseCanonicalGuid(d: in String): Option[Uuid] {
  try {
    Some(value = Uuid.fromString(d))
  } catch Bug as b {
    None
  }
}
