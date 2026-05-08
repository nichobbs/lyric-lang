# 28 — `Std.Aspects` Sketch (pressure-test for D047 + 27)

**Status:** Drafted, exploratory.  This is a worked-example
pressure-test of the aspect design — *not* a published spec for
`Std.Aspects`.  The goal is to surface design tensions in
`docs/26-aspects.md` (D047) and `docs/27-aspect-libraries.md`
before any implementation work begins.
**Decision-log entry:** None.

---

## 1. Why this exists

D047 specifies the `aspect` block.  27 specifies the
library/consumer split for distributing aspects in DLLs.  Neither
contains an end-to-end worked example of the *standard library
of aspects* the design implies.  This sketch fills that gap by
writing four candidate `Std.Aspects` aspects in pseudo-Lyric
source, plus a realistic consumer that uses all four, and noting
the design tensions that surface along the way.

The four aspects:

| Aspect | Mode | What it tests |
|---|---|---|
| `Logging` | B (generic IL) | The default ABI on a generic, parametric body |
| `Timing` | C (`@inline_template`) | The hot-path opt-in |
| `Validating` | metadata-only | Contract-only `pub aspect` (Q-aspectlib-002) |
| `Auth` | B + required config field | Required-config-field propagation (Q-aspectlib-005) |

Plus a fifth — `Tracing` — as a sanity check that two B-mode
aspects compose cleanly with each other and with `Logging`.

---

## 2. The library — `Std.Aspects`

Package layout:

```
stdlib/std/aspects/
├── lyric.toml             # `Std.Aspects` package
├── logging.l              # pub aspect Logging
├── timing.l               # pub aspect Timing  (@inline_template)
├── validating.l           # pub aspect Validating  (metadata-only)
├── auth.l                 # pub aspect Auth
└── tracing.l              # pub aspect Tracing
```

### 2.1 `Logging` — default B-mode, generic body

```lyric
package Std.Aspects

import Std.Core
import Std.Log

@stable(since="0.1")
pub aspect Logging {
  config {
    enabled: Bool     = true
    level:   LogLevel = LogLevel.Info
  }

  // No `requires:` / `ensures:` — Logging is an observer, not a
  // contract enforcer.

  around(args) -> ret {
    if !config.enabled { return proceed(args) }

    Std.Log.log(config.level, "→ ${call.shortName}")
    let r = proceed(args)
    let ms = call.elapsed.unwrapOr(0)
    Std.Log.log(config.level, "← ${call.shortName} (${ms}ms)")
    r
  }
}
```

Library-side compilation (B-mode):

- `Logging.Around<TArgs, TRet>(call, args, proceed)` lands in
  `Std.Aspects.dll` as a generic IL method.
- The `config { enabled, level }` schema goes in
  `Lyric.Contract.Std.Aspects` resource entry (per Q-config-004).
- No `requires:` / `ensures:` clauses to publish.

### 2.2 `Timing` — `@inline_template` for hot paths

```lyric
package Std.Aspects

import Std.Core
import Std.Time

@stable(since="0.1")
@inline_template
pub aspect Timing {
  config {
    enabled: Bool = true
  }

  ensures:
    ret.elapsedMs >= 0  // synthesised companion field?  see §5.4

  around(args) -> ret {
    if !config.enabled { return proceed(args) }
    let started = Std.Time.nowMs()
    let r = proceed(args)
    let elapsed = Std.Time.nowMs() - started
    Std.Metrics.observeMs(call.qualifiedName, elapsed)
    r
  }
}
```

Library-side compilation (C-mode):

- The body source is embedded as a resource in `Std.Aspects.dll`.
- No generic IL is emitted for `Timing.Around`.
- The contract clause (`ret.elapsedMs >= 0`) is published in the
  contract resource.

Consumer-side: when a consumer's `use Std.Aspects.Timing matches:
…` is encountered, the compiler **re-parses, type-checks, and
lowers** the body inside the consumer's package, exactly as if
the body had been copy-pasted in.  Std.Time and Std.Metrics
imports are hoisted into the consumer's package automatically
(see §5.2).

### 2.3 `Validating` — contract-only, no `around`

```lyric
package Std.Aspects

import Std.Core

@stable(since="0.1")
pub aspect Validating {
  // Contract-only.  No `around` body, no `config` block.

  requires:
    nonNull(args)              // every arg field non-null
}
```

This is the smallest possible library aspect — pure metadata,
zero IL.  The published surface is just the `requires:` clause
attached to the aspect's name.

Consumer use: `use Std.Aspects.Validating matches: name like
"*"` adds `nonNull(args)` to every matched function's wrapper
contract.  See §6 of D047 for what `nonNull(args)` means
(structural check over every arg field).

### 2.4 `Auth` — required config field

```lyric
package Std.Aspects

import Std.Core

@stable(since="0.1")
pub aspect Auth {
  config {
    @sensitive
    tenantId: String                // no default → required
  }

  requires:
    args.callerToken != ""

  around(args) -> ret {
    if !verifyToken(args.callerToken, config.tenantId) {
      return Err(error = AuthError.Forbidden)
    }
    proceed(args)
  }
}

func verifyToken(token: in String, tenantId: in String): Bool { … }
```

Library-side: B-mode (default).  `tenantId` has no default —
per Q-aspectlib-005's resolution, this propagates to consumer
fail-fast at startup.

Consumer use:

```lyric
use Std.Aspects.Auth as TenantA matches: name like "handle*"
                                except name in {handleHealthcheck}
```

Consumer's runtime env vars: `LYRIC_ASPECT_TENANTA_TENANT_ID`
required at startup; `LYRIC_ASPECT_TENANTA_*` follows the alias.

Multi-tenant deployment is natural — different aliases pick up
different env vars:

```lyric
use Std.Aspects.Auth as TenantA matches: name like "handleA*"
use Std.Aspects.Auth as TenantB matches: name like "handleB*"
```

Two distinct aspects in the consumer's composition graph, each
with its own tenant ID env var.

### 2.5 `Tracing` — composes with `Logging`

```lyric
package Std.Aspects

import Std.Core
import Std.Trace

@stable(since="0.1")
pub aspect Tracing {
  config {
    enabled:    Bool  = true
    sampleRate: Float = 1.0          // 0.0-1.0
  }

  around(args) -> ret {
    if !config.enabled { return proceed(args) }
    if Std.Random.next() > config.sampleRate { return proceed(args) }

    let span = Std.Trace.startSpan(call.qualifiedName)
    let r = proceed(args)
    Std.Trace.endSpan(span)
    r
  }
}
```

B-mode default.  Sampling is the canonical "feature" that justifies
runtime config rather than compile-time gating.

---

## 3. The consumer — a checkout service

```lyric
package CheckoutService

import Std.Core
import Std.Http

import Std.Aspects.Logging
import Std.Aspects.Timing
import Std.Aspects.Tracing
import Std.Aspects.Validating
import Std.Aspects.Auth

// Lexical order = composition order (D047 §6).
// Outer → inner: Logging > Tracing > Validating > Auth > target.
use Logging    matches: name like "handle*"
               except  name in {handleHealthcheck, handlePing}
               config  { level = LogLevel.Debug }

use Tracing    matches: name like "handle*"
               inside:  Logging
               config  { sampleRate = 0.1 }

use Validating matches: name like "handle*" and visibility: pub

use Auth as TenantAuth
               matches: name like "handle*" and visibility: pub
               inside:  Validating

@public_api
pub func handleCreateOrder(request: in CreateOrderRequest)
        : Result[Order, CreateError]
  requires: request.itemCount > 0
  ensures:  ret.isOk implies ret.value.userId == request.userId
{
  …
}
```

Effective wrapper for `handleCreateOrder`, with all four aspects
applied, has the composed contract:

```
requires:
  request.itemCount > 0          (target)
  nonNull(request)               (Validating, propagated via use)
  request.callerToken != ""      (Auth, propagated via use)

ensures:
  ret.isOk implies ret.value.userId == request.userId  (target)
```

Composed nesting:

```
Logging:
  if config.enabled:
    log("→ handleCreateOrder")
    Tracing:
      if config.enabled and Random.next() <= sampleRate:
        startSpan
        Validating: (no body — contract only, asserts run pre-proceed)
          Auth:
            verify token vs tenantId
            handleCreateOrder_target(request)
            // result returned upward
```

---

## 4. Operator deployment

```sh
export LYRIC_ASPECT_LOGGING_ENABLED=true
export LYRIC_ASPECT_LOGGING_LEVEL=Info        # override Debug default
export LYRIC_ASPECT_TRACING_SAMPLERATE=0.05    # 5 % sampling
export LYRIC_ASPECT_TENANTAUTH_TENANT_ID="checkout-prod"  # required, fail-fast if absent

./checkout-service
```

If `LYRIC_ASPECT_TENANTAUTH_TENANT_ID` is unset, the process
aborts with exit code 78 before `main` runs:

```
lyric: required config 'TenantAuth.tenantId'
       (env: LYRIC_ASPECT_TENANTAUTH_TENANT_ID, sensitive)
       is unset
```

Sensitive marker note: per D046 §3.2 + Q-config-004, the
`@sensitive` marker makes downstream `lyric explain` and ops
tooling redact the value automatically.  The library's
`@sensitive` annotation travels through the consumer's
`Lyric.BuildInfo` resource (Q-config-004) so an operator running
`lyric explain CheckoutService` sees:

```
Aspects applied:
  • Logging        from Std.Aspects (logging.l:7)
  • Tracing        from Std.Aspects (tracing.l:7)        inside Logging
  • Validating     from Std.Aspects (validating.l:7)     contract-only
  • TenantAuth     from Std.Aspects.Auth (auth.l:11)     inside Validating

Config (consumer-side):
  Logging.enabled         Bool     = true
  Logging.level           LogLevel = LogLevel.Debug      (overridden from Info)
  Tracing.enabled         Bool     = true
  Tracing.sampleRate      Float    = 0.1                 (overridden from 1.0)
  TenantAuth.tenantId     String   <REQUIRED>            @sensitive
```

---

## 5. Tensions surfaced

This sketch caught a handful of issues that aren't called out in
D047 / 27.  Numbered for tracking.

### 5.1 — `args` shape on generic targets (B-mode)

`Logging` ships a `Around<TArgs, TRet>` generic.  For a target
`func map[T,U](xs: List[T], f: (T) -> U): List[U]`, the
consumer's wrapper instantiates with `TArgs = MapArgs[T, U]`
where `MapArgs` is a synthesised record `{ xs: List[T], f: (T)
-> U }` with the target's type parameters appearing in `TArgs`.

The library's `around` body never reads typed fields off `args`
— `Std.Log.log(level, …)` doesn't look inside.  But the
library's body *can* refer to `args` opaquely (e.g. printing
its representation via a `Display` trait if one is in scope).

**Open issue (Q-aspects-007? — new):** What's the type of
`args` inside a B-mode `pub aspect`?  Three options:

- (a) An *anonymous* parametric record: the body sees `args`
  as opaque, can't read fields.
- (b) A *typed* parametric record: the body can `args.x` if
  every consumer's target has a field named `x`.  Shaky.
- (c) Reflection-shaped access: `args.field("x")`.  Loses type
  safety; matches Option A's shape.

The 27 §6 spec implicitly assumes (a).  Worth pinning down.

### 5.2 — Hoisted imports in C-mode (`@inline_template`)

`Timing` imports `Std.Time` and `Std.Metrics` at the library
level.  When the body re-compiles in the consumer's package,
those imports must be in the consumer's view.  Two paths:

- **Auto-hoist:** the consumer's compiler implicitly pulls the
  template's imports.  Magic, but ergonomic.
- **Explicit:** the consumer must `import Std.Time` /
  `Std.Metrics` itself; otherwise compile error.  Exposes the
  template's dependencies.

I lean explicit; it's consistent with how Lyric handles imports
elsewhere ("nothing is in scope unless imported").

### 5.3 — `@inline_template` body size budget

Nothing in 27 says how big a `@inline_template` body can be.  A
500-line `pub aspect` annotated `@inline_template` would
massively bloat consumer DLLs.  Plausibly need a budget — say,
"reject `@inline_template` if the body lowers to >100 IL
instructions" — or just document the trade-off and leave it to
library author judgement.

### 5.4 — `ret.elapsedMs` in `Timing.ensures:` is fictional

`Timing`'s ensures clause uses `ret.elapsedMs` — but Lyric
return values don't have an `elapsedMs` field.  The contract
makes sense intuitively ("the elapsed time we observed is
non-negative") but doesn't typecheck.

Two paths:

- Drop the contract clause; use a different mechanism (e.g. a
  postcondition assertion inside the body).
- Introduce a `call.elapsed` reference inside `ensures:`,
  promoting `call` from "ambient inside `around`" to "ambient
  inside contract clauses too."

Worth thinking about whether `call` should be visible in
`requires:` / `ensures:` clauses at all — D047 §4.3 says it's
"in scope only inside `around`."

### 5.5 — Multiple `use` of the same library aspect

The `TenantA` / `TenantB` example in §2.4 instantiates
`Std.Aspects.Auth` twice with different aliases.  D047 §6
ordering rules say "two aspects matching the same target need
explicit `wraps:` / `inside:` if they're in different files."
Question: are `TenantA` and `TenantB` "the same aspect" or
"different aspects" for ordering purposes?

I think they're different — they have distinct names — so the
rule is unaffected.  But the diagnostic for ordering conflicts
should be clear: "TenantA and TenantB both match handleX; add
ordering."

### 5.6 — Library aspect with a `requires:` referencing
unverifiable consumer state

`Auth.requires: args.callerToken != ""` works because every
match-target shape includes a `callerToken` field — by
convention.  But the library can't enforce that; if a consumer
applies `Auth` to a target that lacks `callerToken`, the
contract is unprovable.

This is a *use-site type error*, not a library bug.  The
consumer's compiler should reject:

```
A0030: aspect 'TenantAuth' (from Std.Aspects.Auth)
       requires `args.callerToken != ""`,
       but target `handleX` has no `callerToken` field.
```

The library's contract clauses are part of its published
surface; the consumer's compiler verifies they're applicable
at each `use` site.

Worth nailing this down in 27 §9 (verifier interaction).

### 5.7 — `@stable(since="X.Y")` on library aspects

D040 governs `@stable` annotations.  Library aspects are public
API surface — they need `@stable` markers.  This sketch uses
`@stable(since="0.1")` on every `pub aspect` but D040 doesn't
explicitly cover aspects.  Probably trivial to extend; flag it.

### 5.8 — Cross-language consumption

A C# consumer wants to apply `Std.Aspects.Logging` to a C#
method.  This whole design is Lyric-only — the `use`
declaration is Lyric syntax, weaving happens in the Lyric
compiler.  C# would need an entirely different surface.  Out
of scope, but worth noting that aspect libraries are
Lyric-consumer-only.

---

## 6. What this sketch confirms

- The library/consumer split (27 §2) really does work for
  `Logging` / `Timing` / `Validating` / `Auth` / `Tracing`.
- The hybrid B+C ABI (27 §6) maps naturally to the four
  aspects: `Logging` and `Auth` benefit from generic IL
  distribution; `Timing` benefits from inline-template; `Validating`
  has no IL at all; `Tracing` is fine with B.
- The required-config-field rule (Q-aspectlib-005) gives
  multi-tenant `Auth` deployment without new syntax.
- `call.elapsed: Option[Int]` (Q-aspects-003) is the right
  shape — `Logging`'s body uses `unwrapOr(0)` for printing
  cleanly.

## 7. What this sketch wants nailed down before implementation

- §5.1 — **`args` shape on generic targets** (B-mode).  Highest
  priority; affects every B-mode aspect that touches `args.x`.
- §5.2 — **Import hoisting in `@inline_template`** (explicit vs.
  auto).  Affects every C-mode aspect.
- §5.4 — **`call` visibility inside `requires:` / `ensures:`**.
  Affects contract clauses on aspects with timing-flavoured
  semantics.
- §5.6 — **Use-site shape verification** for library
  `requires:` clauses.  Affects auth-flavoured aspects.

The other tensions (§5.3 budget, §5.5 multi-use ordering,
§5.7 `@stable`, §5.8 cross-language) are smaller — known
follow-ups, not implementation blockers.

---

## 8. References

- `docs/26-aspects.md` (D047) — the base aspect design.
- `docs/27-aspect-libraries.md` — the library/consumer split.
- `docs/25-config-blocks.md` (D046) — required-field
  fail-fast rule that Auth.tenantId rides on.
- `docs/24-build-features.md` (D045) — `@cfg` gating, mostly
  irrelevant for `Std.Aspects` (runtime config is the better
  toggle for "enable/disable per deployment").
