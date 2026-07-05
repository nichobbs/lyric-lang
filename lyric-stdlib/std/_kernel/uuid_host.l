//! std/_kernel/uuid_host.l — host boundary for System.Guid (UUID).
//!
//! `Uuid` is a thin alias over `System.Guid`.  The operations below
//! cover the full lifecycle: generation, the nil/empty sentinel, string
//! formatting, and round-trip parsing.
//!
//! `hostGuidToString` routes to the instance `System.Guid.ToString()` call
//! which produces the canonical lowercase hyphenated form
//! "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx".
//!
//! `hostParseCanonicalGuid` is the exception-free Option seam all three
//! kernel twins implement (D-N-026): Std.Uuid's shared canonicalizer
//! validates the four cross-target formats ("D"/"N"/"B"/"P") and hands
//! every twin the canonical lowercase hyphenated form, so the
//! `Guid.TryParse` call here only ever sees "D"-form input (the
//! .NET-only "X" form is intentionally no longer reachable).  The
//! Bool+out `hostTryParseGuid` extern stays as this twin's private
//! bridge to TryParse — the native backend cannot express out params,
//! which is why the shared surface routes through the Option seam.
//!
//! Internal: only Std.Uuid should import this.
@axiom("System.Guid conforms to its documented .NET contract")
package Std.UuidHost

import Std.Core

extern type Uuid = "System.Guid"

// Generate a new random (version 4) UUID.
@externTarget("System.Guid.NewGuid")
pub func hostNewGuid(): Uuid = ()

// The nil UUID: 00000000-0000-0000-0000-000000000000.
@externTarget("System.Guid.Empty")
pub func hostEmptyGuid(): Uuid = ()

// Format a UUID as the canonical lowercase hyphenated string.
@externTarget("System.Guid.ToString")
pub func hostGuidToString(g: in Uuid): String = ()

// The out-param bridge to Guid.TryParse; only hostParseCanonicalGuid
// below should call it.
@externTarget("System.Guid.TryParse")
pub func hostTryParseGuid(s: in String, value: out Uuid): Bool = ()

// Parse the canonical lowercase hyphenated form produced by Std.Uuid's
// shared canonicalizer (D-N-026).
pub func hostParseCanonicalGuid(d: in String): Option[Uuid] {
  var v: Uuid = default()
  if hostTryParseGuid(d, v) {
    Some(value = v)
  } else {
    None
  }
}
