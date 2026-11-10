# Conformance suites: broker gate lifted, JVM leg tracked

Follow-up to the conformance suites in lyric-testing (the earlier entry of the same date).

- With the pure-Lyric in-process broker (`Mq.InMemory`) the broker conformance test no
  longer needs a dotnet gate, and it is lifted.
- `lyric-testing` builds and its 55 + 14 tests pass on `--target jvm` with the released
  0.7.12 compiler, but CI's compiler fails to build the package on the JVM: the
  `requires: allHaveIds(messages)` clause that `MockMessageQueue` inherits from
  `Mq.MessageQueue.publishBatch` does not resolve in the implementing package
  (`J002: unresolved call to 'allHaveIds'`). `testing` therefore stays out of
  `scripts/ci/jvm-ecosystem-suites.sh` until that is fixed; tracked in #8983.
