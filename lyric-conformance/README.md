# lyric-conformance

**Stability:** `stable`

The conformance suites of the library interfaces: one function per interface
that takes a factory for an implementation and checks the contract the
interface documents (D552). An in-tree backend, a mock and an out-of-tree
backend all run the same suite.

## Targets

`dotnet`, `jvm` and `native`. The package depends only on the interface
packages (`lyric-cache`, `lyric-feature-flags`, `lyric-session`, `lyric-mq`,
`lyric-storage`, `lyric-jobs`, `lyric-search`), so a backend can run its suite
on every target it supports. The mocks are in `lyric-testing`, which also
needs `lyric-db` and `lyric-mail` and is `dotnet` only; the suites were part of
that package until D604.

On native a panic cannot be caught (D-N-003): a backend that panics inside a
case ends the run with the panic's message, where `dotnet` and the JVM record
it against the case and go on. Failed expectations are collected and reported
together on every target.

`Testing.Conformance.Search` has not been run on native: there is no in-tree
`SearchClient` that works there yet.

## Packages

| Package | Purpose |
|---|---|
| `Testing.Conformance` | Harness shared by the suites (`Checks`, `runCase`, `requireConformance`) |
| `Testing.Conformance.Cache` / `.Flags` / `.Session` / `.Mq` / `.Storage` / `.Jobs` / `.Search` | One conformance suite per library interface |

## Using a suite

Declare the package and the interface it tests, then call the suite from a
test:

```toml
[dependencies]
"Lyric.Conformance" = { workspace = true }
"Lyric.Cache"       = { workspace = true }
```

```lyric
import Testing.Conformance
import Testing.Conformance.Cache as CacheConformance

test "MyRedisCacheStore conforms to CacheStore" {
  requireConformance(CacheConformance.run({ -> connectMyStore() }, { n -> sleepSeconds(n) }))
}
```

A suite never stops at the first failed expectation: every case runs, and
`requireConformance` then fails the calling test once, naming each failed
expectation.

| Suite | Interface | Factory |
|---|---|---|
| `Cache.run(factory, advanceSeconds)` | `Cache.CacheStore` | fresh store; a hook that moves the store's clock (or sleeps) |
| `Flags.run(factory)` | `Flags.FlagStore` | `(entries) -> store` seeded with the entries |
| `Session.run(factory)` | `Session.SessionStore` | fresh store |
| `Mq.runQueue(factory)` | `Mq.MessageQueue` + `Mq.QueueConsumer` | fresh queue as `QueueEnds` |
| `Mq.runDeadLetterStore(factory)` | `Mq.DeadLetterStore` | `(maxEntries) -> store` |
| `Storage.run(factory)` | `Storage.StorageBucket` | fresh, empty bucket |
| `Jobs.run(factory)` | `Jobs.JobScheduler` | fresh scheduler (submission, status, cancel, cron; handler execution is backend-specific) |
| `Search.run(factory)` (async) | `Search.SearchClient` | client over a fresh backend; `index` must make the document visible to `search` |

Where backends legitimately differ the suite accepts exactly the documented
alternatives: `presignedUrl` succeeds or answers `NOT_SUPPORTED`, and `put`
with user metadata stores it or answers `USER_META_UNSUPPORTED`. The session
suite pins the secure behaviour: `set` on an unknown session is
`SESSION_NOT_FOUND` and never creates the session.

## Tests

`tests/conformance_tests.l` runs each suite against the in-tree backend of its
interface (in-process cache, flag, session and job stores, the in-memory
broker and dead-letter store, the local filesystem bucket), and the cache
suite against a store that forgets what it is given, so a suite that cannot
fail is caught. None of these cases needs a caught panic, so the file runs on
every target:

```sh
lyric test --manifest lyric-conformance/lyric.toml                 # dotnet
lyric test --manifest lyric-conformance/lyric.toml --target jvm
```

The cases that do need one (a backend that panics, `requireConformance`
failing its caller) and the mocks' own conformance are in
`lyric-testing/tests/conformance_tests.l`.
