# Protected-type conversion of the session, dead-letter and flag-registry stores (#8950)

Same pattern as `Cache.InProcessCacheStore` (#8951):

- `Session.InProcessSessionStore` is a protected type; the one write path is a
  private `putSession` member. New `Session.inMemoryWithTtl(ttlSeconds)`
  carries the TTL bound as a precondition, so the "TTL out of range" test now
  exercises the factory (a protected type has no construction-time invariant
  panic to assert).
- `Mq.InProcessDeadLetterStore` is a protected type; tests construct it through
  `inProcessDeadLetterStore(maxEntries)`.
- `Flags.Registry`'s process-global store is a protected type with `entry`
  members; `checkFlag` / `getStringFlag` / `register*` keep their signatures.
- Concurrency tests on both targets: `session_concurrency_*`,
  `mq_deadletter_concurrency_*`, `flags_registry_concurrency_*`.
- The caching chapter's stale "not thread-safe" note is corrected.
