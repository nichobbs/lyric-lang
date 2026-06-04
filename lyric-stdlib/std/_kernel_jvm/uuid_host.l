//! std/_kernel_jvm/uuid_host.l — JVM host boundary for java.util.UUID.
//!
//! Mirrors _kernel/uuid_host.l.  Three of the four operations require
//! lyric.stdlib.jvm.UuidHost shims because the JVM API differs:
//!
//!   hostEmptyGuid    — java.util.UUID has no "Empty" constant; shim
//!                      returns new UUID(0L, 0L).
//!   hostGuidToString — UUID.toString() uses lowercase hyphens (same
//!                      canonical form as .NET), but the JVM method
//!                      dispatch path needs a shim for the extern shape.
//!   hostTryParseGuid — UUID.fromString(string) throws
//!                      IllegalArgumentException on bad input; shim wraps
//!                      it in a try/catch and returns Bool+out.
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

// Shim: new UUID(0L, 0L).
@externTarget("lyric.stdlib.jvm.UuidHost.emptyUuid")
pub func hostEmptyGuid(): Uuid = ()

// Shim: wraps UUID.toString() for the extern dispatch shape.
@externTarget("lyric.stdlib.jvm.UuidHost.guidToString")
pub func hostGuidToString(g: in Uuid): String = ()

// Shim: UUID.fromString(s) wrapped in try/catch.
@externTarget("lyric.stdlib.jvm.UuidHost.tryParse")
pub func hostTryParseGuid(s: in String, value: out Uuid): Bool = ()
