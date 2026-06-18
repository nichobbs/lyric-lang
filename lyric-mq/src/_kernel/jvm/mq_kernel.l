//! Mq.Kernel.Jvm — JVM extern boundary for message broker drivers.
//!
//! JVM implementation of the same contract as Mq.Kernel.Net.
//! Two broker clients are supported on JVM:
//!
//!   rabbitmq — com.rabbitmq.client.ConnectionFactory (amqp-client JAR)
//!   kafka    — org.apache.kafka.clients.producer.KafkaProducer + KafkaConsumer
//!
//! Azure Service Bus and SQS are .NET-only in the current plan; JVM bindings
//! for those brokers (e.g. via AWS SDK for Java or Azure SDK for Java) are
//! tracked in Q-MQ-001 and can be added here when the feature is requested.
//!
//! Handle table and wire format follow the same conventions as Mq.Kernel.Net:
//!   connect → Int handle
//!   consume → JSON object string (same schema) or "" for timeout
//!   ack/nack → delivery tag string
//!
//! Only active when compiled with feature = "jvm" (Phase 6).
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.
@cfg(feature = "jvm")
package Mq.Kernel.Jvm

import Std.Core

// ─── RabbitMQ (AMQP 0-9-1) ───────────────────────────────────────────────────
/// Open an AMQP connection and declare the queue.  Returns a channel handle.
@axiom("com.rabbitmq.client.ConnectionFactory AMQP 0-9-1 client for JVM")
@cfg(feature = "rabbitmq")
pub func connect(url: in String, queueName: in String): Result[Int, String] = Err("")

/// Publish a single message.  `headersJson` is a JSON array of {key,value} pairs.
@axiom("com.rabbitmq.client.ConnectionFactory AMQP 0-9-1 client for JVM")
@cfg(feature = "rabbitmq")
pub func publish(queueId: in Int, messageId: in String, body: in String, headersJson: in String): Result[Unit, String] = Ok(())

/// Publish a batch of messages.  `messagesJson` is a JSON array of message objects.
@axiom("com.rabbitmq.client.ConnectionFactory AMQP 0-9-1 client for JVM")
@cfg(feature = "rabbitmq")
pub func publishBatch(queueId: in Int, messagesJson: in String): Result[Unit, String] = Ok(())

/// Block up to `timeoutMs` ms for the next delivery.
/// Returns the message as a JSON object, or "" on timeout.
@axiom("com.rabbitmq.client.ConnectionFactory AMQP 0-9-1 client for JVM")
@cfg(feature = "rabbitmq")
pub func consume(queueId: in Int, timeoutMs: in Int): Result[String, String] = Ok("")

/// Acknowledge a delivery by its delivery tag.
@axiom("com.rabbitmq.client.ConnectionFactory AMQP 0-9-1 client for JVM")
@cfg(feature = "rabbitmq")
pub func ack(queueId: in Int, deliveryTag: in String): Result[Unit, String] = Ok(())

/// Negatively acknowledge a delivery.  `requeue = true` redelivers; `false` discards.
@axiom("com.rabbitmq.client.ConnectionFactory AMQP 0-9-1 client for JVM")
@cfg(feature = "rabbitmq")
pub func nack(queueId: in Int, deliveryTag: in String, requeue: in Bool): Result[Unit, String] = Ok(())

/// Close the channel and connection.
@axiom("com.rabbitmq.client.ConnectionFactory AMQP 0-9-1 client for JVM")
@cfg(feature = "rabbitmq")
pub func close(queueId: in Int): Unit = ()

// ─── Apache Kafka ─────────────────────────────────────────────────────────────
/// Create a KafkaProducer+KafkaConsumer pair for the given topic.
/// `url` is the bootstrap.servers value; `queueName` is the topic name.
/// Returns an opaque handle.
@axiom("org.apache.kafka.clients.producer.KafkaProducer + KafkaConsumer for JVM")
@cfg(feature = "kafka")
pub func connect(url: in String, queueName: in String): Result[Int, String] = Err("")

/// Produce a single message to the topic.  `headersJson` is serialised to Kafka headers.
@axiom("org.apache.kafka.clients.producer.KafkaProducer + KafkaConsumer for JVM")
@cfg(feature = "kafka")
pub func publish(queueId: in Int, messageId: in String, body: in String, headersJson: in String): Result[Unit, String] = Ok(())

/// Produce a batch of messages.
@axiom("org.apache.kafka.clients.producer.KafkaProducer + KafkaConsumer for JVM")
@cfg(feature = "kafka")
pub func publishBatch(queueId: in Int, messagesJson: in String): Result[Unit, String] = Ok(())

/// Poll for one message, blocking up to `timeoutMs` ms.
/// Returns the message as a JSON object, or "" on timeout.
@axiom("org.apache.kafka.clients.producer.KafkaProducer + KafkaConsumer for JVM")
@cfg(feature = "kafka")
pub func consume(queueId: in Int, timeoutMs: in Int): Result[String, String] = Ok("")

/// Commit the offset for a consumed message (ack).  `deliveryTag` is the
/// topic-partition-offset triple serialised as "topic:partition:offset".
@axiom("org.apache.kafka.clients.producer.KafkaProducer + KafkaConsumer for JVM")
@cfg(feature = "kafka")
pub func ack(queueId: in Int, deliveryTag: in String): Result[Unit, String] = Ok(())

/// Seek back to the message offset (requeue = true) or skip (requeue = false).
@axiom("org.apache.kafka.clients.producer.KafkaProducer + KafkaConsumer for JVM")
@cfg(feature = "kafka")
pub func nack(queueId: in Int, deliveryTag: in String, requeue: in Bool): Result[Unit, String] = Ok(())

/// Close the producer and consumer.
@axiom("org.apache.kafka.clients.producer.KafkaProducer + KafkaConsumer for JVM")
@cfg(feature = "kafka")
pub func close(queueId: in Int): Unit = ()
