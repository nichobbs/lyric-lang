# 2026-10-31: MSIL lambda parameters typed as in-bundle generics are cast to the closed instantiation (#8349)

A lambda parameter typed `Box[Int]` or `Either[Int, String]` (an in-bundle generic
record or union) arrives as `object` under the uniform `Func` ABI. The slice half
of #8349 was fixed in #8469 (a slice is converted to `T[]` at each read). The
generic half was left uncast, so every typed consumer of the parameter (a typed
local, a typed call argument, `==`, a captured read) put an `object` where
`Box<int32>` was expected: ilverify reported `found ref 'object', expected ref
'Box`1<int32>'`.

Root cause: `narrowBoxedParamMsil` / `boxedParamNarrowIsNoopMsil` treated every
`MGenericInstByName` (the by-name form in-bundle generics use) as "no verifiable
narrowing" because an erased `Box<object>` construction could not be cast
(#7755). That reasoning applies to values built with no type information (a bare
`None`); the arguments of a call to a lambda are built against the lambda's
declared parameter types, so they are the closed instantiation.

Fix (`lyric-compiler/msil/codegen.l`): `narrowBoxedParamMsil` emits
`castclass` to the closed instantiation for a non-delegate `MGenericInstByName`,
and `boxedParamNarrowIsNoopMsil` no longer reports it as un-narrowable, so a
captured parameter is stored in a typed closure field. Delegates keep their
existing path. The JVM needs no change: generics erase to the raw class, and the
JVM already checkcasts the parameter to it (the new test passes on both targets).

Also fixes two `SourceFile(...)` constructions in `Lyric.Pipeline`
(`specMayRender`, the propagate-hoist rewrite) that omitted the `files` field added
by docs/70 phase 2a, which broke `make lyric` on a clean `main`.

Tests: `closure_correctness_self_test.l` ("a generic parameter reaching typed
consumers (#8349)") on dotnet and JVM; the file is in the ilverify gate list, and
`make ilverify` reports 0 errors across all 89 consumer self-tests.
