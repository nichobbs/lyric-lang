/// Lambda.Authorizer — event types and response types for Lambda authorizer functions.
///
/// AWS API Gateway supports two authorizer models, each with a distinct event
/// shape and response contract:
///
///   REST API (v1) authorizers
///   ─────────────────────────
///   TOKEN authorizer    — receives an Authorization header value and the ARN
///                         of the method being invoked.  Handler must verify the
///                         token (e.g. JWT) and return an IAM policy document.
///
///   REQUEST authorizer  — receives the full request context (headers, query
///                         parameters, stage variables).  Used when the
///                         authorization decision depends on more than a single
///                         header value.  Returns the same IAM policy type.
///
///   HTTP API (v2) authorizers
///   ─────────────────────────
///   Lambda authorizer   — receives a lightweight request context derived from
///                         the HTTP API event.  Returns a simple boolean
///                         { isAuthorized, context } instead of an IAM policy.
///                         The context map is forwarded to the backend handler
///                         as request context fields.
///
/// Handler signatures:
///   TOKEN:   func h(event: Lambda.Authorizer.TokenAuthorizerEvent,   ctx: Lambda.LambdaContext): Result[Lambda.Authorizer.AuthorizerResponse,     Lambda.LambdaError]
///   REQUEST: func h(event: Lambda.Authorizer.RequestAuthorizerEvent, ctx: Lambda.LambdaContext): Result[Lambda.Authorizer.AuthorizerResponse,     Lambda.LambdaError]
///   HTTP:    func h(event: Lambda.Authorizer.HttpAuthorizerEvent,    ctx: Lambda.LambdaContext): Result[Lambda.Authorizer.HttpAuthorizerResponse, Lambda.LambdaError]
///
/// Registration (in main() via the LambdaApp builder):
///   Lambda.newApp()
///     |> Lambda.onTokenAuthorizer("MyApp.Auth.verifyToken")
///
/// Each authorizer type is registered independently; a single Lambda function
/// acts as one type of authorizer.  Combine types only when the same handler
/// logic applies to multiple invocation shapes.
///
/// See docs/35-lambda-library.md §5 (Authorizers), D063.

@runtime_checked
package Lambda.Authorizer

import Std.Core

// ─── REST API TOKEN authorizer event ─────────────────────────────────────────

/// Event delivered to a REST API TOKEN Lambda authorizer.
///
/// AWS extracts the configured identity source (typically the Authorization
/// header) into authorizationToken and provides the ARN of the route being
/// invoked in methodArn.
///
/// methodArn format:
///   arn:aws:execute-api:{region}:{accountId}:{apiId}/{stage}/{httpMethod}/{resource}
/// e.g.:
///   arn:aws:execute-api:us-east-1:123456789:abc123/prod/GET/users/*/orders
@stable(since="0.1")
pub record TokenAuthorizerEvent {
  /// The raw value of the configured identity source header (e.g. "Bearer eyJ...").
  authorizationToken: String
  /// ARN of the API method being requested; used to scope the returned policy.
  methodArn:          String
}

// ─── REST API REQUEST authorizer event ───────────────────────────────────────

/// Request context embedded in a REST API REQUEST authorizer event.
@stable(since="0.1")
pub record RequestAuthorizerContext {
  accountId:        String
  apiId:            String
  httpMethod:       String
  requestId:        String
  resourceId:       String
  resourcePath:     String
  stage:            String
  path:             String
  requestTime:      String
  requestTimeEpoch: Long
}

/// Event delivered to a REST API REQUEST Lambda authorizer.
///
/// Carries the full request context including all headers, query parameters,
/// path parameters, and stage variables.  The identity source configured on
/// the authorizer determines which fields matter for the authorization decision,
/// but all request metadata is available for policy enrichment.
@stable(since="0.1")
pub record RequestAuthorizerEvent {
  type:                String   // always "REQUEST"
  methodArn:           String
  headers:             Option[Map[String, String]]
  multiValueHeaders:   Option[Map[String, [String]]]
  queryStringParameters:          Option[Map[String, String]]
  multiValueQueryStringParameters: Option[Map[String, [String]]]
  pathParameters:      Option[Map[String, String]]
  stageVariables:      Option[Map[String, String]]
  requestContext:      RequestAuthorizerContext
}

// ─── HTTP API (v2) authorizer event ──────────────────────────────────────────

/// HTTP metadata in an HTTP API authorizer event.
@stable(since="0.1")
pub record HttpAuthorizerHttp {
  method:    String
  path:      String
  protocol:  String
  sourceIp:  String
  userAgent: String
}

/// Request context in an HTTP API authorizer event.
@stable(since="0.1")
pub record HttpAuthorizerRequestContext {
  accountId:   String
  apiId:       String
  domainName:  String
  http:        HttpAuthorizerHttp
  requestId:   String
  routeKey:    String
  stage:       String
  time:        String
  timeEpoch:   Long
}

/// Event delivered to an HTTP API (v2) Lambda authorizer.
///
/// Similar to the HTTP API (v2) Lambda event but without a body.  The
/// identitySource field contains the configured identity source expression
/// (e.g. "$request.header.Authorization"), resolved to its actual value.
@stable(since="0.1")
pub record HttpAuthorizerEvent {
  version:               String   // always "2.0"
  type:                  String   // always "REQUEST"
  routeArn:              String
  identitySource:        String   // resolved identity source value
  routeKey:              String
  rawPath:               String
  rawQueryString:        String
  cookies:               Option[[String]]
  headers:               Map[String, String]
  queryStringParameters: Option[Map[String, String]]
  pathParameters:        Option[Map[String, String]]
  stageVariables:        Option[Map[String, String]]
  requestContext:        HttpAuthorizerRequestContext
}

// ─── REST API authorizer response (IAM policy) ───────────────────────────────

/// Effect of an IAM policy statement.
@stable(since="0.1")
pub union IamEffect {
  case Allow
  case Deny
}

/// A single IAM policy statement.
///
/// For API Gateway authorizers, action should be ["execute-api:Invoke"] and
/// resource should be one or more method ARNs.  The wildcard form
/// "arn:aws:execute-api:{region}:{accountId}:{apiId}/{stage}/*" grants or
/// denies access to all methods on the stage.
@stable(since="0.1")
pub record IamStatement {
  effect:   IamEffect
  action:   [String]   // e.g. ["execute-api:Invoke"]
  resource: [String]   // method ARNs; may contain wildcards
}

/// IAM policy document returned to API Gateway by a REST API authorizer.
@stable(since="0.1")
pub record IamPolicyDocument {
  version:   String          // always "2012-10-17"
  statement: [IamStatement]
}

/// Full authorizer response for REST API TOKEN and REQUEST authorizers.
///
/// policyDocument determines which API methods the caller can invoke.
/// context is forwarded to the integration (Lambda handler) as
/// $context.authorizer.{key} — use it to pass claims or user IDs downstream
/// without the handler re-parsing the token.
/// usageIdentifierKey is the API key value for usage-plan throttling; leave
/// None when not using API keys.
@stable(since="0.1")
pub record AuthorizerResponse {
  principalId:          String
  policyDocument:       IamPolicyDocument
  context:              Map[String, String]
  usageIdentifierKey:   Option[String]
}

/// Allow the caller to invoke the specific method ARN.
/// Grants execute-api:Invoke on exactly the requested resource.
@stable(since="0.1")
pub func allow(principalId: in String, methodArn: in String): AuthorizerResponse
  requires: principalId.length > 0
  requires: methodArn.length > 0
{
  return AuthorizerResponse(
    principalId        = principalId,
    policyDocument     = IamPolicyDocument(
      version   = "2012-10-17",
      statement = [IamStatement(effect = IamEffect.Allow, action = ["execute-api:Invoke"], resource = [methodArn])]),
    context            = Map[String, String].empty(),
    usageIdentifierKey = None)
}

/// Allow the caller to invoke all methods on the same API stage.
/// Derives the wildcard resource from methodArn by replacing the
/// method + resource suffix with "/*".
@stable(since="0.1")
pub func allowAll(principalId: in String, methodArn: in String): AuthorizerResponse
  requires: principalId.length > 0
  requires: methodArn.length > 0
{
  val parts     = methodArn.splitOn("/")
  val stageBase = parts[0] + "/" + parts[1] + "/*"
  return AuthorizerResponse(
    principalId        = principalId,
    policyDocument     = IamPolicyDocument(
      version   = "2012-10-17",
      statement = [IamStatement(effect = IamEffect.Allow, action = ["execute-api:Invoke"], resource = [stageBase])]),
    context            = Map[String, String].empty(),
    usageIdentifierKey = None)
}

/// Deny the caller access to the specific method ARN.
@stable(since="0.1")
pub func deny(principalId: in String, methodArn: in String): AuthorizerResponse
  requires: principalId.length > 0
  requires: methodArn.length > 0
{
  return AuthorizerResponse(
    principalId        = principalId,
    policyDocument     = IamPolicyDocument(
      version   = "2012-10-17",
      statement = [IamStatement(effect = IamEffect.Deny, action = ["execute-api:Invoke"], resource = [methodArn])]),
    context            = Map[String, String].empty(),
    usageIdentifierKey = None)
}

/// Attach a context map to an authorizer response.
/// The context is forwarded to the backend handler as $context.authorizer.{key}.
/// Values must be strings; serialize complex types (e.g. JSON) before attaching.
@stable(since="0.1")
pub func withContext(response: in AuthorizerResponse, ctx: in Map[String, String]): AuthorizerResponse {
  return AuthorizerResponse(
    principalId        = response.principalId,
    policyDocument     = response.policyDocument,
    context            = ctx,
    usageIdentifierKey = response.usageIdentifierKey)
}

/// Set the usage identifier key for API key throttling.
@stable(since="0.1")
pub func withUsageKey(response: in AuthorizerResponse, key: in String): AuthorizerResponse
  requires: key.length > 0
{
  return AuthorizerResponse(
    principalId        = response.principalId,
    policyDocument     = response.policyDocument,
    context            = response.context,
    usageIdentifierKey = Some(key))
}

// ─── HTTP API (v2) authorizer response ───────────────────────────────────────

/// Simple authorizer response for HTTP API (v2) Lambda authorizers.
///
/// isAuthorized determines whether the request proceeds.
/// context is forwarded to the backend handler as $context.authorizer.{key}.
@stable(since="0.1")
pub record HttpAuthorizerResponse {
  isAuthorized: Bool
  context:      Map[String, String]
}

/// Allow the request to proceed with no context.
@stable(since="0.1")
pub func authorized(): HttpAuthorizerResponse {
  return HttpAuthorizerResponse(isAuthorized = true, context = Map[String, String].empty())
}

/// Allow the request to proceed, forwarding context to the backend handler.
@stable(since="0.1")
pub func authorizedWithContext(ctx: in Map[String, String]): HttpAuthorizerResponse {
  return HttpAuthorizerResponse(isAuthorized = true, context = ctx)
}

/// Deny the request.  API Gateway returns 403 Forbidden to the caller.
@stable(since="0.1")
pub func denied(): HttpAuthorizerResponse {
  return HttpAuthorizerResponse(isAuthorized = false, context = Map[String, String].empty())
}
