# D614 - The Redis backend of `lyric-session` is removed; `Lyric.Session.Redis` replaces it

**Status:** shipped. Extraction phase of docs/71 (D552, D561).

## Context

`lyric-session` carried a Redis store: `NativeSessionStore`, `connectRedis()`,
and two kernels (`Session.Kernel.Net` on StackExchange.Redis, `Session.Kernel.Jvm`
on Lettuce) behind mutually exclusive `dotnet` / `jvm` features and `[nuget]` /
`[maven]` tables. It stored a session as one JSON string and updated it with
separate load and save round trips (lost updates under concurrency, documented
as `@experimental`), read its configuration from
`LYRIC_CONFIG_SESSION_REDISSESSION_*`, and was never run against a live server
in CI beyond a JVM test file that needed `LYRIC_SESSION_REDIS_URL`.

`lyric-ecosystem` now has `Lyric.Session.Redis` (`session-redis`), built on the
pure-Lyric `Lyric.Redis` client: every read-modify-write is one Lua script, it
runs the `Testing.Conformance.Session` suite against a real server on `dotnet`,
`jvm` and `native`, and it needs no third-party library. CLAUDE.md of that
repository puts any backend that needs an SDK or a native dependency there.

## Decision

1. Remove from `lyric-session`: `NativeSessionStore`, `connectRedis()`, the
   `RedisSession` config variables (`LYRIC_CONFIG_SESSION_REDISSESSION_URL`,
   `_KEYPREFIX`), `src/_kernel/net` and `src/_kernel/jvm`, the Redis JSON
   serialisation helpers, `tests/session_redis_jvm_tests.l`, the `dotnet` /
   `jvm` features, the `[nuget]` and `[maven]` tables and the `Lyric.Cache`
   dependency (it was only a build-order edge; nothing imports `Cache`).
   Nothing in `lyric-stdlib` or the compiler changes.
2. Keep the `SessionStore` interface, `SessionError`, `SessionData`, the
   in-process store, the cookie and lifetime helpers, `isValidSessionId`,
   `maxSessionTtlSeconds` (both used by `Lyric.Session.Redis`) and
   `maskUrlCredentials` (public, `@stable`, still covered by its tests; a
   backend routes connection errors through it).
3. The package is now pure Lyric with no kernel or feature, builds and passes
   its suite on `dotnet`, the JVM and native, and declares
   `targets = ["dotnet", "jvm", "native"]` (D603). The `Session.SessionConcurrency*Tests`
   modules stay gated to `dotnet` / `jvm`; there is no native concurrency test.
4. The README carries a migration note (option mapping, key layout and id
   format differences, and that existing sessions do not carry over).
5. CI: the `session` ecosystem-tests entry no longer builds `lyric-cache`,
   restores, or selects a feature (`scripts/ci/session-tests.sh`), the JVM suite
   runner no longer treats `session` as a Maven-restoring library, and the
   `ECO_DEPS` entry is empty. `lyric-testing` and `lyric-conformance` keep their
   dependency on `Lyric.Session` unchanged.

## Consequences

- Breaking for an application that called `Session.connectRedis()` or named
  `Session.NativeSessionStore`: it moves to `Lyric.Session.Redis`
  (`connect(url, options(prefix, ttl))`). Sessions already in Redis are not read
  by the new store (different key layout and id format) and every user signs in
  once. `lyric-session` is not consumed in-tree by any other library or
  example (`lyric-testing`'s `MockSessionStore` and `lyric-conformance`'s
  `Testing.Conformance.Session` use only the interface).
- `Lyric.Session.Redis` reads no environment variable; an application that keeps
  the `LYRIC_CONFIG_SESSION_SESSION_TTLSECONDS` lifetime passes
  `sessionConfigFromEnv().ttlSeconds` to `options`.
