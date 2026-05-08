# 30 — Aspect-to-aspect contract inheritance (sketch)

**Status:** Drafted, exploratory.  Pressure-tests Q-aspects-006
in `docs/26-aspects.md`.
**Builds on:** D047 (composed contracts in §5.1, around-body
nesting in §6, verifier interaction in §11),
`docs/27-aspect-libraries.md` (library aspects' contract
clauses participating in composition), `docs/28-std-aspects-sketch.md`
(the `Validation` + `Authorization` motivating example).
**Decision-log entry:** None — this is a sketch, not a spec.

---

## 1. Motivation

D047 §5.1 establishes that aspect contract clauses augment the
*target's* contract — every aspect's `requires:` and `ensures:`
joins into the wrapper's composed pre/postcondition.  But D047
§11's verifier story discharges each aspect's body
**independently against the target's bare contract**.  Each
aspect sees only `T.requires` / `T.ensures`; no upstream
aspect's clauses flow into a downstream aspect's body.

This is sound but pessimistic.  Concrete pattern from the
`Std.Aspects` sketch (28 §3):

```lyric
use Std.Aspects.Validating matches: name like "handle*" and visibility: pub
use Std.Aspects.Auth as TenantAuth
                   matches: name like "handle*" and visibility: pub
                   inside:  Validating
```

`Validating.requires:` adds `nonNull(args.user)` to every
matched handler's wrapper precondition.  `Auth`'s body then
reads `args.user.permissions` — but the verifier can't prove
non-null access from `T`'s contract alone.  Auth's body
ought to be able to *assume* Validating's `nonNull(args.user)`
because by the time Auth runs, Validating's before-half has
already executed inside the same wrapper.

Q-aspects-006 asks: should aspect contract clauses inherit
along the composition chain?  This sketch proposes **yes**,
with a precise pre/post-symmetric rule and a worked-example
walkthrough of the cases that get more / less expressive.

---

## 2. The current v1 model

For wrapper `W = A₁ ⊃ A₂ ⊃ ... ⊃ Aₙ ⊃ T` (outer-to-inner
nesting per D047 §6):

```
wrapper(args):
  // 1. wrapper's composed requires checked here
  A₁.before                     (A₁'s around body up to proceed)
    A₂.before
      ...
        Aₙ.before
          target(args)
        Aₙ.after                (rest of Aₙ's around body)
      ...
    A₂.after
  A₁.after
  // 2. wrapper's composed ensures checked here
```

D047 §11 says the verifier discharges:

- **Wrapper-level VC**: at boundary 1, prove the composed
  precondition entails what the target's body needs at boundary
  2 ; at boundary 2, prove the composed postcondition.
- **Per-aspect-body VC**: each Aₖ's body is verified
  *individually* — the verifier assumes `T.requires` at entry
  and proves `Aₖ.ensures` at exit, but doesn't assume any
  *other* aspect's clauses.

The current rule is correct but loses information: by the time
Aₖ runs, A₁..Aₖ₋₁'s before-halves have already established
their `requires:` clauses — the verifier just doesn't pass that
to Aₖ's body.

---

## 3. The proposed model — cumulative inheritance

For aspect Aₖ's around body, when verifying:

### 3.1 Before `proceed`

**Assumption set:** `T.requires ∧ A₁.requires ∧ A₂.requires ∧
... ∧ Aₖ.requires`.

The wrapper's composed precondition was checked at boundary 1.
Every aspect's `requires:` held at entry and the cumulative
conjunction has remained true through outer aspects' before-halves
*provided no aspect rewrote `args`* (see §3.3).  Aₖ's own
`requires:` has held since entry too (it's part of the wrapper's
composed precondition).

**Obligation:** prove anything Aₖ's body asserts before
`proceed`, plus the consumer-side D047 §4.2 boundary check
(target's `requires:` against the args passed to `proceed`).

### 3.2 After `proceed`

**Assumption set:** `T.ensures ∧ Aₙ.ensures ∧ Aₙ₋₁.ensures ∧
... ∧ Aₖ₊₁.ensures` against the value of `ret`.

Each inner aspect's `ensures:` held at its own return-point.
Because aspects nest, by the time control returns to Aₖ's
after-half, every aspect strictly inside Aₖ has finished and
their `ensures:` clauses have been established.

**Obligation:** prove `Aₖ.ensures` against `ret` at exit.

### 3.3 Args rewriting (D047 §4.2 mut bindings)

If any A_j for j < k rewrote `args` before calling
`proceed(args')`, the picture changes.  Two options:

- **Conservative (lean):** inheritance only works on the
  *un-rewritten* `args`.  As soon as an upstream aspect
  rewrites, downstream aspects lose access to upstream
  requires (they may still hold for the new args, but the
  verifier doesn't track preservation).
- **Aggressive:** rewriters bear the obligation to preserve
  every upstream `requires:` clause across the rewrite —
  the wrapper inserts assertions just like it does for
  target-`requires:` per D047 §4.2.  More expressive, more
  work for the verifier, more work for aspect authors.

I lean **conservative**.  Most real aspects don't rewrite
args (read-only observers); the rewriting case is rare
enough to deserve an opt-in escape hatch (`@preserves(<list
of upstream aspects>)` annotation if it ever lands).
Aggressive can be added later without breaking conservative.

---

## 4. Worked examples

### 4.1 Validating + Authorization (the motivating case)

```lyric
package CheckoutService

use Std.Aspects.Validating
    matches: name like "handle*"
use Std.Aspects.Auth as TenantAuth
    matches: name like "handle*"
    inside:  Validating          // composition order: Validating outer

@public_api
pub func handleCreateOrder(request: in CreateOrderRequest)
        : Result[Order, CreateError] { … }
```

Composition: `Validating ⊃ TenantAuth ⊃ handleCreateOrder`.
Wrapper composed contract:

```
requires:
  T.requires                        (handleCreateOrder's own)
  nonNull(args.user)                (Validating)
  args.callerToken != ""            (TenantAuth)
```

When verifying TenantAuth's body:
- Before `proceed`: assume `T.requires ∧ nonNull(args.user)
  ∧ args.callerToken != ""`.  Now `args.user.permissions`
  inside TenantAuth's body is provably non-null because
  `nonNull(args.user)` is in the assumption set.  The
  verifier's earlier worry — "Auth panics on null" — is
  discharged statically.
- After `proceed`: assume `T.ensures` (no inner aspect to
  inherit ensures from in this 2-aspect example).
- Obligation: prove TenantAuth.ensures (none in the worked
  example) at exit.

When verifying Validating's body (contract-only, no around):
- The body is empty.  No body-level VCs.
- Wrapper-level: Validating's `requires:` becomes part of
  the wrapper's composed precondition (D047 §5.1, unchanged).

### 4.2 Library aspect feeding a local aspect

```lyric
use Std.Aspects.Validating       matches: name like "handle*"
aspect AuditedAccess {
  matches: name like "handle*"
  inside: Validating
  around(args) -> ret {
    log("accessing user ${args.user.id}")    // would panic if user is null
    proceed(args)
  }
}
```

`Std.Aspects.Validating` is a B-mode library aspect.  Its
`requires:` clause references `args.user`; per 27 §9.1.1
shape-verification, the consumer-side compiler has already
checked that every matched target carries a `user` field.

When verifying `AuditedAccess.around`:
- Before `proceed`: assume `T.requires ∧
  Validating.requires`.  `args.user.id` inside AuditedAccess's
  body is reachable via `nonNull(args.user)`, so no NPE.
- The B-mode opacity from 27 §6.1.1 doesn't affect contract
  inheritance: clauses are publish-time metadata, not
  run-time field access by the library body.  The
  *consumer's* aspect (`AuditedAccess`, local) reads
  `args.user.id` directly because it's compiled with full
  visibility — that's D047, unchanged.

### 4.3 Three aspects with both requires and ensures

```lyric
aspect Outer  { ensures: ret.isOk implies wasLogged }
aspect Middle { requires: nonNull(args.token); ensures: usedTokenAtLeastOnce }
aspect Inner  { requires: args.token.length > 0  }
// composition: Outer ⊃ Middle ⊃ Inner ⊃ target
```

Wrapper:

```
requires:
  T.requires ∧ nonNull(args.token) ∧ args.token.length > 0
ensures:
  T.ensures ∧ ret.isOk implies wasLogged ∧ usedTokenAtLeastOnce
```

Verifying Inner.around:
- Before proceed: assume `T.requires ∧ nonNull(args.token) ∧
  args.token.length > 0`.
- After proceed: assume `T.ensures` only (no inner aspects).
- Prove: nothing for ensures (Inner has none).

Verifying Middle.around:
- Before proceed: assume `T.requires ∧ nonNull(args.token) ∧
  args.token.length > 0` (Inner's requires inherited from
  *outside* doesn't make sense — actually yes, Inner is
  inside Middle, so Middle's body runs before Inner's; but
  Inner's requires is part of the wrapper's composed
  precondition, so it holds from boundary 1 onwards).

Wait — that's the subtlety.  Inner is *inside* Middle in the
composition graph.  Middle's body runs *before* Inner's.
But Inner's `requires:` is part of the wrapper's composed
precondition — it had to hold at wrapper entry.  So
Middle's body, even though Inner hasn't run yet at that
point, can still assume Inner's `requires:` from the
boundary check.

This is sound: the wrapper's composed precondition is checked
once at entry; from that point on, every aspect's `requires:`
holds.  Pre-proceed, Middle inherits requires from *every*
aspect in the wrapper (including Inner, which hasn't run
yet) — they all hold by virtue of the wrapper's boundary
check.

So the §3.1 rule is more permissive than I first wrote.
Let me restate:

> **Pre-proceed assumption set for Aₖ.around:**
> `T.requires ∧ ⋀_{i=1..n} A_i.requires`

Every aspect's requires inherited, regardless of nesting
position.  The wrapper-boundary check guarantees them all.

> **Post-proceed assumption set for Aₖ.around:**
> `T.ensures ∧ ⋀_{i>k} A_i.ensures`

Only *strictly inner* aspects' ensures inherited.  Outer
aspects' after-halves haven't run yet when Aₖ.after runs.

The asymmetry is real: requires is "everyone's, all the
time" (wrapper checks it at entry once); ensures is
"strictly inner only" (it's a temporal walk back out).

Verifying Outer.around then:
- Before proceed: assume `T.requires ∧ nonNull(args.token) ∧
  args.token.length > 0`.
- After proceed: assume `T.ensures ∧ ret.isOk implies wasLogged
  ∧ usedTokenAtLeastOnce` — wait that's wrong, Outer.ensures
  is `ret.isOk implies wasLogged`; we don't assume our own
  ensures.
- After proceed: assume `T.ensures ∧ Middle.ensures ∧
  Inner.ensures` = `T.ensures ∧ usedTokenAtLeastOnce` (Inner
  has no ensures).
- Prove: `ret.isOk implies wasLogged` (Outer's ensures).

### 4.4 Skip / replace patterns

```lyric
aspect CircuitBreaker {
  around(args) -> ret {
    if breakerOpen() { return Err(error = TripError) }
    proceed(args)
  }
}
```

If CircuitBreaker short-circuits (no `proceed`), no inner
aspect runs at all.  Inner aspects' `requires:` clauses are
**vacuously satisfied** at runtime (caller is never reached).
At verification time, the inner aspect's `requires:` was
proven at the wrapper boundary; whether it would have held
"down there" is moot.  Inner aspects' `ensures:` aren't
established because their bodies didn't run — but the
wrapper's composed `ensures:` is what callers see, and
that's checked at exit.  If CircuitBreaker's short-circuit
return doesn't satisfy the composed ensures, the wrapper
fails (D047 §5).

So skip-replace doesn't break inheritance: the wrapper
boundary checks subsume everything.

---

## 5. Verifier interaction (revising D047 §11)

D047 §11 defines four VC families.  Q-aspects-006's change is
a small mechanical extension to step (3) — per-aspect-body
verification.

Revised step (3): for each aspect Aₖ's around body, the
verifier:

1. **Pre-proceed phase:** add `T.requires ∧ ⋀_{i=1..n}
   A_i.requires` to the assumption set.  Verify the body
   prefix (before `proceed`) under this assumption.
2. **Post-proceed phase:** at the `proceed` call, switch to
   `T.ensures ∧ ⋀_{i>k} A_i.ensures` (against `ret`).
   Verify the body suffix.
3. **Exit:** prove `Aₖ.ensures` against `ret` at the body's
   exit.

Steps (1)–(2) are the inheritance-aware extensions; step (3)
is unchanged.  Wrapper-level VCs (steps 1 and 2 of D047 §11)
are unchanged.

Implementation note: the verifier already builds the
composition graph from D047 §6.  Inheriting clauses is just
"walk the graph and union the clause sets."  No new graph
machinery needed.

---

## 6. Tensions surfaced

### 6.1 — `mut args` rewriting in upstream aspects

Per §3.3, when an upstream aspect rewrites `args`, downstream
aspects' `requires:` clauses no longer hold against the
rewritten args automatically.  Conservative lean: drop
inheritance through rewriters; only target-level invariants
flow.  Aggressive lean: rewriters bear preservation obligations.

**Lean: conservative for v1.x.**  Rewriting aspects are
rare; the conservative rule subsumes the aggressive rule
(it's strictly less expressive but always sound).  Add an
opt-in `@preserves(<aspect names>)` annotation in v2 if
real demand surfaces.

### 6.2 — Library aspect contract reference into local aspect

A library aspect `Std.Aspects.Validating` that adds
`requires: nonNull(args.user)` is consumed by a local
aspect `AuditedAccess` that depends on `args.user`.  Does
inheritance work cross-library?

Yes, mechanically.  The library's clauses are part of the
consumer's wrapper's composed precondition (27 §5.1
unchanged).  Inheritance doesn't care which package the
clause came from.

But there's a *naming* concern: when a verifier diagnostic
says "non-null because `nonNull(args.user)` holds at this
point", which aspect should it credit?  Lean: name the
*originating* aspect (`Std.Aspects.Validating`) plus the
consumer's `use` site (`use Validating matches: ...` at
`app.l:7`).  Mirrors the existing diagnostic provenance from
D047 §5.3.

### 6.3 — Diagnostic provenance for inherited assumptions

When the verifier proves a fact about Aₖ's body using an
upstream aspect's clause, the explanation should make the
inheritance visible:

```
verified: args.user.permissions is non-null at app.l:42
  because nonNull(args.user) holds (Validating, from Std.Aspects)
                                   used at app.l:7
  inherited at this point in the composition (Auth ⊃ TenantAuth)
```

Without this, debugging "why does the verifier think this is
non-null" becomes spooky.  This is a tooling concern, not a
soundness one — but worth nailing down before users hit it.

### 6.4 — Cross-file ordering ambiguity

D047 §6.1 already errors on cross-file aspect overlap with
no explicit ordering.  Inheritance rides on the same
ordering graph; if ordering is ambiguous, inheritance is
too.  No new constraint — inherits the existing error
(`A0007`).

### 6.5 — Async aspects (D047 §13)

Bootstrap-grade async lowering doesn't preserve all
guarantees (D047 §13).  Inheritance through an async
aspect is even more constrained: the suspension-and-resume
points may invalidate the cumulative requires set if the
aspect resumes after some external state changed.

Lean: inheritance is **opt-in for async aspects**.  An
`async pub aspect` body must annotate `@inherits_contracts`
to participate; without it, the verifier falls back to the
v1 "T-only" assumption set.  Defer the exact opt-in syntax;
flag the existence.

### 6.6 — `requires:` referencing non-args expressions

Most aspect `requires:` clauses reference `args.X` (caller-side
data).  But a clause could in principle reference a global
or a `Std.Time.now()`-flavoured expression.  Inheritance
through such clauses is dubious: a global may have changed
between wrapper boundary and Aₖ's body.

Lean: inheritance only works on **`args`-only `requires:`
clauses**.  A `requires:` clause that references anything
other than `args.*` and `call.*` (which is read-only and
constant up to `proceed`) doesn't participate in inheritance;
the verifier falls back to T-only assumptions for that
specific clause.  Conservative; can relax later if a real
use case appears.

---

## 7. What this sketch confirms

- **Inheritance is a small, mechanical extension** of D047's
  existing composition graph and verifier story.  No new
  ordering rules, no new diagnostic codes (the existing
  A0007 / contract-failure provenance covers the surface).
- **Pre-proceed inherits everyone's requires** (boundary
  check guarantees them all); **post-proceed inherits only
  strictly-inner ensures** (temporal walk-back).  The
  asymmetry is justified by the wrapper-boundary semantics.
- **Library aspects participate naturally** (no extra spec
  work).  Inheritance composes with 27's library/consumer
  split: the *clause source* doesn't matter, only its
  position in the composition graph.
- **Skip / replace patterns** (D047 §4.1) don't break
  inheritance — the wrapper boundary subsumes runtime
  flow.

---

## 8. What this sketch wants nailed down before v1.x

- **§6.1 mut-args inheritance** — confirm conservative is the
  right v1.x default; defer aggressive `@preserves` to v2.
- **§6.3 diagnostic provenance** — the inheritance message
  shape (which aspect to credit + composition position).
  Affects debuggability more than correctness, but nailing
  the format early prevents inconsistent renderings later.
- **§6.5 async opt-in** — `@inherits_contracts` annotation
  shape for async aspects, or just "no inheritance through
  async, full stop" for v1.x.
- **§6.6 args-only requires** — confirm inheritance is
  restricted to `args.*` / `call.*`-referencing clauses;
  reject global-touching clauses from the inherited set.

---

## 9. Out of scope

- **Statement-level assertion inheritance.**  An aspect's
  body containing `assert nonNull(x)` is a body-internal
  fact, not a contract clause.  Downstream aspects don't
  see it; this is by design (assertions aren't part of
  the public contract surface).
- **Inheritance across non-aspect wrappers.**  Aspects
  inherit from aspects; an aspect on a target wrapped by
  `wire` / `protected type` machinery doesn't inherit
  from those non-aspect wrappers.  D047 already restricts
  the composition to aspect-only.
- **Multi-target inheritance.**  Each target's wrapper has
  its own composition graph; inheritance is per-target.
  Two different targets matched by the same aspect don't
  share inherited clauses.
- **Verifier-internal optimisations.**  E.g. caching
  inheritance graphs across wrappers.  Implementation
  detail; not in this sketch.

---

## 10. Implications for `Std.Aspects` (28 §6 / §7 revisited)

The 28 §6 list of "what the sketch confirms about the design"
gains an item: **the proposed v1.x inheritance rule unlocks
the canonical 'Validating + Auth' pattern** without forcing
aspect authors to repeat preconditions across every
auth-flavoured aspect.  Without inheritance, every `Auth`-
shaped aspect would have to re-declare `requires:
nonNull(args.user)`; with inheritance, declaring it once on
`Validating` (or any composed-outer aspect) is enough.

The 28 §7 "before-implementation" list grows by one entry:
**inheritance-aware verifier integration** is a precondition
for the `Std.Aspects` ecosystem to be ergonomic.  Without
it, the published-contract benefits of D047 + 27 are
diluted by per-aspect repetition.

---

## 11. References

- `docs/26-aspects.md` (D047) — base aspect spec.  §5.1
  (composition), §6 (ordering), §11 (verifier interaction)
  are the load-bearing sections.
- `docs/27-aspect-libraries.md` — library aspect contract
  surfacing (§5.1 unchanged).  §9.1.1 (B-mode shape
  verification) is orthogonal to inheritance.
- `docs/28-std-aspects-sketch.md` — `Validating` + `Auth`
  motivating example.  §3 worked example.
- D047 §4.2 — `mut args` boundary checks that motivate the
  conservative §3.3 rule.
- D-progress-031 / D-progress-078 — Lyric.Contract
  resource format that carries inheritable clauses across
  package boundaries.
