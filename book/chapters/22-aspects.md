# Aspects

Most code has concerns that cut across many functions: logging every request that enters a service, measuring how long each operation takes, enforcing an authentication check before any handler runs. The natural impulse is to write a helper and call it from each function. The problem is that the helper call is now scattered across dozens of functions, and every new function added to the service needs the same boilerplate. When the requirement changes — say, log the elapsed time as well as the entry — you update one function and miss seven others, or you refactor the helper's signature and break every call site at once.

Lyric addresses this with the `aspect` block. An aspect describes behaviour that should apply to a matched set of functions, written once and maintained in one place. The compiler weaves it in — no call-site boilerplate, no scattered wrapper functions, no synchronization burden when the requirement changes.

## §22.1 The `aspect` block

An aspect is a module-scope item, a peer to `func`, `wire`, and `config`. Here is a complete aspect that logs entry and exit for a family of request-handling functions:

```lyric
aspect Logging {
  matches: name like "handle*"

  around(args) -> ret {
    Std.Log.info("→ entering handler")
    proceed(args)
    Std.Log.info("← exiting handler")
  }
}
```

Three parts make up this aspect.

**`matches:`** is the filter that determines which functions this aspect applies to. It accepts one or more predicates joined by `and`; every predicate must hold for a function to be selected:

| Predicate | Selects when… |
|-----------|---------------|
| `name like "<glob>"` | Short name matches the glob (`*` any sequence, `?` one char, `[abc]`/`[a-z]` sets/ranges) |
| `annotated: @Name` | Function carries the named annotation |
| `visibility: pub \| priv \| internal` | Function has the stated access level |
| `signature: returns "<glob>"` | Return type (e.g. `"Int"`, `"Result[*,*]"`) matches the glob |

An optional `except name in { fn1, fn2 }` suffix excludes specific functions by short name after all predicates pass. For example, `name like "handle*"` selects every function in the current package whose short name starts with `handle`.

**`around(args) -> ret`** is the advice body. `args` is a placeholder for the original function's arguments, forwarded unchanged when you call `proceed(args)`. `ret` is the binding name for the return value; its type equals the matched target's return type. The body's last expression is the return value (for `Unit`-returning functions this is implicit).

**`proceed(args)`** executes the matched function with the original arguments. Everything before it is pre-advice; everything after is post-advice. You can call it zero times (skip the original function entirely) or more than once (retry, repeat). The most common pattern is a single call.

Matching aspects are package-private: an `aspect` block weaves over functions in the same package only. A `pub aspect` without a `matches:` clause is an exportable template — see §22.6 for current limitations.

## §22.2 Composition order

A function can be matched by more than one aspect at the same time. By default, aspects are applied in lexical declaration order: the aspect declared first is outermost (runs first, calls `proceed()` which enters the next aspect, and so on).

When you need explicit control, use `wraps:` and `inside:` in the aspect header:

```lyric
aspect Auth {
  matches: name like "handle*"
  wraps: Logging   // Auth is outside Logging — Auth runs first

  around(args) -> ret {
    if not AuthStore.verify() {
      return Result.err(AuthError.unauthorized())
    }
    proceed(args)
  }
}

aspect Logging {
  matches: name like "handle*"

  around(args) -> ret {
    Std.Log.info("→ handler")
    proceed(args)
    Std.Log.info("← handler")
  }
}
```

`wraps: OtherAspect` means this aspect is placed outside the named aspect — it runs before the other aspect and its `proceed(args)` enters the other aspect's advice. `inside: OtherAspect` is the reverse.

You can name multiple aspects in a single `wraps:` or `inside:` clause, separated by commas. The compiler resolves the ordering at build time; a cycle in the ordering constraints is a compile error.

## §22.3 Contract augmentation

Aspects can add `requires:` and `ensures:` clauses to the functions they match. The aspect clauses are composed additively with the function's own clauses: a function with two `requires:` clauses and an aspect that adds one more ends up with three preconditions, all of which are checked.

```lyric
aspect Positive {
  matches: name like "add*"
  requires: true   // trivially-true; illustrates that the clause is evaluated

  around(args) -> ret {
    proceed(args)
  }
}
```

The additive composition means aspects cannot remove a function's own contracts. If a function has `requires: amount > 0`, no aspect can weaken or override that precondition — aspects can only add obligations.

In `@proof_required` packages, aspect-added contracts become additional SMT obligations. The verifier checks the full composed contract as a single set of proof goals.

## §22.4 Per-function opt-out

A function can be excluded from all aspects with `@no_aspect`, or excluded from a specific aspect with `@no_aspect("AspectName")` (passing the name as a string literal):

```lyric
@no_aspect
pub func handleHealth(): HealthStatus {
  return HealthStatus.ok()
}

@no_aspect("Logging")
pub func handleMetrics(): MetricsPayload {
  // Logging would be too noisy here; Auth still applies.
  return Metrics.snapshot()
}
```

`@no_aspect` without arguments removes the function from every aspect's match set, regardless of what `matches:` would select. `@no_aspect("Name")` removes it from one named aspect only.

Use `@no_aspect` when the reason is specific to one function and you know the aspect name at the time you write the function.

## §22.5 `proceed(args)` semantics

`proceed(args)` in the around body calls the target function with the original arguments and returns the target's return value. Several common patterns:

**Before/after wrapping:**

```lyric
around(args) -> ret {
  println("before")
  proceed(args)
  println("after")
}
```

**Early return (skip the target):**

```lyric
around(args) -> ret {
  if CacheStore.has(cacheKey) {
    return CacheStore.get(cacheKey)
  }
  proceed(args)
}
```

**Repeat (retry or loop):**

```lyric
around(args) -> ret {
  var i = 0
  while i < 3 {
    proceed(args)
    i = i + 1
  }
}
```

`proceed(args)` may appear anywhere in the around body, including inside loops, if-branches, and try blocks.

## §22.6 Features not yet implemented

The following features are designed and specified in `docs/26-aspects.md` but not yet wired in the compiler:

**`call` context.** Inside the `around` body, the ambient `call` value
exposes compile-time-known metadata about the weave site: `call.shortName`,
`call.qualifiedName`, `call.modulePath`, `call.sourceLocation`,
`call.annotations`, and `call.aspect` are materialised as locals by the
weaver and rewritten in place. The weaver pre-scans the body and only
emits the locals that are actually read — aspects that don't reference
`call.*` produce byte-identical wrappers to the weaver's pre-tier-6
output. `call.elapsed` and `call.caller` need runtime instrumentation
(timestamp capture around `proceed`, caller-site stack walk) and are
not yet wired; references to either surface as an **A0043** weave-time
diagnostic naming the unrecognised field and listing the recognised
ones. Follow-up tracked in issue #1298.

**`config {}` injection.** Each `config { }` field with a literal
default is materialised by the weaver as a synthetic
`val __aspect_cfg_<name>: <ty> = <default>` at the top of the woven
body, and `config.<name>` member accesses inside the body are
rewritten to that local. Fields without a default are skipped —
runtime env-var resolution per the config-block design is a follow-up.
The prelude is lazy: aspects that never read `config.*` get no
synthetic locals.

**`@inline_template` (C-mode).** Aspects whose enclosing item carries
`@inline_template` get `args.<field>` rewrites at weave time: each
field name must match a parameter of the matched function, and
mismatches surface as an **A0042** weave-time diagnostic naming the
aspect, the matched function, and the offending field. The old L006
lint warning has been removed since the rewriting now lands.

The rest of the aspect system works end-to-end: write an aspect in a package, publish it, consume it in another package, and the compiler weaves it over the matched functions at build time. Aspect templates (`pub aspect` without `matches:`), pointcut predicates (`annotated:`, `visibility:`, `signature: returns`), composition ordering (`wraps:` / `inside:`), and the `except name in { … }` exclusion clause are all fully shipped.

## Exercises

1. Write an aspect named `Timing` that matches all functions whose names start with `query`. Before `proceed(args)` print `"start"` and after it print `"end"`. Verify that a `queryUser` function prints `start`, then its own output, then `end`.

2. Declare two aspects, `Auth` and `Logging`, both matching `"handle*"` functions. Use `wraps: Logging` on `Auth` to place `Auth` outside `Logging`. Call a matched function and verify that `Auth`'s pre-advice runs before `Logging`'s pre-advice.

3. Add `requires: true` to an aspect that matches `"compute*"` functions. Verify that the program compiles and the matched function returns the correct result. Then change `requires: true` to `requires: false` and observe the runtime contract failure (in a `@runtime_checked` package).

4. Annotate one function with `@no_aspect` and another with `@no_aspect("Logging")`. Confirm that the first function is wrapped by neither aspect, and the second is still wrapped by `Auth` but not `Logging`.

5. Write an aspect whose `around` body calls `proceed(args)` inside a `while` loop three times. Call the matched function once and verify that its body runs three times.
