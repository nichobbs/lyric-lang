# 55 — B-mode aspect library ABI: implementation plan

**Status:** Unbacked implementation plan. Extends `docs/27-aspect-libraries.md`
§6.1 (D047-revision 2026-05-08, Q-aspectlib-001 — "hybrid B + C", spec'd but
**not implemented**; see "Current state" below). Prerequisite for
`docs/56-row-typed-aspect-args-sketch.md` (Option 1 row-polymorphic `args`).
**Decision-log entry:** none yet — this plan proposes revising Q-aspectlib-001's
"Resolved" note, which currently overclaims implementation status (see §1).

---

## 1. Current state — B-mode does not exist, and the doc trail overclaims it

`docs/27-aspect-libraries.md` §6.1 and the D047-revision log entry for
Q-aspectlib-001 (`docs/03-decision-log.md` line 1978) both read as if B-mode
shipped: *"library DLL carries both generic IL for B-mode aspects **and**
embedded source resources for C-mode aspects."* It doesn't. A repo-wide grep
for `Around<`, generic-monomorphised aspect codegen, or any B-mode-specific
emission in `lyric-compiler/lyric/weaver/weaver.l` and
`lyric-compiler/msil/bridge.l` turns up nothing. The only real,
CI-tested, shipped cross-package aspect mechanism is C-mode
(`@inline_template`) — every ecosystem aspect (`Auth.Aspects.ValidateKey`,
`Web.Aspects.RequiresAuth`, `Web.Aspects.RateLimit`, `Ws.Aspects.WsAuth`,
`Resilience.Retry`, …) is C-mode today, not because library authors chose
it over B-mode, but because B-mode was never buildable.

**Action item bundled with this plan:** once a decision-log entry backs
this doc, update Q-aspectlib-001's "Resolved" note to say B/C were resolved
*at the spec level* in 2026-05-08, with B-mode's *implementation* tracked
here, and correct `docs/27` §6.1's "ships as a generic method" framing to
match whichever variant (§3 below) is actually built.

## 2. A harder blocker than "wire up the aspect ABI": generic methods don't exist

The framing in `docs/27` §6.1 — *"a `pub aspect` ships as a generic method
in the library DLL"* (`static TRet Around<TArgs, TRet>(...)`) — describes a
**reified CLR open generic method** (`MVAR`-typed, `MethodDef`-owned
`GenericParam` rows). Per `docs/43-in-bundle-generics-plan.md`'s own open
question **Q-GEN-002**: the self-hosted MSIL emitter reifies **generic
types only** (records/unions get `GenericParam` table (0x2A) rows + `VAR`
fields + `TypeSpec` instantiation). Generic *functions/methods* are
explicitly out of scope for that plan and are handled exclusively by
**`Lyric.Mono`** — call-site monomorphisation that emits a specialised,
non-generic copy per concrete type-argument combination
(`lyric-compiler/lyric/mono.l`). There is no MVAR/MethodDef-GenericParam
emission path in the self-hosted MSIL backend today, for *any* generic
function, aspect or otherwise.

This means "ship `Around<TArgs,TRet>` as one generic method, consumer
instantiates it" is not an aspect-shaped gap — it's a **compiler-wide,
generics-architecture gap** that would need its own epic (reify generic
*methods*, not just types: `MethodDef`-owned `GenericParam` rows, `MVAR`
operand encoding, call-site `MethodSpec` emission, JVM parity story on
top of type erasure). That epic is out of scope here. Building it only to
unblock aspects would be backwards — if it's worth doing, it's worth doing
as its own decision-logged plan that benefits every generic function, not
a side effect of the aspects work.

**So this plan does not attempt reified B-mode.** It proposes a variant —
call it **B′-mode** — that gets the *type-safety and zero-boxing* half of
B-mode's motivation using infrastructure that already exists, and is
explicit about which half of the motivation it does **not** solve.

## 3. B′-mode: cross-package monomorphisation, not reified generics

### 3.1 What already exists to build on

- **`Lyric.Mono.monoFileWithImports`** (`lyric-compiler/lyric/mono.l`)
  already monomorphises **cross-package** generic function calls: it
  accepts `importedGenDecls` so a caller in package A can specialise a
  generic function whose `IFunc` declaration lives in package B, producing
  a mangled specialised copy (`mapFoo__Int__String`) compiled directly
  into A. This is opt-in and, per its own doc comment, soundness depends
  on "the imported function's body referencing only items the user's
  compilation unit can resolve" — the wider cross-package symbol
  resolution is described as depending on `Lyric.RestoredPackages` (Band 6).
- **`Lyric.RestoredPackages`** (`lyric-compiler/lyric/restored_packages.l`,
  #1229 Phase A.3.2) already turns a restored dependency DLL's contract
  metadata into a synthesised, type-checkable preamble — the mechanism
  this PR's `contract_meta.l` change (D-progress-537) extended to carry
  `@inline_template` aspect bodies.
- **`from`-instance resolution, config merging, contract composition**
  (`Lyric.Weaver.resolveFromInstanceItem`, `mergeAspectConfig`,
  `collectAspectTemplates`) are ABI-agnostic today — they resolve *which*
  template a consumer's `aspect X from Lib.Y { matches: ... }` refers to
  and merge config, entirely independent of whether the matched template
  turns out to be B′-mode or C-mode. **This machinery is shared, not
  duplicated, by the plan below.**
- **`impl <ExternInterface> for Record` → `InterfaceImpl` row emission**
  (`docs/51-ffi-interfaces-proposal.md`) is the reusable pattern for
  auto-synthesising interface conformance from resolved metadata — cited
  here because §5 below and `docs/56` §5 both reuse it for a different
  purpose (field-access markers), not because B′-mode itself needs it.

### 3.2 The B′-mode shape

A `pub aspect` **without** `@inline_template` is B′-mode by default (this
matches the "B is the default, C is opt-in" framing docs/27 already
committed to). Instead of shipping compiled generic IL, the library ships
the aspect's **parsed, type-checked `AspectDecl`** (config schema,
`around` body AST, contracts) as contract metadata — structurally the same
payload this PR already wires for C-mode
(`Lyric.ContractMetaEmit`/`contract_meta.l`'s new `aspectBodyText`/
`reprForAspect`), but consumed differently:

- **C-mode today:** the weaver re-parses the embedded body text and
  inlines it, rewriting `args.<field>` to the matched function's actual
  parameter (name-only match, A0042 on miss — see the live example in the
  `ValidateKey` conversation this doc's sibling thread walked through).
- **B′-mode (proposed):** the weaver treats the template's `around` body
  as a **generic function body** with an implicit type parameter `TArgs`
  standing in for "the matched function's parameter tuple," and hands it
  to `Lyric.Mono.monoFileWithImports` to specialise **once per distinct
  concrete `(TArgs, TRet)` pair** across all call sites that share that
  shape — not once per call site regardless of type, which is what C-mode
  effectively does today by re-parsing per use.

The consumer-visible difference from C-mode is small (both still compile a
specialised copy into the consumer's own DLL — see §3.3 for what this does
and doesn't buy you), but it changes two things that matter:

1. **`args` stays parametric/opaque** in the template body — B′-mode
   aspects cannot do named field access (`args.apiKey`) at all, matching
   Q-aspectlib-§5.1's original "anonymous parametric record" rule. This is
   the correctness lever, not a codegen detail: it's what lets the library
   author's body be verified *once*, generically, rather than per matched
   target shape. `ValidateKey`-shaped aspects (need `args.apiKey`) stay
   C-mode; `Logging`/`Tracing`/`Timing`-shaped aspects (treat `args`
   opaquely, pass it to `proceed`, print it via `Display`) become B′-mode
   candidates.
2. **Specialisation keys on `(TArgs, TRet)` shape, not call site.** Ten
   handlers with an identical parameter tuple share one specialised
   `Around` copy in the consumer DLL; C-mode recompiles per instantiation
   regardless. This is the "avoid per-use-site cost" win B-mode was
   supposed to deliver, achieved via dedup at the Mono layer rather than
   via CLR-level generic sharing.

### 3.3 What B′-mode does and does not solve

Be explicit about this, because it's the crux of the "is this worth
building separately from row polymorphism" question from the originating
conversation:

| | C-mode (today) | B′-mode (this plan) | True B-mode (§2, out of scope) |
|---|---|---|---|
| Zero boxing on primitives | Yes | Yes | Yes |
| Static type safety | Yes | Yes | Yes |
| `args.<field>` access | Yes (name-rewrite) | **No** (opaque) | No (opaque, per docs/27 §6.1.1) |
| Per-shape dedup across call sites | No (recompiles per use) | **Yes** (Mono specialises once per shape) | Yes (one shared IL body) |
| Consumable from C#/F#/Java (non-Lyric) | No | **No** | **Yes** |
| Needs the reified-generic-methods epic (§2) | No | No | **Yes** |

**The honest conclusion:** B′-mode does not resolve the "tied to Lyric,
not usable elsewhere" objection any better than C-mode does — both still
require the consumer to be compiling with the Lyric toolchain, which
specialises the template body into the consumer's own DLL. Only true
reified B-mode (§2) produces a library artifact a non-Lyric caller can
invoke directly, and that's gated on the separate generic-methods epic.
What B′-mode *does* buy over C-mode: it restores the "`args` is opaque,
verified once generically" discipline the docs always intended for the
non-field-access aspects (the majority of the ecosystem's shipped
aspects — `Logging`, `Tracing`, `Timing`-shaped), and it removes the
per-call-site recompilation cost for that class of aspect. That's real
value independent of whether the interop story ever gets solved, and it's
the piece worth shipping now.

## 4. Why this is the right foundation for `docs/56` (row polymorphism)

The follow-on conversation asked whether row-polymorphic `args` (Option 1
— `where TArgs has {apiKey: String}`) should be built on top of true
reified generics or on top of monomorphisation. **It composes far more
naturally with B′-mode than with true B-mode:**

- A row constraint needs to be *checked* against a concrete shape at some
  point. Under monomorphisation, that check happens once per specialised
  copy, at the same point Mono already infers concrete type arguments —
  no new runtime machinery, just an extra predicate on which
  specialisations `Lyric.Mono` is willing to produce.
- Under true reified generics, satisfying an open-record constraint for
  an *arbitrary, unknown-at-compile-time* instantiation would need a
  runtime witness/dictionary-passing scheme (roughly what Rust trait
  objects or Haskell type-class dictionaries do) — a much larger runtime
  and ABI design, on top of the already-out-of-scope MVAR epic.

So: **ship B′-mode now** (this plan), and treat `docs/56`'s row-typed
`args` as a follow-on extension of B′-mode's monomorphisation path, not of
the (unbuilt, likely much later) true-generics path. True reified B-mode
stays a separate, optional, interop-motivated epic that neither this plan
nor `docs/56` is blocked on.

## 5. Phased work items

Phases are sequenced so each is independently mergeable and each expands
real ecosystem coverage (an observer-style aspect converts from C-mode to
B′-mode and gets its per-use-site recompilation removed) rather than
landing inert scaffolding.

### Phase 0 — Contract metadata: distinguish B′ from C

- Extend the `ContractDecl(kind = "aspect")` shape this PR added
  (`lyric-compiler/lyric/contract_meta.l`) with a mode discriminator
  (`bmode: Bool`, or a `kind` value split into `"aspect_c"` /
  `"aspect_b"`) so a restored dependency's contract metadata tells the
  consumer which path to route through. Today every embedded aspect body
  is implicitly C-mode (gated on `hasInlineTemplateAnnotation`); Phase 0
  adds the non-`@inline_template` `pub aspect` case, still embedding the
  body (needed either way — see §3.2), tagged B′.
- Update `docs/45` §"Format Version 3" field table if the discriminator
  needs a new JSON field (additive — doesn't bump `formatVersion`).

### Phase 1 — Weaver: B′-mode resolution and specialisation-key computation

- Add a `resolveFromInstanceItemBMode` sibling to
  `Lyric.Weaver.resolveFromInstanceItem` (`weaver/weaver.l:2702`) that,
  instead of inlining the template body, computes the matched function's
  `(TArgs, TRet)` shape (the ordered parameter-type tuple and return type)
  and registers `(template identity, shape)` as a **specialisation key**.
- Do **not** apply the `args.<field>` rewrite pass — B′-mode templates
  must fail closed (a clear diagnostic, new code e.g. `A0046`) if they
  reference `args.<field>`, since that's exactly the C-mode-only rewrite
  this mode intentionally omits. This is a straightforward reuse of the
  existing `aspectTemplateIsCMode` detector (`weaver.l:2649`) inverted:
  if a `from`-instance resolves to a non-`@inline_template` template *and*
  the template body is later found to reference `args.<field>`, emit
  `A0046` at weave time rather than letting it fall through to a
  confusing downstream error.

### Phase 2 — Mono: generic-shape specialisation for aspect bodies

- Add a `monoAspectAroundBody` entry point in `Lyric.Mono` (or a thin
  wrapper calling `monoFileWithImports` with the aspect's `around` body
  reframed as a synthetic generic `IFunc(TArgs, TRet)`) that, given the
  set of specialisation keys Phase 1 collected, emits one specialised
  copy per distinct `(TArgs, TRet)` shape into the consumer's compilation
  unit, and rewrites each matched function's wrapper to call the
  shape-appropriate specialised copy instead of inlining.
- Dedup is the whole point of this phase: verify with a fixture where two
  handlers share a parameter shape and assert only one specialised copy
  is emitted (mirrors the dedup assertions already used for record/union
  monomorphisation in `mono_self_test.l`).

### Phase 3 — MSIL codegen

- No new emitter primitives needed (§2 established this deliberately) —
  Phase 2's output is ordinary specialised (non-generic) `IFunc`s, which
  the existing MSIL backend already compiles. The only net-new codegen
  concern is the `proceed: (TArgs) -> TRet` parameter shape: reuse the
  **strongly-typed lambda ABI** from Epic #1877 (D113, `docs/52`) —
  `proceed` becomes a real `System.Func<...>`-shaped closure argument
  (direct `ldftn`/closure-class dispatch, no `Uniform Func ABI` erasure),
  which already ships as of the closure-zero-overhead work.

### Phase 4 — JVM parity

- JVM generics are erased-to-`Object` + `checkcast` by design decision
  (`docs/44` §J4, "accept erased + `checkcast` for v1... this is the
  accepted design stance, not a stopgap"). B′-mode's Mono-based
  specialisation sidesteps this entirely on the JVM side too: Phase 2's
  specialised copies are ordinary non-generic functions before they ever
  reach `jvm/bridge.l`, so **no JVM-specific generics work is needed** —
  the existing `monoFileWithImports` + `collectStdlibGenericFuncsJvm`
  cross-package monomorphisation path (`docs/44` line 173, tracked
  #1707) already does same-shape work for ordinary generic functions;
  this phase is "make sure aspect bodies flow through the same path,"
  not new JVM codegen.
- This is a direct, load-bearing reason B′-mode (not true B-mode) is the
  right thing to build now: true reified generics would need an
  *independent*, likely much harder, JVM story (real `invokedynamic`
  bridge methods or accept boxing-on-JVM as a platform-parity exception,
  which `docs/33`'s remediation-plan pattern would require its own
  decision-log entry to accept). B′-mode has zero JVM-specific delta.

### Phase 5 — Ecosystem migration (proof of value)

- Convert one real shipped aspect from C-mode to B′-mode as the
  acceptance test — `lyric-logging`'s `CallLogging` or `lyric-otel`'s
  tracing aspect are the natural candidates (pure observers, no
  `args.<field>` access per the existing `docs/27` worked examples).
- Runtime regression coverage mirrors the pattern `aspect_weave_self_test.l`
  already established for C-mode: weave a B′-mode aspect onto a real
  function, assert the woven behaviour, on both `--target dotnet` and
  `--target jvm`.

## 6. Open questions

- **Q-bmode-001 — Specialisation-key granularity.** Should shape-keying
  use structural type equality (two records with the same field layout
  but different names are "the same shape") or nominal equality (must be
  literally the same types)? Structural is more dedup-friendly but is
  itself a small step toward `docs/56`'s row-typing direction — worth
  deciding explicitly rather than drifting into it.
- **Q-bmode-002 — Contract-hash interaction.** If a B′-mode template body
  changes between library versions, every consumer needs to re-specialise
  (same as any generic-function ABI change). Does this need its own
  breaking-change signal beyond the existing `@stable(since=...)`
  machinery `Q-aspectlib-004` already covers for `requires:`/`ensures:`
  changes, or does it fall out of that mechanism for free since the body
  is part of the contract hash?
- **Q-bmode-003 — When does true reified B-mode become worth it?** If
  cross-language (non-Lyric) consumption of library aspects is never
  actually requested, the §2 epic may never be worth its cost. Track as a
  standing question rather than committing either way now.
- **Q-bmode-004 — A0046 diagnostic wording and whether B′-mode should be
  inferred or explicit.** Should a `pub aspect` without `@inline_template`
  be B′-mode by silent default (matching docs/27's original framing), or
  should it require an explicit opt-in annotation (e.g. `@bmode`) so a
  library author's *intent* is visible in source rather than inferred
  from the absence of `@inline_template`? Leaning toward silent default to
  match the already-published docs/27 framing, but flagging since this
  PR's own review (see #4552-#4555 on PR #4546) showed how easy it is for
  an implicit convention to drift from what the code actually enforces.
