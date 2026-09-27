# lyric-lambda on JVM: generic free-function return inference from call-site arguments (#7337)

`lyric-lambda`'s test suite now builds and runs on `--target jvm` and is
wired into CI, alongside `--target dotnet`. It was never run on JVM before
this fix, so the gap went unnoticed until reported.

## Root cause

Both reported J007 sites (`Lambda.LambdaTests:368`, reading `attr.s` after
`match mapGet(evt.records[0].dynamodb.keys, "id") { case Some(attr) -> ... }`;
`Lambda.DispatchTests:302`, reading `attr.attributeType`/`attr.value` after
the same `mapGet(...)` shape on a directly-field-accessed `Map`) came from
the same underlying gap, not two independent bugs:

`Std.Collections.mapGet[K, V](m: in Map[K, V], key: in K): Option[V]`
declares its return type as `Option[V]`, where `V` is `mapGet`'s OWN generic
parameter — not a resolved type. `Jvm.Codegen.returnTypeGenericArgsFiltered`
(rightly) refuses to trust a bare reference to a function's own type
parameter as if it were a concrete type at REGISTRATION time (a caller's
inferred substitution isn't visible from the declared signature alone), so
`mapGet`'s registered `JvmFuncSig.retGenericArgs` came back empty. Every
consumer of that empty list — in particular the match-payload unboxing a
`case Some(v) -> …` destructure relies on — had no way to recover `V`'s
concrete class for a GIVEN call, so `attr` stayed erased `java.lang.Object`
and any field read on it failed `J007`.

MSIL never hit this: the CLR's real (non-erased) generics carry `V`'s actual
instantiation at the call site, so this class of bug is JVM-only by
construction — exactly why CI only running the suite on `--target dotnet`
hid it.

Neither #7362 (a `List[T].toArray()` element losing its type) nor #7479 (a
value unwrapped from a field receiver's `Result[Iface, E]`-returning method)
turned out to be the root cause here — those are calls whose return type
mentions a type parameter belonging to something OTHER than the callee
itself (a receiver's own instantiation, or the receiver method's declaring
type). This is the first fix for the narrower "the callee's OWN generic
parameter appears bare in its declared return type" shape.

## Fix

`Jvm.Codegen.inferGenericReturnArgsFromCallArgs` (`lyric-compiler/jvm/codegen/03_match.l`)
recovers the substitution from the call site's own arguments instead of the
bare declared signature: it unifies each declared parameter's shape
(`Map[K, V]`, `slice[T]`, …) against the matching call ARGUMENT's own
recovered instantiation (`Jvm.Codegen.scrutineeGenericArgs`), positionally
solving for the function's type parameters, then substitutes into the raw
(un-filtered) declared return type. `JvmFuncSig` gained four new fields
(`ownTypeParams`, `declParamTypeExprs`, `declRetTypeExprRaw`,
`declRetExternTypes`) carrying the declaration-time context this needs;
every other sig-registration site passes neutral empty defaults, so only the
plain free-function registration (`Jvm.Codegen.collectFileSigsSeeded`'s
`IFunc` arm, `lyric-compiler/jvm/codegen/06_items.l`) participates.

Recovering the call argument's own instantiation in turn needed
`Jvm.Codegen.receiverClassOf` to resolve a CHAINED receiver
(`evt.records[0].dynamodb.keys`), not only a bare local/`self` — it
previously handled one level only. It now recurses through `EMember`
(a new `fieldClassOf` reads a field's own precise class straight from
`FuncCtx.caseFields`, since a plain concrete-typed field is never erased)
and `EIndex` (reusing `indexedElemTypeOverride`, the SAME narrowing real
`EIndex` codegen already applies), mirroring step-by-step what actual
bytecode emission (`lowerExpr`) already computes for the same chain.

## Tests

`lyric-compiler/jvm/generic_free_func_return_jvm_self_test.l` (3 cases, both
targets): the exact `Lambda.LambdaTests` shape (index + field hops to a
`Map` field), the exact `Lambda.DispatchTests` shape (a direct field hop, no
indexing), and a direct match with no intermediate binding. Batched into CI
via `scripts/ci/jvm-generics-self-tests-batch.sh` alongside 3 sibling
generic/cross-package self-tests (one step, keeping `.github/workflows/ci.yml`
under `scripts/ci/check-workflow-size.sh`'s ceiling).

CI: a `lyric-lambda suite on JVM (lyric test --target jvm --features jvm)`
step (`.github/workflows/ci.yml`) runs `lyric test --manifest
lyric-lambda/lyric.toml --target jvm --no-default-features --features jvm`
via `scripts/ci/manifest-jvm-maven-test.sh` (the manifest's unconditional
`import Web` needs Undertow Maven-restored first). This fix alone left
`lambda_dispatch_tests.l`/`lambda_aspect_weaving_tests.l` still failing on a
separate, related bug — see `docs/progress/2026-09-27-jvm-transitive-import-type-resolution.md`
(#7357) for the follow-up that closed those out; the full suite is green on
`--target jvm` as of that fix.
