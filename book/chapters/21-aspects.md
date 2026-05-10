# Aspects

Most code has concerns that cut across many functions: logging every request that enters a service, measuring how long each operation takes, enforcing an authentication check before any handler runs. The natural impulse is to write a helper and call it from each function. The problem is that the helper call is now scattered across dozens of functions, and every new function added to the service needs the same boilerplate. When the requirement changes — say, log the elapsed time as well as the entry — you update one function and miss seven others, or you refactor the helper's signature and break every call site at once.

Lyric addresses this with the `aspect` block. An aspect describes behaviour that should apply to a matched set of functions, written once and maintained in one place. The compiler weaves it in at the matched call sites — no call-site boilerplate, no scattered wrapper functions, no synchronization burden when the requirement changes.

::: note
**Note:** As of the current compiler milestone, the aspect syntax, `matches:` filter, `around` body, and config block are fully parsed, type-checked, and represented in the AST. The runtime weaver — the component that actually applies aspects at matched call sites — is deferred to a later milestone. You can write and type-check aspects today; the woven execution is not yet active. This chapter describes the shipped design so that the syntax is not a surprise when the weaver lands.
:::

## §21.1 The `aspect` block

An aspect is a module-scope item, a peer to `func`, `wire`, and `config`. Here is a complete aspect that logs entry and exit for a family of request-handling functions:

```lyric
aspect Logging {
  matches:
    name like "handle*"
    except name in { handleHealth }

  config {
    enabled: Bool = true
    level:   LogLevel = LogLevel.Info
  }

  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      Std.Log.info("→ " + call.shortName)
      ret = call.proceed()
      Std.Log.info("← " + call.shortName + " (" + call.elapsed.unwrapOr(0).toString() + "ms)")
    }
  }
}
```

Four parts make up this aspect.

**`matches:`** is the filter that determines which functions this aspect applies to. `name like "handle*"` selects every function in the current package whose short name starts with `handle`. The glob syntax is POSIX: `*` matches any sequence of characters and `?` matches exactly one character. The `except name in { handleHealth }` line excludes one specific function from the match, even though it starts with `handle`.

**`config {}`** declares compile-time configuration fields with defaults. Config fields are available by name directly inside the aspect body — not via a `config.` prefix. This works identically to a standalone `config {}` block (Chapter 11). The fields are settable via environment variables at build time (§21.3).

**`around(call) -> ret`** is the advice body. The identifier `call` is the ambient context for the intercepted call; `ret` is the name you choose for the return value. The assignment `ret = call.proceed()` executes the underlying function and stores its result. Everything before that assignment is pre-advice; everything after is post-advice.

You can read `call.elapsed` after `call.proceed()` to get the elapsed time in milliseconds. Before `proceed()` it is `None`; after it is `Some(ms)` where `ms` is the wall-clock duration of the underlying call.

The `not enabled` expression is ordinary Lyric boolean negation. Do not write `!enabled` or `not config.enabled` — the field is directly in scope.

::: sidebar
**Cross-cutting concerns.** The canonical examples are logging, tracing, metrics, authentication checks, and retry wrappers. What they share is that the logic belongs to the infrastructure layer, not to the business logic inside any individual function. Putting them in the functions themselves couples the two layers together; extracting them into aspects separates them cleanly. When you later replace your logging library, you change one aspect, not a hundred call sites.
:::

## §21.2 The `call` context

Inside `around(call) -> ret`, the `call` identifier exposes the following fields:

| Field | Type | Notes |
|---|---|---|
| `call.shortName` | `String` | The function's unqualified name, e.g. `"handleTransfer"` |
| `call.qualifiedName` | `String` | The fully qualified name, e.g. `"TransferHttp.handleTransfer"` |
| `call.modulePath` | `String` | The module path without the function name, e.g. `"TransferHttp"` |
| `call.elapsed` | `Option[Int]` | `None` before `proceed()`, `Some(ms)` after |
| `call.sourceLocation` | `String` | The source file and line of the matched function's declaration |
| `call.annotations` | `slice[String]` | Names of annotations on the matched function, e.g. `["@auth_required"]` |

`call.proceed()` executes the matched function with its original arguments and returns the original return value. You call it exactly once in a normal advice body. Calling it zero times returns early without executing the function; calling it more than once executes the function multiple times. Both are legal for specific use cases — a caching aspect might skip `proceed()` on a cache hit; a retry aspect might call `proceed()` in a loop — but the common case is a single call.

The `call` context does not expose the arguments by name in an ordinary aspect. To read a specific named parameter, you need an `@inline_template` aspect (§21.7). For most infrastructure concerns — logging, timing, authentication via annotation — the fields above are sufficient.

## §21.3 Config blocks in aspects

An aspect's `config {}` block works the same way as a standalone `config {}` block. Each field has a name, a type, and a default value. Fields are readable directly by name in the aspect body.

```lyric
aspect RateLimit {
  matches:
    name like "handle*"

  config {
    maxRequestsPerMinute: Int  = 1000
    burstAllowance:       Int  = 50
    rejectOnExceed:       Bool = true
  }

  around(call) -> ret {
    if not Throttle.check(maxRequestsPerMinute, burstAllowance) and rejectOnExceed {
      ret = Result.err(RateLimitError.exceeded())
    } else {
      ret = call.proceed()
    }
  }
}
```

To override a config field at build time, set the environment variable `LYRIC_ASPECT_<INSTANTIATION_UPPER>_<FIELD_UPPER>`. For the `RateLimit` aspect:

- `LYRIC_ASPECT_RATELIMIT_MAXREQUESTSPERMINUTE=500`
- `LYRIC_ASPECT_RATELIMIT_BURSTALLOWANCE=10`
- `LYRIC_ASPECT_RATELIMIT_REJECTONEXCEED=false`

The instantiation name is the aspect's declared name, uppercased. For aspects instantiated from a template with a local name (§21.7), it is the local name that is used.

::: note
**Note:** Boolean config fields accept `true` and `false` as environment variable values. Numeric fields accept any valid integer or float literal. Setting an environment variable to an unparseable value is a build error.
:::

## §21.4 Composition order

A function can be matched by more than one aspect at the same time. The order in which they are applied matters: the outermost aspect runs first, calls `proceed()`, and the next aspect runs inside it, and so on until the innermost advice calls the original function.

By default, aspects are applied in lexical declaration order: the aspect declared first in the source file is outermost. This is predictable and consistent with the principle that source order is the authoritative order for everything in Lyric.

When you need explicit control, use `wraps:` and `inside:` in the aspect header:

```lyric
aspect Auth {
  matches:
    name like "handle*"

  wraps: Logging   // Auth is outside Logging — Auth runs first

  around(call) -> ret {
    if not AuthStore.verify(call.annotations) {
      ret = Result.err(AuthError.unauthorized())
    } else {
      ret = call.proceed()
    }
  }
}
```

`wraps: OtherAspect` means this aspect is placed outside the named aspect in the composition chain — it runs before the other aspect and its `call.proceed()` enters the other aspect's advice. `inside: OtherAspect` is the reverse: this aspect is placed inside the named aspect and runs after it.

You can state multiple names in a single `wraps:` or `inside:` clause, separated by commas. The resulting order is resolved at compile time; a cycle in the ordering constraints is a compile error.

A practical heuristic: authentication should be outermost (no point logging a rejected unauthenticated request), tracing next, then logging, then instrumentation like rate limiting. Use `wraps:` and `inside:` to codify that ordering explicitly rather than relying on file order, which is fragile across merges.

## §21.5 Contract augmentation

Aspects can add `requires:` and `ensures:` clauses to the functions they match. The aspect clauses are composed additively with the function's own clauses: a function with two `requires:` clauses and an aspect that adds one more ends up with three preconditions, all of which are checked.

```lyric
aspect BudgetGuard {
  matches:
    name like "spend*"

  requires: call.annotations.contains("@budget_checked")
  ensures: true   // BudgetGuard adds no postcondition; placeholder for demonstration
}
```

There is one important restriction: `call` is NOT in scope inside a `requires:` clause. Preconditions are evaluated before the call context is established — they run against the function's parameters, not the `call` object. The `call` context is available in `ensures:` clauses because postconditions are evaluated after `proceed()` completes.

```lyric
aspect Audit {
  matches:
    name like "transfer*"

  // WRONG — call is not in scope in requires:
  // requires: call.modulePath == "TransferService"

  // Correct — call IS in scope in ensures:
  ensures: call.elapsed.isSome
}
```

The additive composition means aspects cannot remove a function's own contracts. If a function has `requires: amount > 0`, no aspect can weaken or override that precondition. Aspects can only add obligations. This is intentional: the function author retains control over the minimum contract their code depends on.

In `@proof_required` packages, aspect-added contracts become additional SMT obligations. The verifier checks the full composed contract — the function's own clauses plus every matching aspect's clauses — as a single set of proof goals.

## §21.6 Per-function opt-out

A function can be excluded from all aspects with `@no_aspect`, or excluded from a specific aspect with `@no_aspect(AspectName)`:

```lyric
@no_aspect
pub func handleHealth(): HealthStatus {
  return HealthStatus.ok()
}

@no_aspect(Logging)
pub func handleMetrics(): MetricsPayload {
  // Logging would be too noisy here; Auth and RateLimit still apply
  return Metrics.snapshot()
}
```

`@no_aspect` without arguments removes the function from every aspect's match set, regardless of what `matches:` would select. `@no_aspect(Name)` removes it from one named aspect only; other aspects still match normally.

This is the explicit per-function escape hatch. For bulk exclusions, the `except name in { ... }` clause in the aspect's `matches:` block is cleaner than annotating every function individually. Use `except` when you know at aspect-writing time that a category of functions should be excluded; use `@no_aspect` when the reason is specific to one function.

::: note
**Note:** `@no_aspect` and the `except` clause interact without ambiguity. If a function appears in an `except` list, it is excluded regardless of whether it also carries `@no_aspect`. The two mechanisms are independent and both effective.
:::

## §21.7 Aspect templates

An aspect declared with `pub` and no `matches:` block is an aspect template. It defines reusable advice that consumers instantiate locally with their own `matches:` filter:

```lyric
// In Pkg.Logging package:
pub aspect LoggingTemplate {
  config {
    enabled: Bool = true
    level:   LogLevel = LogLevel.Info
  }

  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      Std.Log.info("→ " + call.shortName)
      ret = call.proceed()
      Std.Log.info("← " + call.shortName + " (" + call.elapsed.unwrapOr(0).toString() + "ms)")
    }
  }
}
```

A consumer in another package instantiates it:

```lyric
import Pkg.Logging

aspect Logging from Pkg.Logging.LoggingTemplate {
  matches:
    name like "handle*"
    except name in { handleHealth }

  config {
    level: LogLevel = LogLevel.Debug   // override this default; enabled keeps its template default
  }
}
```

The `from Pkg.Logging.LoggingTemplate` clause names the template. The `matches:` block is required — a template has none, so the consumer must supply it. The `config {}` block is optional; if present, it overrides default values for specific fields. Field names and types must match the template exactly — you can only change defaults, not add or rename fields.

The environment variable naming uses the local instantiation name (`Logging` in the example above), not the template name.

### B-mode and C-mode templates

There are two compilation modes for `pub aspect` templates, distinguished by the `@inline_template` annotation.

**B-mode** (the default for `pub aspect`) compiles the advice body to generic IL in the template package. The advice body is fixed bytecode that ships with the template library. It can read `call.qualifiedName`, `call.shortName`, `call.elapsed`, and the other `call` fields, but it cannot read the matched function's parameters by name. This is the right mode for infrastructure concerns — logging, tracing, timing — where the advice only needs to know what function was called, not what arguments it received.

**C-mode** (`@inline_template`) recompiles the advice body in the consumer's package. Because the body is recompiled in the consumer's context, it can read the matched function's named parameters via the `args` implicit:

```lyric
@inline_template
pub aspect AuthTemplate {
  config {
    tokenField: String = "authToken"
  }

  around(call) -> ret {
    if not TokenStore.verify(args.authToken) {
      ret = Result.err(AuthError.unauthorized())
    } else {
      ret = call.proceed()
    }
  }
}
```

When instantiated against a function `handleTransfer(authToken: String, ...)`, the body can read `args.authToken` directly. The compiler type-checks the `args` access against the actual parameter types of the matched functions in the consumer package. If none of the matched functions have an `authToken` parameter, the instantiation fails with a type error.

Use B-mode for advice that works on any function regardless of its signature. Use C-mode when the advice needs to inspect specific arguments — authentication token extraction, input sanitisation, parameter-level auditing. C-mode imposes a stronger coupling between the template and the consumer: the consumer's functions must have the parameters the advice reads.

::: sidebar
**Why not always C-mode?** C-mode re-compiles the advice body per consumer package, which means the advice is part of the consumer's compilation unit, not the library's. Library authors lose the ability to ship a fixed compiled blob and guarantee binary compatibility. B-mode advice is a single compiled artefact that ships with the library and is verifiable once. C-mode advice is more like a code generator: powerful, but its behaviour is re-verified per consumer.

For most cross-cutting concerns, the information available via `call.*` is enough. Reserve `@inline_template` for the minority of aspects that genuinely need argument-level access.
:::

## Exercises

1. Write an aspect named `Timing` that matches all functions whose names start with `query` and logs `call.shortName` together with `call.elapsed` after `proceed()`. Verify that the `matches:` filter and the `around` body compile without errors.

2. Add a `config { verboseMode: Bool = false }` field to the `Timing` aspect from exercise 1. When `verboseMode` is true, also log `call.qualifiedName` and `call.sourceLocation`. When false, log only the short name and elapsed time.

3. Declare two aspects, `Auth` and `Logging`, both matching `"handle*"` functions. Use `wraps: Logging` on `Auth` to place `Auth` outside `Logging`. Add a third aspect `Metrics` and use `inside: Auth` to place it between `Auth` and `Logging`. Verify the ordering compiles.

4. Annotate one function in the match set with `@no_aspect(Logging)` and a different function with `@no_aspect`. Confirm that the first function is still matched by `Auth` and `Metrics`, and the second function is matched by none of the three aspects.

5. Write a `pub aspect LoggingTemplate` in a library package and a consumer in a separate package that instantiates it with `aspect AppLogging from Pkg.LoggingTemplate { matches: name like "serve*" }`. Override one config default in the consumer's `config {}` block. What happens if you try to add a new config field in the consumer that does not exist in the template?

6. Write a `@inline_template` aspect that reads a parameter named `requestId` from each matched function and prepends it to every log line. Instantiate it against a handler that has a `requestId: String` parameter. Then try to instantiate it against a handler that does not — observe the type error the compiler produces.
