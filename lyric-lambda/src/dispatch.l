//! Lambda.Dispatch — event-source detection, JSON marshalling, and the
//! transport loops for the `aws` and `local` `Lambda.Kernel.Runtime`
//! feature variants.
//!
//! Historically both `_kernel/lambda_kernel_aws.l` and
//! `_kernel/lambda_kernel_local.l` declared an `extern package` (
//! `Amazon.Lambda.RuntimeSupport` / `Lambda.LocalServer`) that was meant to
//! delegate the entire runtime-loop dispatch to a hand-written host adapter.
//! No such adapter was ever written — grepping the whole repository turned
//! up zero code backing either extern name. This file is that dispatch
//! logic, written for the first time in pure Lyric, shared by both kernel
//! variants because (per the original `local` kernel's own header comment)
//! "the dispatch logic is identical to the aws kernel" — only the
//! transport differs (HTTP long-polling against `$AWS_LAMBDA_RUNTIME_API`
//! vs. a synchronous local HTTP test server).
//!
//! The AWS custom runtime protocol needs no FFI at all: it is plain HTTP
//! GET/POST against `$AWS_LAMBDA_RUNTIME_API`, buildable entirely on the
//! already-real `Std.Http` client (used by the `aws` transport below) and
//! `Std.HttpServer` (used by the `local` transport below) — the same
//! pattern `lyric-web`'s `Web.start()` already uses for its own accept loop.
//!
//! ## What is implemented
//!
//! - The wire protocol: `GET .../invocation/next` (event body + the
//!   `Lambda-Runtime-Aws-Request-Id` / `-Deadline-Ms` /
//!   `-Invoked-Function-Arn` headers), `POST .../invocation/{id}/response`,
//!   `POST .../invocation/{id}/error` (AWS's `{"errorMessage","errorType"}`
//!   shape), and `POST .../init/error`.
//! - Event-source detection by sniffing the raw JSON payload shape.
//! - Full JSON decode/encode and `Lambda.Direct` dispatch for the `aws:sqs`
//!   event source and the `raw` catch-all — chosen as the reference
//!   implementations because they are the two structurally distinct
//!   dispatch shapes in this library (a batch-of-records event, and an
//!   opaque passthrough) and the `README.md`'s own quick-start examples
//!   both use them.
//! - Full JSON decode/encode and `Lambda.Direct` dispatch for `aws:sns`,
//!   `aws:s3`, `aws:dynamodb`, `aws:kinesis`, and EventBridge events,
//!   following the `aws:sqs` pattern (#5600). Each decoder is checked
//!   against AWS's documented real-payload field casing, which is not
//!   uniform: SNS records are PascalCase ("EventSource", "Sns", ...); S3's
//!   request/response elements use "sourceIPAddress" and the hyphenated
//!   "x-amz-request-id"/"x-amz-id-2"; DynamoDB and Kinesis records use
//!   "eventID" (not "eventId") and "eventSourceARN"; DynamoDB attribute
//!   values use the single/double-letter DynamoDB wire keys ("S", "N",
//!   "BOOL", ...); EventBridge is a single envelope at the payload root
//!   (no `Records` array) with the "detail-type" JSON key mapped to the
//!   `detailType` field.
//! - Full JSON decode/encode and dispatch for all three Lambda authorizer
//!   types (TOKEN, REQUEST, HTTP API v2) — the IAM-policy and simple
//!   isAuthorized response shapes are already fully modelled in
//!   `Lambda.Authorizer` and needed no new record types.
//!
//! ## What is deliberately NOT implemented (and fails loudly, not silently)
//!
//! - DynamoDB's `M` (Map) and `L` (List) attribute-value wire types are not
//!   decoded by `decodeDynamoDbAttributeValue` — a nested `M`/`L` attribute
//!   silently decodes to an all-`None` `DynamoDbAttributeValue` rather than
//!   erroring. This is a pre-existing limitation of the `DynamoDbAttributeValue`
//!   record itself (see its doc comment in `events.l`); flagged here too since
//!   this file is what actually wires that decoder into live dispatch.
//! - API Gateway v1/v2 and ALB (`Lambda.withRouter`) dispatch:
//!   `Lambda.Kernel.WebBridge`'s `ConditionalWeakTable<LambdaRouter,
//!   Web.Router>` registry is proven (a `LambdaRouter` token now resolves
//!   back to its `Web.Router` — see that kernel's header comment), but
//!   mapping an API Gateway/ALB event through the resolved router (method/
//!   path/header/body extraction, match-and-dispatch, `ApiGwResponse`
//!   encoding, CORS) is separate, larger work, not done here
//!   (docs/35-lambda-library.md §4).
//! - Streaming (`Lambda.withStreamingHandler` / `Lambda.Direct.streamingHandler`):
//!   `Lambda.Stream`'s `StreamWriter` has no working transport (see that
//!   package's header comment).
//!
//! Builds on both targets structurally (`Std.Http`/`Std.HttpServer`'s public
//! surface is not target-gated), but is only exercised by the `aws`/`local`
//! feature variants of `Lambda.Kernel.Runtime`, which are dotnet-only in
//! practice (the JVM managed-runtime kernel does not use this file at all —
//! see `lambda_kernel_jvm.l`).
//!
//! ## Update (#6358): the `Std.Http` cross-package gap this section used to
//! ## describe is fixed on `main`
//!
//! This section previously reported two runtime bugs blocking
//! runtime-testing of the `aws` client path: (1) `defaultClient(): HttpClient`
//! followed by `client.get(url)` from any package other than `Std.Http`
//! itself throwing "unsupported method 'get' on the receiver type", and (2)
//! calling `Std.Http.getAsync` (or any of `Std.Http`'s async free functions)
//! from *any* Lyric program throwing `System.MissingMethodException`. Both
//! were re-verified against current `main` with live-server repros (a
//! standalone cross-assembly package calling `getAsync`/`bodyText` and,
//! separately, `defaultClient().get(url)`/`bodyText`) and **no longer
//! reproduce** — both now correctly read the response body. `getNextInvocation`/
//! `postJson`'s use of the free async functions here is a stylistic choice,
//! not a workaround for either bug anymore.
//!
//! A different, narrower bug remains open in the *timeout* family
//! specifically (`sendWithTimeoutAsync`/`getWithTimeoutAsync`/
//! `postWithTimeoutAsync`, not used by this file): see the doc comments on
//! those functions in `lyric-stdlib/std/http.l` and issue #6367 /
//! #2494's family. `getNextInvocation`/`postJson` do not call the timeout
//! variants, so this file is unaffected either way.
//!
//! See docs/35-lambda-library.md, decision log D062/D064/D099.
package Lambda.Dispatch

import Std.Core
import Std.Collections
import Std.Errors
import Std.Http
import Std.HttpServer
import Std.Json
import Std.Environment as Env
import Std.Time
import Std.Parse
import Std.Console
import Std.Uuid
import Std.Encoding
import Lambda
import Lambda.Events
import Lambda.Authorizer

// ─── Event-source detection ──────────────────────────────────────────────────
/// The event source a raw Lambda invocation payload was classified as.
/// Mirrors the rules documented in the (former) `lambda_kernel_aws.l`
/// header comment, extended with the three authorizer shapes.
pub union EventSource {
  case ApiGwV1Src
  case ApiGwV2Src
  case AlbSrc
  case SqsSrc
  case SnsSrc
  case S3Src
  case DynamoDbSrc
  case KinesisSrc
  case EventBridgeSrc
  case TokenAuthSrc
  case RequestAuthSrc
  case HttpAuthSrc
  case RawSrc
}

func hasProp(elem: in JsonElement, name: in String): Bool {
  match tryGetProperty(elem, name) {
    case Some(_) -> true
    case None -> false
  }
}

func stringPropEquals(elem: in JsonElement, name: in String, expected: in String): Bool {
  match tryGetProperty(elem, name) {
    case Some(v) -> valueKind(v) == 3 and getString(v) == expected
    case None -> false
  }
}

func hasNestedProp(elem: in JsonElement, outer: in String, inner: in String): Bool {
  match tryGetProperty(elem, outer) {
    case Some(outerElem) -> hasProp(outerElem, inner)
    case None -> false
  }
}

func jsonArrayFirst(elem: in JsonElement): Option[JsonElement] {
  var cur = enumerateArray(elem)
  if arrayMoveNext(cur) {
    return Some(value = arrayCurrent(cur))
  }
  return None
}

// SQS, S3, DynamoDB, and Kinesis all use the lowerCamelCase "eventSource"
// key, but AWS's documented SNS-to-Lambda event shape uses "EventSource"
// (PascalCase, alongside "Sns"/"MessageId"/...) — `JsonElement.TryGetProperty`
// is case-sensitive (`JsonDocumentOptions` default), so a real SNS payload
// would otherwise never match and would silently fall through to `RawSrc`.
func firstRecordEventSource(root: in JsonElement): String {
  match tryGetProperty(root, "Records") {
    case Some(recordsElem) -> {
      match jsonArrayFirst(recordsElem) {
        case Some(first) -> {
          val lower = match tryGetProperty(first, "eventSource") {
            case Some(esElem) -> if valueKind(esElem) == 3 { getString(esElem) } else { "" }
            case None -> ""
          }
          if lower.length > 0 {
            lower
          } else {
            match tryGetProperty(first, "EventSource") {
              case Some(esElem) -> if valueKind(esElem) == 3 { getString(esElem) } else { "" }
              case None -> ""
            }
          }
        }
        case None -> ""
      }
    }
    case None -> ""
  }
}

// Sniffs the JSON shape per the rules in this file's header comment.
// A malformed payload (fails to parse as JSON at all) is treated as `raw`
// rather than crashing the invocation loop — the `raw` catch-all handler
// signature (`(String, LambdaContext) -> Result[...]`) is exactly "I don't
// know what this is, here is the text" already.
pub func detectEventSource(rawPayload: in String): EventSource {
  return try {
    detectEventSourceUnsafe(rawPayload)
  } catch Bug as _ {
    RawSrc
  }
}

func detectEventSourceUnsafe(rawPayload: in String): EventSource {
  val doc = parseJson(rawPayload)
  defer {
    disposeJson(doc)
  }
  val root = rootElement(doc)
  val isV2 = stringPropEquals(root, "version", "2.0")

  if isV2 and hasProp(root, "routeArn") {
    return HttpAuthSrc
  }
  if hasProp(root, "authorizationToken") {
    return TokenAuthSrc
  }
  if stringPropEquals(root, "type", "REQUEST") and hasProp(root, "methodArn") and not isV2 {
    return RequestAuthSrc
  }
  if isV2 and hasNestedProp(root, "requestContext", "http") {
    return ApiGwV2Src
  }
  if hasProp(root, "httpMethod") and hasNestedProp(root, "requestContext", "resourceId") {
    return ApiGwV1Src
  }
  if hasNestedProp(root, "requestContext", "elb") {
    return AlbSrc
  }
  val recordSource = firstRecordEventSource(root)
  if recordSource == "aws:sqs" {
    return SqsSrc
  }
  if recordSource == "aws:sns" {
    return SnsSrc
  }
  if recordSource == "aws:s3" {
    return S3Src
  }
  if recordSource == "aws:dynamodb" {
    return DynamoDbSrc
  }
  if recordSource == "aws:kinesis" {
    return KinesisSrc
  }
  if hasProp(root, "source") and hasProp(root, "detail-type") {
    return EventBridgeSrc
  }
  return RawSrc
}

// ─── Shared JSON decode helpers ───────────────────────────────────────────────
func getStringProp(elem: in JsonElement, name: in String): String {
  match tryGetProperty(elem, name) {
    case Some(v) -> if valueKind(v) == 3 { getString(v) } else { "" }
    case None -> ""
  }
}

func getLongProp(elem: in JsonElement, name: in String): Long {
  match tryGetProperty(elem, name) {
    case Some(v) -> match tryGetLong(v) { case Some(n) -> n; case None -> 0i64 }
    case None -> 0i64
  }
}

func decodeStringMap(elem: in JsonElement): Map[String, String] {
  val result: Map[String, String] = newMap()
  var cur = enumerateObject(elem)
  while objectMoveNext(cur) {
    val prop = objectCurrent(cur)
    val value = propertyValue(prop)
    if valueKind(value) == 3 {
      result.add(propertyName(prop), getString(value))
    }
  }
  return result
}

func decodeOptStringMap(root: in JsonElement, name: in String): Option[Map[String, String]] {
  match tryGetProperty(root, name) {
    case Some(v) -> if valueKind(v) == 1 { Some(value = decodeStringMap(v)) } else { None }
    case None -> None
  }
}

func decodeStringListMap(elem: in JsonElement): Map[String, slice[String]] {
  val result: Map[String, slice[String]] = newMap()
  var cur = enumerateObject(elem)
  while objectMoveNext(cur) {
    val prop = objectCurrent(cur)
    val list: List[String] = newList()
    var acur = enumerateArray(propertyValue(prop))
    while arrayMoveNext(acur) {
      val v = arrayCurrent(acur)
      if valueKind(v) == 3 {
        list.add(getString(v))
      }
    }
    result.add(propertyName(prop), list.toArray())
  }
  return result
}

func decodeOptStringListMap(root: in JsonElement, name: in String): Option[Map[String, slice[String]]] {
  match tryGetProperty(root, name) {
    case Some(v) -> if valueKind(v) == 1 { Some(value = decodeStringListMap(v)) } else { None }
    case None -> None
  }
}

func decodeOptStringArray(root: in JsonElement, name: in String): Option[slice[String]] {
  match tryGetProperty(root, name) {
    case Some(v) -> {
      if valueKind(v) == 2 {
        val list: List[String] = newList()
        var cur = enumerateArray(v)
        while arrayMoveNext(cur) {
          val e = arrayCurrent(cur)
          if valueKind(e) == 3 {
            list.add(getString(e))
          }
        }
        Some(value = list.toArray())
      } else {
        None
      }
    }
    case None -> None
  }
}

func getOptStringProp(elem: in JsonElement, name: in String): Option[String] {
  match tryGetProperty(elem, name) {
    case Some(v) -> if valueKind(v) == 3 { Some(value = getString(v)) } else { None }
    case None -> None
  }
}

// JsonValueKind.True = 5, JsonValueKind.False = 6 — used for DynamoDB's
// BOOL/NULL attribute-value shapes, which are JSON booleans, not strings.
func getOptBoolProp(elem: in JsonElement, name: in String): Option[Bool] {
  match tryGetProperty(elem, name) {
    case Some(v) -> {
      val k = valueKind(v)
      if k == 5 or k == 6 {
        Some(value = getBoolean(v))
      } else {
        None
      }
    }
    case None -> None
  }
}

// ─── SQS decode / encode ──────────────────────────────────────────────────────
func decodeSqsMessageAttribute(elem: in JsonElement): SqsMessageAttribute {
  val stringValue = match tryGetProperty(elem, "stringValue") {
    case Some(v) -> if valueKind(v) == 3 { Some(value = getString(v)) } else { None }
    case None -> None
  }
  val binaryValue = match tryGetProperty(elem, "binaryValue") {
    case Some(v) -> if valueKind(v) == 3 { Some(value = getString(v)) } else { None }
    case None -> None
  }
  return SqsMessageAttribute(
    stringValue = stringValue,
    binaryValue = binaryValue,
    dataType = getStringProp(elem, "dataType")
  )
}

func decodeSqsMessageAttributeMap(elem: in JsonElement): Map[String, SqsMessageAttribute] {
  val result: Map[String, SqsMessageAttribute] = newMap()
  var cur = enumerateObject(elem)
  while objectMoveNext(cur) {
    val prop = objectCurrent(cur)
    result.add(propertyName(prop), decodeSqsMessageAttribute(propertyValue(prop)))
  }
  return result
}

func decodeSqsRecord(elem: in JsonElement): SqsRecord {
  return SqsRecord(
    messageId = getStringProp(elem, "messageId"),
    receiptHandle = getStringProp(elem, "receiptHandle"),
    body = getStringProp(elem, "body"),
    attributes = match tryGetProperty(elem, "attributes") {
      case Some(v) -> decodeStringMap(v)
      case None -> newMap()
    },
    messageAttributes = match tryGetProperty(elem, "messageAttributes") {
      case Some(v) -> decodeSqsMessageAttributeMap(v)
      case None -> newMap()
    },
    md5OfBody = getStringProp(elem, "md5OfBody"),
    eventSource = getStringProp(elem, "eventSource"),
    // real AWS payloads use "eventSourceARN" (all-caps ARN); our record
    // field is the Lyric-conventional `eventSourceArn`.
    eventSourceArn = getStringProp(elem, "eventSourceARN"),
    awsRegion = getStringProp(elem, "awsRegion")
  )
}

func decodeSqsEvent(root: in JsonElement): SqsEvent {
  val records: List[SqsRecord] = newList()
  match tryGetProperty(root, "Records") {
    case Some(recordsElem) -> {
      var cur = enumerateArray(recordsElem)
      while arrayMoveNext(cur) {
        records.add(decodeSqsRecord(arrayCurrent(cur)))
      }
    }
    case None -> ()
  }
  return SqsEvent(records = records.toArray())
}

func encodeSqsBatchResponse(resp: in SqsBatchResponse): String {
  var sb = "{\"batchItemFailures\":["
  var i = 0
  while i < resp.batchItemFailures.length {
    if i > 0 {
      sb = sb + ","
    }
    sb = sb + "{\"itemIdentifier\":" + encodeString(resp.batchItemFailures[i].itemIdentifier) + "}"
    i = i + 1
  }
  return sb + "]}"
}

// ─── SNS decode ────────────────────────────────────────────────────────────────
// AWS's SNS notification wrapper uses PascalCase field names throughout
// ("EventSource", "Sns", "MessageId", ...) — a different convention from
// SQS's lowerCamelCase, confirmed against AWS's documented Lambda-SNS
// sample event.
func decodeSnsMessageAttribute(elem: in JsonElement): SnsMessageAttribute {
  return SnsMessageAttribute(attributeType = getStringProp(elem, "Type"), value = getStringProp(elem, "Value"))
}

func decodeSnsMessageAttributeMap(elem: in JsonElement): Map[String, SnsMessageAttribute] {
  val result: Map[String, SnsMessageAttribute] = newMap()
  var cur = enumerateObject(elem)
  while objectMoveNext(cur) {
    val prop = objectCurrent(cur)
    result.add(propertyName(prop), decodeSnsMessageAttribute(propertyValue(prop)))
  }
  return result
}

func emptySnsMessage(): SnsMessage {
  return SnsMessage(
    messageId = "",
    topicArn = "",
    subject = None,
    message = "",
    timestamp = "",
    signatureVersion = "",
    signature = "",
    signingCertUrl = "",
    unsubscribeUrl = "",
    messageAttributes = newMap()
  )
}

func decodeSnsMessage(elem: in JsonElement): SnsMessage {
  return SnsMessage(
    messageId = getStringProp(elem, "MessageId"),
    topicArn = getStringProp(elem, "TopicArn"),
    subject = getOptStringProp(elem, "Subject"),
    message = getStringProp(elem, "Message"),
    timestamp = getStringProp(elem, "Timestamp"),
    signatureVersion = getStringProp(elem, "SignatureVersion"),
    signature = getStringProp(elem, "Signature"),
    signingCertUrl = getStringProp(elem, "SigningCertUrl"),
    unsubscribeUrl = getStringProp(elem, "UnsubscribeUrl"),
    messageAttributes = match tryGetProperty(elem, "MessageAttributes") {
      case Some(v) -> decodeSnsMessageAttributeMap(v)
      case None -> newMap()
    }
  )
}

func decodeSnsRecord(elem: in JsonElement): SnsRecord {
  return SnsRecord(
    eventSource = getStringProp(elem, "EventSource"),
    eventVersion = getStringProp(elem, "EventVersion"),
    eventSubscriptionArn = getStringProp(elem, "EventSubscriptionArn"),
    sns = match tryGetProperty(elem, "Sns") {
      case Some(v) -> decodeSnsMessage(v)
      case None -> emptySnsMessage()
    }
  )
}

func decodeSnsEvent(root: in JsonElement): SnsEvent {
  val records: List[SnsRecord] = newList()
  match tryGetProperty(root, "Records") {
    case Some(recordsElem) -> {
      var cur = enumerateArray(recordsElem)
      while arrayMoveNext(cur) {
        records.add(decodeSnsRecord(arrayCurrent(cur)))
      }
    }
    case None -> ()
  }
  return SnsEvent(records = records.toArray())
}

// ─── S3 decode ─────────────────────────────────────────────────────────────────
// Two real-payload quirks vs. the record field names: the request
// parameter is "sourceIPAddress" (capital IP), and the response elements
// are the hyphenated "x-amz-request-id" / "x-amz-id-2" — neither is a
// valid Lyric identifier, which is exactly why S3ResponseElements /
// S3RequestParameters rename them in the record shape.
func emptyS3RequestParameters(): S3RequestParameters {
  return S3RequestParameters(sourceIpAddress = "")
}

func decodeS3RequestParameters(elem: in JsonElement): S3RequestParameters {
  return S3RequestParameters(sourceIpAddress = getStringProp(elem, "sourceIPAddress"))
}

func emptyS3ResponseElements(): S3ResponseElements {
  return S3ResponseElements(xAmzRequestId = "", xAmzId2 = "")
}

func decodeS3ResponseElements(elem: in JsonElement): S3ResponseElements {
  return S3ResponseElements(
    xAmzRequestId = getStringProp(elem, "x-amz-request-id"),
    xAmzId2 = getStringProp(elem, "x-amz-id-2")
  )
}

func emptyS3Bucket(): S3Bucket {
  return S3Bucket(name = "", ownerIdentity = newMap(), arn = "")
}

func decodeS3Bucket(elem: in JsonElement): S3Bucket {
  return S3Bucket(
    name = getStringProp(elem, "name"),
    ownerIdentity = match tryGetProperty(elem, "ownerIdentity") {
      case Some(v) -> decodeStringMap(v)
      case None -> newMap()
    },
    arn = getStringProp(elem, "arn")
  )
}

func emptyS3Object(): S3Object {
  return S3Object(key = "", size = 0i64, eTag = "", sequencer = "")
}

func decodeS3Object(elem: in JsonElement): S3Object {
  return S3Object(
    key = getStringProp(elem, "key"),
    size = getLongProp(elem, "size"),
    eTag = getStringProp(elem, "eTag"),
    sequencer = getStringProp(elem, "sequencer")
  )
}

func emptyS3Detail(): S3Detail {
  return S3Detail(s3SchemaVersion = "", configurationId = "", bucket = emptyS3Bucket(), object = emptyS3Object())
}

func decodeS3Detail(elem: in JsonElement): S3Detail {
  return S3Detail(
    s3SchemaVersion = getStringProp(elem, "s3SchemaVersion"),
    configurationId = getStringProp(elem, "configurationId"),
    bucket = match tryGetProperty(elem, "bucket") {
      case Some(v) -> decodeS3Bucket(v)
      case None -> emptyS3Bucket()
    },
    object = match tryGetProperty(elem, "object") {
      case Some(v) -> decodeS3Object(v)
      case None -> emptyS3Object()
    }
  )
}

func decodeS3Record(elem: in JsonElement): S3Record {
  return S3Record(
    eventVersion = getStringProp(elem, "eventVersion"),
    eventSource = getStringProp(elem, "eventSource"),
    awsRegion = getStringProp(elem, "awsRegion"),
    eventTime = getStringProp(elem, "eventTime"),
    eventName = getStringProp(elem, "eventName"),
    userIdentity = match tryGetProperty(elem, "userIdentity") {
      case Some(v) -> decodeStringMap(v)
      case None -> newMap()
    },
    requestParameters = match tryGetProperty(elem, "requestParameters") {
      case Some(v) -> decodeS3RequestParameters(v)
      case None -> emptyS3RequestParameters()
    },
    responseElements = match tryGetProperty(elem, "responseElements") {
      case Some(v) -> decodeS3ResponseElements(v)
      case None -> emptyS3ResponseElements()
    },
    s3 = match tryGetProperty(elem, "s3") { case Some(v) -> decodeS3Detail(v); case None -> emptyS3Detail() }
  )
}

func decodeS3Event(root: in JsonElement): S3Event {
  val records: List[S3Record] = newList()
  match tryGetProperty(root, "Records") {
    case Some(recordsElem) -> {
      var cur = enumerateArray(recordsElem)
      while arrayMoveNext(cur) {
        records.add(decodeS3Record(arrayCurrent(cur)))
      }
    }
    case None -> ()
  }
  return S3Event(records = records.toArray())
}

// ─── DynamoDB Streams decode ────────────────────────────────────────────────────
// Two quirks vs. the record field names: the per-record id is "eventID"
// (capital ID, like Kinesis below), and DynamoDB's low-level attribute-value
// wire format uses single/double-uppercase-letter keys ("S", "N", "B",
// "BOOL", "NULL", "SS", "NS", "BS") per the DynamoDB Streams Record API,
// not the Lyric-conventional lowercase field names on DynamoDbAttributeValue.
func decodeDynamoDbAttributeValue(elem: in JsonElement): DynamoDbAttributeValue {
  return DynamoDbAttributeValue(
    s = getOptStringProp(elem, "S"),
    n = getOptStringProp(elem, "N"),
    b = getOptStringProp(elem, "B"),
    bool = getOptBoolProp(elem, "BOOL"),
    null = getOptBoolProp(elem, "NULL"),
    ss = decodeOptStringArray(elem, "SS"),
    ns = decodeOptStringArray(elem, "NS"),
    bs = decodeOptStringArray(elem, "BS")
  )
}

func decodeDynamoDbAttributeMap(elem: in JsonElement): Map[String, DynamoDbAttributeValue] {
  val result: Map[String, DynamoDbAttributeValue] = newMap()
  var cur = enumerateObject(elem)
  while objectMoveNext(cur) {
    val prop = objectCurrent(cur)
    result.add(propertyName(prop), decodeDynamoDbAttributeValue(propertyValue(prop)))
  }
  return result
}

// ApproximateCreationDateTime is documented as a Unix-epoch number but is
// not guaranteed to be integral on the wire; fall back to a Double read
// (truncated) so a fractional-second timestamp still decodes instead of
// silently dropping to None.
func getOptEpochLongProp(elem: in JsonElement, name: in String): Option[Long] {
  match tryGetProperty(elem, name) {
    case Some(v) -> match tryGetLong(v) {
      case Some(n) -> Some(value = n)
      case None -> match tryGetDouble(v) { case Some(d) -> Some(value = d.toLong()); case None -> None }
    }
    case None -> None
  }
}

func emptyDynamoDbStreamRecord(): DynamoDbStreamRecord {
  return DynamoDbStreamRecord(
    approximateCreationDateTime = None,
    keys = newMap(),
    newImage = None,
    oldImage = None,
    sequenceNumber = "",
    sizeBytes = 0i64,
    streamViewType = ""
  )
}

func decodeDynamoDbStreamRecord(elem: in JsonElement): DynamoDbStreamRecord {
  return DynamoDbStreamRecord(
    approximateCreationDateTime = getOptEpochLongProp(elem, "ApproximateCreationDateTime"),
    keys = match tryGetProperty(elem, "Keys") {
      case Some(v) -> decodeDynamoDbAttributeMap(v)
      case None -> newMap()
    },
    newImage = match tryGetProperty(elem, "NewImage") {
      case Some(v) -> if valueKind(v) == 1 {
        Some(value = decodeDynamoDbAttributeMap(v))
      } else {
        None
      }
      case None -> None
    },
    oldImage = match tryGetProperty(elem, "OldImage") {
      case Some(v) -> if valueKind(v) == 1 {
        Some(value = decodeDynamoDbAttributeMap(v))
      } else {
        None
      }
      case None -> None
    },
    sequenceNumber = getStringProp(elem, "SequenceNumber"),
    sizeBytes = getLongProp(elem, "SizeBytes"),
    streamViewType = getStringProp(elem, "StreamViewType")
  )
}

func decodeDynamoDbRecord(elem: in JsonElement): DynamoDbRecord {
  return DynamoDbRecord(
    eventId = getStringProp(elem, "eventID"),
    eventVersion = getStringProp(elem, "eventVersion"),
    eventSource = getStringProp(elem, "eventSource"),
    eventName = getStringProp(elem, "eventName"),
    awsRegion = getStringProp(elem, "awsRegion"),
    dynamodb = match tryGetProperty(elem, "dynamodb") {
      case Some(v) -> decodeDynamoDbStreamRecord(v)
      case None -> emptyDynamoDbStreamRecord()
    },
    eventSourceArn = getStringProp(elem, "eventSourceARN")
  )
}

func decodeDynamoDbEvent(root: in JsonElement): DynamoDbEvent {
  val records: List[DynamoDbRecord] = newList()
  match tryGetProperty(root, "Records") {
    case Some(recordsElem) -> {
      var cur = enumerateArray(recordsElem)
      while arrayMoveNext(cur) {
        records.add(decodeDynamoDbRecord(arrayCurrent(cur)))
      }
    }
    case None -> ()
  }
  return DynamoDbEvent(records = records.toArray())
}

// ─── Kinesis Data Streams decode ────────────────────────────────────────────────
// Like DynamoDB, the per-record id is "eventID" (capital ID) and the ARN
// field is "eventSourceARN" (all-caps ARN), both mapped onto the
// Lyric-conventional eventId / eventSourceArn fields.
func emptyKinesisRecord(): KinesisRecord {
  return KinesisRecord(
    kinesisSchemaVersion = "",
    partitionKey = "",
    sequenceNumber = "",
    data = "",
    approximateArrivalTimestamp = 0.0
  )
}

func decodeKinesisRecord(elem: in JsonElement): KinesisRecord {
  return KinesisRecord(
    kinesisSchemaVersion = getStringProp(elem, "kinesisSchemaVersion"),
    partitionKey = getStringProp(elem, "partitionKey"),
    sequenceNumber = getStringProp(elem, "sequenceNumber"),
    data = getStringProp(elem, "data"),
    approximateArrivalTimestamp = match tryGetProperty(elem, "approximateArrivalTimestamp") {
      case Some(v) -> match tryGetDouble(v) { case Some(d) -> d; case None -> 0.0 }
      case None -> 0.0
    }
  )
}

func decodeKinesisStreamRecord(elem: in JsonElement): KinesisStreamRecord {
  return KinesisStreamRecord(
    kinesis = match tryGetProperty(elem, "kinesis") {
      case Some(v) -> decodeKinesisRecord(v)
      case None -> emptyKinesisRecord()
    },
    eventSource = getStringProp(elem, "eventSource"),
    eventVersion = getStringProp(elem, "eventVersion"),
    eventId = getStringProp(elem, "eventID"),
    eventName = getStringProp(elem, "eventName"),
    invokeIdentityArn = getStringProp(elem, "invokeIdentityArn"),
    awsRegion = getStringProp(elem, "awsRegion"),
    eventSourceArn = getStringProp(elem, "eventSourceARN")
  )
}

func decodeKinesisEvent(root: in JsonElement): KinesisEvent {
  val records: List[KinesisStreamRecord] = newList()
  match tryGetProperty(root, "Records") {
    case Some(recordsElem) -> {
      var cur = enumerateArray(recordsElem)
      while arrayMoveNext(cur) {
        records.add(decodeKinesisStreamRecord(arrayCurrent(cur)))
      }
    }
    case None -> ()
  }
  return KinesisEvent(records = records.toArray())
}

// ─── EventBridge decode ──────────────────────────────────────────────────────────
// Unlike the other four sources, EventBridge delivers a single event
// envelope directly at the root — no "Records" wrapper. "detail-type" is
// not a valid Lyric identifier, hence the detailType rename; "detail" is
// kept as raw JSON text since its shape depends on source + detailType.
func decodeEventBridgeEvent(root: in JsonElement): EventBridgeEvent {
  return EventBridgeEvent(
    version = getStringProp(root, "version"),
    id = getStringProp(root, "id"),
    source = getStringProp(root, "source"),
    account = getStringProp(root, "account"),
    time = getStringProp(root, "time"),
    region = getStringProp(root, "region"),
    resources = match decodeOptStringArray(root, "resources") { case Some(arr) -> arr; case None -> [] },
    detailType = getStringProp(root, "detail-type"),
    detail = match tryGetProperty(root, "detail") { case Some(v) -> getRawText(v); case None -> "{}" }
  )
}

// ─── Authorizer decode / encode ───────────────────────────────────────────────
func decodeTokenAuthorizerEvent(root: in JsonElement): TokenAuthorizerEvent {
  return TokenAuthorizerEvent(
    authorizationToken = getStringProp(root, "authorizationToken"),
    methodArn = getStringProp(root, "methodArn")
  )
}

func decodeRequestAuthorizerContext(elem: in JsonElement): RequestAuthorizerContext {
  return RequestAuthorizerContext(
    accountId = getStringProp(elem, "accountId"),
    apiId = getStringProp(elem, "apiId"),
    httpMethod = getStringProp(elem, "httpMethod"),
    requestId = getStringProp(elem, "requestId"),
    resourceId = getStringProp(elem, "resourceId"),
    resourcePath = getStringProp(elem, "resourcePath"),
    stage = getStringProp(elem, "stage"),
    path = getStringProp(elem, "path"),
    requestTime = getStringProp(elem, "requestTime"),
    requestTimeEpoch = getLongProp(elem, "requestTimeEpoch")
  )
}

func emptyRequestAuthorizerContext(): RequestAuthorizerContext {
  return RequestAuthorizerContext(
    accountId = "",
    apiId = "",
    httpMethod = "",
    requestId = "",
    resourceId = "",
    resourcePath = "",
    stage = "",
    path = "",
    requestTime = "",
    requestTimeEpoch = 0i64
  )
}

func decodeRequestAuthorizerEvent(root: in JsonElement): RequestAuthorizerEvent {
  return RequestAuthorizerEvent(
    authorizerType = getStringProp(root, "type"),
    methodArn = getStringProp(root, "methodArn"),
    headers = decodeOptStringMap(root, "headers"),
    multiValueHeaders = decodeOptStringListMap(root, "multiValueHeaders"),
    queryStringParameters = decodeOptStringMap(root, "queryStringParameters"),
    multiValueQueryStringParameters = decodeOptStringListMap(root, "multiValueQueryStringParameters"),
    pathParameters = decodeOptStringMap(root, "pathParameters"),
    stageVariables = decodeOptStringMap(root, "stageVariables"),
    requestContext = match tryGetProperty(root, "requestContext") {
      case Some(v) -> decodeRequestAuthorizerContext(v)
      case None -> emptyRequestAuthorizerContext()
    }
  )
}

func decodeHttpAuthorizerHttp(elem: in JsonElement): HttpAuthorizerHttp {
  return HttpAuthorizerHttp(
    method = getStringProp(elem, "method"),
    path = getStringProp(elem, "path"),
    protocol = getStringProp(elem, "protocol"),
    sourceIp = getStringProp(elem, "sourceIp"),
    userAgent = getStringProp(elem, "userAgent")
  )
}

func emptyHttpAuthorizerHttp(): HttpAuthorizerHttp {
  return HttpAuthorizerHttp(method = "", path = "", protocol = "", sourceIp = "", userAgent = "")
}

func decodeHttpAuthorizerRequestContext(elem: in JsonElement): HttpAuthorizerRequestContext {
  return HttpAuthorizerRequestContext(
    accountId = getStringProp(elem, "accountId"),
    apiId = getStringProp(elem, "apiId"),
    domainName = getStringProp(elem, "domainName"),
    http = match tryGetProperty(elem, "http") {
      case Some(v) -> decodeHttpAuthorizerHttp(v)
      case None -> emptyHttpAuthorizerHttp()
    },
    requestId = getStringProp(elem, "requestId"),
    routeKey = getStringProp(elem, "routeKey"),
    stage = getStringProp(elem, "stage"),
    time = getStringProp(elem, "time"),
    timeEpoch = getLongProp(elem, "timeEpoch")
  )
}

func emptyHttpAuthorizerRequestContext(): HttpAuthorizerRequestContext {
  return HttpAuthorizerRequestContext(
    accountId = "",
    apiId = "",
    domainName = "",
    http = emptyHttpAuthorizerHttp(),
    requestId = "",
    routeKey = "",
    stage = "",
    time = "",
    timeEpoch = 0i64
  )
}

// AWS sends `identitySource` as an array of resolved identity-source values
// (one per configured expression); `HttpAuthorizerEvent.identitySource` is a
// single `String` (the existing, not-my-place-to-redesign record shape), so
// the first element stands in for "the" identity source value.
func firstIdentitySource(root: in JsonElement): String {
  match decodeOptStringArray(root, "identitySource") {
    case Some(arr) -> if arr.length > 0 { arr[0] } else { "" }
    case None -> ""
  }
}

func decodeHttpAuthorizerEvent(root: in JsonElement): HttpAuthorizerEvent {
  return HttpAuthorizerEvent(
    version = getStringProp(root, "version"),
    authorizerType = getStringProp(root, "type"),
    routeArn = getStringProp(root, "routeArn"),
    identitySource = firstIdentitySource(root),
    routeKey = getStringProp(root, "routeKey"),
    rawPath = getStringProp(root, "rawPath"),
    rawQueryString = getStringProp(root, "rawQueryString"),
    cookies = decodeOptStringArray(root, "cookies"),
    headers = match tryGetProperty(root, "headers") { case Some(v) -> decodeStringMap(v); case None -> newMap() },
    queryStringParameters = decodeOptStringMap(root, "queryStringParameters"),
    pathParameters = decodeOptStringMap(root, "pathParameters"),
    stageVariables = decodeOptStringMap(root, "stageVariables"),
    requestContext = match tryGetProperty(root, "requestContext") {
      case Some(v) -> decodeHttpAuthorizerRequestContext(v)
      case None -> emptyHttpAuthorizerRequestContext()
    }
  )
}

func encodeStringArray(arr: in slice[String]): String {
  var sb = "["
  var i = 0
  while i < arr.length {
    if i > 0 {
      sb = sb + ","
    }
    sb = sb + encodeString(arr[i])
    i = i + 1
  }
  return sb + "]"
}

func encodeStringMap(m: in Map[String, String]): String {
  var sb = "{"
  val keys = mapKeys(m).toArray()
  var i = 0
  while i < keys.length {
    if i > 0 {
      sb = sb + ","
    }
    match mapGet(m, keys[i]) {
      case Some(v) -> {
        sb = sb + encodeString(keys[i]) + ":" + encodeString(v)
      }
      case None -> ()
    }
    i = i + 1
  }
  return sb + "}"
}

func iamEffectString(e: in IamEffect): String {
  match e {
    case Allow -> "Allow"
    case Deny -> "Deny"
  }
}

func encodeIamStatement(s: in IamStatement): String {
  return "{\"Effect\":" + encodeString(iamEffectString(s.effect)) + ",\"Action\":" + encodeStringArray(s.action) +
    ",\"Resource\":" +
    encodeStringArray(s.resource) +
    "}"
}

// IAM policy JSON is capitalised ("Version"/"Statement"/"Effect"/...) per
// AWS convention — deliberately not matching this repo's lowerCamelCase
// Lyric field-naming convention on `IamPolicyDocument`/`IamStatement`.
func encodeAuthorizerResponse(resp: in AuthorizerResponse): String {
  var statements = "["
  var i = 0
  while i < resp.policyDocument.statement.length {
    if i > 0 {
      statements = statements + ","
    }
    statements = statements + encodeIamStatement(resp.policyDocument.statement[i])
    i = i + 1
  }
  statements = statements + "]"
  var sb = "{\"principalId\":" + encodeString(resp.principalId) + ",\"policyDocument\":{\"Version\":" +
    encodeString(resp.policyDocument.version) +
    ",\"Statement\":" +
    statements +
    "}" +
    ",\"context\":" +
    encodeStringMap(resp.context)
  match resp.usageIdentifierKey {
    case Some(k) -> {
      sb = sb + ",\"usageIdentifierKey\":" + encodeString(k)
    }
    case None -> ()
  }
  return sb + "}"
}

func encodeHttpAuthorizerResponse(resp: in HttpAuthorizerResponse): String {
  val boolStr = if resp.isAuthorized { "true" } else { "false" }
  return "{\"isAuthorized\":" + boolStr + ",\"context\":" + encodeStringMap(resp.context) + "}"
}

// ─── AWS Lambda error JSON shape ──────────────────────────────────────────────
func awsErrorJson(message: in String, errorType: in String): String {
  return "{\"errorMessage\":" + encodeString(message) + ",\"errorType\":" + encodeString(errorType) + "}"
}

/// The `{"errorMessage","errorType"}` shape AWS Lambda expects on
/// `POST .../invocation/{id}/error` and (via `Std.HttpServer`) on the
/// `local` kernel's error response body.
pub func lambdaErrorJson(err: in LambdaError): String {
  match err {
    case HandlerError(msg, t) -> awsErrorJson(msg, t)
    case ParseError(msg) -> awsErrorJson(msg, "ParseError")
    case TimeoutError(ms) -> awsErrorJson("remaining time " + ms.toString() + "ms", "TimeoutError")
    case InternalError(msg) -> awsErrorJson(msg, "InternalError")
  }
}

/// The `errorType` string AWS's Runtime API expects in the
/// `Lambda-Runtime-Function-Error-Type` header on an `/error` POST — the
/// same discriminant `lambdaErrorJson` embeds in the body's `errorType`
/// field, so the header and body agree.
pub func lambdaErrorType(err: in LambdaError): String {
  match err {
    case HandlerError(_, t) -> t
    case ParseError(_) -> "ParseError"
    case TimeoutError(_) -> "TimeoutError"
    case InternalError(_) -> "InternalError"
  }
}

// ─── DirectHandler lookup ─────────────────────────────────────────────────────
func findSqsDirect(app: in LambdaApp): Option[DirectHandler] {
  var i = 0
  while i < app.directHandlers.length {
    match app.directHandlers[i] {
      case SqsDirect(_) -> return Some(value = app.directHandlers[i])
      case SqsBatchDirect(_) -> return Some(value = app.directHandlers[i])
      case _ -> ()
    }
    i = i + 1
  }
  return None
}

func findRawDirect(app: in LambdaApp): Option[DirectHandler] {
  var i = 0
  while i < app.directHandlers.length {
    match app.directHandlers[i] {
      case RawDirect(_) -> return Some(value = app.directHandlers[i])
      case _ -> ()
    }
    i = i + 1
  }
  return None
}

func findSnsDirect(app: in LambdaApp): Option[DirectHandler] {
  var i = 0
  while i < app.directHandlers.length {
    match app.directHandlers[i] {
      case SnsDirect(_) -> return Some(value = app.directHandlers[i])
      case _ -> ()
    }
    i = i + 1
  }
  return None
}

func findS3Direct(app: in LambdaApp): Option[DirectHandler] {
  var i = 0
  while i < app.directHandlers.length {
    match app.directHandlers[i] {
      case S3Direct(_) -> return Some(value = app.directHandlers[i])
      case _ -> ()
    }
    i = i + 1
  }
  return None
}

func findDynamoDbDirect(app: in LambdaApp): Option[DirectHandler] {
  var i = 0
  while i < app.directHandlers.length {
    match app.directHandlers[i] {
      case DynamoDbDirect(_) -> return Some(value = app.directHandlers[i])
      case _ -> ()
    }
    i = i + 1
  }
  return None
}

func findKinesisDirect(app: in LambdaApp): Option[DirectHandler] {
  var i = 0
  while i < app.directHandlers.length {
    match app.directHandlers[i] {
      case KinesisDirect(_) -> return Some(value = app.directHandlers[i])
      case _ -> ()
    }
    i = i + 1
  }
  return None
}

func findEventBridgeDirect(app: in LambdaApp): Option[DirectHandler] {
  var i = 0
  while i < app.directHandlers.length {
    match app.directHandlers[i] {
      case EventBridgeDirect(_) -> return Some(value = app.directHandlers[i])
      case _ -> ()
    }
    i = i + 1
  }
  return None
}

func findTokenAuthorizerDirect(app: in LambdaApp): Option[DirectHandler] {
  var i = 0
  while i < app.directHandlers.length {
    match app.directHandlers[i] {
      case TokenAuthorizerDirect(_) -> return Some(value = app.directHandlers[i])
      case _ -> ()
    }
    i = i + 1
  }
  return None
}

func findRequestAuthorizerDirect(app: in LambdaApp): Option[DirectHandler] {
  var i = 0
  while i < app.directHandlers.length {
    match app.directHandlers[i] {
      case RequestAuthorizerDirect(_) -> return Some(value = app.directHandlers[i])
      case _ -> ()
    }
    i = i + 1
  }
  return None
}

func findHttpAuthorizerDirect(app: in LambdaApp): Option[DirectHandler] {
  var i = 0
  while i < app.directHandlers.length {
    match app.directHandlers[i] {
      case HttpAuthorizerDirect(_) -> return Some(value = app.directHandlers[i])
      case _ -> ()
    }
    i = i + 1
  }
  return None
}

// ─── Per-source dispatch ──────────────────────────────────────────────────────
func dispatchSqs(app: in LambdaApp, rawPayload: in String, ctx: in LambdaContext): Result[String, LambdaError] {
  match findSqsDirect(app) {
    case Some(SqsDirect(handler)) -> {
      val doc = parseJson(rawPayload)
      defer {
        disposeJson(doc)
      }
      val event = decodeSqsEvent(rootElement(doc))
      match handler.handle(event, ctx) {
        case Ok(_) -> Ok(value = "null")
        case Err(e) -> Err(error = e)
      }
    }
    case Some(SqsBatchDirect(handler)) -> {
      val doc = parseJson(rawPayload)
      defer {
        disposeJson(doc)
      }
      val event = decodeSqsEvent(rootElement(doc))
      match handler.handle(event, ctx) {
        case Ok(resp) -> Ok(value = encodeSqsBatchResponse(resp))
        case Err(e) -> Err(error = e)
      }
    }
    case _ -> Err(
      error = InternalError(
        "no handler registered for aws:sqs; register one with Lambda.Direct.sqsHandler / " +
          "sqsBatchHandler and Lambda.withDirect"
      )
    )
  }
}

func dispatchSns(app: in LambdaApp, rawPayload: in String, ctx: in LambdaContext): Result[String, LambdaError] {
  match findSnsDirect(app) {
    case Some(SnsDirect(handler)) -> {
      val doc = parseJson(rawPayload)
      defer {
        disposeJson(doc)
      }
      val event = decodeSnsEvent(rootElement(doc))
      match handler.handle(event, ctx) {
        case Ok(_) -> Ok(value = "null")
        case Err(e) -> Err(error = e)
      }
    }
    case _ -> Err(
      error = InternalError(
        "no handler registered for aws:sns; register one with Lambda.Direct.snsHandler " +
          "and Lambda.withDirect"
      )
    )
  }
}

func dispatchS3(app: in LambdaApp, rawPayload: in String, ctx: in LambdaContext): Result[String, LambdaError] {
  match findS3Direct(app) {
    case Some(S3Direct(handler)) -> {
      val doc = parseJson(rawPayload)
      defer {
        disposeJson(doc)
      }
      val event = decodeS3Event(rootElement(doc))
      match handler.handle(event, ctx) {
        case Ok(_) -> Ok(value = "null")
        case Err(e) -> Err(error = e)
      }
    }
    case _ -> Err(
      error = InternalError(
        "no handler registered for aws:s3; register one with Lambda.Direct.s3Handler " +
          "and Lambda.withDirect"
      )
    )
  }
}

func dispatchDynamoDb(app: in LambdaApp, rawPayload: in String, ctx: in LambdaContext): Result[String, LambdaError] {
  match findDynamoDbDirect(app) {
    case Some(DynamoDbDirect(handler)) -> {
      val doc = parseJson(rawPayload)
      defer {
        disposeJson(doc)
      }
      val event = decodeDynamoDbEvent(rootElement(doc))
      match handler.handle(event, ctx) {
        case Ok(_) -> Ok(value = "null")
        case Err(e) -> Err(error = e)
      }
    }
    case _ -> Err(
      error = InternalError(
        "no handler registered for aws:dynamodb; register one with Lambda.Direct.dynamoDbHandler " +
          "and Lambda.withDirect"
      )
    )
  }
}

func dispatchKinesis(app: in LambdaApp, rawPayload: in String, ctx: in LambdaContext): Result[String, LambdaError] {
  match findKinesisDirect(app) {
    case Some(KinesisDirect(handler)) -> {
      val doc = parseJson(rawPayload)
      defer {
        disposeJson(doc)
      }
      val event = decodeKinesisEvent(rootElement(doc))
      match handler.handle(event, ctx) {
        case Ok(_) -> Ok(value = "null")
        case Err(e) -> Err(error = e)
      }
    }
    case _ -> Err(
      error = InternalError(
        "no handler registered for aws:kinesis; register one with Lambda.Direct.kinesisHandler " +
          "and Lambda.withDirect"
      )
    )
  }
}

func dispatchEventBridge(app: in LambdaApp, rawPayload: in String, ctx: in LambdaContext): Result[String, LambdaError] {
  match findEventBridgeDirect(app) {
    case Some(EventBridgeDirect(handler)) -> {
      val doc = parseJson(rawPayload)
      defer {
        disposeJson(doc)
      }
      val event = decodeEventBridgeEvent(rootElement(doc))
      match handler.handle(event, ctx) {
        case Ok(_) -> Ok(value = "null")
        case Err(e) -> Err(error = e)
      }
    }
    case _ -> Err(
      error = InternalError(
        "no handler registered for EventBridge events; register one with Lambda.Direct.eventBridgeHandler " +
          "and Lambda.withDirect"
      )
    )
  }
}

func dispatchRaw(app: in LambdaApp, rawPayload: in String, ctx: in LambdaContext): Result[String, LambdaError] {
  match findRawDirect(app) {
    case Some(RawDirect(handler)) -> {
      match handler.handle(rawPayload, ctx) {
        case Ok(_) -> Ok(value = "null")
        case Err(e) -> Err(error = e)
      }
    }
    case _ -> Err(
      error = InternalError(
        "no handler registered for raw/unrecognised events; register one with " +
          "Lambda.Direct.rawHandler and Lambda.withDirect"
      )
    )
  }
}

func dispatchTokenAuthorizer(
  app: in LambdaApp, rawPayload: in String, ctx: in LambdaContext
): Result[String, LambdaError] {
  match findTokenAuthorizerDirect(app) {
    case Some(TokenAuthorizerDirect(handler)) -> {
      val doc = parseJson(rawPayload)
      defer {
        disposeJson(doc)
      }
      val event = decodeTokenAuthorizerEvent(rootElement(doc))
      match handler.handle(event, ctx) {
        case Ok(resp) -> Ok(value = encodeAuthorizerResponse(resp))
        case Err(e) -> Err(error = e)
      }
    }
    case _ -> Err(
      error = InternalError(
        "no handler registered for the TOKEN authorizer; register one with " +
          "Lambda.Direct.tokenAuthorizerHandler and Lambda.withDirect"
      )
    )
  }
}

func dispatchRequestAuthorizer(
  app: in LambdaApp, rawPayload: in String, ctx: in LambdaContext
): Result[String, LambdaError] {
  match findRequestAuthorizerDirect(app) {
    case Some(RequestAuthorizerDirect(handler)) -> {
      val doc = parseJson(rawPayload)
      defer {
        disposeJson(doc)
      }
      val event = decodeRequestAuthorizerEvent(rootElement(doc))
      match handler.handle(event, ctx) {
        case Ok(resp) -> Ok(value = encodeAuthorizerResponse(resp))
        case Err(e) -> Err(error = e)
      }
    }
    case _ -> Err(
      error = InternalError(
        "no handler registered for the REQUEST authorizer; register one with " +
          "Lambda.Direct.requestAuthorizerHandler and Lambda.withDirect"
      )
    )
  }
}

func dispatchHttpAuthorizer(
  app: in LambdaApp, rawPayload: in String, ctx: in LambdaContext
): Result[String, LambdaError] {
  match findHttpAuthorizerDirect(app) {
    case Some(HttpAuthorizerDirect(handler)) -> {
      val doc = parseJson(rawPayload)
      defer {
        disposeJson(doc)
      }
      val event = decodeHttpAuthorizerEvent(rootElement(doc))
      match handler.handle(event, ctx) {
        case Ok(resp) -> Ok(value = encodeHttpAuthorizerResponse(resp))
        case Err(e) -> Err(error = e)
      }
    }
    case _ -> Err(
      error = InternalError(
        "no handler registered for the HTTP API (v2) authorizer; register one with " +
          "Lambda.Direct.httpAuthorizerHandler and Lambda.withDirect"
      )
    )
  }
}

func dispatchHttp(app: in LambdaApp): Result[String, LambdaError] {
  match app.httpRouter {
    case Some(_) -> return Err(
      error = InternalError(
        "HTTP dispatch via Lambda.withRouter is not implemented yet: the LambdaRouter " +
          "token now resolves back to its Web.Router (Lambda.Kernel.WebBridge's " +
          "ConditionalWeakTable<LambdaRouter, Web.Router> registry is proven, see that file's " +
          "header comment), but mapping an API Gateway v1/v2/ALB event through the resolved " +
          "router (method/path/header/body extraction, match-and-dispatch, ApiGwResponse " +
          "encoding, CORS) is separate, larger work not done here " +
          "(see docs/35-lambda-library.md §4)"
      )
    )
    case None -> ()
  }
  match app.streamingHandler {
    case Some(_) -> return Err(
      error = InternalError(
        "streaming HTTP dispatch is not implemented yet: Lambda.Stream has no working transport"
      )
    )
    case None -> ()
  }
  return Err(error = InternalError("no HTTP handler registered on this LambdaApp"))
}

/// Classify `rawPayload` and dispatch it to the matching registered
/// `Lambda.Direct` handler, returning the JSON response body to post back
/// (`Ok`) or the `LambdaError` to report via the error endpoint (`Err`).
/// No I/O — safe to unit test directly against literal JSON strings.
@stable(since = "0.1")
pub func dispatchInvocation(
  app: in LambdaApp, rawPayload: in String, ctx: in LambdaContext
): Result[String, LambdaError] {
  match detectEventSource(rawPayload) {
    case SqsSrc -> dispatchSqs(app, rawPayload, ctx)
    case RawSrc -> dispatchRaw(app, rawPayload, ctx)
    case TokenAuthSrc -> dispatchTokenAuthorizer(app, rawPayload, ctx)
    case RequestAuthSrc -> dispatchRequestAuthorizer(app, rawPayload, ctx)
    case HttpAuthSrc -> dispatchHttpAuthorizer(app, rawPayload, ctx)
    case SnsSrc -> dispatchSns(app, rawPayload, ctx)
    case S3Src -> dispatchS3(app, rawPayload, ctx)
    case DynamoDbSrc -> dispatchDynamoDb(app, rawPayload, ctx)
    case KinesisSrc -> dispatchKinesis(app, rawPayload, ctx)
    case EventBridgeSrc -> dispatchEventBridge(app, rawPayload, ctx)
    case ApiGwV1Src -> dispatchHttp(app)
    case ApiGwV2Src -> dispatchHttp(app)
    case AlbSrc -> dispatchHttp(app)
  }
}

// ─── aws transport: HTTP long-polling against $AWS_LAMBDA_RUNTIME_API ────────
record Invocation {
  requestId: String
  payload: String
  deadlineMs: Long
  invokedFunctionArn: String
}

// Calls the `Std.Http` free functions (`getAsync`/`sendAsync`, the
// "process-wide default client" surface) rather than obtaining an
// `HttpClient` interface value and calling methods on it: doing the
// latter from a package other than `Std.Http` itself reproducibly throws
// "unsupported method 'get' on the receiver type" at runtime — confirmed
// with a 10-line repro with zero Lambda-specific code involved, so this
// is a pre-existing self-hosted-backend gap in interface-typed factory
// return values, not anything specific to this dispatch loop. The free
// functions below hit the exact same `Std.HttpHost` primitives without
// going through the interface at all.
func getNextInvocation(runtimeApi: in String): Result[Invocation, String] {
  val url = "http://" + runtimeApi + "/2018-06-01/runtime/invocation/next"
  match await getAsync(url) {
    case Err(e) -> return Err(error = "GET /invocation/next failed: " + HttpError.message(e))
    case Ok(resp) -> {
      val requestId = match HttpResponse.header(resp, "Lambda-Runtime-Aws-Request-Id") {
        case Some(v) -> v
        case None -> ""
      }
      if requestId.length == 0 {
        return Err(error = "GET /invocation/next response is missing the Lambda-Runtime-Aws-Request-Id header")
      }
      val deadlineStr = match HttpResponse.header(resp, "Lambda-Runtime-Deadline-Ms") {
        case Some(v) -> v
        case None -> "0"
      }
      val deadlineMs = match parseOptLong(deadlineStr) { case Some(v) -> v; case None -> 0i64 }
      val invokedArn = match HttpResponse.header(resp, "Lambda-Runtime-Invoked-Function-Arn") {
        case Some(v) -> v
        case None -> ""
      }
      match await HttpResponse.bodyText(resp) {
        case Err(e) -> Err(error = "GET /invocation/next body read failed: " + IOError.message(e))
        case Ok(body) -> Ok(
          value = Invocation(
            requestId = requestId,
            payload = body,
            deadlineMs = deadlineMs,
            invokedFunctionArn = invokedArn
          )
        )
      }
    }
  }
}

func buildAwsContext(inv: in Invocation): LambdaContext {
  return LambdaContext(
    functionName = Env.getVarOrDefault("AWS_LAMBDA_FUNCTION_NAME", ""),
    functionVersion = Env.getVarOrDefault("AWS_LAMBDA_FUNCTION_VERSION", "$LATEST"),
    invokedFunctionArn = inv.invokedFunctionArn,
    memoryLimitInMb = match parseOptInt(Env.getVarOrDefault("AWS_LAMBDA_FUNCTION_MEMORY_SIZE", "128")) {
      case Some(v) -> v
      case None -> 128
    },
    requestId = inv.requestId,
    logGroupName = Env.getVarOrDefault("AWS_LAMBDA_LOG_GROUP_NAME", ""),
    logStreamName = Env.getVarOrDefault("AWS_LAMBDA_LOG_STREAM_NAME", ""),
    remainingTimeMs = inv.deadlineMs - nowEpochMillis()
  )
}

// `postAsync` hardcodes `text/plain`; the runtime API response/error/
// init-error bodies are always JSON, so build the request explicitly via
// `sendAsync` (the free-function form — see `getNextInvocation`'s comment
// on why not the `HttpClient` interface) rather than widen the shared
// `Std.Http` post() contract.
//
// `errorType` is non-empty only for the `/error` and `/init/error` POSTs;
// when present it is sent in the `Lambda-Runtime-Function-Error-Type`
// header AWS's Runtime API keys the invocation's error classification on
// (#5592).  A non-2xx status is treated as a transport failure (#5601):
// the API returns 202 Accepted on success, and a 4xx/5xx means the POST
// was rejected (e.g. the request was already responded to), which the
// loop must surface rather than silently swallow.
func postJson(urlStr: in String, body: in String, errorType: in String): Result[Unit, String] {
  match Url.tryFrom(urlStr) {
    case Err(e) -> Err(error = HttpError.message(e))
    case Ok(url) -> {
      val base = withJsonBody(request(POST, url), body)
      // "Lambda-Runtime-Function-Error-Type" is never a reserved framing
      // header, so this can only take the `Ok` branch.
      val req = if errorType.length > 0 {
        match withHeader(base, "Lambda-Runtime-Function-Error-Type", errorType) {
          case Ok(r) -> r
          case Err(_) -> base
        }
      } else {
        base
      }
      match await sendAsync(req) {
        case Err(e) -> Err(error = HttpError.message(e))
        case Ok(resp) -> {
          if HttpResponse.isSuccess(resp) {
            Ok(value = ())
          } else {
            Err(error = "Runtime API POST to " + urlStr + " returned status " + HttpResponse.statusCode(resp).toString())
          }
        }
      }
    }
  }
}

/// Run exactly one GET-next / dispatch / POST-response(-or-error) cycle
/// against `runtimeApi`. `Err` means the transport itself is broken (the
/// GET or the response/error POST failed) — the caller should treat that
/// as fatal, matching AWS's guidance that a custom runtime unable to reach
/// the Runtime API should exit so the execution environment is recycled.
/// A handler-level failure (the registered handler returned `Err`, or no
/// handler was registered) is NOT a transport error: it is reported via
/// `POST .../error` and `Ok(Unit)` is returned so the loop keeps polling.
@stable(since = "0.1")
pub func pollAndDispatchOnce(runtimeApi: in String, app: in LambdaApp): Result[Unit, String] {
  match getNextInvocation(runtimeApi) {
    case Err(e) -> Err(error = e)
    case Ok(inv) -> {
      val ctx = buildAwsContext(inv)
      match dispatchInvocation(app, inv.payload, ctx) {
        case Ok(body) -> postJson(
          "http://" + runtimeApi + "/2018-06-01/runtime/invocation/" + inv.requestId + "/response",
          body,
          ""
        )
        case Err(lambdaErr) -> postJson(
          "http://" + runtimeApi + "/2018-06-01/runtime/invocation/" + inv.requestId + "/error",
          lambdaErrorJson(lambdaErr),
          lambdaErrorType(lambdaErr)
        )
      }
    }
  }
}

func postInitError(runtimeApi: in String, message: in String): Result[Unit, String] {
  return postJson(
    "http://" + runtimeApi + "/2018-06-01/runtime/init/error",
    awsErrorJson(message, "InitError"),
    "InitError"
  )
}

/// Entry point for `Lambda.Kernel.Runtime`'s `aws` feature variant. Blocks
/// forever, polling `$AWS_LAMBDA_RUNTIME_API` and dispatching each
/// invocation, until the transport itself fails (at which point it POSTs
/// `/init/error` if that is still reachable — best-effort, per AWS's own
/// guidance that a runtime unable to reach the API should just exit — and
/// terminates the process non-zero).
@stable(since = "0.1")
pub func runAwsCustomRuntimeLoop(app: in LambdaApp): Unit {
  match Env.getVar("AWS_LAMBDA_RUNTIME_API") {
    case Err(_) -> {
      Console.error("Lambda.Kernel.Runtime (aws): AWS_LAMBDA_RUNTIME_API is not set; cannot start the custom runtime loop")
      Env.exitCode(1)
    }
    case Ok(runtimeApi) -> {
      var fatal: Option[String] = None
      while fatal == None {
        match pollAndDispatchOnce(runtimeApi, app) {
          case Ok(_) -> ()
          case Err(msg) -> {
            fatal = Some(value = msg)
          }
        }
      }
      match fatal {
        case Some(msg) -> {
          Console.error("Lambda.Kernel.Runtime (aws): fatal runtime API error: " + msg)
          val _ = postInitError(runtimeApi, msg)
          Env.exitCode(1)
        }
        case None -> ()
      }
    }
  }
}

// ─── local transport: synchronous test server over Std.HttpServer ───────────
func buildLocalContext(): LambdaContext {
  val timeoutMs = match parseOptLong(Env.getVarOrDefault("LYRIC_LOCAL_TIMEOUT_MS", "30000")) {
    case Some(v) -> v
    case None -> 30000i64
  }
  return LambdaContext(
    functionName = "local-function",
    functionVersion = "$LATEST",
    invokedFunctionArn = "arn:aws:lambda:us-east-1:000000000000:function:local-function",
    memoryLimitInMb = 512,
    requestId = uuidToString(newUuid()),
    logGroupName = "/aws/lambda/local-function",
    logStreamName = "local",
    remainingTimeMs = timeoutMs
  )
}

func functionErrorHeaders(): Map[String, String] {
  val h: Map[String, String] = newMap()
  h.add("X-Amz-Function-Error", "Unhandled")
  return h
}

/// Handle exactly one local-server invocation: read the request body as
/// the raw Lambda event JSON, dispatch it, and write the Lambda response
/// (or the AWS error JSON shape, with `X-Amz-Function-Error: Unhandled`,
/// matching `aws lambda invoke --endpoint-url`'s contract) — always HTTP
/// 200, since the Lambda invoke API reports handler failure in the body
/// and a header, not the status line.
@stable(since = "0.1")
pub func handleOneLocalRequest(httpCtx: in HttpContext, app: in LambdaApp): Unit {
  val body = requestBody(httpCtx)
  val ctx = buildLocalContext()
  match dispatchInvocation(app, body, ctx) {
    case Ok(responseBody) -> respondJson(httpCtx, 200, responseBody)
    case Err(err) -> respondBytesWithHeaders(
      httpCtx,
      200,
      "application/json",
      encodeUtf8(lambdaErrorJson(err)),
      functionErrorHeaders()
    )
  }
}

/// Entry point for `Lambda.Kernel.Runtime`'s `local` feature variant.
/// Listens at `localhost:{localPort}` indefinitely; every request (any
/// method or path — this is a single-purpose test server, not a general
/// HTTP endpoint) is treated as one Lambda invocation whose body is the
/// raw event JSON, matching `sam local invoke` / `aws lambda invoke
/// --endpoint-url http://localhost:{localPort}`.
@stable(since = "0.1")
pub func runLocalServer(app: in LambdaApp, localPort: in Int): Unit {
  val prefix = "http://localhost:" + localPort.toString() + "/"
  val listener = startListener(prefix)
  Console.println(
    "[lyric-lambda] local test server listening on " + prefix + " (POST /2015-03-31/functions/function/invocations)"
  )
  while true {
    val httpCtx = nextContext(listener)
    handleOneLocalRequest(httpCtx, app)
  }
}
