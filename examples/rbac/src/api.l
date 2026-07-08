//! Rbac.Api — HTTP handler functions and route table.
//!
//! Route table:
//!   POST  /users                    — create user
//!   GET   /users/{id}               — get user
//!   GET   /users/{id}/roles         — list role assignments
//!   POST  /users/{id}/roles         — grant role (requires ManageUsers)
//!   DELETE /users/{id}/roles/{role} — revoke role (requires ManageUsers)
//!   POST  /check                    — check a (userId, permission) pair
@runtime_checked
package Rbac.Api

import Std.Core
import Std.Collections
import Std.Json
import Std.Parse
import Rbac.Policy
import Rbac.Store
import Rbac.Enforcement
import Db
import Web
import Web.Aspects
import OTel

// ─── Aspects ──────────────────────────────────────────────────────────────────
aspect Throttle from Web.Aspects.RateLimit {
  matches: name like "handle*"
  config {
    requestsPerMinute: Int = 200
    burstSize: Int = 30
  }
}

// Env-var resolution (docs/26 §8) is not implemented yet, so
// LYRIC_ASPECT_AUTH_JWTSECRET / _ISSUER / _AUDIENCE are never read at
// runtime — the literal defaults below are what actually runs.
aspect Auth from Web.Aspects.RequiresAuth {
  inside: Throttle
  matches: name in { handleCreateUser, handleGrantRole, handleRevokeRole }
  config {
    @sensitive
    jwtSecret: String = "REPLACE_ME_WITH_A_REAL_SECRET"
    // Obviously-invalid placeholder: an empty string here would let a JWT
    // signed with an empty key validate, silently accepting any token. Set
    // this directly in source before running the example for real — the
    // env var is not wired up.
    issuer: String = "rbac-service"
    audience: String = "rbac-api"
  }
}

// ─── Request records ──────────────────────────────────────────────────────────
pub record CreateUserRequest {
  username: String
}

pub record GrantRoleRequest {
  role: String    // target role name
  grantorId: Long      // user performing the grant
}

pub record CheckRequest {
  userId: Long
  permission: String    // permission label (e.g. "write")
}

// ─── Helpers ──────────────────────────────────────────────────────────────────
func storeErrToApi(e: in StoreError): ApiError {
  val msg = Rbac.Store.errorMessage(e)
  match e {
    case StoreError.UserNotFound(_) -> Web.notFound(msg)
    case StoreError.RoleNotFound(_) -> Web.notFound(msg)
    case StoreError.ResourceNotFound(_) -> Web.notFound(msg)
    case StoreError.PermissionDenied(_) -> Web.forbidden(msg)
    case StoreError.DatabaseError(_) -> Web.internalError(msg)
  }
}

func jsonArr(items: in List[String]): String {
  var buf: String = "["
  var first: Bool = true
  for item in items {
    if not first {
      buf = buf + ","
    }
    buf = buf + item
    first = false
  }
  return buf + "]"
}

// ─── Handlers ─────────────────────────────────────────────────────────────────
// See Ledger.Api for @body / authToken rationale.
@post("/users")
pub func handleCreateUser(@body req: in CreateUserRequest, authToken: String): Result[String, ApiError] {
  val span = OTel.startSpan("rbac.user.create", 1)
  if req.username.length == 0 {
    OTel.endSpan(span)
    return Err(Web.badRequest("username must not be empty"))
  }
  match Db.connectFromEnv() {
    case Err(e) -> {
      OTel.setSpanError(span, e.message)
      OTel.endSpan(span)
      Err(Web.serviceUnavailable("database unavailable"))
    }
    case Ok(conn) -> match Rbac.Store.createUser(conn, req.username) { case Err(e) -> { conn.close(); OTel.setSpanError(span, Rbac.Store.errorMessage(e)); OTel.endSpan(span); Err(storeErrToApi(e)) }; case Ok(user) -> { conn.close(); OTel.setSpanAttribute(span, "user.id", user.id.toString()); OTel.endSpan(span); Ok(Rbac.Store.userToJson(user)) } }
  }
}

@get("/users/{id}")
pub func handleGetUser(id: Long): Result[String, ApiError] {
  val span = OTel.startSpan("rbac.user.get", 1)
  OTel.setSpanAttribute(span, "user.id", id.toString())
  match Db.connectFromEnv() {
    case Err(e) -> {
      OTel.setSpanError(span, e.message)
      OTel.endSpan(span)
      Err(Web.serviceUnavailable("database unavailable"))
    }
    case Ok(conn) -> match Rbac.Store.getUserById(conn, id) { case Err(e) -> { conn.close(); OTel.endSpan(span); Err(storeErrToApi(e)) }; case Ok(None) -> { conn.close(); OTel.endSpan(span); Err(Web.notFound("user " + id.toString() + " not found")) }; case Ok(Some(user)) -> { conn.close(); OTel.endSpan(span); Ok(Rbac.Store.userToJson(user)) } }
  }
}

@get("/users/{id}/roles")
pub func handleGetUserRoles(id: Long): Result[String, ApiError] {
  val span = OTel.startSpan("rbac.roles.list", 1)
  OTel.setSpanAttribute(span, "user.id", id.toString())
  match Db.connectFromEnv() {
    case Err(e) -> {
      OTel.setSpanError(span, e.message)
      OTel.endSpan(span)
      Err(Web.serviceUnavailable("database unavailable"))
    }
    case Ok(conn) -> match Rbac.Store.getRolesForUser(conn, id) { case Err(e) -> { conn.close(); OTel.endSpan(span); Err(storeErrToApi(e)) }; case Ok(assignments) -> { conn.close(); OTel.setSpanAttribute(span, "role.count", assignments.count.toString()); OTel.endSpan(span); val jsons: List[String] = newList(); for a in assignments { jsons.add(Rbac.Store.assignmentToJson(a)) }; Ok(jsonArr(jsons)) } }
  }
}

// authToken injected and validated by Auth aspect before handler body.
@post("/users/{id}/roles")
pub func handleGrantRole(id: Long, @body req: in GrantRoleRequest, authToken: String): Result[String, ApiError] {
  val span = OTel.startSpan("rbac.role.grant", 1)
  OTel.setSpanAttribute(span, "user.id", id.toString())
  OTel.setSpanAttribute(span, "role", req.role)
  OTel.setSpanAttribute(span, "grantor.id", req.grantorId.toString())
  match Db.connectFromEnv() {
    case Err(e) -> {
      OTel.setSpanError(span, e.message)
      OTel.endSpan(span)
      Err(Web.serviceUnavailable("database unavailable"))
    }
    case Ok(conn) -> match Rbac.Enforcement.grantRole(conn, req.grantorId, id, req.role) { case Err(e) -> { conn.close(); OTel.setSpanError(span, Rbac.Store.errorMessage(e)); OTel.endSpan(span); Err(storeErrToApi(e)) }; case Ok(_) -> { conn.close(); OTel.endSpan(span); Ok("{\"granted\":true}") } }
  }
}

@delete("/users/{id}/roles/{role}")
pub func handleRevokeRole(id: Long, role: String, authToken: String): Result[String, ApiError] {
  val span = OTel.startSpan("rbac.role.revoke", 1)
  OTel.setSpanAttribute(span, "user.id", id.toString())
  OTel.setSpanAttribute(span, "role", role)
  match Db.connectFromEnv() {
    case Err(e) -> {
      OTel.setSpanError(span, e.message)
      OTel.endSpan(span)
      Err(Web.serviceUnavailable("database unavailable"))
    }
    case Ok(conn) -> match Rbac.Store.revokeRole(conn, id, role) { case Err(e) -> { conn.close(); OTel.setSpanError(span, Rbac.Store.errorMessage(e)); OTel.endSpan(span); Err(storeErrToApi(e)) }; case Ok(_) -> { conn.close(); OTel.endSpan(span); Ok("{\"revoked\":true}") } }
  }
}

@post("/check")
pub func handleCheck(@body req: in CheckRequest): Result[String, ApiError] {
  val span = OTel.startSpan("rbac.check", 1)
  OTel.setSpanAttribute(span, "user.id", req.userId.toString())
  OTel.setSpanAttribute(span, "permission", req.permission)

  match Rbac.Policy.roleFromString(req.permission) {
    case _ -> ()    // permission is not a role; just proceed
  }
  match Rbac.Policy.permissionLabel(Permission.Read) {
    case _ -> ()    // ensure policy package is linked
  }

  // Resolve permission label to enum variant.
  val permOpt = match req.permission {
    case "read" -> Some(value = Permission.Read)
    case "write" -> Some(value = Permission.Write)
    case "delete" -> Some(value = Permission.Delete)
    case "manage_users" -> Some(value = Permission.ManageUsers)
    case "administer_all" -> Some(value = Permission.AdministerAll)
    case _ -> None
  }

  match permOpt {
    case None -> {
      OTel.endSpan(span)
      Err(Web.badRequest("unknown permission: " + req.permission))
    }
    case Some(perm) -> match Db.connectFromEnv() { case Err(e) -> { OTel.setSpanError(span, e.message); OTel.endSpan(span); Err(Web.serviceUnavailable("database unavailable")) }; case Ok(conn) -> match Rbac.Enforcement.check(conn, req.userId, perm) { case Err(e) -> { conn.close(); OTel.endSpan(span); Err(storeErrToApi(e)) }; case Ok(CheckResult.Allowed(roleName)) -> { conn.close(); OTel.setSpanAttribute(span, "check.result", "allowed"); OTel.endSpan(span); Ok("{\"allowed\":true,\"via_role\":\"" + roleName + "\"}") }; case Ok(CheckResult.Denied(reason)) -> { conn.close(); OTel.setSpanAttribute(span, "check.result", "denied"); OTel.endSpan(span); Ok("{\"allowed\":false,\"reason\":\"" + reason + "\"}") } } }
  }
}

// ─── Web.Request adapters ───────────────────────────────────────────────────────
// See Ledger.Api for the adapter rationale (aspect-guarded handlers keep their
// original parameter list; each adapter does the request-shape plumbing).
func authTokenFrom(req: in Web.Request): String {
  match Web.header(req, "authorization") {
    case Some(v) -> if v.startsWith("Bearer ") { v.substring(7) } else { v }
    case None -> ""
  }
}

func idPathParam(req: in Web.Request): Result[Long, ApiError] {
  match Web.pathParam(req, "id") {
    case None -> Err(Web.badRequest("missing path parameter: id"))
    case Some(raw) -> match parseOptLong(raw) { case Some(n) -> Ok(n); case None -> Err(Web.badRequest("id must be an integer: " + raw)) }
  }
}

func toResponse(result: in Result[String, ApiError]): Web.Response {
  match result {
    case Ok(body) -> Web.json(200, body)
    case Err(e) -> Web.errorResponse(e)
  }
}

func parseCreateUserRequest(body: in String): Result[CreateUserRequest, ApiError] {
  return try {
    val doc = parseJson(body)
    val root = rootElement(doc)
    val req = CreateUserRequest(username = getString(getProperty(root, "username")))
    disposeJson(doc)
    Ok(req)
  } catch Bug as e {
    Err(Web.badRequest("malformed request body: " + e.message))
  }
}

func parseGrantRoleRequest(body: in String): Result[GrantRoleRequest, ApiError] {
  return try {
    val doc = parseJson(body)
    val root = rootElement(doc)
    val req = GrantRoleRequest(
      role = getString(getProperty(root, "role")),
      grantorId = getInt64(getProperty(root, "grantorId"))
    )
    disposeJson(doc)
    Ok(req)
  } catch Bug as e {
    Err(Web.badRequest("malformed request body: " + e.message))
  }
}

func parseCheckRequest(body: in String): Result[CheckRequest, ApiError] {
  return try {
    val doc = parseJson(body)
    val root = rootElement(doc)
    val req = CheckRequest(
      userId = getInt64(getProperty(root, "userId")),
      permission = getString(getProperty(root, "permission"))
    )
    disposeJson(doc)
    Ok(req)
  } catch Bug as e {
    Err(Web.badRequest("malformed request body: " + e.message))
  }
}

pub func adaptCreateUser(req: in Web.Request): Web.Response {
  match parseCreateUserRequest(req.body) {
    case Err(e) -> Web.errorResponse(e)
    case Ok(body) -> toResponse(handleCreateUser(body, authTokenFrom(req)))
  }
}

pub func adaptGetUser(req: in Web.Request): Web.Response {
  match idPathParam(req) {
    case Err(e) -> Web.errorResponse(e)
    case Ok(id) -> toResponse(handleGetUser(id))
  }
}

pub func adaptGetUserRoles(req: in Web.Request): Web.Response {
  match idPathParam(req) {
    case Err(e) -> Web.errorResponse(e)
    case Ok(id) -> toResponse(handleGetUserRoles(id))
  }
}

pub func adaptGrantRole(req: in Web.Request): Web.Response {
  match idPathParam(req) {
    case Err(e) -> Web.errorResponse(e)
    case Ok(id) -> match parseGrantRoleRequest(req.body) { case Err(e) -> Web.errorResponse(e); case Ok(body) -> toResponse(handleGrantRole(id, body, authTokenFrom(req))) }
  }
}

pub func adaptRevokeRole(req: in Web.Request): Web.Response {
  match idPathParam(req) {
    case Err(e) -> Web.errorResponse(e)
    case Ok(id) -> match Web.pathParam(req, "role") { case None -> Web.errorResponse(Web.badRequest("missing path parameter: role")); case Some(role) -> toResponse(handleRevokeRole(id, role, authTokenFrom(req))) }
  }
}

pub func adaptCheck(req: in Web.Request): Web.Response {
  match parseCheckRequest(req.body) {
    case Err(e) -> Web.errorResponse(e)
    case Ok(body) -> toResponse(handleCheck(body))
  }
}

// ─── Route handlers ───────────────────────────────────────────────────────────
// Web.Handler is an interface, not a stored closure: invoking a closure
// defined in one package from another package that also defines its own
// closures is unreliable in the current self-hosted MSIL backend (issue
// #5363), so each adapter above is registered via a small record wrapper.
record CreateUserHandler {
}

impl Web.Handler for CreateUserHandler {
  func handle(req: in Web.Request): Web.Response {
    adaptCreateUser(req)
  }
}

record GetUserHandler {
}

impl Web.Handler for GetUserHandler {
  func handle(req: in Web.Request): Web.Response {
    adaptGetUser(req)
  }
}

record GetUserRolesHandler {
}

impl Web.Handler for GetUserRolesHandler {
  func handle(req: in Web.Request): Web.Response {
    adaptGetUserRoles(req)
  }
}

record GrantRoleHandler {
}

impl Web.Handler for GrantRoleHandler {
  func handle(req: in Web.Request): Web.Response {
    adaptGrantRole(req)
  }
}

record RevokeRoleHandler {
}

impl Web.Handler for RevokeRoleHandler {
  func handle(req: in Web.Request): Web.Response {
    adaptRevokeRole(req)
  }
}

record CheckHandler {
}

impl Web.Handler for CheckHandler {
  func handle(req: in Web.Request): Web.Response {
    adaptCheck(req)
  }
}

// ─── Route table ──────────────────────────────────────────────────────────────
pub func routes(): Web.Router {
  val r = Web.create()
  val r = Web.addPost(r, "/users", CreateUserHandler())
  val r = Web.addGet(r, "/users/{id}", GetUserHandler())
  val r = Web.addGet(r, "/users/{id}/roles", GetUserRolesHandler())
  val r = Web.addPost(r, "/users/{id}/roles", GrantRoleHandler())
  val r = Web.addDelete(r, "/users/{id}/roles/{role}", RevokeRoleHandler())
  val r = Web.addPost(r, "/check", CheckHandler())
  return r
}
