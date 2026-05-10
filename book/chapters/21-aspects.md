# Chapter 21: Aspects

Aspects let you apply cross-cutting behaviour — logging, caching, rate-limiting,
timeouts — to a set of functions without modifying those functions.  Lyric's
aspect system uses `around` advice and a `call` context object to wrap matched
functions at compile time.

## Defining an aspect

```lyric
aspect HttpLogging from Web.Aspects.RequestLogging {
  matches: name like "handle*"
  config {
    level: Std.Logging.LogLevel = Std.Logging.LogLevel.Info
  }
}
```

An aspect declaration names a *template* (`from`), a *selector* (`matches:`),
and optional *config overrides*.  The compiler weaves the template body around
every function in the current package whose name matches the selector.

## The `matches:` selector

`matches:` accepts a Boolean expression over function metadata:

| Predicate | Meaning |
|---|---|
| `name like "pattern"` | Simple wildcard match on the short function name |
| `name == "exactName"` | Exact match |
| `qualified like "Pkg.*"` | Match on the fully-qualified name |

Multiple predicates can be combined with `&&` and `\|\|`.

## The `call` context

Inside an aspect template body, `call` exposes the wrapped invocation:

| Field | Type | Meaning |
|---|---|---|
| `call.shortName` | `String` | Short function name |
| `call.qualifiedName` | `String` | Fully-qualified function name |
| `call.modulePath` | `String` | Package name |
| `call.elapsed` | `Option[Int]` | Elapsed milliseconds (populated after `call.proceed()`) |
| `call.proceed()` | returns `ret` type | Invoke the original function |

## The `around` body

```lyric
around(call) -> ret {
  // code before
  ret = call.proceed()
  // code after; ret is now bound
}
```

- `ret = call.proceed()` invokes the original function and binds the result.
- Code before `call.proceed()` runs as a pre-condition.
- Code after `call.proceed()` can inspect or replace `ret`.
- If `enabled` is `false`, the body should delegate: `ret = call.proceed()`.

## Pub aspect templates (`pub aspect`)

A `pub aspect` without a `matches:` selector is a *reusable template*.
Libraries publish templates; consumers instantiate them with their own
`matches:` and config.

```lyric
// In a library:
pub aspect QueryLogging {
  config {
    enabled: Bool = true
    level:   Std.Logging.LogLevel = Std.Logging.LogLevel.Debug
  }
  around(call) -> ret {
    // ...
  }
}

// In a consuming package:
aspect DbLog from Db.Aspects.QueryLogging {
  matches: name like "handle*"
  config { level: Std.Logging.LogLevel = Std.Logging.LogLevel.Info }
}
```

## Config fields and env vars

Every config field declared in an aspect template is overridable at runtime via
an env var:

```
LYRIC_ASPECT_<INSTANTIATION>_<FIELD>
```

For example, if you instantiate `aspect DbLog from Db.Aspects.QueryLogging`,
the master switch env var is `LYRIC_ASPECT_DBLOG_ENABLED`.

## B-mode vs C-mode templates

| Mode | How | Use case |
|---|---|---|
| B-mode | Template body is compiled once | Observing `call.qualifiedName`, `call.elapsed` |
| C-mode (`@inline_template`) | Body is re-compiled in the consumer's package | Reading named `args.*` fields on the concrete handler |

C-mode templates declare `@inline_template` and access `args.<fieldName>` by
name.  The compiler reports shape error A0042 if the matched handler does not
declare the expected parameter.

## Aspect composition

Multiple aspects can be applied to the same function.  The `inside:` keyword
controls ordering:

```lyric
aspect HttpLogging from Web.Aspects.RequestLogging {
  matches: name like "handle*"
}

aspect ApiRateLimit from Web.Aspects.RateLimiting {
  matches: name like "handle*"
  inside:  HttpLogging          // RateLimiting runs inside HttpLogging
}
```

The `inside:` aspect's body wraps the innermost call; the outer aspect wraps
the inner.

## Contract augmentation

Aspects can contribute `ensures:` clauses that are visible to downstream
`@proof_required` consumers:

```lyric
pub aspect Timeout {
  ensures:
    call.elapsed.unwrapOr(0) >= 0
  around(call) -> ret {
    // ...
  }
}
```

## Summary

| Concept | Syntax |
|---|---|
| Instantiate a template | `aspect Name from Pkg.Template { matches: ...; config { ... } }` |
| Template declaration | `pub aspect Name { config { ... }; around(call) -> ret { ... } }` |
| Proceed | `ret = call.proceed()` |
| Composition | `inside: OuterAspect` |
| Runtime config override | `LYRIC_ASPECT_<NAME>_<FIELD>` |
| C-mode template | `@inline_template pub aspect Name { ... }` |
