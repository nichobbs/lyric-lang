# Array extern aliases are no longer encoded as generic instantiations (#7610)

`externTargetBracketGenericInstMsil` (#7449, D-progress-999) recovers the real
closed GENERICINST for a bracket-suffixed extern-type alias used as an
`@externTarget` parameter or return type. It recognised such an alias by a
bare "CLR FQN contains `[`" test, so an array alias
(`extern type StrArr = "System.String[]"`) was also treated as an
instantiation and encoded as a zero-argument `System.String<>`.

On v0.7.0 every `@externTarget` taking such an alias failed at run time with
`MissingMethodException` (for example
`Void System.Array.SetValue(System.String, Int32)`), because `argTyToSig`
could not describe the bogus instantiation, so metadata-direct resolution was
skipped and the declared types were encoded. After #7519 taught `argTyToSig`
to describe instantiations, instance calls bound again (the receiver is
dropped before overload scoring), but any scored array-alias argument still
failed at build time with F0015 (`gi_System.String` in the declared
signature), e.g. a static `System.Array.Copy`. 0.6.3 bound all of these. Found
porting nichobbs/cloud-agents to 0.7.0, whose SQLite driver and session store
use this `Array.CreateInstance`/`SetValue`/`GetValue`/`Copy` pattern.

The helper now asks `isClosedGenericInstFqn`, which requires a backtick-arity
head before the first `[`, at least one type argument, and no trailing array
rank specifier (`[]`, `[,]`). Array aliases keep the `object` erasure they had
before #7449, which metadata-direct resolution upcasts to `System.Array` /
`System.Object` parameters.

Fixing the encoding exposed a second, older inconsistency. The F0015
pre-check that verifies an explicit `@externStatic` wrapper against metadata
used the strict auto-FFI resolver (`Mdr.resolveExtern`), which rejects an
erased `object` argument for a named reference parameter such as
`System.Array`. The call itself is bound by the metadata-direct pass with the
lenient `@externTarget` scorer, which accepts that upcast. So
`@externStatic @externTarget("System.Array.Copy")` over `String[]` aliases
failed F0015 (on 0.6.3 too), while the unhinted spelling of the same wrapper
bound and ran. Since F0027 steers users toward adding the hint, the two
together left no working spelling whenever F0027 fired. The pre-check now
also accepts a static overload that the lenient resolver binds
(`externTargetResolvesStaticLenient`). A declaration that only matches an
instance overload, or matches nothing, still reports F0015.

Verified by two new cases in `lyric-compiler/lyric/generic_extern_param_self_test.l`
(already in `scripts/ci/compiler-self-tests-batch.sh`): an array alias as an
instance receiver and a return (`CreateInstance`/`SetValue`/`GetValue`/
`get_Length`), and as a scored static argument of an explicit `@externStatic` wrapper
(`Array.Copy`). The Copy case fails with F0015 before either fix
(`gi_System.String` before the first, `obj` before the second). docs/66 §5 records the correction.
