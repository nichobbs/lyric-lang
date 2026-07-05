# 58 — Library-contributed DI extensions: config templates, `contributes[T]`, wire templates

**Status:** Unbacked sketch — pressure-tested across a design conversation,
no decision-log entry yet. Written up per the discussion's conclusion;
before implementation, the open tensions in §7 need explicit decisions
recorded as a new `D-` entry in `docs/03-decision-log.md`.
**Builds on:** `docs/25-config-blocks.md` (D046 — config-block semantics
this extends), `docs/01-language-reference.md` §10 (wire / DI — the
resolution model this extends), `docs/26-aspects.md` §18 and
`docs/27-aspect-libraries.md` (D047/D050 — the "library declares a
reusable typed extension point; consumer instantiates with local
overrides" idiom this borrows and adapts), `docs/24-build-features.md`
(D045 — settles the `@cfg`-is-compile-time-only /
config-is-runtime-only boundary this proposal must respect).
**Decision-log entry:** none yet.

---

## 1. Motivation

A library like `lyric-web` wants to expose a coherent, typed,
overridable configuration and wiring surface — "here's everything you
need to run a server: static file serving, error handlers, a
middleware pipeline, sane defaults for all of it" — without forcing
every consumer to hand-assemble each piece.

Three existing mechanisms each cover part of this and none covers all
of it:

- **`config { }` blocks** (`docs/25-config-blocks.md`, D046) are typed
  and env-var-backed, but **package-private by design** — `pub config`
  is rejected (`G0008`). A library cannot expose one for a consumer to
  fill in.
- **`wire { }` blocks** (`docs/01-language-reference.md` §10) are
  fully generic typed DI — any record/interface can be bound — but
  have no notion of "a library's reusable bundle of bindings"; every
  consumer hand-writes the whole graph from scratch.
- **Aspect templates** (`docs/26-aspects.md` §18, `docs/27` §7) already
  solve almost exactly this shape of problem — library declares a
  typed, overridable, env-var-namespaced extension point; consumer
  instantiates it locally — but only for `around` advice bound to a
  `matches:` pointcut. Static file roots or an ordered middleware
  pipeline aren't advice around a matched function; there's nothing to
  weave.

Confirmed against the actual state of the ecosystem: `lyric-web`
(`lyric-web/README.md`) has no static-file or error-handler
configuration today, and its existing `Server`/`CORS` config is a
plain package-private `config` block inside `Web` itself — not
something a consumer can extend, override, or compose with its own
additions per deployment.

This document proposes three additive pieces that close the gap,
building outward from D046 in the same way `docs/29` does for file
sources: **config templates**, **`contributes[T]` multi-value
bindings**, and **wire templates** (the composable, includable unit
that bundles the first two together).

---

## 2. The shared idiom

All three pieces are the same recurring pattern already established by
aspect templates, generalized beyond advice-around-a-function:

> A library declares a reusable, typed extension point with defaults.
> A consumer instantiates or includes it with a local name and
> selective, explicitly-permitted overrides. Composition resolves
> lexically, at compile time. The result is indistinguishable from a
> consumer who hand-wrote the same declarations locally — no runtime
> container, no reflection, no implicit discovery.

That last sentence is load-bearing and is inherited directly from
`docs/26-aspects.md` §18's framing of templates. It is also why this
proposal explicitly rejects a Spring-style reflective/classpath-scanned
container model (see §5.6) in favor of something closer to Guice's
compile-time-resolved `Module` — Lyric's `wire` is already
compile-time-resolved and cycle-checked; nothing here should weaken
that.

---

## 3. Config templates: `pub config` + `from`

Relax `G0008` specifically for a template form: a `pub config` block
with no body beyond typed fields and defaults is legal in a library
package.

```lyric
// library: lyric-web/src/web.l
package Web

pub config StaticFiles {
  root:                String = "./public"
  cacheControlSeconds: Int    = 3600
  fallbackToIndex:     Bool   = false
}
```

A consumer materializes it with `from`, mirroring aspect-template
instantiation (`docs/26` §18.2/§18.3) exactly:

```lyric
config Assets from Web.StaticFiles {
  root: String = "./wwwroot"   // override; cacheControlSeconds keeps the library default
}
```

- Env var derivation mirrors §18.3's `LYRIC_ASPECT_*` rule, substituting
  `LYRIC_CONFIG_<CONSUMER>_<LOCALNAME>_<FIELD>`.
- A field named in the override that doesn't exist on the template, or
  whose type doesn't match, is a compile error — same class of
  diagnostic as `A0023`/`A0024` for aspect config overrides.
- Once `docs/29`'s layered file/CLI config ships, a config template
  instantiation participates automatically — no separate design work,
  same reasoning as D048 §6.4 already gives for aspect config blocks.
- The resolved schema (names, types, defaults, `@sensitive` markers)
  is recorded in the consumer's `Lyric.BuildInfo`/`Lyric.Contract`
  exactly as D046/Q-config-004 already do for ordinary config blocks.

`Assets` is a value of the template's field shape, usable directly
wherever any other typed value is usable — see §5 for how it slots
into a `wire` graph without any new binding syntax.

---

## 4. `contributes[T]`: ordered multi-value wire bindings

`bind`/`singleton` model exactly one instance per type. Some extension
points are inherently a **collection contributed to from multiple,
independent declaration sites** — an HTTP middleware/filter pipeline
being the motivating case. The closest prior art is Dagger's
multibinding (`@IntoSet`), not Spring's `List<Filter>` autowiring —
Dagger is compile-time/reflection-free, matching `wire`'s own model;
Spring's is runtime-reflective and does not fit.

```lyric
pub interface Middleware {
  func wrap(req: in Request, next: Handler): Response
}
```

```lyric
wire ProductionApp {
  @provided config: AppConfig

  contributes[Middleware] logging = Web.loggingMiddleware()
  contributes[Middleware] cors    = Web.corsMiddleware(Settings.cors)
  contributes[Middleware] auth    = MyApp.jwtMiddleware(config.jwtSecret)
    inside: logging
    wraps:  cors

  singleton router: Web.Router = Web.create(middlewares: Middleware)
}
```

### 4.1 Resolution rule

Two or more `contributes[T]` entries for the same `T`, anywhere in the
(fully expanded, post-`include`) wire graph, make the bare identifier
`T` resolve as `List[T]` — ordered by declaration, adjusted by
`wraps:`/`inside:` clauses reusing aspects' existing ordering
vocabulary **literally**, not just conceptually: `docs/26` §6.2 defines
`wraps: X` ("this is outer, X is inner") and `inside: X` ("this is
inner, X is outer") as duals for composing nested advice, and a
middleware/filter chain is exactly the same nesting shape — outer
entries wrap inner ones — so the same pair of clauses transfers
unchanged rather than inventing `before:`/`after:` list-position
syntax that would mean the same thing with a different vocabulary.
Mixing a plain `bind T -> impl` / `singleton x: T` with `contributes[T]` for the
same `T` in one graph is a compile error — ambiguous whether `T` means
"the instance" or "the collection."

### 4.2 v1 scope

- **Singleton-scope contributions only.** A middleware/filter's
  *instance* is naturally process-lifetime even though it acts
  per-request; `scoped[X]` contributions would need per-contributor
  scope reconciliation into one aggregate list, deferred until a
  concrete need surfaces (matches this repo's general "defer until
  demanded" posture elsewhere).
- **Open by default.** Any declaration site — module-internal or
  consumer's own top-level wire block — may add a `contributes[T]`
  entry for a `T` the graph already collects. No permission needed;
  this is the entire point of multibinding (see §5.5 for why this is
  *not* the same trust level as replacing or removing an existing
  entry).
- **`sealed contributes[T]`** (inside a module, §5) blocks external
  add/remove/reorder entirely, for a library that has a
  correctness-critical invariant about its collection (e.g. "auth must
  always run, nothing may be inserted ahead of it"). Left as an
  explicit per-collection opt-in rather than a default — see §7 for
  which default is actually right.

---

## 5. Wire templates: `wire template` + `include`

The composable, includable unit. Mental model, stated precisely
because it resolves several otherwise-fuzzy questions at once:

> **A `wire template` is a parameterized function from `@provided`
> inputs to `expose`d outputs. `include Mod { ... }` is a call to that
> function, textually spliced into the includer's scope — not a
> runtime-resolved component.**

```lyric
// library: lyric-web
pub wire template ServerModule {
  @provided config: AppConfig

  config StaticFiles from Web.StaticFiles {
    root: String = "./public"
  }

  contributes[Middleware] cors    = Web.corsMiddleware(config.cors)
  contributes[Middleware] logging = Web.loggingMiddleware()

  singleton router: Web.Router =
      Web.create(staticFiles: StaticFiles, middlewares: Middleware)

  expose router
  overridable StaticFiles, cors
}
```

```lyric
// consumer
wire ProductionApp {
  @provided config: AppConfig

  include Web.ServerModule {
    @provided config: config          // only needed when names differ
    StaticFiles { root = "./wwwroot" }  // override; cors, logging keep module defaults
  }

  contributes[Middleware] auth = MyApp.jwtMiddleware(config.jwtSecret)
    inside: logging

  expose router
}
```

### 5.1 `@provided` resolution is name-based, not type-directed

`wire`'s existing resolution model is lexical name matching — an
identifier resolves because something in the same textual scope was
bound under that exact name (`@provided config: AppConfig`, then
`config.dbUrl` elsewhere; `bind AccountRepository -> impl`, then
`AccountRepository` used as a value). There is no reflection step that
finds "whatever `Clock`-typed value happens to exist" the way Spring's
container would. Consequently `include` needs an explicit
provided-mapping when the includer's local name differs from what the
module expects (`@provided config: appConfig` inside the `include { }`
braces) — this is the same shape as binding a named/keyword argument
to a function call, which is exactly what the mental model above
predicts.

### 5.2 Multiple instantiation and name collisions

`include Web.ServerModule as Public { ... }` /
`include Web.ServerModule as Admin { ... }` is calling the same
"function" twice with different arguments — this falls out of §5's
model for free, no special-casing needed. **Working assumption, not yet
settled (see Q-wire-002 in §7):** an exposed name auto-propagates into
the includer's bare namespace *unless* it collides (with another
inclusion's exposed name, or a name the includer already declared), in
which case the includer must alias (`include ... as Public`) and access
the value qualified — `Public.router` — reusing the same
static-namespace access syntax config blocks already use
(`Settings.field`), rather than inventing new disambiguation rules.

### 5.3 Nested inclusion and cycles

Modules may `include` other modules. The existing "no cycles in the
wire graph" check (`docs/01` §10.2) must treat inclusion edges the
same way it treats `bind`/`singleton` dependency edges — same
algorithm, larger edge set. No new cycle-detection design needed,
just a wider input to the existing one.

### 5.4 `@cfg` and features: settled, not open

Per D045 (`docs/24-build-features.md` §1.1, §2.2, §7,
Q-features-001 — **closed**): a published library's active feature set
is frozen at `lyric publish` time; a downstream consumer has no lever
over it, full stop — this is a stronger guarantee than "discouraged,"
it's architecturally closed. `@cfg` is always evaluated against
whichever package is actually doing the compiling; there is no
cross-package toggle mechanism to design around.

**Conclusion: wire templates are precompiled only — no source-splice
/ "C-mode" analog exists or is needed** (see §6 for why the aspect
precedent that motivated C-mode doesn't transfer). Consequently:

- `@cfg` inside a wire template is exclusively the *library author's*
  own internal build-variant concern (e.g. gating a JVM-only branch of
  the template) — never a consumer-facing extension axis.
- Any behavior that must vary per deployment goes through a **runtime
  config toggle** (D046-style `config.enabled` checked inside the
  precompiled body), exactly like `Std.OTel.Tracing`'s `config.enabled`
  today. "Is metrics collection on" becomes an ordinary env var
  resolved independently per consumer at startup — no coordination,
  no registry, nothing new.
- There is no "central feature registry" and there should not be one —
  that would introduce implicit cross-package coupling the whole
  `@cfg`/manifest design deliberately avoids (D046 already rejects
  cross-package config sharing on the same grounds).

### 5.5 Override, remove, reorder — three rights, not one

- **Replace** a named entry's value (`StaticFiles { root = ... }`,
  `cors = MyApp.customCors()`) — gated by the module's `overridable`
  allow-list, mirroring aspect config overrides.
- **Remove** a named entry entirely (`remove cors`) — gated by the
  *same* `overridable` allow-list. If a library author is comfortable
  letting a consumer replace an entry's implementation, dropping it is
  a strict subset of that trust; a separate `removable` marker would
  add surface without buying real additional safety.
- **Reorder** two existing entries relative to each other
  (`reorder cors inside: auth`, keeping `cors`'s own implementation) —
  allowed unconditionally on an **open** collection, since reordering
  only risks "runs in the order the module assumed," not "does it run
  at all." `sealed` (§4.2) is the lever for a module that cares about
  order specifically, without having to lock down replace/remove too.

### 5.6 What this deliberately does not borrow from Spring

- No classpath scanning / reflective `@Autowired`-by-type discovery —
  fights the entire point of `wire` being compile-time-resolved and
  cycle-checked.
- No `@ConditionalOnMissingBean` machinery — an ordinary default
  parameter (`func create(staticFiles: Web.StaticFiles =
  Web.StaticFiles.defaults())`) already gives "library default unless
  the consumer wired one," ordinary default-argument semantics, no new
  conditional-bean runtime concept required.
- No implicit auto-configuration activation (`@ConditionalOnClass` /
  `spring.factories`-style automatic pickup) — `include` is always
  explicit, at a textual site the consumer wrote.

---

## 6. Why no C-mode (source-splice) wire templates

Aspect templates need C-mode (`@inline_template`, `docs/27` §6.2)
because a `matches:` pointcut can match functions of unknown shape —
`args` is an opaque parametric record whose field set genuinely varies
per consumer call site, and B-mode can't type-check field access
against a shape it doesn't know. B′-mode's row constraints
(`where TArgs has { ... }`, D115, `docs/56`) closed most of the real
need for this without full recompilation, and per `docs/57`,
`Auth.Aspects.ValidateKey` has already migrated off `@inline_template`
as the ecosystem proof of value — C-mode is shrinking, not growing.

**Wire templates have no pointcut, so the opaque-shape problem never
arises.** Every extension point is nominally typed by the module
author up front: `@provided config: AppConfig` names a concrete type;
`contributes[Middleware]` requires a nominal `impl Middleware for X`
(Lyric has no structural typing to smuggle an unknown shape through —
D012). Candidates that might seem to need source-splice all collapse
into mechanisms that already exist and are already precompiled:

| Candidate need | Resolves via |
|---|---|
| Module generic over the consumer's own entity type | Ordinary generics + existing monomorphization pipeline (`Lyric.Mono`, `docs/43`) |
| Module wants to introspect what was contributed | Ordinary runtime iteration over `List[T]` |
| Consumer wants to add fields beyond what a config template declared | Already rejected by design (§3), independent of B/C-mode |
| Different codegen per consumer target (dotnet/jvm) | Existing per-target kernel-loading convention (`_kernel_native/<basename>` wins over `_kernel/<basename>`), orthogonal to `@cfg` entirely |

Conclusion: **wire templates are B-mode only.** This isn't merely "no
counterexample found yet" — it removes an entire axis from the
design (no "who compiles this" question, no import-hoisting rules to
replicate from `docs/27` §6.2.1, no per-use-site recompilation cost).

---

## 7. Open questions

- **Q-wire-001:** Should `contributes[T]` collections default to
  **open** (any site may add/reorder; only replace/remove of an
  existing named entry is gated) or **sealed** (nothing external
  without explicit opt-in)? §4.2 leans open-by-default with `sealed`
  as opt-in, on the grounds that most collections (logging/CORS
  ordering) don't have real invariants to protect and requiring
  `open` as boilerplate on every collection would be friction for the
  common case — but a security-sensitive collection (e.g. auth
  middleware ordering) not defaulting to protected is a real risk the
  other way. Needs an explicit call before implementation.
- **Q-wire-002:** Does an included module's `expose`d name
  auto-propagate to the includer's bare namespace (§5.2), or must the
  includer always re-`expose` explicitly? Auto-propagation reduces
  boilerplate (the whole motivation for this proposal) but means the
  includer's own `expose` list no longer fully enumerates what's
  reachable from outside — a legibility/boilerplate tradeoff similar
  in kind to the "no auto-hoist of imports" rule aspects already
  settled (`docs/27` §6.2.1), which came down on the explicit side.
  Worth checking whether the same reasoning should apply here or
  whether the cases differ enough to justify auto-propagation.
- **Q-wire-003:** Verifier interaction — checked against the current
  language reference and found nothing: `wire` has no proof-obligation
  surface today (unlike aspects' `requires:`/`ensures:` composition,
  `docs/26` §11). Wire templates likely inherit nothing new to design
  here, but this should be confirmed rather than assumed once `wire`
  gains any contract surface in the future.
- **Q-wire-004:** Should `overridable` (and `sealed`) apply per-name or
  should there be a coarser "this whole module is closed to
  overrides" escape hatch for library authors who don't want to reason
  about individual extension points at all? Not addressed above;
  probably fine to defer — a module with zero `overridable` names is
  already fully closed by construction, so a separate blanket marker
  may be redundant.

---

## 8. Out of scope

- **Scoped (`scoped[X]`) contributions** — deferred per §4.2 until a
  concrete need surfaces.
- **Cross-package feature toggling of a precompiled wire template** —
  closed by D045/Q-features-001; not reopened by this proposal.
- **C-mode / source-splice wire templates** — see §6; not needed.
- **A central feature or extension registry** — deliberately rejected;
  every mechanism here composes lexically, per §2.

---

## 9. References

- `docs/25-config-blocks.md` (D046) — config-block semantics this
  extends via config templates (§3).
- `docs/29-config-v2-sketch.md` (D048) — layered config that config
  templates participate in automatically once implemented.
- `docs/26-aspects.md` §18, `docs/27-aspect-libraries.md` (D047/D050) —
  the template/`from` idiom this proposal generalizes beyond aspects.
- `docs/56-row-typed-aspect-args-sketch.md` (D115) — the B′-mode
  row-constraint precedent that closed most of C-mode's real use case
  for aspects, cited in §6 as the reason the same escape hatch isn't
  needed here.
- `docs/24-build-features.md` (D045) — settles the `@cfg`
  compile-time-only / D046 runtime-only boundary this proposal must
  respect (§5.4).
- `docs/43-in-bundle-generics-plan.md` — the monomorphization
  machinery §6's table leans on for generic wire templates.
- Dagger multibindings (`@IntoSet`/`@IntoMap`) — closer prior art for
  `contributes[T]` than Spring's runtime collection autowiring, being
  itself compile-time/reflection-free.
- Guice `Module` / `Modules.combine` — closer prior art for wire
  templates than Spring Boot auto-configuration, for the same reason.
