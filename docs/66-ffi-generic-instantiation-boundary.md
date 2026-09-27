# 66 — The MSIL FFI generic-instantiation boundary: scope and design direction

_Status: unbacked exploratory sketch (no decision-log entry yet — see
CLAUDE.md's "Exploratory sketches" convention). Linked from
`docs/42-extern-metadata-resolution.md` §7 (Q-MD-006) and
`docs/50-ffi-delegates-proposal.md`'s open-scope note. A first concrete slice
(parameter/return-position closed-generic-instantiation binding for
`@externTarget` — §5 "Gap 1a") shipped alongside this doc; see the PR this
doc was introduced in._

## 1. Why this doc exists

Nine issues were originally filed against "the MSIL auto-FFI/extern-binding
path doesn't handle generics." Two closed as unrelated FFI hygiene
(`#5704`, `#5613`). Of the remaining seven (`#1760`, `#4601`, `#5525`,
`#5624`, `#5800`, `#5947`, `#6029`), every prior investigating session that
read the actual code independently reached the same conclusion on each one:
_"this needs a coordinated design pass, not a point patch."_ This doc is
that pass — it reads all seven in full, reads the code each one points at,
and answers two questions:

1. Do these seven actually share **one** root cause, or are they multiple
   distinct problems wearing the same label?
2. For each real problem, what's the concrete design direction, and which
   issues does it resolve?

## 2. Verdict: not one gap, and not seven — four, plus one non-member

Reading the code (not just the issue text) shows **four independent
generic-erasure gaps** at different points in the MSIL backend, and **one
issue that doesn't belong in this family at all**:

| Gap | One-line description | Issues |
|---|---|---|
| **1a** | Bracket-suffixed extern-type alias erased to `MObject` at a **parameter/return position** of an unrelated `@externTarget` member (not the alias's own generic-declaring-type receiver) | `#6029` |
| **1b** | Same erasure, but the concrete type is `ByRefLike` (`ReadOnlySpan<T>`/`Span<T>`) — boxing to `object` isn't just lossy, it's **illegal CIL** | `#1760` |
| **2** | Strongly-typed lambda→delegate ABI (D122) builds a delegate from the **call site's concrete type**; the generic-declaring-type erasure convention (`emitGenericExternMember`) expects the **fully-erased** `Func<object,object>`/`Action<object>` shape in the same call — contravariant cast mismatch. Compounded by: the delegate-ctor builders only know how to build `Func`/`Action`, never a **named** BCL delegate type | `#5525`, `#5800`, `#5947` |
| **3** | Lyric's **own** `List[T]`/`Map[K,V]` (not BCL-extern, but the same object-erasure representation) get a codegen-internal type hint (`collExpect`) that is a single ambient value clobbered by every unannotated `val`, instead of a per-local inferred type | `#4601` |
| — | `#5624` is an omnibus of four **unrelated** backend residuals (placeholder Param-table rows, a JVM boxed-slice-field read, JVM auto-FFI scoring parity, an MSIL async state-machine refactor) that share a tracking label but not a mechanism | `#5624` (not part of this family) |

Gaps 1a/1b/2/3 are related by a **pattern**, not a shared code path: the
compiler's default move at a generic-instantiation boundary is "erase to
`object`, recover the real type later if something downstream needs it."
That recovery is inconsistent — some sites recover it (receiver-position
generic-declaring-type calls, via `emitGenericExternMember`/
`emitGenericMethodExternCall`, shipped and hardened across
D-progress-929–941), and some don't (everywhere else a bracket-suffixed
alias or a `List[T]`/delegate value flows). There is no single function to
fix; there are four call sites that each independently decided to erase
when they didn't have to. Gap 1b is additionally a **different kind** of
problem (an illegal-CIL constraint, not just a lost-information one) and
needs its own non-erasing representation, not a recovery of the existing one.

`#5624` is included here only because a prior triage pass filed it under the
same `group:ffi-extern-binding` label. Reading its four items shows none of
them touch generic instantiation at all (see §6).

## 3. What already works (don't re-litigate this)

Before this doc, the following was already shipped and is **not** part of
the gap:

- A member of a generic **declaring** type (`List<T>.ForEach`,
  `ConcurrentDictionary<K,V>.TryGetValue`, `ValueTask<T>.ctor`) resolved as
  the **receiver** of an `@externTarget` call: `emitGenericExternMember`
  builds the real closed `GENERICINST` TypeSpec, casts the receiver, and
  marshals `out`/value-type arguments across the erasure boundary
  (docs/42 §5 Phase 6, `#6581`, hardened by seven follow-up fixes
  D-progress-930–938).
- A BCL method with its **own** method-level generics on a non-generic
  declaring type (`Enumerable.Repeat<T>`, `CallInvoker.
  BlockingUnaryCall<TReq,TResp>`): `emitGenericMethodExternCall` builds the
  OPEN MemberRef + MethodSpec instantiation (docs/42 §5 Phase 6 Gap 2).
- Closed generic **interfaces** (`IEquatable<T>`) via `impl` blocks
  (docs/51, Phase 4).
- In-bundle (Lyric-authored) generic records/unions get real `GenericParam`
  table rows and TypeSpec construction (docs/43) — a different problem
  (writing metadata for a type Lyric itself defines) whose TypeSpec-blob
  *mechanics* (`buildGenericInstBlobWithCtx` et al.) are the same building
  blocks Gap 1a's fix (§5) and the Phase 6 work above both reuse.

The one combination still explicitly declined everywhere (loud panic, not a
silent miscompile): a member that is **both** on a generic-declaring type
**and** has its own method-level generics (`List<T>.ConvertAll<TOutput>`,
`#7138`/D-progress-938). Out of scope of all seven issues here; noted for
completeness.

## 4. The common instinct behind every gap

Every one of the four gaps below is a variation on the same missed step:
*somewhere in the pipeline, a value that has a real, known, closed generic
instantiation gets converted to a context-free `MObject` (or a
hardcoded-erased `Func<object,...>`/`Action<object>`) instead of the
`MGenericInst`/`MValueTypeGenericInst`/typed-delegate representation the
codegen backend can already emit correctly once it has it.* The MSIL
backend's `MsilType` union and its signature-blob writers
(`bufMsilType`/`bufMsilTypeWithCtx` in `lyric-compiler/msil/lowering.l`)
already know how to encode a closed `GENERICINST` correctly — CLASS or
VALUETYPE tag, TypeRef, recursively-encoded type arguments. The gap is
never "the backend can't emit this"; it's "some earlier conversion step
threw the information away before the backend got a chance." So the design
direction for every gap is the same shape: **find the specific conversion
site that erases prematurely, and give it a narrowly-scoped escape hatch
that preserves the real type — without touching the erasure convention
anywhere else that depends on it.**

That "without touching the erasure convention anywhere else" clause is why
none of these were safe as one-line patches: `typeExprToMsilCtx`'s
bracket-suffix erasure, `argFqnToMsil`'s CLASS default, and the delegate-ctor
builders' Func/Action-only shape are all **pervasively called** functions
that other, already-shipped, already-tested paths rely on producing exactly
today's output. The fix pattern that works is: leave the pervasive function
alone, and add a **new, narrowly-scoped conversion** that only fires for the
specific caller that needs the real type, falling back to the old erasing
path everywhere else. This is precedented already — `genericMemberSigToMsil`
exists alongside `resolvedSigToMsil` for exactly this reason (one preserves
`STVar`, one doesn't), and the `TFunction` special case inside
`emitExternTargetBody`'s parameter loop exists alongside the generic
`typeExprToMsilCtx` call for the same reason (D122).

## 5. Gap 1a — parameter/return-position erasure (`#6029`) — **shipped in this PR**

### The bug, precisely

`Msil.Codegen.typeExprToMsilCtx`'s `TRef` branch erases *any* bracket-suffixed
extern-type alias (`extern type ProtoList = "System.Collections.Generic.
List\`1[System.Net.Security.SslApplicationProtocol]"`) to `MObject`. The
comment justifying this says "member calls on it route through
`emitGenericExternMember`" — true when the alias is the **receiver** of its
own generic-declaring-type call, false in every other position. `SslServer
AuthenticationOptions.set_ApplicationProtocols(List<SslApplicationProtocol>)`
takes the alias as a **parameter** of an unrelated (non-generic-declaring)
method; `emitGenericExternMember` never runs for that call at all
(dispatch is gated on `genericArityOfName` of the *target's own* declaring
type name, not on any parameter's type). The erased `MObject` flows straight
into the `@externTarget` MemberRef signature, which then can never bind
(`MissingMethodException` at runtime — confirmed against the real BCL API by
three independent sessions before this one).

A second, independent bug compounds it: `argFqnToMsil` (used to convert a
bracket-suffix's own type-argument FQNs to `MsilType` for TypeSpec
construction) unconditionally tags any non-primitive argument as
`MClassRef` — wrong when the argument is itself a value type
(`SslApplicationProtocol` is a struct). A GENERICINST type argument's own
CLASS/VALUETYPE tag must match its real CLR kind (ECMA-335 §II.23.2.12); the
wrong tag loads with `TypeLoadException` even once the outer erasure bug is
fixed.

### The fix

Two changes, both purely additive (zero change to any other call site):

1. **`argFqnToMsil`** now checks `Mdr.isValueTypeFqn` and returns
   `MValueTypeRef` for a struct argument instead of unconditionally
   `MClassRef`. This is a correctness fix to already-shipped code
   (`emitGenericExternMember`'s own ctor-construction path uses the same
   helper) — it was simply never exercised with a value-type bracket
   argument before.
2. A new helper, `externTargetBracketGenericInstMsil`, recovers the real
   `MGenericInst`/`MValueTypeGenericInst` for a bracket-suffixed alias used
   as an `@externTarget` parameter or return type — reusing the exact same
   `stripBracketSuffix`/`parseBracketArgFqns`/`argFqnToMsil`/
   `internFfiTypeRefNested` building blocks `emitGenericExternMember`
   already uses for the receiver-position case, and producing the identical
   `MsilType` shape `resolvedSigToMsil`'s `STNamedGenericInst` arm already
   produces from metadata-decoded signatures (so the signature-blob writer
   path is already proven, not new). Wired into `emitExternTargetBody`'s
   parameter-type loop and return-type computation as an extra match arm,
   exactly mirroring the existing `TFunction` special case's scoping
   (`@externTarget` signatures only).

A pleasant side effect closes what the issue called "Gap C" for free: when
the alias is instead used as a **return type** and the target method is a
**constructor** of that same generic type (`newProtoList()`'s `@externTarget
("...List\`1..ctor")`, no bracket suffix on the ctor's own target string —
the exact shape `#6029` reported), `emitGenericExternMember`'s existing
`r.isCtor` branch *already* had a mechanism to infer the real type arguments
from a matching `MGenericInst`/`MValueTypeGenericInst` return type
(`retArgs`) — it simply never received one, because the return type was
always the `MObject` erasure. Fixing the return-type erasure activates
pre-existing, already-tested machinery; no new construction-side code was
needed.

### What this does *not* fix

The auto-FFI **direct** property-assignment sugar (`opts.
ApplicationProtocols = list`, no `@externTarget` wrapper) still panics
(`panicExternSetterUnresolved`). That path resolves the setter via
`Mdr.resolveExtern`, which needs `argTyToSig` to describe the value's
`MsilType` as a `SigType` for lookup — and `argTyToSig` has no arm for
`MGenericInst`/`MValueTypeGenericInst` today (it only special-cases Lyric's
own `MListOf`/`MConcreteList`/`MMapOf`/`MConcreteMap` by their **base**
arity name, discarding the instantiation's own type argument, which is also
why it can't disambiguate a same-arity overload on a closed instantiation).
Even with that extended, `Mdr.scoreSigType`'s `STNamedGenericInst` arm
*deliberately* returns `-1` (reject) for a closed instantiation today — see
its own inline comment explaining why a blanket-accept there previously
caused a real regression (D-progress-934) — so a genuine **structural**
match arm (same FQN + same value/reference kind + pairwise-scored type
arguments) is a real, separate follow-up, not a fallback that already
exists. This is filed as a follow-up issue (see §7); it did not fit this
PR's scope alongside everything else, and — per CLAUDE.md's standard — a
smaller, fully-finished slice (the explicit `@externTarget` path) beats a
half-finished larger one.

Also not covered: a parameter/return type that reaches the bracket-suffixed
alias only through an `alias Foo = ProtoList` indirection rather than a
direct reference. `externTargetBracketGenericInstMsil` only consults
`cctx.externTypeNames`, not `cctx.aliasTargets`, so an indirected reference
falls through to the pre-existing `MObject` erasure — not a regression (the
old bug simply persists one level of indirection away), just a narrower
recovery than the general erasure convention's own alias-chain following.

Finally: even with the parameter now correctly typed via this fix,
`argTyToSig` (`lyric-compiler/msil/codegen.l`) still has no arm for
`MGenericInst`/`MValueTypeGenericInst`, so it returns `None` for such a
parameter. This means `emitExternTargetBody`'s F0015 explicit-static
signature-verification pre-check and `emitGenericExternMember`'s own
scored-resolution path both silently skip/degrade for a call involving such
a parameter, falling back to the pre-existing unscored path (harmless today,
since that's exactly the path this fix's own signature construction already
relies on) — but verification coverage for this shape doesn't yet exist.
Closing it is the same `argTyToSig`/`scoreSigType` extension `#7444` already
tracks for the auto-FFI direct-assignment gap; no separate issue needed.

## 6. `#5624` — not part of this family

`#5624` bundles four items under the same tracking label as the six issues
above, but none of them touch generic instantiation:

1. `Msil.Lowering` emits placeholder `Param` table rows (`sequence = 0`
   throughout, 24 call sites) instead of real per-parameter sequence
   numbers — orphaned from a deleted F# emitter's expectations, and
   entangled with a documented safety invariant (D-progress-659: "Lyric-
   emitted assemblies never carry `sequence >= 1`") that a real fix would
   need to revisit. Pure Param-table metadata hygiene.
2. A JVM boxed `slice[Byte]` field's element read stays statically `Object`
   — two independent sessions could not reproduce this against current
   `main` with the two most natural repro shapes.
3. JVM auto-FFI (`findBestMethod`/`findBestConstructor`) lacks scoring
   parity (trailing-default admission, subtype-argument scoring) with the
   MSIL scorer. Related to overload *scoring* generally, not generic
   instantiation specifically — the MSIL scorer gaps this doc is about are
   §5's follow-up, not this.
4. The MSIL async state-machine's `FieldDef` budget is a mirror-of-emission
   hack that needs a side-effect-free dry-run pass instead.

**Recommendation:** split `#5624` into standalone issues per item (item 2
closed as unreproducible — two independent sessions, including one for this
doc, could not reproduce it), and drop the `group:ffi-extern-binding` label
from the survivors since they don't belong in this investigation. This doc
does not do that GitHub bookkeeping itself (out of scope for a design doc),
but the issue has been re-triaged with this finding.

## 7. Gaps 1b / 2 / 3 — design direction and follow-up scope

None of these were attempted in this PR — each is a genuine, separately
dated, cross-cutting change, not a point patch, matching what every prior
session that looked at the actual code already concluded independently.
Per CLAUDE.md: land the smaller finished slice (§5), file the rest with a
concrete plan.

### Gap 1b — `ReadOnlySpan<T>`/`Span<T>` (`#1760`)

`ByRefLike` structs cannot be boxed to `object` — not "lossy," **illegal
CIL**. Gap 1a's fix doesn't help here: recovering the real type at a
parameter position still needs a `box`-based marshalling story for anything
downstream that expects a boxed value, and there isn't one for a ref
struct. This needs a genuinely new, non-erasing `MsilType` case (e.g.
`MByRefLikeRef`) gated to `@unsafe_ffi` call sites only, with stack-only
lifetime rules threaded through every codegen site that currently assumes
"every value is either a primitive or heap-representable" (no field
storage, no array element, no closure capture — mirroring C#'s own
ref-struct restrictions). This is the largest of the four gaps and is its
own follow-up epic, not a slice of this pass.

### Gap 2 — delegate erasure contravariance + named delegate types (`#5525`, `#5800`, `#5947`)

Two sub-problems in the same machinery
(`lambdaExternDelegateParamTypes`/`buildFuncNTypedCtorTok`/
`buildActionNTypedCtorTok`, `lyric-compiler/msil/codegen.l`):

- **Contravariance mismatch**: D122's strongly-typed lambda ABI builds a
  delegate from the lambda's call-site concrete type
  (`Action<Int32>`); when that lambda flows into a parameter of a call that
  *also* goes through `emitGenericExternMember`'s erased-`<object,...>`
  convention for the receiver, the CLR sees an invalid cast
  (`Action<Int32>` is not assignable to the erased `Action<Object>` the
  receiver's TypeSpec expects — delegates are contravariant, not covariant,
  in the wrong direction here). Direction: the erasure decision must be
  made **once per call** and applied consistently to every generic-shaped
  argument in it, not decided independently per parameter. Concretely: when
  `emitGenericExternMember` erases a call's receiver type arguments to
  `object`, any `TFunction`-typed parameter in the *same* call must build
  its delegate against the erased `Func<object,...>`/`Action<object>` shape
  too (boxing the lambda's real parameter values at the call site, the same
  way any other value-type argument already gets boxed crossing that
  erasure boundary), instead of always using the "real, strongly-typed"
  convention regardless of context.
- **Named delegate types**: `buildFuncNTypedCtorTok`/
  `buildActionNTypedCtorTok` only know how to construct `System.Func`N`/
  `System.Action`N`; a genuinely custom delegate (`RemoteCertificate
  ValidationCallback`) has no construction path at all. Direction: a third
  builder, `buildNamedDelegateCtorTok`, that resolves the real delegate type
  from metadata (reusing `Msil.MetadataReader`, the same "read the true BCL
  shape instead of guessing" pattern this doc's §5 fix and the Phase 6 work
  in §3 both already use) and emits `ldftn` + `newobj
  <RealDelegateType>::.ctor` against its actual `TypeRef`/`.ctor` signature.

`#5800` is a test-coverage tracking issue for the same root cause (it exists
specifically because no regression test could be written until the
underlying bug was fixed) and closes as a side effect of `#5525`'s fix
landing with a real test.

### Gap 3 — Lyric-internal `List[T]`/`Map[K,V]` local-hint threading (`#4601`)

Not an FFI/BCL boundary problem — `List[T]`/`Map[K,V]` are Lyric's own
generic collections, always represented as object-erased `List<object>`/
`Dictionary<object,object>` at the CLR level regardless of this fix. The bug
is purely in how the codegen decides **which** erased representation to
build: `lowerStmtMsil`'s `SLocal`/`LBVal` arm pushes `MObject` as the
`collExpect` hint for *any* unannotated `val`, unconditionally clobbering
whatever concrete hint the enclosing function-return scope had already
pushed — so `val l = newList()` inside a `List[String]`-returning function
builds a `List<object>` that then fails to cast at the return site. The
already-tried narrow fix (inherit the ambient hint for an untyped local) is
provably unsafe: a second, unrelated `newList()` earlier in the same
function would incorrectly inherit the *other* local's concrete hint. The
type checker already infers each local's real element type; the direction
is to thread **that** per-local inferred type into `collExpect` at the
specific call-expression node, rather than treating `collExpect` as a single
ambient value any sibling statement can overwrite. This requires auditing
every existing `collExpect` push/pop site (not just `SLocal`) to confirm
none of them rely on the current "one shared value" behavior — real,
cross-cutting compiler-internals work, not a one-line change.

## 8. Issue → design-direction map

| Issue | Gap | Resolved by | Status |
|---|---|---|---|
| `#6029` | 1a | §5 | **Shipped in this PR** (the `@externTarget` explicit-hint path: setter, getter, and no-bracket-suffix ctor inference). Auto-FFI direct-assignment sugar remains — filed as a follow-up (§5 "What this does not fix"). |
| `#1760` | 1b | §7 Gap 1b | Not started — new non-erasing `ByRefLike` value-type category, its own epic. |
| `#5525` | 2 | §7 Gap 2 | Not started — erasure-consistent delegate construction. |
| `#5800` | 2 | §7 Gap 2 | Not started — closes as a side effect of `#5525`'s fix + test. |
| `#5947` | 2 | §7 Gap 2 | Not started — metadata-driven named-delegate construction. |
| `#4601` | 3 | §7 Gap 3 | Not started — per-local `collExpect` threading from the type checker. |
| `#5624` | — | §6 | Not part of this family; recommended for a label/issue split, one item (JVM boxed-slice-field read) reconfirmed unreproducible. |

## 9. What's genuinely new here vs. prior sessions

Every prior session that touched these issues reached "needs a coordinated
pass" and stopped there, correctly, because the pass hadn't been done yet.
This doc is that pass: it (a) confirms the split is 1a/1b/2/3 (not one
thing, not seven things), (b) ships the smallest of the four gaps at
production quality with a real regression test rather than leaving all
seven exactly as found, and (c) gives each remaining gap a concrete,
scoped design direction instead of "this needs more thought" — so the next
session picking up `#1760`, `#5525`/`#5800`/`#5947`, or `#4601` starts from
a design, not from re-reading the same six issue threads again.
