# 27 — Aspect Libraries (cross-package aspect distribution)

**Status:** Drafted, exploratory.
**Builds on:** `docs/26-aspects.md` (D047). This note **extends** D047
without superseding it; the package-scoped weaving rule from D047
§16 still holds — only the *advice body and contract clauses*
travel across the package boundary, not the `matches:` site.
**Decision-log entry:** TBD on adoption.

---

## 1. Motivation

D047 deliberately rejected cross-package weaving: an aspect
declared in package P weaves only over P's own targets, and
attempts to apply it to a different package would break separate
verification, the published contract model, and lexical-ordering
composition (D047 §6, §11, §16).

That decision is the right one for *application*, but it forecloses
*reuse*. Every package that wants logging, timing, metrics, or
authorisation has to copy the advice body. There's no way to ship
`Std.Aspects.Logging` once and have every service in the ecosystem
pick it up. The only escape valve today is "copy-paste the aspect
into your package," which scales badly.

This doc proposes a small extension to D047: **aspects can be
declared in libraries without a `matches:` clause; consumers import
the aspect and provide the application site themselves.** The
weaving still happens in the consumer's package, the consumer's
lexical position governs ordering, and the consumer's
`Lyric.Contract` resource records the composed contract — every
property D047 cares about survives. What crosses the package
boundary is the *what* (advice body, contract clauses, config
shape), not the *where* (matches, ordering).

---

## 2. The split

D047 today bundles two things into one `aspect` block:

1. **What an aspect does** — the `around` body, optional
   `requires:` / `ensures:` clauses, optional `config { ... }`
   block. This is reusable.
2. **Where an aspect applies** — the `matches:` clause and the
   `wraps:` / `inside:` ordering clauses. This is package-specific
   and inherently local to the consumer.

An aspect *library* declares (1) only. A consumer *applies* the
library aspect by binding it to (2):

```
// In the library `Std.Aspects`:
package Std.Aspects

@cfg(feature = "logging")
pub aspect Logging {
  config {
    enabled: Bool     = true
    level:   LogLevel = LogLevel.Info
  }

  requires:
    nonNull(args)        // applies whenever Logging is used

  around(args) -> ret {
    if !config.enabled { return proceed(args) }
    Std.Log.log(config.level, "→ ${call.shortName}")
    let r = proceed(args)
    Std.Log.log(config.level, "← ${call.shortName} (${call.elapsed}ms)")
    r
  }
}
```

```
// In the consumer `MyApp.Handlers`:
package MyApp.Handlers

import Std.Aspects.Logging

use Logging matches: name like "handle*"
            except name in {handleHealthcheck}
            inside: Authorization        // local ordering

aspect Authorization {
  matches: name like "handle*" and visibility: pub
  around(args) -> ret { … }
}
```

The library aspect is declared once. The consumer applies it
locally with its own selector and ordering — the application site
is in `MyApp.Handlers`'s source, the woven IL ends up in
`MyApp.Handlers`'s DLL, and the composed contract is recorded in
`MyApp.Handlers`'s `Lyric.Contract` resource.

---

## 3. Library-side syntax: `pub aspect` without `matches:`

In a library, the rules tighten:

- `pub aspect <Name> { ... }` is valid.  Without `pub` the aspect
  remains package-private and behaves exactly like D047.
- A `pub aspect` **must omit** `matches:`, `wraps:`, `inside:`, and
  `@no_aspect` opt-outs.  Compile error if any are present
  (`A0030: pub aspect cannot include matches:/wraps:/inside: clauses`).
- `requires:` / `ensures:` clauses are allowed and become part of
  the published contract surface.
- `config { ... }` blocks are allowed.  Field names and types are
  fixed at publish time; the consumer can override env-var prefix
  and individual defaults but not field shapes.
- The `around` body is compiled to IL and lives in the library
  DLL.

The library's published surface (the `Lyric.Contract.<Pkg>`
resource per D-progress-031) gains a new shape entry per `pub
aspect` carrying the contract clauses and config schema.  The IL
of the `around` body is in the DLL just like any other compiled
function.

---

## 4. Consumer-side syntax: `use` blocks

The consumer applies a library aspect with a new top-level item:

```ebnf
use-decl = "use" qualified-name aliasOpt
           "matches:" matches-clause
           ordering-clauseOpt*
           config-overrideOpt
aliasOpt = ("as" identifier)?
ordering-clauseOpt = ("wraps:" | "inside:") aspect-name-list
config-override = "config" "{" override-field* "}"
override-field = identifier "=" const-expr
```

The grammar is intentionally close to a `D047 aspect` block —
because semantically that's what it is: an `aspect` declaration
whose `around` body is "call into the library's IL."

Worked example:

```
use Std.Aspects.Logging as RequestLog
    matches: name like "handle*"
    except name in {handleHealthcheck}
    inside: Authorization
    config {
      level = LogLevel.Debug    // override library default
    }
```

This declares a *consumer-local aspect* named `RequestLog`:

- Its `around` body is a one-line shim that calls
  `Std.Aspects.Logging.<around-method>(call, args, proceed)` —
  whatever ABI the library DLL exposes.
- Its `requires:` and `ensures:` come from the library's
  published clauses, attributed to `Std.Aspects.Logging` in
  diagnostics.
- Its `config { ... }` field schema is the library's; the local
  block overrides specific defaults; env-var prefix is
  `LYRIC_ASPECT_REQUESTLOG_*` (i.e. the `as` alias if present,
  otherwise the qualified name's last segment).
- Its lexical position in the consumer's source determines
  ordering with respect to the consumer's other aspects.

---

## 5. Composition rules (the per-target wrapper)

For a consumer target `T` matched by library-imported `RequestLog`
and local aspect `Authorization`:

```
wrapper(T).requires =
  T.requires
  ∧ RequestLog.requires        // = library Logging.requires
  ∧ Authorization.requires

wrapper(T).ensures =
  T.ensures
  ∧ RequestLog.ensures
  ∧ Authorization.ensures
```

Identical to D047 §5 — the only difference is *where the clauses
came from*.  Diagnostic provenance reads:

```
C0014: precondition not satisfied at call site
    requires nonNull(args)
    ^ added by aspect 'RequestLog' (from Std.Aspects.Logging)
      used at app.l:7
```

The `from` clause makes the library origin explicit; the `used at`
points at the consumer's `use` declaration.

---

## 6. Calling the library `around` body — ABI

This is the load-bearing technical question.  Three options, in
increasing order of magic:

### 6.1 Option A — typed-erased delegate

The library compiles the `around` body to a static method with a
fixed signature:

```clr
static object Around(
    AspectCallContext call,
    object[] args,
    Func<object[], object> proceed)
```

The consumer's wrapper boxes args / unboxes return value at the
call boundary.  Pros: simple, library doesn't need to know
consumer's types.  Cons: per-call boxing for primitives and
struct-typed args; type-erasure means losing the static type
guarantees Lyric otherwise provides.

### 6.2 Option B — generic `around` with monomorphisation

The library compiles `around` as a generic method:

```clr
static TRet Around<TArgs, TRet>(
    AspectCallContext call,
    TArgs args,
    Func<TArgs, TRet> proceed)
```

The consumer's wrapper instantiates the generic at the target's
exact arg/ret types.  Pros: zero boxing on primitives, full type
safety.  Cons: monomorphisation per target × per use-site means
binary bloat (same trade-off as D035-era generics); the library
must compile its body so it's safely instantiable across consumer
type universes.

### 6.3 Option C — source-level inline expansion ("template" model)

The library distributes the source for the `around` body alongside
the IL.  At consumer compile time, the source is *re-compiled*
inside the consumer's package, so every monomorphisation is local.
Pros: cleanest type story; the library aspect behaves identically
to a copy-pasted local aspect.  Cons: consumer compile time grows;
the library DLL is essentially a Lyric package that ships its
source as a resource (similar to how `Lyric.Contract` already
ships type info).

I lean towards **B for v1** (real ABI, monomorphised, type-safe)
with **C as a future optimisation** for cases where the library's
body is small and inlining wins.

---

## 7. Config blocks travel with the aspect

A library aspect's `config { ... }` block declares the field names
and types.  At consumer-side, the `use` block can:

- Override individual default values (`config { level = LogLevel.Debug }`).
- Override the env-var prefix via the `as` alias
  (`use … as RequestLog` → `LYRIC_ASPECT_REQUESTLOG_*`).
- Disable specific fields' env-var binding (`config { level pinned }`)
  — defers to the library default at runtime, ignoring env override.

All other D046 (`docs/25-config-blocks.md`) rules apply: read
once at startup, fail-fast on missing required fields, primitives
+ ranges + enums + lists.

The consumer's `Lyric.Contract` resource records the *resolved*
config schema so downstream tools (lyric explain, LSP hover) see
what env vars the consumer actually reads.

---

## 8. Lexical-ordering question — does it survive?

Yes.  The composition graph is built **per-consumer**, over the
consumer's `use` declarations and locally-declared aspects:

- `use` blocks compose with local `aspect` blocks in lexical
  order, file by file, just as D047 §6 specifies.
- A `use` block can carry `wraps:` / `inside:` clauses naming
  other consumer-side aspects (locally declared or imported via
  another `use`).
- Cross-file ordering still requires explicit clauses (D047 §6.1).

The library never sees the consumer's other aspects, so it can't
constrain ordering — that's a feature, not a bug.  If a library
aspect needs to nest inside another library aspect, the consumer
expresses it:

```
use Std.Aspects.Logging
    matches: name like "handle*"
use Std.Aspects.Timing as Timing
    matches: name like "handle*"
    inside: Logging
```

Two library aspects, ordering authored at the consumer.

---

## 9. Verifier interaction

For a `@proof_required` consumer applying a library aspect:

1. The consumer's verifier loads the library DLL and reads its
   contract clauses from `Lyric.Contract.<Lib>`.
2. The composed wrapper VC includes the library's `requires:` /
   `ensures:` exactly as if they were locally declared.
3. The library's `around` body is *not* re-verified — it was
   verified at library publish time against its own contract
   clauses.  Only the *call boundary* between consumer wrapper
   and library body is verified.  This is the standard
   separately-verifiable model; cf. how restored functions
   (D-progress-078) carry their contracts across packages.

If the library was published from an `@axiom` or `@runtime_checked`
package, its body's correctness wasn't proven.  The consumer
either accepts that (treating the library aspect as an extern
boundary) or rejects the import (`@proof_required` packages
typically refuse axiom-only imports already; same rule).

---

## 10. What this doesn't break

- **Package isolation.**  Application is still package-local.
  Only declarations cross.
- **Lexical ordering.**  Per-consumer, governed by consumer
  source.
- **Published contracts.**  Each consumer's DLL records the full
  composed contract, including library-attributed clauses.
- **Per-package verification.**  Library is verified at publish;
  consumer is verified independently.
- **`@no_aspect` opt-out.**  Works against `use`-named aspects
  exactly like local aspects: `@no_aspect(RequestLog)` on a
  target excludes it.
- **`@cfg` gating.**  Both library and consumer can gate.  A
  library aspect gated `@cfg(feature = "logging")` disappears
  from the published surface when the feature is off; consumer
  `use` blocks naming an erased aspect emit `F0010`.

---

## 11. Worked example: a small ecosystem

A library:

```
package Std.Aspects

@cfg(feature = "logging")
pub aspect Logging {
  config { enabled: Bool = true; level: LogLevel = LogLevel.Info }
  around(args) -> ret { … }
}

pub aspect Timing {
  config { enabled: Bool = true }
  ensures: ret.elapsedMs >= 0
  around(args) -> ret { … }
}

pub aspect Validating {
  requires: nonNull(args)        // every use enforces this
}                                // contract-only, no around
```

A service consuming it:

```
package CheckoutService

import Std.Aspects.Logging
import Std.Aspects.Timing
import Std.Aspects.Validating

use Logging   matches: name like "handle*"
              config { level = LogLevel.Debug }

use Timing    matches: name like "handle*"
              inside: Logging

use Validating matches: name like "handle*" and visibility: pub
```

Three library aspects, three application sites, ordered as
`Logging > Timing > target`, with `Validating` adding a
`nonNull(args)` precondition to every public handler.  Composes
exactly like D047, just with the bodies sourced from a library
DLL.

---

## 12. Open questions

The whole doc is exploratory; these are the specific holes I want
poked.

- **Q-aspectlib-001 — Source distribution vs. IL distribution.**
  §6's option C (re-compile inside the consumer) is cleaner for
  type safety but doubles compile times.  Option B (generic IL)
  has the binary-bloat problem.  Which trade-off is right?  Is a
  hybrid (B by default, opt-in to C via a library annotation)
  worth the complexity?
- **Q-aspectlib-002 — `pub aspect` without `around`.**  A
  contract-only library aspect like `Validating` has no IL to
  ship — it's pure metadata.  Should this require a different
  syntax (`pub aspect_contract`) or just be a degenerate `pub
  aspect`?  Leaning toward the latter; it's symmetric with D047
  contract-only aspects.
- **Q-aspectlib-003 — `use` clause without alias when names
  collide.**  Two libraries both export `Logging`.  Consumer
  imports both.  `use Logging matches: …` is now ambiguous.
  Mandatory `as` alias on collision, or qualify by package path?
  Both work; alias is friendlier.
- **Q-aspectlib-004 — Library bumping a contract.**  A library
  changes `Logging.requires:` from `nonNull(args)` to
  `nonNull(args) and args.length > 0`.  That's a SemVer-major
  break for every consumer, exactly the same as bumping a
  function's `requires:`.  Documented; the
  `@stable(since="X.Y")` machinery already covers this.
- **Q-aspectlib-005 — `config` field overrides and v1 type
  set.**  D046 §3 limits config fields to primitives + ranges +
  enums + lists.  Library aspects inherit that.  Open: should
  the library be allowed to declare *required* config fields
  (no default) that *every consumer must override locally*?
  Plausibly yes — `Std.Aspects.Auth { config { tenantId: String
  } }` forces consumers to bind a tenant ID.  But it complicates
  the "library is a closed type" promise.
- **Q-aspectlib-006 — Calling convention and the F# bootstrap.**
  The F# bootstrap is being retired (CLAUDE.md / `docs/23`); the
  ABI choice from §6 only really matters for the self-hosted
  emitter.  Implication: aspect libraries land *after* M5.2
  stage 3+ ships the AST→MSIL bridge.  Not blocked on F#.
- **Q-aspectlib-007 — Cross-package `use` ordering.**  A `use`
  block in package A can name aspect `B.Foo` in `wraps:` /
  `inside:` only if `Foo` is also `use`d (or locally declared)
  in A.  We can't reach into another package to order aspects.
  This is the same package-isolation rule as D047.  Document
  it explicitly.
- **Q-aspectlib-008 — Discoverability.**  How does a developer
  know what aspects a library ships?  `lyric explain
  Std.Aspects` should print every `pub aspect` with its
  contract clauses, config schema, and a usage example.  Not
  a v1 blocker but worth tracking.

---

## 13. Out of scope

- **Re-exposing library aspects.**  Consumer A imports a library
  aspect and re-exports it via `pub use Std.Aspects.Logging`.
  Plausible but adds ordering complexity.  Defer.
- **Aspect inheritance / extension.**  `pub aspect MyLogging
  extends Std.Aspects.Logging { … }`.  Defer.  Composition
  via ordering is enough.
- **Runtime aspect registration.**  `Aspects.register(...)` from
  inside `main`.  Out of scope; aspects are static (D047).
- **Aspects on extern types.**  Aspects on types from a library's
  surface that the consumer didn't declare.  Out of scope;
  aspects target functions, not types (D047 §3.4 / Q-aspects-001).

---

## 14. References

- `docs/26-aspects.md` (D047) — the base aspect design this
  extends.
- `docs/25-config-blocks.md` (D046) — config-block rules that
  carry through to library aspects.
- `docs/24-build-features.md` (D045) — `@cfg(...)` gating that
  works for both library and consumer.
- D-progress-031 — `Lyric.Contract` resource format that gains
  the per-aspect contract entry.
- D-progress-078 — restored-package contract walking that the
  consumer extends to read library aspect surfaces.
- AspectJ `aspect` keyword + abstract pointcuts pattern — the
  closest precedent in the AOP literature for the
  "abstract-then-instantiate" pattern this doc adopts.
