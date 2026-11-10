# lyric-mq: pure-Lyric in-process broker on both targets; broker declarations removed

Part of the ecosystem remediation (docs/71 phase 2, D552 items 1-2).

- New `Mq.InMemory` (`lyric-mq/src/inmemory.l`): the in-process broker as
  protected types (`BrokerQueue`, `BrokerRegistry`), pure Lyric, so publishers,
  consumers and `connect`/`close` are safe on any threads and the behaviour is
  identical on dotnet and the JVM. `consume` polls with short sleeps, never
  holding a lock while it waits. `Mq.connect()`/`connectTo()` and `NativeQueue`
  keep their signatures.
- Removed: `Mq.Kernel.Net` (ConcurrentQueue externs plus RabbitMQ, Azure
  Service Bus, SQS and Confluent.Kafka placeholders that returned "not yet
  implemented"), `Mq.Kernel.Jvm` (RabbitMQ/Kafka unbound no-ops), the
  `rabbitmq`/`azureservicebus`/`sqs`/`kafka` features, the `dotnet`/`jvm`/
  `inmemory` features (they only selected kernels; the manifest has no
  `[features]` table now), and the `[nuget]`/`[maven]` broker dependencies.
- Tests: the existing in-memory tests were dotnet-only and now run on both
  targets (20 and 10 tests); new concurrency tests per target
  (`mq_concurrency_dotnet_tests.l`, `mq_concurrency_jvm_tests.l`) check that
  four publishers and three consumers sharing a queue deliver every message
  exactly once.
- Migration: a build that passed `--features rabbitmq` (or another broker
  feature) to lyric-mq no longer needs it and must not pass it (F0050).
