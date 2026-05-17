# lyric-mq

Transport-agnostic message queue with pluggable broker backends.

## Packages

| Package | Purpose |
|---|---|
| `Mq` | Core types, `MessageQueue`/`QueueConsumer` interfaces, and public API |
| `Mq.Aspects` | Reusable aspect templates: `Idempotent` and `DeadLetter` |

## Quick start

```lyric
import Mq

val queue = Mq.connect("amqp://localhost", "events")

// Publish a message
Mq.publish(queue, Mq.Message {
  id: "msg-1",
  body: "hello world",
  headers: [("content-type", "text/plain")]
})

// Subscribe and consume
val consumer = Mq.subscribe(queue, "my-consumer-group")
match Mq.receive(consumer) {
  case Some(msg) -> {
    println(msg.body)
    Mq.ack(consumer, msg.id)
  }
  case None -> println("no messages")
}
```

## Supported platforms and brokers

`Lyric.Mq` is multi-platform; enable the target platform and the broker
you need in your consumer `lyric.toml`:

```toml
[features]
mq = ["dotnet", "rabbitmq"]  # platform feature plus one broker
```

Platform features:

- `dotnet` — Target the .NET kernel (`Mq.Kernel.Net`)
- `jvm` — Target the JVM kernel (`Mq.Kernel.Jvm`)

Broker features:

- `rabbitmq` — AMQP 0.9.1 via RabbitMQ
- `azureservicebus` — Azure Service Bus queues
- `sqs` — Amazon SQS
- `kafka` — Apache Kafka topics

## Core types and functions

### MessageQueue interface

```lyric
pub interface MessageQueue {
  func publish(message: in Message): Result[Unit, QueueError]
  func publishBatch(messages: in slice[Message]): Result[Unit, QueueError]
  func close(): Unit
}
```

### QueueConsumer interface

```lyric
pub interface QueueConsumer {
  func receive(): Option[Message]
  func ack(messageId: in String): Result[Unit, QueueError]
  func nack(messageId: in String, requeue: in Bool): Result[Unit, QueueError]
}
```

### Message type

```lyric
pub record Message {
  id: String
  body: String
  headers: slice[Tuple[String, String]]
  timestamp: Instant
  deliveryCount: Int
}
```

### Factory functions

```lyric
Mq.connect(brokerUrl: in String, queueName: in String)
  -> Result[MessageQueue, QueueError]

Mq.subscribe(queue: in MessageQueue, consumerGroup: in String)
  -> Result[QueueConsumer, QueueError]

Mq.publish(queue: in MessageQueue, message: in Message)
  -> Result[Unit, QueueError]

Mq.publishBatch(queue: in MessageQueue, messages: in slice[Message])
  -> Result[Unit, QueueError]

Mq.ack(consumer: in QueueConsumer, messageId: in String)
  -> Result[Unit, QueueError]

Mq.nack(consumer: in QueueConsumer, messageId: in String, requeue: in Bool)
  -> Result[Unit, QueueError]
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
