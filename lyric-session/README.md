# lyric-session

Distributed session management with pluggable backends (Redis, in-process).

## Platform parity

| Feature flag | Backend                                              | Status    |
|--------------|-------------------------------------------------------|-----------|
| `dotnet`     | StackExchange.Redis (`Session.Kernel.Net`)            | Available |
| `jvm`        | Lettuce (`io.lettuce:lettuce-core`, `Session.Kernel.Jvm`) | Available |
| `InProcessSessionStore` (both targets) | pure Lyric, no kernel | `dotnet`: Available; `jvm`: **Broken** — see below |

Both kernels bind their respective Redis client directly via `extern
type` + auto-FFI — no F#/Java host shim, no `extern package` (that
mechanism never generated a real binding in either the type checker or
MSIL/JVM codegen). `dotnet` and `jvm` are **mutually exclusive**:
activating both leaves two definitions of `Session`'s Redis dispatch
functions in the bundle (ambiguous-symbol build error). Select exactly
one, matching `--target`:

```sh
lyric build --manifest lyric-session/lyric.toml                                    # --target dotnet (default features)
lyric build --manifest lyric-session/lyric.toml --target jvm --no-default-features --features jvm
```

The `jvm` feature needs `io.lettuce:lettuce-core` resolved via `lyric
restore` (the `[maven]` table in `lyric.toml`); `lyric-resolver.jar`
must be on `PATH`/beside the `lyric` binary/`$LYRIC_MAVEN_RESOLVER` (see
`docs/31-maven-linking.md`).

There is no host-backed in-memory store on either target — the earlier
JVM kernel's `lyric.session.InMemoryStore` `extern package` block was
dead code (the mechanism is a confirmed no-op) and was removed rather
than ported. `InProcessSessionStore` below is pure Lyric and does not
need a kernel at all — but it does not currently work on `--target
jvm`: any write (`create()` followed by `set()`/`get()`/`load()`)
crashes with `class Session.SessionData cannot be cast to class
java.lang.Long`, a JVM backend erased-generics bug tracked in #5451
(not caused by, or specific to, this library — a `Map[String,
SessionData]` value read appears to resolve against an unrelated
`Map[String, Long]` instantiation elsewhere in the JVM bundle). Use the
Redis-backed `NativeSessionStore` on JVM until #5451 is fixed.

**Known gap:** `lyric test --target jvm` and `lyric run --target jvm`
exec the compiled JAR as a plain `java -jar`, with no `-cp`/
`--module-path` for `[maven]`-restored dependencies (a pre-existing gap
in `cli_test.l`/`cli_run.l`, not specific to this library). `lyric build
--target jvm` works correctly and produces a real, auto-FFI-resolved
JAR; running that JAR standalone (against a live Redis) needs the
classpath from `target/restore/jvm-classpath.txt` appended manually,
e.g.:

```sh
lyric restore --manifest lyric-session/lyric.toml
lyric build --manifest lyric-session/lyric.toml --target jvm --no-default-features --features jvm
CP="lyric-session/bin/Session.dll:$(tr '\n' ':' < lyric-session/target/restore/jvm-classpath.txt)"
LYRIC_CONFIG_SESSION_REDISSESSION_URL="redis://127.0.0.1:6379" java -cp "$CP" YourMainClass
```

## Packages

| Package | Purpose |
|---|---|
| `Session` | Core types, `SessionStore` interface, in-process implementation, and public API |
| `Session.Kernel.Net` | StackExchange.Redis-backed session store (`dotnet` feature) |
| `Session.Kernel.Jvm` | Lettuce-backed session store (`jvm` feature) |

## Quick start

```lyric
import Session

// In-memory sessions for development
val store = Session.inMemory()

// Always obtain a fresh session id from `create()` before calling
// `set()`. Calling `set()` on a caller-supplied id that the store has
// not previously issued will return `SESSION_NOT_FOUND`; this is the
// session-fixation guard described in the Security section below.
val sessionId = Session.create(store)

// Store session data
Session.set(store, sessionId, "userId", "user123")
Session.set(store, sessionId, "role", "admin")

// Retrieve session data
match Session.get(store, sessionId, "userId") {
  case Some(value) -> println("user: " + value)
  case None        -> println("session expired")
}

// Clean up
Session.destroy(store, sessionId)
```

## SessionStore interface

`SessionStore` is a pluggable interface for multiple backends:

```lyric
pub interface SessionStore {
  func create(): String
  func load(sessionId: in String): Option[SessionData]
  func save(sessionId: in String, data: in SessionData): Unit
  func destroy(sessionId: in String): Unit
  func get(sessionId: in String, key: in String): Option[String]
  func set(sessionId: in String, key: in String, value: in String): Unit
  func delete(sessionId: in String, key: in String): Unit
  func clear(sessionId: in String): Unit
  func touch(sessionId: in String): Unit
}
```

The v1 implementation is `InProcessSessionStore` (in-memory, single-process).
For distributed systems, use `NativeSessionStore` (Redis-backed, `dotnet` or `jvm` feature).

## Backends

### In-memory (`InProcessSessionStore`)

`Session.inMemory()` stores sessions in-memory. Best for single-server
development. **`--target dotnet` only today** — see "Known gap" above
(#5451); on `--target jvm`, use `NativeSessionStore` instead.

### Redis (`dotnet` / `jvm` feature)

`Session.connectRedis()` connects to Redis, reading connection settings from
the environment (`Session`'s `RedisSession` config block):

| Env var | Default | Meaning |
|---|---|---|
| `LYRIC_CONFIG_SESSION_REDISSESSION_URL` | (required) | Redis connection string |
| `LYRIC_CONFIG_SESSION_REDISSESSION_KEYPREFIX` | `"session:"` | Prefix for session keys |
| `LYRIC_CONFIG_SESSION_SESSION_TTLSECONDS` | `3600` | Session TTL in seconds |

**The connection-string format differs by backend** — each kernel passes
`LYRIC_CONFIG_SESSION_REDISSESSION_URL` straight through to its client
library's own parser, and the two are not interchangeable:

- `dotnet` (`Session.Kernel.Net`, StackExchange.Redis): the library's
  native `host:port[,option=value...]` configuration-string syntax, e.g.
  `127.0.0.1:6379` or `127.0.0.1:6379,password=secret`. **Not** a
  `redis://` URI — StackExchange.Redis does not parse URI schemes, and
  passing one produces a confusing "was not possible to connect to the
  redis server(s)" failure rather than a parse error.
- `jvm` (`Session.Kernel.Jvm`, Lettuce): a `redis://` (or `rediss://` for
  TLS) URI, e.g. `redis://127.0.0.1:6379`, per Lettuce's `RedisURI`
  parser.

Note: `NativeSessionStore` is `@experimental` pending atomic Redis operations.

## Session configuration

Configure sessions via `SessionConfig` in a `config` block:

```lyric
config SessionConfig {
  ttlSeconds: Int = 3600
  cookieName: String = "_session"
  secure: Bool = true
  httpOnly: Bool = true
  sameSite: String = "Strict"
}
```

Config fields:

| Field | Type | Default | Meaning |
|---|---|---|---|
| `ttlSeconds` | `Int` | `3600` | Session expiry time in seconds |
| `cookieName` | `String` | `"_session"` | HTTP cookie name |
| `secure` | `Bool` | `true` | Set Secure cookie flag (HTTPS only) |
| `httpOnly` | `Bool` | `true` | Set HttpOnly cookie flag (no JS access) |
| `sameSite` | `String` | `"Strict"` | SameSite policy: Strict / Lax / None |

## API reference

```lyric
Session.inMemory()                                 // SessionStore
Session.connectRedis(url)                          // SessionStore
Session.create(store)                              // String (session ID)
Session.load(store, sessionId)                     // Option[SessionData]
Session.save(store, sessionId, data)               // Unit
Session.destroy(store, sessionId)                  // Unit
Session.touch(store, sessionId)                    // Unit (reset TTL)
Session.get(store, sessionId, key)                 // Option[String]
Session.set(store, sessionId, key, value)          // Unit
Session.delete(store, sessionId, key)              // Unit
Session.clear(store, sessionId)                    // Unit
```

## Security

### Session fixation

`Session.set()`, `Session.delete()`, and `Session.clear()` all refuse
to operate on a `sessionId` the store has not previously issued.
Specifically, `set()` returns
`Err(SessionError { code = "SESSION_NOT_FOUND", ... })` rather than
creating a new session for the supplied id.

This is deliberate: allowing `set()` to materialise a session for a
caller-supplied id is a classic session-fixation vector — an attacker
who plants a known cookie value (via XSS, subdomain cookie taint, or
a phishing link) can have it elevated when the legitimate user signs
in.  Always obtain a fresh id from `create()` first, and call
`destroy(oldId)` followed by `create()` on every authentication or
privilege-elevation event to rotate the id.

### Secure cookie defaults

`SessionConfig` defaults `secure = true`, `httpOnly = true`,
`sameSite = "Lax"`.  These protect the session cookie against XSS
theft and CSRF by default without operator action.

## Decision log

See `docs/03-decision-log.md` D057 and `docs/10-bootstrap-progress.md`.
