# Conformance suites run on the JVM

Follow-up to the conformance suites in lyric-testing (the earlier entry of the same date).

- With lyric-db building on the JVM (#8932) and the pure-Lyric in-process broker
  (`Mq.InMemory`), `lyric-testing` builds and passes on `--target jvm`: its 55
  existing tests and the 14 conformance tests, against the in-process cache,
  flag, session, job and dead-letter stores, the in-memory broker, the local
  filesystem bucket and the mocks.
- The dotnet gate on the broker conformance test is gone.
- `testing` joins `scripts/ci/jvm-ecosystem-suites.sh` (Maven-restored for Jakarta
  Mail and the JDBC drivers), so the JVM leg runs in CI.
