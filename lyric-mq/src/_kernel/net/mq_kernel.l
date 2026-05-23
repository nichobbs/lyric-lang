/// Mq.Kernel.Net — .NET extern boundary for message broker drivers.
///
/// Phase 5 of #733: in-memory queue backend functional via
/// `Lyric.Mq.InMemoryHost`.  The four broker drivers (RabbitMQ, Azure
/// Service Bus, AWSSDK.SQS, Confluent.Kafka) remain declarative-only —
/// their bindings are routed to placeholder `*NotYet` targets that
/// return a clear "not yet implemented" error until broker-specific
/// Testcontainers infrastructure lands (#779 follow-up).
///
/// All drivers use an integer `queueId` handle issued at connect time.
/// The in-memory backend maintains a per-process `ConcurrentDictionary`
/// of queues with separate Pending (FIFO) and InFlight (ack-tracking)
/// state, mirroring RabbitMQ's basic.nack(requeue) semantics.
///
/// `publishBatch` has been removed from the kernel boundary (#1022):
/// it required the F# host to parse a JSON array, violating the
/// typed-parameters contract.  The public `Mq.publishBatch` wrapper
/// now loops over `publish` at the Lyric level.
///
/// Wire format for messages returned by `consume`:
///   JSON object: {"id":"...","body":"...","headers":[],"deliveryCount":N}
///   Empty string "" signals a timeout (no message available).
///
/// See docs/14-native-stdlib-plan.md for the kernel boundary contract.

package Mq.Kernel.Net

import Std.Core

// ─── In-memory backend (Phase 5 functional path) ─────────────────────────────
//
// Active when `feature = "inmemory"` is enabled or when no feature is
// explicitly set.  Broker drivers below shadow with their own externs
// gated by the relevant feature.

@axiom("Lyric.Mq.InMemoryHost.connect — registers a fresh ConcurrentQueue + ConcurrentDictionary pair per queueName")
@externTarget("Lyric.Mq.InMemoryHost.connect")
@cfg(feature = "inmemory")
pub func connect(url: in String, queueName: in String): Result[Int, String]
  requires: url.length >= 0
  requires: queueName.length > 0
  = ()

@axiom("Lyric.Mq.InMemoryHost.publish — enqueues a single message into the queue's Pending FIFO")
@externTarget("Lyric.Mq.InMemoryHost.publish")
@cfg(feature = "inmemory")
pub func publish(queueId: in Int, messageId: in String, body: in String, headersJson: in String): Result[Unit, String]
  requires: messageId.length > 0
  = ()

@axiom("Lyric.Mq.InMemoryHost.consume — blocking poll on the Pending queue; returns '' on timeout")
@externTarget("Lyric.Mq.InMemoryHost.consume")
@cfg(feature = "inmemory")
pub func consume(queueId: in Int, timeoutMs: in Int): Result[String, String]
  requires: timeoutMs > 0
  = ()

@axiom("Lyric.Mq.InMemoryHost.ack — removes from the InFlight set (idempotent)")
@externTarget("Lyric.Mq.InMemoryHost.ack")
@cfg(feature = "inmemory")
pub func ack(queueId: in Int, deliveryTag: in String): Result[Unit, String]
  requires: deliveryTag.length > 0
  = ()

@axiom("Lyric.Mq.InMemoryHost.nack — re-enqueues if requeue=true, drops otherwise")
@externTarget("Lyric.Mq.InMemoryHost.nack")
@cfg(feature = "inmemory")
pub func nack(queueId: in Int, deliveryTag: in String, requeue: in Bool): Result[Unit, String]
  requires: deliveryTag.length > 0
  = ()

@axiom("Lyric.Mq.InMemoryHost.close — drops all in-flight + pending state for the queue")
@externTarget("Lyric.Mq.InMemoryHost.close")
@cfg(feature = "inmemory")
pub func close(queueId: in Int): Unit = ()

// ─── Broker driver placeholders (#733 follow-ups) ────────────────────────────

@axiom("RabbitMQ backend not yet implemented (#733 follow-up)")
@externTarget("Lyric.Mq.InMemoryHost.rabbitmqConnectNotYet")
@cfg(feature = "rabbitmq")
pub func connect(url: in String, queueName: in String): Result[Int, String]
  requires: url.length > 0
  requires: queueName.length > 0
  = ()

@axiom("Azure Service Bus backend not yet implemented (#733 follow-up)")
@externTarget("Lyric.Mq.InMemoryHost.azureServiceBusConnectNotYet")
@cfg(feature = "azureservicebus")
pub func connect(url: in String, queueName: in String): Result[Int, String]
  requires: url.length > 0
  requires: queueName.length > 0
  = ()

@axiom("AWSSDK.SQS backend not yet implemented (#733 follow-up)")
@externTarget("Lyric.Mq.InMemoryHost.sqsConnectNotYet")
@cfg(feature = "sqs")
pub func connect(url: in String, queueName: in String): Result[Int, String]
  requires: url.length > 0
  requires: queueName.length > 0
  = ()

@axiom("Confluent.Kafka backend not yet implemented (#733 follow-up)")
@externTarget("Lyric.Mq.InMemoryHost.kafkaConnectNotYet")
@cfg(feature = "kafka")
pub func connect(url: in String, queueName: in String): Result[Int, String]
  requires: url.length > 0
  requires: queueName.length > 0
  = ()
