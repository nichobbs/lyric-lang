# lyric-session

**Stability:** `stable`

Session management for Lyric web applications: the `SessionStore` interface,
the in-process store, and the cookie and lifetime configuration helpers.
Distributed backends are separate packages that implement `SessionStore`;
the Redis one is `Lyric.Session.Redis` in lyric-ecosystem (see
"Migrating from `connectRedis()`" below).

## Platform parity

| Target | Status |
|---|---|
| `dotnet` | Available |
| `jvm` | Available |
| `native` | Available (pure Lyric, no kernel; the `Session.SessionConcurrency*Tests` modules are gated to `dotnet` / `jvm`) |

The package is pure Lyric with no third-party dependency, no kernel and no
feature flags: `lyric build` and `lyric test` need no `--features` flag and no
`lyric restore`. It declares `targets = ["dotnet", "jvm", "native"]`.

## Packages

| Package | Purpose |
|---|---|
| `Session` | Core types, `SessionStore` interface, in-process implementation, cookie configuration and public API |

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

The bundled implementation is `InProcessSessionStore` (in-memory,
single-process). For distributed systems use a backend package that implements
`SessionStore`, such as `Lyric.Session.Redis` (lyric-ecosystem).

## Backends

### In-memory (`InProcessSessionStore`)

`Session.inMemory()` stores sessions in-memory. Best for single-server
development. Works on both `--target dotnet` and `--target jvm`.

### Distributed stores

A multi-instance deployment needs a store shared between instances. Backends
live outside this package and implement `SessionStore`, so application code
that takes a `SessionStore` is unchanged. For Redis use `Lyric.Session.Redis`
(`session-redis` in lyric-ecosystem), which runs on `dotnet`, `jvm` and
`native` and re-exports `Session`.

## Migrating from `connectRedis()`

`Session.connectRedis()`, `NativeSessionStore`, the `dotnet` and `jvm`
features, `Session.Kernel.Net` / `Session.Kernel.Jvm`, and the
`LYRIC_CONFIG_SESSION_REDISSESSION_URL` / `_KEYPREFIX` variables were removed
(D614; the extraction phase of docs/71). Replace them with
`Lyric.Session.Redis`:

```lyric
import Session
import Session.Redis as RedisSessions

// before: val store = Session.connectRedis()?   (reads the environment)
val url = Env.getVarOrDefault("APP_SESSION_REDIS_URL", "")
val store = RedisSessions.connect(url, RedisSessions.options("session:", 3600))?
```

| `connectRedis()` | `Lyric.Session.Redis` |
|---|---|
| `LYRIC_CONFIG_SESSION_REDISSESSION_URL` | the `url` argument of `connect`; a `redis://` / `rediss://` URL on every target (the old `dotnet` kernel took a StackExchange `host:port,password=...` string) |
| `LYRIC_CONFIG_SESSION_REDISSESSION_KEYPREFIX` | `options(keyPrefix, ttlSeconds)`, `keyPrefix` (required, not empty) |
| `LYRIC_CONFIG_SESSION_SESSION_TTLSECONDS` | `options(..., ttlSeconds)`; the package reads no environment variable, so pass `Session.sessionConfigFromEnv().ttlSeconds` to keep the cookie and store lifetimes equal |
| `Err(MISSING_REDIS_URL)` | not returned; an unusable URL is `Err(CONNECT_FAILED)` |
| `Err(CONNECT_FAILED)` | the same code; the message never contains the password |

Existing sessions do not carry over. The old store kept each session as one
JSON string under `<keyPrefix><uuid>`; `Lyric.Session.Redis` keeps a Redis hash
under `<keyPrefix><64 hex characters>`, and answers a key of another type under
its prefix with an error, not a missing session. Choose a new prefix, or delete
the old keys before the first deployment
(`redis-cli --scan --pattern 'session:*' | xargs redis-cli del`); either way
every signed-in user signs in again once. Session ids issued before that point
(hyphenated UUIDs, or the no-dash form of the pre-#3022 F# shim) are valid
ids (`isValidSessionId`) but name no session in the new store. Unlike the old
store, every read-modify-write there is one Lua script, so concurrent requests
on one session lose no update.

## Session configuration

Session lifetime and cookie settings are read from the environment via
`Session.sessionConfigFromEnv()`, which returns a plain `SessionConfig`
record (not a `config` block — this library reads its env vars directly,
the same way `inMemory()` does):

```lyric
pub record SessionConfig {
  cookieName: String   // default: "LYRIC_SESSION"
  secure: Bool          // default: true
  httpOnly: Bool        // default: true
  sameSite: String      // default: "Lax"
  ttlSeconds: Int       // default: 3600
}
```

| Env var | Default | Meaning |
|---|---|---|
| `LYRIC_CONFIG_SESSION_SESSION_COOKIENAME` | `"LYRIC_SESSION"` | HTTP cookie name |
| `LYRIC_CONFIG_SESSION_SESSION_SECURE` | `true` | Set the `Secure` cookie flag (HTTPS only) |
| `LYRIC_CONFIG_SESSION_SESSION_HTTPONLY` | `true` | Set the `HttpOnly` cookie flag (no JS access) |
| `LYRIC_CONFIG_SESSION_SESSION_SAMESITE` | `"Lax"` | `SameSite` attribute value: `Strict` / `Lax` / `None` |
| `LYRIC_CONFIG_SESSION_SESSION_TTLSECONDS` | `3600` | Session expiry time in seconds |

`SessionConfig` carries invariants:
- `cookieName` must be an RFC 6265 token (`isCookieToken`);
- `sameSite` must be exactly `Strict`, `Lax` or `None`;
- `ttlSeconds` must be 1 to 31536000 (one year).

A hand-built config that breaks one is a precondition failure; it used to
be silently rewritten, and a lower-case `none` skipped the forced `Secure`.
`sessionConfigFromEnv()` stays fail-soft, so its result always satisfies
them:
- a malformed or absent value falls back to its default;
- `sameSite` is matched case-insensitively (`none` becomes `None`);
- a TTL outside the range falls back to 3600.

`Session.inMemory()` reads the same TTL variable.

Use `Session.cookieHeader(sessionId, cfg)` to build the `Set-Cookie`
header *value* for a session id:

```lyric
val cfg = Session.sessionConfigFromEnv()
val setCookie = Session.cookieHeader(sessionId, cfg)
// "LYRIC_SESSION=<sessionId>; Path=/; HttpOnly; Secure; SameSite=Lax"
```

`cookieHeader` is pure — it builds the header value only. Attach the
returned string as the `Set-Cookie` header on your HTTP framework's
response object (e.g. `lyric-web`'s `Response`); this library does not
write the response header for you.

## API reference

```lyric
Session.inMemory()                                 // SessionStore
Session.create(store)                              // String (session ID)
Session.load(store, sessionId)                     // Option[SessionData]
Session.save(store, sessionId, data)               // Unit
Session.destroy(store, sessionId)                  // Unit
Session.touch(store, sessionId)                    // Unit (reset TTL)
Session.get(store, sessionId, key)                 // Option[String]
Session.set(store, sessionId, key, value)          // Unit
Session.delete(store, sessionId, key)              // Unit
Session.clear(store, sessionId)                    // Unit
Session.sessionConfigFromEnv()                     // SessionConfig
Session.cookieHeader(sessionId, cfg)               // String (Set-Cookie value)
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

### Untrusted session ids

Session ids arrive in request cookies, so every store checks
`isValidSessionId` (1 to 128 characters from `[A-Za-z0-9_-]`, which covers
the UUIDs `create()` issues) before touching its backend:
- an empty or malformed id loads as `None`, and destroying or touching it
  is a no-op;
- saving one returns `Err(INVALID_SESSION_ID)`.

A request carrying `LYRIC_SESSION=` used to reach a store precondition
and crash.

### Secure cookie defaults

`sessionConfigFromEnv()` defaults `secure = true`, `httpOnly = true`,
`sameSite = "Lax"`.  `Session.cookieHeader()` writes these flags into
the returned `Set-Cookie` value, so a caller that uses
`sessionConfigFromEnv()`'s defaults and calls `cookieHeader()` gets a
cookie that resists XSS theft (`HttpOnly`) and cross-site request
forgery (`SameSite`) without further action — but only once it
actually calls `cookieHeader()` and attaches the result to its HTTP
response; this library does not wire the header into any HTTP
framework's response automatically.

## Decision log

See `docs/03-decision-log.md` D057, `docs/decisions/D614-session-redis-extracted.md`
and `docs/10-bootstrap-progress.md`.
