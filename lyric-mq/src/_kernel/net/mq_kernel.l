/// Mq.Kernel.Net — .NET extern boundary for message broker drivers.
///
/// Bridges Lyric's Mq package to .NET message broker client libraries.
/// Each broker is guarded by a feature flag; at least one must be active:
///
///   rabbitmq        — RabbitMQ.Client AMQP 0-9-1 client
///   azureservicebus — Azure.Messaging.ServiceBus client
///   sqs             — AWSSDK.SQS Amazon SQS client
///   kafka           — Confluent.Kafka producer/consumer client
///
/// All drivers use an integer `queueId` handle issued at connect time.
/// The kernel maintains a handle table (ConcurrentDictionary) that maps
/// each ID to the underlying channel/client object.
///
/// Wire format for messages returned by `consume`:
///   JSON object: {"id":"...","body":"...","headers":[{"key":"...","value":"..."},...],
///                 "deliveryCount":N}
///   Empty string "" signals a timeout (no message available).
///
/// Wire format for `publishBatch`:
///   JSON array of the same message objects above.
///
/// Error strings contain the driver exception message and, where available,
/// the broker-specific error code.
///
/// Only active when compiled for .NET (feature = "dotnet" is implicit for
/// Mq.Kernel.Net; individual broker externs are guarded by their own feature).
///
/// See docs/14-native-stdlib-plan.md for the kernel boundary contract.

package Mq.Kernel.Net

import Std.Core

// ─── RabbitMQ (AMQP 0-9-1) ───────────────────────────────────────────────────

@axiom("RabbitMQ.Client AMQP 0-9-1 client for .NET")
@cfg(feature = "rabbitmq")
extern package RabbitMQ.Client {
  /// Open an AMQP connection and declare the queue.  Returns a channel handle.
  pub func connect(url: String, queueName: String): Result[Int, String]
    requires: url.length > 0
    requires: queueName.length > 0

  /// Publish a single message.  `headersJson` is a JSON array of {key,value} pairs.
  pub func publish(queueId: Int, messageId: String, body: String, headersJson: String): Result[Unit, String]
    requires: messageId.length > 0

  /// Publish a batch of messages.  `messagesJson` is a JSON array of message objects.
  pub func publishBatch(queueId: Int, messagesJson: String): Result[Unit, String]
    requires: messagesJson.length > 0

  /// Block up to `timeoutMs` ms for the next delivery.
  /// Returns the message as a JSON object, or "" on timeout.
  pub func consume(queueId: Int, timeoutMs: Int): Result[String, String]
    requires: timeoutMs > 0

  /// Acknowledge a delivery by its delivery tag (message ID from the broker).
  pub func ack(queueId: Int, deliveryTag: String): Result[Unit, String]
    requires: deliveryTag.length > 0

  /// Negatively acknowledge a delivery.  `requeue = true` redelivers; `false` discards.
  pub func nack(queueId: Int, deliveryTag: String, requeue: Bool): Result[Unit, String]
    requires: deliveryTag.length > 0

  /// Close the channel and connection.
  pub func close(queueId: Int): Unit
}

// ─── Azure Service Bus ────────────────────────────────────────────────────────

@axiom("Azure.Messaging.ServiceBus client for .NET")
@cfg(feature = "azureservicebus")
extern package Azure.Messaging.ServiceBus {
  /// Create a ServiceBusClient and a sender+receiver for the given queue/topic.
  /// Returns a session handle.
  pub func connect(url: String, queueName: String): Result[Int, String]
    requires: url.length > 0
    requires: queueName.length > 0

  /// Send a single message to the queue/topic.
  pub func publish(queueId: Int, messageId: String, body: String, headersJson: String): Result[Unit, String]
    requires: messageId.length > 0

  /// Send a batch of messages using `ServiceBusMessageBatch`.
  pub func publishBatch(queueId: Int, messagesJson: String): Result[Unit, String]
    requires: messagesJson.length > 0

  /// Receive one message, blocking up to `timeoutMs` ms.
  /// Returns the message as a JSON object, or "" on timeout.
  pub func consume(queueId: Int, timeoutMs: Int): Result[String, String]
    requires: timeoutMs > 0

  /// Complete (ack) a message by its lock token.
  pub func ack(queueId: Int, deliveryTag: String): Result[Unit, String]
    requires: deliveryTag.length > 0

  /// Abandon (nack with requeue) or dead-letter (nack without requeue) a message.
  pub func nack(queueId: Int, deliveryTag: String, requeue: Bool): Result[Unit, String]
    requires: deliveryTag.length > 0

  /// Close the ServiceBusClient.
  pub func close(queueId: Int): Unit
}

// ─── Amazon SQS ──────────────────────────────────────────────────────────────

@axiom("AWSSDK.SQS Amazon SQS client for .NET")
@cfg(feature = "sqs")
extern package AWSSDK.SQS {
  /// Create an AmazonSQSClient and resolve the queue URL.  Returns a handle.
  pub func connect(url: String, queueName: String): Result[Int, String]
    requires: url.length > 0
    requires: queueName.length > 0

  /// Send a single SQS message.  `headersJson` is serialised into message attributes.
  pub func publish(queueId: Int, messageId: String, body: String, headersJson: String): Result[Unit, String]
    requires: messageId.length > 0

  /// Send a batch of up to 10 messages using `SendMessageBatch`.
  pub func publishBatch(queueId: Int, messagesJson: String): Result[Unit, String]
    requires: messagesJson.length > 0

  /// Receive one message, waiting up to `timeoutMs` ms (mapped to WaitTimeSeconds).
  /// Returns the message as a JSON object, or "" on timeout.
  pub func consume(queueId: Int, timeoutMs: Int): Result[String, String]
    requires: timeoutMs > 0

  /// Delete the message (SQS ack) using its receipt handle as `deliveryTag`.
  pub func ack(queueId: Int, deliveryTag: String): Result[Unit, String]
    requires: deliveryTag.length > 0

  /// Change the message visibility timeout to 0 (immediate requeue) or move to DLQ.
  pub func nack(queueId: Int, deliveryTag: String, requeue: Bool): Result[Unit, String]
    requires: deliveryTag.length > 0

  /// Dispose the SQS client.
  pub func close(queueId: Int): Unit
}

// ─── Apache Kafka ─────────────────────────────────────────────────────────────

@axiom("Confluent.Kafka producer and consumer client for .NET")
@cfg(feature = "kafka")
extern package Confluent.Kafka {
  /// Create a Kafka producer+consumer pair for the given topic.  Returns a handle.
  /// `url` is the bootstrap.servers value; `queueName` is the topic name.
  pub func connect(url: String, queueName: String): Result[Int, String]
    requires: url.length > 0
    requires: queueName.length > 0

  /// Produce a single message to the topic.  `headersJson` is serialised to Kafka headers.
  pub func publish(queueId: Int, messageId: String, body: String, headersJson: String): Result[Unit, String]
    requires: messageId.length > 0

  /// Produce a batch of messages.
  pub func publishBatch(queueId: Int, messagesJson: String): Result[Unit, String]
    requires: messagesJson.length > 0

  /// Poll for one message, blocking up to `timeoutMs` ms.
  /// Returns the message as a JSON object, or "" on timeout.
  pub func consume(queueId: Int, timeoutMs: Int): Result[String, String]
    requires: timeoutMs > 0

  /// Commit the offset for a consumed message (ack).  `deliveryTag` is
  /// the topic-partition-offset triple serialised as "topic:partition:offset".
  pub func ack(queueId: Int, deliveryTag: String): Result[Unit, String]
    requires: deliveryTag.length > 0

  /// Seek back to the message offset for reprocessing (requeue = true) or
  /// skip to the next offset (requeue = false / dead-letter).
  pub func nack(queueId: Int, deliveryTag: String, requeue: Bool): Result[Unit, String]
    requires: deliveryTag.length > 0

  /// Close the producer and consumer.
  pub func close(queueId: Int): Unit
}

// ─── Shared re-exports ────────────────────────────────────────────────────────
// These functions dispatch to the first active broker feature at compile time.
// Only one feature should be active per compilation unit; the compiler selects
// the first matching @cfg block.

/// Open a broker connection.
pub func connect(url: in String, queueName: in String): Result[Int, String]
  requires: url.length > 0
  requires: queueName.length > 0
{
  @cfg(feature = "rabbitmq")
  return RabbitMQ.Client.connect(url, queueName)
  @cfg(feature = "azureservicebus")
  return Azure.Messaging.ServiceBus.connect(url, queueName)
  @cfg(feature = "sqs")
  return AWSSDK.SQS.connect(url, queueName)
  @cfg(feature = "kafka")
  return Confluent.Kafka.connect(url, queueName)
}

/// Publish a single message.
pub func publish(queueId: in Int, messageId: in String, body: in String, headersJson: in String): Result[Unit, String]
  requires: messageId.length > 0
{
  @cfg(feature = "rabbitmq")
  return RabbitMQ.Client.publish(queueId, messageId, body, headersJson)
  @cfg(feature = "azureservicebus")
  return Azure.Messaging.ServiceBus.publish(queueId, messageId, body, headersJson)
  @cfg(feature = "sqs")
  return AWSSDK.SQS.publish(queueId, messageId, body, headersJson)
  @cfg(feature = "kafka")
  return Confluent.Kafka.publish(queueId, messageId, body, headersJson)
}

/// Publish a batch of messages.
pub func publishBatch(queueId: in Int, messagesJson: in String): Result[Unit, String]
  requires: messagesJson.length > 0
{
  @cfg(feature = "rabbitmq")
  return RabbitMQ.Client.publishBatch(queueId, messagesJson)
  @cfg(feature = "azureservicebus")
  return Azure.Messaging.ServiceBus.publishBatch(queueId, messagesJson)
  @cfg(feature = "sqs")
  return AWSSDK.SQS.publishBatch(queueId, messagesJson)
  @cfg(feature = "kafka")
  return Confluent.Kafka.publishBatch(queueId, messagesJson)
}

/// Poll for the next message.
pub func consume(queueId: in Int, timeoutMs: in Int): Result[String, String]
  requires: timeoutMs > 0
{
  @cfg(feature = "rabbitmq")
  return RabbitMQ.Client.consume(queueId, timeoutMs)
  @cfg(feature = "azureservicebus")
  return Azure.Messaging.ServiceBus.consume(queueId, timeoutMs)
  @cfg(feature = "sqs")
  return AWSSDK.SQS.consume(queueId, timeoutMs)
  @cfg(feature = "kafka")
  return Confluent.Kafka.consume(queueId, timeoutMs)
}

/// Acknowledge a message.
pub func ack(queueId: in Int, deliveryTag: in String): Result[Unit, String]
  requires: deliveryTag.length > 0
{
  @cfg(feature = "rabbitmq")
  return RabbitMQ.Client.ack(queueId, deliveryTag)
  @cfg(feature = "azureservicebus")
  return Azure.Messaging.ServiceBus.ack(queueId, deliveryTag)
  @cfg(feature = "sqs")
  return AWSSDK.SQS.ack(queueId, deliveryTag)
  @cfg(feature = "kafka")
  return Confluent.Kafka.ack(queueId, deliveryTag)
}

/// Negatively acknowledge a message.
pub func nack(queueId: in Int, deliveryTag: in String, requeue: in Bool): Result[Unit, String]
  requires: deliveryTag.length > 0
{
  @cfg(feature = "rabbitmq")
  return RabbitMQ.Client.nack(queueId, deliveryTag, requeue)
  @cfg(feature = "azureservicebus")
  return Azure.Messaging.ServiceBus.nack(queueId, deliveryTag, requeue)
  @cfg(feature = "sqs")
  return AWSSDK.SQS.nack(queueId, deliveryTag, requeue)
  @cfg(feature = "kafka")
  return Confluent.Kafka.nack(queueId, deliveryTag, requeue)
}

/// Close the broker connection.
pub func close(queueId: in Int): Unit {
  @cfg(feature = "rabbitmq")
  RabbitMQ.Client.close(queueId)
  @cfg(feature = "azureservicebus")
  Azure.Messaging.ServiceBus.close(queueId)
  @cfg(feature = "sqs")
  AWSSDK.SQS.close(queueId)
  @cfg(feature = "kafka")
  Confluent.Kafka.close(queueId)
}
