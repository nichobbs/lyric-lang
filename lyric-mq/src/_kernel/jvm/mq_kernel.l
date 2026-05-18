/// Mq.Kernel.Jvm — JVM extern boundary for message broker drivers.
///
/// JVM implementation of the same contract as Mq.Kernel.Net.
/// All four broker clients are supported on JVM:
///
///   rabbitmq        — com.rabbitmq.client.ConnectionFactory (amqp-client JAR)
///   azureservicebus — com.azure.messaging.servicebus.ServiceBusClient (Azure SDK for Java)
///   sqs             — software.amazon.awssdk.services.sqs.SqsClient (AWS SDK for Java v2)
///   kafka           — org.apache.kafka.clients.producer.KafkaProducer + KafkaConsumer
///
/// Handle table and wire format follow the same conventions as Mq.Kernel.Net:
///   connect → Int handle
///   consume → JSON object string (same schema) or "" for timeout
///   ack/nack → delivery tag string
///
/// Only active when compiled with feature = "jvm" (Phase 6).
/// See docs/14-native-stdlib-plan.md for the kernel boundary contract.

@cfg(feature = "jvm")
package Mq.Kernel.Jvm

import Std.Core

// ─── RabbitMQ (AMQP 0-9-1) ───────────────────────────────────────────────────

@axiom("com.rabbitmq.client.ConnectionFactory AMQP 0-9-1 client for JVM")
@cfg(feature = "rabbitmq")
extern package com.rabbitmq.client.ConnectionFactory {
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

  /// Acknowledge a delivery by its delivery tag.
  pub func ack(queueId: Int, deliveryTag: String): Result[Unit, String]
    requires: deliveryTag.length > 0

  /// Negatively acknowledge a delivery.  `requeue = true` redelivers; `false` discards.
  pub func nack(queueId: Int, deliveryTag: String, requeue: Bool): Result[Unit, String]
    requires: deliveryTag.length > 0

  /// Close the channel and connection.
  pub func close(queueId: Int): Unit
}

// ─── Apache Kafka ─────────────────────────────────────────────────────────────

@axiom("org.apache.kafka.clients.producer.KafkaProducer + KafkaConsumer for JVM")
@cfg(feature = "kafka")
extern package org.apache.kafka.clients.producer.KafkaProducer {
  /// Create a KafkaProducer+KafkaConsumer pair for the given topic.
  /// `url` is the bootstrap.servers value; `queueName` is the topic name.
  /// Returns an opaque handle.
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

  /// Commit the offset for a consumed message (ack).  `deliveryTag` is the
  /// topic-partition-offset triple serialised as "topic:partition:offset".
  pub func ack(queueId: Int, deliveryTag: String): Result[Unit, String]
    requires: deliveryTag.length > 0

  /// Seek back to the message offset (requeue = true) or skip (requeue = false).
  pub func nack(queueId: Int, deliveryTag: String, requeue: Bool): Result[Unit, String]
    requires: deliveryTag.length > 0

  /// Close the producer and consumer.
  pub func close(queueId: Int): Unit
}

// ─── Azure Service Bus ────────────────────────────────────────────────────────

@axiom("com.azure.messaging.servicebus ServiceBusClient for JVM")
@cfg(feature = "azureservicebus")
extern package com.azure.messaging.servicebus {
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

@axiom("software.amazon.awssdk.services.sqs SqsClient for JVM")
@cfg(feature = "sqs")
extern package software.amazon.awssdk.services.sqs {
  /// Create an SqsClient and resolve the queue URL.  Returns a handle.
  pub func connect(url: String, queueName: String): Result[Int, String]
    requires: url.length > 0
    requires: queueName.length > 0

  /// Send a single SQS message.  `headersJson` is serialised into message attributes.
  pub func publish(queueId: Int, messageId: String, body: String, headersJson: String): Result[Unit, String]
    requires: messageId.length > 0

  /// Send a batch of up to 10 messages using `SendMessageBatchRequest`.
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

  /// Close the SqsClient.
  pub func close(queueId: Int): Unit
}

// ─── Shared re-exports ────────────────────────────────────────────────────────
// Dispatch to the first active broker feature at compile time.
// Only one feature should be active per compilation unit; the compiler selects
// the first matching @cfg block.

/// Open a broker connection.
pub func connect(url: in String, queueName: in String): Result[Int, String]
  requires: url.length > 0
  requires: queueName.length > 0
{
  @cfg(feature = "rabbitmq")
  return com.rabbitmq.client.ConnectionFactory.connect(url, queueName)
  @cfg(feature = "azureservicebus")
  return com.azure.messaging.servicebus.connect(url, queueName)
  @cfg(feature = "sqs")
  return software.amazon.awssdk.services.sqs.connect(url, queueName)
  @cfg(feature = "kafka")
  return org.apache.kafka.clients.producer.KafkaProducer.connect(url, queueName)
}

/// Publish a single message.
pub func publish(queueId: in Int, messageId: in String, body: in String, headersJson: in String): Result[Unit, String]
  requires: messageId.length > 0
{
  @cfg(feature = "rabbitmq")
  return com.rabbitmq.client.ConnectionFactory.publish(queueId, messageId, body, headersJson)
  @cfg(feature = "azureservicebus")
  return com.azure.messaging.servicebus.publish(queueId, messageId, body, headersJson)
  @cfg(feature = "sqs")
  return software.amazon.awssdk.services.sqs.publish(queueId, messageId, body, headersJson)
  @cfg(feature = "kafka")
  return org.apache.kafka.clients.producer.KafkaProducer.publish(queueId, messageId, body, headersJson)
}

/// Publish a batch of messages.
pub func publishBatch(queueId: in Int, messagesJson: in String): Result[Unit, String]
  requires: messagesJson.length > 0
{
  @cfg(feature = "rabbitmq")
  return com.rabbitmq.client.ConnectionFactory.publishBatch(queueId, messagesJson)
  @cfg(feature = "azureservicebus")
  return com.azure.messaging.servicebus.publishBatch(queueId, messagesJson)
  @cfg(feature = "sqs")
  return software.amazon.awssdk.services.sqs.publishBatch(queueId, messagesJson)
  @cfg(feature = "kafka")
  return org.apache.kafka.clients.producer.KafkaProducer.publishBatch(queueId, messagesJson)
}

/// Poll for the next message.
pub func consume(queueId: in Int, timeoutMs: in Int): Result[String, String]
  requires: timeoutMs > 0
{
  @cfg(feature = "rabbitmq")
  return com.rabbitmq.client.ConnectionFactory.consume(queueId, timeoutMs)
  @cfg(feature = "azureservicebus")
  return com.azure.messaging.servicebus.consume(queueId, timeoutMs)
  @cfg(feature = "sqs")
  return software.amazon.awssdk.services.sqs.consume(queueId, timeoutMs)
  @cfg(feature = "kafka")
  return org.apache.kafka.clients.producer.KafkaProducer.consume(queueId, timeoutMs)
}

/// Acknowledge a message.
pub func ack(queueId: in Int, deliveryTag: in String): Result[Unit, String]
  requires: deliveryTag.length > 0
{
  @cfg(feature = "rabbitmq")
  return com.rabbitmq.client.ConnectionFactory.ack(queueId, deliveryTag)
  @cfg(feature = "azureservicebus")
  return com.azure.messaging.servicebus.ack(queueId, deliveryTag)
  @cfg(feature = "sqs")
  return software.amazon.awssdk.services.sqs.ack(queueId, deliveryTag)
  @cfg(feature = "kafka")
  return org.apache.kafka.clients.producer.KafkaProducer.ack(queueId, deliveryTag)
}

/// Negatively acknowledge a message.
pub func nack(queueId: in Int, deliveryTag: in String, requeue: in Bool): Result[Unit, String]
  requires: deliveryTag.length > 0
{
  @cfg(feature = "rabbitmq")
  return com.rabbitmq.client.ConnectionFactory.nack(queueId, deliveryTag, requeue)
  @cfg(feature = "azureservicebus")
  return com.azure.messaging.servicebus.nack(queueId, deliveryTag, requeue)
  @cfg(feature = "sqs")
  return software.amazon.awssdk.services.sqs.nack(queueId, deliveryTag, requeue)
  @cfg(feature = "kafka")
  return org.apache.kafka.clients.producer.KafkaProducer.nack(queueId, deliveryTag, requeue)
}

/// Close the broker connection.
pub func close(queueId: in Int): Unit {
  @cfg(feature = "rabbitmq")
  com.rabbitmq.client.ConnectionFactory.close(queueId)
  @cfg(feature = "azureservicebus")
  com.azure.messaging.servicebus.close(queueId)
  @cfg(feature = "sqs")
  software.amazon.awssdk.services.sqs.close(queueId)
  @cfg(feature = "kafka")
  org.apache.kafka.clients.producer.KafkaProducer.close(queueId)
}
