# 2026-11-13 - lyric-ecosystem: TLS for the TCP clients and seven more packages (docs/71 phase 4)

Follows `2026-11-12-ecosystem-first-backends.md`. All on nichobbs/lyric-ecosystem#3.

**TLS.** `Lyric.Redis` (`rediss://`), `Lyric.Mq.ActiveMq` (`stomp+ssl://`) and `Lyric.Mq.RabbitMq` (`amqps://`) connect over TLS on dotnet and the JVM: system trust store and hostname verification by default, a custom CA, a client identity for mutual TLS, a minimum version, and `withInsecureSkipVerify` under `Std.Http`'s two-key rule. Certificates are PEM text because `Std.Tls` values cannot leave the stdlib (#9064). Each package carries its own socket kernel (`TcpClient` + `SslStream`, `java.net.Socket` + `SSLSocket`), since `Std.TcpHost` has no JVM kernel and no client TLS upgrade (#9042, #9064).

**New packages**, each running its interface's `Testing.Conformance` suite on the targets it claims:

| Package | Interface | Targets | Verified against |
|---|---|---|---|
| `Lyric.Storage.AzureBlob` | `Storage.StorageBucket` | dotnet, jvm | Azurite 3.35.0 |
| `Lyric.Storage.Gcs` | `Storage.StorageBucket` | dotnet, jvm | hermetic endpoint, and Google itself without credentials (signature echo, anonymous reads); no authenticated run yet |
| `Lyric.Jobs.QuartzNet` | `Jobs.JobScheduler` | dotnet | Quartz.NET 3.22.10 in process |
| `Lyric.Mq.RabbitMq` | `Mq.MessageQueue`, `Mq.QueueConsumer` | dotnet, jvm | RabbitMQ 3.12.1 and 4.0.5 |
| `Lyric.Mq.Sqs` | `Mq.MessageQueue`, `Mq.QueueConsumer` | dotnet, jvm | ElasticMQ 1.6.11; not Amazon SQS |
| `Lyric.Flags.Flipt` | `Flags.FlagStore` | dotnet, jvm | Flipt 1.62.0 |
| `Lyric.Aws.SigV4` | shared signing | dotnet, jvm | AWS documentation vectors |

**Fixes found by audits and CI.** `jobs-quartz`: a finite job always reaches a terminal status however its triggers end (a `SchedulerListener` and per-job live-trigger tracking), and cancel during a retry delay never runs the handler again. `mq-activemq`: settlement forgotten before the broker confirmed it, oversize frames poisoning the connection, uncorrelated ERROR frames, an unbounded `consume` and unbounded writes; its dotnet kernel read on the shared thread pool, so a busy pool delayed data that had already arrived. `mq-rabbitmq`: headers travel as one ordered entry, because RabbitMQ 4 keeps application headers as a map. `mq-sqs`: a timeout is always `TIMEOUT` (#9067).

**READMEs.** Every package README has a compile-checked usage example, configuration tables, a Surprises section, tests, pinned versions and known gaps.

**Issues filed in this round:** #9063 (JVM: constructing a re-exported record through an alias), #9064 (no stdlib TLS client for raw TCP; `internal` not enforced across projects), #9067 (`Std.Http` timeouts indistinguishable from connection failures), #9068 (MSIL FFI gaps found binding Quartz.NET), #9069 (dotnet enum by package order; JVM unqualified cross-package `impl`).

The book's chapter 29 matrix lists the new packages and TLS.
