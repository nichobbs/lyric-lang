# lyric-session

Distributed session management with pluggable backends (Redis, in-process).

## Packages

| Package | Purpose |
|---|---|
| `Session` | Core types, `SessionStore` interface, in-process implementation, and public API |
| `Session.Redis` | Native Redis-backed session store (requires `redis` feature) |

## Quick start

```lyric
import Session

// In-memory sessions for development
val store = Session.inMemory()

// Create a new session
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
For distributed systems, use `NativeSessionStore` (Redis-backed, requires `redis` feature).

## Backends

### In-memory (`InProcessSessionStore`)

`Session.inMemory()` stores sessions in-memory. Best for single-server development.

### Redis (`redis` feature)

`Session.connectRedis(url)` connects to Redis. Configure via environment:

| Env var | Default | Meaning |
|---|---|---|
| `LYRIC_SESSION_REDIS_URL` | (required) | Redis connection string (redis://...) |
| `LYRIC_SESSION_REDIS_KEY_PREFIX` | `"session:"` | Prefix for session keys |
| `LYRIC_SESSION_REDIS_TTL_SECONDS` | `3600` | Session TTL in seconds |

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

## Decision log

See `docs/03-decision-log.md` D057 and `docs/10-bootstrap-progress.md`.
