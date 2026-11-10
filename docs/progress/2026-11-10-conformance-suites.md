# Conformance suites in lyric-testing, and four more mocks

Part of the ecosystem remediation (docs/71 phase 2 item 3, D552 item 1).

- `lyric-testing` now publishes `Testing.Conformance` (the harness) and one
  suite per interface: `CacheStore`, `FlagStore`, `SessionStore`,
  `MessageQueue` + `QueueConsumer`, `DeadLetterStore`, `StorageBucket`,
  `JobScheduler` and `SearchClient`. A suite takes a factory for the
  implementation, runs every case even after a failure, and
  `requireConformance` fails the calling test once with the full list.
- `lyric-testing/tests/conformance_tests.l` runs each suite against its
  in-tree backend and against the mocks that implement the same contract, plus
  negative tests (a forgetful store, a panicking store, an empty suite).
- New mocks: `MockJobScheduler`, `MockQueueConsumer`, `MockSearchClient`,
  `MockTranslationStore`. `TestContext` gains `jobs`, `search` and
  `translations`. The Db mock already existed.
- Findings while writing the suites: the `SessionStore.set` doc comment
  promised to create a missing session, but every store (correctly, #316)
  refuses; the comment is corrected and the suite pins the refusal. The local
  bucket refuses user metadata (`USER_META_UNSUPPORTED`) instead of storing it;
  the suite accepts that documented refusal.
- Not in this change: the in-memory broker test is gated to dotnet until the JVM
  reference backend lands; the JVM run of `lyric-testing` needs lyric-db to
  build on the JVM (#8932); a `Ws` mock (#8968).
