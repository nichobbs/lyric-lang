/// Lambda.Events — typed event records for non-HTTP Lambda triggers.
///
/// Covers the most common AWS event sources that deliver batches of records
/// to a Lambda invocation:
///
///   SqsEvent         — Simple Queue Service: batch of SqsRecord
///   SqsBatchResponse — partial-batch-failure response for SQS handlers
///   SnsEvent         — Simple Notification Service: batch of SnsRecord
///   S3Event          — S3 object create / delete: batch of S3Record
///   EventBridgeEvent — EventBridge (CloudWatch Events): single event envelope
///   DynamoDbEvent    — DynamoDB Streams: batch of DynamoDbRecord
///
/// Each type faithfully models the JSON payload shape that AWS delivers to
/// the Lambda handler.  The kernel deserialises the raw invocation JSON into
/// the appropriate type before calling the registered handler.
///
/// Handler registration (in main() or a setup function):
///   Lambda.serve(
///     Lambda.newApp()
///       |> Lambda.onSqs("MyApp.Queue.handleBatch")
///       |> Lambda.onS3("MyApp.Storage.handleObjectEvent"))

@runtime_checked
package Lambda.Events

import Std.Core

// ─── SQS ─────────────────────────────────────────────────────────────────────

/// A typed SQS message attribute.
/// dataType is "String", "Number", "Binary", or a custom type prefixed with
/// "String.", "Number.", or "Binary.".
@stable(since="0.1")
pub record SqsMessageAttribute {
  stringValue:  Option[String]
  binaryValue:  Option[String]   // base64-encoded bytes
  dataType:     String
}

/// A single SQS message within a Lambda invocation batch.
@stable(since="0.1")
pub record SqsRecord {
  messageId:         String
  receiptHandle:     String
  body:              String
  attributes:        Map[String, String]   // system attributes (e.g. ApproximateReceiveCount)
  messageAttributes: Map[String, SqsMessageAttribute]
  md5OfBody:         String
  eventSource:       String   // "aws:sqs"
  eventSourceArn:    String
  awsRegion:         String
}

/// Batch of SQS messages delivered to a Lambda invocation.
/// The handler processes all records and returns either:
///   Result[Unit, LambdaError]           — all-or-nothing (entire batch succeeds or fails)
///   Result[SqsBatchResponse, LambdaError] — partial failure (per-message reporting)
@stable(since="0.1")
pub record SqsEvent {
  records: [SqsRecord]
}

/// Identifies a single SQS message that failed processing.
/// Populate batchItemFailures with the messageIds of failed records to
/// allow Lambda to re-enqueue only those messages on the next invocation.
/// The SQS event source mapping must have FunctionResponseTypes =
/// ["ReportBatchItemFailures"] for this to take effect.
@stable(since="0.1")
pub record SqsBatchItemFailure {
  itemIdentifier: String   // messageId of the failed SqsRecord
}

/// Return this from a SQS handler to report partial-batch failures.
/// Records not listed in batchItemFailures are considered successfully processed
/// and will not be re-delivered.
@stable(since="0.1")
pub record SqsBatchResponse {
  batchItemFailures: [SqsBatchItemFailure]
}

// ─── SNS ─────────────────────────────────────────────────────────────────────

/// A typed SNS message attribute.
@stable(since="0.1")
pub record SnsMessageAttribute {
  type:  String   // "String", "Number", "Binary"
  value: String
}

/// An SNS message payload as delivered to a Lambda subscriber.
@stable(since="0.1")
pub record SnsMessage {
  messageId:         String
  topicArn:          String
  subject:           Option[String]
  message:           String
  timestamp:         String   // ISO-8601
  signatureVersion:  String
  signature:         String
  signingCertUrl:    String
  unsubscribeUrl:    String
  messageAttributes: Map[String, SnsMessageAttribute]
}

/// A single SNS notification record within a Lambda invocation.
@stable(since="0.1")
pub record SnsRecord {
  eventSource:          String   // "aws:sns"
  eventVersion:         String
  eventSubscriptionArn: String
  sns:                  SnsMessage
}

/// Batch of SNS notifications delivered to a Lambda invocation.
/// SNS always delivers exactly one record per invocation, but the
/// event envelope is still an array for consistency with other sources.
@stable(since="0.1")
pub record SnsEvent {
  records: [SnsRecord]
}

// ─── S3 ───────────────────────────────────────────────────────────────────────

/// Source IP of the request that triggered the S3 event.
@stable(since="0.1")
pub record S3RequestParameters {
  sourceIpAddress: String
}

/// AWS request identifiers from the S3 response.
@stable(since="0.1")
pub record S3ResponseElements {
  xAmzRequestId: String
  xAmzId2:       String
}

/// The S3 bucket involved in an event.
@stable(since="0.1")
pub record S3Bucket {
  name:          String
  ownerIdentity: Map[String, String]
  arn:           String
}

/// The S3 object involved in an event.
/// key is URL-percent-encoded; decode it before use as a file path.
@stable(since="0.1")
pub record S3Object {
  key:       String   // URL-encoded; decode before use
  size:      Long
  eTag:      String
  sequencer: String
}

/// Combined bucket + object detail for an S3 event.
@stable(since="0.1")
pub record S3Detail {
  s3SchemaVersion: String
  configurationId: String
  bucket:          S3Bucket
  object:          S3Object
}

/// A single S3 object event record within a Lambda invocation.
/// eventName follows the pattern "ObjectCreated:Put", "ObjectRemoved:Delete", etc.
@stable(since="0.1")
pub record S3Record {
  eventVersion:      String
  eventSource:       String   // "aws:s3"
  awsRegion:         String
  eventTime:         String   // ISO-8601
  eventName:         String   // e.g. "ObjectCreated:Put", "ObjectRemoved:Delete"
  userIdentity:      Map[String, String]
  requestParameters: S3RequestParameters
  responseElements:  S3ResponseElements
  s3:                S3Detail
}

/// Batch of S3 object events delivered to a Lambda invocation.
@stable(since="0.1")
pub record S3Event {
  records: [S3Record]
}

// ─── EventBridge ─────────────────────────────────────────────────────────────

/// EventBridge (CloudWatch Events) event envelope.
///
/// The detail field contains the raw JSON payload for the event.
/// Deserialise it based on the source + detailType combination:
///   source="aws.ec2", detailType="EC2 Instance State-change Notification"
///   source="aws.codepipeline", detailType="CodePipeline Pipeline Execution State Change"
///   source="my.service", detailType="OrderPlaced"  (custom events)
///
/// detailType is the "detail-type" JSON field, renamed to detailType here
/// because Lyric identifiers cannot contain hyphens.
@stable(since="0.1")
pub record EventBridgeEvent {
  version:    String    // always "0"
  id:         String    // UUID
  source:     String    // e.g. "aws.ec2", "my.service"
  account:    String
  time:       String    // ISO-8601
  region:     String
  resources:  [String]  // ARNs of resources involved
  detailType: String    // the "detail-type" JSON field
  detail:     String    // raw JSON detail object; parse based on source + detailType
}

// ─── DynamoDB Streams ─────────────────────────────────────────────────────────

/// A DynamoDB attribute value.  Exactly one of the scalar fields (s, n, b,
/// bool, null) or set/list fields will be populated per attribute in practice.
/// L (List) and M (Map) are omitted — deserialise from the raw JSON detail
/// if your stream records contain nested structures.
@stable(since="0.1")
pub record DynamoDbAttributeValue {
  s:    Option[String]    // String
  n:    Option[String]    // Number (represented as decimal string)
  b:    Option[String]    // Binary (base64-encoded)
  bool: Option[Bool]      // Boolean
  null: Option[Bool]      // Null (true = null value)
  ss:   Option[[String]]  // String Set
  ns:   Option[[String]]  // Number Set (decimal strings)
  bs:   Option[[String]]  // Binary Set (base64-encoded elements)
}

/// The DynamoDB stream data for a single modified item.
@stable(since="0.1")
pub record DynamoDbStreamRecord {
  /// Unix epoch seconds; present when the stream was created with
  /// ApproximateCreationDateTime enabled.
  approximateCreationDateTime: Option[Long]
  /// Primary key attributes of the modified item.
  keys:            Map[String, DynamoDbAttributeValue]
  /// Item image after the write; present for NEW_IMAGE and NEW_AND_OLD_IMAGES stream views.
  newImage:        Option[Map[String, DynamoDbAttributeValue]]
  /// Item image before the write; present for OLD_IMAGE and NEW_AND_OLD_IMAGES stream views.
  oldImage:        Option[Map[String, DynamoDbAttributeValue]]
  sequenceNumber:  String
  sizeBytes:       Long
  /// One of: "KEYS_ONLY", "NEW_IMAGE", "OLD_IMAGE", "NEW_AND_OLD_IMAGES".
  streamViewType:  String
}

/// A single DynamoDB stream record within a Lambda invocation.
@stable(since="0.1")
pub record DynamoDbRecord {
  eventId:        String
  eventVersion:   String
  eventSource:    String   // "aws:dynamodb"
  /// "INSERT", "MODIFY", or "REMOVE".
  eventName:      String
  awsRegion:      String
  dynamodb:       DynamoDbStreamRecord
  eventSourceArn: String
}

/// Batch of DynamoDB Streams records delivered to a Lambda invocation.
@stable(since="0.1")
pub record DynamoDbEvent {
  records: [DynamoDbRecord]
}
