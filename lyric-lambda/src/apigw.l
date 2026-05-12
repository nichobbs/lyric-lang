/// Lambda.ApiGw — API Gateway and ALB event types for Lyric Lambda handlers.
///
/// Models the three HTTP event payload formats that AWS delivers to a Lambda
/// function from an HTTP frontend:
///
///   ApiGwV1Event  — REST API (payload format v1.0)
///                   Key fields: httpMethod, path, headers, multiValueHeaders,
///                   queryStringParameters, multiValueQueryStringParameters,
///                   pathParameters, stageVariables, requestContext, body, isBase64Encoded
///
///   ApiGwV2Event  — HTTP API (payload format v2.0)
///                   Key fields: version="2.0", routeKey, rawPath, rawQueryString,
///                   headers, queryStringParameters, pathParameters, cookies,
///                   requestContext.http.{method,path,...}, body, isBase64Encoded
///
///   AlbEvent      — Application Load Balancer
///                   Key fields: httpMethod, path, headers, multiValueHeaders,
///                   queryStringParameters, multiValueQueryStringParameters,
///                   body, isBase64Encoded, requestContext.elb.targetGroupArn
///
/// User code does not usually work with these types directly.  Attach a
/// Web.Router with Lambda.withRouter() and the kernel handles all three
/// formats transparently, mapping each to the correct Web.Route dispatch
/// call and serialising Result[T, Web.ApiError] back to ApiGwResponse.
///
/// Use these types only when you need direct access to API Gateway request
/// context fields (stage variables, authorizer context, request-time epoch,
/// multi-value header maps, etc.) that are not exposed through Web.Router.

@runtime_checked
package Lambda.ApiGw

import Std.Core

// ─── API Gateway v1 (REST API) ────────────────────────────────────────────────

/// Caller identity information from the API Gateway v1 request context.
@stable(since="0.1")
pub record ApiGwV1Identity {
  sourceIp:              Option[String]
  userAgent:             Option[String]
  accountId:             Option[String]
  cognitoIdentityId:     Option[String]
  cognitoIdentityPoolId: Option[String]
  caller:                Option[String]
  user:                  Option[String]
  userArn:               Option[String]
}

/// Request context injected by API Gateway into every v1 event.
@stable(since="0.1")
pub record ApiGwV1RequestContext {
  accountId:         String
  resourceId:        String
  stage:             String
  requestId:         String
  requestTime:       String   // "dd/MMM/yyyy:HH:mm:ss +0000"
  requestTimeEpoch:  Long
  path:              String
  resourcePath:      String   // route template, e.g. "/users/{id}"
  httpMethod:        String
  apiId:             String
  identity:          ApiGwV1Identity
}

/// API Gateway v1.0 (REST API) Lambda event.
///
/// Produced by REST APIs configured with Lambda proxy integration.
/// All header and query-string values are available in both single-value
/// and multi-value forms.  Use multiValueHeaders / multiValueQueryStringParameters
/// when the client may send repeated header names or query keys.
@stable(since="0.1")
pub record ApiGwV1Event {
  /// Always "1.0".
  version:                         String
  /// Route template, e.g. "/users/{id}".
  resource:                        String
  /// Resolved path, e.g. "/users/42".
  path:                            String
  httpMethod:                      String
  headers:                         Option[Map[String, String]]
  multiValueHeaders:               Option[Map[String, [String]]]
  queryStringParameters:           Option[Map[String, String]]
  multiValueQueryStringParameters: Option[Map[String, [String]]]
  pathParameters:                  Option[Map[String, String]]
  stageVariables:                  Option[Map[String, String]]
  requestContext:                  ApiGwV1RequestContext
  body:                            Option[String]
  isBase64Encoded:                 Bool
}

// ─── API Gateway v2 (HTTP API) ────────────────────────────────────────────────

/// HTTP metadata from the API Gateway v2 request context.
@stable(since="0.1")
pub record ApiGwV2Http {
  method:    String
  path:      String
  protocol:  String
  sourceIp:  String
  userAgent: String
}

/// Request context injected by API Gateway into every v2 event.
@stable(since="0.1")
pub record ApiGwV2RequestContext {
  accountId:   String
  apiId:       String
  domainName:  String
  domainPrefix: String
  http:        ApiGwV2Http
  requestId:   String
  routeKey:    String   // e.g. "GET /users/{id}"
  stage:       String   // "$default" for HTTP API default stage
  time:        String
  timeEpoch:   Long
}

/// API Gateway v2.0 (HTTP API) Lambda event.
///
/// Produced by HTTP APIs (lower latency, lower cost than REST APIs).
/// Headers are single-valued (duplicates are comma-joined per RFC 7230 §3.2.2).
/// Cookies are separated into their own field.
/// The raw query string is available unsplit for custom parsing.
@stable(since="0.1")
pub record ApiGwV2Event {
  /// Always "2.0".
  version:               String
  /// Route key, e.g. "GET /users/{id}" or "$default".
  routeKey:              String
  rawPath:               String
  rawQueryString:        String
  cookies:               Option[[String]]
  headers:               Map[String, String]
  queryStringParameters: Option[Map[String, String]]
  pathParameters:        Option[Map[String, String]]
  requestContext:        ApiGwV2RequestContext
  body:                  Option[String]
  isBase64Encoded:       Bool
}

// ─── Application Load Balancer ────────────────────────────────────────────────

/// ALB target group information from the ALB request context.
@stable(since="0.1")
pub record AlbTargetGroup {
  targetGroupArn: String
}

/// Request context injected by ALB into every Lambda event.
@stable(since="0.1")
pub record AlbRequestContext {
  elb: AlbTargetGroup
}

/// Application Load Balancer Lambda event.
///
/// Produced when an ALB rule forwards requests to a Lambda target group.
/// Structurally similar to API Gateway v1 but without stage variables,
/// resource templates, or authorizer context.
/// Multi-value headers require the ALB target group attribute
/// lambda.multi_value_headers.enabled = true.
@stable(since="0.1")
pub record AlbEvent {
  requestContext:                  AlbRequestContext
  httpMethod:                      String
  path:                            String
  queryStringParameters:           Option[Map[String, String]]
  multiValueQueryStringParameters: Option[Map[String, [String]]]
  headers:                         Option[Map[String, String]]
  multiValueHeaders:               Option[Map[String, [String]]]
  body:                            Option[String]
  isBase64Encoded:                 Bool
}

// ─── API Gateway / ALB response ───────────────────────────────────────────────

/// HTTP response returned to API Gateway or ALB from a Lambda handler.
///
/// The kernel produces this automatically from the Result[T, Web.ApiError]
/// returned by handlers registered through Web.Router:
///   Ok(value)  → statusCode 200, body = JSON-serialised value
///   Err(error) → statusCode error.status, body = { "error": msg, "detail": [...] }
///
/// This type is exposed for cases where you need to construct a response
/// manually (binary payloads, custom status codes, multi-value headers).
@stable(since="0.1")
pub record ApiGwResponse {
  statusCode:        Int
  headers:           Map[String, String]
  multiValueHeaders: Option[Map[String, [String]]]
  body:              String
  isBase64Encoded:   Bool
}

/// Construct a plain-JSON API Gateway response.
@stable(since="0.1")
pub func jsonResponse(statusCode: in Int, body: in String): ApiGwResponse
  requires: statusCode >= 100
  requires: statusCode <= 599
{
  return ApiGwResponse(
    statusCode        = statusCode,
    headers           = Map[String, String].of([("Content-Type", "application/json")]),
    multiValueHeaders = None,
    body              = body,
    isBase64Encoded   = false)
}

/// Construct a binary API Gateway response (base64-encoded body).
@stable(since="0.1")
pub func binaryResponse(statusCode: in Int, contentType: in String, base64Body: in String): ApiGwResponse
  requires: statusCode >= 100
  requires: statusCode <= 599
  requires: contentType.length > 0
{
  return ApiGwResponse(
    statusCode        = statusCode,
    headers           = Map[String, String].of([("Content-Type", contentType)]),
    multiValueHeaders = None,
    body              = base64Body,
    isBase64Encoded   = true)
}
