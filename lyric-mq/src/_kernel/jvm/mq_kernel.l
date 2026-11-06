//! Mq.Kernel.Jvm — JVM extern boundary for message broker drivers.
//!
//! JVM broker drivers (RabbitMQ / Kafka) are not yet implemented. Rather than
//! returning silent `Ok(())` no-ops on `publish`/`consume`/`ack`/`nack` or an
//! empty `Err("")` on `connect`, every operation returns an explicit
//! `NOT_SUPPORTED_ON_TARGET` error.

@cfg(feature = "jvm")
@io
package Mq.Kernel.Jvm

import Std.Core

val RABBITMQ_NOT_SUPPORTED: String =
  "NOT_SUPPORTED_ON_TARGET: lyric-mq RabbitMQ JVM kernel is not yet implemented"
val KAFKA_NOT_SUPPORTED: String =
  "NOT_SUPPORTED_ON_TARGET: lyric-mq Kafka JVM kernel is not yet implemented"

// ─── RabbitMQ (AMQP 0-9-1) ───────────────────────────────────────────────────
@cfg(feature = "rabbitmq")
pub func connect(url: in String, queueName: in String): Result[Int, String] = Err(RABBITMQ_NOT_SUPPORTED)

@cfg(feature = "rabbitmq")
pub func publish(queueId: in Int, messageId: in String, body: in String, headersJson: in String): Result[Unit, String] =
  Err(RABBITMQ_NOT_SUPPORTED)

@cfg(feature = "rabbitmq")
pub func publishBatch(queueId: in Int, messagesJson: in String): Result[Unit, String] =
  Err(RABBITMQ_NOT_SUPPORTED)

@cfg(feature = "rabbitmq")
pub func consume(queueId: in Int, timeoutMs: in Int): Result[String, String] =
  Err(RABBITMQ_NOT_SUPPORTED)

@cfg(feature = "rabbitmq")
pub func ack(queueId: in Int, deliveryTag: in String): Result[Unit, String] =
  Err(RABBITMQ_NOT_SUPPORTED)

@cfg(feature = "rabbitmq")
pub func nack(queueId: in Int, deliveryTag: in String, requeue: in Bool): Result[Unit, String] =
  Err(RABBITMQ_NOT_SUPPORTED)

@cfg(feature = "rabbitmq")
pub func close(queueId: in Int): Unit = ()

// ─── Apache Kafka ─────────────────────────────────────────────────────────────
@cfg(feature = "kafka")
pub func connect(url: in String, queueName: in String): Result[Int, String] = Err(KAFKA_NOT_SUPPORTED)

@cfg(feature = "kafka")
pub func publish(queueId: in Int, messageId: in String, body: in String, headersJson: in String): Result[Unit, String] =
  Err(KAFKA_NOT_SUPPORTED)

@cfg(feature = "kafka")
pub func publishBatch(queueId: in Int, messagesJson: in String): Result[Unit, String] =
  Err(KAFKA_NOT_SUPPORTED)

@cfg(feature = "kafka")
pub func consume(queueId: in Int, timeoutMs: in Int): Result[String, String] =
  Err(KAFKA_NOT_SUPPORTED)

@cfg(feature = "kafka")
pub func ack(queueId: in Int, deliveryTag: in String): Result[Unit, String] =
  Err(KAFKA_NOT_SUPPORTED)

@cfg(feature = "kafka")
pub func nack(queueId: in Int, deliveryTag: in String, requeue: in Bool): Result[Unit, String] =
  Err(KAFKA_NOT_SUPPORTED)

@cfg(feature = "kafka")
pub func close(queueId: in Int): Unit = ()
