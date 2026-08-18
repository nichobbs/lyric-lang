# lyric-mq

Transport-agnostic message queue with pluggable broker backends.

## Platform parity

**Only the `inmemory` backend is production-ready, and only on `dotnet`.**
The public API (`Mq.connect()` / `Mq.connectTo()`, `publish`, `consume`,
`ack`, `nack`, `close`) dispatches into the in-memory kernel on `dotnet`
(wired in #6511 — before that the dispatch stubs never reached any kernel
and every `connect()` returned `Err("no broker configured")`).
`rabbitmq`, `azureservicebus`, `sqs`, and `kafka` all compile and
type-check (feature-gated `connect()` overloads exist for each), but:

- On `dotnet`, all four return `Err("... not yet implemented (Phase 5
  follow-up of #733)")` from `connect()` — declarative placeholders
  pending broker-specific Testcontainers infrastructure (#779).
- On `jvm`, `rabbitmq` and `kafka` are declared with `@axiom`-annotated
  function signatures but have **no real client binding at all** — no
  `extern type`/`extern func` declarations back them, so every call is a
  no-op returning a trivial `Ok(())`/`Err("")`. `azureservicebus` and
  `sqs` aren't declared on `jvm` at all, and there is no `inmemory`
  feature on `jvm` either — the JVM target currently has no working
  backend.

See `docs/57-stdlib-ecosystem-library-review.md` §3.

## Packages

| Package | Purpose |
|---|---|
| `Mq` | Core types, `MessageQueue`/`QueueConsumer` interfaces, and public API |
| `Mq.Aspects` | Reusable aspect templates: `Idempotent` and `DeadLetter` |

## Quick start

```lyric
import Mq

val queue = Mq.connectTo("amqp://localhost", "events")?

// Publish a message
Mq.publish(queue, Mq.Message(
  id            = "msg-1",
  body          = "hello world",
  headers       = [Mq.MessageHeader(key = "content-type", value = "text/plain")],
  deliveryCount = 0))?

// Consume one message (NativeQueue implements QueueConsumer too)
Mq.consume(queue, 5000, { msg ->
  println(msg.body)
  Ok(())
})?
Mq.ack(queue, "msg-1")?
```

## Supported platforms and brokers

`Lyric.Mq` is multi-platform; activate the target platform feature and
one broker feature when you build (per `docs/24-build-features.md`):

```sh
lyric build --features dotnet,rabbitmq
```

Platform features:

- `dotnet` — Target the .NET kernel (`Mq.Kernel.Net`)
- `jvm` — Target the JVM kernel (`Mq.Kernel.Jvm`)

Broker features (see "Platform parity" above — only `inmemory` is real today):

- `inmemory` — In-process queue (`dotnet` only); the only backend with a
  working implementation
- `rabbitmq` — AMQP 0.9.1 via RabbitMQ (`NOT_IMPLEMENTED` on `dotnet`;
  declared-but-unbound on `jvm`)
- `azureservicebus` — Azure Service Bus queues (`NOT_IMPLEMENTED` on
  `dotnet`; not declared on `jvm`)
- `sqs` — Amazon SQS (`NOT_IMPLEMENTED` on `dotnet`; not declared on `jvm`)
- `kafka` — Apache Kafka topics (`NOT_IMPLEMENTED` on `dotnet`;
  declared-but-unbound on `jvm`)

## Core types and functions

### MessageQueue interface

```lyric
pub interface MessageQueue {
  func publish(message: in Message): Result[Unit, String]
  func publishBatch(messages: in slice[Message]): Result[Unit, String]
  func close(): Unit
}
```

### QueueConsumer interface

```lyric
pub interface QueueConsumer {
  func consume(timeoutMs: in Int, handler: (Message) -> Result[Unit, String]): Result[Unit, String]
  func ack(messageId: in String): Result[Unit, String]
  func nack(messageId: in String, requeue: in Bool): Result[Unit, String]
  func close(): Unit
}
```

### Message type

```lyric
pub record Message {
  id: String
  body: String
  headers: slice[MessageHeader]
  deliveryCount: Int
}
```

### Factory functions

```lyric
Mq.connect()                      // URL/queue from LYRIC_CONFIG_MQ_CONNECTION_*
  -> Result[NativeQueue, String]

Mq.connectTo(url: in String, queueName: in String)
  -> Result[NativeQueue, String]

Mq.publish(queue: in MessageQueue, message: in Message)
  -> Result[Unit, String]

Mq.publishBatch(queue: in MessageQueue, messages: in slice[Message])
  -> Result[Unit, String]

Mq.ack(consumer: in QueueConsumer, messageId: in String)
  -> Result[Unit, String]

Mq.nack(consumer: in QueueConsumer, messageId: in String, requeue: in Bool)
  -> Result[Unit, String]
```

## Runtime configuration

`Mq.connect()` reads broker-specific config from environment variables:

| Env var | Meaning |
|---|---|
| `LYRIC_CONFIG_MQ_CONNECTION_URL` | Broker connection string |
| `LYRIC_CONFIG_MQ_CONNECTION_QUEUENAME` | Queue or topic name |
| `LYRIC_CONFIG_MQ_CONNECTION_ACKMODE` | `auto` or `manual` (default: `manual`) |
| `LYRIC_CONFIG_MQ_CONNECTION_MAXDELIVERYCOUNT` | Max redeliveries before DLQ (default: `3`) |
| `LYRIC_CONFIG_MQ_CONNECTION_VISIBILITYTIMEOUTMS` | Message visibility window in ms (SQS only) |

## Aspect templates (`Mq.Aspects`)

### Idempotent

Deduplicates messages by tracking consumed `messageId` values in a cache.
Matches `MessageQueue` implementations and caches the `id` field.

```lyric
import Mq.Aspects

aspect IdempotentPublish from Mq.Aspects.Idempotent {
  matches: name like "*Publish"
  config { ttlSeconds: Int = 3600; dedupePrefix: String = "mq:dedup:" }
}
```

Config fields (env prefix `LYRIC_ASPECT_<INSTANTIATION>_`):

| Field | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | `Bool` | `true` | Master switch |
| `ttlSeconds` | `Int` | `3600` | Dedup cache TTL in seconds |
| `dedupePrefix` | `String` | `"mq:dedup:"` | Key prefix for dedup entries |

### DeadLetter

Routes messages exceeding `maxDeliveryCount` to a dead-letter queue after `nack()`.

```lyric
import Mq.Aspects

aspect HandleDeadLetters from Mq.Aspects.DeadLetter {
  matches: name like "*Consumer"
  config { maxDeliveryCount: Int = 3; dlqName: String = "dead-letters" }
}
```

Config fields (env prefix `LYRIC_ASPECT_<INSTANTIATION>_`):

| Field | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | `Bool` | `true` | Master switch |
| `maxDeliveryCount` | `Int` | `3` | Redelivery threshold |
| `dlqName` | `String` | `"dead-letters"` | Dead-letter queue name |

## Decision log

See `docs/03-decision-log.md` D056.
