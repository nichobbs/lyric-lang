// Mq.Kernel.Net — .NET extern boundary for message broker drivers.
//
// Bridges Lyric's Mq package to .NET message broker client libraries.
// Each broker is guarded by a feature flag; at least one must be active:
//
//   rabbitmq        — RabbitMQ.Client AMQP 0-9-1 client
//   azureservicebus — Azure.Messaging.ServiceBus client
//   sqs             — AWSSDK.SQS Amazon SQS client
//   kafka           — Confluent.Kafka producer/consumer client
//
// All drivers use an integer `queueId` handle issued at connect time.
// The kernel maintains a handle table (ConcurrentDictionary) that maps
// each ID to the underlying channel/client object.
//
// Wire format for messages returned by `consume`:
//   JSON object: {"id":"...","body":"...","headers":[{"key":"...","value":"..."},...],
//                 "deliveryCount":N}
//   Empty string "" signals a timeout (no message available).
//
// Wire format for `publishBatch`:
//   JSON array of the same message objects above.
//
// Error strings contain the driver exception message and, where available,
// the broker-specific error code.
//
// Only active when compiled for .NET (feature = "dotnet" is implicit for
// Mq.Kernel.Net; individual broker externs are guarded by their own feature).
//
// See docs/14-native-stdlib-plan.md for the kernel boundary contract.

package Mq.Kernel.Net

import Std.Core

// ─── RabbitMQ (AMQP 0-9-1) ───────────────────────────────────────────────────

/// Open an AMQP connection and declare the queue.  Returns a channel handle.
@axiom("RabbitMQ.Client AMQP 0-9-1 client for .NET")
@cfg(feature = "rabbitmq")
pub func connect(url: in String, queueName: in String): Result[Int, String] = Err("")

/// Publish a single message.  `headersJson` is a JSON array of {key,value} pairs.
@axiom("RabbitMQ.Client AMQP 0-9-1 client for .NET")
@cfg(feature = "rabbitmq")
pub func publish(queueId: in Int, messageId: in String, body: in String, headersJson: in String): Result[Unit, String] = Ok(())

/// Publish a batch of messages.  `messagesJson` is a JSON array of message objects.
@axiom("RabbitMQ.Client AMQP 0-9-1 client for .NET")
@cfg(feature = "rabbitmq")
pub func publishBatch(queueId: in Int, messagesJson: in String): Result[Unit, String] = Ok(())

/// Block up to `timeoutMs` ms for the next delivery.
/// Returns the message as a JSON object, or "" on timeout.
@axiom("RabbitMQ.Client AMQP 0-9-1 client for .NET")
@cfg(feature = "rabbitmq")
pub func consume(queueId: in Int, timeoutMs: in Int): Result[String, String] = Ok("")

/// Acknowledge a delivery by its delivery tag (message ID from the broker).
@axiom("RabbitMQ.Client AMQP 0-9-1 client for .NET")
@cfg(feature = "rabbitmq")
pub func ack(queueId: in Int, deliveryTag: in String): Result[Unit, String] = Ok(())

/// Negatively acknowledge a delivery.  `requeue = true` redelivers; `false` discards.
@axiom("RabbitMQ.Client AMQP 0-9-1 client for .NET")
@cfg(feature = "rabbitmq")
pub func nack(queueId: in Int, deliveryTag: in String, requeue: in Bool): Result[Unit, String] = Ok(())

/// Close the channel and connection.
@axiom("RabbitMQ.Client AMQP 0-9-1 client for .NET")
@cfg(feature = "rabbitmq")
pub func close(queueId: in Int): Unit = ()

// ─── Azure Service Bus ────────────────────────────────────────────────────────

/// Create a ServiceBusClient and a sender+receiver for the given queue/topic.
/// Returns a session handle.
@axiom("Azure.Messaging.ServiceBus client for .NET")
@cfg(feature = "azureservicebus")
pub func connect(url: in String, queueName: in String): Result[Int, String] = Err("")

/// Send a single message to the queue/topic.
@axiom("Azure.Messaging.ServiceBus client for .NET")
@cfg(feature = "azureservicebus")
pub func publish(queueId: in Int, messageId: in String, body: in String, headersJson: in String): Result[Unit, String] = Ok(())

/// Send a batch of messages using `ServiceBusMessageBatch`.
@axiom("Azure.Messaging.ServiceBus client for .NET")
@cfg(feature = "azureservicebus")
pub func publishBatch(queueId: in Int, messagesJson: in String): Result[Unit, String] = Ok(())

/// Receive one message, blocking up to `timeoutMs` ms.
/// Returns the message as a JSON object, or "" on timeout.
@axiom("Azure.Messaging.ServiceBus client for .NET")
@cfg(feature = "azureservicebus")
pub func consume(queueId: in Int, timeoutMs: in Int): Result[String, String] = Ok("")

/// Complete (ack) a message by its lock token.
@axiom("Azure.Messaging.ServiceBus client for .NET")
@cfg(feature = "azureservicebus")
pub func ack(queueId: in Int, deliveryTag: in String): Result[Unit, String] = Ok(())

/// Abandon (nack with requeue) or dead-letter (nack without requeue) a message.
@axiom("Azure.Messaging.ServiceBus client for .NET")
@cfg(feature = "azureservicebus")
pub func nack(queueId: in Int, deliveryTag: in String, requeue: in Bool): Result[Unit, String] = Ok(())

/// Close the ServiceBusClient.
@axiom("Azure.Messaging.ServiceBus client for .NET")
@cfg(feature = "azureservicebus")
pub func close(queueId: in Int): Unit = ()

// ─── Amazon SQS ──────────────────────────────────────────────────────────────

/// Create an AmazonSQSClient and resolve the queue URL.  Returns a handle.
@axiom("AWSSDK.SQS Amazon SQS client for .NET")
@cfg(feature = "sqs")
pub func connect(url: in String, queueName: in String): Result[Int, String] = Err("")

/// Send a single SQS message.  `headersJson` is serialised into message attributes.
@axiom("AWSSDK.SQS Amazon SQS client for .NET")
@cfg(feature = "sqs")
pub func publish(queueId: in Int, messageId: in String, body: in String, headersJson: in String): Result[Unit, String] = Ok(())

/// Send a batch of up to 10 messages using `SendMessageBatch`.
@axiom("AWSSDK.SQS Amazon SQS client for .NET")
@cfg(feature = "sqs")
pub func publishBatch(queueId: in Int, messagesJson: in String): Result[Unit, String] = Ok(())

/// Receive one message, waiting up to `timeoutMs` ms (mapped to WaitTimeSeconds).
/// Returns the message as a JSON object, or "" on timeout.
@axiom("AWSSDK.SQS Amazon SQS client for .NET")
@cfg(feature = "sqs")
pub func consume(queueId: in Int, timeoutMs: in Int): Result[String, String] = Ok("")

/// Delete the message (SQS ack) using its receipt handle as `deliveryTag`.
@axiom("AWSSDK.SQS Amazon SQS client for .NET")
@cfg(feature = "sqs")
pub func ack(queueId: in Int, deliveryTag: in String): Result[Unit, String] = Ok(())

/// Change the message visibility timeout to 0 (immediate requeue) or move to DLQ.
@axiom("AWSSDK.SQS Amazon SQS client for .NET")
@cfg(feature = "sqs")
pub func nack(queueId: in Int, deliveryTag: in String, requeue: in Bool): Result[Unit, String] = Ok(())

/// Dispose the SQS client.
@axiom("AWSSDK.SQS Amazon SQS client for .NET")
@cfg(feature = "sqs")
pub func close(queueId: in Int): Unit = ()

// ─── Apache Kafka ─────────────────────────────────────────────────────────────

/// Create a Kafka producer+consumer pair for the given topic.  Returns a handle.
/// `url` is the bootstrap.servers value; `queueName` is the topic name.
@axiom("Confluent.Kafka producer and consumer client for .NET")
@cfg(feature = "kafka")
pub func connect(url: in String, queueName: in String): Result[Int, String] = Err("")

/// Produce a single message to the topic.  `headersJson` is serialised to Kafka headers.
@axiom("Confluent.Kafka producer and consumer client for .NET")
@cfg(feature = "kafka")
pub func publish(queueId: in Int, messageId: in String, body: in String, headersJson: in String): Result[Unit, String] = Ok(())

/// Produce a batch of messages.
@axiom("Confluent.Kafka producer and consumer client for .NET")
@cfg(feature = "kafka")
pub func publishBatch(queueId: in Int, messagesJson: in String): Result[Unit, String] = Ok(())

/// Poll for one message, blocking up to `timeoutMs` ms.
/// Returns the message as a JSON object, or "" on timeout.
@axiom("Confluent.Kafka producer and consumer client for .NET")
@cfg(feature = "kafka")
pub func consume(queueId: in Int, timeoutMs: in Int): Result[String, String] = Ok("")

/// Commit the offset for a consumed message (ack).  `deliveryTag` is
/// the topic-partition-offset triple serialised as "topic:partition:offset".
@axiom("Confluent.Kafka producer and consumer client for .NET")
@cfg(feature = "kafka")
pub func ack(queueId: in Int, deliveryTag: in String): Result[Unit, String] = Ok(())

/// Seek back to the message offset for reprocessing (requeue = true) or
/// skip to the next offset (requeue = false / dead-letter).
@axiom("Confluent.Kafka producer and consumer client for .NET")
@cfg(feature = "kafka")
pub func nack(queueId: in Int, deliveryTag: in String, requeue: in Bool): Result[Unit, String] = Ok(())

/// Close the producer and consumer.
@axiom("Confluent.Kafka producer and consumer client for .NET")
@cfg(feature = "kafka")
pub func close(queueId: in Int): Unit = ()
