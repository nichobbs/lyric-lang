# 26 — Compile-time Aspects

**Status:** Partially shipped — v1 surface (parser + AST +
type-check + symbol table) implemented in the F# bootstrap and
self-hosted compiler (PRs #206, #227).  Runtime weaver
(wrapper synthesis, contract composition, ordering, runtime
config, `@no_aspect` opt-out) is the remaining v1 work;
deferred to whichever compiler ships it first.  Library
distribution: `docs/27-aspect-libraries.md`.  Worked-example
pressure-test: `docs/28-std-aspects-sketch.md`.  Aspect
contract inheritance v1.x sketch:
`docs/30-aspect-contract-inheritance-sketch.md` (specced in D049).
**Implementation:** Phase 2 — depends on `docs/24-build-features.md`
(compile-time gating) and `docs/25-config-blocks.md` (typed env-backed
config) shipping first. The verifier-side discharge (§11) lights up
when `docs/15-phase-4-proof-plan.md`'s VC pipeline can ingest woven
contracts.
**Decision-log entry:** D047; contract inheritance v1.x in D049.

> **v1 scope note.** The first slice of implementation lands the
> *language surface* — parser, AST, and basic type-check
> registration for module-scope `aspect Name { matches: name like
> "<glob>"; around(args) -> ret { ... } }` blocks.  Contract
> augmentation (§5), ordering clauses (§6), config blocks (§8),
> `@no_aspect` opt-outs (§3.3), the runtime weaver (§10), and
> verifier integration (§11) are deferred to v1.x slices.  The
> design below describes the full target.

---

## 1. Motivation

Cross-cutting concerns — logging, timing, validation, authorisation,
metrics — recur in every service-shaped Lyric program. Today the only
way to apply them is to copy the same boilerplate into the top of
every method, which violates DRY and (worse) silently rots when a new
method is added without the boilerplate.

Lyric has two precedents that point at the right shape:

- **`wire` blocks.** A package-level declaration that the compiler
  reads and emits derived code from. Visible at the file header,
  scoped to one package, integrates with the rest of the source via
  a small declarative language.
- **`@projectable`, `@stubbable`.** Annotations that ask the compiler
  to *generate* something derived from a type. The shape is "describe
  the shape you want, the compiler produces it."

This document specifies an `aspect` block — a third primitive in the
same family. An aspect declares a **selector** (which functions it
applies to), an **advice body** (the code to run around each match),
and **contract clauses** (extra `requires:` / `ensures:` to compose
with the target). The compiler weaves aspects at build time. There is
no runtime aspect machinery; the woven code is ordinary IL.

The design centres five constraints:

1. **Package-scoped weaving.** An aspect declared in package P weaves
   only over P's own targets. No cross-package action; no surprises
   for downstream consumers of P.
2. **Composed contract is the public contract.** Aspects can add
   `requires:` and `ensures:`; the wrapper's effective contract
   conjoins target + every matched aspect, and that is what the
   verifier discharges and what the published `Lyric.Contract`
   resource records.
3. **Verifier compatibility.** Woven advice is part of the
   verification surface. `@proof_required` packages prove against
   the woven body, not the bare target.
4. **Tooling visibility.** Every method records which aspects apply
   in build metadata; LSP hover and `lyric explain` surface the
   list. "Why is this method behaving differently than I expect?"
   has a one-line answer.
5. **Compile-time enable / runtime configure.** `@cfg` decides
   whether an aspect is woven at all; a `config` block per aspect
   parameterises the woven body's behaviour.

---

## 2. The `aspect` block

```lyric
package MyApp.Handlers

import Std.Core
import Std.Log

aspect Logging {
  matches:
    name like "handle*"
    except name in {handleHealthcheck, handlePing}

  config {
    enabled: Bool     = true
    level:   LogLevel = LogLevel.Info
  }

  around(args) -> ret {
    if !config.enabled {
      return proceed(args)
    }
    Std.Log.log(config.level, "→ ${call.shortName}")
    let r = proceed(args)
    Std.Log.log(config.level, "← ${call.shortName} (${call.elapsed.unwrapOr(0)}ms)")
    r
  }
}
```

The block is a top-level item, peer to `func`, `type`, `wire`,
`config`. Multiple `aspect` blocks per file are allowed (matches
`wire`'s rule).

A related form, `aspect_template`, exports a reusable advice body
without a selector so that library packages can share instrumentation
logic. Consumers bind a `matches:` clause locally via
`aspect Name from Pkg.Template { ... }`. See §18 for the full
specification.

### 2.1 Required content

An aspect must define **at least one** of:

- An `around` advice body (§4).
- An aspect-level `requires:` clause (§5).
- An aspect-level `ensures:` clause (§5).

An aspect with none of the above is a compile error
(`A0009: aspect must define around-advice, requires:, or ensures:`).

### 2.2 Visibility

Aspects are package-private. `pub aspect` is rejected
(`A0001: aspects are package-private; remove 'pub'`). Cross-package
aspect application is deliberately out of scope (§14).

---

## 3. The `matches:` clause

The selector. Determines which functions in the same package the
aspect weaves over.

### 3.1 v1 grammar

```ebnf
matches-clause = "matches:" predicate ("and" predicate)* except-clause?
predicate      = "name like" string-literal
except-clause  = "except name in" "{" identifier-list "}"
```

The `name like "<glob>"` predicate matches the function's short name
(not the qualified module path) against a POSIX-ish glob:

- `*` — match any sequence of characters (including empty)
- `?` — match exactly one character
- `[abc]`, `[a-z]` — match one character from a set or range
- All other characters match literally

`except name in { ... }` excludes a list of literal short names from
the match.

### 3.2 Reserved future predicates

The grammar reserves shape for v2 predicates without breaking v1
source:

```
matches:
  name like "handle*"
  and signature: returns Result[*, *]   # v2
  and annotated: @public_api            # v2
  and visibility: pub                   # v2
```

Each predicate clause begins with a keyword ending in `:` so the
parser can extend without ambiguity. v1 only implements `name like`.

### 3.3 Per-target opt-out

A function can opt out of all aspects, or specific ones, via an
annotation:

```lyric
@no_aspect                    // opt out of every aspect in this package
func handleSensitive(...)

@no_aspect(Logging)           // opt out of Logging only
func handleHotPath(...)

@no_aspect(Logging, Timing)   // opt out of multiple
func handleFastInner(...)
```

`@no_aspect` annotations are checked after `matches:` resolution.
A method where every applicable aspect is opted-out emits no
wrapper.

### 3.4 What can match

Aspects only weave over `func` definitions. Method calls, free
function calls, and interface-method implementations are all
candidates. Type constructors and operator overloads are **not**
candidates in v1 (tracked as Q-aspects-001).

A function is a candidate when its short name satisfies `matches:`
**and** its containing package is the same as the aspect's package
**and** no `@no_aspect` directive excludes it.

---

## 4. The `around` advice

Advice is always *around*-style: the body decides whether and how to
call the target via `proceed(args)`. `before` and `after` patterns
desugar trivially and are not separate primitives.

### 4.1 Signature

```lyric
around(args) -> ret { ... }
```

Inside the body:

- `args` is a record-shaped value with one named field per target
  parameter. The field names match the target's parameter names; the
  field types match the target's parameter types.
- `proceed(args)` calls the target. Returns the typed return value.
  May be omitted entirely (skip / replace semantics) — the wrapper
  then returns whatever the body's last expression evaluates to.
- `ret` is the type of the target's return value, used for the
  advice body's own return.
- Early `return` from inside `around` is allowed and idiomatic for
  skip / replace patterns (caching, circuit breakers, dry-run modes).

### 4.2 Rebinding `args` and `ret`

`args` and `ret` are ordinary `let`-bindings. The body may rebind
them with `let args = ...` or `let r = ...` like any other value:

```lyric
aspect Sanitise {
  matches: name like "handle*"

  around(args) -> ret {
    let args = { ...args, input: sanitise(args.input) }
    proceed(args)
  }
}
```

The compiler statically detects whether the body rebinds `args`
before `proceed` or rebinds the return value before returning. When
rebinding occurs, the wrapper inserts contract-preservation checks at
the boundary:

- **Rebound `args`** must satisfy the target's `requires:`. The check
  is inserted immediately before `proceed`. In `@runtime_checked`,
  it's a runtime assert; in `@proof_required`, it's a verifier
  obligation.
- **Rebound return value** must satisfy the wrapper's composed
  `ensures:` (§5). Same insertion rules.

When the body just threads `args` through and returns the value of
`proceed(args)` unchanged, no extra check fires — the existing target
contract suffices.

There is no `mut` modifier; the analysis is local and the cost-free
case stays cost-free without extra syntax.

### 4.3 The `call` ambient value

Inside `around`, an ambient `call` value exposes metadata about the
weave site:

| Field | Type | Meaning |
|---|---|---|
| `call.qualifiedName` | `String` | Fully qualified target name (e.g. `MyApp.Handlers.handleRequest`) |
| `call.shortName` | `String` | Short target name (`handleRequest`) |
| `call.modulePath` | `String` | Package containing the target |
| `call.sourceLocation` | `SourceLoc` | `{ file, line, column }` of the target's definition |
| `call.caller` | `Option[SourceLoc]` | Caller site, when available; `None` for entry points and reflective calls |
| `call.annotations` | `[Annotation]` | The target's annotations (so an aspect can read `@deprecated`, `@public_api`, etc.) |
| `call.elapsed` | `Option[Int]` | `Some(ms)` after `proceed` returns; `None` before `proceed` is called or if the body never calls `proceed`. The earlier zero-sentinel was rejected as a footgun (Q-aspects-003). |
| `call.aspect` | `String` | The current aspect's name (useful when one helper serves several aspects) |

`SourceLoc` is a simple stdlib record; full layout in
`docs/01-language-reference.md` §1 (TBD pending stdlib doc update).

The `call` value is read-only.

#### 4.3.1 Visibility of `call` inside contract clauses

`call` is in scope inside the `around` body and inside any
`ensures:` clause attached to the aspect.  It is **not** in scope
inside `requires:` clauses.

The asymmetry is justified by the same temporal asymmetry that
governs `requires:` vs `ensures:` for the target's own contract:

- `requires:` is evaluated *before* `proceed` runs.  At that
  point `call.elapsed` is always `None`, and the other fields
  are constants the consumer already knows by other means.
  Allowing `call` here only enables footgun contracts.
- `ensures:` is evaluated *after* the wrapper returns.  Then
  `call.elapsed.unwrapOr(0)` is meaningful, enabling SLO-style
  postconditions like
  `ensures: call.elapsed.unwrapOr(0) <= 1000`.

Putting `call` in `requires:` is a compile error
(`A0040: call is not in scope inside requires: clauses`).

---

## 5. Contract augmentation

Aspects may declare `requires:` and `ensures:` clauses at the aspect
level:

```lyric
aspect Validation {
  matches:
    name like "handle*"

  requires:
    nonNull(args.user)
    args.user.id > 0

  ensures:
    ret.isOk implies ret.value.userId == args.user.id
}
```

### 5.1 Composition rule

For a target `T` matched by aspects `A₁, A₂, ..., Aₙ`:

```
wrapper(T).requires = T.requires ∧ A₁.requires ∧ A₂.requires ∧ ... ∧ Aₙ.requires
wrapper(T).ensures  = T.ensures  ∧ A₁.ensures  ∧ A₂.ensures  ∧ ... ∧ Aₙ.ensures
```

Every clause is **additive** and **conjoined**. Aspects cannot weaken
or remove the target's existing clauses. The wrapper's effective
contract is what callers see and what the verifier discharges.

### 5.2 Why aspects can strengthen `requires:`

An aspect that adds `requires:` makes the wrapped method *harder to
call* than the bare target — every caller must now satisfy the new
clause too. This is intentional. It's the mechanism by which a
`Validation` aspect imposes blanket null-checks across every public
handler, or an `Authorization` aspect demands a role across every
admin endpoint. The composed contract is the public API; callers see
the full obligation.

### 5.3 Diagnostic provenance

Contract failures must point at the aspect that introduced the clause,
not just the target:

```
C0014: precondition not satisfied at call site
    requires nonNull(args.user)
    ^ added by aspect 'Validation' (validation.l:7)
```

Without provenance, debugging "why does this require non-null when
the function signature doesn't say so?" is awful. The compiler tracks
clause origin through the woven IR; the diagnostic renderer reads it.

### 5.4 Unsatisfiable composed preconditions

If aspects A₁ and A₂ both apply to target T and `A₁.requires ∧
A₂.requires ∧ T.requires` is unsatisfiable, the wrapper can never be
called. In `@proof_required` this is a hard error
(`A0010: composed precondition is unsatisfiable on '<target>'`). In
`@runtime_checked` it's a compile-time warning, since the runtime
behaviour ("every call asserts") is observable.

### 5.5 Contract-only aspects

When an aspect has `requires:` and/or `ensures:` but no `around`, the
implicit body is `proceed(args)`:

```lyric
aspect Validation {
  matches: name like "handle*"

  requires:
    nonNull(args.user)
}
```

The wrapper exists purely to carry the composed contract. No advice
runs around the target; only the inserted contract checks fire.

---

## 6. Composition order

When multiple aspects apply to the same target, they nest. If aspects
A and B both match `handleRequest` with A "outside" B, the woven call
is:

```
A.before-half
    B.before-half
        target
    B.after-half
A.after-half
```

(The `before-half` / `after-half` framing is informal — `around` body
above and below `proceed(args)` respectively. With early `return` or
omitted `proceed`, halves can be empty.)

### 6.1 Default ordering

Within a single source file, aspects compose in **lexical order**: the
first declared is outermost.

Across multiple source files in the same package, no implicit order is
defined. If two aspects match overlapping targets and neither names
the other in a `wraps:` / `inside:` clause, the compiler errors:

```
A0007: aspects 'Logging' (logging.l:3) and 'Timing' (timing.l:5)
       both apply to 'handleRequest' but their relative order is unspecified.
       hint: add 'inside: Logging' or 'wraps: Logging' to one of them.
```

The check runs **per-target**: two aspects without explicit ordering
coexist fine if their `matches:` selectors never overlap on any
function in the package.

### 6.2 Explicit ordering: `wraps:` / `inside:`

```lyric
aspect Timing {
  inside: Logging          // Logging wraps Timing — Timing nests inside
  wraps:  Authorization    // Timing wraps Authorization — Authorization nests inside

  matches: name like "handle*"
  around(args) -> ret { ... }
}
```

- `inside: X` — this aspect runs *inside* X's envelope (X is outer,
  this is inner).
- `wraps: X` — this aspect runs *outside* X's envelope (this is outer,
  X is inner).

Both clauses accept comma-separated lists: `wraps: A, B, C`. The two
clauses are duals — `Timing inside: Logging` is equivalent to
`Logging wraps: Timing`. Either works; pick whichever you control.

### 6.3 Cycle detection

Cycles in the `wraps:` / `inside:` graph are a compile error:

```
A0008: ordering cycle: 'A' wraps 'B' wraps 'A'
```

---

## 7. Compile-time gating

Aspects integrate with `docs/24-build-features.md`'s `@cfg`
mechanism:

```lyric
@cfg(feature = "logging")
aspect Logging { ... }

@cfg(any(feature = "tracing", feature = "metrics"))
aspect ObservabilitySpan { ... }
```

When the predicate is false against the active feature set, the
aspect is **erased entirely**:

- No wrapper is emitted around any target.
- No metadata is written.
- Targets compile as bare functions (no aspect overhead, no flag
  check, no branch).
- Other aspects' ordering clauses that reference an erased aspect are
  ignored without warning (the erased aspect is treated as if it were
  never declared).

This is the *zero-cost* path: aspects you compile out leave no
trace.

---

## 8. Runtime configuration

Aspects use the general config-block mechanism from
`docs/25-config-blocks.md` for runtime parameters, with a small
ergonomic tweak: the env-var prefix is `LYRIC_ASPECT_<NAME>_<FIELD>`
instead of `LYRIC_CONFIG_<PKG>_<NAME>_<FIELD>`. (Aspects are
package-private and never collide on the short name within their
own package; the shorter prefix matches operator expectations.)

```lyric
aspect Logging {
  config {
    enabled: Bool       = true
    level:   LogLevel   = LogLevel.Info
    sample:  Float      = 1.0
  }
  ...
}
```

Env vars:
- `LYRIC_ASPECT_LOGGING_ENABLED`
- `LYRIC_ASPECT_LOGGING_LEVEL`
- `LYRIC_ASPECT_LOGGING_SAMPLE`

Field types, parsing, fail-fast behaviour, and `@sensitive` markers
follow `docs/25-config-blocks.md` §3 / §4 unchanged.

### 8.1 No implicit toggle

There is no automatic `enabled` flag. An aspect that wants runtime
on/off declares the field itself, with an explicit default. Aspects
that should always run (e.g. `Validation` enforcing security
invariants) simply don't declare the field.

This is deliberate: making toggling opt-in keeps `Validation` from
silently being switchable.

---

## 9. Worked example

A package with three aspects covering the canonical cross-cutting
concerns, demonstrating ordering, contract augmentation, and gating.

```lyric
package MyApp.Handlers

import Std.Core
import Std.Log

@cfg(feature = "logging")
aspect Logging {
  matches: name like "handle*"

  config {
    enabled: Bool     = true
    level:   LogLevel = LogLevel.Info
  }

  around(args) -> ret {
    if !config.enabled { return proceed(args) }
    Std.Log.log(config.level, "→ ${call.shortName}")
    let r = proceed(args)
    Std.Log.log(config.level, "← ${call.shortName} (${call.elapsed.unwrapOr(0)}ms)")
    r
  }
}

aspect Validation {
  matches: name like "handle*"

  requires:
    nonNull(args.request)
    args.request.userId > 0
}

aspect Authorization {
  inside: Logging          // run inside Logging's envelope

  matches: name like "handle*"

  around(args) -> ret {
    if !Auth.check(call.annotations, args.request) {
      return Err(error = AuthError.Forbidden)
    }
    proceed(args)
  }
}

@public_api
pub func handleCreateUser(request: in CreateUserRequest): Result[User, CreateError]
  requires: request.name.length > 0
  ensures:  ret.isOk implies ret.value.name == request.name
{
  ...
}
```

The compiler emits a wrapper around `handleCreateUser` whose
**effective contract** is:

```
requires:
  request.name.length > 0          (from target)
  nonNull(request)                 (from Validation)
  request.userId > 0               (from Validation)

ensures:
  ret.isOk implies ret.value.name == request.name   (from target)
```

The **woven body**, with `feature = "logging"` active:

```
wrapper(request) -> Result[User, CreateError] {
  if Logging.config.enabled {
    Std.Log.log(Logging.config.level, "→ handleCreateUser")
    if !Auth.check([@public_api], request) {
      Std.Log.log(Logging.config.level, "← handleCreateUser (0ms)")
      return Err(error = AuthError.Forbidden)
    }
    let r = handleCreateUser_target(request)
    Std.Log.log(Logging.config.level, "← handleCreateUser (Nms)")
    r
  } else {
    if !Auth.check([@public_api], request) {
      return Err(error = AuthError.Forbidden)
    }
    handleCreateUser_target(request)
  }
}
```

With `--no-default-features` (logging off), `Logging` is erased and
the wrapper degenerates to:

```
wrapper(request) -> Result[User, CreateError] {
  if !Auth.check([@public_api], request) {
    return Err(error = AuthError.Forbidden)
  }
  handleCreateUser_target(request)
}
```

The composed `requires:` are still enforced (`Validation` is not
gated off), but no logging machinery exists in the binary at all.

---

## 10. Lowering

Each weave site emits a wrapper function with the same name and
signature as the target. The target is renamed (`<name>_target` is the
working scheme — final mangling tracked as Q-aspects-002) and called
from inside the wrapper. Callers transparently bind to the wrapper.

For a target `T` with matched aspects `A₁ ⊃ A₂ ⊃ ... ⊃ Aₙ` (ordering
per §6):

1. The compiler synthesises `T_target(args) -> ret` with the original
   body and the original `requires:` / `ensures:`.
2. It inlines each aspect's `around` body in nesting order. Aₙ's body
   references `proceed(args)`, which the inliner substitutes with a
   call to `T_target(args)`. Aₙ₋₁'s body references `proceed`, which
   the inliner substitutes with the inlined Aₙ wrapper. Etc.
3. Contract-preservation checks (§4.2, §5) are inserted at the inlined
   boundaries.
4. The runtime config block for each aspect (§8) is initialised once
   per process; the inlined body reads `config.<field>` as a static
   load.

Aspects that share an `around` helper can factor it out — see §12 on
generics interaction for the monomorphisation cost.

The `Lyric.Contract.<package>` resource records each wrapped function's
**composed** contract and the list of applied aspects (with
`@cfg`-resolved presence). Restored packages (D-progress-078) consume
this resource exactly as they do today; aspect application is
transparent at the import boundary.

---

## 11. Verifier interaction

For `@proof_required` packages, the woven body — including aspect
advice and inserted contract-preservation checks — is the input to
the VC generator (`docs/15-phase-4-proof-plan.md`). The verifier:

1. Builds the wrapper's composed pre/postcondition (§5.1).
2. Runs the wp/sp pipeline over the inlined body, treating
   `proceed(args)` as the Hoare call rule on `T_target` with its
   declared contract.
3. Discharges the rebinding-boundary checks from §4.2 as ordinary
   assertion VCs.
4. Discharges the unsatisfiability check from §5.4 as a separate VC
   (`composed-precondition-satisfiable`).

For `@runtime_checked` packages, the same checks become runtime
asserts inserted at the boundary points, fed through the existing
`Std.Contract` machinery.

For unannotated packages (no contract checking at all), aspect
contract clauses are still recorded in the `Lyric.Contract` resource
so consumer packages with `@proof_required` see the obligation. They
just aren't enforced inside the producing package.

### 11.1 Aspect bodies and `@axiom`

An aspect's `around` body may itself contain `@axiom`-marked extern
calls (e.g. `Std.Log` lowers to a BCL extern). The aspect inherits
the audit obligations of any extern it touches, same as ordinary
code.

---

## 12. Generics

Lyric monomorphises generic functions per call-site instantiation
(D035). When a generic target is wrapped by an aspect, the wrapper
is also monomorphised — once per instantiation of the target.

To control binary size, factor the aspect's body into a non-generic
helper:

```lyric
aspect Logging {
  matches: name like "handle*"

  around(args) -> ret {
    logEntry(call.qualifiedName, call.shortName)   // non-generic helper
    let r = proceed(args)
    logExit(call.qualifiedName, call.elapsed.unwrapOr(0))
    r
  }
}

func logEntry(qn: in String, sn: in String): Unit { ... }
func logExit(qn: in String, ms: in Int): Unit { ... }
```

The wrapper itself is per-instantiation but small (just packs the
metadata fields and calls into the helpers). The helpers exist once.

Typed access to generic args inside advice (e.g. `args.x: T`) re-bloats
the helper unless the aspect author erases to a uniform shape (`String`
formatting, `Std.Display`-like interface, etc.). v1 does not solve this for
the aspect author; it's the same trade-off any monomorphised generic
faces.

---

## 13. Async

Lyric's bootstrap-grade async lowering (D035) blocks via
`.GetAwaiter().GetResult()`. A real state-machine lowering is Phase 2
work. v1 aspects on `async func` targets work with the bootstrap
lowering (since the wrapper is sync and the target's `await` happens
inside the blocking shim) but **do not preserve async cancellation
semantics correctly** when advice rebinds args.

The conservative v1 stance:

- Aspects on sync functions are first-class.
- Aspects on async functions are accepted by the parser but emit a
  warning (`A0020: aspects on async functions use bootstrap-grade
  lowering; cancellation may not propagate correctly`).
- The Phase 2 async state-machine work explicitly accepts aspect
  awareness as a design constraint. When it lands, the warning lifts
  and aspects compose with continuation-style async naturally.

Async-specific advice features (`await proceed(args)` inside the
advice body, suspend/resume hooks, etc.) are not in v1 scope.

---

## 14. Tooling

### 14.1 LSP

Hover on a target shows applied aspects and the composed contract:

```
func handleCreateUser(request: in CreateUserRequest): Result[User, CreateError]

Aspects applied (outer → inner):
  • Logging        (logging.l:5)        @cfg(feature = "logging")
  • Authorization  (auth.l:9)           inside: Logging
  • Validation     (validation.l:3)     contract-only

Composed contract:
  requires:
    request.name.length > 0
    nonNull(request)              (added by Validation)
    request.userId > 0            (added by Validation)
  ensures:
    ret.isOk implies ret.value.name == request.name
```

A code-lens above each aspect-affected function says
`N aspects applied — view`.

### 14.2 CLI

`lyric explain MyApp.Handlers.handleCreateUser` prints the same
information as the hover, formatted for the terminal.

`lyric explain --aspects MyApp.Handlers` lists every aspect in the
package, the targets each one matches in the current build, and the
composed-contract delta for each match.

### 14.3 Build metadata

Each package's `Lyric.Aspects` resource records the applied-aspects
list per target (including the `@cfg` resolution at build time) so
external tools can introspect a built DLL without re-running the
compiler.

---

## 15. Diagnostics

| Code | Meaning |
|---|---|
| `A0001` | `pub aspect` rejected (aspects are package-private). |
| `A0002` | `aspect` redeclares an existing aspect name in the package. |
| `A0007` | Two aspects' `matches:` overlap on a target with no explicit ordering. |
| `A0008` | Cycle in `wraps:` / `inside:` ordering graph. |
| `A0009` | Aspect defines no `around`, no `requires:`, and no `ensures:`. |
| `A0010` | Composed precondition is unsatisfiable on a target (`@proof_required`). |
| `A0011` | Composed precondition is unsatisfiable (`@runtime_checked`, warning). |
| `A0012` | `@no_aspect(X)` references an aspect not declared in the package. |
| `A0013` | `wraps:` / `inside:` references an aspect not declared in the package. |
| `A0014` | Glob in `matches: name like "..."` is malformed. |
| `A0015` | Rebound `args` cannot be proven to satisfy target `requires:`. |
| `A0016` | Rebound return cannot be proven to satisfy composed `ensures:`. |
| `A0020` | Aspect applied to async function with bootstrap-grade lowering (warning). |
| `A0021` | `aspect_template` body declares a `matches:` clause (templates have no selector; the consumer provides one). |
| `A0022` | `aspect ... from Pkg.Template` instantiation declares `around`, `requires:`, or `ensures:` (those come from the template; only `matches:` and `config` override are allowed). |
| `A0023` | `aspect ... from Pkg.Template` config override declares a field whose type differs from the template's declaration. |
| `A0024` | `aspect ... from Pkg.Template` config override declares a field not present in the template. |
| `A0025` | `from` references an `aspect_template` that is not `pub` (cross-package reference to a package-private template). |
| `A0026` | `from` references a name that is not an `aspect_template` (e.g. a regular `aspect` or an ordinary type). |

Plus the runtime contract codes (`C0014` etc.) gain provenance
fields naming the aspect that introduced the failing clause (§5.3).

---

## 16. Out of scope (v1)

- **Cross-package aspect application.** An aspect in package A
  weaving over functions in package B. Conflicts with package
  isolation, separate verification, and the published-contract model.
  Not deferred — actively rejected. Note: `aspect_template` (§18)
  does *not* relax this rule. A template shares advice *logic*; the
  weaving still happens exclusively inside the consumer's own package.
- **Aspects on type constructors and operator overloads.**
  Tracked as Q-aspects-001.
- **Aspects on macro expansions.** Macros don't exist yet; revisit
  when they do.
- **Statement-level / expression-level advice.** Aspects target
  function calls, not arbitrary code points.
- **Mutation hooks beyond `args` / `ret` rebinding.** No way to
  "patch" the target body. The replace path is "skip `proceed` and
  return your own value."
- **Dynamic aspect registration.** Aspects are static. There is no
  `Aspects.register(...)` API.
- **Per-call enable/disable.** A target-side `@no_aspect(X)`
  excludes the aspect at compile time. Per-call runtime gating is
  done inside the advice body via the aspect's own `config`.

---

## 17. Open questions

> A v1.x sketch addressing Q-aspects-006 (aspect-to-aspect
> contract inheritance) lives at
> `docs/30-aspect-contract-inheritance-sketch.md`.

- **Q-aspects-001:** Should aspects match constructors and operator
  overloads? Probably yes for symmetry, but the `args` shape becomes
  awkward (no parameter names for operators). Defer.
- **Q-aspects-002:** Mangling scheme for `<name>_target`. Conflicts
  with hand-written `_target` suffix names. Probably escape with a
  reserved sigil only the compiler emits.
- **Q-aspects-003:** ~~Should `call.elapsed` be available inside
  the *before-half* (before `proceed`)?~~ **Resolved.** The type
  is `Option[Int]` — `None` before `proceed` returns (or if the
  body never calls `proceed`), `Some(ms)` after. The earlier
  zero-sentinel was rejected as a footgun: a logging aspect that
  prints "elapsed=0ms" looks legitimate but is meaningless. The
  worked examples in §7 / §9 are updated to use
  `call.elapsed.unwrapOr(0)` for printing.
- **Q-aspects-004:** Aspect over multiple packages in the same
  *project* (`docs/20-project-as-dll.md` introduces multi-package
  projects). Project-level aspects are a natural extension, but
  weakening "package-scoped" requires care. Defer to post-Phase 5.
- **Q-aspects-005:** `call.contractValues` — the value of each
  `requires:` / `ensures:` predicate at the weave point. Powerful
  for diagnostic aspects ("log every call where ensures held but
  result was Err"); expensive (re-evaluation cost). Plausibly gated
  behind an `@expensive` marker on the aspect.
- **Q-aspects-006:** Inheritance of contracts from an aspect across
  *aspects* (an aspect adding a clause that subsequent aspects'
  bodies can reason against). Today each aspect sees the unwrapped
  target's contract; this is fine for v1 but limits some patterns —
  e.g. a downstream `Authorization` aspect can't depend on an
  upstream `Validation` aspect's `requires: nonNull(args.user)`
  having been discharged. **Status:** desirable, deferred. The
  composition rule from §5.1 stays as-is for v1 (each aspect's
  contract clauses augment the *target's* contract, not the
  cumulative wrapper-so-far); inheritance is a v1.x revisit when a
  concrete pattern hits the limitation.
- **Q-aspects-007:** When two `aspect ... from Template` instantiations
  coexist in the same package and the template declares `requires:` /
  `ensures:`, can a consumer's ordering clause (`wraps:` / `inside:`)
  reference the other instantiation by its local name? The answer is
  almost certainly yes (ordering always uses local names), but the
  interaction between template-derived contracts and the composition
  rule (§5.1) across ordering boundaries needs an explicit spec test.
  Defer to the v1 implementation pass.

---

## 18. Aspect templates

An `aspect_template` is an exportable aspect body without a selector.
A library package declares the template; consumer packages instantiate
it, binding a `matches:` clause locally. The weaving still happens
inside the consumer's package — the constraint from §16 (no
cross-package weaving) is unchanged. What templates share is the
*advice logic*, not the *weave authority*. The compiled result is
indistinguishable from a consumer who hand-wrote the same `around`
body locally; the template is a maintenance-reduction tool.

### 18.1 Template declaration

```lyric
package Std.OTel

import Std.Core

pub aspect_template Tracing {
  config {
    enabled:    Bool  = true
    sampleRate: Float = 1.0
  }

  around(args) -> ret {
    if !config.enabled { return proceed(args) }
    let span = Std.OTel.startSpan(call.qualifiedName, call.sourceLocation)
    let r = proceed(args)
    span.record(elapsedMs = call.elapsed.unwrapOr(0))
    r
  }
}

pub aspect_template Metrics {
  config {
    enabled: Bool = true
  }

  around(args) -> ret {
    if !config.enabled { return proceed(args) }
    Std.OTel.incrementCounter(call.qualifiedName)
    let r = proceed(args)
    Std.OTel.recordHistogram(call.qualifiedName, call.elapsed.unwrapOr(0))
    r
  }
}
```

A template declares the same body content as an ordinary `aspect`
(`config { }`, `around`, `requires:`, `ensures:`), with one
restriction: **no `matches:` clause**. The selector is the consumer's
responsibility, so the template never weaves anything directly.

A template may be `pub` (cross-package use) or package-private
(intra-package reuse across files in the same package). `pub
aspect_template` is the common case; an unprefixed `aspect_template`
is package-private and may only be instantiated within the same
package.

### 18.2 Template instantiation

```lyric
package MyApp.Handlers

import Std.OTel
import Std.Core

aspect Tracing from Std.OTel.Tracing {
  matches: name like "handle*"
  except name in { handleHealthcheck, handlePing }
}

@cfg(feature = "metrics")
aspect Metrics from Std.OTel.Metrics {
  matches: name like "handle*"

  config {
    enabled: Bool = false    // off by default in this package; operator can override via env
  }
}
```

An instantiation is written `aspect Name from Pkg.Template { ... }`.
The body may contain:

- Exactly one `matches:` clause (required).
- An optional `config { }` block that overrides the template's field
  default values (see §18.3).
- Ordering clauses (`wraps:` / `inside:`), composing with other local
  aspects per §6.

An instantiation may **not** declare `around`, `requires:`, or
`ensures:` — those come from the template (`A0022`).

All other aspect semantics apply unchanged: `@cfg` gating, `@no_aspect`
opt-outs, verifier integration, LSP code-lens.

### 18.3 Config field overrides

When a consumer's instantiation declares a `config { }` block, each
field in the block *overrides the default* from the template. The
field name and type must match the template's declaration exactly;
differing types are `A0023`. Declaring a field not present in the
template is `A0024`.

```lyric
aspect Tracing from Std.OTel.Tracing {
  matches: name like "handle*"

  config {
    sampleRate: Float = 0.1   // lower default for this package
    // 'enabled' not overridden; stays at template's default of true
  }
}
```

The effective default for each field is: the consumer's override if
present, otherwise the template's declared default. Runtime env vars
always win over any compile-time default, using the **local
instantiation name**:

```
LYRIC_ASPECT_TRACING_ENABLED=false
LYRIC_ASPECT_TRACING_SAMPLERATE=0.5
```

If two packages both instantiate `Std.OTel.Tracing` and name their
local aspect differently (`Tracing` vs. `OtelTracing`), their env var
namespaces are separate. Operators configure each package's weaving
independently.

### 18.4 `@cfg` interaction

`@cfg` works independently on the template and on each instantiation:

```lyric
// In the library
@cfg(feature = "otel")
pub aspect_template Tracing { ... }

// In the consumer
@cfg(feature = "tracing")
aspect Tracing from Std.OTel.Tracing {
  matches: name like "handle*"
}
```

- If the template's `@cfg` predicate is false, the template is erased;
  every instantiation silently disappears (treated as if the `from`
  reference doesn't exist). No error.
- If the instantiation's `@cfg` predicate is false but the template
  exists, only that instantiation is erased.
- If the instantiation's predicate is true but the template was erased
  by its own `@cfg`, the instantiation is also silently erased.

The zero-cost property (§7) holds for templates: a fully erased
instantiation emits no wrapper, no metadata, no branch.

### 18.5 Worked example — OpenTelemetry library

A `Std.OTel` package provides tracing, metrics, and logging templates.
Consumers opt in per-package with a one-block declaration.

```lyric
// stdlib/std/otel.l  (simplified)
package Std.OTel

import Std.Core
import Std._kernel.OTelKernel    // @externTarget externs for ActivitySource etc.

pub aspect_template Tracing {
  config {
    enabled:     Bool   = true
    sampleRate:  Float  = 1.0
    spanKind:    String = "internal"
  }

  around(args) -> ret {
    if !config.enabled { return proceed(args) }
    if !OTelKernel.sample(config.sampleRate) { return proceed(args) }
    let span = OTelKernel.startSpan(
                 call.qualifiedName, config.spanKind, call.sourceLocation)
    let r = proceed(args)
    span.setStatus(Ok)
    span.end(elapsedMs = call.elapsed.unwrapOr(0))
    r
  }
}

pub aspect_template RequestLogging {
  config {
    enabled: Bool     = true
    level:   LogLevel = LogLevel.Info
  }

  around(args) -> ret {
    if !config.enabled { return proceed(args) }
    Std.Log.log(config.level, "→ ${call.qualifiedName}", [])
    let r = proceed(args)
    Std.Log.log(config.level, "← ${call.qualifiedName} (${call.elapsed.unwrapOr(0)}ms)", [])
    r
  }
}
```

Consumer package:

```lyric
package MyService.Api

import Std.OTel
import Std.Core

@cfg(feature = "otel")
aspect RequestLogging from Std.OTel.RequestLogging {
  matches: name like "handle*"
  except name in { handleHealthcheck }

  config {
    level: LogLevel = LogLevel.Debug   // override to Debug in this service
  }
}

@cfg(feature = "otel")
aspect Tracing from Std.OTel.Tracing {
  matches: name like "handle*"
  except name in { handleHealthcheck }
  wraps: RequestLogging
}
```

The kernel extern boundary (`stdlib/std/_kernel/otel.l`) holds
`@externTarget` / `extern type` declarations for
`System.Diagnostics.ActivitySource`, `Activity`, and related BCL
types. Standard OTel env vars (`OTEL_EXPORTER_OTLP_ENDPOINT`,
`OTEL_SERVICE_NAME`, etc.) flow through to the .NET SDK at the extern
boundary; Lyric config fields cover Lyric-specific knobs (sampling,
enabled flag, log level). Operators do not need to learn a Lyric-
specific naming scheme for the exporter endpoint.

---

## 19. References

- AspectJ (https://www.eclipse.org/aspectj/) — the canonical AOP
  reference, particularly for around-advice and pointcut design.
- Spring AOP (https://docs.spring.io/spring-framework/reference/core/aop.html)
  — declarative aspect application via annotations.
- `docs/24-build-features.md` — `@cfg` and feature manifest.
- `docs/25-config-blocks.md` — typed env-backed config blocks.
- `docs/15-phase-4-proof-plan.md` — verifier pipeline that ingests
  woven contracts.
- D035 (`docs/03-decision-log.md`) — bootstrap-grade lowerings for
  generics, async, and FFI; constrains the v1 aspect interaction
  with each.
- D-progress-031 — `Lyric.Contract` embedded resource format.
- D-progress-077 / D-progress-078 — manifest-driven build /
  restored-package surface.
