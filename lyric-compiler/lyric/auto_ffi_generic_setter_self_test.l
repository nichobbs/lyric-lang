//! auto_ffi_generic_setter_self_test.l — regression test for the auto-FFI
//! DIRECT property-assignment sugar (`o.Prop = value`, no `@externTarget`
//! wrapper) binding a setter whose parameter is a CLOSED generic
//! instantiation over an extern type (#7444, the auto-FFI-sugar half of
//! #6029 left unfixed by D-progress-999's `@externTarget`-wrapper fix).
//!
//! `o.ApplicationProtocols = l` (`l: List<SslApplicationProtocol>`) used to
//! panic at compile time:
//!
//!   Msil.Codegen: property 'System.Net.Security.SslServerAuthenticationOptions
//!   .ApplicationProtocols' has a getter but no accessible setter
//!   (set_ApplicationProtocols) in reference-assembly metadata; it cannot be
//!   assigned. (Msil.Codegen.Program.panicExternSetterUnresolved)
//!
//! Three independent, coordinated gaps in `lyric-compiler/msil/`, all fixed
//! together (a partial fix would have left the resolved setter unreachable
//! or uncallable):
//!
//!   1. `argTyToSig` (`codegen.l`) had no arm for `MGenericInst`/
//!      `MValueTypeGenericInst` — it fell through to `externRefFqn`, which
//!      only handles `MValueTypeRef`/`MClassRef`, so a closed generic
//!      instantiation could never be DESCRIBED as a `SigType` for lookup.
//!      New arms recurse into `typeArgs` via a new `argTyListToSig` helper
//!      and call the already-existing `Mdr.mkNamedGenericInstSig` (added by
//!      an earlier session for the read direction, `resolvedSigToMsil`, but
//!      never used on the write/describe side until now).
//!   2. `Mdr.scoreSigType`'s `STNamedGenericInst` arm (`metadata_reader.l`)
//!      *unconditionally* rejected (-1) any CLOSED generic-instantiation
//!      parameter (only an OPEN one, still wrapping a declaring-type VAR,
//!      scored 0) — a deliberate fix for a real regression (D-progress-934:
//!      an unrelated same-arity BCL overload spuriously tying against the
//!      correct match). This meant even the property's OWN getter-typed
//!      probe in `resolveExternSetterMsil` (which builds a `SigType`
//!      straight from real metadata, no `argTyToSig` involved at all) could
//!      never match the setter's identically-shaped parameter — a textbook
//!      "structurally identical types don't recognize each other" bug. Fixed
//!      with a genuine STRUCTURAL match arm: when `arg` is ALSO a closed
//!      `STNamedGenericInst` of the same head FQN/value-kind/arity with every
//!      type argument an EXACT match (`sigNamedGenericInstArgsExact`, mirroring
//!      `STSzArray`'s own element-invariance handling just above it — CLR
//!      generic type arguments are invariant, so a widening/boxing match on
//!      an argument is not good enough), it scores 3 (exact) — never
//!      touching the D-progress-934 `sigArgsContainOpenGeneric`-gated branch,
//!      which stays byte-for-byte unchanged.
//!   3. `argCoercionInsns` (`codegen.l`) had no arm for a
//!      `STNamedGenericInst` parameter sig either — it fell through the
//!      non-primitive `sigNamedFqn`-based branch (which returns "" for a
//!      generic instantiation) straight to `None`, so even after gaps 1/2 are
//!      fixed and the RIGHT setter is scored and resolved, emitting the
//!      actual call still panicked ("cannot adapt a value of the assigned
//!      type"). Fixed by mirroring `STSzArray`'s own coercion arm just above
//!      it: confirm an exact structural match (score 3) and emit zero
//!      coercion instructions (a value type passes by value, a reference
//!      type by reference, exactly as a plain extern-type argument already
//!      does).
//!
//! `argCoercionInsns` is shared by BOTH the property-setter path
//! (`externSetterCoercion`) and the general auto-FFI method-call argument
//! validator (`autoFfiValidateParams`), so this fix also unblocks an
//! ordinary auto-FFI METHOD call (not just a property setter) that passes a
//! closed generic instantiation as an argument — not exercised by a
//! dedicated case here (no simple real-BCL repro at hand), but worth noting
//! for anyone extending this test.
//!
//! Run by native `lyric test` (compiles in-process through the self-hosted
//! Msil.Bridge and asserts every runtime value). Imports only `Std.*`.
//!
//!   lyric test lyric-compiler/lyric/auto_ffi_generic_setter_self_test.l
@test_module
package Lyric.AutoFfiGenericSetterSelfTest

import Std.Core
import Std.Testing

extern type Opts = "System.Net.Security.SslServerAuthenticationOptions"

extern type ProtoList = "System.Collections.Generic.List`1[System.Net.Security.SslApplicationProtocol]"

extern type Proto = "System.Net.Security.SslApplicationProtocol"

@externTarget("System.Net.Security.SslServerAuthenticationOptions..ctor")
func newOpts(): Opts = ()

@externTarget("System.Collections.Generic.List`1..ctor")
func newProtoList(): ProtoList = ()

@externTarget("System.Net.Security.SslApplicationProtocol..ctor")
func newProto(name: in String): Proto = ()

@externInstance
@externTarget("System.Collections.Generic.List`1[System.Net.Security.SslApplicationProtocol].Add")
func protoListAdd(l: in ProtoList, item: in Proto): Unit = ()

// Explicit-wrapper receiver-position read-back, mirroring
// `generic_extern_param_self_test.l`'s `protoListCount` — already worked
// before this fix (the receiver-position `emitGenericExternMember` path is
// untouched by this issue), used here purely to verify the auto-FFI setter
// actually stored the real list rather than something degenerate.
@externTarget("System.Collections.Generic.List`1[System.Net.Security.SslApplicationProtocol].get_Count")
func protoListCount(l: in ProtoList): Int = ()

test "auto-FFI direct property assignment binds a setter whose parameter is a closed generic instantiation (#7444)" {
  val o = newOpts()
  val l = newProtoList()
  protoListAdd(l, newProto("h2"))
  protoListAdd(l, newProto("http/1.1"))
  // The line that used to panic at compile time (panicExternSetterUnresolved):
  // no @externTarget wrapper for set_ApplicationProtocols anywhere in this file.
  o.ApplicationProtocols = l
  val back = o.ApplicationProtocols
  assertEqualInt(protoListCount(back), 2, "round-tripped ApplicationProtocols keeps both entries")
}
