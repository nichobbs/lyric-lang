# 56 — Row-typed `args` for B′-mode aspects (Option 1 sketch)

**Status:** Specced and shipped in D115. Option 1 (the row-constraint design
below) was chosen over Option 2 (§4's marker-interface alternative) and
implemented: grammar (`where TArgs has { ... }`, `docs/grammar.ebnf`), weaver
(`__LyricBModeArgs_<template>` record synthesis, `args.<field>` rewrite,
A0047 diagnostic), formatter round-trip, and an ecosystem proof-of-value
(`Auth.Aspects.ValidateKey` converted off `@inline_template`). Extends
`docs/55-bmode-aspect-libraries-plan.md` (D114's B′-mode). Cited from
`docs/27-aspect-libraries.md` §12 as Q-aspectlib-009. See D115 for the full
rationale, the Q-row-001–005 resolutions, and verification. D118 fixed a
pre-existing (pre-D115) gap where aspect `requires:`/`ensures:` clauses
referencing `args.<field>` were never enforced at runtime, then used the fix
to retire `@inline_template` from every other field-accessing ecosystem
library aspect (`Web.Aspects`, `Validation.Aspects`, `Mq.Aspects`,
`Ws.Aspects`, `Grpc.Aspects`, `Storage.Aspects`, `Lambda.Aspects`).

---

## 1. The problem this revisits

`docs/27` §6.1.1 draws a hard line: B-mode `args` is opaque (no
`args.<field>`); anything that needs named field access "belongs as a
**local** aspect... or as C-mode." `Auth.Aspects.ValidateKey` needs
`args.apiKey`, so it's C-mode — which means it ships as source text
(`ContractDecl.body`, this PR's D-progress-537 change) and gets
re-parsed/re-typechecked at every consumer use site. The objection that
started this thread: shipping source ties the mechanism to Lyric and
forecloses non-Lyric consumption, and it re-pays parse/typecheck cost
per use site rather than once.

This sketch asks: can `args` carry **named, typed field access** while
staying in the generic/monomorphised world (B′-mode, `docs/55`), instead
of forcing every field-accessing aspect into C-mode?

## 2. Design sketch: an open-record constraint on `TArgs`

Proposed syntax, following the existing `where T: Interface` bound form
(`docs/01-language-reference.md`'s generic function syntax —
`func sum[T](xs: slice[T]): T where T: Add + Default`):

```lyric
@inline_template  // NOTE: still opt-in-flagged, see §6 on naming
pub aspect ValidateKey {
  config {
    enabled: Bool = true
    @sensitive
    expectedKey: String
  }
  around(call) -> ret where TArgs has { apiKey: String } {
    if not enabled {
      ret = call.proceed()
    } else if args.apiKey == "" {
      ret = Err("API key is missing")
    } else if Auth.verifyApiKey(args.apiKey, expectedKey) {
      ret = call.proceed()
    } else {
      ret = Err("API key is invalid")
    }
  }
}
```

`TArgs has { field: Type, ... }` is a **row constraint**: it says "TArgs
must be a record-shaped type that includes (at least) these named fields
at these types," without naming or fixing the *rest* of TArgs's shape (the
"row variable" — the part of the record this aspect doesn't care about).
This is standard row polymorphism (OCaml/PureScript object/variant rows,
Elm's extensible records); Lyric has **no existing structural-typing
concept at all** — confirmed by grep across `docs/01-language-reference.md`
and `grammar.ebnf` for "row", "structural", "has {", "open record": zero
hits outside unrelated uses of "structural" for record equality. This
would be a first for the language, not an extension of something half-built.

## 3. Type-checking: why this doesn't need general structural typing

The naive version of this feature is "add row-polymorphic types to the
language generally" — genuinely large (docs/55 §4's framing of this as
"the biggest lever" understates how much it touches: every generic
function, every `where` clause, every place a type gets displayed or
diffed in tooling). The narrower version, scoped to aspect `args`, is
smaller because of one structural fact: **`TArgs` is never a type the
user names or writes down.** It's always compiler-synthesized per B′-mode
specialisation, from the matched function's actual parameter list
(`docs/55` §3.2). That means row *satisfaction* checking doesn't need
general row unification — it only needs, at each specialisation site
Mono considers:

1. Read the row constraint's field list off the aspect declaration once
   (`{apiKey: String}`).
2. Check the candidate matched function's parameter list contains each
   named field at a compatible type — a simple linear scan, not a
   unification algorithm, because the synthesized `TArgs` is always a flat
   product of the target's actual named parameters (no nested rows, no
   row variables the user can name or combine).
3. If satisfied, Mono proceeds to specialise as it would for any other
   B′-mode shape (`docs/55` §3.2/§4); if not, this is a **weave-time**
   diagnostic (new code, e.g. `A0047`), not a downstream type error —
   matching the existing `A0042` precedent for C-mode's `args.<field>`
   mismatch (`weaver.l:2313`).

This is why `docs/55` §4 argues row typing composes with monomorphisation
and not with true reified generics: under monomorphisation, "does this
concrete instantiation satisfy the row" is decided once, per specialised
copy, with full knowledge of the concrete target shape. Under true
reified generics, the same question has to be answered for an unknown,
not-yet-known instantiation, which needs a runtime witness/dictionary
mechanism — a fundamentally different (and larger) problem. **Scoping to
"TArgs is always compiler-synthesized, never user-named" is what keeps
this in the "structural check at a known finite set of specialisation
sites" regime instead of the "general row-unification type theory"
regime.**

## 4. Whether this is really "smaller" than Option 2 (marker interfaces)

The earlier conversation compared this (Option 1) against a narrower
alternative (Option 2): auto-synthesize a nominal marker interface per
`(aspect, field-shape)` pair and require the specialised `TArgs` to
implement it, reusing the `impl <ExternInterface> for Record` →
`InterfaceImpl` emission pattern (`docs/51`). Restated against the scoped
version of Option 1 above, the gap between them narrows considerably:

| | Option 1 (row constraint, scoped) | Option 2 (marker interface) |
|---|---|---|
| New syntax | `where TArgs has {...}` — genuinely new grammar | None — inferred from `args.<field>` usage, same as today's A0042 detection |
| Type-checker surface | New constraint *kind*, even if satisfaction-checking is narrow (§3) | None — satisfaction is structural-scan + synthesized `impl`, no new constraint kind in the type checker at all |
| Codegen | Reuses B′-mode's existing per-shape specialisation (§3, step 3) | Synthesize one interface + one `impl` per shape, reusing `docs/51`'s emission path directly |
| User-visible language surface | Permanent — `has {...}` becomes documented syntax, teachable, shows up in `lyric doc`/LSP | None — entirely invisible compiler machinery |
| Generalises beyond aspects | Yes, in principle (the constraint kind could later apply to any generic function, not just synthesized `TArgs`) | No — deliberately a private aspect-args-only mechanism |

Scoping Option 1 down to "only ever applied to compiler-synthesized
`TArgs`" (§3) removes most of the type-theory risk `docs/55`'s earlier
blast-radius comparison worried about (row unification, subtyping under
extension, SMT encoding for the verifier) — those only bite if row types
become *general* (nameable in ordinary `where` clauses, appearing in
arbitrary user code). If this sketch stays scoped to aspect `args`
specifically, and the constraint is never something a user writes on an
ordinary generic function, most of that risk doesn't apply.

**What Option 1 still costs that Option 2 doesn't:** new parser/grammar
surface, a new constraint AST node, and — the one piece that doesn't
shrink no matter how narrowly this is scoped — **teaching users a new
concept** (`has {...}` row constraints) versus zero new user-facing
surface for Option 2. That's a real, durable cost even in the scoped
version: once `has {...}` syntax exists and is documented, it's part of
the language forever, discoverable, and someone will eventually ask "can
I use this on my own generic function?" — at which point the pressure to
generalize it (and take on the type-theory cost §3 sidesteps) shows up
anyway.

## 5. Verifier interaction

`docs/27` §9 already establishes that `lyric prove` discharges contracts
against the *woven* body via `Lyric.Weaver.weaveFile` before VC
generation. Because §3's scoped row-satisfaction check happens at
specialisation time (Mono has already produced a concrete, monomorphic
`IFunc` with `TArgs` resolved to a real record type before the verifier
ever sees it), **the verifier needs no new SMT theory for open records** —
by the time `vcgen.l` walks the woven body, `args.apiKey` is an ordinary
field access on an ordinary (fully concrete) record type, exactly like
any other verified aspect body today. This is a direct consequence of
scoping to synthesized `TArgs` (§3) rather than general row types: if this
sketch generalized to arbitrary user-written generic functions with row
constraints, the verifier *would* need genuinely new machinery (proving a
property for all types satisfying an open constraint, not just the one
concrete instantiation in front of it) — another reason to keep this
scoped.

## 6. Naming and surface questions this sketch leaves open

**All five resolved in D115** (see that entry for full rationale); kept
below as the pressure-test record per the sketch-doc convention.

- **Q-row-001 — Keyword/spelling.** `has { ... }` is a placeholder.
  Alternatives: `where TArgs: { apiKey: String }` (record-literal-as-type
  syntax, reuses existing `:` bound syntax but risks visual confusion with
  nominal interface bounds); a dedicated marker like
  `where TArgs provides apiKey: String`. Needs a real syntax-design pass,
  not decided here.
  **Resolved (D115):** shipped `has { ... }` verbatim, as a contextual word
  recognised only in this grammar position (not a reserved keyword).
- **Q-row-002 — Does this replace `@inline_template` as the trigger, or
  compose with it?** The sketch example in §2 still carries
  `@inline_template`, which is arguably wrong — a row-constrained B′-mode
  aspect is explicitly *not* C-mode (it doesn't ship/re-parse source text
  at the consumer). The trigger for "this aspect needs row-checked field
  access" should probably be the presence of a `where TArgs has {...}`
  clause itself, with `@inline_template` staying reserved for genuine
  C-mode. Needs reconciling with `docs/55` Q-bmode-004's B′-mode
  inference question.
  **Resolved (D115):** the row clause's presence is the trigger;
  `@inline_template` stays reserved for C-mode. The §2 example's
  `@inline_template` annotation was dropped in the shipped design.
- **Q-row-003 — Multiple aspects on one target, each with different row
  requirements.** If two B′-mode row-constrained aspects both match the
  same function, do their row constraints compose (union of required
  fields) or does each get an independently-specialised `TArgs` view? The
  existing composition model (`docs/26` §5, composed contracts) doesn't
  have an analogous case to generalize from since C-mode's `args.<field>`
  rewrite is per-aspect-per-call, not a shared typed view.
  **Resolved (D115):** neither — resolved for free. Each template gets its
  own synthesised args record and its own independent per-match
  satisfaction check; two templates matching the same function each get
  their own `__lyric_args` parameter with no composition/union logic
  needed.
- **Q-row-004 — Optional fields / row extension operators.** Real row-type
  systems typically need more than "has these fields" (e.g. "has these
  fields and nothing else," or default values for absent fields). Decide
  whether v1 needs anything beyond the simplest "at least these fields,
  rest ignored" form in §2, or whether that's sufficient for every
  realistic aspect use case (it likely is — no shipped or sketched aspect
  needs row *exclusion*).
  **Resolved (D115):** shipped the simplest "at least these fields, rest
  ignored" form only; no exclusion or default-value operators.
- **Q-row-005 — Should this ship at all, versus Option 2?** Restating
  `docs/55`'s framing honestly: Option 2 (marker interfaces) gets
  everything in the "what B′-mode + field access needs" column with less
  permanent language surface. Option 1's case rests on it generalizing
  usefully beyond aspects someday (structural typing has obvious
  candidate uses in `docs/40`'s source-generator work, or generic
  serialization) — a bet on future demand this sketch doesn't resolve.
  If that bet doesn't pan out, ship Option 2 instead and treat this
  sketch as declined, not deleted (per the sketch-doc convention:
  keep the pressure-test record, mark it superseded if a decision
  goes the other way).
  **Resolved (D115):** ship Option 1. See D115's Context/Decision for what
  changed the calculus (Option 2 turned out to need its own new internal-
  interface-synthesis plumbing too, not literally zero new mechanism).

## 7. What this sketch does not cover

- True reified B-mode's interop story (`docs/55` §2/§3.3) is orthogonal —
  row typing over synthesized `TArgs` says nothing about whether a
  non-Lyric caller could ever invoke a row-constrained B-mode aspect
  directly. If the reified-generics epic ever lands, it would need its
  own answer to "how does a runtime witness prove row satisfaction,"
  which is a materially different (harder) problem than §3's
  specialisation-time check.
- JVM parity is not separately analyzed here because §5's conclusion
  (row satisfaction resolved before codegen sees a generic type at all)
  means this sketch inherits `docs/55` §"Phase 4"'s conclusion for free:
  no JVM-specific work, since by the time `jvm/bridge.l` sees the woven
  body, `TArgs` is already a concrete, resolved record type.
