//! std/_kernel_native/uuid_host.l — native-target UUID kernel.
//!
//! The `--target native` twin of `_kernel/uuid_host.l`, selected by the
//! native source loader by basename.  `Uuid` is represented as its
//! canonical lowercase hyphenated 36-char string (D-N-026): formatting
//! is the identity, parsing wraps input Std.Uuid's shared canonicalizer
//! has already validated and lowercased, and only v4 generation crosses
//! the C boundary — `lyric_uuid_v4` draws 16 bytes from
//! `lyric_secure_random` (getrandom(2) / getentropy), stamps the
//! RFC 4122 version-4 and variant-10 bits, and formats once, in C.
//!
//! Internal: only Std.Uuid should import this.
@axiom("lyric_uuid_v4 conforms to RFC 4122 section 4.4 as documented in lyric_rt.h")
package Std.UuidHost

import Std.Core

pub record Uuid {
  hex: String
}

extern func rtUuidV4(): String = "lyric_uuid_v4"

// Generate a new random (version 4) UUID.
pub func hostNewGuid(): Uuid {
  Uuid(hex = rtUuidV4())
}

// The nil UUID: 00000000-0000-0000-0000-000000000000.
pub func hostEmptyGuid(): Uuid {
  Uuid(hex = "00000000-0000-0000-0000-000000000000")
}

// Format a UUID as the canonical lowercase hyphenated string — the
// representation IS that string, so this is the identity.
pub func hostGuidToString(g: in Uuid): String {
  g.hex
}

// Parse the canonical lowercase hyphenated form produced by Std.Uuid's
// shared canonicalizer (D-N-026): already validated, so wrap directly.
pub func hostParseCanonicalGuid(d: in String): Option[Uuid] {
  Some(value = Uuid(hex = d))
}
