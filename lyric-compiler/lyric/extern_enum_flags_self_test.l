//! extern_enum_flags_self_test.l — regression test for bitwise composition
//! of a real BCL `[Flags]` enum reached through `extern type` (no
//! `@externTarget` wrapper).
//!
//! An extern enum constant (`X509KeyStorageFlags.EphemeralKeySet`) already
//! resolves to a real, correctly-typed value via the auto-FFI static-member
//! read (`Mdr.isEnumType` + the Constant-table decode, docs/42 §5's 2026-07
//! status update): the constant is typed as the enum's own `MValueTypeRef`,
//! not a bare `Int`. This test closes the next gap the codebase's own
//! research flagged as unverified: composing two such constants with
//! Lyric's bitwise methods (`.and`/`.or`, #1610).
//!
//! Those methods are dispatched purely by member name in
//! `Msil.Codegen.lowerMethodCallMsil` (`codegen.l`'s `"and"`/`"or"`/`"xor"`/
//! `"shl"`/`"shr"` arm) with NO receiver-type gate — it pushes the argument,
//! emits the CIL `and`/`or`/... opcode (which operates on whatever integral
//! value already sits on the stack, exactly the same for an enum as for a
//! bare `Int`), and returns `recvTy` unchanged. A `MValueTypeRef` receiver
//! first probes the metadata-based instance-auto-FFI dispatch
//! (`tryInstanceAutoFfiFromMetadata`, docs/42 Phase 3c step 4b) for a REAL
//! CLR instance method named `and`/`or`; an enum has none, so that probe
//! misses, the receiver's address is dropped and its VALUE reloaded, and
//! codegen falls through to the generic bitwise arm exactly as it does for
//! `Int`/`Long`. So this test is confirming an already-shipped codegen
//! path composes correctly, not adding new codegen — no `codegen.l` change
//! was needed. `System.Convert.ToInt32(object)` is used as the oracle to
//! read the underlying `Int32` back out (an enum value boxes into `object`
//! like any other value type, docs/59 §6's boxing fix), since Lyric has no
//! direct enum-to-Int cast.
//!
//! `.NET`-only: `[Flags]` enums are a C#/BCL idiom with no JVM equivalent
//! (the JDK's own flag-shaped constants — e.g. `java.util.zip.Deflater`'s
//! levels — are plain `int`s, which already pass through `Int` with no
//! special handling needed), so there is nothing to port for JVM parity.
@test_module
package Lyric.ExternEnumFlagsSelfTest

import Std.Core
import Std.Testing

extern type KeyStorageFlags = "System.Security.Cryptography.X509Certificates.X509KeyStorageFlags"

extern type Convert = "System.Convert"

test "a single extern enum constant reads back its real underlying value" {
  assertEqualInt(Convert.ToInt32(KeyStorageFlags.DefaultKeySet), 0, "DefaultKeySet")
  assertEqualInt(Convert.ToInt32(KeyStorageFlags.UserKeySet), 1, "UserKeySet")
  assertEqualInt(Convert.ToInt32(KeyStorageFlags.MachineKeySet), 2, "MachineKeySet")
  assertEqualInt(Convert.ToInt32(KeyStorageFlags.Exportable), 4, "Exportable")
  assertEqualInt(Convert.ToInt32(KeyStorageFlags.EphemeralKeySet), 32, "EphemeralKeySet")
}

test ".or composes two extern enum flags into their combined bit pattern" {
  val combined = KeyStorageFlags.EphemeralKeySet.or(KeyStorageFlags.Exportable)
  assertEqualInt(Convert.ToInt32(combined), 36, "EphemeralKeySet | Exportable == 32 | 4")
}

test ".or composes three extern enum flags regardless of grouping order" {
  val ab = KeyStorageFlags.UserKeySet.or(KeyStorageFlags.Exportable)
  val abc = ab.or(KeyStorageFlags.PersistKeySet)
  assertEqualInt(Convert.ToInt32(abc), 21, "UserKeySet | Exportable | PersistKeySet == 1 | 4 | 16")

  // Same three flags, different starting pair and order -- demonstrates the
  // result doesn't depend on which two get OR'd together first.
  val pu = KeyStorageFlags.PersistKeySet.or(KeyStorageFlags.UserKeySet)
  val pue = pu.or(KeyStorageFlags.Exportable)
  assertEqualInt(Convert.ToInt32(pue), 21, "PersistKeySet | UserKeySet | Exportable == 21 (different grouping)")
}

test ".and isolates a set bit out of a combined extern enum value" {
  val combined = KeyStorageFlags.EphemeralKeySet.or(KeyStorageFlags.Exportable)
  assertEqualInt(Convert.ToInt32(combined.and(KeyStorageFlags.Exportable)), 4, "combined & Exportable is set")
  assertEqualInt(Convert.ToInt32(combined.and(KeyStorageFlags.MachineKeySet)), 0, "combined & MachineKeySet is unset")
}

test ".xor toggles a bit in an extern enum value" {
  val combined = KeyStorageFlags.EphemeralKeySet.or(KeyStorageFlags.Exportable)
  assertEqualInt(
    Convert.ToInt32(combined.xor(KeyStorageFlags.Exportable)),
    32,
    "toggling off Exportable leaves EphemeralKeySet"
  )
}

// `.shl`/`.shr` have no real-world use on a `[Flags]` enum (you shift bit
// *positions*, not named flag values), but they share the exact same
// name-only codegen dispatch as `.and`/`.or`/`.xor` (this file's header),
// so covering them here closes that claim's last gap. The shifted results
// are deliberately chosen to land on other real named constants of the
// same enum, not arbitrary numbers.
test ".shl and .shr shift an extern enum value's bit pattern" {
  assertEqualInt(Convert.ToInt32(KeyStorageFlags.UserKeySet.shl(2)), 4, "UserKeySet << 2 == Exportable's value")
  assertEqualInt(
    Convert.ToInt32(KeyStorageFlags.EphemeralKeySet.shr(1)),
    16,
    "EphemeralKeySet >> 1 == PersistKeySet's value"
  )
}
