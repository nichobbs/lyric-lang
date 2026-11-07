# D387 - The builder's extern member calls (docs/70 phase 3a, #8613)

**Status:** shipped (`buildExternCall` in `build_expr.l`); extends D365 and D389.

## Context

A call to a member of an `extern type` (`Math.Max(a, b)`, `sb.IndexOf("x")`,
`SB.new()`) was an I0002 ("an extern call"). The checker recorded an
`ExternCallSite` (host type, receiver type arguments, member name, argument
count; D365) but `Callee.Extern` needs a `HostMemberRef`: the owner, the member
kind, whether it is static and the parameter and result types of the one
overload the call binds. `ExternIterResolver.resolveMember` answers only the
result type, and only when every overload of that arity agrees.

## Decision

1. `ExternIterResolver.resolveMemberSigs(clrName, member, argc, isProperty)`
   returns every candidate overload as an `ExternMemberSig` (static flag,
   parameters as `ExternIterElem`s, result), looked up on the type and its
   supertypes; `new` is the type's own constructors. Implemented over the MSIL
   metadata reader (`Msil.MetadataReader.hostMemberSigsOfExtern`) and the JVM
   class reader (`Jvm.AutoFfi.hostMemberSigDescsOfExternJvm`). It answers None
   when a type is not located or a candidate is a generic method.
2. `buildExternCall` turns each candidate's parameters into `Ty`s (a host class
   the argument already names keeps the argument's own `HostTypeRef`; a host
   string takes `String` for a `String` argument) and picks the overload the
   argument types fit: 2 points per exact argument, 1 per implicit widening.
   Equal best scores that differ in parameters, or no fit, are counted I0002;
   an overload inherited unchanged from a supertype is not a tie.
3. The call is `XCall(Extern(member), args)`. An instance member takes its
   receiver as the first argument and the first parameter (so the verifier's
   arity rule needs no special case); the receiver must be the host type itself.
   A constructor is a static member named `new` of kind `HMConstructor` whose
   result is the call's type. Arguments are positional only.
4. Not built yet, counted: named arguments, property and field reads (member
   access), generic host methods, array/pointer/by-reference parameters (the
   resolver reports them as a host name that matches no Lyric type), and a
   receiver of a host subtype or a Lyric-side extern alias of another host
   type. A call whose overloads disagree on the result is still untyped by the
   checker (`tyErrorHost`), so it never reaches the builder; typing such a call
   from the selected overload is the follow-up that lets the census reach zero
   for host calls.
