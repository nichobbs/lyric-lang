# 2026-11-07 - TIR builder: extern member calls (D387)

`Lyric.Tir.Build` builds calls to members of `extern type`s as
`XCall(Extern(HostMemberRef), args)` (docs/70 phase 3a, #8613). The new
`ExternIterResolver.resolveMemberSigs` reports every overload of a host member
(MSIL reference-pack metadata and JVM class files); the builder selects the
overload from the argument types, widening where the checker does, and counts
named arguments, ambiguous overloads and unresolvable members as I0002.
`tir_build_self_test.l` is at 63 cases (static, widened, instance, constructor,
named-argument). See D387 for the scope boundary.
