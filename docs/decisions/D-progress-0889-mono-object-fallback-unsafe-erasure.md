# D-progress-889 — `Lyric.Mono`'s Object-defaulted fallback specialisation for imported generics no longer crashes at runtime against a real, differently-instantiated argument; new `M0004` diagnostic (#5970)

**Context.** When `Lyric.Mono` cannot infer a call's concrete type
argument(s) for an IMPORTED (cross-package, non-`@axiom`) generic function,
it has always defaulted every unpinned type parameter to `Object` and still
emitted a specialised copy (`inferReturnFromName`'s `importedFill` /
`rewriteExpr`'s matching call-site fallback) — the erased uniform-ABI
meaning the un-specialised call would otherwise have, since a generic `pub
func`'s declaration is dropped from the emitted assembly entirely (#5604)
and leaving the call un-rewritten meant codegen silently dropped it. This is
sound when the argument's own runtime instantiation genuinely IS whatever
gets defaulted (a value freshly constructed at the call site — a union-case
ctor call, a nullary case reference, a lambda literal). It is **not** sound
when the argument is opaque to mono's inference (its real, already-fixed
instantiation is simply unknown) and the callee's parameter is a
non-covariant generic shape (`Std.Core.Result`, `Map`/`List`, a user
`record`/`union`) rather than a `slice`/`Array`: the emitted
`fname__Object__Object` specialisation's `match`/`isinst`/`castclass` sites
can never structurally accept a real, differently-instantiated argument —
observed as `match not exhaustive in …isOk__Object__Object scr=
GStd.Core.Result<O,O,>` and `InvalidProgramException` (the issue's own
repro), and independently as `InvalidCastException: … Dictionary`2[String,
String] to Dictionary`2[Object,Object]` inside `mapKeys__Object__Object`
(#5422, cited from the issue's comment thread).

**Two prior audit items tried and superseded (see the issue's own comment
thread).** (1) A call-site heuristic diagnostic (the reverted PR #6141)
examined the CALL SITE's control-flow shape and produced a real false
positive on `examples/product-catalog`'s `map(rows, rowToProduct)` — a
match-bound `List` argument into a `slice[T]`-shaped parameter, which is
actually safe (array covariance), but indistinguishable from the unsafe
shape using only call-site control-flow. (2) Making codegen's match-arm
lowering "fail safely" for an `Object`-typed scrutinee (an `isinst`-miss
panic instead of a hard crash) was considered but rejected here: it would
make every call through such a specialisation panic **unconditionally**,
even when the real argument's `Ok`/`Err` (etc.) arm is exactly the one an
`Object`-shaped match happens to hit correctly for some inputs — degrading a
sometimes-correct (for a narrow set of shapes) call into an always-wrong
one is not a fix, and the real defect is that the specialisation should
never have been created for this argument in the first place.

**The fix (`lyric-compiler/lyric/mono.l`) — two-part, narrower than either
prior attempt.**

1. **Shape check, not control-flow:** `typeExprUnsafeUnderErasure` inspects
   the CALLEE's own declared parameter type (something mono already has in
   hand as `baseDecl`/`decl`), not the call site's syntax. A parameter typed
   `slice[T]` / `Array[N, T]` with `T` used BARE as the element is exempt
   (real CLR/JVM array; reference-type covariance genuinely tolerates any
   real reference-typed array argument through an `Object[]`-typed
   parameter — this is the `map`/`filter`/`fold`-over-a-`List` idiom #6141
   broke). Every OTHER generic shape referencing an unpinned parameter
   directly as a type argument (`Result[T, E]`, `Map[K, V]`, a user
   `record`/`union`) is flagged, recursing through nested slices/nullables
   so `slice[Result[T, E]]` is caught too.
2. **Opacity, not shape alone:** the per-argument inference loop (both
   `inferReturnFromName` and `rewriteExpr`'s bare-`EPath` rewrite site) now
   tracks, per processed argument, whether it gave inference ANY evidence at
   all — a recognised lambda literal, a union-case ctor-call (`ctorSynthOfArg`),
   a **new** bare nullary-case reference (`bareInferenceOnlyCtorRef`, the
   zero-field counterpart `ctorSynthOfArg` never matched — `NoneLike` with no
   call parens — closing a gap that would otherwise have wrongly flagged the
   pre-existing, load-bearing `isEmptyLike(NoneLike)` #5604 test), or a
   successfully-inferred `inferExprTE` result — versus giving NONE (a call
   through a function-typed parameter, an untracked binding, or any other
   expression shape mono's inference doesn't yet cover). `hasOpaqueErasureUnsafeGenericParam`
   only refuses the Object-defaulted fallback when an unsafe-shaped parameter's
   argument is BOTH opaque AND unsafe-shaped — a freshly-constructed argument
   against an unsafe shape (`isOkLike2(MkOk(v = 7))`, `wrapIt(MkOk(v = 5))`
   read back through a tracked binding) stays exempt, since the value
   genuinely IS the instantiation that gets defaulted; only an opaque
   argument's unknowable, possibly-different-from-`Object` real instantiation
   is unsafe. This is the precise distinction the reverted call-site
   heuristic could not make without analysing the callee body — it turned
   out unnecessary to analyse the body at all; the callee's PARAMETER SHAPE
   plus the CALL SITE's evidence-vs-opacity split is sufficient and does not
   revisit the rejected match-arm-codegen direction.

   Refusing the fallback raises a new `M0004` diagnostic at the call site
   instead of silently emitting the crashing specialisation — the
   `Lyric.Mono` counterpart of `M0002`'s trade for same-package generics
   (a compile-time error instead of a construct that compiles clean and
   fails at runtime).

**Regression coverage.** Three new cases in `mono_self_test.l` (82 → 85):
an opaque argument (a call through a function-typed parameter — the file's
own documented "still falls through to un-specialised" inference gap,
matching the real #5970/#5422 repros exactly, since neither the untracked
`File.writeText` binding nor the match-bound `Dictionary` argument were
ever anything mono could see through either) against a `Result`-shaped
imported generic now raises `M0004` and does not emit
`isOkLike3__Object__Object`; the same opacity routed through an
intermediate local binding first (confirming `inferReturnFromName`'s mirror
of the guard does not leave the binding carrying a phantom instantiation a
later call would trust); and the same opaque-argument shape against a
`slice[T]`-parametered imported generic still defaults to `Object` exactly
as before (the explicit non-regression case for the #6141 `map`/`filter`
idiom). All 12 pre-existing `#5604`/`#5843`/`#5422`/`#5961`/`#5962` tests
in the same file that legitimately rely on the Object-defaulted fallback
(ctor-synth partial pins, tracked bindings, ambiguous-name-resolves-to-Object,
the bare-nullary-case shape) continue to pass unchanged, confirming the
fix does not regress any of the "legitimately `Object`-typed generic usage"
cases the issue asked to preserve.

**Scope note.** `hasOpaqueErasureUnsafeGenericParam` treats a parameter as
unsafe based on its declared TYPE SHAPE alone (any non-`slice`/`Array`
`TGenericApp` referencing an unpinned param), not on whether the callee's
body actually performs a structural `match`/cast on it — a same-shape
pass-through function (e.g. an identity-like `wrapIt`) is flagged
conservatively even when its own body never inspects the value, matching
this file's existing "safe degradation" philosophy elsewhere (prefer a
compile-time diagnostic over a risk of a silent runtime crash). A tuple or
lambda-parameter-nested occurrence of an unpinned type parameter is not
walked into (deliberately narrower than `teMentionsTypeParam`'s full
traversal) since neither shape appears in any known #5970-class repro and
over-broadening the walk risks exactly the kind of false positive #6141
already demonstrated; a future report of a crash through one of those
shapes would extend `typeExprUnsafeUnderErasure` rather than requiring a
new mechanism.

**Addendum (2026-09-05, pre-merge review, #6940).** The shape check above had
a gap: `typeArgOccursUnsafely`'s fallback (the function that decides whether
a bare type ARGUMENT to another generic is unsafe) re-applied the
`slice`/`Array`-covariance exemption even when the slice/array was itself
nested as a type argument INSIDE an already-unsafe outer generic —
`Result[slice[T], E]`, `Map[K, slice[T]]` — rather than being the
parameter's own top-level type. Array covariance only makes `Object[]`
accept a real `Foo[]` when the array IS the parameter's own static type; it
does not make `Result<Object[], E>` accept a real `Result<Foo[], E>`, since
closed generic types are invariant over ALL of their type arguments on both
MSIL and JVM regardless of whether one of those arguments happens to be an
array. Concretely, `firstOrErr[T](r: in ResLike[slice[T], String]): Bool`
called with an opaque `ResLike[slice[Int], String]` argument passed
`hasOpaqueErasureUnsafeGenericParam` (both type arguments came back "safe" —
the bare `String` isn't unpinned, and the nested `slice[T]` wrongly re-hit
the top-level exemption) and mono emitted the crashing
`firstOrErr__Object`, reproducing the #5970 crash class one level of nesting
away from the shapes the original three regression tests cover.
`Result[slice[...], ...]` is a pervasive idiom in this codebase
(`http_hpack.l`, `directory.l`, `tls.l`), so this was a live gap, not a
theoretical one.

Fixed by having `typeArgOccursUnsafely` handle `TSlice`/`TArray`/
`TNullable`/`TParen` directly, recursing through itself (not through
`typeExprUnsafeUnderErasure`/`typeExprNestedUnsafe`) — so once traversal has
crossed into a type-ARGUMENT position, a bare unpinned ref anywhere along a
slice/array/nullable/paren chain stays flagged unsafe, and the covariance
exemption is only ever reachable from `hasOpaqueErasureUnsafeGenericParam`'s
own direct, top-level call into `typeExprUnsafeUnderErasure` on the
parameter's own declared type. A fourth `mono_self_test.l` case
(`ResLike[slice[T], String]`, #6940) confirms `M0004` now fires and
`firstOkLike__Object` is not emitted, while the three pre-existing #5970
cases and the legitimate top-level `slice[T]`-parametered `map`/`filter`
non-regression case (test 85) continue to pass unchanged.

**Addendum (2026-09-06, CI follow-up) — `Jvm.Bridge` union-ctor-inference
collection gap, not a `mono.l` defect.** The `compiler-self-tests-jvm` CI job
on this PR's branch failed `match_bound_pattern_type_self_test.l` under
`--target jvm` only (`--target dotnet` passed): `mapKeys`/`mapValues` called
on a `case Some(mm) -> …`-bound `Map` argument raised the new `M0004` instead
of specialising, seemingly contradicting that file's own header, which
documents `Lyric.Mono.bindPatternEnvMono` already tracking match-arm pattern
types for exactly this shape (#5422). Root-caused (not merely patched) by
reproducing the CI failure from a clean build of this PR's exact head commit
against a from-scratch `main` baseline (main: 6/6 pass on both targets; this
branch: 6/6 pass on `--target dotnet`, 4 `M0004` failures on `--target jvm`
only) with `println` instrumentation added temporarily to `mono.l` (reverted
before the real fix, never committed): `state.ctorCandidates["Some"]` was
EMPTY on the JVM compile path (`candidates.count=0`), so
`bindPatternEnvMono`'s `PConstructor` arm's "exactly one owner-matching
candidate" check always failed and evicted `mm` from `env` instead of
tracking `Map[String, String]` — `mono.l` itself is untouched and behaved
identically to `--target dotnet` given the same input; `Jvm.Bridge`'s
`collectStdlibGenericFuncsJvm` (`lyric-compiler/jvm/bridge.l`) simply never
fed stdlib union-case ctor-inference synths (`Std.Core.Option`'s
`Some`/`None`, `Std.Core.Result`'s `Ok`/`Err`, and every other stdlib
union's cases) into `monoGenFuncs` at all — unlike `Msil.Bridge`, whose
`collectStdlibUnionCtorDecls(stdlibPkgs)` (calling the same
`Lyric.Mono.unionCtorInferenceDecls`, #5604) has fed this list since before
#5970. This was a genuine, pre-existing MSIL/JVM parity gap (silent on JVM
before this PR only because the JVM backend's own full generic erasure — see
`compileProjectToJarBundledWithRestored`'s doc comment, "JVM has no reified
generics to preserve" — makes an `Object`-defaulted specialisation just as
runtime-safe as a correctly-typed one there, so the pre-#5970
unconditional-Object-default fallback papered over the missing env tracking
without ever crashing); #5970's stricter opacity check is simply the first
thing to treat "no inference evidence" as a hard error instead of a silent
default, surfacing it. Fixed by adding the same
`unionCtorInferenceDecls`-over-`stdlibFiles` collection loop to
`Jvm.Bridge.collectStdlibGenericFuncsJvm`, positioned identically to the MSIL
side (after real generic functions so a real function still wins the
monomorphizer's first-wins name merge, before the `mapGet` inference-only
intrinsic stub, which must stay last) — restores `env`-based match-arm
pattern-type tracking to full JVM/MSIL parity, so `mapKeys(mm)` infers
`K=String, V=String` correctly on JVM exactly as it already did on MSIL, and
the `M0004` opacity guard is never even consulted for this legitimate case
(rather than gating the diagnostic by target, which would have papered over
the actual defect and left JVM's pattern-type inference silently blind for
every other consumer of that same env state). Verified against a from-scratch
rebuild of both targets: `match_bound_pattern_type_self_test.l` now passes
6/6 on `--target jvm` (previously 4 `M0004` failures) and unchanged 6/6 on
`--target dotnet`; `mono_self_test.l` (86/86, dotnet, mono.l untouched by
this fix) and a JVM sanity sweep (`bitwise_self_test.l`,
`result_generic_specialization_self_test.l`, `block_shadow_self_test.l`,
`aspect_weave_self_test.l`, `async_spawn_self_test.l`,
`stdlib_generic_mono_self_test.l`) all continue to pass unchanged. Scope
note: `Jvm.Bridge` still has no JVM analog of `Msil.Bridge`'s
`collectStdlibNonGenericFuncs` (stdlib non-generic `pub func`s fed to
inference for #5196) — a related but distinct gap, not exercised by this
CI failure and not fixed here; tracked as a follow-up (#7009) rather than
folded into this fix's blast radius.
