# lyric-resilience

Resilience and fault-tolerance library for [Lyric](https://github.com/nichobbs/lyric-lang). Ships aspect templates for retry and circuit-breaker patterns with configurable exponential backoff.

> **Status**: @experimental — the Retry and CircuitBreaker aspect templates compile and have unit tests, but their end-to-end behaviour under load has not been exercised in CI. Both `.NET` and JVM backends are available.

## Platform parity

| Target | Status |
|---|---|
| `.NET` | Available |
| JVM | Available |

## Packages

| Package | Description |
|---|---|
| `Resilience` | Core: `Retry` and `CircuitBreaker` aspect templates, `sleepMs` helper |

## Installation

```toml
[dependencies]
"Lyric.Resilience" = { path = "../lyric-resilience" }

# Import as:
# import Resilience
```

## Quick start

### Retry pattern

The `Retry` aspect template automatically retries failed operations with exponential backoff:

```lyric
import Resilience
import Std.Core

aspect ApiRetry from Resilience.Retry {
  matches: name like "callRemote*"
  config {
    maxAttempts:     Int = 3
    initialDelayMs:  Int = 100
    maxDelayMs:      Int = 30000
    backoffFactor:   Int = 2
  }
}
```

When a matched function returns `Err(...)`, the aspect:

1. Waits with exponential backoff: `delay = min(initialDelayMs * 2^attempt, maxDelayMs)`
2. Retries up to `maxAttempts` times
3. Returns the result of the final attempt

### Circuit breaker pattern

The `CircuitBreaker` aspect template prevents cascading failures by stopping requests when a threshold of failures is exceeded:

```lyric
import Resilience
import Std.Core

aspect ServiceBreaker from Resilience.CircuitBreaker {
  matches: name like "callDownstream*"
  config {
    failureThreshold: Int = 5
    cooldownMs:       Int = 30000
  }
}
```

The circuit breaker operates in three states:

| State | Behavior |
|---|---|
| **Closed** | Requests pass through normally; success/failure counter runs |
| **Open** | Requests fail immediately without calling the target; reached when failures ≥ `failureThreshold` |
| **Half-open** | After `cooldownMs`, the circuit tries one request; if it succeeds, close; if it fails, reopen |

### Backoff strategy

The `Retry` aspect uses exponential backoff to increase delays between retry attempts:

```
delay_0 = initialDelayMs
delay_1 = min(initialDelayMs * backoffFactor, maxDelayMs)
delay_2 = min(initialDelayMs * backoffFactor^2, maxDelayMs)
...
```

Example with defaults:
- `initialDelayMs = 100` ms
- `maxDelayMs = 30000` ms

| Attempt | Delay |
|---|---|
| 1 | 100 ms |
| 2 | 200 ms |
| 3 | 400 ms |
| 4 | 800 ms |
| 5 | 1600 ms |
| 6 | 3200 ms |
| 7 | 6400 ms (capped at maxDelayMs = 30000) |

## Aspect templates

### `Resilience.Retry`

Automatically retries failed operations with exponential backoff.

**Applies to**: Functions returning `Result[T, String]`.

**Behavior**: When a matched function returns `Err(...)`, the aspect waits (with backoff) and retries up to `maxAttempts` times. If all retries fail, returns the error from the final attempt.

```lyric
import Resilience

aspect ApiRetry from Resilience.Retry {
  matches: name like "callRemote*"
  config {
    maxAttempts:    Int = 3
    initialDelayMs: Int = 100
    maxDelayMs:     Int = 30000
    backoffFactor:  Int = 2
  }
}
```

**Configuration**:

| Field | Type | Default | Description |
|---|---|---|---|
| `enabled` | `Bool` | `true` | Master switch |
| `maxAttempts` | `Int` | `3` | Max retries (≥ 1) |
| `initialDelayMs` | `Int` | `100` | Initial backoff in milliseconds |
| `maxDelayMs` | `Int` | `30000` | Cap on backoff |
| `backoffFactor` | `Int` | `2` | Delay multiplier per retry (exponential) |
| `jitterFraction` | `Float` | `0.1` | Jitter parameter (accepted for API compatibility; not applied) |
| `logRetries` | `Bool` | `true` | Log each failed attempt at warn level |

**Env var**: `LYRIC_ASPECT_<LocalName>_<FIELD>` (e.g., `LYRIC_ASPECT_APIRETRY_MAXATTEMPTS=5`)

### `Resilience.CircuitBreaker`

Stops requests when failure rate exceeds threshold to prevent cascading failures.

**Applies to**: Functions returning `Result[T, String]`.

**Behavior**: Tracks failures and enters "open" state when failures ≥ `failureThreshold`. While open, all requests fail immediately. After `cooldownMs`, allows one trial request ("half-open" state); if it succeeds, closes the circuit; if it fails, reopens.

```lyric
import Resilience

aspect ServiceBreaker from Resilience.CircuitBreaker {
  matches: name like "callDownstream*"
  config {
    failureThreshold: Int = 5
    cooldownMs:       Int = 30000
  }
}
```

**Configuration**:

| Field | Type | Default | Description |
|---|---|---|---|
| `enabled` | `Bool` | `true` | Master switch |
| `failureThreshold` | `Int` | `5` | Failures before opening (≥ 1) |
| `cooldownMs` | `Int` | `30000` | Duration in open state before trying half-open |

**Env var**: `LYRIC_ASPECT_<LocalName>_<FIELD>` (e.g., `LYRIC_ASPECT_SERVICEBREAKER_FAILURETHRESHOLD=10`)

## Composition example

Combine `Retry` and `CircuitBreaker` to implement robust fault tolerance:

```lyric
import Resilience
import Std.Core

// Inner aspect: retry transient failures
aspect Retry from Resilience.Retry {
  matches: name like "call*Service"
  config {
    maxAttempts:    Int = 3
    initialDelayMs: Int = 100
    maxDelayMs:     Int = 2000
    backoffFactor:  Int = 2
  }
}

// Outer aspect: circuit breaker stops cascading failures
aspect CircuitBreak from Resilience.CircuitBreaker {
  matches: name like "call*Service"
  inside: Retry
  config {
    failureThreshold: Int = 5
    cooldownMs:       Int = 60000
  }
}

// Example call flow:
// 1. Incoming request → CircuitBreaker checks state
// 2. If closed, proceed to Retry
// 3. Retry loop: call target, on Err retry with backoff up to 3x
// 4. Return result to CircuitBreaker
// 5. CircuitBreaker updates failure count and state
pub func callUserService(userId: in Int): Result[User, String] {
  // Implementation—aspects wrap this automatically
  ...
}
```

The execution order is **outer to inner on entry, inner to outer on exit**:

```
Entry:  CircuitBreak.enter → Retry.enter → target
Exit:   target → Retry.exit → CircuitBreak.exit
```

So the circuit breaker guards the entire retry loop, preventing the system from retrying when the circuit is already open.

## Low-level API

### `sleepMs`

Block the calling thread for a specified number of milliseconds:

```lyric
pub func sleepMs(ms: in Int): Unit
  requires: ms >= 0
```

| Parameter | Description |
|---|---|
| `ms` | Milliseconds to sleep |

**Example**:

```lyric
import Resilience
import Std.Time

func retryWithCustomLogic(target: Unit -> Result[Int, String]): Result[Int, String] {
  var attempt = 0
  var result = target()

  while attempt < 3 && result.isErr() {
    // Simple exponential backoff: 100ms, 200ms, 400ms
    val delayMs = 100 * (1 << attempt)
    Resilience.sleepMs(delayMs)
    attempt = attempt + 1
    result = target()
  }

  result
}
```

## Integration with other libraries

### With `lyric-logging`

Log retry and circuit-breaker events:

```lyric
import Resilience
import Lyric.Logging

val log = Lyric.Logging.getLogger("MyApp.Resilience")

aspect Retry from Resilience.Retry {
  matches: name like "call*"
  config {
    maxAttempts: Int = 3
  }
}

// Inside matched function:
// Retry aspect logs: [DEBUG] → attempt 1/3
//                    [DEBUG] ← attempt 1/3 failed; retry
//                    [DEBUG] ← attempt 3/3 succeeded
```

### With `lyric-web`

Protect HTTP handlers from downstream failures:

```lyric
import Resilience
import Web

aspect DownstreamRetry from Resilience.Retry {
  matches: name like "handle*"
  config {
    maxAttempts: Int = 2
  }
}

pub func handleGetUser(id: in Int): Result[User, ApiError] {
  // Automatically retries callUserService on transient failures
  val user = callUserService(id)?
  Ok(user)
}

// Wire the handler into a Web router:
// var router = Web.create()
// router = Web.addGet(router, "/users/{id}", "MyApp.handleGetUser")
```

## Package layout

```
lyric-resilience/
  lyric.toml                  package manifest
  README.md                   this file
  src/
    resilience.l              Resilience  (Retry, CircuitBreaker, sleepMs)
  tests/
    *_tests.l                 test modules
```

## See also

- `docs/26-aspects.md` §18 — aspect template design and instantiation rules
- `docs/27-aspect-libraries.md` — cross-package aspect distribution
- `docs/25-config-blocks.md` — config block semantics
- `docs/03-decision-log.md` — design decisions
