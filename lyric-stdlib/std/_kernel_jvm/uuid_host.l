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
//!   hostTryParseGuid — `UUID.fromString(s)` throws
//!                      IllegalArgumentException on bad input; wrapped in
//!                      `try { … } catch Bug` for the Bool+out shape.
//!
//! `hostNewGuid` maps directly to java.util.UUID.randomUUID().
//!
//! Internal: only Std.Uuid should import this.
@axiom("java.util.UUID conforms to its documented JVM contract")
package Std.UuidHost

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

// `UUID.fromString` throws IllegalArgumentException (a RuntimeException,
// catchable as Bug) on malformed input.
pub func hostTryParseGuid(s: in String, value: out Uuid): Bool {
  try {
    value = Uuid.fromString(s)
    true
  } catch Bug as b {
    value = hostEmptyGuid()
    false
  }
}
