//! generic_extern_param_self_test.l — regression test for a bracket-suffixed
//! extern-type-alias used as a PARAMETER or RETURN type of an unrelated
//! (non-generic-declaring) `@externTarget` member (#6029 Gap A/C).
//!
//! `Msil.Codegen.typeExprToMsilCtx`'s `TRef` branch erases any bracket-
//! suffixed extern-type alias (a closed generic instantiation such as
//! `List`1[SomeValueType]`) to `MObject`.  That erasure is correct when the
//! alias is the RECEIVER of its own generic-declaring-type member call:
//! `emitGenericExternMember` (see `generic_extern_self_test.l`) routes around
//! it entirely, re-deriving the real TypeSpec from the `@externTarget` target
//! string itself.  It is wrong when the SAME alias is a PARAMETER or RETURN
//! type of an unrelated method's own signature — `emitGenericExternMember`
//! never runs for that call at all, so the erased `MObject` flowed straight
//! into the MemberRef signature and the call could never bind.  Confirmed
//! against a real BCL API (#6029): `SslServerAuthenticationOptions.
//! set_ApplicationProtocols(List<SslApplicationProtocol>)` compiled clean but
//! threw `MissingMethodException` at run time, because the setter's own
//! parameter degraded to `System.Object`.
//!
//! `externTargetBracketGenericInstMsil` (`Msil.Codegen`) recovers the real
//! closed `MGenericInst`/`MValueTypeGenericInst` for exactly this shape,
//! scoped to `@externTarget` parameter/return positions so the general
//! erasure convention every other caller relies on is untouched.  As a side
//! effect this also closes #6029 Gap C (a ctor's own `@externTarget` string
//! carrying no bracket suffix): `emitGenericExternMember`'s existing
//! `r.isCtor` branch already infers the real type arguments from the Lyric-
//! declared return type when it resolves to a matching `MGenericInst` — it
//! just never received one before this fix, since the return type was always
//! the `MObject` erasure.  `argFqnToMsil` is also fixed here to tag a
//! non-primitive VALUE-TYPE argument (`SslApplicationProtocol`, a struct) as
//! `MValueTypeRef` rather than unconditionally `MClassRef`: a GENERICINST
//! type argument's own CLASS/VALUETYPE tag must match its real CLR kind
//! (ECMA-335 §II.23.2.12), and this bug pre-dates and is independent of the
//! erasure fix above (it affects any bracket-suffixed extern-type alias whose
//! own type argument is a struct, in any position).
//!
//! Run by native `lyric test` (compiles in-process through the self-hosted
//! Msil.Bridge and asserts every runtime value).  Imports only `Std.*`.
//!
//!   lyric test lyric-compiler/lyric/generic_extern_param_self_test.l
@test_module
package Lyric.GenericExternParamSelfTest

import Std.Core
import Std.Testing

extern type Opts = "System.Net.Security.SslServerAuthenticationOptions"

extern type ProtoList = "System.Collections.Generic.List`1[System.Net.Security.SslApplicationProtocol]"

@externTarget("System.Net.Security.SslServerAuthenticationOptions..ctor")
func newOpts(): Opts = ()

// No bracket suffix on the ctor target string itself (the exact shape #6029
// reported): the real `List<SslApplicationProtocol>` type argument must be
// inferred from the declared return type `ProtoList` (Gap C).
@externTarget("System.Collections.Generic.List`1..ctor")
func newProtoList(): ProtoList = ()

@externInstance
@externTarget("System.Net.Security.SslServerAuthenticationOptions.set_ApplicationProtocols")
func setProtos(o: in Opts, l: in ProtoList): Unit = ()

@externInstance
@externTarget("System.Net.Security.SslServerAuthenticationOptions.get_ApplicationProtocols")
func getProtos(o: in Opts): ProtoList = ()

@externTarget("System.Collections.Generic.List`1[System.Net.Security.SslApplicationProtocol].get_Count")
func protoListCount(l: in ProtoList): Int = ()

test "generic-collection-of-extern-value-type parameter binds on a non-generic-declaring-type setter (#6029)" {
  val o = newOpts()
  val l = newProtoList()
  setProtos(o, l)
  val back = getProtos(o)
  assertEqualInt(protoListCount(back), 0, "round-tripped ApplicationProtocols starts empty")
}
