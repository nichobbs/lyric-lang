/// Mq.Kernel.Jvm — JVM extern boundary for message broker drivers.
///
/// JVM implementation of the same contract as Mq.Kernel.Net.
/// Two broker clients are supported on JVM:
///
///   rabbitmq — com.rabbitmq.client.ConnectionFactory (amqp-client JAR)
///   kafka    — org.apache.kafka.clients.producer.KafkaProducer + KafkaConsumer
///
/// Azure Service Bus and SQS are .NET-only in the current plan; JVM bindings
/// for those brokers (e.g. via AWS SDK for Java or Azure SDK for Java) are
/// tracked in Q-MQ-001 and can be added here when the feature is requested.
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

// ─── Shared re-exports ────────────────────────────────────────────────────────
// Dispatch to the first active broker feature at compile time.

/// Open a broker connection.
pub func connect(url: in String, queueName: in String): Result[Int, String]
  requires: url.length > 0
  requires: queueName.length > 0
{
  @cfg(feature = "rabbitmq")
  return com.rabbitmq.client.ConnectionFactory.connect(url, queueName)
  @cfg(feature = "kafka")
  return org.apache.kafka.clients.producer.KafkaProducer.connect(url, queueName)
}

/// Publish a single message.
pub func publish(queueId: in Int, messageId: in String, body: in String, headersJson: in String): Result[Unit, String]
  requires: messageId.length > 0
{
  @cfg(feature = "rabbitmq")
  return com.rabbitmq.client.ConnectionFactory.publish(queueId, messageId, body, headersJson)
  @cfg(feature = "kafka")
  return org.apache.kafka.clients.producer.KafkaProducer.publish(queueId, messageId, body, headersJson)
}

/// Publish a batch of messages.
pub func publishBatch(queueId: in Int, messagesJson: in String): Result[Unit, String]
  requires: messagesJson.length > 0
{
  @cfg(feature = "rabbitmq")
  return com.rabbitmq.client.ConnectionFactory.publishBatch(queueId, messagesJson)
  @cfg(feature = "kafka")
  return org.apache.kafka.clients.producer.KafkaProducer.publishBatch(queueId, messagesJson)
}

/// Poll for the next message.
pub func consume(queueId: in Int, timeoutMs: in Int): Result[String, String]
  requires: timeoutMs > 0
{
  @cfg(feature = "rabbitmq")
  return com.rabbitmq.client.ConnectionFactory.consume(queueId, timeoutMs)
  @cfg(feature = "kafka")
  return org.apache.kafka.clients.producer.KafkaProducer.consume(queueId, timeoutMs)
}

/// Acknowledge a message.
pub func ack(queueId: in Int, deliveryTag: in String): Result[Unit, String]
  requires: deliveryTag.length > 0
{
  @cfg(feature = "rabbitmq")
  return com.rabbitmq.client.ConnectionFactory.ack(queueId, deliveryTag)
  @cfg(feature = "kafka")
  return org.apache.kafka.clients.producer.KafkaProducer.ack(queueId, deliveryTag)
}

/// Negatively acknowledge a message.
pub func nack(queueId: in Int, deliveryTag: in String, requeue: in Bool): Result[Unit, String]
  requires: deliveryTag.length > 0
{
  @cfg(feature = "rabbitmq")
  return com.rabbitmq.client.ConnectionFactory.nack(queueId, deliveryTag, requeue)
  @cfg(feature = "kafka")
  return org.apache.kafka.clients.producer.KafkaProducer.nack(queueId, deliveryTag, requeue)
}

/// Close the broker connection.
pub func close(queueId: in Int): Unit {
  @cfg(feature = "rabbitmq")
  com.rabbitmq.client.ConnectionFactory.close(queueId)
  @cfg(feature = "kafka")
  org.apache.kafka.clients.producer.KafkaProducer.close(queueId)
}
