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
//! - Full JSON decode/encode and dispatch for all three Lambda authorizer
//!   types (TOKEN, REQUEST, HTTP API v2) — the IAM-policy and simple
//!   isAuthorized response shapes are already fully modelled in
//!   `Lambda.Authorizer` and needed no new record types.
//!
//! ## What is deliberately NOT implemented (and fails loudly, not silently)
//!
//! - `aws:sns`, `aws:s3`, `aws:dynamodb`, `aws:kinesis`, and EventBridge
//!   events are correctly *detected* (so the loop never misclassifies or
//!   crashes on them) but dispatch returns `LambdaError.InternalError`
//!   naming the missing JSON decoder. Porting the remaining five is
//!   mechanical repetition of the `aws:sqs` pattern below — tracked as
//!   follow-up, not attempted here to keep this change's blast radius
//!   reviewable.
//! - API Gateway v1/v2 and ALB (`Lambda.withRouter`) dispatch: blocked on
//!   `Lambda.Kernel.WebBridge`'s `ConditionalWeakTable<LambdaRouter,
//!   Web.Router>` feasibility spike (docs/35-lambda-library.md; that
//!   kernel's own header comment) — there is no way to resolve a
//!   `LambdaRouter` token back to the `Web.Router` it wraps yet.
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
//! ## A verified pre-existing `Std.Http` gap blocks runtime-testing the `aws`
//! ## client path specifically (not this file's own logic)
//!
//! `getNextInvocation`/`postJson` call `Std.Http`'s free async functions
//! (`getAsync`/`sendAsync`) rather than an `HttpClient` interface value —
//! `defaultClient(): HttpClient` followed by `client.get(url)` from any
//! package other than `Std.Http` itself throws "unsupported method 'get' on
//! the receiver type" at runtime (reproduced with a 10-line repro, zero
//! Lambda code). Switching to the free functions avoids *that* bug, but
//! uncovered a second, more fundamental one: calling `Std.Http.getAsync`
//! (or any of `Std.Http`'s async free functions) from *any* Lyric program
//! throws `System.MissingMethodException` at runtime — reproduced with an
//! equally trivial standalone program with no Lambda code and no assembly
//! boundary of any kind. `lyric-stdlib/tests/http_tests.l`'s own header
//! comment already flags this surface as never actually exercised
//! ("Actually sending a request ... needs a live server and is out of scope
//! here — see docs/57 §5.2"), which is consistent with nothing in this repo
//! having hit it before. Both bugs live in `lyric-stdlib`/`lyric-compiler`,
//! outside `lyric-lambda`'s scope to fix. Net effect: the `aws` feature's
//! client-side GET-next/POST-response loop is believed correct against the
//! documented protocol (mirrors the request/response shape verified
//! end-to-end for the `local` feature, which uses `Std.HttpServer` instead
//! and is unaffected) but could not be runtime-verified in this sandbox.
//! See this change's implementation report for the exact repro commands.
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

func firstRecordEventSource(root: in JsonElement): String {
  match tryGetProperty(root, "Records") {
    case Some(recordsElem) -> {
      match jsonArrayFirst(recordsElem) {
        case Some(first) -> {
          match tryGetProperty(first, "eventSource") {
            case Some(esElem) -> if valueKind(esElem) == 3 { getString(esElem) } else { "" }
            case None -> ""
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
    case _ -> Err(error = InternalError("no handler registered for aws:sqs; register one with Lambda.Direct.sqsHandler / " + "sqsBatchHandler and Lambda.withDirect"))
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
    case _ -> Err(error = InternalError("no handler registered for raw/unrecognised events; register one with " + "Lambda.Direct.rawHandler and Lambda.withDirect"))
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
    case _ -> Err(error = InternalError("no handler registered for the TOKEN authorizer; register one with " + "Lambda.Direct.tokenAuthorizerHandler and Lambda.withDirect"))
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
    case _ -> Err(error = InternalError("no handler registered for the REQUEST authorizer; register one with " + "Lambda.Direct.requestAuthorizerHandler and Lambda.withDirect"))
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
    case _ -> Err(error = InternalError("no handler registered for the HTTP API (v2) authorizer; register one with " + "Lambda.Direct.httpAuthorizerHandler and Lambda.withDirect"))
  }
}

func dispatchHttp(app: in LambdaApp): Result[String, LambdaError] {
  match app.httpRouter {
    case Some(_) -> return Err(
      error = InternalError(
        "HTTP dispatch via Lambda.withRouter is not implemented yet: the Lambda.Kernel.Net " +
          "router-token registry (ConditionalWeakTable<LambdaRouter, Web.Router>) needs a " +
          "feasibility spike before a LambdaRouter token can be resolved back to a Web.Router " +
          "(see docs/35-lambda-library.md and Lambda.Kernel.WebBridge's header comment)"
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

func notImplementedSource(sourceName: in String): Result[String, LambdaError] {
  return Err(
    error = InternalError(
      sourceName + " event JSON decoding is not implemented yet (this release implements aws:sqs, raw, " +
        "and all three authorizer types as the reference pattern; the remaining event sources " +
        "are mechanical repetition of that pattern, tracked as follow-up work)"
    )
  )
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
    case SnsSrc -> notImplementedSource("aws:sns")
    case S3Src -> notImplementedSource("aws:s3")
    case DynamoDbSrc -> notImplementedSource("aws:dynamodb")
    case KinesisSrc -> notImplementedSource("aws:kinesis")
    case EventBridgeSrc -> notImplementedSource("EventBridge")
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
        case Ok(body) -> Ok(value = Invocation(requestId = requestId, payload = body, deadlineMs = deadlineMs, invokedFunctionArn = invokedArn))
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
      val req = if errorType.length > 0 { withHeader(base, "Lambda-Runtime-Function-Error-Type", errorType) } else { base }
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
        case Ok(body) -> postJson("http://" + runtimeApi + "/2018-06-01/runtime/invocation/" + inv.requestId + "/response", body, "")
        case Err(lambdaErr) -> postJson("http://" + runtimeApi + "/2018-06-01/runtime/invocation/" + inv.requestId + "/error", lambdaErrorJson(lambdaErr), lambdaErrorType(lambdaErr))
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
    case Err(err) -> respondBytesWithHeaders(httpCtx, 200, "application/json", encodeUtf8(lambdaErrorJson(err)), functionErrorHeaders())
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
