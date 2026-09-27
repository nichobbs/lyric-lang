# D-progress-1005 — Bind the auto-FFI direct-assignment sugar to a setter whose parameter is a closed generic instantiation (#7444)

**Status:** shipped

## Context

D-progress-999 (#6029, PR #7449) fixed the explicit `@externTarget`-wrapper
half of binding a bracket-suffixed extern-type alias (a closed generic
instantiation such as `List<SslApplicationProtocol>`) as a parameter or
return type. It explicitly left the **auto-FFI direct property-assignment**
sugar (`o.ApplicationProtocols = l`, no `@externTarget` wrapper) unfixed,
filed as this issue (#7444), because the two gaps are genuinely independent
and the direct-assignment path needed more care to avoid reopening a real,
previously-fixed regression (D-progress-934).

`o.ApplicationProtocols = l` panicked at compile time:

```
Msil.Codegen: property 'System.Net.Security.SslServerAuthenticationOptions
.ApplicationProtocols' has a getter but no accessible setter
(set_ApplicationProtocols) in reference-assembly metadata; it cannot be
assigned. (Msil.Codegen.Program.panicExternSetterUnresolved)
```

## Decision

Three independent, coordinated fixes in `lyric-compiler/msil/`, all
necessary together — fixing only one or two would have left the resolved
setter unreachable or uncallable:

1. **`argTyToSig`** (`codegen.l`) had no arm for `MGenericInst`/
   `MValueTypeGenericInst` — it fell through to `externRefFqn`, which only
   handles `MValueTypeRef`/`MClassRef`, so a closed generic instantiation
   could never be *described* as a `SigType` for lookup at all. Added arms
   that recurse into `typeArgs` via a new `argTyListToSig` helper and call
   `Mdr.mkNamedGenericInstSig` — a constructor an earlier session had already
   added for the *read* direction (`resolvedSigToMsil`'s `STNamedGenericInst`
   arm) but never wired up for the write/describe side.

2. **`Mdr.scoreSigType`**'s `STNamedGenericInst` arm (`metadata_reader.l`)
   *unconditionally* rejected (`-1`) any closed generic-instantiation
   parameter (only an *open* one, still wrapping a declaring-type VAR, scored
   `0`) — a deliberate fix for a real regression (D-progress-934: an
   unrelated same-arity BCL overload spuriously tying against the correct
   match). This meant even the property's *own* getter-typed probe in
   `resolveExternSetterMsil` — which builds a `SigType` straight from real
   metadata (`gp.sig.returnType`), no `argTyToSig` involved at all — could
   never match the setter's identically-shaped parameter: a textbook
   "structurally identical types don't recognize each other" bug. Added a
   genuine **structural match** arm: when `arg` is *also* a closed
   `STNamedGenericInst` of the same head FQN/value-kind/arity with every type
   argument an *exact* match (new helper `sigNamedGenericInstArgsExact`,
   mirroring `STSzArray`'s own element-invariance handling just above it —
   CLR generic type arguments are invariant, so a widening/boxing match on an
   argument, which `scoreSigType` would ordinarily accept at tier 2, is not
   good enough here), it scores `3` (exact) — never touching the
   D-progress-934 `sigArgsContainOpenGeneric`-gated branch, which stays
   byte-for-byte unchanged (a wrapped-VAR parameter, e.g. `ValueTask<T>`'s
   `.ctor(Task<TResult>)`, never reaches this new branch at all: its own type
   argument list still contains a VAR, so `sigArgsContainOpenGeneric` catches
   it first).

3. **`argCoercionInsns`** (`codegen.l`) had no arm for a `STNamedGenericInst`
   parameter sig either — it fell through the non-primitive `sigNamedFqn`-
   based branch (which returns `""` for a generic instantiation) straight to
   `None`. Even after gaps 1–2 are fixed and the *right* setter is scored and
   resolved, emitting the actual call still panicked ("cannot adapt a value
   of the assigned type"). Fixed by mirroring `STSzArray`'s own coercion arm
   just above it: confirm an exact structural match (score `3`) and emit
   zero coercion instructions.

4. **`externSetterCoercion`**'s pre-existing `castclass` fallback (used when
   `argCoercionInsns` returns `None` because the assigned value's *tracked*
   type doesn't already exactly match) only built a plain-FQN `castclass`
   (`MCastclassByName`) — correct for an ordinary extern class type, but
   `MCastclassByName` interns a non-generic `TypeRef`, which can't express a
   closed generic instantiation. This gap surfaced empirically: an untyped
   local (`val l = newProtoList()`, no annotation) is tracked as plain
   `MObject` even though its real runtime type is the correct closed
   instantiation — the general `typeExprToMsilCtx` erasure convention every
   *other* caller relies on (D-progress-999's own decision doc says so
   explicitly: "locals, fields, non-`@externTarget` functions... untouched").
   So `argCoercionInsns`'s new arm (gap 3) never actually fires for this
   common case; the fallback needs to handle it instead. Fixed by using the
   already-existing `MCastclassGeneric(className, typeArgs)` instruction
   (previously only used for in-bundle generic union-case narrowing) instead
   of `MCastclassByName` when the parameter is `MGenericInst` — it builds a
   real closed TypeSpec via `findTypeRefRowByName` + `buildGenericInstBlobWithCtx`,
   so the narrowing check is genuine, not silently dropped to `object`.

This fourth gap was **not** identified by the original issue's diagnosis —
it only surfaced when actually reproducing the fix end-to-end (the issue's
"suggested fix direction" named gaps 1–2 as the *root cause*, correctly, but
implementing just those two still panicked one level deeper, at emission
time rather than resolution time). Confirmed via the same self-test used to
verify gaps 1–3: an *annotated* local (`val l: ProtoList = newProtoList()`)
would not have exercised this path, since `typeExprToMsilBodyCtx` erases the
annotation the same way; only the untyped-local shape (which resolves the
value's type from the init expression, `initTy`) surfaces it. Since an
untyped local is by far the more common and idiomatic way to write this
code, fixing gap 4 was not optional.

`argCoercionInsns` is shared by both the property-setter path
(`externSetterCoercion`) and the general auto-FFI method-call argument
validator (`autoFfiValidateParams`), so gap 3's fix also unblocks an
ordinary auto-FFI **method call** (not just a property setter) that passes a
closed generic instantiation as an argument whose tracked type already
matches exactly — not separately tested here (no simple real-BCL repro at
hand for that specific shape), but a real side benefit worth noting.

## Verification

New self-test `lyric-compiler/lyric/auto_ffi_generic_setter_self_test.l`:
constructs a `List<SslApplicationProtocol>` via the (already-working)
explicit-wrapper receiver-position path, assigns it to
`SslServerAuthenticationOptions.ApplicationProtocols` via the auto-FFI
**direct** sugar (`o.ApplicationProtocols = l`, no `@externTarget` wrapper
anywhere in the file), reads it back via `o.ApplicationProtocols` (auto-FFI
getter sugar), and asserts the round-tripped list's `Count` through the
existing explicit-wrapper `get_Count` receiver-position call.

No regression: full sweep of every FFI/generic-extern self-test unchanged
(`auto_ffi_self_test` 23/23 — including "auto-FFI resolves inherited
instance members through the Extends chain," the exact test that caught the
original unconditional-`STNamedGenericInst`-accept regression this fix's
gated structural-match arm must not reopen; `typed_ffi_delegate_self_test`
5/5 — the D-progress-934 `ValueTask` ctor-disambiguation regression guard;
`generic_extern_self_test`, `generic_extern_methodspec_self_test`,
`generic_extern_valuetype_instance_self_test`, `generic_extern_param_self_test`,
`mono_self_test`, `nested_generic_self_test`, `cross_package_generics_self_test`,
`msil_project_bridge_self_test`, `msil_restored_bridge_self_test` — all
unchanged pass counts). Also ran `lyric-stdlib/tests/metadata_reader_tests.l`
directly (`LYRIC_LOAD_COMPILER=1 lyric run`, via an isolated copy skipping
only the pre-existing unrelated `testTableRows` failure, #5624): every other
test including `testOverloadResolveSelf`, `testOverloadResolveBcl`,
`testResolveExtern`, `testResolveExternValueType`,
`testScoreSigTypeArrayInvariance` passes clean.

## Scope note

This closes #7444 as originally scoped: the auto-FFI direct-assignment sugar
for a *setter* whose parameter is a closed generic instantiation now binds.
Docs/66's remaining open gaps (1b `ByRefLike`, 2 delegate-erasure
contravariance, 3 Lyric collection local-hint threading) are untouched and
still tracked separately.
