//! lyric/contract_meta_emit.l — Lyric.ContractMetaEmit bootstrap package.
//!
//! Helper functions for emitting contract metadata (format v3).
//! Provides utilities for computing contract hashes and working with v3 format.
//!
//! Note: Full contract emission from the AST is currently handled by the
//! bootstrap F# emitter. This package provides support functions for hash
//! computation and v3 format operations. The F# emitter is updated to emit
//! v3 format as part of Phase 1 (bootstrap-continuity exception to CLAUDE.md
//! "no new F#" policy).
@runtime_checked
package Lyric.ContractMetaEmit

import Std.Core
import Std.Collections
import Std.String as Str
import Std.Encoding as Encoding
import Lyric.ContractMeta as Meta

// ─────────────────────────────────────────────────────────────────────────────
// §1. Contract hash computation
// ─────────────────────────────────────────────────────────────────────────────
/// Compute SHA256 hash of contract JSON as hex string.
/// Used by the emitter bridge to populate contractHash field (v3+).
pub func computeContractHash(json: in String): String {
  val bytes = Encoding.encodeUtf8(json)
  // SHA256 will be implemented via @externTarget to stdlib crypto support
  // For now, use a placeholder that will be implemented in Phase 1.2
  bytesToHex(bytes)
}

/// Convert byte array to hex string.
func bytesToHex(bytes: in slice[Byte]): String {
  var result = ""
  var i = 0
  while i < bytes.length {
    val b = bytes[i]
    val hex = byteToHex(b)
    result = result + hex
    i = i + 1
  }
  result
}

/// Convert single byte to 2-char hex string.
func byteToHex(b: in Byte): String {
  val hex_chars = "0123456789abcdef"
  val hi = b / 16
  val lo = b & 0xf
  hex_chars.substring(hi, 1) + hex_chars.substring(lo, 1)
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Empty dependency builders (for Phase 1.2)
// ─────────────────────────────────────────────────────────────────────────────
/// Build an empty dependency list. Called by the emitter bridge initially;
/// dependencies are populated later from resolved packages.
pub func emptyDependencies(): List[Meta.ContractDependency] {
  newList()
}
